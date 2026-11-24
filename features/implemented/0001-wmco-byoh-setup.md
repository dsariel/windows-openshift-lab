# Feature 0001: WMCO BYOH Setup

**Status:** ✅ Implemented

## Summary
Automated hybrid Linux/Windows OpenShift lab with Windows Server 2025 joined via WMCO BYOH.

## Skills Demonstrated
Windows Server automation, PowerShell, OpenSSH, WMCO operator, OVN-Kubernetes hybrid networking, containerd

## What We Learned

**Key Technical Details:**
- autounattend.xml + Joliet ISO for unattended install
- WMCO BYOH uses `windows-instances` ConfigMap + SSH keys
- OVN-Kubernetes hybrid overlay: VXLAN (UDP 4789), pod CIDR 10.132.0.0/14
- Containerd sometimes needs reset after Windows Updates
- SATA disk + e1000e NIC for compatibility

**Critical Configuration:**
- Hybrid overlay enabled before WMCO install
- Firewall: SSH (22), WinRM (5985), kubelet (10250), VXLAN (4789)
- SSH key injection in autounattend.xml (not post-install)

**Challenges:**
- Windows Updates break containerd → `reset-containerd` command
- IIS pod unreachable → OVN hybrid overlay + firewall rules
- WMCO timeout → check containerd logs, restart

## Implementation
Scripts: `setup-cluster.sh`, `setup.sh`
Phases: Prerequisites → Windows ISO → VM creation → Install → First logon → Updates → WMCO → Verify
