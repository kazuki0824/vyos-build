#!/bin/bash
set -eu -o pipefail

start_sudo_keepalive() {
  sudo -v || return 1

  local parent_pid=$$
  (
    while true; do
      sleep 60
      kill -0 "$parent_pid" 2>/dev/null || exit 0
      sudo -n -v >/dev/null 2>&1 || exit 0
    done
  ) &

  SUDO_KEEPALIVE_PID=$!
  export SUDO_KEEPALIVE_PID
}

stop_sudo_keepalive() {
  if [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  unset SUDO_KEEPALIVE_PID
  sudo -k
}

trap 'stop_sudo_keepalive' EXIT INT TERM

start_sudo_keepalive


########################################################################

sudo git clean -xdf

wget -P ./packages/ https://github.com/tsukumijima/px4_drv/releases/download/v0.4.5/px4-drv-dkms_0.4.5_all.deb

cd scripts/package-build/linux-kernel/
REF="v6.6.133"
FIRMWARE_REF="20260309"
if [ ! -d linux ]; then
  git clone git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git --no-single-branch --depth 1 -b $REF
else
  cd linux
  git fetch -vv
  git reset --hard HEAD
  git switch $REF --detach
  cd ..
fi
if [ ! -d linux-firmware ]; then
  git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git --single-branch
else
  cd linux-firmware
  git reset --hard HEAD
  git switch main
  git pull -vv
  git switch $FIRMWARE_REF --detach
  cd ..
fi
cd ../../../

ANDROID_TOOLS_DIR="${ANDROID_TOOLS_DIR:-$(realpath ../android_device_maleicacid_androidtv_tools)}"
ANDROID_PRODUCT="r86s_virtio_tv"
ANDROID_OUT_DIR="$ANDROID_TOOLS_DIR/build-work/out/target/product/$ANDROID_PRODUCT"
BOOT_QCOW2="$ANDROID_OUT_DIR/disk-vda.qcow2"
USERDATA_QCOW2="$ANDROID_OUT_DIR/userdata-empty.qcow2"
ANDROID_STAGE_DIR="$(pwd)/data/live-build-config/includes.chroot/usr/local/share/android-tv"

if [ ! -x $ANDROID_TOOLS_DIR ]; then
  git clone https://github.com/kazuki0824/android_device_maleicacid_androidtv_tools.git $ANDROID_TOOLS_DIR
fi

## Build Android
(cd ../ && source "$ANDROID_TOOLS_DIR/get_android_qcow2.sh")


test -f "$BOOT_QCOW2"
test -f "$USERDATA_QCOW2"

sudo rm -rf "$ANDROID_STAGE_DIR"
sudo mkdir -p "$ANDROID_STAGE_DIR"
sudo cp -f "$BOOT_QCOW2" "$ANDROID_STAGE_DIR/androidtv.qcow2"
sudo cp -f "$USERDATA_QCOW2" "$ANDROID_STAGE_DIR/userdata-empty.qcow2"

DOCKER_ENV_ARGS=()
if [ -n "${VYOS1X_REPO_URL:-}" ]; then
  DOCKER_ENV_ARGS+=(-e "VYOS1X_REPO_URL=$VYOS1X_REPO_URL")
fi

sudo docker pull vyos/vyos-build:current
sudo docker run --privileged --rm -i "${DOCKER_ENV_ARGS[@]}" -v $(pwd):/vyos -w /vyos vyos/vyos-build:current bash << EOF
set -eu -o pipefail
sudo mount -i -o remount,exec,dev /vyos

sudo apt update
sudo apt install llvm-dev libclang-dev clang flex bison bc kmod libssl-dev libelf-dev python3-dev libtraceevent-dev -y

# note: https://lore.kernel.org/lkml/20240401212303.537355-4-ojeda@kernel.org/
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --default-toolchain nightly-2023-08-01 --component rust-src -y
source '/home/vyos_bld/.cargo/env'
cargo install bindgen-cli --version 0.68.1 --locked

cd scripts/package-build/linux-kernel/
./build-kernel.sh
./build-linux-firmware.sh
mv -v ./*.deb ../../../packages/
cd ../../../

sudo ./build-vyos-image r86s-kvm --architecture amd64 --build-by 'maleicacid824+dev@gmail.com' --custom-package bluez --custom-package bluez-alsa-utils --custom-package alsa-utils --custom-package zstd --custom-package python3-dbus
EOF

