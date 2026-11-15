#!/usr/bin/env bash

# Boot the stack on the Arm FVP (FVP_Base_RevC-2xAEMvA) with FEAT_RME and
# RME-DA enabled, using the firmware built by ./build_fvp_fw.sh and the
# kernel/rootfs built by ./build_kernel.sh and ./build_rootfs.sh.
#
# Model parameters mirror Shrinkwrap's FVP_Base_RevC-2xAEMvA-rme.yaml (+arch
# v9.2) and TF-RMM's model-enable-da.yaml (FVP_DA_DIR, see below).
#
# Environment:
#   FVP         model binary            (default: FVP_Base_RevC-2xAEMvA in PATH)
#   FVP_DA_DIR  dir with pci_fixedup.json, sample_key/, measurements.json
#               generated from TF-RMM tools/shrinkwrap (default: ~/fvp/da)
#   KERNEL      kernel Image            (default: out/Image)
#   ROOTFS      host rootfs             (default: out/host.ext4)
#   INIT        script run by init      (default: /host/host.sh)
#
# The current directory is shared with the FVP as 9p tag "host" (mounted at
# /host by rootfs/common/init), like -virtfs in run.sh.
#
# Consoles: terminal_0 (uart0: TF-A BL1/BL2, EDK2, Linux) is attached here via
# telnet. uart1/uart2/uart3 (BL31/secure/RMM) are logged to out/fvp/uartN.log.

set -euo pipefail

[ -v FVP ] || FVP=FVP_Base_RevC-2xAEMvA
[ -v FVP_DA_DIR ] || FVP_DA_DIR=$HOME/fvp/da
[ -v KERNEL ] || KERNEL=out/Image
[ -v ROOTFS ] || ROOTFS=out/host.ext4
[ -v INIT ] || INIT=/host/host.sh

fw=out/fvp
for f in $fw/bl1.bin $fw/fip.bin $fw/fvp-base-revc.dtb $KERNEL $ROOTFS \
         $FVP_DA_DIR/pci_fixedup.json; do
    if [ ! -f "$f" ]; then
        echo "error: $f not found (run ./build_fvp_fw.sh, ./build_kernel.sh, ./build_rootfs.sh)"
        exit 1
    fi
done
if ! which $FVP > /dev/null; then
    echo "error: $FVP not found"
    exit 1
fi

# EDK2 loads Image/fdt.dtb over semihosting and runs startup.nsh from the
# semihosting root (same trick as Shrinkwrap's ns-edk2-base.yaml).
semihost=$(mktemp -d)
fvp_pid=
cleanup()
{
    [ -n "$fvp_pid" ] && kill $fvp_pid 2> /dev/null && wait $fvp_pid || true
    rm -rf $semihost
}
trap cleanup EXIT

cp -f $KERNEL $semihost/Image
cp -f $fw/fvp-base-revc.dtb $semihost/fdt.dtb
cat > $semihost/startup.nsh << EOF
Image dtb=fdt.dtb nokaslr console=ttyAMA0 earlycon=pl011,0x1c090000 root=/dev/vda rw init=/init kvm-arm.mode=rmm -- $INIT
EOF

rm -f $fw/uart*.log
: > $fw/fvp.log

set -x
$FVP \
    -C bp.secureflashloader.fname=$fw/bl1.bin \
    -C bp.flashloader0.fname=$fw/fip.bin \
    -C bp.virtioblockdevice.image_path=$ROOTFS \
    -C bp.virtiop9device.root_path=$(pwd) \
    -C bp.virtiop9device.mount_tag=host \
    -C cluster0.cpu0.semihosting-cwd=$semihost \
    `# consoles` \
    -C bp.terminal_0.start_telnet=0 \
    -C bp.terminal_1.start_telnet=0 \
    -C bp.terminal_2.start_telnet=0 \
    -C bp.terminal_3.start_telnet=0 \
    -C bp.pl011_uart0.out_file=$fw/uart0.log \
    -C bp.pl011_uart1.out_file=$fw/uart1.log \
    -C bp.pl011_uart2.out_file=$fw/uart2.log \
    -C bp.pl011_uart3.out_file=$fw/uart3.log \
    -C bp.pl011_uart0.unbuffered_output=1 \
    -C bp.pl011_uart1.unbuffered_output=1 \
    -C bp.pl011_uart2.unbuffered_output=1 \
    -C bp.pl011_uart3.unbuffered_output=1 \
    `# FVP_Base_RevC-2xAEMvA-base.yaml` \
    -C bp.dram_size=4 \
    -C cluster0.NUM_CORES=4 \
    -C cluster1.NUM_CORES=4 \
    -C cluster0.PA_SIZE=48 \
    -C cluster1.PA_SIZE=48 \
    -C bp.vis.disable_visualisation=1 \
    -C bp.refcounter.non_arch_start_at_default=1 \
    -C bp.ve_sysregs.exit_on_shutdown=1 \
    -C pctl.startup=0.0.0.0 \
    -C cluster0.clear_reg_top_eret=2 \
    -C cluster1.clear_reg_top_eret=2 \
    -C bp.smsc_91c111.enabled=1 \
    -C bp.hostbridge.userNetworking=1 \
    -C bp.hostbridge.userNetPorts=8022=22 \
    -C cache_state_modelled=0 \
    -C cluster0.stage12_tlb_size=1024 \
    -C cluster1.stage12_tlb_size=1024 \
    -C cluster0.check_memory_attributes=0 \
    -C cluster1.check_memory_attributes=0 \
    -C cluster0.gicv3.cpuintf-mmap-access-level=2 \
    -C cluster1.gicv3.cpuintf-mmap-access-level=2 \
    -C cluster0.gicv3.without-DS-support=1 \
    -C cluster1.gicv3.without-DS-support=1 \
    -C cluster0.gicv4.mask-virtual-interrupt=1 \
    -C cluster1.gicv4.mask-virtual-interrupt=1 \
    -C bp.virtio_rng.enabled=1 \
    `# arch/v9.2.yaml (v8.0 .. v9.2)` \
    -C cluster0.has_16k_granule=1 -C cluster1.has_16k_granule=1 \
    -C cluster0.has_arm_v8-1=1 -C cluster1.has_arm_v8-1=1 \
    -C cluster0.has_large_system_ext=1 -C cluster1.has_large_system_ext=1 \
    -C cluster0.has_arm_v8-2=1 -C cluster1.has_arm_v8-2=1 \
    -C cluster0.has_large_va=1 -C cluster1.has_large_va=1 \
    -C cluster0.has_sve=1 -C cluster1.has_sve=1 \
    -C cluster0.has_arm_v8-3=1 -C cluster1.has_arm_v8-3=1 \
    -C cluster0.has_arm_v8-4=1 -C cluster1.has_arm_v8-4=1 \
    -C cluster0.has_amu=1 -C cluster1.has_amu=1 \
    -C cluster0.has_arm_v8-5=1 -C cluster1.has_arm_v8-5=1 \
    -C cluster0.has_branch_target_exception=1 -C cluster1.has_branch_target_exception=1 \
    -C cluster0.has_rndr=1 -C cluster1.has_rndr=1 \
    -C cluster0.has_arm_v8-6=1 -C cluster1.has_arm_v8-6=1 \
    -C cluster0.ecv_support_level=2 -C cluster1.ecv_support_level=2 \
    -C cluster0.enhanced_pac2_level=3 -C cluster1.enhanced_pac2_level=3 \
    -C cluster0.has_arm_v8-7=1 -C cluster1.has_arm_v8-7=1 \
    -C cluster0.has_arm_v9-0=1 -C cluster1.has_arm_v9-0=1 \
    -C cluster0.max_32bit_el=0 -C cluster1.max_32bit_el=0 \
    -C cluster0.sve.has_sve2=1 -C cluster1.sve.has_sve2=1 \
    -C cluster0.has_arm_v9-1=1 -C cluster1.has_arm_v9-1=1 \
    -C cluster0.has_arm_v9-2=1 -C cluster1.has_arm_v9-2=1 \
    -C cluster0.has_brbe=1 -C cluster1.has_brbe=1 \
    -C cluster0.brbe_disable_recording=1 -C cluster1.brbe_disable_recording=1 \
    -C cluster0.sve.has_sme=1 -C cluster1.sve.has_sme=1 \
    `# FVP_Base_RevC-2xAEMvA-rme.yaml: FEAT_RME` \
    -C cluster0.rme_support_level=2 \
    -C cluster1.rme_support_level=2 \
    -C bp.secure_memory=0 \
    -C bp.has_rme=1 \
    -C cluster0.output_attributes="ExtendedID[62:55]=MPAM_PMG,ExtendedID[54:39]=MPAM_PARTID,ExtendedID[38:37]=MPAM_SP" \
    -C cluster1.output_attributes="ExtendedID[62:55]=MPAM_PMG,ExtendedID[54:39]=MPAM_PARTID,ExtendedID[38:37]=MPAM_SP" \
    -C cluster0.restriction_on_speculative_execution=2 \
    -C cluster1.restriction_on_speculative_execution=2 \
    -C cluster0.restriction_on_speculative_execution_aarch32=2 \
    -C cluster1.restriction_on_speculative_execution_aarch32=2 \
    `# TF-RMM model-enable-da.yaml: RME-DA (PCIe hierarchy + RME-aware SMMUv3)` \
    -C pci.enable_device_id_checks=0 \
    -C pci.hierarchy_file_name=$FVP_DA_DIR/pci_fixedup.json \
    -C pci.pci_smmuv3.mmu.SMMU_AIDR=0x3 \
    -C pci.pci_smmuv3.mmu.SMMU_IDR0=0x498F769B \
    -C pci.pci_smmuv3.mmu.SMMU_IDR1=0xE733D10 \
    -C pci.pci_smmuv3.mmu.SMMU_IDR3=0x773C \
    -C pci.pci_smmuv3.mmu.SMMU_IDR5=0x4F6 \
    -C pci.pci_smmuv3.mmu.SMMU_S_IDR0=0x1000000 \
    -C pci.pci_smmuv3.mmu.SMMU_S_IDR1=0xA0000002 \
    -C pci.pci_smmuv3.mmu.SMMU_S_IDR2=0x0 \
    -C pci.pci_smmuv3.mmu.SMMU_S_IDR3=0x0 \
    -C pci.pci_smmuv3.mmu.SMMU_ROOT_IDR0=0x80000F \
    -C pci.pci_smmuv3.mmu.SMMU_ROOT_IIDR=0x43B \
    -C pci.pci_smmuv3.mmu.SMMU_R_IDR0=0x1012400 \
    -C pci.pci_smmuv3.mmu.SMMU_R_IDR3=0x10000 \
    -C pci.pci_smmuv3.mmu.SMMU_R_MECIDR=0xF \
    -C pci.pci_smmuv3.mmu.ish_is_osh=1 \
    -C pci.pci_smmuv3.mmu.root_register_page_offset=0x20000 \
    -C pci.pci_smmuv3.mmu.size_of_tlb=1 \
    -C pci.pci_smmuv3.mmu.size_of_gpttlb=1 \
    -C pci.pci_smmuv3.mmu.mec_attribute_transform="UserFlags[31:16]=MECID" \
    -C pci.pci_smmuv3.mmu.mpam_attribute_transform="ExtendedID[62:55]=MPAM_PMG,ExtendedID[54:39]=MPAM_PARTID,ExtendedID[38:37]=MPAM_SP" \
    -C pci.pci_smmuv3.mmu.output_attribute_transform="ExtendedID[31:0]=DeviceID" \
    -C cci550.force_on_from_start=1 \
    > $fw/fvp.log 2>&1 &
fvp_pid=$!
set +x

# wait for the model to open terminal_0 and attach to it
port=
for i in $(seq 1 300); do
    port=$(sed -n 's/.*terminal_0: Listening for serial connection on port \([0-9]*\).*/\1/p' $fw/fvp.log | head -1 || true)
    [ -n "$port" ] && break
    if ! kill -0 $fvp_pid 2> /dev/null; then
        cat $fw/fvp.log
        exit 1
    fi
    sleep 0.1
done
if [ -z "$port" ]; then
    echo "error: FVP did not open terminal_0, see $fw/fvp.log"
    exit 1
fi

echo "-------------------------------------------------------------"
echo "console: telnet localhost $port (ssh: -p 8022 root@localhost)"
echo "logs: $fw/uart{0,1,2,3}.log, $fw/fvp.log"
echo "exit with ctrl + ] then 'quit'"
echo "-------------------------------------------------------------"
telnet localhost $port || true
