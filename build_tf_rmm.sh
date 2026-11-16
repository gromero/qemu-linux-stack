#!/usr/bin/env bash

set -euo pipefail
set -x

if [ -z "${DISABLE_CONTAINER_CHECK:-}" ]; then
    ./container.sh ./build_tf_rmm.sh
    exit 0
fi

clone()
{
    ./clone.sh \
        tf-rmm \
        https://review.trustedfirmware.org/TF-RMM/tf-rmm.git \
        7f0d6b222bc02c79f45d1cb95c26d3586db18153 \
        patches/rmm-silence-Unhandled-read-write-regs-info.patch \
        patches/rmm-add-granules-for-non-coherent-devices.patch \
        patches/rmm-runtime-rmi-do-not-require-PMUv3p7-at-boot.patch
}

build()
{
    pushd $(readlink -f tf-rmm)
    env CROSS_COMPILE=aarch64-linux-gnu- \
      cmake -DRMM_CONFIG=qemu_sbsa_defcfg \
      -DCMAKE_BUILD_TYPE=Debug \
      -DLOG_LEVEL=40 \
      -S . -B build
    intercept-build --append \
    make -C build -j "$(nproc)"
    sed -i compile_commands.json -e 's/"cc"/"aarch64-linux-gnu-gcc"/'
    popd
}

clone
build
