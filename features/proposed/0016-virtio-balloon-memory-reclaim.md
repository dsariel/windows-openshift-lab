# Feature 0016: VirtIO-Balloon Memory Reclaim for Windows VMs

**Status:** Proposed | **Priority:** P1

## Summary
Implement free page reporting in Windows VirtIO-balloon driver to enable memory overcommit (currently Windows needs 1:1 RAM).

## Skills Demonstrated
C/C++ Windows driver development, Windows Driver Kit (WDK), VirtIO protocol, Windows memory management

## What We'll Learn
- Windows Driver Model (KMDF)
- VirtIO-balloon protocol: inflation/deflation, free page reporting
- Windows Memory Manager (MmProbeAndLockPages, PFN database)
- Standby cache trimming

## Motivation
**Problem:** Windows holds unused memory as standby cache, no reclaim
**Impact:** 10 VMs × 16GB = 160GB host RAM (no overcommit)
**Goal:** Enable overcommit like Linux (potential 50% savings)

## Proposal
Enhance virtio-balloon driver (C) → implement free page reporting → register with Windows Memory Manager → trim standby cache → test with QEMU/KubeVirt

## Testing (Lab)
✅ Driver development, basic functionality
⏸️ Full overcommit testing (needs multiple VMs with workloads)

**Upstream:** virtio-win project (Red Hat)
