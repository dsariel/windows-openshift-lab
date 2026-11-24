# Feature 0002: VM as Pod (KubeVirt)

**Status:** ✅ Implemented

## Summary
Windows VMs as pods using OpenShift Virtualization with automated installation, serial console, network verification.

## Skills Demonstrated
OpenShift Virtualization, KubeVirt, QEMU, virtctl, PVC/CDI, serial console (EMS), bcdedit

## What We Learned

**Critical Windows/KubeVirt Configuration:**
```yaml
devices:
  disks:
    - disk: {bus: sata}      # SATA required, SCSI fails
  interfaces:
    - model: e1000e          # Native drivers, not virtio-net
  autoattachSerialConsole: true
```

**Emergency Management Services (EMS):**
- bcdedit order: `/emssettings` → `/ems on` → `/bootdebug on`
- Port 1, baud 115200, works only after Windows boots
- Requires autoattachSerialConsole in VM spec

**Storage:**
- virtctl image-upload for multi-GB ISOs (~15-20 min)
- ISO needs Joliet extensions (-J flag)
- PVC sizing: 10Gi (ISO), 60Gi (Windows disk)

**Challenges:**
- SCSI bus: Windows can't find autounattend.xml → use SATA
- No network: virtio-net needs drivers → use e1000e
- Blank serial console: normal during install → use VNC

## Implementation
Scripts: `spawn-vm-pod.sh`, `check-vm-network.sh`
Components: HyperConverged CR, VirtualMachine, VirtualMachineInstance, PVCs, virtctl
