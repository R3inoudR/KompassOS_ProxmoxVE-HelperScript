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
# This script creates a KompassOS VM in Proxmox VE and attaches the KompassOS HWE installer ISO.
# Notes:
# - Only the HWE ISO is supported.
# - ISO storage can be dir, nfs, cifs, cephfs, etc. as long as Proxmox can resolve a filesystem path
#   and it is writable (checked via pvesm path + write test).
# - Save this file with LF line endings (not CRLF).

set -euo pipefail

# Community helper functions (telemetry/hooks used by community scripts)
# If you don't want this dependency, remove the next line and the post_* calls.
source /dev/stdin <<<"$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)"

# --- Script identity (used by api.func) ---
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="kompassos-hwe-vm"
var_os="kompassos"
var_version="hwe"

# --- UI / Formatting ---
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
DGN=$'\033[32m'
CL=$'\033[m'
BFR=$'\r\033[K'
TAB="  "
CM="${TAB}✔️  ${CL}"
CROSS="${TAB}✖️  ${CL}"

msg_info()  { echo -ne "${TAB}${YW}$1...${CL}"; }
msg_ok()    { echo -e  "${BFR}${CM}${GN}$1${CL}"; }
msg_error() { echo -e  "${BFR}${CROSS}${RD}$1${CL}"; }
die()       { msg_error "$1"; echo -e "\nExiting..."; exit 1; }

header_info() {
  clear
  # "Big" style banner for KompassOS (TAAG Big-like)
  cat <<'EOF'
  _  __                                    ____   _____ 
 | |/ /                                   / __ \ / ____|
 | ' / ___  _ __ ___  _ __   __ _ ___ ___| |  | | (___  
 |  < / _ \| '_ ` _ \| '_ \ / _` / __/ __| |  | |\___ \ 
 | . \ (_) | | | | | | |_) | (_| \__ \__ \ |__| |____) |
 |_|\_\___/|_| |_| |_| .__/ \__,_|___/___/\____/|_____/ 
                     | |                                
                     |_|                                

EOF
  echo "  KompassOS (HWE) VM Installer for Proxmox VE"
  echo "  GitHub: https://github.com/L0g0ff/KompassOS"
  echo "  Site:   https://www.kompassos.nl/"
  echo
}

# --- KompassOS HWE only (as requested) ---
BASE_URL="https://isos.kompassos.nl"
ISO_NAME="kompassos-dx-hwe.iso"
ISO_URL="${BASE_URL}/${ISO_NAME}"
SUM_URL="${BASE_URL}/${ISO_NAME}-CHECKSUM"

# --- Traps / cleanup ---
TEMP_DIR="$(mktemp -d)"
pushd "$TEMP_DIR" >/dev/null

cleanup_vmid() {
  if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
    qm stop "$VMID" &>/dev/null || true
    qm destroy "$VMID" &>/dev/null || true
  fi
}

cleanup() {
  local exit_code=$?
  popd >/dev/null || true
  rm -rf "$TEMP_DIR" || true

  # Let api.func know final status (best-effort)
  if [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]]; then
    if [[ $exit_code -eq 0 ]]; then
      post_update_to_api "done" "none" || true
    else
      post_update_to_api "failed" "$exit_code" || true
    fi
  fi
}
trap cleanup EXIT

error_handler() {
  local exit_code="$?"
  post_update_to_api "failed" "${exit_code}" || true
  echo -e "\n${RD}[ERROR]${CL} Exit code ${RD}${exit_code}${CL} while executing: ${YW}${BASH_COMMAND}${CL}\n"
  cleanup_vmid || true
  exit "${exit_code}"
}
trap error_handler ERR
trap 'post_update_to_api "failed" "130" || true; cleanup_vmid || true; exit 130' SIGINT
trap 'post_update_to_api "failed" "143" || true; cleanup_vmid || true; exit 143' SIGTERM

# --- Safety checks ---
check_root() {
  if [[ "$(id -u)" -ne 0 || "$(ps -o comm= -p "$PPID")" == "sudo" ]]; then
    clear
    msg_error "Please run this script as root (not via sudo)."
    echo -e "\nExiting..."
    exit 1
  fi
}

arch_check() {
  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    die "Unsupported architecture: $(dpkg --print-architecture) (amd64 only)."
  fi
}

pve_check() {
  local ver
  if command -v pveversion >/dev/null 2>&1; then
    ver="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
    [[ "$ver" =~ ^(8|9)\. ]] || die "Unsupported Proxmox VE version: ${ver} (expected 8.x or 9.x)."
  else
    die "pveversion not found (are you on a Proxmox VE host?)."
  fi
}

ssh_check() {
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    if ! whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno \
      --title "SSH DETECTED" \
      --yesno "It's suggested to use the Proxmox host shell instead of SSH.\nProceed anyway?" 10 62; then
      die "User exited script"
    fi
  fi
}

get_valid_nextid() {
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

exit_script() {
  header_info
  die "User exited script"
}

# --- Storage selection (community-style radiolist) ---
pick_storage_menu() {
  # $1: content type (images|iso), $2: title, $3: prompt
  local content="$1"
  local title="$2"
  local prompt="$3"

  local menu=()
  local msg_max=0
  local line tag typ free item offset

  while read -r line; do
    tag="$(awk '{print $1}' <<<"$line")"
    typ="$(awk '{printf "%-10s", $2}' <<<"$line")"
    free="$(numfmt --field 4-6 --from-unit=K --to=iec --format %.2f <<<"$line" | awk '{printf("%9sB", $6)}')"
    item=" Type: $typ Free: $free "
    offset=2
    if (( ${#item} + offset > msg_max )); then
      msg_max=$(( ${#item} + offset ))
    fi
    menu+=("$tag" "$item" "OFF")
  done < <(pvesm status -content "$content" | awk 'NR>1')

  local count=$(( ${#menu[@]} / 3 ))
  if (( count == 0 )); then
    die "No valid storage found for content '$content'."
  fi
  if (( count == 1 )); then
    echo "${menu[0]}"
    return 0
  fi

  local choice=""
  while [[ -z "$choice" ]]; do
    choice="$(whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "$title" \
      --radiolist "$prompt\nTo make a selection, use the Spacebar.\n" \
      16 $((msg_max + 23)) 6 \
      "${menu[@]}" 3>&1 1>&2 2>&3)" || exit_script
  done
  echo "$choice"
}

# ISO storage: accept dir, nfs, cifs, cephfs, etc. as long as:
# - Proxmox can resolve a filesystem path via pvesm path
# - The resolved directory is writable
ensure_iso_storage_writable() {
  local st="$1"
  local test_path test_dir

  test_path="$(pvesm path "${st}:iso/${ISO_NAME}" 2>/dev/null || true)"
  [[ -n "$test_path" ]] || die "ISO storage '$st' does not provide a filesystem path for ISO volumes (pvesm path failed)."

  test_dir="$(dirname "$test_path")"
  mkdir -p "$test_dir" 2>/dev/null || die "Cannot create ISO directory on storage '$st': $test_dir"

  touch "${test_dir}/.kompassos-write-test" 2>/dev/null || die "ISO storage '$st' is not writable: $test_dir"
  rm -f "${test_dir}/.kompassos-write-test" 2>/dev/null || true
}

# --- Defaults / Advanced ---
VMID="$(get_valid_nextid)"
HN="kompassos"
MACHINE="q35"
UEFI="yes"
CPU_MODEL="kvm64"
CORES="4"
RAM_MIB="8192"
DISK_SIZE="64G"
DISK_CACHE=""
BRIDGE="vmbr0"
VLAN=""
MTU=""
VERIFY_SUM="yes"
START_VM="yes"

default_settings() {
  METHOD="default"
  VMID="$(get_valid_nextid)"
  HN="kompassos"
  MACHINE="q35"
  UEFI="yes"
  CPU_MODEL="kvm64"
  CORES="4"
  RAM_MIB="8192"
  DISK_SIZE="64G"
  DISK_CACHE=""
  BRIDGE="vmbr0"
  VLAN=""
  MTU=""
  VERIFY_SUM="yes"
  START_VM="yes"

  header_info
  echo -e "${TAB}${DGN}Using default settings:${CL}\n"
  echo -e "${TAB}VMID:      ${VMID}"
  echo -e "${TAB}Hostname:  ${HN}"
  echo -e "${TAB}Machine:   ${MACHINE}"
  echo -e "${TAB}UEFI/OVMF: ${UEFI}"
  echo -e "${TAB}CPU:       ${CPU_MODEL}"
  echo -e "${TAB}Cores:     ${CORES}"
  echo -e "${TAB}RAM:       ${RAM_MIB} MiB"
  echo -e "${TAB}Disk:      ${DISK_SIZE}"
  echo -e "${TAB}Bridge:    ${BRIDGE}"
  echo -e "${TAB}Checksum:  ${VERIFY_SUM}"
  echo -e "${TAB}Start VM:  ${START_VM}\n"

  whiptail --backtitle "Proxmox VE Helper Scripts" --title "READY" \
    --yesno "Ready to create the KompassOS (HWE) VM with default settings?" 10 70 \
    || exit_script
}

advanced_settings() {
  METHOD="advanced"
  header_info

  local v

  v="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "VMID" \
    --inputbox "Set Virtual Machine ID" 8 58 "$VMID" 3>&1 1>&2 2>&3)" || exit_script
  VMID="${v:-$(get_valid_nextid)}"
  if qm status "$VMID" &>/dev/null || pct status "$VMID" &>/dev/null; then
    die "ID $VMID is already in use."
  fi

  v="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "HOSTNAME" \
    --inputbox "Set Hostname" 8 58 "$HN" 3>&1 1>&2 2>&3)" || exit_script
  HN="$(echo "${v:-kompassos}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  [[ -n "$HN" ]] || HN="kompassos"

  local mach
  mach="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" \
    --radiolist "Choose machine type" 10 58 2 \
    "q35" "Recommended" ON \
    "i440fx" "Legacy" OFF \
    3>&1 1>&2 2>&3)" || exit_script
  MACHINE="$mach"

  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "FIRMWARE" \
    --yesno "Use UEFI/OVMF (recommended)?" 10 58; then
    UEFI="yes"
  else
    UEFI="no"
  fi

  local cpu
  cpu="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU MODEL" \
    --radiolist "Choose CPU model" 10 58 2 \
    "kvm64" "Default" ON \
    "host" "Host passthrough" OFF \
    3>&1 1>&2 2>&3)" || exit_script
  CPU_MODEL="$cpu"

  v="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CORES" \
    --inputbox "Allocate CPU cores" 8 58 "$CORES" 3>&1 1>&2 2>&3)" || exit_script
  CORES="${v:-4}"

  v="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "RAM" \
    --inputbox "Allocate RAM in MiB" 8 58 "$RAM_MIB" 3>&1 1>&2 2>&3)" || exit_script
  RAM_MIB="${v:-8192}"

  v="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK SIZE" \
    --inputbox "Disk size (e.g. 64G, 100G)" 8 58 "$DISK_SIZE" 3>&1 1>&2 2>&3)" || exit_script
  DISK_SIZE="$(echo "${v:-64G}" | tr -d ' ')"

  local cache_choice
  cache_choice="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" \
    --radiolist "Choose disk cache mode" 10 58 2 \
    "none" "Default" ON \
    "writethrough" "Write Through" OFF \
    3>&1 1>&2 2>&3)" || exit_script
  if [[ "$cache_choice" == "writethrough" ]]; then
    DISK_CACHE="cache=writethrough,"
  else
    DISK_CACHE=""
  fi

  v="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "BRIDGE" \
    --inputbox "Set network bridge" 8 58 "$BRIDGE" 3>&1 1>&2 2>&3)" || exit_script
  BRIDGE="${v:-vmbr0}"

  v="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "VLAN" \
    --inputbox "Set VLAN tag (blank = default)" 8 58 "" 3>&1 1>&2 2>&3)" || exit_script
  if [[ -n "$v" ]]; then VLAN=",tag=$v"; else VLAN=""; fi

  v="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MTU" \
    --inputbox "Set MTU (blank = default)" 8 58 "" 3>&1 1>&2 2>&3)" || exit_script
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
  echo -e "${TAB}${DGN}Advanced settings summary:${CL}\n"
  echo -e "${TAB}VMID:      ${VMID}"
  echo -e "${TAB}Hostname:  ${HN}"
  echo -e "${TAB}Machine:   ${MACHINE}"
  echo -e "${TAB}UEFI/OVMF: ${UEFI}"
  echo -e "${TAB}CPU:       ${CPU_MODEL}"
  echo -e "${TAB}Cores:     ${CORES}"
  echo -e "${TAB}RAM:       ${RAM_MIB} MiB"
  echo -e "${TAB}Disk:      ${DISK_SIZE}"
  echo -e "${TAB}Bridge:    ${BRIDGE}"
  echo -e "${TAB}Checksum:  ${VERIFY_SUM}"
  echo -e "${TAB}Start VM:  ${START_VM}\n"

  whiptail --backtitle "Proxmox VE Helper Scripts" --title "READY" \
    --yesno "Ready to create the KompassOS (HWE) VM using the above settings?" 10 76 \
    || advanced_settings
}

start_menu() {
  header_info
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "KompassOS (HWE) VM" \
    --yesno "This will create a new KompassOS (HWE) VM.\nProceed?" 10 62 \
    || exit_script

  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" \
    --yesno "Use default settings?" --no-button "Advanced" 10 58; then
    default_settings
  else
    advanced_settings
  fi
}

# --- Main ---
check_root
arch_check
pve_check
ssh_check
start_menu

# api.func hook (best-effort)
post_to_api_vm

header_info
msg_info "Selecting VM disk storage"
VM_STORAGE="$(pick_storage_menu "images" "Storage Pools" "Which storage pool would you like to use for ${HN}?")"
msg_ok "Using ${BL}${VM_STORAGE}${GN} for VM disk storage."

msg_info "Selecting ISO storage"
ISO_STORAGE="$(pick_storage_menu "iso" "ISO Storage" "Where should the KompassOS ISO be stored?")"
ensure_iso_storage_writable "$ISO_STORAGE"
msg_ok "Using ${BL}${ISO_STORAGE}${GN} for ISO storage."

msg_info "Resolving ISO path"
ISO_PATH="$(pvesm path "${ISO_STORAGE}:iso/${ISO_NAME}")"
msg_ok "ISO path: ${BL}${ISO_PATH}${GN}"

if [[ ! -f "$ISO_PATH" ]]; then
  msg_info "Downloading KompassOS (HWE) ISO"
  mkdir -p "$(dirname "$ISO_PATH")"
  curl -f#SL -o "$ISO_PATH" "$ISO_URL"
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${BL}${ISO_NAME}${GN}"
else
  msg_ok "ISO already exists: ${BL}${ISO_NAME}${GN}"
fi

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

# Thin provisioning/discard on block storage (leave empty for dir/nfs/btrfs)
THIN="discard=on,ssd=1,"
STORAGE_TYPE="$(pvesm status -storage "$VM_STORAGE" | awk 'NR>1 {print $2}')"
case "$STORAGE_TYPE" in
  nfs|dir|btrfs) THIN="" ;;
  *) : ;;
esac

CPU_ARG=""
[[ "$CPU_MODEL" == "host" ]] && CPU_ARG="-cpu host"

MACHINE_ARG=""
[[ "$MACHINE" == "q35" ]] && MACHINE_ARG="-machine q35"

BIOS_ARG=""
[[ "$UEFI" == "yes" ]] && BIOS_ARG="-bios ovmf"

msg_info "Creating KompassOS (HWE) VM"

qm create "$VMID" \
  -agent 1 \
  -tablet 0 \
  -localtime 1 \
  ${MACHINE_ARG} \
  ${BIOS_ARG} \
  ${CPU_ARG} \
  -cores "$CORES" \
  -memory "$RAM_MIB" \
  -balloon 0 \
  -name "$HN" \
  -tags "kompassos" \
  -net0 "virtio,bridge=${BRIDGE}${VLAN}${MTU}" \
  -onboot 1 \
  -ostype l26 \
  -scsihw virtio-scsi-pci \
  -rng0 source=/dev/urandom \
  >/dev/null

if [[ "$UEFI" == "yes" ]]; then
  DISK0="vm-${VMID}-disk-0"
  pvesm alloc "$VM_STORAGE" "$VMID" "$DISK0" 4M >/dev/null
  qm set "$VMID" -efidisk0 "${VM_STORAGE}:${DISK0}" >/dev/null
fi

qm set "$VMID" -scsi0 "${VM_STORAGE}:${DISK_SIZE},${DISK_CACHE}${THIN}iothread=1" >/dev/null
qm set "$VMID" -ide2 "${ISO_STORAGE}:iso/${ISO_NAME},media=cdrom" >/dev/null
qm set "$VMID" -serial0 socket -vga virtio >/dev/null

# IMPORTANT: Proxmox expects semicolons in boot order
qm set "$VMID" -boot "order=ide2;scsi0" >/dev/null

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

msg_ok "Created KompassOS (HWE) VM (${BL}${VMID}${GN})"

if [[ "$START_VM" == "yes" ]]; then
  msg_info "Starting VM"
  qm start "$VMID" >/dev/null
  msg_ok "VM started"
else
  msg_ok "VM not started (per selection)"
fi

echo -e "\n${TAB}${GN}Done!${CL}"
echo -e "${TAB}Install via the Proxmox console (ISO is attached as CD-ROM)."
echo -e "${TAB}After install (optional): qm set ${VMID} -boot \"order=scsi0;ide2\""
echo -e "${TAB}KompassOS: https://www.kompassos.nl/"
echo -e "${TAB}Repo:     https://github.com/L0g0ff/KompassOS\n"