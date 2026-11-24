# Feature 0010: CSI Driver for Windows

**Status:** Proposed | **Priority:** P2

## Summary
Implement CSI driver for Windows nodes (currently only in-tree drivers supported).

## Skills Demonstrated
Go (Kubernetes CSI), Windows storage APIs, gRPC, CSI spec compliance

## What We'll Learn
- CSI spec: NodeStageVolume, NodePublishVolume, etc.
- Windows volume management APIs
- golang.org/x/sys/windows package

## Proposal
Build CSI node plugin (Go) → Windows volume mount/unmount → gRPC server → test with PVCs

## Testing (Lab)
✅ Driver development, gRPC APIs, unit tests
❌ Full CSI workflow (needs kubelet integration + storage backend)

**Upstream:** kubernetes-csi
