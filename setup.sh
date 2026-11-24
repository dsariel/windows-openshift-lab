#!/usr/bin/env bash
#
# setup.sh - Automated Windows Server 2025 + OpenShift WMCO (BYOH) setup
#
#   ./setup.sh           Run the full automated setup
#   ./setup.sh cleanup   Remove the VM and all OpenShift resources (keeps the ISO)
#   ./setup.sh status    Show VM / node / workload status
#   ./setup.sh health        One-shot health check of laptop, OpenShift, Windows and workload
#   ./setup.sh diagnose-windows  Container runtime diagnostics on the Windows node (read-only)
#   ./setup.sh reset-containerd  Move containerd storage aside on the Windows node; images re-download
#   ./setup.sh observe-pod   Print the IIS pod table + new pod events every minute until ready
#   ./setup.sh stop-windows-updates  Stop the Windows Update task on the VM if it is only searching
#   ./setup.sh spawn-vm-pod      Spawn a Windows VM as a pod using OpenShift Virtualization
#
# Every setting below can be overridden from the environment, e.g.:
#   BRIDGE=br0 VM_RAM_MB=16384 ./setup.sh
#
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# crc and the oc it ships (installed by setup-cluster.sh)
export PATH="$HOME/.local/bin:$PATH:$HOME/.crc/bin/oc"

VM_NAME="${VM_NAME:-win2025-wmco}"
WIN_HOSTNAME="${WIN_HOSTNAME:-win2025-wmco}"          # max 15 chars, lowercase -> node name
VM_RAM_MB="${VM_RAM_MB:-8192}"
VM_CPUS="${VM_CPUS:-4}"
VM_DISK_GB="${VM_DISK_GB:-60}"
WIN_PASSWORD="${WIN_PASSWORD:-Windows123!}"
WIN_TIMEZONE="${WIN_TIMEZONE:-UTC}"
WIN_IMAGE_INDEX="${WIN_IMAGE_INDEX:-2}"                # 2 = Standard Evaluation (Desktop Experience)

# Libvirt
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
LIBVIRT_NET="${LIBVIRT_NET:-}"                         # empty = "crc" if it exists (setup-cluster.sh), else "default"
WIN_MAC="${WIN_MAC:-52:54:00:57:4d:43}"                # fixed MAC so the DHCP reservation can be made before boot
WIN_STATIC_HOST="${WIN_STATIC_HOST:-50}"               # last octet reserved for Windows on networks without a DHCP range
BRIDGE="${BRIDGE:-}"                                   # e.g. br0 -> VM on your LAN (recommended for remote clusters)
IMG_DIR="${IMG_DIR:-/var/lib/libvirt/images}"

# Windows ISO (Microsoft Evaluation Center, en-US)
WIN_ISO="${WIN_ISO:-$IMG_DIR/windows-server-2025-eval.iso}"
WIN_ISO_URL="${WIN_ISO_URL:-https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us}"

# Generated files
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/.wmco-work}"
SSH_KEY="${SSH_KEY:-$WORK_DIR/wmco_ssh_key}"           # dedicated, passphrase-less key (WMCO needs one)
VM_DISK="$IMG_DIR/$VM_NAME.qcow2"
CONFIG_ISO="$IMG_DIR/$VM_NAME-autounattend.iso"

# OpenShift / WMCO
WMCO_NS="openshift-windows-machine-config-operator"
WMCO_PACKAGE="${WMCO_PACKAGE:-}"                       # auto-detected if empty
WMCO_CATALOG="${WMCO_CATALOG:-}"                       # auto-detected if empty
WMCO_CHANNEL="${WMCO_CHANNEL:-}"                       # package default channel if empty
HYBRID_OVERLAY_AUTO="${HYBRID_OVERLAY_AUTO:-0}"        # 1 = patch hybrid overlay if missing
HYBRID_CIDR="${HYBRID_CIDR:-10.132.0.0/14}"
HYBRID_HOST_PREFIX="${HYBRID_HOST_PREFIX:-23}"

# Test workload
TEST_NS="${TEST_NS:-wmco-test}"
IIS_IMAGE="${IIS_IMAGE:-mcr.microsoft.com/windows/servercore/iis:windowsservercore-ltsc2025}"
FORCE="${FORCE:-0}"                                    # 1 = skip confirmation prompts (reset-containerd)
WIN_UPDATE="${WIN_UPDATE:-1}"                          # 1 = install Windows updates so the host matches the image build
WU_SEARCH_TIMEOUT_MIN="${WU_SEARCH_TIMEOUT_MIN:-30}"   # abort a hung update *search* (read-only; never download/install)

# Timeouts (minutes)
INSTALL_TIMEOUT_MIN="${INSTALL_TIMEOUT_MIN:-75}"
NODE_TIMEOUT_MIN="${NODE_TIMEOUT_MIN:-40}"
CRC_API_WAIT_MIN="${CRC_API_WAIT_MIN:-10}"
WORKLOAD_TIMEOUT_MIN="${WORKLOAD_TIMEOUT_MIN:-40}"
IIS_HTTP_TIMEOUT_MIN="${IIS_HTTP_TIMEOUT_MIN:-3}"

TOTAL_PHASES=8
START_TS=$(date +%s)

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi

CURRENT_PHASE="init"
phase() { CURRENT_PHASE="$2"; echo; echo "${C_B}${C_C}━━━ Phase $1/$TOTAL_PHASES: $2 ━━━${C_0}  ${3:+($3)}"; }
info()  { echo "  ${C_C}•${C_0} $*"; }
ok()    { echo "  ${C_G}✔${C_0} $*"; }
warn()  { echo "  ${C_Y}⚠${C_0} $*" >&2; }
die()   { echo "  ${C_R}✘ $*${C_0}" >&2; exit 1; }
hint()  { echo "    ${C_Y}hint:${C_0} $*" >&2; }
elapsed() { local s=$(( $(date +%s) - ${1:-$START_TS} )); printf '%dm%02ds' $((s/60)) $((s%60)); }

FAIL_LINE=""
on_exit() {
  local rc=$?
  [[ $rc -eq 0 ]] && return
  echo >&2
  echo "${C_R}${C_B}Setup failed during phase: $CURRENT_PHASE (exit $rc${FAIL_LINE:+, line $FAIL_LINE})${C_0}" >&2
  echo "Troubleshooting:" >&2
  echo "  - Watch the VM console:    virt-viewer -c $LIBVIRT_URI $VM_NAME" >&2
  echo "  - VM state:                virsh -c $LIBVIRT_URI dominfo $VM_NAME" >&2
  if [[ -n "${WIN_IP:-}" ]]; then
    echo "  - Windows setup log:       ssh -i $SSH_KEY Administrator@$WIN_IP type C:\\wmco-setup.log" >&2
  fi
  echo "  - WMCO logs:               oc logs -n $WMCO_NS deploy/windows-machine-config-operator" >&2
  if [[ "$CURRENT_PHASE" == "Windows updates" ]]; then
    echo "  - Windows Update keeps running on the VM. Check/stop it safely: ./setup.sh stop-windows-updates" >&2
  fi
  echo "  - Re-running ./setup.sh is safe; completed steps are skipped." >&2
  echo "  - Start over:              ./setup.sh cleanup && ./setup.sh" >&2
}

# LC_ALL=C: output such as "shut off" is parsed below and must not be translated
virsh_() { LC_ALL=C virsh -q -c "$LIBVIRT_URI" "$@"; }
# Note: never pipe into "grep -q" under pipefail - grep exits on the first match,
# the writer gets SIGPIPE and the pipeline reports failure. Match on captured output.

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
win_ssh() { ssh "${SSH_OPTS[@]}" "Administrator@$WIN_IP" "$@"; }
win_ps()  { win_ssh "powershell -NoProfile -NonInteractive -Command \"$1\""; }

# ----------------------------------------------------------------------------
# Phase 1: Prerequisites
# ----------------------------------------------------------------------------
ensure_libvirt_group() {
  # Already have access (group active, root, or polkit)?
  if [[ $EUID -eq 0 ]] || virsh -q -c "$LIBVIRT_URI" list >/dev/null 2>&1; then return; fi
  command -v virsh >/dev/null || return   # packages get installed in phase 1
  local grp=libvirt
  getent group libvirt >/dev/null || grp=libvirtd
  if ! grep -qx "$grp" <<<"$(id -nG "$USER" | tr ' ' '\n')"; then
    info "Adding $USER to the $grp group (sudo)"
    sudo usermod -aG "$grp" "$USER"
  fi
  if [[ -z "${WMCO_SG_REEXEC:-}" ]]; then
    info "Re-executing with the $grp group active"
    export WMCO_SG_REEXEC=1
    exec sg "$grp" -c "$(printf '%q ' "$0" "$@")"
  fi
  die "Could not activate libvirt group membership. Log out/in and run again."
}

install_packages() {
  local missing=()
  command -v virsh        >/dev/null || missing+=(virsh)
  command -v virt-install >/dev/null || missing+=(virt-install)
  command -v ssh          >/dev/null || missing+=(ssh)
  command -v ssh-keygen   >/dev/null || missing+=(ssh)
  command -v curl         >/dev/null || missing+=(curl)
  command -v xorriso >/dev/null || command -v genisoimage >/dev/null || command -v mkisofs >/dev/null || missing+=(iso)
  command -v qemu-img     >/dev/null || missing+=(qemu)
  [[ ${#missing[@]} -eq 0 ]] && return

  info "Installing missing tools: ${missing[*]}"
  if command -v dnf >/dev/null; then
    sudo dnf install -y libvirt-daemon-kvm libvirt-client qemu-kvm qemu-img virt-install \
      virt-viewer xorriso openssh-clients curl
  elif command -v apt-get >/dev/null; then
    sudo apt-get update -y
    sudo apt-get install -y libvirt-daemon-system libvirt-clients qemu-kvm qemu-utils \
      virtinst virt-viewer xorriso openssh-client curl
  else
    die "Please install: libvirt, qemu-kvm, virt-install, virt-viewer, xorriso, openssh, curl"
  fi
}

# Log in automatically when the cluster is OpenShift Local (crc); tokens from
# 'oc login' expire after ~24h, so a re-run the next day would otherwise fail.
crc_field() {  # value of one field of 'crc status -o json' (empty if unavailable)
  crc status -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1" 2>/dev/null || true
}
crc_status() { crc_field openshiftStatus; }

# Keep the laptop from suspending while we run: a host suspend/resume jumps the
# crc VM's clock, which leaves OpenShift "Unreachable" until 'crc stop && crc start',
# and would also break the Windows install and our timeouts.
inhibit_sleep() {
  [[ -n "${WMCO_INHIBITED:-}" ]] && return
  command -v systemd-inhibit >/dev/null || return
  export WMCO_INHIBITED=1
  local what
  for what in sleep:idle:handle-lid-switch sleep; do
    systemd-inhibit --what="$what" --mode=block true >/dev/null 2>&1 && break
    what=""
  done
  if [[ -z "$what" ]]; then
    echo "  ⚠ Could not block system suspend (no permission). Keep the machine awake while this runs;" >&2
    echo "    after a suspend/resume the crc cluster needs: crc stop && crc start" >&2
    return
  fi
  exec systemd-inhibit --what="$what" --mode=block \
    --who="WMCO setup" --why="Installing Windows node; suspend would break the crc cluster" \
    "$0" "$@"
}

ensure_oc_login() {
  local err
  if err=$(oc whoami 2>&1); then return; fi
  if command -v crc >/dev/null && [[ -d "$HOME/.crc/machines/crc" ]]; then
    local st t0 last_min=-1
    t0=$(date +%s)
    while :; do
      st=$(crc_status)
      [[ "$st" == "Running" ]] && break
      # Stopped / no VM: waiting will not help
      if [[ "$st" == "Stopped" || "$st" == "" ]] && [[ "$(crc_field crcStatus)" != "Running" ]]; then
        hint "Start it with: crc start   (or ./setup-cluster.sh)"
        die "The crc cluster is not running (status: ${st:-unknown})."
      fi
      # VM up but almost no RAM in use: OpenShift is not running inside it (typical
      # after a host suspend/resume). It will not recover by itself.
      local ram; ram=$(crc_field ramUsage)
      if [[ "$ram" =~ ^[0-9]+$ ]] && (( ram > 0 && ram < 2 * 1024 * 1024 * 1024 )); then
        hint "This usually follows a laptop suspend/resume. Restart the cluster:"
        hint "crc stop && crc start     # then re-run ./setup.sh"
        die "crc VM is running but OpenShift is not ($(( ram / 1024 / 1024 ))MB RAM in use, API '$st')."
      fi
      # VM is up but the API is not answering yet (e.g. after suspend/reboot): wait
      if (( $(date +%s) - t0 > CRC_API_WAIT_MIN * 60 )); then
        hint "getent hosts api.crc.testing        # must resolve to $(crc ip 2>/dev/null || echo 'the crc IP')"
        hint "curl -k https://api.crc.testing:6443/readyz"
        hint "oc --kubeconfig ~/.crc/machines/crc/kubeconfig get co"
        hint "If the laptop was suspended: crc stop && crc start"
        die "crc VM is running but the OpenShift API stayed '$st' for ${CRC_API_WAIT_MIN} min."
      fi
      local m=$(( ($(date +%s) - t0) / 60 ))
      if (( m != last_min )); then info "crc API status '$st' - waiting for it to recover (${m} min)"; last_min=$m; fi
      sleep 15
    done
    info "oc session expired or missing - logging in to crc as kubeadmin"
    local creds user pass api
    creds=$(crc console --credentials -o json)
    user=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["clusterConfig"]["adminCredentials"]["username"])' <<<"$creds")
    pass=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["clusterConfig"]["adminCredentials"]["password"])' <<<"$creds")
    api=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["clusterConfig"]["url"])' <<<"$creds")
    if oc login -u "$user" -p "$pass" "$api" --insecure-skip-tls-verify=true >/dev/null 2>&1; then
      return
    fi
    # Fall back to crc's certificate-based admin kubeconfig
    if [[ -f "$HOME/.crc/machines/crc/kubeconfig" ]]; then
      export KUBECONFIG="$HOME/.crc/machines/crc/kubeconfig"
      oc whoami >/dev/null 2>&1 && { info "Using crc admin kubeconfig ($KUBECONFIG)"; return; }
    fi
    die "Could not log in to the crc cluster. Try: crc console --credentials"
  fi
  echo "    oc: ${err%%$'\n'*}" >&2
  hint "No cluster? ./setup-cluster.sh creates a local OpenShift cluster and logs you in."
  die "oc is not logged in. Run 'oc login ...' as cluster-admin."
}

check_prereqs() {
  phase 1 "Prerequisites" "<1 min"
  install_packages
  command -v oc >/dev/null || die "'oc' not found in PATH. Run ./setup-cluster.sh or install the OpenShift CLI."
  [[ -e /dev/kvm ]] || die "/dev/kvm not present - enable hardware virtualization in BIOS."

  if ! systemctl is-active --quiet libvirtd && ! systemctl is-active --quiet virtqemud; then
    info "Starting libvirt"
    sudo systemctl enable --now libvirtd 2>/dev/null || sudo systemctl enable --now virtqemud.socket
  fi
  virsh_ list >/dev/null || die "Cannot connect to $LIBVIRT_URI"
  ok "libvirt reachable ($LIBVIRT_URI)"

  ensure_oc_login
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "Current oc user ($(oc whoami)) is not cluster-admin."
  ok "OpenShift: $(oc whoami) @ $(oc whoami --show-server)"

  check_hybrid_overlay

  if [[ -z "$BRIDGE" && -z "$LIBVIRT_NET" ]]; then
    if virsh_ net-info crc >/dev/null 2>&1; then LIBVIRT_NET=crc; else LIBVIRT_NET=default; fi
  fi
  if [[ -z "$BRIDGE" ]]; then
    if ! virsh_ net-info "$LIBVIRT_NET" >/dev/null 2>&1; then
      die "libvirt network '$LIBVIRT_NET' not found (set LIBVIRT_NET or BRIDGE)."
    fi
    if ! grep -qx "$LIBVIRT_NET" <<<"$(virsh_ net-list --name)"; then   # lists active networks only
      virsh_ net-start "$LIBVIRT_NET" >/dev/null 2>&1 || true            # tolerate "already active"
      grep -qx "$LIBVIRT_NET" <<<"$(virsh_ net-list --name)" || die "libvirt network '$LIBVIRT_NET' could not be started."
    fi
    virsh_ net-autostart "$LIBVIRT_NET" >/dev/null
    ok "Network: libvirt NAT network '$LIBVIRT_NET'"
    if [[ "$LIBVIRT_NET" != "crc" ]]; then
      warn "The cluster must be able to reach the VM on '$LIBVIRT_NET' (works when the cluster runs on this host)."
      hint "For a remote cluster use a bridge: BRIDGE=br0 ./setup.sh"
    fi
  else
    ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge '$BRIDGE' does not exist on this host."
    ok "Network: bridge $BRIDGE"
  fi

  # Disk space
  local need_kb=$(( VM_DISK_GB * 1024 * 1024 ))
  [[ -f "$WIN_ISO" ]] || need_kb=$(( need_kb + 7 * 1024 * 1024 ))
  local avail_kb; avail_kb=$(df -Pk "$IMG_DIR" | awk 'NR==2{print $4}')
  if (( avail_kb < need_kb )); then
    warn "Only $((avail_kb/1024/1024))GB free in $IMG_DIR (want ~$((need_kb/1024/1024))GB). The qcow2 disk is thin, continuing."
  fi

  mkdir -p "$WORK_DIR"
  if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "wmco-byoh" -f "$SSH_KEY"
    ok "Generated dedicated SSH key: $SSH_KEY"
  else
    ok "Using SSH key: $SSH_KEY"
  fi
}

check_hybrid_overlay() {
  local net_type ho
  net_type=$(oc get network.config cluster -o jsonpath='{.status.networkType}')
  [[ "$net_type" == "OVNKubernetes" ]] || die "Cluster network type is '$net_type'; WMCO requires OVNKubernetes."
  ho=$(oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.hybridOverlayConfig}')
  if [[ -n "$ho" ]]; then
    ok "Hybrid overlay networking configured"
    return
  fi
  if [[ "$HYBRID_OVERLAY_AUTO" == "1" ]]; then
    info "Enabling hybrid overlay ($HYBRID_CIDR /$HYBRID_HOST_PREFIX)"
    oc patch network.operator.openshift.io cluster --type=merge -p \
      "{\"spec\":{\"defaultNetwork\":{\"ovnKubernetesConfig\":{\"hybridOverlayConfig\":{\"hybridClusterNetwork\":[{\"cidr\":\"$HYBRID_CIDR\",\"hostPrefix\":$HYBRID_HOST_PREFIX}]}}}}}"
    info "Waiting for the network operator to roll out"
    sleep 20
    oc wait co/network --for=condition=Progressing=False --timeout=20m >/dev/null
    ok "Hybrid overlay enabled"
  else
    die "Hybrid overlay networking is not configured on the cluster."
  fi
}

# ----------------------------------------------------------------------------
# Phase 2: Windows ISO
# ----------------------------------------------------------------------------
# Ask for the sudo password once, then keep the credential fresh in the background
# so steps after long waits (ISO download, Windows install) never block on a prompt.
sudo_keepalive() {
  [[ $EUID -eq 0 ]] && return
  info "Some steps need sudo (ISO/disk files in $IMG_DIR, packages)"
  sudo -v || die "sudo is required."
  local parent=$$
  ( while kill -0 "$parent" 2>/dev/null; do sudo -n -v 2>/dev/null || exit; sleep 50; done ) &
  disown
}

is_iso() {  # ISO9660 signature "CD001" at byte 32769
  [[ -f "$1" ]] && (( $(stat -c %s "$1") > 4000000000 )) \
    && [[ "$(dd if="$1" bs=1 skip=32769 count=5 2>/dev/null | tr -d '\0')" == "CD001" ]]
}

remote_size() {
  curl -sIL -m 30 "$1" | awk 'tolower($1)=="content-length:" {n=$2} END {gsub(/\r/, "", n); print n+0}'
}

ensure_iso() {
  phase 2 "Windows Server 2025 ISO" "one-time ~6GB download"
  if is_iso "$WIN_ISO"; then
    ok "ISO present: $WIN_ISO"
    return
  fi
  sudo mkdir -p "$IMG_DIR"
  local part="$WIN_ISO.part" want have
  want=$(remote_size "$WIN_ISO_URL")
  have=$( [[ -f "$part" ]] && stat -c %s "$part" || echo 0 )
  if (( have > 0 && have == want )) || { (( want == 0 )) && is_iso "$part"; }; then
    info "Found a completed download from a previous run"
  else
    (( have > 0 )) && info "Resuming download ($((have/1024/1024))MB of $((want/1024/1024))MB already present)" \
                   || info "Downloading Windows Server 2025 Evaluation ISO to $WIN_ISO"
    info "Source: $WIN_ISO_URL"
    sudo curl -fL --retry 5 --retry-delay 5 -C - --progress-bar -o "$part" "$WIN_ISO_URL" \
      || die "ISO download failed. Download it manually and set WIN_ISO=/path/to.iso"
  fi
  is_iso "$part" || die "$part is not a valid ISO image. Delete it and re-run."
  sudo mv "$part" "$WIN_ISO"
  ok "ISO ready: $WIN_ISO ($(du -h "$WIN_ISO" | cut -f1))"
}

# ----------------------------------------------------------------------------
# Phase 3: Unattended config + VM
# ----------------------------------------------------------------------------
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<<"$1"; }

write_autounattend() {
  local pw; pw=$(xml_escape "$WIN_PASSWORD")
  local arch='processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'

  cat > "$WORK_DIR/iso/autounattend.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" $arch>
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" $arch>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>500</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>System</Label><Active>true</Active></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>$WIN_IMAGE_INDEX</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>2</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>WMCO Lab</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $arch>
      <ComputerName>$WIN_HOSTNAME</ComputerName>
      <TimeZone>$WIN_TIMEZONE</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" $arch>
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Microsoft-Windows-ServerManager-SvrMgrNc" $arch>
      <DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $arch>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $arch>
      <UserAccounts>
        <AdministratorPassword><Value>$pw</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <Password><Value>$pw</Value><PlainText>true</PlainText></Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Configure EMS port and baud rate</Description>
          <CommandLine>bcdedit /emssettings EMSPORT:1 EMSBAUDRATE:115200</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Enable Emergency Management Services for serial console</Description>
          <CommandLine>bcdedit /ems on</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Enable bootdebug for boot manager</Description>
          <CommandLine>bcdedit /bootdebug on</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>WMCO BYOH host preparation</Description>
          <CommandLine>cmd.exe /c for %d in (D E F G H I J K) do @if exist %d:\wmco-setup.ps1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File %d:\wmco-setup.ps1</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF
}

write_setup_ps1() {
  local pubkey; pubkey=$(cat "$SSH_KEY.pub")
  cat > "$WORK_DIR/iso/wmco-setup.ps1" <<EOF
# Runs once at first logon (from autounattend.xml). Prepares the host for WMCO BYOH.
\$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\\wmco-setup.log -Append

Write-Host '==> Network profile: Private'
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

Write-Host '==> OpenSSH Server'
\$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
if (\$cap -and \$cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name \$cap.Name }
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd   # first start creates C:\\ProgramData\\ssh

Write-Host '==> Authorized key for Administrator'
\$ak = 'C:\\ProgramData\\ssh\\administrators_authorized_keys'
Set-Content -Path \$ak -Value '$pubkey' -Encoding ascii
icacls.exe \$ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
Restart-Service sshd

Write-Host '==> WinRM'
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Service -Name WinRM -StartupType Automatic

Write-Host '==> Firewall rules'
\$rules = @(
  @{ Name='WMCO-SSH';      Port=22;    Proto='TCP' },
  @{ Name='WMCO-WinRM';    Port=5985;  Proto='TCP' },
  @{ Name='WMCO-RDP';      Port=3389;  Proto='TCP' },
  @{ Name='WMCO-Kubelet';  Port=10250; Proto='TCP' },
  @{ Name='WMCO-Exporter'; Port=9182;  Proto='TCP' },
  @{ Name='WMCO-VXLAN';    Port=4789;  Proto='UDP' }
)
foreach (\$r in \$rules) {
  if (-not (Get-NetFirewallRule -Name \$r.Name -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name \$r.Name -DisplayName \$r.Name -Direction Inbound -Action Allow \`
      -Protocol \$r.Proto -LocalPort \$r.Port -Profile Any | Out-Null
  }
}
New-NetFirewallRule -Name 'WMCO-ICMP' -DisplayName 'WMCO-ICMP' -Direction Inbound -Action Allow \`
  -Protocol ICMPv4 -IcmpType 8 -Profile Any -ErrorAction SilentlyContinue | Out-Null
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value 0

Write-Host '==> No automatic update reboots (setup.sh installs updates itself in a controlled phase)'
New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU' -Name NoAutoUpdate -Value 1

Write-Host '==> Windows Containers feature'
Install-WindowsFeature -Name Containers | Out-Null

Set-Content -Path C:\\wmco-setup.done -Value (Get-Date -Format o)
Write-Host '==> Done, rebooting to finish the Containers feature'
Stop-Transcript
Restart-Computer -Force
EOF
}

build_config_iso() {
  rm -rf "$WORK_DIR/iso"; mkdir -p "$WORK_DIR/iso"
  write_autounattend
  write_setup_ps1
  local tmp_iso="$WORK_DIR/autounattend.iso"
  if command -v xorriso >/dev/null; then
    xorriso -as mkisofs -quiet -J -r -V WMCOCFG -o "$tmp_iso" "$WORK_DIR/iso"
  else
    "$(command -v genisoimage || command -v mkisofs)" -quiet -J -r -V WMCOCFG -o "$tmp_iso" "$WORK_DIR/iso"
  fi
  sudo install -m 0644 "$tmp_iso" "$CONFIG_ISO"
  ok "Generated autounattend.xml + wmco-setup.ps1 -> $CONFIG_ISO"
}

vm_exists() { virsh_ dominfo "$VM_NAME" >/dev/null 2>&1; }
vm_state()  { virsh_ domstate "$VM_NAME" 2>/dev/null | head -1; }

open_viewer() {
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v virt-viewer >/dev/null; then
    nohup virt-viewer -c "$LIBVIRT_URI" --wait "$VM_NAME" >/dev/null 2>&1 &
    ok "Console viewer opened (virt-viewer)"
  else
    info "No graphical display detected. Watch the console with: virt-viewer -c $LIBVIRT_URI $VM_NAME"
  fi
}

create_vm() {
  phase 3 "Create virtual machine" "1-2 min"
  if vm_exists; then
    ok "VM '$VM_NAME' already exists (state: $(vm_state)) - skipping creation"
    [[ "$(vm_state)" == "running" ]] || virsh_ start "$VM_NAME" >/dev/null
    open_viewer
    return
  fi

  build_config_iso

  local net_arg
  if [[ -n "$BRIDGE" ]]; then net_arg="bridge=$BRIDGE,model=e1000e,mac=$WIN_MAC"
  else net_arg="network=$LIBVIRT_NET,model=e1000e,mac=$WIN_MAC"; prereserve_dhcp; fi

  info "Creating VM: ${VM_CPUS} vCPU, $((VM_RAM_MB/1024))GB RAM, ${VM_DISK_GB}GB disk"
  # SATA disk + e1000e NIC use in-box Windows drivers (no virtio ISO needed).
  # Boot order hd,cdrom: the empty disk falls through to the DVD on first boot;
  # after Setup's first reboot the disk is bootable, so there is no install loop.
  virt-install --connect "$LIBVIRT_URI" \
    --name "$VM_NAME" \
    --memory "$VM_RAM_MB" --vcpus "$VM_CPUS" --cpu host-passthrough \
    --osinfo detect=on,require=off \
    --boot hd,cdrom \
    --disk "path=$VM_DISK,size=$VM_DISK_GB,format=qcow2,bus=sata" \
    --disk "path=$WIN_ISO,device=cdrom,bus=sata,readonly=on" \
    --disk "path=$CONFIG_ISO,device=cdrom,bus=sata,readonly=on" \
    --network "$net_arg" \
    --graphics spice --video qxl \
    --features hyperv.relaxed.state=on,hyperv.vapic.state=on,hyperv.spinlocks.state=on,hyperv.spinlocks.retries=8191 \
    --clock offset=localtime,hypervclock_present=yes \
    --import --noautoconsole >/dev/null
  ok "VM '$VM_NAME' created and booting from the Windows ISO"
  open_viewer
}

# ----------------------------------------------------------------------------
# Phase 4: Windows installation -> IP address
# ----------------------------------------------------------------------------
vm_mac() { virsh_ domiflist "$VM_NAME" | awk 'NR>0 && $5 ~ /:/ {print $5; exit}'; }

discover_ip() {
  local mac src ip
  mac=$(vm_mac)
  for src in lease arp; do
    ip=$(virsh_ domifaddr "$VM_NAME" --source "$src" 2>/dev/null \
          | awk '/ipv4/ {sub(/\/.*/, "", $4); print $4; exit}')
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
  # Bridged: try the host neighbour table
  if [[ -n "$mac" ]]; then
    ip=$(ip neigh | awk -v m="$mac" 'tolower($5)==tolower(m) && $1 ~ /\./ {print $1; exit}')
    [[ -n "$ip" ]] && echo "$ip"
  fi
}

# Networks without a DHCP range (e.g. crc's) only hand out reserved addresses,
# so reserve one for our fixed MAC before the VM boots.
prereserve_dhcp() {
  local xml gw ip
  xml=$(virsh_ net-dumpxml "$LIBVIRT_NET")
  grep -q "mac='$WIN_MAC'" <<<"$xml" && return
  grep -q "<range" <<<"$xml" && return
  gw=$(grep -o "<ip [^>]*address='[0-9.]*'" <<<"$xml" | head -1 | grep -o "[0-9.]*'$" | tr -d "'")
  [[ -n "$gw" ]] || die "Cannot read the IPv4 subnet of libvirt network '$LIBVIRT_NET'."
  ip="${gw%.*}.$WIN_STATIC_HOST"
  virsh_ net-update "$LIBVIRT_NET" add ip-dhcp-host \
    "<host mac='$WIN_MAC' name='$WIN_HOSTNAME' ip='$ip'/>" --live --config >/dev/null
  ok "Reserved $ip for the Windows VM on network '$LIBVIRT_NET'"
}

reserve_dhcp() {
  [[ -n "$BRIDGE" ]] && return
  local mac; mac=$(vm_mac)
  if grep -q "mac='$mac'" <<<"$(virsh_ net-dumpxml "$LIBVIRT_NET")"; then return; fi
  if virsh_ net-update "$LIBVIRT_NET" add ip-dhcp-host \
       "<host mac='$mac' name='$WIN_HOSTNAME' ip='$WIN_IP'/>" --live --config >/dev/null 2>&1; then
    ok "Reserved DHCP lease $WIN_IP for $mac (IP stays stable across reboots)"
  fi
}

wait_for_ip() {
  phase 4 "Unattended Windows installation" "15-25 min"
  if [[ -n "${WIN_IP:-}" ]]; then ok "Using WIN_IP=$WIN_IP"; return; fi
  info "Windows Setup is running unattended - watch the console window for progress"
  local t0; t0=$(date +%s)
  local deadline=$(( t0 + INSTALL_TIMEOUT_MIN * 60 ))
  local last_min=-1 restarts=0
  while :; do
    WIN_IP=$(discover_ip || true)
    [[ -n "$WIN_IP" ]] && break
    if [[ "$(vm_state)" == "shut off" ]]; then
      (( restarts++ < 3 )) || die "VM keeps shutting off during installation."
      warn "VM powered off during installation - starting it again (recovery $restarts/3)"
      virsh_ start "$VM_NAME" >/dev/null
    fi
    (( $(date +%s) > deadline )) && { hint "Check the console for a Setup error dialog."; die "No IP after ${INSTALL_TIMEOUT_MIN} min."; }
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then info "Waiting for DHCP address... ${m} min elapsed"; last_min=$m; fi
    sleep 15
  done
  ok "VM has IP address $WIN_IP ($(elapsed "$t0"))"
  reserve_dhcp
}

# ----------------------------------------------------------------------------
# Phase 5: SSH / WinRM / host prep
# ----------------------------------------------------------------------------
wait_for_access() {
  phase 5 "Network & remote access" "2-5 min after Windows finishes"
  local t0; t0=$(date +%s)
  local deadline=$(( t0 + INSTALL_TIMEOUT_MIN * 60 ))
  local last_min=-1 state="" restarts=0

  info "Waiting for SSH key login + Containers feature (installed by first-logon script)"
  while :; do
    # IP may change between WinPE and the installed OS on bridged networks
    local nip; nip=$(discover_ip || true); [[ -n "$nip" ]] && WIN_IP=$nip
    state=$(win_ps "(Get-WindowsFeature Containers).InstallState" 2>/dev/null | tr -d '\r' || true)
    [[ "$state" == "Installed" ]] && break
    if [[ "$(vm_state)" == "shut off" ]]; then
      (( restarts++ < 3 )) || die "VM keeps shutting off."
      warn "VM is off - starting it (recovery $restarts/3)"
      virsh_ start "$VM_NAME" >/dev/null
    fi
    (( $(date +%s) > deadline )) && {
      hint "Log in via the console (Administrator / $WIN_PASSWORD) and check C:\\wmco-setup.log"
      die "Windows host was not ready after ${INSTALL_TIMEOUT_MIN} min (last state: ${state:-no ssh})."
    }
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then
      info "${m} min elapsed - ${state:+containers: $state}${state:-SSH not reachable yet (Windows still installing)}"
      last_min=$m
    fi
    sleep 20
  done
  ok "SSH key login works: ssh -i $SSH_KEY Administrator@$WIN_IP"
  ok "Containers feature installed"

  if (timeout 3 bash -c "</dev/tcp/$WIN_IP/5985") 2>/dev/null; then ok "WinRM listening on $WIN_IP:5985"
  else warn "WinRM port 5985 not reachable from this host"; fi
  if (timeout 3 bash -c "</dev/tcp/$WIN_IP/3389") 2>/dev/null; then ok "RDP listening on $WIN_IP:3389"
  else warn "RDP port 3389 not reachable from this host"; fi

  # Installation media no longer needed: eject so the VM can never boot Setup again
  local tgt
  for tgt in $(virsh_ domblklist "$VM_NAME" --details | awk '$2=="cdrom"{print $3}'); do
    virsh_ change-media "$VM_NAME" "$tgt" --eject --live --config >/dev/null 2>&1 || true
  done
  ok "Installation media ejected"

  # Pre-flight: can Windows reach the cluster's internal API?
  local api host port
  api=$(oc get infrastructure cluster -o jsonpath='{.status.apiServerInternalURI}')
  host=${api#https://}; port=${host##*:}; host=${host%%:*}
  local test_cmd="if ((Test-NetConnection -ComputerName '$host' -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded) { 'ok' }"
  if ! grep -q ok <<<"$(win_ps "$test_cmd" 2>/dev/null)"; then
    # Names like api-int.crc.testing resolve on this host (NetworkManager dnsmasq)
    # but not inside the VM: pin them in the Windows hosts file.
    local ext name addr
    ext=$(oc whoami --show-server); ext=${ext#https://}; ext=${ext%%:*}
    for name in "$host" "$ext"; do
      addr=$(getent ahostsv4 "$name" | awk '{print $1; exit}')
      [[ -n "$addr" ]] || continue
      win_ps "Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value '$addr $name'" >/dev/null 2>&1 \
        && info "Added '$addr $name' to the Windows hosts file"
    done
  fi
  if grep -q ok <<<"$(win_ps "$test_cmd" 2>/dev/null)"; then
    ok "Windows can reach $host:$port"
  else
    warn "Windows cannot reach the internal API ($host:$port). The node will not be able to join."
    hint "Make '$host' resolvable from the VM (DNS or C:\\Windows\\System32\\drivers\\etc\\hosts) and routable."
  fi
}

# ----------------------------------------------------------------------------
# Phase 6: Windows updates
# ----------------------------------------------------------------------------
# Process-isolated containers share the host kernel: the ltsc2025 images track the
# latest cumulative update, and a host left at the ISO's build (e.g. 26100.1742 vs
# image 26100.33822) fails with "hcs::System::Start ... exited unexpectedly".

# Build revision (UBR) the test image was built for, from the MCR registry API
image_ubr() {
  local ref=${IIS_IMAGE#mcr.microsoft.com/} repo tag
  repo=${ref%%:*}; tag=${ref##*:}
  python3 - "$repo" "$tag" <<'PYEOF' 2>/dev/null || true
import json, sys, urllib.request
repo, tag = sys.argv[1:3]
base = "https://mcr.microsoft.com/v2/" + repo
acc = ", ".join(["application/vnd.docker.distribution.manifest.list.v2+json",
                 "application/vnd.oci.image.index.v1+json",
                 "application/vnd.docker.distribution.manifest.v2+json",
                 "application/vnd.oci.image.manifest.v1+json"])
get = lambda u: json.load(urllib.request.urlopen(urllib.request.Request(u, headers={"Accept": acc}), timeout=30))
m = get(base + "/manifests/" + tag)
if "manifests" in m:
    v = next(x["platform"].get("os.version", "") for x in m["manifests"] if x["platform"].get("os") == "windows")
else:
    v = get(base + "/blobs/" + m["config"]["digest"]).get("os.version", "")
print(v.split(".")[-1])
PYEOF
}

host_build() {
  win_ps "\$v=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; \$v.CurrentBuild + '.' + \$v.UBR" 2>/dev/null | tr -d '\r'
}

host_up_to_date() {  # $1 = image build revision
  local have; have=$(host_build)
  [[ -n "$1" && "${have##*.}" =~ ^[0-9]+$ ]] && (( ${have##*.} >= $1 ))
}

win_pending_reboot() {
  [[ "$(win_ps "if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) { 'yes' }" 2>/dev/null | tr -d '\r')" == yes ]]
}

# Graceful reboot for update rounds:
#  - wait until Windows servicing is idle (TrustedInstaller/TiWorker finish component
#    store work after an update; interrupting that is what can damage the system)
#  - "shutdown /r /t 0": with /t > 0 Windows implies /f (force-close); /t 0 does not
win_reboot() {
  local t0 last_min=-1 busy
  t0=$(date +%s)
  while :; do
    busy=$(win_ps "(Get-Process TiWorker,TrustedInstaller,msiexec -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique) -join ','" 2>/dev/null | tr -d '\r' || true)
    [[ -z "$busy" ]] && break
    if (( $(date +%s) - t0 > 60 * 60 )); then
      hint "ssh -i $SSH_KEY Administrator@$WIN_IP   then: Get-Process TiWorker,TrustedInstaller"
      die "Windows servicing ($busy) still busy after 60 min - not rebooting it from the script."
    fi
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then info "  waiting for Windows servicing to finish before reboot ($busy) - ${m} min"; last_min=$m; fi
    sleep 30
  done
  win_ssh "shutdown /r /t 0 /c \"WMCO setup: Windows updates\"" >/dev/null 2>&1 || true
  wait_for_reboot
}

wait_for_reboot() {
  local t0; t0=$(date +%s)
  # down...
  while win_ssh "echo up" >/dev/null 2>&1; do
    (( $(date +%s) - t0 > 300 )) && break
    sleep 10
  done
  # ...and up again (installing updates during boot can take a while)
  local last_min=-1
  until win_ssh "echo up" >/dev/null 2>&1; do
    (( $(date +%s) - t0 > 45 * 60 )) && die "Windows did not come back after the update reboot (45 min)."
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then info "  rebooting / applying updates... ${m} min"; last_min=$m; fi
    sleep 15
  done
  ok "Windows is back after reboot ($(elapsed "$t0"))"
}

# ---- Update task left over from an interrupted run -------------------------
wu_task_state() {  # Running / Ready / ... ; empty if the task does not exist
  win_ssh "schtasks /Query /TN wmco-wu /FO CSV /NH 2>nul" 2>/dev/null | tr -d '\r' | awk -F'","' 'NF>=3 {gsub(/"/, "", $3); print $3; exit}'
}
wu_last_step() {   # last line of C:\wmco-wu.log without the timestamp
  win_ssh "type C:\\wmco-wu.log 2>nul" 2>/dev/null | tr -d '\r' | grep . | tail -1 | cut -c21-
}
# Only the search is read-only; download/install must be left alone
wu_step_is_safe_to_stop() { [[ "$1" == "Searching for updates" ]]; }

# Returns 0 if no update task is running anymore (stopped or not running),
# 1 if it is downloading/installing and was left alone.
wu_stop_if_safe() {
  local state step
  state=$(wu_task_state)
  step=$(wu_last_step)
  info "Host build: $(host_build || echo '?')   update task: ${state:-none}   last step: ${step:-none}"
  if [[ "$state" != "Running" ]]; then ok "No Windows Update task is running"; return 0; fi
  if wu_step_is_safe_to_stop "$step"; then
    win_ssh "schtasks /End /TN wmco-wu" >/dev/null 2>&1 || true
    ok "Stopped the update task (it was only searching - read-only, nothing changed on the system)"
    return 0
  fi
  warn "The update task is '$step' - NOT stopping it (interrupting download/install is unsafe)"
  return 1
}

# Called at the start of phase 6: stop a leftover search, or wait for a leftover
# download/install to finish (and reboot if it asks for one) before doing anything else.
wu_handle_leftover() {
  wu_stop_if_safe && return
  local t0 last_min=-1 status
  t0=$(date +%s)
  info "Waiting for the update task from the previous run to finish"
  while [[ "$(wu_task_state)" == "Running" ]]; do
    (( $(date +%s) - t0 > 120 * 60 )) && die "Leftover update task still running after 120 min."
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then info "  ${m} min - host build $(host_build || echo '?') - $(wu_last_step)"; last_min=$m; fi
    sleep 30
  done
  status=$(win_ssh "type C:\\wmco-wu.status 2>nul" 2>/dev/null | tr -d '\r' || true)
  ok "Previous update task finished: ${status:-no status}"
  [[ "$status" == REBOOT ]] && win_reboot
  return 0
}

stop_updates() {
  vm_exists || die "VM '$VM_NAME' does not exist."
  WIN_IP="${WIN_IP:-$(discover_ip || true)}"
  [[ -n "$WIN_IP" ]] || die "Could not find the VM's IP address (set WIN_IP=...)."
  win_ssh "echo ok" >/dev/null 2>&1 || die "Cannot SSH to Administrator@$WIN_IP."
  if wu_stop_if_safe; then
    ok "Safe to re-run ./setup.sh"
  else
    hint "Watch it:  ssh -i $SSH_KEY Administrator@$WIN_IP type C:\\wmco-wu.log"
    hint "Or just re-run ./setup.sh - phase 6 waits for this task to finish before continuing."
    return 1
  fi
}

update_windows() {
  phase 6 "Windows updates" "20-60 min, one-time"
  if [[ "$WIN_UPDATE" != "1" ]]; then warn "WIN_UPDATE=$WIN_UPDATE - skipping (containers may fail to start on an outdated host)"; return; fi
  local build_at_start; build_at_start=$(host_build)
  wu_handle_leftover

  local want have
  want=$(image_ubr)
  have=$(host_build)
  info "Host build: ${have:-unknown}   container image ($IIS_IMAGE) build revision: ${want:-unknown}"
  if host_up_to_date "$want"; then
    ok "Host is at least as new as the container image - no update needed"
    return
  fi

  # The Windows Update API refuses remote (SSH) logons, so run it as SYSTEM in a scheduled task
  cat > "$WORK_DIR/wmco-wu.ps1" <<'PSEOF'
$log = 'C:\wmco-wu.log'
function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format s), $m) }
try {
  $session  = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher()
  L 'Searching for updates'
  $found = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0").Updates
  L ("Found {0} update(s)" -f $found.Count)
  if ($found.Count -eq 0) { Set-Content C:\wmco-wu.status 'NONE'; exit 0 }
  $coll = New-Object -ComObject Microsoft.Update.UpdateColl
  foreach ($u in $found) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; L ("  " + $u.Title); [void]$coll.Add($u) }
  L 'Downloading'
  $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
  L 'Installing'
  $in = $session.CreateUpdateInstaller(); $in.Updates = $coll; $res = $in.Install()
  L ("Result {0}, reboot required: {1}" -f $res.ResultCode, $res.RebootRequired)
  if ($res.RebootRequired) { Set-Content C:\wmco-wu.status 'REBOOT' } else { Set-Content C:\wmco-wu.status 'DONE' }
} catch {
  L ("ERROR " + $_)
  Set-Content C:\wmco-wu.status ("ERROR " + $_)
}
PSEOF
  scp "${SSH_OPTS[@]}" -q "$WORK_DIR/wmco-wu.ps1" "Administrator@$WIN_IP:C:/wmco-wu.ps1"

  local round status t0 last_min line phase_since cur_phase
  for round in 1 2 3 4; do
    # A finished cumulative update can leave servicing work that needs another reboot;
    # searching before that reboot tends to hang.
    if (( round > 1 )) && win_pending_reboot; then
      info "Windows reports a pending reboot - rebooting before searching again"
      win_reboot
    fi
    # Stop as soon as the host is as new as the image - more rounds are not needed
    if (( round > 1 )) && host_up_to_date "$want"; then
      ok "Host build $(host_build) is at least the image revision $want - done"
      break
    fi

    info "Update round $round: searching, downloading and installing (progress in C:\\wmco-wu.log)"
    win_ssh "del /q C:\\wmco-wu.status 2>nul & schtasks /Create /F /TN wmco-wu /RU SYSTEM /RL HIGHEST /SC ONCE /SD 01/01/2099 /ST 00:00 /TR \"powershell -NoProfile -ExecutionPolicy Bypass -File C:\\wmco-wu.ps1\" >nul 2>&1 & schtasks /Run /TN wmco-wu >nul" \
      || die "Could not start the Windows Update task."
    t0=$(date +%s); last_min=-1; status=""; cur_phase=""; phase_since=$t0
    # Show only log lines written by this round (the log keeps earlier rounds)
    local seen log_txt total
    seen=$(win_ssh "type C:\\wmco-wu.log 2>nul" 2>/dev/null | tr -d '\r' | grep -c . || true)
    seen=${seen:-0}
    while :; do
      status=$(win_ssh "type C:\\wmco-wu.status 2>nul" 2>/dev/null | tr -d '\r' || true)
      [[ -n "$status" ]] && break
      (( $(date +%s) - t0 > 90 * 60 )) && die "Windows Update round $round did not finish within 90 min."
      local m=$(( ($(date +%s) - t0) / 60 ))
      if (( m != last_min )); then
        # Same data as: ssh ... type C:\wmco-wu.log   and the host build query
        log_txt=$(win_ssh "type C:\\wmco-wu.log 2>nul" 2>/dev/null | tr -d '\r' || true)
        total=$(printf '%s\n' "$log_txt" | grep -c . || true)
        if (( total > seen )); then
          printf '%s\n' "$log_txt" | grep . | tail -n +"$((seen + 1))" | sed 's/^/      log: /'
          seen=$total
        fi
        line=$(printf '%s\n' "$log_txt" | grep . | tail -1 | cut -c21-)
        info "  ${m} min - host build $(host_build || echo '?') - ${line:-starting}"
        last_min=$m
        if [[ "$line" != "$cur_phase" ]]; then cur_phase=$line; phase_since=$(date +%s); fi
        # The search itself normally takes a few minutes; a long hang is a known WU behaviour
        if [[ "$cur_phase" == "Searching for updates" ]] && (( $(date +%s) - phase_since > WU_SEARCH_TIMEOUT_MIN * 60 )); then
          warn "Update search hung for ${WU_SEARCH_TIMEOUT_MIN} min - stopping it"
          win_ssh "schtasks /End /TN wmco-wu" >/dev/null 2>&1 || true
          status="HUNG"
          break
        fi
      fi
      sleep 30
    done
    case "$status" in
      NONE)   ok "No more updates available"; break ;;
      DONE)   ok "Updates installed (no reboot needed)" ;;
      REBOOT) ok "Updates installed - rebooting ($(elapsed "$t0"))"
              win_reboot ;;
      HUNG)   if host_up_to_date "$want"; then ok "Host is already up to date - not waiting for the search"; break; fi
              info "Host not up to date yet - rebooting (once servicing is idle) and retrying"
              win_reboot ;;
      *)      hint "ssh -i $SSH_KEY Administrator@$WIN_IP type C:\\wmco-wu.log"
              die "Windows Update failed: $status" ;;
    esac
  done
  win_ssh "schtasks /Delete /F /TN wmco-wu" >/dev/null 2>&1 || true

  have=$(host_build)
  if [[ -n "$want" && "${have##*.}" =~ ^[0-9]+$ ]] && (( ${have##*.} < want )); then
    warn "Host build $have is still older than the image revision $want; containers may fail to start."
    hint "Use an image matching the host, e.g. IIS_IMAGE=... or check C:\\wmco-wu.log"
  else
    ok "Host build now $have"
  fi

  # Layers unpacked on the old build fail on the new one
  # ("hcsshim::PrepareLayer ... unrecognized format (0xc0370112)"): start clean.
  if [[ -n "$build_at_start" && "$have" != "$build_at_start" ]] && containerd_has_layers; then
    info "Windows build changed ($build_at_start -> $have) on a node that already has container images"
    reset_containerd auto
  fi
}

# ----------------------------------------------------------------------------
# Phase 7: WMCO + BYOH registration
# ----------------------------------------------------------------------------
detect_wmco_package() {
  if [[ -n "$WMCO_PACKAGE" && -n "$WMCO_CATALOG" ]]; then return; fi
  local p
  for p in windows-machine-config-operator community-windows-machine-config-operator; do
    if oc get packagemanifest -n openshift-marketplace "$p" >/dev/null 2>&1; then
      WMCO_PACKAGE=$p
      WMCO_CATALOG=$(oc get packagemanifest -n openshift-marketplace "$p" -o jsonpath='{.status.catalogSource}')
      break
    fi
  done
  [[ -n "$WMCO_PACKAGE" ]] || die "WMCO package not found in any CatalogSource (redhat-operators / community-operators)."
  [[ -n "$WMCO_CHANNEL" ]] || WMCO_CHANNEL=$(oc get packagemanifest -n openshift-marketplace "$WMCO_PACKAGE" -o jsonpath='{.status.defaultChannel}')
}

wait_for_csv() {
  local t0; t0=$(date +%s)
  info "Waiting for the operator to install"
  while :; do
    local csv phase_
    csv=$(oc get subscription -n "$WMCO_NS" windows-machine-config-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [[ -n "$csv" ]]; then
      phase_=$(oc get csv -n "$WMCO_NS" "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      [[ "$phase_" == "Succeeded" ]] && { ok "Operator $csv is running ($(elapsed "$t0"))"; return; }
    fi
    (( $(date +%s) - t0 > 900 )) && die "WMCO CSV did not reach Succeeded within 15 min."
    sleep 10
  done
}

deploy_wmco() {
  phase 7 "OpenShift integration (WMCO BYOH)" "5-15 min"
  detect_wmco_package
  info "Operator: $WMCO_PACKAGE (catalog $WMCO_CATALOG, channel $WMCO_CHANNEL)"

  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $WMCO_NS
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: windows-machine-config-operator
  namespace: $WMCO_NS
spec:
  targetNamespaces:
  - $WMCO_NS
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: windows-machine-config-operator
  namespace: $WMCO_NS
spec:
  channel: "$WMCO_CHANNEL"
  installPlanApproval: Automatic
  name: $WMCO_PACKAGE
  source: $WMCO_CATALOG
  sourceNamespace: openshift-marketplace
EOF
  ok "Namespace, OperatorGroup and Subscription applied"
  wait_for_csv

  oc create secret generic cloud-private-key -n "$WMCO_NS" \
    --from-file=private-key.pem="$SSH_KEY" --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "Secret cloud-private-key created"

  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: windows-instances
  namespace: $WMCO_NS
data:
  $WIN_IP: |-
    username=Administrator
EOF
  ok "ConfigMap windows-instances registers $WIN_IP as a BYOH host"

  local t0 last_min=-1 node=""; t0=$(date +%s)
  local deadline=$(( t0 + NODE_TIMEOUT_MIN * 60 ))
  info "Waiting for WMCO to configure the host and the node to become Ready"
  while :; do
    node=$(oc get nodes -l kubernetes.io/os=windows \
             -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[*].address}{"\n"}{end}' 2>/dev/null \
           | awk -v ip="$WIN_IP" '{for (i=2;i<=NF;i++) if ($i==ip) {print $1; exit}}' || true)
    if [[ -n "$node" ]] && [[ "$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]]; then
      break
    fi
    (( $(date +%s) > deadline )) && {
      hint "oc logs -n $WMCO_NS deploy/windows-machine-config-operator | tail -50"
      die "Windows node did not become Ready within ${NODE_TIMEOUT_MIN} min."
    }
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then
      info "${m} min elapsed - ${node:+node $node registered, waiting for Ready}${node:-WMCO is configuring the Windows host}"
      last_min=$m
    fi
    sleep 15
  done
  WIN_NODE=$node
  ok "Windows node '$WIN_NODE' is Ready ($(elapsed "$t0"))"
}

# ----------------------------------------------------------------------------
# Phase 8: Test workload
# ----------------------------------------------------------------------------
declare -A SEEN_EVENTS=()       # event uid -> last printed count
POD_WARNINGS=0
EVENTS_SINCE_MIN="${EVENTS_SINCE_MIN:-15}"   # first report: only events newer than this

# One progress report: the pod table plus pod events that are new or repeated since
# the last report, with their last time and count (the useful part of
# 'oc describe pod'). The first report skips events older than EVENTS_SINCE_MIN.
# Used by phase 8 and './setup.sh observe-pod'.
pod_progress() {
  info "$1 - pods (oc get pods -n $TEST_NS -o wide):"
  oc get pods -n "$TEST_NS" -l app=iis -o wide 2>/dev/null | cut -c1-150 | sed 's/^/      /' || true

  local first=0 cutoff now hidden=0
  [[ ${#SEEN_EVENTS[@]} -eq 0 ]] && first=1
  now=$(date -u +%s)
  cutoff=$(( now - EVENTS_SINCE_MIN * 60 ))
  local uid cnt ts1 ts2 ev_type ev_reason ev_obj ev_msg ts epoch age
  while IFS='|' read -r uid cnt ts1 ts2 ev_type ev_reason ev_obj ev_msg; do
    [[ -n "$uid" && "$ev_obj" == iis-* ]] || continue
    cnt=${cnt:-1}
    [[ "${SEEN_EVENTS[$uid]:-}" == "$cnt" ]] && continue
    ts=${ts1:-$ts2}
    epoch=$(date -u -d "$ts" +%s 2>/dev/null || echo "$now")
    if (( first )) && (( epoch < cutoff )); then
      SEEN_EVENTS[$uid]=$cnt; hidden=$((hidden + 1)); continue
    fi
    SEEN_EVENTS[$uid]=$cnt
    [[ "$ev_type" == Warning ]] && POD_WARNINGS=1
    age=$(( (now - epoch) / 60 ))
    printf '      event: %4sm ago x%-3s %-7s %-22s %s: %s\n' "$age" "$cnt" "$ev_type" "$ev_reason" "$ev_obj" "$ev_msg"
  done < <(oc get events -n "$TEST_NS" --field-selector involvedObject.kind=Pod \
             --sort-by=.lastTimestamp \
             -o jsonpath='{range .items[*]}{.metadata.uid}{"|"}{.count}{"|"}{.lastTimestamp}{"|"}{.eventTime}{"|"}{.type}{"|"}{.reason}{"|"}{.involvedObject.name}{"|"}{.message}{"\n"}{end}' 2>/dev/null || true)
  (( hidden > 0 )) && info "  ($hidden events older than ${EVENTS_SINCE_MIN} min not shown; EVENTS_SINCE_MIN=600 to see them)"
  return 0
}

# True if an IIS pod got the stale-layer sandbox error after epoch $1
stale_layer_errors_since() {
  local since=$1 ts msg
  while IFS='|' read -r ts msg; do
    [[ -n "$ts" && "$msg" == *0xc0370112* ]] || continue
    (( $(date -u -d "$ts" +%s 2>/dev/null || echo 0) >= since )) && return 0
  done < <(oc get events -n "$TEST_NS" --field-selector reason=FailedCreatePodSandBox \
             -o jsonpath='{range .items[*]}{.lastTimestamp}{"|"}{.message}{"\n"}{end}' 2>/dev/null || true)
  return 1
}

iis_ready() {
  local ready
  ready=$(oc get deploy iis -n "$TEST_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [[ "${ready:-0}" -ge 1 ]]
}

# On demand (any time, also in a second terminal during ./setup.sh - read-only)
observe_pod() {
  ensure_oc_login
  oc get deploy iis -n "$TEST_NS" >/dev/null 2>&1 || die "No IIS deployment in namespace $TEST_NS yet (phase 8 creates it)."
  local t0; t0=$(date +%s)
  info "Observing the IIS pod every minute until it is ready (Ctrl-C to stop - this does not affect the setup)"
  local hinted=0
  while :; do
    pod_progress "$(( ($(date +%s) - t0) / 60 )) min"
    iis_ready && break
    if (( ! hinted && POD_WARNINGS )); then
      info "Warnings above - for a full laptop/OpenShift/Windows check run: ./setup.sh health"
      hinted=1
    fi
    sleep 60
  done
  local ip port
  ip=$(oc get pod -n "$TEST_NS" -l app=iis -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || true)
  port=$(oc get svc iis -n "$TEST_NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
  ok "IIS pod is ready"
  if [[ -n "$ip" && -n "$port" ]]; then
    if curl -fs -m 10 -o /dev/null "http://$ip:$port/"; then ok "IIS responds at http://$ip:$port/"
    else warn "Pod is ready but http://$ip:$port/ did not answer from this host"; fi
  fi
}
deploy_workload() {
  phase 8 "Test IIS workload" "1-2 min + image pull (servercore is ~2GB+)"
  oc apply -f - >/dev/null <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: windows2025
handler: runhcs-wcow-process
scheduling:
  nodeSelector:
    kubernetes.io/os: windows
  tolerations:
  - key: os
    value: Windows
    effect: NoSchedule
---
apiVersion: v1
kind: Namespace
metadata:
  name: $TEST_NS
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: iis
  namespace: $TEST_NS
EOF
  # Grant before the pod exists: Windows pods must not get the Linux UID/SELinux
  # defaults that the restricted SCCs inject.
  oc adm policy add-scc-to-user privileged -z iis -n "$TEST_NS" >/dev/null

  oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iis
  namespace: $TEST_NS
  labels: {app: iis}
spec:
  replicas: 1
  selector:
    matchLabels: {app: iis}
  template:
    metadata:
      labels: {app: iis}
      annotations:
        # Without this, SCC admission prefers the more restrictive restricted-v2,
        # which forces runAsNonRoot=true and the kubelet refuses ContainerAdministrator.
        openshift.io/required-scc: privileged
    spec:
      serviceAccountName: iis
      runtimeClassName: windows2025
      securityContext:
        runAsNonRoot: false
        windowsOptions:
          runAsUserName: ContainerAdministrator
      containers:
      - name: iis
        image: $IIS_IMAGE
        ports:
        - containerPort: 80
        readinessProbe:
          tcpSocket: {port: 80}
          initialDelaySeconds: 10
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: iis
  namespace: $TEST_NS
spec:
  type: NodePort
  selector: {app: iis}
  ports:
  - port: 80
    targetPort: 80
EOF
  ok "RuntimeClass, Deployment and NodePort Service applied in namespace $TEST_NS"

  info "Waiting for the IIS pod (first image pull can take 5-15 min)"
  local t0 last_min=-1; t0=$(date +%s)
  local deadline=$(( t0 + WORKLOAD_TIMEOUT_MIN * 60 ))
  while :; do
    iis_ready && break
    if (( $(date +%s) > deadline )); then
      echo "    --- oc describe pod -n $TEST_NS -l app=iis ---" >&2
      oc describe pod -n "$TEST_NS" -l app=iis 2>&1 | sed 's/^/    /' >&2 || true
      die "IIS pod not ready within ${WORKLOAD_TIMEOUT_MIN} min."
    fi
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then
      pod_progress "${m} min elapsed"
      # Image layers unpacked before a Windows update: reset containerd once, then keep waiting
      if (( ! CONTAINERD_RESET_DONE )) && stale_layer_errors_since "$t0"; then
        warn "Pod sandbox fails with 'PrepareLayer ... unrecognized format (0xc0370112)' - stale image layers"
        reset_containerd auto
        deadline=$(( $(date +%s) + WORKLOAD_TIMEOUT_MIN * 60 ))
      fi
      last_min=$m
    fi
    sleep 15
  done

  local pod_node
  pod_node=$(oc get pod -n "$TEST_NS" -l app=iis -o jsonpath='{.items[0].spec.nodeName}')
  [[ "$pod_node" == "${WIN_NODE:-$pod_node}" ]] && ok "IIS pod running on Windows node $pod_node ($(elapsed "$t0"))" \
    || warn "IIS pod is on $pod_node, expected $WIN_NODE"

  NODE_PORT=$(oc get svc iis -n "$TEST_NS" -o jsonpath='{.spec.ports[0].nodePort}')
  check_iis_http
}

# Phase 8 is only successful when IIS really answers over the NodePort.
# Retries for IIS_HTTP_TIMEOUT_MIN: the Windows NodePort rules (kube-proxy/HNS) can
# lag a little behind pod readiness.
check_iis_http() {
  local url="http://$WIN_IP:$NODE_PORT/" t0 code="" server="" err=""
  t0=$(date +%s)
  info "Checking that IIS answers at $url"
  while :; do
    local hdr
    hdr=$(curl -s -m 10 -D - -o /dev/null "$url" 2>&1) && {
      code=$(awk 'toupper($1) ~ /^HTTP/ {c=$2} END {print c}' <<<"$hdr")
      server=$(awk -F': ' 'tolower($1)=="server" {gsub(/\r/, "", $2); print $2}' <<<"$hdr")
    } || err=$hdr
    if [[ "$code" == 200 ]]; then
      ok "IIS answers at $url (HTTP $code${server:+, Server: $server})"
      return 0
    fi
    (( $(date +%s) - t0 > IIS_HTTP_TIMEOUT_MIN * 60 )) && break
    sleep 10
  done

  # Narrow it down: is IIS itself up (pod IP from inside Windows) or only the NodePort path broken?
  local pod_ip inside=""
  pod_ip=$(oc get pod -n "$TEST_NS" -l app=iis -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
  if [[ -n "$pod_ip" ]]; then
    inside=$(win_ps "try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 http://$pod_ip/).StatusCode } catch { 'error: ' + \$_.Exception.Message }" 2>/dev/null | tr -d '\r')
    info "From Windows to the pod directly (http://$pod_ip/): ${inside:-no answer}"
  fi
  hint "curl -v $url"
  [[ "$inside" == 200 ]] && hint "IIS works inside the node - check kube-proxy / NodePort (Get-Service kube-proxy; hnsdiag list loadbalancers)"
  die "IIS did not answer at $url within ${IIS_HTTP_TIMEOUT_MIN} min (last: ${code:+HTTP $code}${err:+${err:0:120}})."
}

# ----------------------------------------------------------------------------
# Windows container runtime diagnostics (./setup.sh diagnose-windows)
# Read-only, except that crictl is installed into C:\k\tools if missing.
# ----------------------------------------------------------------------------
diagnose_windows() {
  mkdir -p "$WORK_DIR"
  vm_exists || die "VM '$VM_NAME' does not exist."
  WIN_IP="${WIN_IP:-$(discover_ip || true)}"
  [[ -n "$WIN_IP" ]] || die "Could not find the VM's IP address (set WIN_IP=...)."
  win_ssh "echo ok" >/dev/null 2>&1 || die "Cannot SSH to Administrator@$WIN_IP."

  # crictl matching the node's Kubernetes minor (kubelet v1.35.5 -> crictl v1.35.0)
  local kv crictl_ver="v1.35.0"
  if oc whoami >/dev/null 2>&1 || { (ensure_oc_login) >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; }; then
    kv=$(oc get nodes -l kubernetes.io/os=windows -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
    [[ "$kv" =~ ^(v[0-9]+\.[0-9]+)\. ]] && crictl_ver="${BASH_REMATCH[1]}.0"
  fi

  cat > "$WORK_DIR/wmco-diag.ps1" <<'PSEOF'
param([string]$CrictlVersion)
$ErrorActionPreference = 'SilentlyContinue'
function H($t) { ''; "=== $t ===" }

H 'Windows'
$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"Build: $($v.CurrentBuild).$($v.UBR)   Last boot: $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime)"
"Containers feature: $((Get-WindowsFeature Containers).InstallState)"

H 'Container filter drivers (fltmc)'
fltmc | Select-String 'wcifs|bindflt|UnionFS|Filter Name'
foreach ($d in 'wcifs', 'bindflt') { "{0,-8} service: {1}" -f $d, (Get-Service $d).Status }

H 'Node services'
Get-Service containerd, kubelet, hybrid-overlay-node, kube-proxy, windows_exporter | Format-Table Name, Status, StartType -AutoSize | Out-String -Width 200

H 'containerd configuration'
$confPath = 'C:\k\containerd\containerd_conf.toml'
$conf = Get-Content $confPath -Raw
if ($conf) {
  Get-Content $confPath | Select-String '^\s*(root|state)\s*=|snapshotter|sandbox_image' | ForEach-Object { $_.Line.Trim() }
} else { "not found: $confPath" }
$root = [regex]::Match([string]$conf, '(?m)^\s*root\s*=\s*"([^"]+)"').Groups[1].Value -replace '\\\\', '\'
if (-not $root) { $root = 'C:\ProgramData\containerd\root' }
"root: $root"

H 'containerd storage'
$snap = Join-Path $root 'io.containerd.snapshotter.v1.windows\snapshots'
"snapshots dir: $snap"
"unpacked layers (snapshots): $((Get-ChildItem $snap -Directory | Measure-Object).Count)"
"content blobs: $((Get-ChildItem (Join-Path $root 'io.containerd.content.v1.content\blobs\sha256') -File | Measure-Object).Count)"
Get-ChildItem (Split-Path $root) -Directory | Where-Object Name -like 'root.bad-*' | ForEach-Object { "set-aside storage: $($_.FullName)" }

H 'crictl images / pods'
$crictl = 'C:\k\tools\crictl.exe'
if (-not (Test-Path $crictl)) {
  "installing crictl $CrictlVersion into C:\k\tools"
  New-Item -ItemType Directory -Force C:\k\tools | Out-Null
  $url = "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CrictlVersion/crictl-$CrictlVersion-windows-amd64.tar.gz"
  Invoke-WebRequest -UseBasicParsing $url -OutFile C:\k\tools\crictl.tgz
  tar -xf C:\k\tools\crictl.tgz -C C:\k\tools
}
if (Test-Path $crictl) {
  $ep = '--runtime-endpoint=npipe:////./pipe/containerd-containerd'
  & $crictl $ep '--image-endpoint=npipe:////./pipe/containerd-containerd' --timeout 60s images 2>$null
  ''
  & $crictl $ep --timeout 60s pods 2>$null
} else { 'crictl not available' }

H 'HNS networks (hnsdiag)'
hnsdiag list networks 2>$null

H 'Recent container errors in C:\var\log (last 24h, newest 10 per file)'
$pat = 'PrepareLayer|0xc037|hcs::|hcsshim|unpack|snapshot|failed to create shim|level=error'
Get-ChildItem C:\var\log -Recurse -File -Include *.log, *.txt | Where-Object LastWriteTime -gt (Get-Date).AddDays(-1) | ForEach-Object {
  $m = Select-String -Path $_.FullName -Pattern $pat | Select-Object -Last 10
  if ($m) { "--- $($_.FullName)"; $m | ForEach-Object { $_.Line.Substring(0, [math]::Min(300, $_.Line.Length)) } }
}
PSEOF
  info "Collecting container runtime diagnostics from Administrator@$WIN_IP (read-only)"
  scp "${SSH_OPTS[@]}" -q "$WORK_DIR/wmco-diag.ps1" "Administrator@$WIN_IP:C:/wmco-diag.ps1" \
    || die "Could not copy the diagnostics script to the VM."
  win_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\wmco-diag.ps1 $crictl_ver" | tr -d '\r'
}

# ----------------------------------------------------------------------------
CONTAINERD_RESET_DONE=0
containerd_has_layers() {
  local n
  n=$(win_ps "if (Get-Service containerd -ErrorAction SilentlyContinue) { (Get-ChildItem 'C:\ProgramData\containerd\root\io.containerd.snapshotter.v1.windows\snapshots' -Directory -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }" 2>/dev/null | tr -d '\r')
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 ))
}

# Reset containerd storage on the Windows node (./setup.sh reset-containerd)
# Moves the storage folder aside (not deleted, so it can be restored) so every image
# is downloaded and unpacked fresh - e.g. after layers unpacked on an older Windows
# build fail with "hcsshim::PrepareLayer ... unrecognized format (0xc0370112)".
# ----------------------------------------------------------------------------
reset_containerd() {  # [auto] = called from setup phases: no prompt, no follow-up hints
  local mode=${1:-}
  mkdir -p "$WORK_DIR"
  vm_exists || die "VM '$VM_NAME' does not exist."
  WIN_IP="${WIN_IP:-$(discover_ip || true)}"
  [[ -n "$WIN_IP" ]] || die "Could not find the VM's IP address (set WIN_IP=...)."
  win_ssh "echo ok" >/dev/null 2>&1 || die "Cannot SSH to Administrator@$WIN_IP."
  ensure_oc_login

  echo "${C_B}Reset containerd storage on $VM_NAME ($WIN_IP)${C_0}"
  info "Moves C:\\ProgramData\\containerd\\root aside (kept as root.bad-<time>) and restarts containerd + kubelet."
  info "All images on the node are downloaded again (IIS is ~2.4GB, ~15 min)."
  if [[ "$FORCE" != "1" && "$mode" != auto ]]; then
    [[ -t 0 ]] || die "Not interactive - run with FORCE=1 to confirm."
    local answer; read -r -p "    Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "Aborted"; return 0; }
  fi

  # 1. Nothing may use the images while the storage is moved
  local replicas=""
  if oc get deploy iis -n "$TEST_NS" >/dev/null 2>&1; then
    replicas=$(oc get deploy iis -n "$TEST_NS" -o jsonpath='{.spec.replicas}')
    [[ "$replicas" =~ ^[0-9]+$ ]] && (( replicas > 0 )) || replicas=1
    oc scale deploy iis -n "$TEST_NS" --replicas=0 >/dev/null
    info "Scaled IIS to 0 (was $replicas); waiting for its pods to go away"
    local t0; t0=$(date +%s)
    while [[ -n "$(oc get pods -n "$TEST_NS" -l app=iis -o name 2>/dev/null)" ]]; do
      if (( $(date +%s) - t0 > 300 )); then
        warn "IIS pods still present after 5 min - force-deleting them"
        oc delete pods -n "$TEST_NS" -l app=iis --force --grace-period=0 >/dev/null 2>&1 || true
        break
      fi
      sleep 5
    done
    ok "IIS pods gone"
  fi

  # 2. Stop services, move the storage folder aside, start services
  cat > "$WORK_DIR/wmco-reset-containerd.ps1" <<'PSEOF'
$ErrorActionPreference = 'Stop'
$conf = Get-Content C:\k\containerd\containerd_conf.toml -Raw
$root = [regex]::Match($conf, '(?m)^\s*root\s*=\s*"([^"]+)"').Groups[1].Value -replace '\\\\', '\'
if (-not $root) { $root = 'C:\ProgramData\containerd\root' }
"containerd root: $root"
Stop-Service kubelet -Force
Stop-Service containerd -Force
if (Test-Path $root) {
  $leaf = (Split-Path $root -Leaf) + '.bad-' + (Get-Date -Format yyyyMMddHHmmss)
  Rename-Item -Path $root -NewName $leaf
  "moved aside to: $(Join-Path (Split-Path $root) $leaf)"
} else { "root folder not present - nothing to move" }
Start-Service containerd
Start-Service kubelet
Get-Service containerd, kubelet | ForEach-Object { "service $($_.Name): $($_.Status)" }
PSEOF
  scp "${SSH_OPTS[@]}" -q "$WORK_DIR/wmco-reset-containerd.ps1" "Administrator@$WIN_IP:C:/wmco-reset-containerd.ps1" \
    || die "Could not copy the reset script to the VM."
  local out
  if ! out=$(win_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\wmco-reset-containerd.ps1" 2>&1 | tr -d '\r'); then
    sed 's/^/      /' <<<"$out" >&2
    hint "Make sure the services run again: ssh -i $SSH_KEY Administrator@$WIN_IP powershell Start-Service containerd,kubelet"
    die "Resetting containerd failed."
  fi
  sed 's/^/      /' <<<"$out"
  grep -q 'service containerd: Running' <<<"$out" && grep -q 'service kubelet: Running' <<<"$out" \
    || die "containerd/kubelet are not running after the reset."
  ok "containerd storage reset"

  # 3. Node Ready again, then bring IIS back
  local node t0
  node=$(oc get nodes -l kubernetes.io/os=windows -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$node" ]]; then
    t0=$(date +%s)
    until [[ "$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]; do
      (( $(date +%s) - t0 > 300 )) && { warn "Node $node not Ready after 5 min"; break; }
      sleep 10
    done
    ok "Node $node Ready"
  fi
  if [[ -n "$replicas" ]]; then
    oc scale deploy iis -n "$TEST_NS" --replicas="$replicas" >/dev/null
    ok "Scaled IIS back to $replicas"
    [[ "$mode" == auto ]] || info "Watch it come up: ./setup.sh observe-pod"
  fi
  info "The old storage folder can be deleted once IIS works (shown by ./setup.sh diagnose-windows)."
  CONTAINERD_RESET_DONE=1
}

# ----------------------------------------------------------------------------
# Health check (./setup.sh health): one snapshot of laptop, OpenShift, Windows, workload
# ----------------------------------------------------------------------------
H_FAIL=0; H_WARN=0
h_section() { echo; echo "${C_B}$1${C_0}"; }
h_line() {  # status(ok|warn|fail|info) name detail
  local icon
  case "$1" in
    ok)   icon="${C_G}✔${C_0}" ;;
    warn) icon="${C_Y}⚠${C_0}"; H_WARN=$((H_WARN + 1)) ;;
    fail) icon="${C_R}✘${C_0}"; H_FAIL=$((H_FAIL + 1)) ;;
    *)    icon="${C_C}•${C_0}" ;;
  esac
  printf '  %s %-34s %s\n' "$icon" "$2" "$3"
}
h_free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}'; }
h_disk() {  # path label
  [[ -d "$1" ]] || return 0
  local gb; gb=$(h_free_gb "$1")
  if   (( gb < 10 )); then h_line fail "$2" "${gb}GB free ($1)"
  elif (( gb < 25 )); then h_line warn "$2" "${gb}GB free ($1)"
  else h_line ok "$2" "${gb}GB free ($1)"; fi
}

# All Windows checks in one SSH round trip; prints key=value lines
h_windows_probe() {  # api_host api_port
  cat > "$WORK_DIR/wmco-health.ps1" <<'PSEOF'
param([string]$ApiHost, [int]$ApiPort)
$ErrorActionPreference = 'SilentlyContinue'
$v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"build=$($v.CurrentBuild).$($v.UBR)"
$os = Get-CimInstance Win32_OperatingSystem
"lastboot=$($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))"
"mem_free_mb=$([math]::Round($os.FreePhysicalMemory/1024))"
$pr = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
      (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
"pending_reboot=$pr"
$t = schtasks /Query /TN wmco-wu /FO CSV /NH 2>$null
"wu_task=$(if ($t) { ($t -split '","')[2].Trim('"') } else { 'none' })"
$l = Get-Content C:\wmco-wu.log -Tail 1
"wu_last=$(if ($l) { $l.Substring([math]::Min(20, $l.Length)) } else { '' })"
$d = Get-Disk -Number 0
"disk_readonly=$($d.IsReadOnly)"
"disk_status=$($d.OperationalStatus)"
"c_free_gb=$([math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 1))"
foreach ($s in 'containerd', 'kubelet', 'hybrid-overlay-node', 'kube-proxy') {
  $x = Get-Service $s
  "svc_$s=$(if ($x) { $x.Status } else { 'missing' })"
}
"hns_overlay=$([bool](hnsdiag list networks 2>$null | Select-String 'OVNKubernetesHybridOverlayNetwork'))"
$ok = $false
try { $tc = New-Object Net.Sockets.TcpClient; $ok = $tc.ConnectAsync($ApiHost, $ApiPort).Wait(3000); $tc.Close() } catch { }
"api_reachable=$ok"
PSEOF
  scp "${SSH_OPTS[@]}" -q "$WORK_DIR/wmco-health.ps1" "Administrator@$WIN_IP:C:/wmco-health.ps1" 2>/dev/null || return 1
  win_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\wmco-health.ps1 $1 $2" 2>/dev/null | tr -d '\r'
}

health() {
  mkdir -p "$WORK_DIR"
  echo "${C_B}WMCO lab health check${C_0}  ($(date '+%Y-%m-%d %H:%M'))"

  # ---------------- Laptop ----------------
  h_section "Laptop"
  h_disk "$IMG_DIR" "Disk (VM images)"
  h_disk "$HOME/.crc" "Disk (crc)"
  local avail_mb; avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  if   (( avail_mb < 1024 )); then h_line fail "Memory" "${avail_mb}MB available"
  elif (( avail_mb < 2048 )); then h_line warn "Memory" "${avail_mb}MB available"
  else h_line ok "Memory" "$((avail_mb / 1024))GB available"; fi
  local load cpus; load=$(cut -d' ' -f1 /proc/loadavg); cpus=$(nproc)
  if awk -v l="$load" -v c="$cpus" 'BEGIN {exit !(l > 2 * c)}'; then h_line warn "CPU load" "$load (1 min) on $cpus CPUs"
  else h_line ok "CPU load" "$load (1 min) on $cpus CPUs"; fi
  local nets; nets=$(virsh_ net-list --name 2>/dev/null || true)
  local net=${LIBVIRT_NET:-}
  [[ -z "$net" && -z "$BRIDGE" ]] && { grep -qx crc <<<"$nets" && net=crc || net=default; }
  if [[ -n "$BRIDGE" ]]; then
    ip link show "$BRIDGE" >/dev/null 2>&1 && h_line ok "Network" "bridge $BRIDGE" || h_line fail "Network" "bridge $BRIDGE missing"
  elif grep -qx "$net" <<<"$nets"; then h_line ok "Network" "libvirt '$net' active"
  else h_line fail "Network" "libvirt '$net' not active"; fi
  local st
  if command -v crc >/dev/null; then
    st=$(virsh_ domstate crc 2>/dev/null | head -1 || true)
    [[ "$st" == running ]] && h_line ok "VM crc" "running" || h_line fail "VM crc" "${st:-not defined}"
  fi
  st=$(virsh_ domstate "$VM_NAME" 2>/dev/null | head -1 || true)
  [[ "$st" == running ]] && h_line ok "VM $VM_NAME" "running" || h_line fail "VM $VM_NAME" "${st:-not defined}"
  if [[ "$st" == running ]]; then
    local be; be=$(virsh_ domblkerror "$VM_NAME" 2>/dev/null || true)
    [[ -z "$be" || "$be" == *"No errors"* ]] && h_line ok "VM disk errors" "none" || h_line fail "VM disk errors" "$be"
  fi

  # ---------------- OpenShift ----------------
  h_section "OpenShift"
  local logged_in=0
  if command -v crc >/dev/null; then
    local cs os ram
    cs=$(crc_field crcStatus); os=$(crc_field openshiftStatus); ram=$(crc_field ramUsage)
    if [[ "$os" == Running ]]; then h_line ok "crc" "VM $cs, OpenShift $os, RAM $(( ${ram:-0} / 1024 / 1024 / 1024 ))GB in use"
    elif [[ "$cs" == Running && "$ram" =~ ^[0-9]+$ ]] && (( ram > 0 && ram < 2 * 1024 * 1024 * 1024 )); then
      h_line fail "crc" "VM running but OpenShift '$os' with $(( ram / 1024 / 1024 ))MB RAM - run: crc stop && crc start"
    else h_line fail "crc" "VM ${cs:-?}, OpenShift ${os:-?}"; fi
  fi
  if oc whoami >/dev/null 2>&1 || { (ensure_oc_login) >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; }; then
    logged_in=1
    h_line ok "oc login" "$(oc whoami) @ $(oc whoami --show-server)"
  else
    h_line fail "oc login" "not logged in"
  fi
  local want=""
  if (( logged_in )); then
    local cv; cv=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
    h_line info "Cluster version" "${cv:-unknown}"
    local bad
    bad=$(oc get co -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Available")].status}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null \
          | awk '$2 != "True" || $3 == "True" {printf "%s%s", sep, $1; sep=", "}' || true)
    [[ -z "$bad" ]] && h_line ok "Cluster operators" "all available, none degraded" || h_line warn "Cluster operators" "not healthy: $bad"
    local name ready
    while read -r name ready; do
      [[ -n "$name" ]] || continue
      [[ "$ready" == True ]] && h_line ok "Node $name" "Ready" || h_line fail "Node $name" "Ready=$ready"
    done < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null || true)
    local ho; ho=$(oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.hybridOverlayConfig}' 2>/dev/null || true)
    [[ -n "$ho" ]] && h_line ok "Hybrid overlay" "configured" || h_line fail "Hybrid overlay" "not configured"
    local csv phase_
    csv=$(oc get subscription -n "$WMCO_NS" windows-machine-config-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    phase_=$( [[ -n "$csv" ]] && oc get csv -n "$WMCO_NS" "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$phase_" == Succeeded ]] && h_line ok "WMCO operator" "$csv" || h_line fail "WMCO operator" "${csv:-not installed} ${phase_}"
    local inst; inst=$(oc get cm windows-instances -n "$WMCO_NS" -o jsonpath='{.data}' 2>/dev/null || true)
    [[ -n "$inst" ]] && h_line ok "windows-instances" "$inst" || h_line warn "windows-instances" "ConfigMap missing"
    [[ -z "${WIN_IP:-}" && "$inst" =~ \"([0-9.]+)\" ]] && WIN_IP=${BASH_REMATCH[1]}
  fi

  # ---------------- Windows ----------------
  h_section "Windows ($VM_NAME)"
  [[ -z "${WIN_IP:-}" ]] && vm_exists && WIN_IP=$(discover_ip || true)
  want=$(image_ubr)
  if [[ -z "${WIN_IP:-}" ]]; then
    h_line fail "IP address" "unknown (VM not running or no DHCP lease)"
  elif ! win_ssh "echo ok" >/dev/null 2>&1; then
    h_line fail "SSH" "Administrator@$WIN_IP not reachable"
  else
    h_line ok "SSH" "Administrator@$WIN_IP"
    local api host port probe
    api=$( (( logged_in )) && oc get infrastructure cluster -o jsonpath='{.status.apiServerInternalURI}' 2>/dev/null || echo "https://api-int.crc.testing:6443")
    host=${api#https://}; port=${host##*:}; host=${host%%:*}
    probe=$(h_windows_probe "$host" "$port" || true)
    pv() { sed -n "s/^$1=//p" <<<"$probe" | head -1; }
    local b ubr; b=$(pv build); ubr=${b##*.}
    if [[ -n "$want" && "$ubr" =~ ^[0-9]+$ ]] && (( ubr >= want )); then h_line ok "Windows build" "$b (image needs .$want)"
    elif [[ -n "$want" ]]; then h_line fail "Windows build" "$b older than image build .$want - run ./setup.sh (phase 6)"
    else h_line warn "Windows build" "$b (image build unknown)"; fi
    h_line info "Last boot" "$(pv lastboot)"
    local mf; mf=$(pv mem_free_mb)
    [[ "${mf:-0}" =~ ^[0-9]+$ ]] && (( mf < 512 )) && h_line warn "Memory" "${mf}MB free" || h_line ok "Memory" "${mf:-?}MB free"
    [[ "$(pv pending_reboot)" == True ]] && h_line warn "Pending reboot" "yes - Windows Update needs a restart" || h_line ok "Pending reboot" "no"
    local wt; wt=$(pv wu_task)
    if [[ "$wt" == Running ]]; then h_line warn "Windows Update task" "running: $(pv wu_last)  (./setup.sh stop-windows-updates)"
    else h_line ok "Windows Update task" "${wt:-none} (not running)"; fi
    [[ "$(pv disk_readonly)" == False && "$(pv disk_status)" == Online ]] && h_line ok "Disk" "writable, $(pv disk_status)" \
      || h_line fail "Disk" "read-only=$(pv disk_readonly) status=$(pv disk_status)"
    local cf; cf=$(pv c_free_gb); cf=${cf%%.*}
    if   [[ "$cf" =~ ^[0-9]+$ ]] && (( cf < 5 ));  then h_line fail "C: free" "${cf}GB"
    elif [[ "$cf" =~ ^[0-9]+$ ]] && (( cf < 10 )); then h_line warn "C: free" "${cf}GB"
    else h_line ok "C: free" "${cf:-?}GB"; fi
    local svc sv
    for svc in containerd kubelet hybrid-overlay-node kube-proxy; do
      sv=$(pv "svc_$svc")
      [[ "$sv" == Running ]] && h_line ok "Service $svc" "Running" || h_line fail "Service $svc" "${sv:-unknown}"
    done
    [[ "$(pv hns_overlay)" == True ]] && h_line ok "Pod network (HNS)" "OVNKubernetesHybridOverlayNetwork present" \
      || h_line fail "Pod network (HNS)" "OVNKubernetesHybridOverlayNetwork missing (normal for a few min after reboot)"
    [[ "$(pv api_reachable)" == True ]] && h_line ok "Cluster API from Windows" "$host:$port reachable" \
      || h_line fail "Cluster API from Windows" "$host:$port not reachable"
  fi

  # ---------------- Workload ----------------
  h_section "Workload ($TEST_NS)"
  if (( logged_in )) && oc get deploy iis -n "$TEST_NS" >/dev/null 2>&1; then
    iis_ready && h_line ok "IIS deployment" "ready" || h_line fail "IIS deployment" "not ready"
    oc get pods -n "$TEST_NS" -l app=iis -o wide 2>/dev/null | cut -c1-150 | sed 's/^/      /' || true
    local cutoff warn_lines
    cutoff=$(( $(date -u +%s) - 15 * 60 ))
    warn_lines=$(oc get events -n "$TEST_NS" --field-selector type=Warning --sort-by=.lastTimestamp \
        -o jsonpath='{range .items[*]}{.lastTimestamp}{"|"}{.count}{"|"}{.reason}{"|"}{.involvedObject.name}{"|"}{.message}{"\n"}{end}' 2>/dev/null \
      | while IFS='|' read -r ts cnt reason obj msg; do
          [[ -n "$ts" ]] || continue
          (( $(date -u -d "$ts" +%s 2>/dev/null || echo 0) >= cutoff )) || continue
          printf '      %s x%s %s %s: %s\n' "${ts#*T}" "${cnt:-1}" "$reason" "$obj" "$msg" | cut -c1-240
        done || true)
    if [[ -n "$warn_lines" ]]; then
      h_line warn "Warning events (15 min)" "$(grep -c . <<<"$warn_lines")"
      tail -5 <<<"$warn_lines"
      if grep -qE 'PrepareLayer|hcs::|hcsshim|0xc037' <<<"$warn_lines"; then
        h_line info "Container runtime errors" "details: ./setup.sh diagnose-windows; layer errors: ./setup.sh reset-containerd"
      fi
    else
      h_line ok "Warning events (15 min)" "none"
    fi
    local port ip
    port=$(oc get svc iis -n "$TEST_NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
    ip=${WIN_IP:-}
    if [[ -n "$port" && -n "$ip" ]]; then
      curl -fs -m 10 -o /dev/null "http://$ip:$port/" && h_line ok "IIS HTTP" "http://$ip:$port/ responds" \
        || h_line fail "IIS HTTP" "http://$ip:$port/ no response"
    fi
  else
    h_line info "IIS deployment" "not deployed yet"
  fi

  echo
  if (( H_FAIL )); then echo "${C_R}${C_B}Health: $H_FAIL failed, $H_WARN warnings${C_0}"; return 1
  elif (( H_WARN )); then echo "${C_Y}${C_B}Health: OK with $H_WARN warnings${C_0}"
  else echo "${C_G}${C_B}Health: all checks passed${C_0}"; fi
}

# ----------------------------------------------------------------------------
# Summary / status
# ----------------------------------------------------------------------------
summary() {
  echo
  echo "${C_G}${C_B}━━━ Setup complete in $(elapsed) ━━━${C_0}"
  cat <<EOF

  Windows VM
    Name:      $VM_NAME
    IP:        $WIN_IP
    SSH:       ssh -i $SSH_KEY Administrator@$WIN_IP
    RDP:       $WIN_IP:3389   (Administrator / $WIN_PASSWORD)
    Console:   virt-viewer -c $LIBVIRT_URI $VM_NAME

  OpenShift
    Node:      ${WIN_NODE:-?}
    Check:     oc get nodes -l kubernetes.io/os=windows -o wide

  Test workload
    Pods:      oc get pods -n $TEST_NS -o wide
    URL:       http://$WIN_IP:${NODE_PORT:-<nodeport>}/

  Remove everything:  ./setup.sh cleanup
EOF
}

status() {
  echo "VM:"; virsh_ dominfo "$VM_NAME" 2>/dev/null | grep -E 'Name|State' || echo "  not defined"
  vm_exists && { echo "IP: $(discover_ip || echo unknown)"; }
  echo; echo "Windows nodes:"; oc get nodes -l kubernetes.io/os=windows -o wide 2>/dev/null || true
  echo; echo "WMCO:"; oc get csv -n "$WMCO_NS" 2>/dev/null || true
  echo; echo "Workload:"; oc get pods,svc -n "$TEST_NS" -o wide 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
cleanup() {
  echo "${C_B}Cleaning up WMCO lab (ISO is preserved: $WIN_ISO)${C_0}"
  if oc whoami >/dev/null 2>&1; then
    info "Removing test workload"
    oc delete ns "$TEST_NS" --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || warn "namespace $TEST_NS deletion timed out"
    oc delete runtimeclass windows2025 --ignore-not-found >/dev/null 2>&1 || true

    if oc get cm windows-instances -n "$WMCO_NS" >/dev/null 2>&1; then
      info "Deregistering BYOH host (WMCO deconfigures the node)"
      oc delete cm windows-instances -n "$WMCO_NS" >/dev/null
      local t0; t0=$(date +%s)
      while [[ -n "$(oc get nodes -l kubernetes.io/os=windows -o name 2>/dev/null)" ]]; do
        (( $(date +%s) - t0 > 600 )) && { warn "Windows node still present after 10 min, deleting it"; \
          oc delete nodes -l kubernetes.io/os=windows --wait=false >/dev/null 2>&1 || true; break; }
        sleep 10
      done
    fi
    oc delete nodes -l kubernetes.io/os=windows --ignore-not-found >/dev/null 2>&1 || true

    info "Removing WMCO operator"
    local csv
    csv=$(oc get subscription -n "$WMCO_NS" windows-machine-config-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    oc delete subscription -n "$WMCO_NS" windows-machine-config-operator --ignore-not-found >/dev/null 2>&1 || true
    [[ -n "$csv" ]] && oc delete csv -n "$WMCO_NS" "$csv" --ignore-not-found >/dev/null 2>&1 || true
    oc delete ns "$WMCO_NS" --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || warn "namespace $WMCO_NS deletion timed out"
    ok "OpenShift resources removed"
  else
    warn "oc not logged in - skipping OpenShift cleanup"
  fi

  if vm_exists; then
    info "Removing VM $VM_NAME"
    local mac; mac=$(vm_mac || true)
    [[ "$(vm_state)" == "shut off" ]] || virsh_ destroy "$VM_NAME" >/dev/null 2>&1 || true
    virsh_ undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh_ undefine "$VM_NAME" >/dev/null
    if [[ -z "$BRIDGE" && -n "$mac" ]]; then
      local entry
      entry=$(virsh_ net-dumpxml "$LIBVIRT_NET" | grep -o "<host mac='$mac'[^>]*/>" || true)
      [[ -n "$entry" ]] && virsh_ net-update "$LIBVIRT_NET" delete ip-dhcp-host "$entry" --live --config >/dev/null 2>&1 || true
    fi
    ok "VM undefined"
  fi
  # Delete only our own disk and config ISO - never the Windows ISO
  for f in "$VM_DISK" "$CONFIG_ISO"; do
    [[ -e "$f" ]] && { sudo rm -f "$f"; ok "Deleted $f"; }
  done
  virsh_ pool-refresh default >/dev/null 2>&1 || true
  if [[ -d "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; ok "Deleted $WORK_DIR"; fi
  echo "${C_G}${C_B}Cleanup complete.${C_0}"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  case "${1:-setup}" in
    spawn-vm-pod)
      exec "$SCRIPT_DIR/spawn-vm-pod.sh"
      ;;
    setup|"")
      inhibit_sleep "$@"
      trap 'FAIL_LINE=$LINENO' ERR
      trap on_exit EXIT
      ensure_libvirt_group "$@"
      echo "${C_B}Windows Server 2025 + OpenShift WMCO (BYOH) automated setup${C_0}"
      echo "Estimated total time: 25-40 minutes"
      sudo_keepalive
      check_prereqs
      ensure_iso
      create_vm
      wait_for_ip
      wait_for_access
      update_windows
      deploy_wmco
      deploy_workload
      summary
      ;;
    cleanup)
      ensure_libvirt_group "$@"
      sudo_keepalive
      cleanup
      ;;
    status)
      ensure_libvirt_group "$@"
      status
      ;;
    observe-pod)
      observe_pod
      ;;
    health)
      ensure_libvirt_group "$@"
      health
      ;;
    diagnose-windows)
      ensure_libvirt_group "$@"
      diagnose_windows
      ;;
    reset-containerd)
      ensure_libvirt_group "$@"
      reset_containerd
      ;;
    stop-windows-updates)
      ensure_libvirt_group "$@"
      stop_updates
      ;;
    -h|--help|help)
      awk 'NR > 1 && !/^#/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "$0"
      ;;
    *)
      die "Unknown command '$1'. Usage: $0 [setup|cleanup|status|health|diagnose-windows|reset-containerd|observe-pod|stop-windows-updates|spawn-vm-pod]"
      ;;
  esac
}

# Only run main if not being sourced
if [[ "${_SOURCING:-0}" != "1" && "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
