# Feature 0013: Disconnected Environment Support for Windows Nodes

**Status:** Proposed | **Priority:** P1

## Summary
Enable WMCO in air-gapped clusters (OpenShift 4.22 limitation).

## Skills Demonstrated
Go (WMCO), air-gap architecture, image mirroring, ImageContentSourcePolicy

## What We'll Learn
- Registry mirror configuration
- Payload mirroring (containerd, kubelet binaries)
- ImageContentSourcePolicy for Windows images
- Bootstrap bundle creation

## Proposal
Mirror registry for images → HTTP server for payloads → WMCO ConfigMap for mirror URLs → simulate air-gap with firewall

## Testing (Lab)
✅ Fully testable: local mirrors, simulated air-gap with iptables

**Upstream:** WMCO
