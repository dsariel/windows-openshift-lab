#!/usr/bin/env bash
#
# setup.sh - Automated Windows Server 2025 + OpenShift WMCO (BYOH) setup
#
#   ./setup.sh           Run the full automated setup
#   ./setup.sh cleanup   Remove the VM and all OpenShift resources (keeps the ISO)
#   ./setup.sh status    Show VM / node / workload status
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

# Timeouts (minutes)
INSTALL_TIMEOUT_MIN="${INSTALL_TIMEOUT_MIN:-75}"
NODE_TIMEOUT_MIN="${NODE_TIMEOUT_MIN:-40}"
CRC_API_WAIT_MIN="${CRC_API_WAIT_MIN:-10}"
WORKLOAD_TIMEOUT_MIN="${WORKLOAD_TIMEOUT_MIN:-40}"

TOTAL_PHASES=7
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

Write-Host '==> Avoid surprise reboots from Windows Update during setup'
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
# Phase 6: WMCO + BYOH registration
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
  phase 6 "OpenShift integration (WMCO BYOH)" "5-15 min"
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
# Phase 7: Test workload
# ----------------------------------------------------------------------------
deploy_workload() {
  phase 7 "Test IIS workload" "1-2 min + image pull (servercore is ~2GB+)"
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
    spec:
      serviceAccountName: iis
      runtimeClassName: windows2025
      securityContext:
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
    local ready
    ready=$(oc get deploy iis -n "$TEST_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    [[ "${ready:-0}" -ge 1 ]] && break
    (( $(date +%s) > deadline )) && {
      hint "oc describe pod -n $TEST_NS -l app=iis"
      die "IIS pod not ready within ${WORKLOAD_TIMEOUT_MIN} min."
    }
    local m=$(( ($(date +%s) - t0) / 60 ))
    if (( m != last_min )); then
      local reason
      reason=$(oc get pod -n "$TEST_NS" -l app=iis -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
      info "${m} min elapsed - pod ${reason:-pending}"
      last_min=$m
    fi
    sleep 15
  done

  local pod_node
  pod_node=$(oc get pod -n "$TEST_NS" -l app=iis -o jsonpath='{.items[0].spec.nodeName}')
  [[ "$pod_node" == "${WIN_NODE:-$pod_node}" ]] && ok "IIS pod running on Windows node $pod_node ($(elapsed "$t0"))" \
    || warn "IIS pod is on $pod_node, expected $WIN_NODE"

  NODE_PORT=$(oc get svc iis -n "$TEST_NS" -o jsonpath='{.spec.ports[0].nodePort}')
  if curl -fs -m 10 -o /dev/null "http://$WIN_IP:$NODE_PORT/"; then
    ok "IIS responds at http://$WIN_IP:$NODE_PORT/"
  else
    warn "Could not reach http://$WIN_IP:$NODE_PORT/ from this host (may be a routing/firewall matter)"
  fi
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
    -h|--help|help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *)
      die "Unknown command '$1'. Usage: $0 [setup|cleanup|status]"
      ;;
  esac
}

main "$@"
