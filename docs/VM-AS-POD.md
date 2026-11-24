# Windows VM as Pod - Deployment Guide

This guide explains how to run Windows VMs as pods using OpenShift Virtualization in the lab environment.

## Overview

The `spawn-vm-pod.sh` script automates the deployment of Windows VMs as pods using KubeVirt. It handles:
- OpenShift Virtualization operator installation
- ISO upload (Windows + config)
- VM creation with correct configuration (SATA bus, e1000e NIC)
- Automated Windows installation via autounattend.xml
- Serial console configuration (EMS)

## Quick Start

```bash
./setup-cluster.sh              # Create OpenShift cluster
./spawn-vm-pod.sh windows       # Create Windows VM as pod
./check-vm-network.sh           # Check network status
```

## What Works on CRC (Local Lab)

✅ OpenShift Virtualization operator installation  
✅ Windows VM deployment with virtctl image-upload  
✅ Automated unattended Windows installation  
✅ Serial console access (EMS)  
✅ VNC console access  
✅ Network connectivity (pod network via masquerade)  

## Critical Configuration

### Storage Bus (SATA Required)

**Problem:** Windows can't find autounattend.xml on SCSI bus  
**Solution:** Use SATA for all disks and CD-ROMs

```yaml
devices:
  disks:
    - disk:
        bus: sata    # CRITICAL: SCSI doesn't work
      name: windows-disk
    - cdrom:
        bus: sata
        readonly: true
      name: windows-iso
```

### Network Adapter (e1000e for Native Drivers)

**Problem:** virtio-net requires extra driver disk  
**Solution:** Use e1000e (Windows has native drivers)

```yaml
devices:
  interfaces:
    - name: default
      model: e1000e    # CRITICAL: not virtio-net
      masquerade: {}
```

### Serial Console (EMS)

```yaml
devices:
  autoattachSerialConsole: true
```

Then configure in Windows:
```powershell
bcdedit /ems on
bcdedit /emssettings EMSPORT:1 EMSBAUDRATE:115200
```

## Lab Environment (CRC)

The lab uses **CRC (OpenShift Local)** with `crc-csi-hostpath-provisioner` storage class.

The `spawn-vm-pod.sh` script handles:
- ISO upload via `virtctl image-upload`
- PVC creation for Windows ISO, config ISO, and disk
- VM creation with proper configuration

**Manual deployment** (if needed):

```bash
# Upload Windows ISO
virtctl image-upload pvc windows-iso \
  --namespace=virt-windows \
  --image-path=/var/lib/libvirt/images/windows-server-2025-eval.iso \
  --size=10Gi \
  --insecure

# Upload config ISO
virtctl image-upload pvc config-iso \
  --namespace=virt-windows \
  --image-path=.wmco-work/vm-pod-autounattend.iso \
  --size=100Mi \
  --insecure
```

## Accessing Windows VM

```bash
# VNC console (works during installation)
virtctl vnc windows-pod-vm -n virt-windows

# Serial console (works after Windows boots)
virtctl console windows-pod-vm -n virt-windows

# Check VM status
oc get vm,vmi -n virt-windows -o wide
```

## Troubleshooting

### Serial Console is Blank

**Normal:** Serial console is blank during Windows installation  
**Solution:** Use VNC during install, serial console works after boot

### Windows Installation Stuck

```bash
# Check VNC console
virtctl vnc windows-pod-vm -n virt-windows

# Check QEMU logs
oc logs -n virt-windows virt-launcher-windows-xxx -c compute

# Verify SATA bus is used (not SCSI)
oc get vm windows-pod-vm -n virt-windows -o yaml | grep bus
```

### Network Not Working

**Check:** Network adapter is e1000e (not virtio-net)
```bash
oc get vm windows-pod-vm -n virt-windows -o yaml | grep model
```

### ISO Upload Stuck

```bash
# Check DataVolume status
oc get dv -n virt-windows
oc describe dv windows-iso -n virt-windows

# Check CDI pod
oc get pods -n openshift-cnv | grep cdi
```

## References

- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [KubeVirt User Guide](https://kubevirt.io/user-guide/)
- [virtctl CLI Reference](https://kubevirt.io/user-guide/operations/virtctl_client_tool/)
