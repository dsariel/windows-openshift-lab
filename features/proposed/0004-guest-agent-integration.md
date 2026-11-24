# Feature 0004: Guest Agent Integration

**Status:** Proposed | **Priority:** P1

## Summary
Install qemu-guest-agent in Windows VMs for deeper host-guest integration.

## Skills Demonstrated
QEMU guest agent, VirtIO drivers, Windows services, host-guest protocols

## What We'll Learn
- VirtIO driver package installation (virtio-win.iso)
- Guest agent MSI installation, virtio-serial channel
- File system freeze/thaw for snapshots
- Guest metrics (OS version, IP, hostname)

## Proposal

**VM Spec:**
```yaml
devices:
  - name: guest-agent
    serial:
      type: virtio
```

**Windows Installation:**
```powershell
Invoke-WebRequest -Uri https://.../virtio-win.iso -OutFile C:\virtio-win.iso
Mount-DiskImage -ImagePath C:\virtio-win.iso
msiexec /i D:\guest-agent\qemu-ga-x64.msi /quiet /norestart
Start-Service QEMU-GA; Set-Service QEMU-GA -StartupType Automatic
```

## Testing
```bash
virtctl guestosinfo windows-pod-vm
virtctl fslist windows-pod-vm
oc describe vmi windows-pod-vm | grep guestOSInfo
```

