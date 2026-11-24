#!/usr/bin/env bash
#
# spawn-vm-pod.sh - Create VMs running as pods using OpenShift Virtualization
#
# Usage:
#   ./spawn-vm-pod.sh              Create Fedora VM and documentation
#   ./spawn-vm-pod.sh windows      Create Windows VM (uses virtctl image-upload)
#   ./spawn-vm-pod.sh run-workload [vm-name] [namespace]
#                                  Show workload test instructions
#
# Examples:
#   ./spawn-vm-pod.sh                    # Fedora VM (quick proof of concept)
#   ./spawn-vm-pod.sh windows            # Windows VM (requires ISO upload)
#   ./spawn-vm-pod.sh run-workload       # Show workload instructions
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source setup.sh to get all the helper functions and variables
export _SOURCING=1
source "$SCRIPT_DIR/setup.sh"
unset _SOURCING

# Configuration for VM pod
VIRT_NS="${VIRT_NS:-openshift-cnv}"
VIRT_TEST_NS="${VIRT_TEST_NS:-virt-windows}"
VIRT_VM_NAME="${VIRT_VM_NAME:-windows-pod-vm}"
VIRT_VM_MEMORY="${VIRT_VM_MEMORY:-8Gi}"      # 8GB for Windows Server VM
VIRT_VM_CPUS="${VIRT_VM_CPUS:-4}"            # 4 CPUs for better performance
VIRT_VM_DISK_SIZE="${VIRT_VM_DISK_SIZE:-60Gi}" # 60GB for Windows Server installation

# ----------------------------------------------------------------------------
# Install virtctl if needed
# ----------------------------------------------------------------------------
ensure_virtctl() {
  if command -v virtctl >/dev/null 2>&1; then
    ok "virtctl already installed: $(virtctl version --client 2>&1 | grep GitVersion | cut -d: -f2 | cut -d, -f1)"
    return
  fi

  info "Installing virtctl CLI"

  # Get it from OpenShift Virtualization console download
  local virtctl_url
  virtctl_url=$(oc get ConsoleCLIDownload -o jsonpath='{.items[?(@.metadata.name=="virtctl-clidownloads-kubevirt-hyperconverged")].spec.links[0].href}' 2>/dev/null || true)

  if [[ -z "$virtctl_url" ]]; then
    warn "virtctl download not available from cluster"
    hint "OpenShift Virtualization operator should provide virtctl via ConsoleCLIDownload"
    hint "Manual install: curl -L <cluster-url>/amd64/linux/virtctl.tar.gz | tar xz -C ~/.local/bin"
    return 1
  fi

  info "Downloading virtctl from cluster: $virtctl_url"
  mkdir -p "$HOME/.local/bin"
  if curl -kL "$virtctl_url" 2>/dev/null | tar xzf - -C "$HOME/.local/bin" 2>/dev/null; then
    chmod +x "$HOME/.local/bin/virtctl"
    export PATH="$HOME/.local/bin:$PATH"
    ok "virtctl installed to $HOME/.local/bin/virtctl"
  else
    warn "Could not download virtctl from cluster"
    hint "Check: oc get ConsoleCLIDownload"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Check nested virtualization
# ----------------------------------------------------------------------------
check_nested_virt() {
  echo
  echo "${C_B}${C_C}Checking nested virtualization${C_0}"

  if [[ ! -e /dev/kvm ]]; then
    die "/dev/kvm not available - hardware virtualization required"
  fi

  local nested=0 cpu_vendor=""
  if grep -q GenuineIntel /proc/cpuinfo; then
    cpu_vendor="intel"
    nested=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo "N")
    [[ "$nested" == "Y" || "$nested" == "1" ]] && nested=1 || nested=0
  elif grep -q AuthenticAMD /proc/cpuinfo; then
    cpu_vendor="amd"
    nested=$(cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || echo "0")
    [[ "$nested" == "1" ]] && nested=1 || nested=0
  fi

  if (( nested )); then
    ok "Nested virtualization enabled ($cpu_vendor)"
  else
    warn "Nested virtualization may not be enabled"
    if [[ "$cpu_vendor" == "intel" ]]; then
      hint "Enable: echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm-intel.conf"
      hint "Reload: sudo modprobe -r kvm_intel && sudo modprobe kvm_intel"
    elif [[ "$cpu_vendor" == "amd" ]]; then
      hint "Enable: echo 'options kvm_amd nested=1' | sudo tee /etc/modprobe.d/kvm-amd.conf"
      hint "Reload: sudo modprobe -r kvm_amd && sudo modprobe kvm_amd"
    fi
  fi
}

# ----------------------------------------------------------------------------
# Install OpenShift Virtualization
# ----------------------------------------------------------------------------
ensure_virt_operator() {
  echo
  echo "${C_B}${C_C}OpenShift Virtualization operator${C_0}"

  # Check if already installed
  local already_installed=0
  if oc get csv -n "$VIRT_NS" 2>/dev/null | grep -q kubevirt-hyperconverged-operator; then
    local csv
    csv=$(oc get csv -n "$VIRT_NS" 2>/dev/null | grep kubevirt-hyperconverged | awk '{print $1}')
    ok "Operator already installed: $csv"
    already_installed=1
  fi

  if (( ! already_installed )); then
    # Install operator
    info "Creating namespace $VIRT_NS"
    oc create namespace "$VIRT_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1

    # Create OperatorGroup
    oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: $VIRT_NS
spec:
  targetNamespaces:
  - $VIRT_NS
EOF

    # Wait for marketplace catalog sources to be ready
    info "Waiting for OperatorHub marketplace..."
    local timeout=600  # 10 minutes for fresh cluster
    local elapsed=0

    # First, wait for catalog source pods to be Running
    while (( elapsed < timeout )); do
      local ready_count
      ready_count=$(oc get pods -n openshift-marketplace -l olm.catalogSource 2>/dev/null | grep -c "1/1.*Running" || true)
      if (( ready_count >= 3 )); then  # At least certified, community, redhat
        break
      fi
      sleep 10
      elapsed=$((elapsed + 10))
      if (( elapsed % 60 == 0 )); then
        info "  Still waiting for catalog source pods ($((elapsed / 60)) min)..."
      fi
    done

    if (( elapsed >= timeout )); then
      die "Timeout waiting for catalog sources. Check: oc get pods -n openshift-marketplace"
    fi

    # Then wait for packagemanifests to populate (can take 10-15 min on fresh cluster)
    elapsed=0
    while (( elapsed < 900 )); do  # 15 minutes for fresh cluster catalog indexing
      local pkg_check
      pkg_check=$(oc get packagemanifest -n openshift-marketplace 2>&1 | grep -i kubevirt || true)
      if [[ -n "$pkg_check" ]]; then
        ok "Package catalog ready"
        break
      fi
      sleep 10
      elapsed=$((elapsed + 10))
      if (( elapsed % 60 == 0 )); then
        info "  Still waiting for package catalogs ($((elapsed / 60)) min)..."
        # Debug: show what we're getting
        local total_pkgs
        total_pkgs=$(oc get packagemanifest -n openshift-marketplace 2>/dev/null | wc -l || echo "0")
        info "    (Found $total_pkgs total packages so far)"
      fi
    done

    if (( elapsed >= 900 )); then
      die "Timeout waiting for kubevirt packages. Check: oc get packagemanifest -n openshift-marketplace"
    fi

    # Find package
    local pkg="" catalog="" channel=""
    for p in kubevirt-hyperconverged community-kubevirt-hyperconverged; do
      if oc get packagemanifest -n openshift-marketplace "$p" >/dev/null 2>&1; then
        pkg="$p"
        catalog=$(oc get packagemanifest -n openshift-marketplace "$p" -o jsonpath='{.status.catalogSource}')
        channel=$(oc get packagemanifest -n openshift-marketplace "$p" -o jsonpath='{.status.defaultChannel}')
        if [[ -n "$catalog" && -n "$channel" ]]; then
          break
        fi
      fi
    done

    [[ -n "$pkg" && -n "$catalog" && -n "$channel" ]] || die "OpenShift Virtualization package not found or incomplete"
    info "Installing $pkg from $catalog (channel: $channel)"

    # Create Subscription
    oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: $VIRT_NS
spec:
  channel: "$channel"
  installPlanApproval: Automatic
  name: $pkg
  source: $catalog
  sourceNamespace: openshift-marketplace
EOF

    # Wait for CSV
    local t0 csv phase_ last_min=-1
    t0=$(date +%s)
    info "Waiting for operator (can take 5-10 min)..."
    while :; do
      csv=$(oc get subscription -n "$VIRT_NS" kubevirt-hyperconverged -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
      if [[ -n "$csv" ]]; then
        phase_=$(oc get csv -n "$VIRT_NS" "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [[ "$phase_" == "Succeeded" ]] && break
      fi
      (( $(date +%s) - t0 > 900 )) && die "Operator install timeout (15 min)"
      local m=$(( ($(date +%s) - t0) / 60 ))
      if (( m != last_min )); then
        info "  ${m} min - phase: ${phase_:-installing}"
        last_min=$m
      fi
      sleep 10
    done
    ok "Operator installed: $csv"
  fi

  # Create HyperConverged CR (runs always, even if operator was already installed)
  if ! oc get hyperconverged -n "$VIRT_NS" kubevirt-hyperconverged >/dev/null 2>&1; then
    info "Creating HyperConverged resource"
    oc apply -f - >/dev/null <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: $VIRT_NS
spec: {}
EOF

    local t0 last_min=-1
    t0=$(date +%s)
    info "Waiting for HyperConverged to be available..."
    while :; do
      local cond
      cond=$(oc get hyperconverged -n "$VIRT_NS" kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
      [[ "$cond" == "True" ]] && break
      (( $(date +%s) - t0 > 900 )) && die "HyperConverged timeout (15 min)"
      local m=$(( ($(date +%s) - t0) / 60 ))
      if (( m != last_min )); then
        info "  ${m} min - waiting for Available=True"
        last_min=$m
      fi
      sleep 15
    done
    ok "OpenShift Virtualization ready"
  else
    ok "HyperConverged resource already exists"
  fi

  # Wait for VirtualMachine CRD to be available
  info "Checking VirtualMachine CRD..."
  local t0 last_min=-1
  t0=$(date +%s)
  while ! oc get crd virtualmachines.kubevirt.io >/dev/null 2>&1; do
    (( $(date +%s) - t0 > 600 )) && die "VirtualMachine CRD not available after 10 min"
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then
      info "  ${m} min - waiting for CRD registration"
      last_min=$m
    fi
    sleep 10
  done
  ok "VirtualMachine CRD available"
}

# ----------------------------------------------------------------------------
# Build config ISO - reuses write_autounattend from setup.sh + adds workload script
# ----------------------------------------------------------------------------
build_simple_config_iso() {
  local output_iso="$1"
  local iso_dir="$WORK_DIR/iso"

  rm -rf "$iso_dir"
  mkdir -p "$iso_dir"

  # Set variables for write_autounattend from setup.sh
  WIN_PASSWORD="${WIN_PASSWORD:-Windows123!}"
  WIN_IMAGE_INDEX="${WIN_IMAGE_INDEX:-2}"
  WIN_HOSTNAME="${WIN_HOSTNAME:-windows-pod-vm}"
  WIN_TIMEZONE="${WIN_TIMEZONE:-UTC}"

  # Reuse write_autounattend from setup.sh (creates $WORK_DIR/iso/autounattend.xml)
  write_autounattend

  # Create workload test script (write_autounattend expects wmco-setup.ps1)
  cat > "$iso_dir/wmco-setup.ps1" <<'PSEOF'
# Windows VM workload test
Start-Transcript -Path C:\workload.log -Append
Write-Host "=== Workload Test Started at $(Get-Date) ==="

Write-Host "`n=== Enabling Emergency Management Services for serial console ==="
Write-Host "Configuring EMS settings (port:1, baud:115200)"
bcdedit /emssettings EMSPORT:1 EMSBAUDRATE:115200
Write-Host "Enabling EMS on current boot entry"
bcdedit /ems on
# Also enable on the default boot entry explicitly
$bootmgr = bcdedit /enum bootmgr | Select-String "identifier" | Select-Object -First 1
if ($bootmgr) {
    Write-Host "Enabling bootdebug for boot manager"
    bcdedit /bootdebug on
}
Write-Host "EMS configuration complete"

Write-Host "`nSystem Information:"
$os = Get-WmiObject Win32_OperatingSystem
Write-Host "  OS: $($os.Caption) Build $($os.BuildNumber)"
Write-Host "  CPU Cores: $((Get-WmiObject Win32_Processor).NumberOfCores)"
Write-Host "  Memory: $([math]::Round($os.TotalVisibleMemorySize / 1MB, 2))GB"

Write-Host "`nNetwork Configuration:"
$adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if ($adapter) {
    Write-Host "  Adapter: $($adapter.Name) ($($adapter.InterfaceDescription))"
    $ip = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($ip) {
        Write-Host "  IP Address: $ip"
        Set-Content -Path C:\ip.txt -Value $ip
    } else {
        Write-Host "  IP Address: Not assigned"
    }

    Write-Host "`nTesting internet connectivity:"
    Write-Host "  Pinging 8.8.8.8..."
    $ping = Test-Connection -ComputerName 8.8.8.8 -Count 4 -ErrorAction SilentlyContinue
    if ($ping) {
        $avgTime = ($ping | Measure-Object -Property ResponseTime -Average).Average
        Write-Host "  SUCCESS: Average response time: $([math]::Round($avgTime, 2))ms"
        Set-Content -Path C:\ping-success.txt -Value "OK"
    } else {
        Write-Host "  FAILED: Cannot reach 8.8.8.8"
    }
} else {
    Write-Host "  No active network adapter found"
}

Write-Host "`nRunning CPU stress test for 60 seconds..."
1..60 | ForEach-Object {
    $percent = [int](($_ / 60) * 100)
    Write-Progress -Activity "CPU Stress Test" -Status "$percent% Complete" -PercentComplete $percent
    Start-Sleep -Seconds 1
    # Simple CPU work
    1..1000 | ForEach-Object { [math]::Sqrt($_) } | Out-Null
}

Write-Host "`n=== Workload Test Completed at $(Get-Date) ==="
Set-Content -Path C:\workload.done -Value (Get-Date -Format o)
Stop-Transcript
PSEOF

  # Create ISO - EXACT same method as setup.sh (line 544-549)
  local tmp_iso="$WORK_DIR/autounattend.iso"
  if command -v xorriso >/dev/null; then
    xorriso -as mkisofs -quiet -J -r -V WMCOCFG -o "$tmp_iso" "$iso_dir"
  else
    "$(command -v genisoimage || command -v mkisofs)" -quiet -J -r -V WMCOCFG -o "$tmp_iso" "$iso_dir"
  fi
  mv "$tmp_iso" "$output_iso"

  ok "Built config ISO (reusing setup.sh autounattend.xml + workload test)"
}

# ----------------------------------------------------------------------------
# Create Windows VM as a pod
# ----------------------------------------------------------------------------
create_fedora_vm_pod() {
  echo
  echo "${C_B}${C_C}Creating Fedora VM as a pod (proof of concept)${C_0}"

  # Create namespace
  oc create namespace "$VIRT_TEST_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1
  ok "Namespace: $VIRT_TEST_NS"

  # Create a simple Fedora VM using containerDisk (no ISO import needed)
  info "Creating VirtualMachine with Fedora containerDisk"
  oc apply -f - >/dev/null <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora-vm
  namespace: $VIRT_TEST_NS
  labels:
    app: fedora-vm
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: fedora-vm
    spec:
      domain:
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
          interfaces:
          - name: default
            masquerade: {}
        resources:
          requests:
            memory: 2Gi
            cpu: 2
      networks:
      - name: default
        pod: {}
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/containerdisks/fedora:latest
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            password: fedora
            chpasswd: { expire: False }
            ssh_pwauth: True
            runcmd:
              - echo "=== VM Workload Test Started at \$(date) ===" | tee /var/log/workload.log
              - echo "CPU Cores: \$(nproc)" | tee -a /var/log/workload.log
              - echo "Memory: \$(free -h | grep Mem | awk '{print \$2}')" | tee -a /var/log/workload.log
              - echo "Running CPU stress test for 60 seconds..." | tee -a /var/log/workload.log
              - dnf install -y stress &>/dev/null || yum install -y stress &>/dev/null
              - stress --cpu 2 --timeout 60s
              - echo "=== VM Workload Test Completed at \$(date) ===" | tee -a /var/log/workload.log
              - echo "Workload test successful" > /var/log/workload.done
EOF

  ok "VirtualMachine 'fedora-vm' created"

  # Wait for it to start
  wait_for_vm_running "fedora-vm" "$VIRT_TEST_NS" 10
}

upload_iso_with_virtctl() {
  local pvc_name="$1"
  local iso_path="$2"
  local size="$3"
  local namespace="$4"

  if oc get pvc "$pvc_name" -n "$namespace" >/dev/null 2>&1; then
    ok "PVC $pvc_name already exists"
    local phase
    phase=$(oc get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.status.phase}')
    if [[ "$phase" == "Bound" ]]; then
      ok "PVC is Bound and ready"
      return 0
    fi
  fi

  info "Uploading $(basename "$iso_path") to PVC $pvc_name ($size)"
  info "This will take several minutes for large ISOs..."

  # Upload using virtctl
  if virtctl image-upload pvc "$pvc_name" \
    --namespace="$namespace" \
    --image-path="$iso_path" \
    --size="$size" \
    --insecure \
    --force-bind 2>&1 | grep -v "^$"; then
    ok "Upload completed: $pvc_name"
    return 0
  else
    warn "Upload may have failed or is still in progress"
    hint "Check: oc get pvc $pvc_name -n $namespace"
    return 1
  fi
}

create_windows_vm_pod() {
  echo
  echo "${C_B}${C_C}Creating Windows VM as a pod${C_0}"

  # Ensure we have the Windows ISO
  if [[ ! -f "$WIN_ISO" ]]; then
    die "Windows ISO not found at $WIN_ISO. Run ./setup.sh first to download it."
  fi
  ok "Windows ISO: $WIN_ISO"

  # Create namespace
  oc create namespace "$VIRT_TEST_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1
  ok "Namespace: $VIRT_TEST_NS"

  # Build autounattend config ISO
  local vm_config_iso="$WORK_DIR/vm-pod-autounattend.iso"
  if [[ ! -f "$vm_config_iso" ]]; then
    info "Building autounattend config ISO"
    build_simple_config_iso "$vm_config_iso"
  fi
  ok "Config ISO: $vm_config_iso"

  # Upload ISOs using virtctl image-upload
  echo
  info "Uploading Windows ISO to cluster storage..."
  info "This requires CDI (Container Data Importer) which is part of OpenShift Virtualization"
  echo

  upload_iso_with_virtctl "windows-iso" "$WIN_ISO" "10Gi" "$VIRT_TEST_NS" || {
    warn "Windows ISO upload failed or incomplete"
    hint "You can retry by running: ./spawn-vm-pod.sh windows"
    return 1
  }

  upload_iso_with_virtctl "windows-config" "$vm_config_iso" "100Mi" "$VIRT_TEST_NS" || {
    warn "Config ISO upload failed or incomplete"
    return 1
  }

  # Create blank disk for Windows installation
  info "Creating blank disk PVC for Windows installation"
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${VIRT_VM_NAME}-disk
  namespace: $VIRT_TEST_NS
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: $VIRT_VM_DISK_SIZE
EOF
  ok "Created blank disk PVC: ${VIRT_VM_NAME}-disk"

  # Create Windows VM
  info "Creating Windows VirtualMachine"
  oc apply -f - >/dev/null <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: $VIRT_VM_NAME
  namespace: $VIRT_TEST_NS
  labels:
    app: $VIRT_VM_NAME
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/vm: $VIRT_VM_NAME
    spec:
      domain:
        cpu:
          cores: $VIRT_VM_CPUS
        devices:
          disks:
          # IMPORTANT: Must use SATA bus for Windows (SCSI doesn't work - autounattend.xml not found)
          - disk:
              bus: sata
            name: windows-disk
            bootOrder: 1
          - cdrom:
              bus: sata
              readonly: true
            name: windows-iso
            bootOrder: 2
          - cdrom:
              bus: sata
              readonly: true
            name: config-iso
            bootOrder: 3
          interfaces:
          - name: default
            masquerade: {}
            model: e1000e  # Use e1000e instead of virtio-net (Windows has native drivers)
          # Serial console for virtctl console access
          autoattachSerialConsole: true
        firmware:
          bootloader:
            bios: {}
        features:
          acpi: {}
          apic: {}
          hyperv:
            relaxed: {}
            vapic: {}
            spinlocks:
              spinlocks: 8191
        clock:
          utc: {}
          timer:
            hyperv: {}
        resources:
          requests:
            memory: $VIRT_VM_MEMORY
      networks:
      - name: default
        pod: {}
      volumes:
      - name: windows-disk
        persistentVolumeClaim:
          claimName: ${VIRT_VM_NAME}-disk
      - name: windows-iso
        persistentVolumeClaim:
          claimName: windows-iso
      - name: config-iso
        persistentVolumeClaim:
          claimName: windows-config
EOF

  ok "VirtualMachine '$VIRT_VM_NAME' created"

  # Wait for it to start
  wait_for_vm_running "$VIRT_VM_NAME"
}

create_datavolume_from_http() {
  local dv_name="$1"
  local http_url="$2"
  local size="$3"

  if oc get pvc "$dv_name" -n "$VIRT_TEST_NS" >/dev/null 2>&1; then
    ok "PVC $dv_name already exists"
    return
  fi

  info "Creating DataVolume to import from $http_url"
  oc apply -f - >/dev/null <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: $dv_name
  namespace: $VIRT_TEST_NS
spec:
  source:
    http:
      url: "$http_url"
  storage:
    resources:
      requests:
        storage: $size
EOF

  # Wait for import to complete
  local t0 last_min=-1
  t0=$(date +%s)
  info "Waiting for import to complete (this may take several minutes)..."
  while :; do
    local phase
    phase=$(oc get dv "$dv_name" -n "$VIRT_TEST_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$phase" == "Succeeded" ]] && break

    if [[ "$phase" == "Failed" ]]; then
      oc get dv "$dv_name" -n "$VIRT_TEST_NS" -o yaml | grep -A 5 "conditions:" >&2
      die "DataVolume import failed"
    fi

    (( $(date +%s) - t0 > 1200 )) && die "DataVolume import timeout (20 min)"
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then
      local progress
      progress=$(oc get dv "$dv_name" -n "$VIRT_TEST_NS" -o jsonpath='{.status.progress}' 2>/dev/null || echo "0%")
      info "  ${m} min - phase: ${phase:-Pending}, progress: ${progress}"
      last_min=$m
    fi
    sleep 15
  done

  ok "DataVolume $dv_name imported successfully"
}

start_http_server() {
  local http_port=8088

  # Check if server already running
  if curl -s -m 2 "http://localhost:$http_port/" >/dev/null 2>&1; then
    ok "HTTP server already running on port $http_port" >&2
    echo "$http_port"
    return
  fi

  info "Starting HTTP server from $WORK_DIR on port $http_port" >&2
  cd "$WORK_DIR"
  python3 -m http.server $http_port >/dev/null 2>&1 &
  local server_pid=$!

  # Save PID for cleanup
  echo "$server_pid" > "$WORK_DIR/http-server.pid"

  # Wait for server to start
  sleep 2
  if ! curl -s -m 2 "http://localhost:$http_port/" >/dev/null 2>&1; then
    die "Failed to start HTTP server"
  fi

  ok "HTTP server started from $WORK_DIR (PID: $server_pid)" >&2
  echo "$http_port"
}

wait_for_vm_running() {
  local vm_name="${1:-$VIRT_VM_NAME}"
  local namespace="${2:-$VIRT_TEST_NS}"
  local timeout_min="${3:-10}"

  local t0 last_min=-1
  t0=$(date +%s)
  info "Waiting for VirtualMachineInstance $vm_name..."
  while :; do
    local phase_
    phase_=$(oc get vmi -n "$namespace" "$vm_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase_" == "Running" ]]; then
      ok "VirtualMachineInstance is Running"
      local pod
      pod=$(oc get pod -n "$namespace" -l kubevirt.io/vm="$vm_name" -o name 2>/dev/null | head -1)
      [[ -n "$pod" ]] && ok "Pod: ${pod#*/}"
      return 0
    fi
    (( $(date +%s) - t0 > timeout_min * 60 )) && {
      warn "VM not running after $timeout_min min - check: oc get vmi,pod -n $namespace"
      return 1
    }
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then
      info "  ${m} min - phase: ${phase_:-Pending}"
      last_min=$m
    fi
    sleep 10
  done
}

show_fedora_summary() {
  echo
  echo "${C_B}${C_G}Fedora VM Pod Created Successfully!${C_0}"
  echo
  echo "${C_B}VM Information:${C_0}"
  echo "  Name:       fedora-vm"
  echo "  Namespace:  $VIRT_TEST_NS"
  echo "  Memory:     2Gi"
  echo "  CPUs:       2"
  echo "  Image:      quay.io/containerdisks/fedora:latest"
  echo
  echo "${C_B}Access:${C_0}"
  echo "  Console:    virtctl console fedora-vm -n $VIRT_TEST_NS"
  echo "  VNC:        virtctl vnc fedora-vm -n $VIRT_TEST_NS"
  echo "  Login:      fedora / fedora"
  echo
  echo "${C_B}Check workload:${C_0}"
  echo "  # Connect to console and check:"
  echo "  cat /var/log/workload.log"
  echo "  cat /var/log/workload.done"
  echo
  echo "${C_B}Status:${C_0}"
  echo "  VMs:        oc get vm,vmi -n $VIRT_TEST_NS -o wide"
  echo "  Pods:       oc get pods -n $VIRT_TEST_NS"
  echo "  Logs:       oc logs -n $VIRT_TEST_NS \$(oc get pod -n $VIRT_TEST_NS -l kubevirt.io/vm=fedora-vm -o name)"
  echo
  echo "${C_B}Delete:${C_0}"
  echo "  oc delete vm fedora-vm -n $VIRT_TEST_NS"
  echo "  oc delete ns $VIRT_TEST_NS  # removes everything"
  echo
  echo "${C_Y}${C_B}Documentation:${C_0}"
  echo "  VM Operations: $WORK_DIR/VM-OPERATIONS-GUIDE.md"
  echo "  Windows VMs:   $WORK_DIR/WINDOWS-VM-GUIDE.md"
}

show_windows_summary() {
  echo
  echo "${C_B}${C_G}Windows VM Pod Created!${C_0}"
  echo
  echo "${C_B}VM Information:${C_0}"
  echo "  Name:       $VIRT_VM_NAME"
  echo "  Namespace:  $VIRT_TEST_NS"
  echo "  Memory:     $VIRT_VM_MEMORY"
  echo "  CPUs:       $VIRT_VM_CPUS"
  echo
  echo "${C_B}${C_Y}IMPORTANT: Windows Installation in Progress${C_0}"
  echo "  Installation takes 15-20 minutes"
  echo "  ${C_B}Use VNC to monitor installation progress:${C_0}"
  echo "    virtctl vnc $VIRT_VM_NAME -n $VIRT_TEST_NS"
  echo
  echo "${C_B}Access:${C_0}"
  echo "  VNC (graphical):  virtctl vnc $VIRT_VM_NAME -n $VIRT_TEST_NS"
  echo "  Console (text):   virtctl console $VIRT_VM_NAME -n $VIRT_TEST_NS"
  echo "    ${C_Y}Note: Serial console only works AFTER Windows installation completes${C_0}"
  echo
  echo "${C_B}Wait for Installation:${C_0}"
  echo "  ./spawn-vm-pod.sh wait-install  # Monitor installation progress"
  echo "  ./spawn-vm-pod.sh verify-windows # Verify after installation"
  echo
  echo "${C_B}Status:${C_0}"
  echo "  VMs:        oc get vm,vmi -n $VIRT_TEST_NS -o wide"
  echo "  Pods:       oc get pods -n $VIRT_TEST_NS"
  echo "  Events:     oc get events -n $VIRT_TEST_NS --sort-by=.lastTimestamp"
  echo
  echo "${C_B}Delete:${C_0}"
  echo "  oc delete vm $VIRT_VM_NAME -n $VIRT_TEST_NS"
  echo "  oc delete ns $VIRT_TEST_NS  # removes everything"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
create_windows_docs() {
  mkdir -p "$WORK_DIR"
  local doc="$WORK_DIR/WINDOWS-VM-GUIDE.md"
  cat > "$doc" <<'DOCEOF'
# Windows VM as a Pod - Production Guide

This guide explains how to run Windows VMs as pods in OpenShift Virtualization.

## What Works on CRC (Local Development)

✓ OpenShift Virtualization operator installation
✓ HyperConverged deployment
✓ Fedora/Linux VMs using containerDisk
✓ Basic VM lifecycle (start, stop, console access)

## Challenges with Windows on CRC

CRC (single-node local cluster) has limitations:

1. **Storage**: The crc-csi-hostpath-provisioner uses WaitForFirstConsumer binding
   - Blocks DataVolume HTTP imports (needs pre-bound PVC)
   - HostPath volumes can't access host files (CRC VM is isolated)

2. **Resources**: Windows needs significant resources
   - 8GB RAM for Windows VM
   - 6-8GB for OpenShift Virtualization control plane
   - CRC needs 32GB+ total allocation

3. **ISO Import**: CDI (Container Data Importer) import stuck on local storage

## Windows VM on Production Clusters

### Prerequisites

- OpenShift cluster with OpenShift Virtualization installed
- Storage class that supports dynamic provisioning (e.g., `ocs-storagecluster-ceph-rbd`)
- Windows Server ISO file or qcow2 image
- At least 16GB RAM and 4 CPUs available for the VM

### Method 1: Using virtctl image-upload

```bash
# Upload Windows ISO to a PVC
virtctl image-upload pvc windows-iso \
  --namespace=virt-windows \
  --image-path=/path/to/windows-server-2025.iso \
  --size=10Gi \
  --insecure

# Upload autounattend config ISO
virtctl image-upload pvc windows-config \
  --namespace=virt-windows \
  --image-path=/path/to/autounattend.iso \
  --size=100Mi \
  --insecure
```

### Method 2: Using DataVolume with HTTP Source

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: windows-iso
  namespace: virt-windows
spec:
  source:
    http:
      url: "https://your-server.com/windows-server-2025.iso"
  storage:
    resources:
      requests:
        storage: 10Gi
```

### Method 3: Pre-built Windows Image

Best for production - create a qcow2 image with Windows pre-installed:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: windows-disk
  namespace: virt-windows
spec:
  source:
    registry:
      url: "docker://quay.io/your-org/windows-server-2025:latest"
  storage:
    resources:
      requests:
        storage: 60Gi
```

### Windows VM Manifest

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: windows-vm
  namespace: virt-windows
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/vm: windows-vm
    spec:
      domain:
        cpu:
          cores: 4
        devices:
          disks:
          - disk:
              bus: sata
            name: windows-disk
          - cdrom:
              bus: sata
              readonly: true
            bootOrder: 1
            name: windows-iso
          - cdrom:
              bus: sata
              readonly: true
            bootOrder: 2
            name: config-iso
          interfaces:
          - name: default
            masquerade: {}
        features:
          acpi: {}
          apic: {}
          hyperv:
            relaxed: {}
            vapic: {}
            spinlocks:
              spinlocks: 8191
            vpindex: {}
            runtime: {}
            synic: {}
            synictimer:
              direct: {}
        clock:
          utc: {}
          timer:
            hyperv: {}
        resources:
          requests:
            memory: 8Gi
      networks:
      - name: default
        pod: {}
      volumes:
      - name: windows-disk
        persistentVolumeClaim:
          claimName: windows-disk-pvc
      - name: windows-iso
        persistentVolumeClaim:
          claimName: windows-iso
      - name: config-iso
        persistentVolumeClaim:
          claimName: windows-config
```

## Autounattend.xml for Unattended Install

The autounattend.xml created by this script includes:
- Automatic Windows installation
- Administrator password configuration
- Network configuration
- First-boot workload execution

Located at: `$WORK_DIR/vm-pod-iso/autounattend.xml`

## Workload Testing

The workload test script runs at first boot:
- CPU stress test (60 seconds)
- System information logging
- Results in `C:\workload.log`

Located at: `$WORK_DIR/vm-pod-iso/workload.ps1`

## Recommended Storage Classes by Platform

- **AWS**: `gp3-csi`, `gp2`
- **Azure**: `managed-premium`
- **VMware**: `thin-csi`
- **OpenShift Data Foundation**: `ocs-storagecluster-ceph-rbd`
- **Local/Bare Metal**: `hostpath-provisioner` (requires manual PV creation)

## Accessing Windows VM

```bash
# VNC console
virtctl vnc windows-vm -n virt-windows

# Serial console (if configured)
virtctl console windows-vm -n virt-windows

# RDP (if service exposed)
oc get svc -n virt-windows
```

## Troubleshooting

```bash
# Check VM status
oc get vm,vmi -n virt-windows -o wide

# Check launcher pod
oc get pods -n virt-windows -l kubevirt.io/vm=windows-vm

# View events
oc get events -n virt-windows --sort-by=.lastTimestamp

# Check DataVolume import progress
oc get dv -n virt-windows
oc describe dv windows-iso -n virt-windows

# Logs from launcher pod
oc logs -n virt-windows <launcher-pod-name> -c compute
```

## References

- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about_virt/about-virt.html)
- [KubeVirt User Guide](https://kubevirt.io/user-guide/)
- [CDI (Containerized Data Importer)](https://github.com/kubevirt/containerized-data-importer)
- [virtctl CLI Reference](https://kubevirt.io/user-guide/operations/virtctl_client_tool/)
DOCEOF

  ok "Created Windows VM guide: $doc"

  # Create VM operations guide
  local ops_doc="$WORK_DIR/VM-OPERATIONS-GUIDE.md"
  if [[ ! -f "$ops_doc" ]]; then
    # VM operations guide would be created here if not exists
    # For now, it's created separately
    info "VM operations guide: $ops_doc"
  fi
}

run_workload() {
  local vm_name="${1:-fedora-vm}"
  local namespace="${2:-virt-windows}"

  echo "${C_B}VM Workload Test Helper${C_0}"
  echo

  # Check if VM exists and is running
  if ! oc get vmi "$vm_name" -n "$namespace" >/dev/null 2>&1; then
    die "VM $vm_name not found or not running in namespace $namespace"
  fi

  local vm_ip status
  vm_ip=$(oc get vmi "$vm_name" -n "$namespace" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null)
  status=$(oc get vmi "$vm_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)

  ok "VM: $vm_name"
  ok "Status: $status"
  ok "IP: $vm_ip"
  echo

  echo "${C_B}Step 1: Connect to VM Console${C_0}"
  echo "  virtctl console $vm_name -n $namespace"
  echo

  echo "${C_B}Step 2: Login${C_0}"
  echo "  Username: fedora"
  echo "  Password: fedora"
  echo

  echo "${C_B}Step 3: Install stress tool${C_0}"
  echo "  sudo dnf install -y stress"
  echo

  echo "${C_B}Step 4: Run CPU workload test${C_0}"
  echo "  echo \"=== Workload Started at \$(date) ===\" | tee /tmp/workload.log"
  echo "  stress --cpu \$(nproc) --timeout 60s"
  echo "  echo \"=== Workload Completed at \$(date) ===\" | tee -a /tmp/workload.log"
  echo "  echo \"DONE\" > /tmp/workload.done"
  echo

  echo "${C_B}Step 5: View results${C_0}"
  echo "  cat /tmp/workload.log"
  echo "  cat /tmp/workload.done"
  echo

  echo "${C_B}Step 6: Exit console${C_0}"
  echo "  Press: Ctrl+]  (or Ctrl+5)"
  echo

  # Create a quick reference script
  local script="$WORK_DIR/run-vm-workload.sh"
  cat > "$script" <<'SCRIPTEOF'
#!/bin/bash
# Quick workload test for Fedora VM
# This prints the commands - you still need to run them manually in the VM console

VM_NAME="${1:-fedora-vm}"
NAMESPACE="${2:-virt-windows}"

echo "=== VM Workload Test Commands ==="
echo
echo "# 1. Connect to console:"
echo "virtctl console $VM_NAME -n $NAMESPACE"
echo
echo "# 2. Inside VM, run these commands:"
echo "sudo dnf install -y stress"
echo "echo '=== Workload Started at '\$(date)' ===' | tee /tmp/workload.log"
echo "echo 'CPU Cores: '\$(nproc) | tee -a /tmp/workload.log"
echo "echo 'Memory: '\$(free -h | grep Mem | awk '{print \$2}') | tee -a /tmp/workload.log"
echo "stress --cpu \$(nproc) --timeout 60s"
echo "echo '=== Workload Completed at '\$(date)' ===' | tee -a /tmp/workload.log"
echo "echo 'DONE' > /tmp/workload.done"
echo "cat /tmp/workload.log"
echo
echo "# 3. Exit console: Ctrl+]"
SCRIPTEOF
  chmod +x "$script"

  ok "Helper script created: $script"
  echo
  echo "${C_Y}${C_B}Ready to run workload!${C_0}"
  echo "Execute the commands above, or run:"
  echo "  $script"
}

wait_for_installation() {
  local vm_name="${1:-windows-pod-vm}"
  local namespace="${2:-virt-windows}"
  local timeout_min="${3:-30}"

  echo
  echo "${C_B}${C_C}Monitoring Windows Installation${C_0}"
  echo
  echo "VM: $vm_name"
  echo "Namespace: $namespace"
  echo "Timeout: $timeout_min minutes"
  echo
  echo "${C_Y}Installation monitoring via serial console bootloader messages${C_0}"
  echo "${C_Y}For graphical view, use: virtctl vnc $vm_name -n $namespace${C_0}"
  echo
  echo "Waiting for installation to complete..."
  echo "This typically takes 15-20 minutes"
  echo

  local start_time elapsed_min
  start_time=$(date +%s)

  while true; do
    # Calculate elapsed time
    elapsed_min=$(( ($(date +%s) - start_time) / 60 ))

    # Check timeout
    if [[ $elapsed_min -ge $timeout_min ]]; then
      warn "Installation monitoring timeout ($timeout_min minutes)"
      echo
      echo "To continue monitoring:"
      echo "  VNC:     virtctl vnc $vm_name -n $namespace"
      echo "  Console: virtctl console $vm_name -n $namespace"
      return 1
    fi

    # Try to check if Windows has booted (VM has IP and responds to ping)
    local vm_ip
    vm_ip=$(oc get vmi "$vm_name" -n "$namespace" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")

    if [[ -n "$vm_ip" && "$vm_ip" != "null" ]]; then
      info "VM has IP: $vm_ip (elapsed: $elapsed_min min)"

      # Check if pod exists (indicates install may be progressing)
      local pod_phase
      pod_phase=$(oc get pod -n "$namespace" -l kubevirt.io/vm="$vm_name" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

      if [[ "$pod_phase" == "Running" ]]; then
        ok "Installation appears to be progressing (elapsed: $elapsed_min min)"
        echo
        echo "${C_Y}To view installation progress:${C_0}"
        echo "  virtctl vnc $vm_name -n $namespace"
        echo
        echo "${C_Y}After installation completes, verify with:${C_0}"
        echo "  ./spawn-vm-pod.sh verify-windows"
        echo
        echo "Continuing to monitor for completion markers..."
      fi
    else
      info "Waiting for VM networking... (elapsed: $elapsed_min min)"
    fi

    # Sleep before next check
    sleep 60
  done
}

verify_windows_workload() {
  local vm_name="${1:-windows-pod-vm}"
  local namespace="${2:-virt-windows}"

  echo
  echo "${C_B}${C_C}Verifying Windows VM Workload${C_0}"
  echo

  # Check if VM exists
  if ! oc get vmi "$vm_name" -n "$namespace" >/dev/null 2>&1; then
    die "VM '$vm_name' not found in namespace '$namespace'"
  fi

  # Get VM phase
  local phase
  phase=$(oc get vmi "$vm_name" -n "$namespace" -o jsonpath='{.status.phase}')
  echo "${C_B}VM Status:${C_0}"
  echo "  Phase: $phase"

  if [[ "$phase" != "Running" ]]; then
    warn "VM is not running (phase: $phase)"
    echo "Start the VM with: virtctl start $vm_name -n $namespace"
    return 1
  fi

  # Get VM network info
  local vm_ip vm_mac
  vm_ip=$(oc get vmi "$vm_name" -n "$namespace" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "N/A")
  vm_mac=$(oc get vmi "$vm_name" -n "$namespace" -o jsonpath='{.status.interfaces[0].mac}' 2>/dev/null || echo "N/A")
  echo "  IP:    $vm_ip"
  echo "  MAC:   $vm_mac"
  echo

  # Get launcher pod
  local pod
  pod=$(oc get pod -n "$namespace" -l kubevirt.io/vm="$vm_name" -o name 2>/dev/null | head -1)
  if [[ -z "$pod" ]]; then
    warn "Launcher pod not found"
    return 1
  fi
  echo "${C_B}Launcher Pod:${C_0} ${pod#*/}"
  echo

  # Verify workload completion by checking for marker files
  echo "${C_B}Checking workload completion...${C_0}"
  echo "Note: This requires the VM to have completed the workload test"
  echo

  info "To verify via console:"
  echo
  echo "${C_B}1. Connect to Windows via VNC (graphical):${C_0}"
  echo "   virtctl vnc $vm_name -n $namespace"
  echo
  echo "${C_B}2. OR connect via serial console (text, after installation):${C_0}"
  echo "   virtctl console $vm_name -n $namespace"
  echo "   ${C_Y}Note: Serial console only works after Windows boots${C_0}"
  echo
  echo "${C_B}3. Run these commands in Windows PowerShell:${C_0}"
  echo "   ipconfig | findstr /C:\"IPv4\""
  echo "   type C:\\ip.txt"
  echo "   type C:\\ping-success.txt"
  echo "   type C:\\workload.done"
  echo "   type C:\\workload.log"
  echo
  echo "   Exit console: Ctrl+] or Ctrl+5"
  echo

  echo "${C_B}Expected Results:${C_0}"
  echo "  ✓ C:\\ip.txt          - Contains VM IP address"
  echo "  ✓ C:\\ping-success.txt - Contains 'OK' if internet works"
  echo "  ✓ C:\\workload.done    - Exists when test completes"
  echo "  ✓ C:\\workload.log     - Full workload test output"
  echo

  ok "Verification instructions displayed"
}

cleanup_vms() {
  echo
  echo "${C_B}${C_Y}Cleaning up VMs and resources${C_0}"
  echo

  ensure_oc_login

  # Delete VMs
  if oc get vm -n virt-windows >/dev/null 2>&1; then
    echo "${C_B}Deleting VMs:${C_0}"
    oc get vm -n virt-windows -o name 2>/dev/null | while read vm; do
      echo "  - $vm"
      oc delete "$vm" -n virt-windows --ignore-not-found=true
    done
    sleep 3
  fi

  # Delete PVCs
  if oc get pvc -n virt-windows >/dev/null 2>&1; then
    echo "${C_B}Deleting PVCs:${C_0}"
    oc get pvc -n virt-windows -o name 2>/dev/null | while read pvc; do
      echo "  - $pvc"
      oc delete "$pvc" -n virt-windows --ignore-not-found=true
    done
    sleep 3
  fi

  # Delete DataVolumes
  if oc get dv -n virt-windows >/dev/null 2>&1; then
    echo "${C_B}Deleting DataVolumes:${C_0}"
    oc get dv -n virt-windows -o name 2>/dev/null | while read dv; do
      echo "  - $dv"
      oc delete "$dv" -n virt-windows --ignore-not-found=true
    done
    sleep 3
  fi

  # Optionally delete namespace
  if [[ "${1:-}" == "--all" ]]; then
    echo "${C_B}Deleting namespace: virt-windows${C_0}"
    oc delete namespace virt-windows --ignore-not-found=true
  fi

  ok "Cleanup complete"
  echo
  echo "To delete the entire namespace: $0 cleanup --all"
}

main() {
  local command="${1:-}"

  case "$command" in
    cleanup)
      shift
      cleanup_vms "$@"
      ;;
    wait-install)
      shift
      ensure_oc_login
      ensure_virtctl
      wait_for_installation "$@"
      ;;
    verify-windows)
      shift
      ensure_oc_login
      ensure_virtctl
      verify_windows_workload "$@"
      ;;
    run-workload)
      shift
      ensure_oc_login
      ensure_virtctl
      run_workload "$@"
      ;;
    windows)
      echo "${C_B}OpenShift Virtualization - Windows VM as a Pod${C_0}"
      ensure_oc_login
      ensure_virtctl
      check_nested_virt
      ensure_virt_operator
      create_windows_vm_pod
      create_windows_docs
      show_windows_summary
      ;;
    *)
      echo "${C_B}OpenShift Virtualization - VM as a Pod${C_0}"
      ensure_oc_login
      ensure_virtctl
      check_nested_virt
      ensure_virt_operator

      # For CRC: Use Fedora to prove concept
      create_fedora_vm_pod
      create_windows_docs
      show_fedora_summary
      ;;
  esac
}

main "$@"
