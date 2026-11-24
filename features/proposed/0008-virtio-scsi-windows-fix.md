# Feature 0008: VirtIO-SCSI Support for Windows VMs

**Status:** Proposed | **Priority:** P1

## Summary
Fix VirtIO-SCSI disk bus for Windows in KubeVirt/QEMU. Currently Windows can't find autounattend.xml on SCSI, requires SATA workaround.

## Skills Demonstrated
C programming (QEMU), VirtIO protocol, Windows device enumeration, QEMU device models, upstream contribution

## What We'll Learn
- QEMU virtio-scsi device model implementation
- Windows Setup device enumeration during PE phase
- VirtIO vs SATA bus differences
- QEMU tracing and debugging

## Motivation
**Current:** SCSI fails (autounattend.xml not found)
**Workaround:** SATA works but is legacy
**Goal:** Modern VirtIO-SCSI support

## Proposal
1. Reproduce bug with QEMU tracing
2. Root cause: device enumeration timing or driver availability
3. Fix in QEMU virtio-scsi.c
4. Test across Windows 2019/2022/2025
5. Submit to qemu-devel@nongnu.org

## Testing
```bash
# CI test
./spawn-vm-pod.sh windows --disk-bus=scsi
./spawn-vm-pod.sh wait-install
./spawn-vm-pod.sh verify-windows
```

**Lab Testability:** ✅ Fully testable
**Upstream:** QEMU project
