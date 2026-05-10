#!/usr/bin/env bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: qemu_aarch64_cmd"
    exit 1
fi

set -x

[ -v INIT ] || INIT=/host/host.sh

mkdir -p out/EFI
cp -f out/Image ./out/EFI/Image
cat > ./out/EFI/startup.nsh << EOF
fs0:
Image nokaslr root=/dev/vda rw init=/init pcie_acs_override=downstream,multifunction
EOF

# Need to cd to spdm_responder_emu folder so it can access keys
#(cd out/spdm/ && ./spdm_responder_emu --trans PCI_DOE --slot_count 1)&
#spdm_pid=$!
kill_spdm_emu()
{
	echo oops
#	(kill $spdm_pid && wait $spdm_pid) || true
}
trap kill_spdm_emu EXIT

# wait for spdm_emu
sleep 1

dd if=/dev/urandom of=out/disk bs=1M count=1

"$@" \
-nodefaults \
-display none \
-serial mon:stdio \
-netdev user,id=vnet \
-device virtio-net-pci,netdev=vnet \
-M sbsa-ref \
-cpu max,x-rme=on \
-smp 1 \
-m 2G \
-drive file=out/SBSA_FLASH0.fd,format=raw,if=pflash \
-drive file=out/SBSA_FLASH1.fd,format=raw,if=pflash \
-drive file=fat:rw:out/EFI,format=raw,if=none,id=drv0 \
-device ide-hd,drive=drv0 \
-drive format=raw,file=./out/host.ext4,if=virtio \
-virtfs local,path=$(pwd)/,mount_tag=host,security_model=mapped,readonly=off \
-device pcie-root-port,id=root_port,chassis=1,slot=0 \
-device ahci,id=ahci,spdm_port=2323,bus=root_port \
-drive id=disk,file=out/disk,if=none \
-device ide-hd,drive=disk,bus=ahci.0 \
-d unimp \
-d guest_errors \
-d invalid_mem

# -drive file=fat:rw:out/EFI,format=raw,if=none,id=drv0 \  # drv0 file with EFI fs
# -device ide-hd,drive=drv0 \                              # 1. IDE device drive drv0 (sdb/sdb1)
# -drive format=raw,file=./out/host.ext4,if=virtio \       # 2. Virtio device drive with host.ext4 fs (vda)
# -virtfs local,path=$(pwd)/,mount_tag=host,security_model=mapped,readonly=off \
# -device pcie-root-port,id=root_port,chassis=1,slot=0 \   # PCIe bus where ICH9 connects
# -device ahci,id=ahci,spdm_port=2323,bus=root_port \      # ICH9 SATA Controller with AHCI
# -drive id=disk,file=out/disk,if=none \                   # Disk0 file
# -device ide-hd,drive=disk,bus=ahci.0 \                   # 3. IDE device drive Disk0 (sda)

rm -rf out/EFI
rm -f out/disk
