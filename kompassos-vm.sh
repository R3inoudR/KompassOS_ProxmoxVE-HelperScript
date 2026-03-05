#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# KompassOS (HWE) VM Helper Script for Proxmox VE
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This script creates a KompassOS VM in Proxmox VE and attaches the HWE installer ISO.

source /dev/stdin <<<"$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)"

set -euo pipefail

# --- UI / Formatting (community style) ---
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
TAB=" "
HOLD=" "
CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"

function msg_info() { local msg="$1"; echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}${CL}"; }
function msg_ok()   { local msg="$1"; echo -e "${BFR}${CM}${GN}${msg}${CL}"; }
function msg_error(){ local msg="$1"; echo -e "${BFR}${CROSS}${RD}${msg}${CL}"; }

function header_info() {
  clear
  cat <<"EOF"
 _  __                            ____   _____
| |/ /___  _ __ ___  _ __   __ _ / ___| | ____|
| ' // _ \| '_ ` _ \| '_ \ / _` | |  _  |  _|
| . \ (_) | | | | | | |_) | (_| | |_| | | |___
|_|\_\___/|_| |_| |_| .__/ \__,_|\____| |_____|
                     |_|

KompassOS (HWE) VM Installer for Proxmox VE
EOF
}

function die() { msg_error "$1"; echo -e "\nExiting..."; sleep 1; exit 1; }

# --- Telemetry / script identity (used by api.func) ---
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="kompassos-hwe-vm"
var_os="kompassos"
var_version="hwe"

# --- Traps / error handling ---
function error_handler() {
  local exit_code="$?"
  local line_number="${1:-unknown}"
  local command="${2:-unknown}"
  post_update_to_api "failed" "${exit_code}" || true
  echo -e "\n${RD}[ERROR]${CL} line ${RD}${line_number}${CL}: exit code ${RD}${exit_code}${CL} while executing: ${YW}${command}${CL}\n"
  cleanup_vmid || true
  exit "${exit_code}"
}
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap 'cleanup' EXIT
trap 'post_update_to_api "failed" "130" || true; cleanup_vmid || true; exit 130' SIGINT
trap 'post_update_to_api "failed" "143" || true; cleanup_vmid || true; exit 143' SIGTERM

# --- Temp workspace ---
TEMP_DIR="$(mktemp -d)"
pushd "$TEMP_DIR" >/dev/null

function cleanup() {
  local exit_code=$?
  popd >/dev/null || true
  rm -rf "$TEMP_DIR" || true
  if [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]]; then
    if [[ $exit_code -eq 0 ]]; then
      post_update_to_api "done" "none" || true
    else
      post_update_to_api "failed" "$exit_code" || true
    fi
  fi
}

# --- Hardcoded: only HWE build (per request) ---
BASE_URL="https://isos.kompassos.nl"
ISO_NAME="kompassos-dx-hwe.iso"
ISO_URL="${BASE_URL}/${ISO_NAME}"
SUM_URL="${BASE_URL}/${ISO_NAME}-CHECKSUM"

# --- Safety checks (community conventions) ---
function check_root() {
  if [[ "$(id -u)" -ne 0 || "$(ps -o comm= -p "$PPID")" == "sudo" ]]; then
    clear
    msg_error "Please run this script as root (not via sudo)."
    echo -e "\nExiting..."
    sleep 2
    exit 1
  fi
}

function arch_check() {
  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    echo -e "\n${TAB}${YW}This script is intended for amd64 Proxmox VE (no PiMox/ARM).${CL}\n"
    exit 1
  fi
}

function pve_check() {
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    ((MINOR >= 0 && MINOR <= 9)) || die "Unsupported Proxmox VE version: ${PVE_VER} (supported 8.0–8.9)"
    return 0
  fi
  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    ((MINOR >= 0 && MINOR <= 1)) || die "Unsupported Proxmox VE version: ${PVE_VER} (supported 9.0–9.1)"
    return 0
  fi
  die "Unsupported Proxmox VE version: ${PVE_VER} (supported 8.x or 9.0–9.1)"
}

function ssh_check() {
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    if ! whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno \
      --title "SSH DETECTED" \
      --yesno "It's suggested to use the Proxmox host shell instead of SSH.\nProceed anyway?" 10 62; then
      header_info
      die "User exited script"
    fi
  fi
}

function exit_script() {
  header_info
  die "User exited script"
}

function get_valid_nextid() {
  local try_id
  try_id="$(pvesh get /cluster/nextid)"
  while true; do
    if [[ -f "/etc/pve/qemu-server/${try_id}.conf" || -f "/etc/pve/lxc/${try_id}.conf" ]]; then
      try_id=$((try_id + 1)); continue
    fi
    if lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1)); continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
    qm stop "$VMID" &>/dev/null || true
    qm destroy "$VMID" &>/dev/null || true
  fi
}

# --- Storage selection (community style) ---
function pick_storage_menu() {
  # $1: content type (images|iso), $2: title, $3: prompt
  local CONTENT="$1"
  local TITLE="$2"
  local PROMPT="$3"

  local MENU=()
  local MSG_MAX_LENGTH=0

  while read -r line; do
    local TAG TYPE FREE ITEM OFFSET
    TAG="$(echo "$line" | awk '{print $1}')"
    TYPE="$(echo "$line" | awk '{printf "%-10s", $2}')"
    FREE="$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf("%9sB", $6)}')"
    ITEM=" Type: $TYPE Free: $FREE "
    OFFSET=2
    if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH} ]]; then
      MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
    fi
    MENU+=("$TAG" "$ITEM" "OFF")
  done < <(pvesm status -content "$CONTENT" | awk 'NR>1')

  local VALID
  VALID="$(pvesm status -content "$CONTENT" | awk 'NR>1')"
  [[ -n "$VALID" ]] || die "Unable to detect a valid storage location for content '$CONTENT'."

  local COUNT
  COUNT=$((${#MENU[@]} / 3))
  if [[ "$COUNT" -eq 1 ]]; then
    echo "${MENU[0]}"
    return 0
  fi

  local CHOICE=""
  while [[ -z "${CHOICE:-}" ]]; do
    CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "$TITLE" \
      --radiolist "$PROMPT\nTo make a selection, use the Spacebar.\n" \
      16 $((MSG_MAX_LENGTH + 23)) 6 \
      "${MENU[@]}" 3>&1 1>&2 2>&3) || exit_script
  done
  echo "$CHOICE"
}

function ensure_iso_dir_storage() {
  # ISO storage must be a 'dir' storage type for /iso/ file placement.
  local ST="$1"
  local ST_TYPE
  ST_TYPE="$(pvesm status -storage "$ST" | awk 'NR>1 {print $2}')"
  if [[ "$ST_TYPE" != "dir" ]]; then
    die "Selected ISO storage '$ST' is type '$ST_TYPE'. ISO storage must be a 'dir' storage (e.g. local)."
  fi
}

# --- Settings (default / advanced) ---
VMID="$(get_valid_nextid)"
HN="kompassos"
MACHINE="q35"
UEFI="yes"
CPU_MODEL="kvm64"
CORE_COUNT="4"
RAM_SIZE="8192"     # MiB
DISK_SIZE="64G"
DISK_CACHE=""       # e.g. cache=writethrough,
BRG="vmbr0"
VLAN=""
MTU=""
START_VM="yes"
VERIFY_SUM="yes"

function default_settings() {
  METHOD="default"
  VMID="$(get_valid_nextid)"
  HN="kompassos"
  MACHINE="q35"
  UEFI="yes"
  CPU_MODEL="kvm64"
  CORE_COUNT="4"
  RAM_SIZE="8192"
  DISK_SIZE="64G"
  DISK_CACHE=""
  BRG="vmbr0"
  VLAN=""
  MTU=""
  START_VM="yes"
  VERIFY_SUM="yes"

  header_info
  echo -e "${TAB}${GN}Using Default Settings:${CL}\n"
  echo -e "${TAB}${BL}VMID:${CL}      ${VMID}"
  echo -e "${TAB}${BL}Hostname:${CL}  ${HN}"
  echo -e "${TAB}${BL}Machine:${CL}   ${MACHINE}"
  echo -e "${TAB}${BL}UEFI/OVMF:${CL} ${UEFI}"
  echo -e "${TAB}${BL}CPU model:${CL} ${CPU_MODEL}"
  echo -e "${TAB}${BL}Cores:${CL}     ${CORE_COUNT}"
  echo -e "${TAB}${BL}RAM:${CL}       ${RAM_SIZE} MiB"
  echo -e "${TAB}${BL}Disk:${CL}      ${DISK_SIZE}"
  echo -e "${TAB}${BL}Bridge:${CL}    ${BRG}"
  echo -e "${TAB}${BL}Checksum:${CL}  ${VERIFY_SUM}"
  echo -e "${TAB}${BL}Start VM:${CL}  ${START_VM}\n"

  whiptail --backtitle "Proxmox VE Helper Scripts" --title "READY" \
    --yesno "Ready to create the KompassOS (HWE) VM with default settings?" 10 70 \
    || exit_script
}

function advanced_settings() {
  METHOD="advanced"
  header_info

  local v

  v=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "VIRTUAL MACHINE ID" \
    --inputbox "Set Virtual Machine ID" 8 58 "$VMID" 3>&1 1>&2 2>&3) || exit_script
  VMID="${v:-$(get_valid_nextid)}"
  if qm status "$VMID" &>/dev/null || pct status "$VMID" &>/dev/null; then
    die "ID $VMID is already in use."
  fi

  v=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "HOSTNAME" \
    --inputbox "Set Hostname" 8 58 "$HN" 3>&1 1>&2 2>&3) || exit_script
  HN="$(echo "${v:-kompassos}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  [[ -n "$HN" ]] || HN="kompassos"

  local mach
  mach=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" \
    --radiolist "Choose machine type" 10 58 2 \
    "q35" "Recommended" ON \
    "i440fx" "Legacy" OFF \
    3>&1 1>&2 2>&3) || exit_script
  MACHINE="$mach"

  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "FIRMWARE" \
    --yesno "Use UEFI/OVMF (recommended)?" 10 58; then
    UEFI="yes"
  else
    UEFI="no"
  fi

  local cpu
  cpu=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU MODEL" \
    --radiolist "Choose CPU model" 10 58 2 \
    "kvm64" "Default" ON \
    "host" "Host passthrough" OFF \
    3>&1 1>&2 2>&3) || exit_script
  CPU_MODEL="$cpu"

  v=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU CORES" \
    --inputbox "Allocate CPU cores" 8 58 "$CORE_COUNT" 3>&1 1>&2 2>&3) || exit_script
  CORE_COUNT="${v:-4}"

  v=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "RAM" \
    --inputbox "Allocate RAM in MiB" 8 58 "$RAM_SIZE" 3>&1 1>&2 2>&3) || exit_script
  RAM_SIZE="${v:-8192}"

  v=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK SIZE" \
    --inputbox "Disk size (e.g. 64G, 100G)" 8 58 "$DISK_SIZE" 3>&1 1>&2 2>&3) || exit_script
  DISK_SIZE="$(echo "${v:-64G}" | tr -d ' ')"

  local cache_choice
  cache_choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" \
    --radiolist "Choose disk cache mode" 10 58 2 \
    "none" "Default" ON \
    "writethrough" "Write Through" OFF \
    3>&1 1>&2 2>&3) || exit_script
  if [[ "$cache_choice" == "writethrough" ]]; then
    DISK_CACHE="cache=writethrough,"
  else
    DISK_CACHE=""
  fi

  v=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "BRIDGE" \
    --inputbox "Set network bridge" 8 58 "$BRG" 3>&1 1>&2 2>&3) || exit_script
  BRG="${v:-vmbr0}"

  v=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "VLAN" \
    --inputbox "Set VLAN tag (leave blank for default)" 8 58 "" 3>&1 1>&2 2>&3) || exit_script
  if [[ -n "$v" ]]; then VLAN=",tag=$v"; else VLAN=""; fi

  v=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MTU" \
    --inputbox "Set MTU (leave blank for default)" 8 58 "" 3>&1 1>&2 2>&3) || exit_script
  if [[ -n "$v" ]]; then MTU=",mtu=$v"; else MTU=""; fi

  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "CHECKSUM" \
    --yesno "Verify ISO checksum (best-effort)?" 10 58; then
    VERIFY_SUM="yes"
  else
    VERIFY_SUM="no"
  fi

  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VM" \
    --yesno "Start VM when completed?" 10 58; then
    START_VM="yes"
  else
    START_VM="no"
  fi

  header_info
  echo -e "${TAB}${GN}Advanced Settings Summary:${CL}\n"
  echo -e "${TAB}${BL}VMID:${CL}      ${VMID}"
  echo -e "${TAB}${BL}Hostname:${CL}  ${HN}"
  echo -e "${TAB}${BL}Machine:${CL}   ${MACHINE}"
  echo -e "${TAB}${BL}UEFI/OVMF:${CL} ${UEFI}"
  echo -e "${TAB}${BL}CPU model:${CL} ${CPU_MODEL}"
  echo -e "${TAB}${BL}Cores:${CL}     ${CORE_COUNT}"
  echo -e "${TAB}${BL}RAM:${CL}       ${RAM_SIZE} MiB"
  echo -e "${TAB}${BL}Disk:${CL}      ${DISK_SIZE}"
  echo -e "${TAB}${BL}Bridge:${CL}    ${BRG}"
  echo -e "${TAB}${BL}Checksum:${CL}  ${VERIFY_SUM}"
  echo -e "${TAB}${BL}Start VM:${CL}  ${START_VM}\n"

  whiptail --backtitle "Proxmox VE Helper Scripts" --title "READY" \
    --yesno "Ready to create the KompassOS (HWE) VM using the above settings?" 10 76 \
    || advanced_settings
}

function start_menu() {
  header_info
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "KompassOS (HWE) VM" \
    --yesno "This will create a New KompassOS (HWE) VM.\nProceed?" 10 62; then
    :
  else
    exit_script
  fi

  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" \
    --yesno "Use Default Settings?" --no-button "Advanced" 10 58; then
    default_settings
  else
    advanced_settings
  fi
}

# --- Main flow ---
check_root
arch_check
pve_check
ssh_check
start_menu

# Telemetry hook (api.func)
post_to_api_vm

header_info

msg_info "Selecting VM disk storage"
VM_STORAGE="$(pick_storage_menu "images" "Storage Pools" "Which storage pool would you like to use for ${HN}?")"
msg_ok "Using ${BL}${VM_STORAGE}${GN} for VM disk storage."

msg_info "Selecting ISO storage"
ISO_STORAGE="$(pick_storage_menu "iso" "ISO Storage" "Where should the KompassOS ISO be stored?")"
ensure_iso_dir_storage "$ISO_STORAGE"
msg_ok "Using ${BL}${ISO_STORAGE}${GN} for ISO storage."

# Resolve actual ISO path
msg_info "Resolving ISO path"
ISO_PATH="$(pvesm path "${ISO_STORAGE}:iso/${ISO_NAME}")"
msg_ok "ISO path: ${BL}${ISO_PATH}${GN}"

# Download ISO (if missing)
if [[ ! -f "$ISO_PATH" ]]; then
  msg_info "Downloading KompassOS (HWE) ISO"
  mkdir -p "$(dirname "$ISO_PATH")"
  curl -f#SL -o "$ISO_PATH" "$ISO_URL"
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${BL}${ISO_NAME}${GN}"
else
  msg_ok "ISO already exists: ${BL}${ISO_NAME}${GN}"
fi

# Best-effort checksum verify
if [[ "$VERIFY_SUM" == "yes" ]]; then
  if command -v sha256sum >/dev/null 2>&1; then
    msg_info "Downloading checksum (best-effort)"
    if curl -fsSL -o checksum.txt "$SUM_URL"; then
      echo -en "\e[1A\e[0K"
      EXPECTED="$(grep -Eo '([a-fA-F0-9]{64})' checksum.txt | head -n1 || true)"
      if [[ -n "${EXPECTED:-}" ]]; then
        msg_info "Verifying SHA256"
        ACTUAL="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
        if [[ "${ACTUAL,,}" != "${EXPECTED,,}" ]]; then
          die "Checksum mismatch for ${ISO_NAME}"
        fi
        echo -en "\e[1A\e[0K"
        msg_ok "Checksum OK"
      else
        msg_ok "Checksum format not recognized, skipping verify"
      fi
    else
      echo -en "\e[1A\e[0K"
      msg_ok "Checksum download failed, skipping verify"
    fi
  else
    msg_ok "sha256sum not found, skipping verify"
  fi
else
  msg_ok "Checksum verification disabled"
fi

# Storage type handling (thin/discard on block storages)
THIN="discard=on,ssd=1,"
STORAGE_TYPE="$(pvesm status -storage "$VM_STORAGE" | awk 'NR>1 {print $2}')"
case "$STORAGE_TYPE" in
  nfs|dir|btrfs) THIN="" ;;
  *) : ;;
esac

# Build qm args
CPU_ARG=""
[[ "$CPU_MODEL" == "host" ]] && CPU_ARG="-cpu host"

MACHINE_ARG=""
[[ "$MACHINE" == "q35" ]] && MACHINE_ARG="-machine q35"

BIOS_ARG=""
[[ "$UEFI" == "yes" ]] && BIOS_ARG="-bios ovmf"

msg_info "Creating KompassOS (HWE) VM"

qm create "$VMID" \
  -agent 1 \
  ${MACHINE_ARG} \
  -tablet 0 \
  -localtime 1 \
  ${BIOS_ARG} \
  ${CPU_ARG} \
  -cores "$CORE_COUNT" \
  -memory "$RAM_SIZE" \
  -name "$HN" \
  -tags "kompassos" \
  -net0 "virtio,bridge=${BRG}${VLAN}${MTU}" \
  -onboot 1 \
  -ostype l26 \
  -scsihw virtio-scsi-pci \
  >/dev/null

# Allocate EFI vars disk (only when UEFI is enabled)
if [[ "$UEFI" == "yes" ]]; then
  DISK0="vm-${VMID}-disk-0"
  pvesm alloc "$VM_STORAGE" "$VMID" "$DISK0" 4M >/dev/null
  qm set "$VMID" -efidisk0 "${VM_STORAGE}:${DISK0}" >/dev/null
fi

# Main disk (scsi0)
qm set "$VMID" -scsi0 "${VM_STORAGE}:${DISK_SIZE},${DISK_CACHE}${THIN}iothread=1" >/dev/null

# Attach ISO
qm set "$VMID" -ide2 "${ISO_STORAGE}:iso/${ISO_NAME},media=cdrom" >/dev/null

# Boot + console
qm set "$VMID" -boot "order=scsi0;ide2" -serial0 socket -vga virtio >/dev/null

# Set a KompassOS-focused description (no community-scripts links)
DESCRIPTION=$(cat <<'EOF'
<div align='center'>

<h2>KompassOS (HWE) VM</h2>

<p>Creates a KompassOS (HWE) VM and attaches the installer ISO.</p>

<a href='https://www.kompassos.nl/' target='_blank' rel='noopener noreferrer'>
  <img src='https://img.shields.io/badge/KompassOS-Website-3b82f6?style=for-the-badge' />
</a>

<a href='https://github.com/L0g0ff/KompassOS' target='_blank' rel='noopener noreferrer'>
  <img src='https://img.shields.io/badge/GitHub-L0g0ff%2FKompassOS-111827?style=for-the-badge' />
</a>

<a href='https://isos.kompassos.nl/' target='_blank' rel='noopener noreferrer'>
  <img src='https://img.shields.io/badge/ISOs-isos.kompassos.nl-22c55e?style=for-the-badge' />
</a>

</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" >/dev/null

echo -en "\e[1A\e[0K"
msg_ok "Created KompassOS (HWE) VM (${BL}${VMID}${GN})"

# Start VM if selected
if [[ "$START_VM" == "yes" ]]; then
  msg_info "Starting VM"
  qm start "$VMID" >/dev/null
  echo -en "\e[1A\e[0K"
  msg_ok "VM started"
else
  msg_ok "VM not started (per selection)"
fi

echo -e "\n${TAB}${GN}Done!${CL}"
echo -e "${TAB}Install via the Proxmox console (ISO is attached as CD-ROM)."
echo -e "${TAB}KompassOS: https://www.kompassos.nl/"
echo -e "${TAB}Repo:     https://github.com/L0g0ff/KompassOS\"