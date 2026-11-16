#!/usr/bin/env bash

# Build the firmware needed to boot the stack on the Arm FVP
# (FVP_Base_RevC-2xAEMvA) with FEAT_RME and RME-DA:
#   TF-RMM (fvp_defcfg) -> EDK2 (ArmVExpress-FVP) -> DTB -> TF-A (PLAT=fvp)
#
# This mirrors what Shrinkwrap's cca-3world.yaml + TF-RMM's cca_da.yaml build,
# but uses the clone.sh/container.sh conventions of this repo. Sources are
# cloned under fvp-* names, unpatched, so they never clash with the qemu_sbsa
# trees built by build_tf_rmm.sh/build_arm_trusted_firmware.sh/build_edk2.sh.
#
# The kernel and rootfs are *not* built here: run ./build_kernel.sh and
# ./build_rootfs.sh (or ./build.sh) first. The DTB is compiled with the dtc
# from that kernel tree.
#
# Output: out/fvp/{bl1.bin,fip.bin,fvp-base-revc.dtb,rmm.img,FVP_AARCH64_EFI.fd}
#
# Component versions can be overridden from the environment.

set -euo pipefail
set -x

if [ -z "${DISABLE_CONTAINER_CHECK:-}" ]; then
    ./container.sh ./build_fvp_fw.sh
    exit 0
fi

: "${FVP_RMM_URL:=https://review.trustedfirmware.org/TF-RMM/tf-rmm.git}"
: "${FVP_RMM_VERSION:=7f0d6b222bc02c79f45d1cb95c26d3586db18153}"
: "${FVP_TFA_URL:=https://github.com/ARM-software/arm-trusted-firmware}"
: "${FVP_TFA_VERSION:=7bbda56cecb40232444c223615ba9e8c6968c4b6}"
: "${FVP_EDK2_URL:=https://github.com/tianocore/edk2.git}"
: "${FVP_EDK2_VERSION:=edk2-stable202608}"
: "${FVP_EDK2_PLATFORMS_URL:=https://github.com/tianocore/edk2-platforms}"
: "${FVP_EDK2_PLATFORMS_VERSION:=d672a812054e9d4fe5868a1ee65f438c10710535}"

export CROSS_COMPILE=aarch64-linux-gnu-
top=$(pwd)
out=$top/out/fvp

clone()
{
    ./clone.sh fvp-tf-rmm "$FVP_RMM_URL" "$FVP_RMM_VERSION"
    ./clone.sh fvp-arm-trusted-firmware "$FVP_TFA_URL" "$FVP_TFA_VERSION"
    ./clone.sh fvp-edk2 "$FVP_EDK2_URL" "$FVP_EDK2_VERSION"
    pushd fvp-edk2
    ../clone.sh edk2-platforms "$FVP_EDK2_PLATFORMS_URL" \
        "$FVP_EDK2_PLATFORMS_VERSION"
    popd
}

build_rmm()
{
    pushd $(readlink -f fvp-tf-rmm)
    cmake -DRMM_CONFIG=fvp_defcfg \
          -DCMAKE_BUILD_TYPE=Debug \
          -DLOG_LEVEL=40 \
          -S . -B build-fvp
    make -C build-fvp -j "$(nproc)"
    popd
}

build_edk2()
{
    pushd $(readlink -f fvp-edk2)
    export PACKAGES_PATH=$(pwd):$(pwd)/edk2-platforms
    export GCC_AARCH64_PREFIX=$CROSS_COMPILE
    make -C BaseTools -j $(nproc)
    # always build in debug to enable traces
    bash -c ". edksetup.sh &&
    build -q -n $(nproc) -a AARCH64 -b DEBUG -t GCC \
    -p Platform/ARM/VExpressPkg/ArmVExpress-FVP-AArch64.dsc \
    --pcd PcdShellDefaultDelay=0 \
    --pcd PcdUefiShellDefaultBootEnable=1"
    popd
}

# Same DTB as Shrinkwrap's dt-base.yaml: fvp-base-revc.dts plus an overlay
# that reserves the firmware carveout (RMM lives at 0xFDC00000), fixes the
# timer frequency, adds PSCI/cpu-map and enables the virtio-9p device.
build_dtb()
{
    local linux=$(readlink -f linux)
    local dtc=$linux/scripts/dtc/dtc
    if [ ! -x "$dtc" ]; then
        echo "error: $dtc not found, run ./build_kernel.sh first"
        exit 1
    fi
    local dts=$linux/arch/arm64/boot/dts/arm/fvp-base-revc.dts
    local tmp=$out/fvp-base-revc.tmp.dtb
    mkdir -p $out
    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        -I $linux/include -I $linux/arch/arm64/boot/dts \
        -I $linux/scripts/dtc/include-prefixes \
        $dts | $dtc -q -I dts -O dtb -o $tmp -
    ( $dtc -q -I dtb -O dts $tmp; cat << 'EOF'
/ {
    reserved-memory {
        fw: fw@7C000000 {
            reg = <0x00000000 0xFC000000 0 0x04000000>;
            no-map;
        };
    };
    timer {
        clock-frequency = <100000000>;
    };
    psci {
        compatible = "arm,psci-1.0", "arm,psci-0.2";
        max-pwr-lvl = <2>;
    };
    cpus {
        cpu-map {
            cluster0 {
                core0 { cpu = <&{/cpus/cpu@0}>; };
                core1 { cpu = <&{/cpus/cpu@100}>; };
                core2 { cpu = <&{/cpus/cpu@200}>; };
                core3 { cpu = <&{/cpus/cpu@300}>; };
            };
            cluster1 {
                core0 { cpu = <&{/cpus/cpu@10000}>; };
                core1 { cpu = <&{/cpus/cpu@10100}>; };
                core2 { cpu = <&{/cpus/cpu@10200}>; };
                core3 { cpu = <&{/cpus/cpu@10300}>; };
            };
        };
    };
    bus@8000000 {
        motherboard-bus@8000000 {
            iofpga-bus@300000000 {
                virtio@200000 {
                    status = "okay";
                };
            };
        };
    };
};
EOF
    ) | $dtc -q -I dts -O dtb -o $out/fvp-base-revc.dtb -
    rm -f $tmp
}

build_tfa()
{
    # TF-A compiles its fw_config DTS too, and the container has no dtc
    local dtc=$(readlink -f linux)/scripts/dtc/dtc
    pushd $(readlink -f fvp-arm-trusted-firmware)
    # tf-a is not very good to handle config changes, so simply clean it
    git clean -ffdx
    # On PLAT=fvp, ENABLE_RMM=1 also turns on the DA pieces (FIRME IDE-KM,
    # attestation, PLAT_PCIE_ROOT_COMPLEX_MAX), see plat/arm/board/fvp/platform.mk
    make PLAT=fvp \
         ENABLE_FEAT_RME=1 \
         ENABLE_RMM=1 \
         RMM=$(readlink -f ../fvp-tf-rmm)/build-fvp/Debug/rmm.img \
         BL33=$(readlink -f ../fvp-edk2)/Build/ArmVExpress-FVP-AArch64/DEBUG_GCC/FV/FVP_AARCH64_EFI.fd \
         FVP_HW_CONFIG=$out/fvp-base-revc.dtb \
         FEATURE_DETECTION=0 \
         ARM_DISABLE_TRUSTED_WDOG=1 \
         LOG_LEVEL=40 \
         DEBUG=1 \
         DTC=$dtc \
         all fip -j$(( $(nproc) < 8 ? $(nproc) : 8 ))
    popd
}

output()
{
    mkdir -p $out
    rsync fvp-arm-trusted-firmware/build/fvp/debug/{bl1.bin,fip.bin} $out/
    rsync fvp-tf-rmm/build-fvp/Debug/rmm.img $out/
    rsync fvp-edk2/Build/ArmVExpress-FVP-AArch64/DEBUG_GCC/FV/FVP_AARCH64_EFI.fd $out/
}

clone
build_rmm
build_edk2
build_dtb
build_tfa
output
ls -la $out
