#!/usr/bin/env python3
from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f'usage: {sys.argv[0]} <vyos-1x-tree>')

    installer = Path(sys.argv[1]) / 'src/op_mode/image_installer.py'
    text = installer.read_text()

    constants = """CONST_RESERVED_SPACE: int = (2 + 1 + 256) * 1024**2
"""
    constants_new = constants + """
# r86s-kvm keeps Android /data outside the VyOS persistence filesystem.
# The host partition is passed to QEMU as a raw block device and therefore
# must survive VyOS image upgrades and reinstallations.
ANDROID_USERDATA_FLAVOR: str = 'r86s-kvm'
ANDROID_USERDATA_PARTLABEL: str = 'android-userdata'
ANDROID_USERDATA_MIN_SIZE: int = 16 * 1024**3
"""
    text = replace_once(text, constants, constants_new, 'constants')

    old_create = """def create_partitions(target_disk: str, target_size: int,
                      prompt: bool = True) -> None:
    \"\"\"Create partitions on a target disk

    Args:
        target_disk (str): a target disk
        target_size (int): size of disk in bytes
    \"\"\"
    # define target rootfs size in KB (smallest unit acceptable by sgdisk)
    available_size: int = (target_size - CONST_RESERVED_SPACE) // 1024
    if prompt:
        rootfs_size: int = ask_root_size(available_size)
    else:
        rootfs_size: int = available_size

    print(MSG_INFO_INSTALL_PARTITIONING)
    raid.clear()
    disk.disk_cleanup(target_disk)
    disk_details: disk.DiskDetails = disk.parttable_create(target_disk,
                                                           rootfs_size)

    return disk_details

"""

    new_create = """def _android_userdata_layout_enabled() -> bool:
    return get_version_data().get('flavor') == ANDROID_USERDATA_FLAVOR


def _partition_path(drive_path: str, number: int) -> str:
    separator = 'p' if drive_path[-1].isdigit() else ''
    return f'{drive_path}{separator}{number}'


def _find_android_userdata_partition(target_disk: str):
    lsblk = loads(cmdl([
        'lsblk', '-Jpo', 'NAME,TYPE,PARTLABEL,START', target_disk
    ]))
    devices = lsblk.get('blockdevices') or []
    children = devices[0].get('children', []) if devices else []
    matches = [
        part for part in children
        if part.get('type') == 'part'
        and part.get('partlabel') == ANDROID_USERDATA_PARTLABEL
    ]

    if not matches:
        return None
    if len(matches) != 1:
        raise RuntimeError(
            f'Multiple {ANDROID_USERDATA_PARTLABEL} partitions found on '
            f'{target_disk}'
        )

    expected_userdata = _partition_path(target_disk, 4)
    expected_root = _partition_path(target_disk, 3)
    part = matches[0]
    if part.get('name') != expected_userdata:
        raise RuntimeError(
            f'{ANDROID_USERDATA_PARTLABEL} must be partition 4 '
            f'({expected_userdata}), found {part.get("name")}'
        )

    roots = [item for item in children if item.get('name') == expected_root]
    if len(roots) != 1:
        raise RuntimeError(
            f'Cannot preserve {ANDROID_USERDATA_PARTLABEL}: '
            f'VyOS root partition {expected_root} was not found'
        )

    return {
        'path': expected_userdata,
        'start_sector': int(part['start']),
        'root_start_sector': int(roots[0]['start']),
    }


def _create_android_partition_table(target_disk: str, rootfs_size: int,
                                    userdata_partition) -> disk.DiskDetails:
    expected = {
        _partition_path(target_disk, number)
        for number in (1, 2, 3, 4)
    }

    if userdata_partition is None:
        disk.disk_cleanup(target_disk)
        run(
            f'sgdisk -a1 '
            f'-n1:2048:4095 -t1:EF02 '
            f'-n2:4096:+256M -t2:EF00 '
            f'-n3:0:+{rootfs_size}K -t3:8300 '
            f'-n4:0:0 -t4:8300 -c4:{ANDROID_USERDATA_PARTLABEL} '
            f'{target_disk}'
        )
    else:
        partitions = set(disk.partition_list(target_disk))
        unexpected = partitions - expected
        if unexpected:
            raise RuntimeError(
                'Refusing to preserve Android userdata with unexpected '
                f'partitions present: {sorted(unexpected)}'
            )

        # Preserve p4 byte-for-byte. Re-create only the VyOS-owned partitions.
        for number in (1, 2, 3):
            partition = _partition_path(target_disk, number)
            if partition in partitions:
                run(f'wipefs -af {partition}')
                run(f'sgdisk -d {number} {target_disk}')

        run(
            f'sgdisk -a1 '
            f'-n1:2048:4095 -t1:EF02 '
            f'-n2:4096:+256M -t2:EF00 '
            f'-n3:0:+{rootfs_size}K -t3:8300 '
            f'{target_disk}'
        )

    sync()
    run(f'partx -u {target_disk}')

    partitions = disk.partition_list(target_disk)
    return disk.DiskDetails(
        name=target_disk,
        partition={
            'efi': next(
                x for x in partitions
                if x == _partition_path(target_disk, 2)
            ),
            'root': next(
                x for x in partitions
                if x == _partition_path(target_disk, 3)
            ),
        },
    )


def create_partitions(target_disk: str, target_size: int,
                      prompt: bool = True) -> None:
    \"\"\"Create partitions on a target disk

    Args:
        target_disk (str): a target disk
        target_size (int): size of disk in bytes
    \"\"\"
    android_layout = _android_userdata_layout_enabled()
    userdata_partition = (
        _find_android_userdata_partition(target_disk)
        if android_layout else None
    )

    # define target rootfs size in KB (smallest unit acceptable by sgdisk)
    if android_layout and userdata_partition is not None:
        sector_size = int(cmdl(['blockdev', '--getss', target_disk]))
        available_bytes = (
            (
                userdata_partition['start_sector']
                - userdata_partition['root_start_sector']
            )
            * sector_size
        )
    elif android_layout:
        available_bytes = (
            target_size
            - CONST_RESERVED_SPACE
            - ANDROID_USERDATA_MIN_SIZE
        )
    else:
        available_bytes = target_size - CONST_RESERVED_SPACE

    if available_bytes < CONST_MIN_ROOT_SIZE:
        raise RuntimeError(
            'Not enough disk space for the VyOS root partition'
            + (' and 16 GiB Android userdata partition' if android_layout else '')
        )

    available_size: int = available_bytes // 1024
    if prompt:
        rootfs_size: int = ask_root_size(available_size)
    else:
        rootfs_size: int = available_size

    print(MSG_INFO_INSTALL_PARTITIONING)
    raid.clear()

    if android_layout:
        return _create_android_partition_table(
            target_disk, rootfs_size, userdata_partition
        )

    disk.disk_cleanup(target_disk)
    disk_details: disk.DiskDetails = disk.parttable_create(target_disk,
                                                           rootfs_size)

    return disk_details

"""
    text = replace_once(text, old_create, new_create, 'create_partitions')

    raid_gate = """    if len(disks_available) < 2:
        return None
"""
    raid_gate_new = """    # A single stable partition label must resolve to exactly one block device.
    # Do not create duplicate Android userdata partitions through RAID install.
    if _android_userdata_layout_enabled():
        return None

    if len(disks_available) < 2:
        return None
"""
    text = replace_once(text, raid_gate, raid_gate_new, 'RAID gate')

    installer.write_text(text)


if __name__ == '__main__':
    main()
