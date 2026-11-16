#!/usr/bin/env bash

set -euo pipefail
set -x

if [ -z "${DISABLE_CONTAINER_CHECK:-}" ]; then
    ./container.sh ./build_arm_trusted_firmware.sh
    exit 0
fi

clone()
{
    ./clone.sh \
        arm-trusted-firmware \
        https://github.com/ARM-software/arm-trusted-firmware \
        7bbda56cecb40232444c223615ba9e8c6968c4b6 \
        patches/arm-trusted-firmware-v5-01-qemu-move-manifest-definition-out-of-function.patch \
        patches/arm-trusted-firmware-v5-02-qemu-upgrade-boot-manifest-structure-to-version-5.patch \
        patches/arm-trusted-firmware-v5-03-qemu-add-support-for-coherent-and-non-coherent-memory.patch \
        patches/arm-trusted-firmware-v5-04-qemu-add-support-for-smmu-area.patch \
        patches/arm-trusted-firmware-v5-05-qemu-add-support-for-PCIe-root-complex-memory.patch \
        patches/arm-trusted-firmware-v5-06-qemu-add-plat-rmmd-reserve-memory-for-SBSA-platform.patch \
        patches/arm-trusted-firmware-v5-07-qemu-make-BDF-mapping-top-inclusive.patch \
        patches/arm-trusted-firmware-v5-08-qemu-sbsa-hand-the-SMMUv3-over-to-the-RMM.patch \
        patches/arm-trusted-firmware-v5-09-qemu-Add-stubs-to-support-IDE-key-management.patch \
        patches/arm-trusted-firmware-v5-10-qemu-sbsa-align-NS-DRAM-after-RMM-carveout-to-1GB.patch
}

build()
{
    pushd $(readlink -f arm-trusted-firmware)
    # tf-a is not very good to handle config changes, so simply clean it
    git clean -ffdx
    # boot with edk2, as uboot does not seem to work with rme
    # https://trustedfirmware-a.readthedocs.io/en/latest/components/realm-management-extension.html#building-and-running-tf-a-with-rme
    intercept-build --append \
    make PLAT=qemu_sbsa \
         ENABLE_FEAT_RME=1 \
         ENABLE_RMM=1 \
         `# runtime-detect AMU/trace like FVP: otherwise CPTR_EL3.{TAM,TTA}` \
         `# are unknown bits and the RMM's FEATURE_AVAILABILITY query asserts` \
         ENABLE_FEAT_AMU=2 \
         ENABLE_SYS_REG_TRACE_FOR_NS=2 \
         RMM=../tf-rmm/build/Debug/rmm.img \
         LOG_LEVEL=40 \
         DEBUG=1 \
         all fip -j$(nproc)
    sed -i compile_commands.json -e 's/"cc"/"aarch64-linux-gnu-gcc"/'
    popd
}

clone
build
