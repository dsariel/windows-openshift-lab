# Features

Lab features demonstrating Windows workloads on OpenShift: implemented capabilities, in-progress work, and proposed experiments.

## Status Overview

### Implemented (3)
| # | Title | Skills Demonstrated |
|---|-------|---------------------|
| 0001 | WMCO BYOH Setup | Windows automation, SSH, WMCO, hybrid networking |
| 0002 | VM as Pod (KubeVirt) | OpenShift Virtualization, KubeVirt, QEMU, storage |
| 0003 | CI Testing Framework | Test automation, shell scripting, error handling |

### Proposed - Lab-Testable (8 P1 + 1 P2)
| # | Title | Priority | Skills | Testable |
|---|-------|----------|--------|----------|
| 0004 | Guest Agent Integration | P1 | Windows-Linux interop, virtio, QEMU | ✅ Full |
| 0005 | Crash Dump Collection | P1 | Kernel debugging, WinDbg, automation | ✅ Full |
| 0006 | Windows Debugging Infrastructure | P1 | WinDbg, symbols, kernel debug | ✅ Full |
| 0007 | Performance Benchmarking Suite | P1 | Performance analysis, metrics | ✅ Full |
| **0008** | **VirtIO-SCSI Windows Fix** | **P1** | **C, QEMU, VirtIO, upstream** | **✅ Full** |
| **0012** | **Private Registry Support** | **P1** | **Go, WMCO, certificates, containerd** | **✅ Full** |
| **0013** | **Disconnected Environment** | **P1** | **Go, WMCO, air-gap, mirroring** | **✅ Full** |
| **0016** | **VirtIO-Balloon Memory Reclaim** | **P1** | **C, Windows drivers, VirtIO** | **✅ Full** |
| **0017** | **Cluster-Wide Proxy Support** | **P1** | **Go, WMCO, proxy config** | **✅ Full** |
| 0018 | User-Defined Monitoring | P2 | Go, Prometheus, monitoring | ✅ Full |

### Proposed - Research & Prototype (5 P2)
| # | Title | Priority | Skills | Testable |
|---|-------|----------|--------|----------|
| **0009** | **Windows HPA Metrics** | **P2** | **Go, K8s controllers, metrics** | **⏸️ Partial** |
| **0010** | **CSI Driver for Windows** | **P2** | **Go, CSI, storage APIs** | **⏸️ Partial** |
| **0011** | **Network Policy for Windows** | **P2** | **Go, OVN-K8s, HNS, security** | **⏸️ Partial** |
| **0014** | **VPA for Windows** | **P2** | **Go, VPA, in-place resize** | **⏸️ Partial** |
| **0015** | **GPU Passthrough + Migration** | **P2** | **KubeVirt, GPU-P, SR-IOV** | **❌ Hardware** |

**Legend:** ✅ Full = Fully testable in lab | ⏸️ Partial = Core dev testable, full validation needs infrastructure | ❌ Hardware = Requires specialized hardware

## How to Contribute

1. Copy `TEMPLATE.md` to `proposed/NNNN-feature-name.md`
2. Fill in the template, focusing on what we'll learn
3. Submit PR for review
4. Move to `in-progress/` when work starts
5. Move to `implemented/` when done, documenting what was learned

## Skills Development Areas

### Go Programming (7 features)
- **WMCO Operator:** #0012, #0013, #0017, #0018 (private registry, disconnected, proxy, monitoring)
- **Kubernetes Controllers:** #0009, #0014 (HPA metrics, VPA)
- **Storage/Networking:** #0010, #0011 (CSI driver, network policy)

### C/C++ Systems Programming (3 features)
- **QEMU:** #0008 (VirtIO-SCSI fix)
- **Windows Drivers:** #0016 (VirtIO-balloon memory reclaim)
- **Low-Level Virtualization:** #0015 (GPU passthrough research)

### Windows Expertise (5 features)
- **Kernel Debugging:** #0005, #0006 (crash dumps, WinDbg)
- **Configuration:** #0012, #0013, #0017 (registry, air-gap, proxy)
- **Memory Management:** #0016 (VirtIO-balloon)

### Virtualization Technology (4 features)
- **KubeVirt:** #0002, #0004, #0015 (VM-as-pod, guest agent, GPU)
- **QEMU:** #0008 (VirtIO-SCSI)
- **VirtIO:** #0004, #0008, #0016 (guest agent, SCSI, balloon)

### Performance & Monitoring (3 features)
- **Benchmarking:** #0007 (performance suite)
- **Metrics:** #0009, #0018 (HPA metrics, monitoring)
- **Resource Management:** #0014, #0016 (VPA, memory reclaim)

### Upstream Contribution (10 features)
- **WMCO:** #0012, #0013, #0017, #0018 (enterprise features)
- **QEMU:** #0008 (VirtIO-SCSI fix)
- **VirtIO-Win:** #0016 (balloon driver)
- **KubeVirt:** #0015 (GPU passthrough)
- **OVN-Kubernetes:** #0011 (network policy)
- **VPA:** #0014 (Windows support)
- **CSI:** #0010 (Windows driver)
- **Kubernetes HPA:** #0009 (Windows metrics)

