# Feature 0015: GPU Passthrough with Live Migration for Windows VMs

**Status:** Proposed | **Priority:** P2

## Summary
Enable GPU passthrough for Windows VMs with live migration using Windows Server 2025 GPU-P (GPU Partitioning).

## Skills Demonstrated
KubeVirt GPU management, Windows Server 2025 GPU-P, SR-IOV, IOMMU (VT-D/AMD-Vi), NVIDIA vGPU

## What We'll Learn
- GPU-P vs DDA (Direct Device Assignment)
- SR-IOV interface for GPUs
- NVIDIA vGPU Software v18.x+
- KubeVirt GPU device plugin

## Motivation
AI/ML inference, CAD/CAM, video encoding, medical imaging, VDI

**Requirement:** Windows Server 2025 Datacenter + NVIDIA vGPU v18+ for live migration

## Proposal
**VM Spec:**
```yaml
devices:
  gpus:
  - name: gpu1
    deviceName: nvidia.com/GP102GL_Tesla_P40
  hostDevices:
  - name: gpu-vf
    deviceName: pci_8086_2030
```

## Testing (Lab)
❌ Requires SR-IOV GPU hardware (Tesla P40, A100, etc.) + multiple physical servers

**Upstream:** KubeVirt
