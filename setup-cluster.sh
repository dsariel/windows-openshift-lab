#!/usr/bin/env bash
#
# setup-cluster.sh - Local OpenShift cluster (OpenShift Local / CRC) ready for WMCO BYOH
#
#   ./setup-cluster.sh           Create and start the cluster, log in, enable hybrid overlay
#   ./setup-cluster.sh cleanup   Stop and delete the cluster
#   ./setup-cluster.sh status    Show cluster status
#
# Afterwards run ./setup.sh. It attaches the Windows VM to the same libvirt
# network ("crc") so the cluster and the Windows node can reach each other.
#
# Requires a Red Hat pull secret (free account):
#   https://console.redhat.com/openshift/create/local
# Save it as ./pull-secret.txt or set PULL_SECRET_FILE=/path/to/pull-secret.
#
# Every setting below can be overridden from the environment.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CRC_MEMORY_MB="${CRC_MEMORY_MB:-12288}"     # CRC minimum is 10752
CRC_CPUS="${CRC_CPUS:-4}"
CRC_DISK_GB="${CRC_DISK_GB:-40}"
WIN_VM_RAM_MB="${VM_RAM_MB:-8192}"          # what setup.sh will use for Windows (resource check)
PULL_SECRET_FILE="${PULL_SECRET_FILE:-$SCRIPT_DIR/pull-secret.txt}"
CRC_VERSION="${CRC_VERSION:-latest}"        # crc release to download, e.g. 2.64.0 (ships OpenShift 4.22.14)
CRC_URL="${CRC_URL:-https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/crc/$CRC_VERSION/crc-linux-amd64.tar.xz}"
MIN_OCP_VERSION="${MIN_OCP_VERSION:-4.22}"  # WMCO 10.22+ (Windows Server 2025 support) needs OpenShift 4.22+
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
HYBRID_CIDR="${HYBRID_CIDR:-10.132.0.0/14}"
HYBRID_HOST_PREFIX="${HYBRID_HOST_PREFIX:-23}"
FORCE="${FORCE:-0}"                         # 1 = ignore the memory check

TOTAL_PHASES=5
START_TS=$(date +%s)

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

on_exit() {
  local rc=$?
  [[ $rc -eq 0 ]] && return
  echo >&2
  echo "${C_R}${C_B}Cluster setup failed during phase: $CURRENT_PHASE (exit $rc)${C_0}" >&2
  echo "Troubleshooting:" >&2
  echo "  - crc status / crc logs:   crc status; crc start --log-level debug" >&2
  echo "  - Re-running ./setup-cluster.sh is safe." >&2
  echo "  - Start over:              ./setup-cluster.sh cleanup && ./setup-cluster.sh" >&2
}

export PATH="$BIN_DIR:$HOME/.crc/bin/oc:$PATH"

# ----------------------------------------------------------------------------
# Phase 1: Host checks
# ----------------------------------------------------------------------------
check_host() {
  phase 1 "Host checks" "<1 min"
  [[ $EUID -ne 0 ]] || die "Run as a regular user (crc refuses to run as root); it uses sudo when needed."
  [[ -e /dev/kvm ]] || die "/dev/kvm not present - enable hardware virtualization in BIOS."
  systemctl is-active --quiet NetworkManager || die "NetworkManager must be running (required by crc)."
  command -v curl >/dev/null || die "curl is required."

  local mem_mb cpus need_mb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  cpus=$(nproc)
  need_mb=$(( CRC_MEMORY_MB + WIN_VM_RAM_MB + 2048 ))
  info "Host: ${cpus} CPUs, $((mem_mb/1024))GB RAM"
  info "Plan: cluster ${CRC_CPUS} CPUs/$((CRC_MEMORY_MB/1024))GB + Windows VM $((WIN_VM_RAM_MB/1024))GB + ~2GB for the host"
  if (( mem_mb < need_mb )); then
    warn "Not enough RAM: need ~$((need_mb/1024))GB, host has $((mem_mb/1024))GB."
    hint "Lower it, e.g. CRC_MEMORY_MB=10752 VM_RAM_MB=4096 (tight), or use a bigger host."
    [[ "$FORCE" == "1" ]] || die "Aborting (set FORCE=1 to continue anyway)."
  else
    ok "Memory OK"
  fi
  (( cpus >= CRC_CPUS )) || die "Host has $cpus CPUs, cluster wants $CRC_CPUS (set CRC_CPUS)."

  local free_gb; free_gb=$(df -Pk "$HOME" | awk 'NR==2{print int($4/1024/1024)}')
  (( free_gb >= CRC_DISK_GB )) || warn "Only ${free_gb}GB free in \$HOME; the cluster disk may grow to ${CRC_DISK_GB}GB."

  if [[ ! -s "$PULL_SECRET_FILE" ]]; then
    warn "Pull secret not found at $PULL_SECRET_FILE"
    hint "Download it from https://console.redhat.com/openshift/create/local"
    if [[ -t 0 ]]; then
      local p; read -r -p "    Path to pull secret file: " p
      p="${p/#\~/$HOME}"
      [[ -s "$p" ]] || die "File '$p' not found."
      PULL_SECRET_FILE="$p"
    else
      die "Set PULL_SECRET_FILE=/path/to/pull-secret and re-run."
    fi
  fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))["auths"]' "$PULL_SECRET_FILE" 2>/dev/null \
    || die "$PULL_SECRET_FILE is not a valid pull secret (JSON with an \"auths\" key)."
  ok "Pull secret: $PULL_SECRET_FILE"
}

# ----------------------------------------------------------------------------
# Phase 2: crc binary + configuration
# ----------------------------------------------------------------------------
# OpenShift version bundled with the crc binary on PATH ("OpenShift version: 4.22.14")
crc_ocp_version() { crc version 2>/dev/null | awk -F': *' '/OpenShift version/ {print $2; exit}'; }
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

download_crc() {
  info "Downloading crc ($CRC_VERSION) from $CRC_URL"
  mkdir -p "$BIN_DIR"
  local tmp; tmp=$(mktemp -d)
  curl -fL --retry 3 --progress-bar "$CRC_URL" -o "$tmp/crc.tar.xz"
  tar -xJf "$tmp/crc.tar.xz" -C "$tmp"
  install -m 0755 "$(find "$tmp" -type f -name crc | head -1)" "$BIN_DIR/crc"
  rm -rf "$tmp"
  hash -r
}

install_crc() {
  phase 2 "Install OpenShift Local (crc)" "1-3 min"
  local ocp=""
  command -v crc >/dev/null && ocp=$(crc_ocp_version)
  if [[ -z "$ocp" ]]; then
    download_crc
    ocp=$(crc_ocp_version)
  elif ! version_ge "$ocp" "$MIN_OCP_VERSION"; then
    warn "Installed crc ($(command -v crc)) bundles OpenShift $ocp; need >= $MIN_OCP_VERSION"
    download_crc
    ocp=$(crc_ocp_version)
    [[ "$(command -v crc)" == "$BIN_DIR/crc" ]] || die "An older crc at $(command -v crc) shadows $BIN_DIR/crc - remove it."
  fi
  version_ge "$ocp" "$MIN_OCP_VERSION" \
    || die "crc $CRC_VERSION bundles OpenShift $ocp (< $MIN_OCP_VERSION). Set CRC_VERSION to a newer release."
  ok "crc $(crc version | awk -F': *' '/CRC version/ {print $2; exit}') with OpenShift $ocp"

  # An existing cluster created from an older bundle must be recreated
  if [[ -d "$HOME/.crc/machines/crc" ]] && ! crc_running; then
    local cur; cur=$(crc status -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("openshiftVersion",""))' 2>/dev/null || true)
    if [[ -n "$cur" ]] && ! version_ge "$cur" "$MIN_OCP_VERSION"; then
      die "Existing crc cluster is OpenShift $cur. Run './setup-cluster.sh cleanup' first to recreate it with $ocp."
    fi
  fi

  crc config set consent-telemetry no        >/dev/null
  crc config set preset openshift            >/dev/null
  crc config set network-mode system         >/dev/null   # libvirt "crc" network, reachable by the Windows VM
  crc config set memory "$CRC_MEMORY_MB"     >/dev/null
  crc config set cpus "$CRC_CPUS"            >/dev/null
  crc config set disk-size "$CRC_DISK_GB"    >/dev/null
  crc config set pull-secret-file "$PULL_SECRET_FILE" >/dev/null
  ok "crc configured (preset openshift, system networking, ${CRC_CPUS} CPU / $((CRC_MEMORY_MB/1024))GB / ${CRC_DISK_GB}GB)"

  info "Running 'crc setup' (may ask for your sudo password; first run downloads a ~4GB bundle)"
  crc setup
  ok "crc setup complete"
}

# ----------------------------------------------------------------------------
# Phase 3: Start cluster + login
# ----------------------------------------------------------------------------
crc_running() { crc status -o json 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("openshiftStatus")=="Running" else 1)'; }

start_cluster() {
  phase 3 "Start OpenShift cluster" "10-20 min on first start"
  if crc_running; then
    ok "Cluster already running"
  else
    local t0; t0=$(date +%s)
    crc start
    ok "Cluster started ($(elapsed "$t0"))"
  fi

  # oc from the bundle, if none installed
  if ! command -v oc >/dev/null || [[ "$(command -v oc)" == "$HOME/.crc/bin/oc/oc" ]]; then
    mkdir -p "$BIN_DIR"
    ln -sf "$HOME/.crc/bin/oc/oc" "$BIN_DIR/oc"
    ok "oc linked to $BIN_DIR/oc"
  fi

  local creds user pass api
  creds=$(crc console --credentials -o json)
  user=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["clusterConfig"]["adminCredentials"]["username"])' <<<"$creds")
  pass=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["clusterConfig"]["adminCredentials"]["password"])' <<<"$creds")
  api=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["clusterConfig"]["url"])' <<<"$creds")
  oc login -u "$user" -p "$pass" "$api" --insecure-skip-tls-verify=true >/dev/null
  oc auth can-i '*' '*' --all-namespaces >/dev/null || die "Logged in as $user but not cluster-admin."
  ok "Logged in as $user (cluster-admin) at $api"

  local cv; cv=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
  version_ge "$cv" "$MIN_OCP_VERSION" || die "Cluster runs OpenShift $cv; need >= $MIN_OCP_VERSION. Run cleanup and retry."
  ok "OpenShift $cv"

  info "Waiting for cluster operators to settle"
  oc wait co --all --for=condition=Available=True --timeout=15m >/dev/null \
    || warn "Some cluster operators are not Available yet: oc get co"
}

# ----------------------------------------------------------------------------
# Phase 4: Hybrid overlay networking
# ----------------------------------------------------------------------------
enable_hybrid_overlay() {
  phase 4 "Hybrid overlay networking" "2-5 min"
  local net_type ho
  net_type=$(oc get network.config cluster -o jsonpath='{.status.networkType}')
  [[ "$net_type" == "OVNKubernetes" ]] || die "Cluster network type is '$net_type'; WMCO requires OVNKubernetes."

  ho=$(oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.hybridOverlayConfig}')
  if [[ -n "$ho" ]]; then
    ok "Hybrid overlay already configured: $ho"
    return
  fi
  info "Patching network operator: hybridClusterNetwork $HYBRID_CIDR (hostPrefix $HYBRID_HOST_PREFIX)"
  oc patch network.operator.openshift.io cluster --type=merge -p \
    "{\"spec\":{\"defaultNetwork\":{\"ovnKubernetesConfig\":{\"hybridOverlayConfig\":{\"hybridClusterNetwork\":[{\"cidr\":\"$HYBRID_CIDR\",\"hostPrefix\":$HYBRID_HOST_PREFIX}]}}}}}" >/dev/null

  local t0; t0=$(date +%s)
  info "Waiting for OVN-Kubernetes to roll out with hybrid overlay"
  sleep 30
  oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes --timeout=15m >/dev/null \
    || warn "ovnkube-node rollout not finished: oc get pods -n openshift-ovn-kubernetes"
  oc wait co/network --for=condition=Degraded=False --timeout=10m >/dev/null \
    || warn "network operator reports Degraded: oc get co network"
  ok "Hybrid overlay enabled ($(elapsed "$t0"))"
}

# ----------------------------------------------------------------------------
# Phase 5: Summary
# ----------------------------------------------------------------------------
summary() {
  phase 5 "Ready for WMCO" ""
  local ip; ip=$(crc ip 2>/dev/null || echo "?")
  ok "Cluster node IP: $ip (libvirt network 'crc')"
  oc get nodes -o wide | sed 's/^/    /'
  echo
  echo "${C_G}${C_B}━━━ Cluster ready in $(elapsed) ━━━${C_0}"
  cat <<EOF

  Console:     $(crc console --url 2>/dev/null || echo https://console-openshift-console.apps-crc.testing)
  Credentials: crc console --credentials
  oc:          $(command -v oc)   (logged in as kubeadmin)

  Next step:   ./setup.sh          # Windows VM joins on the 'crc' libvirt network
  Remove:      ./setup-cluster.sh cleanup
EOF
  if [[ ":$PATH:" != *":$BIN_DIR:"* ]] || ! grep -qs "$BIN_DIR" "$HOME/.bashrc" "$HOME/.profile" 2>/dev/null; then
    echo
    hint "Add $BIN_DIR to PATH in new shells: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
  fi
}

status() {
  command -v crc >/dev/null || { echo "crc not installed"; return; }
  crc status || true
  echo; oc get nodes -o wide 2>/dev/null || true
  echo; echo "Hybrid overlay: $(oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.hybridOverlayConfig}' 2>/dev/null || echo unknown)"
}

cleanup() {
  echo "${C_B}Removing the OpenShift Local cluster${C_0}"
  command -v crc >/dev/null || { ok "crc not installed - nothing to do"; return; }
  if virsh -q -c qemu:///system dominfo win2025-wmco >/dev/null 2>&1; then
    warn "The Windows VM still exists; run ./setup.sh cleanup first to deregister it cleanly."
  fi
  crc stop >/dev/null 2>&1 || true
  crc delete -f >/dev/null 2>&1 || true
  ok "Cluster deleted (crc binary, cached bundle and pull secret kept; 'crc cleanup' reverts host changes)"
}

main() {
  case "${1:-setup}" in
    setup|"")
      trap on_exit EXIT
      echo "${C_B}OpenShift Local cluster setup for WMCO${C_0}"
      echo "Estimated total time: 15-30 minutes (first run downloads ~4GB)"
      check_host
      install_crc
      start_cluster
      enable_hybrid_overlay
      summary
      ;;
    cleanup) cleanup ;;
    status)  status ;;
    -h|--help|help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "Unknown command '$1'. Usage: $0 [setup|cleanup|status]" ;;
  esac
}

main "$@"
