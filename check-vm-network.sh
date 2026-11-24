#!/bin/bash
# Check Windows VM network connectivity
#
# Usage:
#   ./check-vm-network.sh           # Show status and instructions
#   ./check-vm-network.sh console   # Connect to Windows console directly

set -euo pipefail

# Colors
C_R='\033[0;31m'
C_G='\033[0;32m'
C_Y='\033[0;33m'
C_B='\033[1m'
C_0='\033[0m'

VM_NAME="${1:-windows-pod-vm}"
NAMESPACE="${2:-virt-windows}"

# Support 'console' as first arg
if [[ "${1:-}" == "console" ]]; then
  VM_NAME="windows-pod-vm"
  NAMESPACE="virt-windows"
fi

echo "=== Windows VM Network Status ==="

# Check if VM exists and is running
if ! oc get vmi "$VM_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "❌ VM '$VM_NAME' not found in namespace '$NAMESPACE'"
  exit 1
fi

# Get network info
VM_IP=$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}')
VM_MAC=$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].mac}')
VM_LINK=$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].linkState}')
VM_PHASE=$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')

echo "  VM:     $VM_NAME"
echo "  Phase:  $VM_PHASE"
echo "  IP:     $VM_IP"
echo "  MAC:    $VM_MAC"
echo "  Link:   $VM_LINK"
echo

# Check workload completion
echo "Workload Status:"
POD=$(oc get pod -n "$NAMESPACE" -l kubevirt.io/vm="$VM_NAME" -o name 2>/dev/null || echo "")
if [[ -n "$POD" ]]; then
  echo "  Launcher pod: ${POD##*/}"
  echo "  Note: Check C:\\workload.log and C:\\workload.done from Windows console"
else
  echo "  ⚠️  Launcher pod not found"
fi
echo

# Instructions
echo "To verify internet connectivity from inside Windows:"
echo
echo "  ${C_Y}Option 1: VNC Console (Recommended - always works)${C_0}"
echo "     virtctl vnc $VM_NAME -n $NAMESPACE"
echo "     - Graphical Windows desktop"
echo "     - Works during installation and after"
echo "     - Open PowerShell and run verification commands"
echo
echo "  ${C_Y}Option 2: Serial Console (Only after installation completes)${C_0}"
echo "     virtctl console $VM_NAME -n $NAMESPACE"
echo "     - Text-only console (EMS must be enabled)"
echo "     - ${C_R}Will be blank during Windows installation${C_0}"
echo "     - Works after Windows boots into installed OS"
echo "     - Exit: Ctrl+] or Ctrl+5"
echo
echo "  ${C_B}Commands to run in Windows (PowerShell):${C_0}"
echo "     ipconfig | findstr /C:\"IPv4\"  # Check network config"
echo "     ping 8.8.8.8                   # Test internet"
echo "     type C:\\ip.txt                 # VM IP from workload"
echo "     type C:\\ping-success.txt       # Ping result"
echo "     type C:\\workload.log           # Full workload log"
echo "     type C:\\workload.done          # Completion marker"
echo

# Option to connect directly
if [[ "${1:-}" == "console" ]]; then
  echo -e "${C_Y}Connecting to Windows serial console...${C_0}"
  echo
  echo -e "${C_R}WARNING: Serial console will be blank during Windows installation!${C_0}"
  echo -e "${C_Y}If you see a blank screen, Windows is still installing.${C_0}"
  echo -e "${C_Y}Use VNC instead: virtctl vnc $VM_NAME -n $NAMESPACE${C_0}"
  echo
  echo "Once Windows boots, you can run:"
  echo "  - ipconfig"
  echo "  - ping 8.8.8.8"
  echo "  - type C:\\workload.log"
  echo "  - type C:\\workload.done"
  echo
  echo "Exit console: Ctrl+] or Ctrl+5"
  echo
  sleep 3
  virtctl console "$VM_NAME" -n "$NAMESPACE"
fi
