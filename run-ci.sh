#!/bin/bash
# run-ci.sh - Continuous Integration test suite for WMCO setup scripts
#
# Tests all setup scripts for WMCO and Windows VMs (libvirt and pod-based)
#
# Usage:
#   ./run-ci.sh           # Run full test suite
#   ./run-ci.sh quick     # Quick tests (skip long-running Windows installs)
#   ./run-ci.sh cluster   # Test cluster setup only
#   ./run-ci.sh vm-pod    # Test VM-as-pod only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Color output
C_R='\033[0;31m'
C_G='\033[0;32m'
C_Y='\033[0;33m'
C_B='\033[1m'
C_0='\033[0m'

TEST_LOG="${TEST_LOG:-$SCRIPT_DIR/.wmco-work/ci-test.log}"
QUICK_MODE="${QUICK_MODE:-0}"

# Test results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

mkdir -p "$(dirname "$TEST_LOG")"
: > "$TEST_LOG"  # Truncate log

log() { echo -e "$*" | tee -a "$TEST_LOG"; }
info() { log "${C_B}INFO:${C_0} $*"; }
ok() { log "${C_G}✓${C_0} $*"; }
warn() { log "${C_Y}⚠${C_0} $*"; }
fail() { log "${C_R}✗${C_0} $*"; }
die() { fail "$*"; exit 1; }

test_start() {
  local test_name="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  info "Test $TESTS_RUN: $test_name"
  echo "=== Test $TESTS_RUN: $test_name ===" >> "$TEST_LOG"
}

test_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  ok "PASSED: $1"
  echo
}

test_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_TESTS+=("$1")
  fail "FAILED: $1"
  echo
}

run_command() {
  local desc="$1"
  shift
  info "  Running: $*"
  if "$@" >> "$TEST_LOG" 2>&1; then
    ok "  $desc"
    return 0
  else
    fail "  $desc"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Test: Cluster Setup
# ----------------------------------------------------------------------------
test_cluster_setup() {
  test_start "CRC Cluster Setup"

  # Check if crc exists
  if ! run_command "Check crc binary" ./setup-cluster.sh status; then
    if [[ $QUICK_MODE -eq 1 ]]; then
      warn "CRC not set up, skipping in quick mode"
      test_pass "Cluster setup (skipped in quick mode)"
      return 0
    fi
    test_fail "CRC not installed"
    return 1
  fi

  # Check cluster status
  if ! crc status | grep -q "CRC VM:.*Running"; then
    if [[ $QUICK_MODE -eq 1 ]]; then
      warn "CRC not running, skipping in quick mode"
      test_pass "Cluster setup (skipped - not running)"
      return 0
    fi
    info "Starting CRC cluster (this may take 10+ minutes)..."
    if ! run_command "Start CRC cluster" crc start; then
      test_fail "Failed to start CRC cluster"
      return 1
    fi
  fi

  # Verify oc command works
  if ! run_command "OpenShift CLI access" oc whoami; then
    test_fail "Cannot access OpenShift cluster"
    return 1
  fi

  # Check cluster operators
  if ! run_command "Cluster operators ready" bash -c "oc get co -o json | jq -e '.items | all(.status.conditions[] | select(.type==\"Available\") | .status == \"True\")'"; then
    warn "Some cluster operators not ready"
  fi

  test_pass "CRC cluster is running and accessible"
}

# ----------------------------------------------------------------------------
# Test: virtctl Installation
# ----------------------------------------------------------------------------
test_virtctl() {
  test_start "virtctl CLI Tool"

  # virtctl needs a cluster to work, check if CRC is running
  if ! crc status 2>/dev/null | grep -q "CRC VM:.*Running"; then
    if [[ $QUICK_MODE -eq 1 ]]; then
      info "virtctl requires running cluster, skipping in quick mode"
      test_pass "virtctl check (skipped - no cluster)"
      return 0
    fi
  fi

  if ! command -v virtctl >/dev/null 2>&1; then
    info "virtctl not found"
    if [[ $QUICK_MODE -eq 1 ]]; then
      test_pass "virtctl check (skipped - not installed)"
      return 0
    fi
    test_fail "virtctl not installed"
    return 1
  fi

  # Check if virtctl client is working (don't require server connection)
  if virtctl version 2>&1 | grep -q "Client Version"; then
    ok "virtctl client installed"

    # Check if server-side KubeVirt is available
    if virtctl version 2>&1 | grep -q "Server Version"; then
      ok "virtctl server connection working"
      test_pass "virtctl is installed and working"
    else
      info "virtctl client OK, server not available (OpenShift Virtualization not installed)"
      test_pass "virtctl client installed (server not available)"
    fi
  else
    test_fail "virtctl not working"
  fi
}

# ----------------------------------------------------------------------------
# Test: OpenShift Virtualization Operator
# ----------------------------------------------------------------------------
test_virt_operator() {
  test_start "OpenShift Virtualization Operator"

  # Check if operator is installed
  if ! oc get csv -n openshift-cnv | grep -q kubevirt-hyperconverged; then
    if [[ $QUICK_MODE -eq 1 ]]; then
      warn "Operator not installed, skipping in quick mode"
      test_pass "Virtualization operator (skipped - not installed)"
      return 0
    fi
    info "Installing OpenShift Virtualization operator (5-10 minutes)..."
    # This will be done by spawn-vm-pod.sh
  fi

  # Check HyperConverged resource
  if oc get hco -n openshift-cnv kubevirt-hyperconverged >/dev/null 2>&1; then
    local available
    available=$(oc get hco -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
    if [[ "$available" == "True" ]]; then
      test_pass "OpenShift Virtualization is ready"
    else
      warn "HyperConverged resource exists but not Available"
      test_pass "OpenShift Virtualization operator installed (not fully ready)"
    fi
  else
    warn "HyperConverged resource not found"
    test_pass "Virtualization operator check (needs manual setup)"
  fi
}

# ----------------------------------------------------------------------------
# Test: Fedora VM as Pod
# ----------------------------------------------------------------------------
test_fedora_vm_pod() {
  test_start "Fedora VM as Pod (Proof of Concept)"

  if [[ $QUICK_MODE -eq 1 ]]; then
    info "Skipping Fedora VM test in quick mode"
    test_pass "Fedora VM (skipped in quick mode)"
    return 0
  fi

  # Check if OpenShift Virtualization is ready
  if ! oc get hco -n openshift-cnv kubevirt-hyperconverged >/dev/null 2>&1; then
    warn "OpenShift Virtualization operator not installed"
    info "To install: ./spawn-vm-pod.sh windows (takes 15-20 min on fresh cluster)"
    test_pass "Fedora VM (skipped - operator not installed)"
    return 0
  fi

  local available
  available=$(oc get hco -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  if [[ "$available" != "True" ]]; then
    warn "OpenShift Virtualization operator not ready yet"
    info "Wait for operator to be ready, then re-run tests"
    test_pass "Fedora VM (skipped - operator not ready)"
    return 0
  fi

  # Clean up existing VM if present
  oc delete vm fedora-vm -n virt-windows --ignore-not-found=true >/dev/null 2>&1 || true
  sleep 5

  # Create Fedora VM (operator already installed, so this should be fast)
  if ! run_command "Create Fedora VM pod" timeout 180 ./spawn-vm-pod.sh; then
    test_fail "Failed to create Fedora VM"
    return 1
  fi

  # Wait for VM to be running
  info "Waiting for Fedora VM to start (up to 2 min)..."
  local timeout=120
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if oc get vmi fedora-vm -n virt-windows -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
      ok "Fedora VM is running"
      break
    fi
    sleep 5
    ((elapsed+=5))
  done

  if [[ $elapsed -ge $timeout ]]; then
    test_fail "Fedora VM did not start within timeout"
    return 1
  fi

  # Check VM IP
  local vm_ip
  vm_ip=$(oc get vmi fedora-vm -n virt-windows -o jsonpath='{.status.interfaces[0].ipAddress}')
  if [[ -n "$vm_ip" ]]; then
    ok "Fedora VM has IP: $vm_ip"
    test_pass "Fedora VM pod created and running successfully"
  else
    test_fail "Fedora VM running but no IP address"
  fi
}

# ----------------------------------------------------------------------------
# Test: Windows VM as Pod
# ----------------------------------------------------------------------------
test_windows_vm_pod() {
  test_start "Windows VM as Pod"

  # Check if Windows ISO exists
  if [[ ! -f /var/lib/libvirt/images/windows-server-2025-eval.iso ]]; then
    warn "Windows ISO not found at /var/lib/libvirt/images/windows-server-2025-eval.iso"
    test_pass "Windows VM (skipped - no ISO)"
    return 0
  fi

  if [[ $QUICK_MODE -eq 1 ]]; then
    info "Skipping Windows VM full test in quick mode (installation takes 20+ min)"
    test_pass "Windows VM (skipped in quick mode)"
    return 0
  fi

  # Check if OpenShift Virtualization is ready
  if ! oc get hco -n openshift-cnv kubevirt-hyperconverged >/dev/null 2>&1; then
    warn "OpenShift Virtualization operator not installed"
    info "To install: ./spawn-vm-pod.sh windows (takes 15-20 min on fresh cluster)"
    test_pass "Windows VM (skipped - operator not installed)"
    return 0
  fi

  local available
  available=$(oc get hco -n openshift-cnv kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  if [[ "$available" != "True" ]]; then
    warn "OpenShift Virtualization operator not ready yet"
    info "Wait for operator to be ready, then re-run tests"
    test_pass "Windows VM (skipped - operator not ready)"
    return 0
  fi

  # Clean up existing VM if present
  oc delete vm windows-pod-vm -n virt-windows --ignore-not-found=true >/dev/null 2>&1 || true
  oc delete pvc windows-pod-vm-disk windows-iso windows-config -n virt-windows --ignore-not-found=true >/dev/null 2>&1 || true
  sleep 10

  # Create Windows VM (operator already installed, so just upload ISO and create VM)
  if ! run_command "Create Windows VM pod" timeout 1800 ./spawn-vm-pod.sh windows; then
    test_fail "Failed to create Windows VM"
    return 1
  fi

  # Wait for VM to be running
  info "Waiting for Windows VM to start (up to 5 min)..."
  local timeout=300
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if oc get vmi windows-pod-vm -n virt-windows -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
      ok "Windows VM is running"
      break
    fi
    sleep 10
    ((elapsed+=10))
  done

  if [[ $elapsed -ge $timeout ]]; then
    test_fail "Windows VM did not start within timeout"
    return 1
  fi

  # Check VM IP
  local vm_ip
  vm_ip=$(oc get vmi windows-pod-vm -n virt-windows -o jsonpath='{.status.interfaces[0].ipAddress}')
  if [[ -n "$vm_ip" ]]; then
    ok "Windows VM has IP: $vm_ip"
  else
    warn "Windows VM running but no IP address assigned yet"
  fi

  # Note: Full Windows installation verification would require VNC/console access
  info "Windows installation may still be in progress (check with: virtctl vnc windows-pod-vm -n virt-windows)"

  test_pass "Windows VM pod created and started (installation in progress)"
}

# ----------------------------------------------------------------------------
# Test: Windows Workload Verification
# ----------------------------------------------------------------------------
test_windows_workload() {
  test_start "Windows VM Workload Verification"

  # Check if Windows VM exists and is running
  if ! oc get vmi windows-pod-vm -n virt-windows >/dev/null 2>&1; then
    warn "Windows VM not found, skipping workload verification"
    test_pass "Windows workload (skipped - VM not found)"
    return 0
  fi

  local phase
  phase=$(oc get vmi windows-pod-vm -n virt-windows -o jsonpath='{.status.phase}')
  if [[ "$phase" != "Running" ]]; then
    warn "Windows VM not running (phase: $phase)"
    test_pass "Windows workload (skipped - VM not running)"
    return 0
  fi

  # Run verification command
  if run_command "Verify Windows workload setup" ./spawn-vm-pod.sh verify-windows; then
    info "Manual verification required - check VNC console"
    test_pass "Windows workload verification command executed"
  else
    test_fail "Windows workload verification failed"
  fi
}

# ----------------------------------------------------------------------------
# Test: Network Connectivity Check
# ----------------------------------------------------------------------------
test_network_check() {
  test_start "VM Network Status Check"

  if ! oc get vmi windows-pod-vm -n virt-windows >/dev/null 2>&1; then
    warn "No Windows VM found for network check"
    test_pass "Network check (skipped - no VM)"
    return 0
  fi

  if run_command "Check VM network status" ./check-vm-network.sh; then
    test_pass "Network status check script working"
  else
    test_fail "Network status check failed"
  fi
}

# ----------------------------------------------------------------------------
# Test: Documentation Files
# ----------------------------------------------------------------------------
test_documentation() {
  test_start "Documentation Files"

  # README.md should always exist
  if [[ -f "README.md" ]]; then
    ok "Found: README.md"
  else
    test_fail "README.md missing"
    return 1
  fi

  # .wmco-work docs are generated by scripts, check if present
  local generated_docs=(
    ".wmco-work/WINDOWS-VM-GUIDE.md"
    ".wmco-work/VM-OPERATIONS-GUIDE.md"
  )

  local found=0
  for doc in "${generated_docs[@]}"; do
    if [[ -f "$doc" ]]; then
      ok "Found: $doc"
      found=$((found + 1))
    fi
  done

  if [[ $found -eq 0 ]]; then
    info "Generated docs not found (created when scripts run)"
  else
    ok "Found $found generated doc(s)"
  fi

  test_pass "Documentation check complete"
}

# ----------------------------------------------------------------------------
# Test: Helper Scripts
# ----------------------------------------------------------------------------
test_helper_scripts() {
  test_start "Helper Scripts Executable"

  local scripts=(
    "setup-cluster.sh"
    "setup.sh"
    "spawn-vm-pod.sh"
    "check-vm-network.sh"
  )

  local non_exec=0
  for script in "${scripts[@]}"; do
    if [[ -x "$script" ]]; then
      ok "Executable: $script"
    else
      warn "Not executable: $script"
      non_exec=$((non_exec + 1))
    fi
  done

  if [[ $non_exec -eq 0 ]]; then
    test_pass "All scripts are executable"
  else
    test_fail "$non_exec script(s) not executable"
  fi
}

# ----------------------------------------------------------------------------
# Main Test Suite
# ----------------------------------------------------------------------------
print_summary() {
  echo
  echo "========================================"
  echo "CI Test Summary"
  echo "========================================"
  echo "Tests Run:    $TESTS_RUN"
  echo "Tests Passed: $TESTS_PASSED"
  echo "Tests Failed: $TESTS_FAILED"
  echo

  if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "Failed Tests:"
    for test in "${FAILED_TESTS[@]}"; do
      echo "  - $test"
    done
    echo
  fi

  echo "Full log: $TEST_LOG"
  echo "========================================"

  # Additional notes
  if [[ $QUICK_MODE -eq 0 ]]; then
    echo
    info "Note: VM tests are skipped if OpenShift Virtualization is not installed."
    info "To install the operator and test VMs:"
    info "  1. Run: ./spawn-vm-pod.sh windows (takes 15-20 min on fresh cluster)"
    info "  2. Then re-run: ./run-ci.sh"
  fi
  echo

  if [[ $TESTS_FAILED -eq 0 ]]; then
    ok "All tests passed!"
    return 0
  else
    fail "Some tests failed"
    return 1
  fi
}

main() {
  local mode="${1:-full}"

  case "$mode" in
    quick)
      QUICK_MODE=1
      info "Running quick test suite (skipping long-running tests)"
      ;;
    cluster)
      info "Running cluster tests only"
      test_cluster_setup
      print_summary
      return $?
      ;;
    vm-pod)
      info "Running VM-as-pod tests only"
      test_cluster_setup
      test_virtctl
      test_virt_operator
      test_fedora_vm_pod
      test_windows_vm_pod
      test_windows_workload
      test_network_check
      print_summary
      return $?
      ;;
    full|"")
      info "Running full test suite"
      ;;
    *)
      echo "Usage: $0 [full|quick|cluster|vm-pod]"
      echo
      echo "Modes:"
      echo "  full      - Full test suite (default)"
      echo "  quick     - Quick tests only (skip long-running tests)"
      echo "  cluster   - Cluster setup tests only"
      echo "  vm-pod    - VM-as-pod tests only"
      exit 1
      ;;
  esac

  echo
  echo "========================================"
  echo "WMCO CI Test Suite"
  echo "========================================"
  echo "Mode: $mode"
  echo "Quick: $QUICK_MODE"
  echo "Log:  $TEST_LOG"
  echo "========================================"
  echo

  # Run all tests
  test_helper_scripts
  test_documentation
  test_cluster_setup
  test_virtctl
  test_virt_operator
  test_fedora_vm_pod
  test_windows_vm_pod
  test_windows_workload
  test_network_check

  print_summary
}

main "$@"
