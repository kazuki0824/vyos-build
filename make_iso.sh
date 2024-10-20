#!/bin/bash
set -eu -o pipefail


sudo git clean -xdf

wget -P ./packages/ https://github.com/tsukumijima/px4_drv/releases/download/v0.4.5/px4-drv-dkms_0.4.5_all.deb

cd scripts/package-build/linux-kernel/
REF="v6.6.56"
FIRMWARE_REF="20240610"
if [ ! -d linux ]; then
  git clone git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git --no-single-branch --depth 1 -b $REF
else
  cd linux
  git fetch -vv
  git switch $REF --detach
  cd ..
fi
if [ ! -d linux-firmware ]; then
  git clone git://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git --single-branch
else
  cd linux-firmware
  git switch main
  git pull -vv
  git switch $FIRMWARE_REF --detach
  cd ..
fi
cd ../../../


sudo docker run --privileged --rm -i -v $(pwd):/vyos -w /vyos vyos/vyos-build:current bash << EOF
set -eu -o pipefail
sudo mount -i -o remount,exec,dev /vyos

sudo apt update
sudo apt install llvm-dev libclang-dev clang -y

# note: https://lore.kernel.org/lkml/20240401212303.537355-4-ojeda@kernel.org/
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --default-toolchain nightly-2023-08-01 --component rust-src -y
source '/home/vyos_bld/.cargo/env'
cargo install bindgen-cli --version 0.68.1 --locked

cd scripts/package-build/linux-kernel/
./build-kernel.sh
./build-linux-firmware.sh
mv -v ./*.deb ../../../packages/
cd ../../../

sudo ./build-vyos-image generic --architecture amd64 --build-by 'maleicacid824+dev@gmail.com' --custom-package bluez --custom-package bluez-alsa-utils --custom-package alsa-utils --custom-package zstd --custom-package python3-dbus
EOF

