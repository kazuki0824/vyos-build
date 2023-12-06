#!/bin/bash
CWD=$(pwd)
KERNEL_SRC=linux

set -e

if [ ! -d ${KERNEL_SRC} ]; then
    echo "Linux Kernel source directory does not exists, please 'git clone'"
    exit 1
fi

cd ${KERNEL_SRC}

if [ -d .git ]; then
    echo "I: Clean modified files - reset Git repo"
    git reset --hard HEAD
    git clean --force -d -x
fi

echo "I: Copy Kernel config (x86_64_vyos_defconfig) to Kernel Source"
cp -rv ${CWD}/arch/ .

KERNEL_VERSION=$(make kernelversion)
KERNEL_SUFFIX=-$(awk -F "= " '/kernel_flavor/ {print $2}' ../../../../data/defaults.toml | tr -d \")
KERNEL_CONFIG=arch/x86/configs/vyos_defconfig

# User-defined configs
make LLVM=1 rustavailable
scripts/config --file $KERNEL_CONFIG --enable CONFIG_SOUND
scripts/config --file $KERNEL_CONFIG --enable CONFIG_SND
scripts/config --file $KERNEL_CONFIG --enable CONFIG_SND_USB
scripts/config --file $KERNEL_CONFIG --module CONFIG_SND_USB_AUDIO
scripts/config --file $KERNEL_CONFIG --enable CONFIG_SAMPLES
scripts/config --file $KERNEL_CONFIG --enable CONFIG_SAMPLES_RUST
scripts/config --file $KERNEL_CONFIG --enable CONFIG_SAMPLES_RUST_MINIMAL
scripts/config --file $KERNEL_CONFIG --enable CONFIG_SAMPLES_RUST_HOSTPROGS
scripts/config --file $KERNEL_CONFIG --module CONFIG_BT
scripts/config --file $KERNEL_CONFIG --module CONFIG_BT_HCIBTUSB
scripts/config --file $KERNEL_CONFIG --enable CONFIG_BT_HCIBTUSB_RTL
scripts/config --file $KERNEL_CONFIG --enable CONFIG_BT_HCIBTUSB_BCM
scripts/config --file $KERNEL_CONFIG --disable CONFIG_MODVERSIONS
scripts/config --file $KERNEL_CONFIG --enable CONFIG_RUST

# VyOS requires some small Kernel Patches - apply them here
# It's easier to habe them here and make use of the upstream
# repository instead of maintaining a full Kernel Fork.
# Saving time/resources is essential :-)
PATCH_DIR=${CWD}/patches/kernel
for patch in $(ls ${PATCH_DIR})
do
    echo "I: Apply Kernel patch: ${PATCH_DIR}/${patch}"
    patch -p1 < ${PATCH_DIR}/${patch}
done

# Change name of Signing Cert
sed -i -e "s/CN =.*/CN=VyOS build time autogenerated kernel key/" certs/default_x509.genkey

TRUSTED_KEYS_FILE=trusted_keys.pem
# start with empty key file
echo -n "" > $TRUSTED_KEYS_FILE
CERTS=$(find ../../../data/live-build-config/includes.chroot/var/lib/shim-signed/mok -name "*.pem" -type f || true)
if [ ! -z "${CERTS}" ]; then
  # add known public keys to Kernel certificate chain
  for file in $CERTS; do
    cat $file >> $TRUSTED_KEYS_FILE
  done
  # Force Kernel module signing and embed public keys
  echo "CONFIG_SYSTEM_TRUSTED_KEYRING" >> $KERNEL_CONFIG
  echo "CONFIG_SYSTEM_TRUSTED_KEYS=\"$TRUSTED_KEYS_FILE\"" >> $KERNEL_CONFIG
fi

echo "I: make vyos_defconfig"
# Select Kernel configuration - currently there is only one
make vyos_defconfig

echo "I: Generate environment file containing Kernel variable"
EPHEMERAL_KEY="/tmp/ephemeral.key"
EPHEMERAL_PEM="/tmp/ephemeral.pem"
cat << EOF >${CWD}/kernel-vars
#!/bin/sh
export KERNEL_VERSION=${KERNEL_VERSION}
export KERNEL_SUFFIX=${KERNEL_SUFFIX}
export KERNEL_DIR=${CWD}/${KERNEL_SRC}
export EPHEMERAL_KEY=${EPHEMERAL_KEY}
export EPHEMERAL_CERT=${EPHEMERAL_PEM}
EOF

echo "I: Build Debian Kernel package"
touch .scmversion
make bindeb-pkg BUILD_TOOLS=1 LOCALVERSION=${KERNEL_SUFFIX} KDEB_PKGVERSION=${KERNEL_VERSION}-1 -j $(getconf _NPROCESSORS_ONLN)

# Back to the old Kernel build-scripts directory
cd $CWD
EPHEMERAL_KERNEL_KEY=$(grep -E "^CONFIG_MODULE_SIG_KEY=" ${KERNEL_SRC}/$KERNEL_CONFIG | awk -F= '{print $2}' | tr -d \")
if test -f "${EPHEMERAL_KEY}"; then
    rm -f ${EPHEMERAL_KEY}
fi
if test -f "${EPHEMERAL_PEM}"; then
    rm -f ${EPHEMERAL_PEM}
fi
if test -f "${KERNEL_SRC}/${EPHEMERAL_KERNEL_KEY}"; then
    openssl rsa -in ${KERNEL_SRC}/${EPHEMERAL_KERNEL_KEY} -out ${EPHEMERAL_KEY}
    openssl x509 -in ${KERNEL_SRC}/${EPHEMERAL_KERNEL_KEY} -out ${EPHEMERAL_PEM}
fi
