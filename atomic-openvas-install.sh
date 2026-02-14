#!/usr/bin/env bash
# atomic-openvas-install.sh
# AlmaLinux 9.x - Install OpenVAS via Atomicorp (interactive prompts allowed)
#
# Handles Atomicorp requirement: SELinux must be DISABLED for openvas-setup.
# Will:
#  - install atomic + openvas
#  - attempt openvas-setup
#  - if it fails due to SELinux enabled, it will set SELinux=disabled, add selinux=0 kernel arg, reboot
#  - after reboot, re-run script; it resumes and runs openvas-setup

set -Eeuo pipefail

LOG="/var/log/openvas-install.log"
ALT_LOG="/var/log/openvas_vm_build.log"
STATE_DIR="/var/lib/openvas_vm_build"
STATE_FILE="$STATE_DIR/state.env"
INSTALLER="/tmp/atomic-installer.sh"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root: sudo -i; then bash $0" >&2
    exit 1
  fi
}

setup_logs() {
  mkdir -p /var/log "$STATE_DIR"
  touch "$LOG"
  chmod 600 "$LOG"

  if [[ -e "$ALT_LOG" && ! -L "$ALT_LOG" ]]; then
    mv -f "$ALT_LOG" "${ALT_LOG}.$(date +%s).bak"
  fi
  ln -sfn "$LOG" "$ALT_LOG"
}

start_logging() {
  exec > >(tee -a "$LOG") 2>&1
}

ts() { date -Is; }
step() { echo -e "\n[$(ts)] === $* ==="; }

run() {
  local desc="$1"; shift
  local cmd="$*"
  step "$desc"
  echo "[$(ts)] CMD: $cmd"
  bash -lc "$cmd"
}

confirm() {
  local q="$1"
  echo
  read -r -p "$q [y/N]: " ans || true
  [[ "${ans,,}" == "y" ]]
}

selinux_mode() {
  if command -v getenforce >/dev/null 2>&1; then
    getenforce || true
  else
    echo "unknown"
  fi
}

save_state() {
  cat >"$STATE_FILE" <<EOF
PHASE="${PHASE}"
EOF
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
  : "${PHASE:=start}"
}

disable_selinux_persistently() {
  step "Disabling SELinux persistently (required by Atomicorp openvas-setup)"
  echo "[$(ts)] Current SELinux runtime: $(selinux_mode)"

  # 1) /etc/selinux/config
  run "Set SELINUX=disabled in /etc/selinux/config" \
    "sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true"

  # 2) Kernel arg (most reliable)
  if command -v grubby >/dev/null 2>&1; then
    # Add selinux=0 to ALL kernels
    run "Add kernel arg selinux=0 (grubby --update-kernel=ALL)" \
      "grubby --update-kernel=ALL --args='selinux=0' || true"
  else
    step "WARN: grubby not found; cannot automatically set kernel arg selinux=0"
    echo "Install grubby or add selinux=0 to GRUB_CMDLINE_LINUX manually."
  fi

  step "SELinux disabled settings applied. A reboot is required."
}

# ----------------------------
# Main
# ----------------------------
need_root
setup_logs
start_logging
load_state

step "Starting Atomicorp OpenVAS install (phase: $PHASE)"
echo "Logs:"
echo " - $LOG"
echo " - $ALT_LOG (symlink)"
echo "State: $STATE_FILE"

# Phase 1: base install
if [[ "$PHASE" == "start" ]]; then
  if confirm "Run system update (dnf -y update) first?"; then
    run "System update" "dnf -y update"
  else
    step "Skipping system update"
  fi

  run "Install dnf plugins core (config-manager)" "dnf -y install dnf-plugins-core"

  if confirm "Enable CRB repo (recommended on Alma/RHEL 9 for dependencies)?"; then
    run "Enable CRB" "dnf config-manager --set-enabled crb"
  else
    step "CRB not enabled (user choice)"
  fi

  if confirm "Install EPEL (can help resolve dependencies)?"; then
    run "Install EPEL" "dnf -y install epel-release"
  else
    step "EPEL not installed (user choice)"
  fi

  run "Install base dependencies" \
"dnf -y install wget curl gnupg2 gcc gcc-c++ make cmake \
 glib2 glib2-devel libxml2 libxml2-devel libpcap libpcap-devel \
 libgcrypt libgcrypt-devel libssh libssh-devel gnutls gnutls-devel \
 redis postgresql-server postgresql python3 python3-pip openssl-devel systemd-devel nano grubby"

  run "Enable & start PostgreSQL + Redis (best effort)" \
'if [[ ! -d /var/lib/pgsql/data/base ]]; then postgresql-setup --initdb || true; fi; systemctl enable --now postgresql || true; systemctl enable --now redis || true'

  run "Download Atomicorp installer to $INSTALLER" \
"curl -fsSL https://updates.atomicorp.com/installers/atomic -o '$INSTALLER' && chmod +x '$INSTALLER'"

  step "Run Atomicorp installer (interactive)"
  echo "[$(ts)] If it prompts for terms, type: yes"
  echo "[$(ts)] CMD: bash '$INSTALLER'"
  bash "$INSTALLER"

  run "dnf clean all + makecache" "dnf -y clean all && dnf -y makecache"
  run "Install OpenVAS via Atomicorp" "dnf -y install openvas"

  PHASE="setup"
  save_state
fi

# Phase 2: openvas-setup (may require SELinux disabled)
if [[ "$PHASE" == "setup" ]]; then
  step "Run openvas-setup (may be interactive)"
  echo "[$(ts)] SELinux runtime: $(selinux_mode)"
  echo "[$(ts)] CMD: openvas-setup"

  set +e
  openvas-setup
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    # Detect the specific Atomicorp SELinux message (from your output)
    if grep -qiE "selinux must be disabled" "$LOG"; then
      step "Detected Atomicorp requirement: SELinux must be DISABLED (not Permissive/Enforcing)."
      if confirm "Apply required SELinux disable + reboot now?"; then
        disable_selinux_persistently
        PHASE="postreboot_setup"
        save_state
        step "Rebooting now. After reboot, re-run: bash $0"
        reboot
      else
        step "Not applying SELinux disable. openvas-setup cannot proceed."
        exit 1
      fi
    else
      step "openvas-setup failed (rc=$rc). Check log: $LOG"
      exit "$rc"
    fi
  fi

  # If setup succeeded
  PHASE="feeds"
  save_state
fi

# Phase 3: feeds (best effort)
if [[ "$PHASE" == "postreboot_setup" ]]; then
  # After reboot, ensure runtime is actually disabled (getenforce might still exist but should show Disabled)
  step "Post-reboot: retry openvas-setup"
  echo "[$(ts)] SELinux runtime: $(selinux_mode)"
  echo "[$(ts)] CMD: openvas-setup"
  openvas-setup

  PHASE="feeds"
  save_state
fi

if [[ "$PHASE" == "feeds" ]]; then
  if command -v greenbone-feed-sync >/dev/null 2>&1; then
    run "Run greenbone-feed-sync --all (best effort)" "greenbone-feed-sync --all"
  else
    step "greenbone-feed-sync not found (may be normal depending on packaging). Skipping."
  fi

  PHASE="done"
  save_state
fi

step "Summary"
ip -4 addr show | awk '/inet /{print $2"  "$NF}' | head -n 12 || true
echo
echo "Logs:"
echo " - $LOG"
echo " - $ALT_LOG"
echo "State file: $STATE_FILE"
echo "Phase: $PHASE"

if [[ "$PHASE" == "done" ]]; then
  step "Done"
  exit 0
fi

exit 0
