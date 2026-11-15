#!/usr/bin/env bash

set -euo pipefail
set -x

if [ -z "${DISABLE_CONTAINER_CHECK:-}" ]; then
    ./container.sh ./build_edk2.sh
    exit 0
fi

clone()
{
    ./clone.sh \
        edk2 \
        https://github.com/tianocore/edk2.git \
        edk2-stable202608

    pushd edk2
    ../clone.sh \
        edk2-platforms \
        https://github.com/tianocore/edk2-platforms \
        d672a812054e9d4fe5868a1ee65f438c10710535
    popd
}

build()
{
    pushd $(readlink -f edk2)

    export PACKAGES_PATH=$(pwd):$(pwd)/edk2-platforms
    # copy bin from TF-A
    mkdir -p Platform/Qemu/Sbsa/
    cp -f ../arm-trusted-firmware/build/qemu_sbsa/debug/*.bin Platform/Qemu/Sbsa/

    make -C BaseTools -j $(nproc)
    export GCC_AARCH64_PREFIX=aarch64-linux-gnu-
    # always build in debug to enable traces
    # Set options to boot by default in EFI shell
    intercept-build --append \
    bash -c ". edksetup.sh &&
    build -q -n $(nproc) -a AARCH64 -b DEBUG -t GCC \
    -D ENABLE_RME \
    -p edk2-platforms/Platform/Qemu/SbsaQemu/SbsaQemu.dsc \
    --pcd PcdUefiShellDefaultBootEnable=1 \
    --pcd PcdShellDefaultDelay=0 \
    --pcd PcdPlatformBootTimeOut=0"
    sed -i compile_commands.json -e 's/"cc"/"aarch64-linux-gnu-gcc"/'
    truncate -s 256M Build/SbsaQemuRme/DEBUG_GCC/FV/SBSA_FLASH*.fd
    popd
}

output()
{
    mkdir -p out
    rsync ./edk2/Build/SbsaQemuRme/DEBUG_GCC/FV/SBSA_FLASH* out/
}

clone
build
output
