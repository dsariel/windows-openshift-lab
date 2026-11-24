# VM Operations Guide

Day-to-day operations for Windows VMs running as pods in OpenShift Virtualization.

## VM Lifecycle

### Create VM

```bash
./spawn-vm-pod.sh windows
```

### Start/Stop VM

```bash
# Start
virtctl start windows-pod-vm -n virt-windows

# Stop
virtctl stop windows-pod-vm -n virt-windows

# Restart
virtctl restart windows-pod-vm -n virt-windows
```

### Delete VM

```bash
# Delete VM and keep PVCs
./spawn-vm-pod.sh cleanup

# Delete VM and all PVCs
./spawn-vm-pod.sh cleanup --all
```

## Console Access

### VNC Console

```bash
# Connect to graphical console
virtctl vnc windows-pod-vm -n virt-windows
```

**Use cases:**
- Windows installation monitoring
- Graphical troubleshooting
- Full desktop access

### Serial Console

```bash
# Connect to text console (requires EMS)
virtctl console windows-pod-vm -n virt-windows
```

**Use cases:**
- Command-line access
- Troubleshooting when VNC doesn't work
- Automation and scripting

**Note:** Serial console requires Emergency Management Services (EMS) configured in Windows.

## Monitoring

### VM Status

```bash
# List all VMs
oc get vm -n virt-windows

# Detailed VM status
oc get vm,vmi -n virt-windows -o wide

# VM description
oc describe vm windows-pod-vm -n virt-windows
oc describe vmi windows-pod-vm -n virt-windows
```

### VM Resources

```bash
# Check virt-launcher pod
oc get pods -n virt-windows -l kubevirt.io/vm=windows-pod-vm

# Pod resources
oc top pod -n virt-windows

# PVC usage
oc get pvc -n virt-windows
```

### VM Events

```bash
# Recent events
oc get events -n virt-windows --sort-by=.lastTimestamp

# Watch events live
oc get events -n virt-windows --watch
```

### Logs

```bash
# QEMU logs
oc logs -n virt-windows virt-launcher-windows-xxx -c compute

# virt-launcher logs
oc logs -n virt-windows virt-launcher-windows-xxx
```

## Network Operations

### Check IP Address

```bash
# From VMI status
oc get vmi windows-pod-vm -n virt-windows -o jsonpath='{.status.interfaces[0].ipAddress}'

# Using check script
./check-vm-network.sh
```

### Expose Services

#### NodePort

```yaml
apiVersion: v1
kind: Service
metadata:
  name: windows-rdp
  namespace: virt-windows
spec:
  type: NodePort
  selector:
    kubevirt.io/vm: windows-pod-vm
  ports:
  - protocol: TCP
    port: 3389
    targetPort: 3389
    nodePort: 30389
```

#### Route (HTTP/HTTPS)

```bash
# Expose service via route
oc expose svc windows-http -n virt-windows
oc get route -n virt-windows
```

## Storage Operations

### List PVCs

```bash
oc get pvc -n virt-windows
```

### Expand Disk

```bash
# Edit PVC (if storage class supports volume expansion)
oc edit pvc windows-disk -n virt-windows
# Change storage: request to larger value
```

### Snapshot VM

```bash
# Create VirtualMachineSnapshot
oc apply -f - <<EOF
apiVersion: snapshot.kubevirt.io/v1alpha1
kind: VirtualMachineSnapshot
metadata:
  name: windows-snapshot-$(date +%Y%m%d-%H%M%S)
  namespace: virt-windows
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: windows-pod-vm
EOF

# List snapshots
oc get vmsnapshot -n virt-windows
```

## Common Tasks

### Wait for Installation

```bash
./spawn-vm-pod.sh wait-install
```

### Verify Windows Workload

```bash
./spawn-vm-pod.sh verify-windows
```

### Check Network Connectivity

```bash
./check-vm-network.sh
./check-vm-network.sh console  # Also open console
```

### Update Windows

Connect via console and run Windows Update:
```powershell
# In Windows VM
Install-Module PSWindowsUpdate -Force
Get-WindowsUpdate
Install-WindowsUpdate -AcceptAll -AutoReboot
```

## Troubleshooting

### VM Won't Start

```bash
# Check events
oc get events -n virt-windows --sort-by=.lastTimestamp | tail -20

# Check virt-launcher pod
oc get pods -n virt-windows
oc describe pod virt-launcher-windows-xxx -n virt-windows
```

### Can't Connect to Console

```bash
# VNC not working - check pod
oc get pods -n virt-windows | grep launcher

# Serial console not working - check EMS in Windows
# Connect via VNC first, then configure EMS:
# bcdedit /ems on
```

### Network Issues

```bash
# Check VMI network status
oc get vmi windows-pod-vm -n virt-windows -o yaml | grep -A 20 interfaces

# Check if pod network is reachable
oc rsh -n virt-windows virt-launcher-windows-xxx ping 8.8.8.8
```

### Performance Issues

```bash
# Check resources
oc top pod -n virt-windows

# Increase VM resources (edit VM spec)
oc edit vm windows-pod-vm -n virt-windows
# Update cpu.cores and memory.requests
```

## References

- [KubeVirt User Guide](https://kubevirt.io/user-guide/)
- [virtctl CLI Reference](https://kubevirt.io/user-guide/operations/virtctl_client_tool/)
- [OpenShift Virtualization Docs](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
