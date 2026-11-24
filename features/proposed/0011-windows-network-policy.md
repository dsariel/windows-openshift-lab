# Feature 0011: Network Policy for Windows Pods

**Status:** Proposed | **Priority:** P2

## Summary
Implement NetworkPolicy for Windows by translating to Windows firewall rules via OVN-Kubernetes + HNS.

## Skills Demonstrated
Go (OVN-Kubernetes), Windows HNS APIs, NetworkPolicy semantics, security policies

## What We'll Learn
- OVN-Kubernetes NetworkPolicy controller
- Host Networking Service (HNS) ACL policies
- Windows Firewall configuration for containers

## Proposal
NetworkPolicy watcher → translate to HNS ACL → apply to Windows containers

## Testing (Lab)
✅ Translation logic, HNS API calls, single-pod enforcement
❌ Multi-pod policies, traffic filtering validation (needs cluster)

**Upstream:** OVN-Kubernetes
