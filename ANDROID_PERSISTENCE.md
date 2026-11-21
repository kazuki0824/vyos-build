# R86S Android external persistent disks

This PR updates the `r86s-kvm` flavor to use Android tools' external-state
disk contract. It requires both the `virtio_x86_64_tv_grub` product PR and
the `android_device_maleicacid_androidtv_tools` build PR to be merged.

- The ISO contains a replaceable, read-only `androidtv.qcow2` and the
  Android-built `persist.img` (16 MiB FAT32, initial GRUB env and A/B state).
- A **destructive new VyOS installation** creates host GPT #4 userdata,
  #5 metadata (34 MiB with an inner GPT and 32 MiB metadata at guest vdc1),
  and #6 persist (raw 16 MiB FAT32 at guest vdd).
- The VM attaches host GPT #4 as vdb, #5 as vdc, and #6 as vdd.
- An ordinary VyOS image upgrade must retain all three host GPT state
  partitions and MUST NOT copy persist.img onto an existing installation.
- A migration from the previous 2-partition state layout is not automatic:
  GPT #4 previously consumed the remaining disk. Back up / relocate data
  before adding GPT #6. Never pair existing encrypted userdata with fresh
  blank metadata.

Acceptance after merging all three PRs: clean VyOS ISO build, fresh install,
full Android boot, write/read app state, VyOS image upgrade, retained state,
and successful reboot. No runtime test has been performed by this PR.
