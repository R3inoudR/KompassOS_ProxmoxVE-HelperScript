#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# KompassOS (HWE) VM Installer for Proxmox VE
#
# Copyright (c) 2026
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# KompassOS references:
# - https://github.com/L0g0ff/KompassOS
# - https://www.kompassos.nl/
#
# Notes:
# - Only the KompassOS HWE ISO is supported.
# - ISO storage may be dir/nfs/cifs/cephfs/... as long as pvesm path resolves and is writable.
# - Disk size is numeric GiB to avoid ZFS parsing issues.
# - Save with LF line endings (not CRLF).

set -euo pipefail

# -------------------------
# Constants (KompassOS HWE)
# -------------------------
BASE_URL="https://isos.kompassos.nl"
ISO_NAME="kompassos-dx-hwe.iso"
ISO_URL="${BASE_URL}/${ISO_NAME}"
SUM_URL="${BASE_URL}/${ISO_NAME}-CHECKSUM"

# -------------
# UI / Styling
# -------------
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
DGN=$'\033[32m'
CL=$'\033[m'
BFR=$'\r\033[K'
TAB="  "
OK_MARK="${TAB}✔️  "
ERR_MARK="${TAB}✖️  "

info()  { echo -e "${TAB}${YW}[INFO]${CL}  $*"; }
ok()    { echo -e "${BFR}${OK_MARK}${GN}$*${CL}"; }
warn()  { echo -e "${TAB}${YW}[WARN]${CL}  $*"; }
err()   { echo -e "${BFR}${ERR_MARK}${RD}$*${CL}"; }
die()   { err "$*"; echo -e "\nExiting..."; exit 1; }

header() {
  clear
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
  echo
  echo "  KompassOS (HWE) VM Installer for Proxmox VE"
  echo "  GitHub: https://github.com/L0g0ff/KompassOS"
  echo "  Site:   https://www.kompassos.nl/"
  echo
}

# -----------------
# Basic prerequisites
# -----------------
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run this script as root."
  fi
}

require_cmds() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Missing required command(s): ${missing[*]}"
  fi
}

require_pve() {
  command -v pveversion >/dev/null 2>&1 || die "This does not look like a Proxmox VE host (pveversion not found)."
  command -v pvesm >/dev/null 2>&1 || die "pvesm not found."
  command -v qm >/dev/null 2>&1 || die "qm not found."
}

arch_check() {
  local arch
  arch="$(dpkg --print-architecture)"
  [[ "$arch" == "amd64" ]] || die "Unsupported architecture: $arch (amd64 only)."
}

ssh_warning() {
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    if ! whiptail --backtitle "KompassOS VM Installer" --defaultno \
      --title "SSH DETECTED" \
      --yesno "It's recommended to run from the Proxmox host console instead of SSH.\nProceed anyway?" 10 70; then
      die "User aborted."
    fi
  fi
}

# -----------------
# CRLF guard (helps prevent \r problems)
# -----------------
crlf_guard() {
  # If the script itself contains CRLF, bail with a clear message.
  if grep -q $'\r' "$0"; then
    die "This script contains CRLF line endings. Convert to LF (Unix) and try again."
  fi
}

# -----------------
# Helpers
# -----------------
get_next_vmid() {
  local id
  id="$(pvesh get /cluster/nextid)"
  echo "$id"
}

is_id_in_use() {
  local id="$1"
  [[ -f "/etc/pve/qemu-server/${id}.conf" || -f "/etc/pve/lxc/${id}.conf" ]]
}

normalize_gib() {
  # Accept: "64", "64G", "64g", "64GiB", " 64 " -> output numeric "64"
  local in="${1//[[:space:]]/}"
  in="${in,,}"
  in="${in%gib}"
  in="${in%gb}"
  in="${in%g}"
  [[ "$in" =~ ^[0-9]+$ ]] || return 1
  echo "$in"
}

# -----------------
# Storage selection
# -----------------
pick_storage_menu() {
  # $1 content (images|iso), $2 title, $3 prompt
  local content="$1" title="$2" prompt="$3"

  local lines menu=() msg_max=0
  lines="$(pvesm status -content "$content" | awk 'NR>1')"
  [[ -n "$lines" ]] || die "No storage found for content='$content'."

  while IFS= read -r line; do
    local tag typ free item
    tag="$(awk '{print $1}' <<<"$line")"
    typ="$(awk '{printf "%-10s", $2}' <<<"$line")"
    free="$(numfmt --field 4-6 --from-unit=K --to=iec --format %.2f <<<"$line" | awk '{printf("%9sB", $6)}')"
    item=" Type: $typ Free: $free "
    (( ${#item} > msg_max )) && msg_max=${#item}
    menu+=("$tag" "$item" "OFF")
  done <<<"$lines"

  local count=$(( ${#menu[@]} / 3 ))
  if (( count == 1 )); then
    echo "${menu[0]}"
    return 0
  fi

  local choice=""
  while [[ -z "$choice" ]]; do
    choice="$(whiptail --backtitle "KompassOS VM Installer" \
      --title "$title" \
      --radiolist "$prompt\nUse Spacebar to select.\n" \
      16 $((msg_max + 26)) 8 \
      "${menu[@]}" 3>&1 1>&2 2>&3)" || die "User aborted."
  done
  echo "$choice"
}

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

# -----------------
# ISO download + checksum
# -----------------
download_iso_if_missing() {
  local iso_path="$1"
  if [[ -f "$iso_path" ]]; then
    ok "ISO already exists: ${iso_path}"
    return 0
  fi

  info "Downloading: ${ISO_URL}"
  mkdir -p "$(dirname "$iso_path")"
  curl -f#SL -o "$iso_path" "$ISO_URL"
  echo -en "\e[1A\e[0K"
  ok "ISO downloaded: ${iso_path}"
}

verify_checksum_best_effort() {
  local iso_path="$1"

  if ! command -v sha256sum >/dev/null 2>&1; then
    warn "sha256sum not found; skipping checksum verification."
    return 0
  fi

  info "Attempting checksum verification (best-effort)..."
  if ! curl -fsSL -o checksum.txt "$SUM_URL"; then
    warn "Checksum file download failed; skipping verification."
    return 0
  fi

  local expected actual
  expected="$(grep -Eo '([a-fA-F0-9]{64})' checksum.txt | head -n1 || true)"
  if [[ -z "${expected:-}" ]]; then
    warn "Checksum format not recognized; skipping verification."
    return 0
  fi

  actual="$(sha256sum "$iso_path" | awk '{print $1}')"
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    die "Checksum mismatch for ${ISO_NAME}"
  fi
  ok "Checksum OK (sha256)."
}

# -----------------
# VM creation
# -----------------
create_vm() {
  local vmid="$1"
  local name="$2"
  local machine="$3"
  local uefi="$4"        # yes|no
  local cpu_model="$5"   # kvm64|host
  local cores="$6"
  local ram_mib="$7"
  local disk_gib="$8"    # numeric
  local disk_cache="$9"  # "" or "cache=writethrough,"
  local bridge="${10}"
  local vlan="${11}"     # "" or ",tag=###"
  local mtu="${12}"      # "" or ",mtu=####"
  local vm_storage="${13}"
  local iso_storage="${14}"

  local thin="discard=on,ssd=1,"
  local storage_type
  storage_type="$(pvesm status -storage "$vm_storage" | awk 'NR>1 {print $2}')"
  case "$storage_type" in
    nfs|dir|btrfs) thin="" ;; # those are file-based or already handle discard differently
    *) : ;;
  esac

  local cpu_arg=""
  [[ "$cpu_model" == "host" ]] && cpu_arg="-cpu host"

  local machine_arg=""
  [[ "$machine" == "q35" ]] && machine_arg="-machine q35"

  local bios_arg=""
  [[ "$uefi" == "yes" ]] && bios_arg="-bios ovmf"

  info "Creating VM ${vmid} (${name})..."

  qm create "$vmid" \
    -agent 1 \
    -tablet 0 \
    -localtime 1 \
    ${machine_arg} \
    ${bios_arg} \
    ${cpu_arg} \
    -cores "$cores" \
    -memory "$ram_mib" \
    -balloon 0 \
    -name "$name" \
    -tags "kompassos" \
    -net0 "virtio,bridge=${bridge}${vlan}${mtu}" \
    -onboot 1 \
    -ostype l26 \
    -scsihw virtio-scsi-pci \
    -rng0 source=/dev/urandom \
    >/dev/null

  if [[ "$uefi" == "yes" ]]; then
    qm set "$vmid" -efidisk0 "${vm_storage}:0,format=raw,efitype=4m,pre-enrolled-keys=1" >/dev/null
  fi

  # IMPORTANT: numeric disk size (GiB) avoids ZFS "64G" parsing errors.
  qm set "$vmid" -scsi0 "${vm_storage}:${disk_gib},format=raw,${disk_cache}${thin}iothread=1" >/dev/null
  qm set "$vmid" -ide2 "${iso_storage}:iso/${ISO_NAME},media=cdrom" >/dev/null
  qm set "$vmid" -serial0 socket -vga virtio >/dev/null

  # IMPORTANT: Proxmox expects semicolons
  qm set "$vmid" -boot "order=ide2;scsi0" >/dev/null

  ok "VM created: ${vmid}"
}

# -----------------
# Menus (Default / Advanced)
# -----------------
# Defaults (safe / sane)
VMID="$(get_next_vmid)"
HN="kompassos"
MACHINE="q35"
UEFI="yes"
CPU_MODEL="kvm64"
CORES="4"
RAM_MIB="8192"
DISK_GIB="64"       # numeric
DISK_CACHE=""       # or "cache=writethrough,"
BRIDGE="vmbr0"
VLAN=""
MTU=""
VERIFY_SUM="yes"
START_VM="yes"

default_settings() {
  header
  echo -e "${TAB}${DGN}Using default settings:${CL}\n"
  echo -e "${TAB}VMID:      ${VMID}"
  echo -e "${TAB}Hostname:  ${HN}"
  echo -e "${TAB}Machine:   ${MACHINE}"
  echo -e "${TAB}UEFI/OVMF: ${UEFI}"
  echo -e "${TAB}CPU:       ${CPU_MODEL}"
  echo -e "${TAB}Cores:     ${CORES}"
  echo -e "${TAB}RAM:       ${RAM_MIB} MiB"
  echo -e "${TAB}Disk:      ${DISK_GIB} GiB"
  echo -e "${TAB}Bridge:    ${BRIDGE}"
  echo -e "${TAB}Checksum:  ${VERIFY_SUM}"
  echo -e "${TAB}Start VM:  ${START_VM}\n"

  whiptail --backtitle "KompassOS VM Installer" --title "READY" \
    --yesno "Create the KompassOS (HWE) VM with default settings?" 10 74 \
    || die "User aborted."
}

advanced_settings() {
  header
  local v

  v="$(whiptail --backtitle "KompassOS VM Installer" --title "VMID" \
    --inputbox "Set Virtual Machine ID" 8 58 "$VMID" 3>&1 1>&2 2>&3)" || die "User aborted."
  VMID="${v:-$VMID}"
  [[ "$VMID" =~ ^[0-9]+$ ]] || die "Invalid VMID."
  is_id_in_use "$VMID" && die "ID $VMID is already in use."

  v="$(whiptail --backtitle "KompassOS VM Installer" --title "HOSTNAME" \
    --inputbox "Set VM name" 8 58 "$HN" 3>&1 1>&2 2>&3)" || die "User aborted."
  HN="$(echo "${v:-kompassos}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  [[ -n "$HN" ]] || HN="kompassos"

  MACHINE="$(whiptail --backtitle "KompassOS VM Installer" --title "MACHINE TYPE" \
    --radiolist "Choose machine type" 10 60 2 \
    "q35" "Recommended" ON \
    "i440fx" "Legacy" OFF \
    3>&1 1>&2 2>&3)" || die "User aborted."

  if whiptail --backtitle "KompassOS VM Installer" --title "FIRMWARE" \
    --yesno "Use UEFI/OVMF (recommended)?" 10 60; then
    UEFI="yes"
  else
    UEFI="no"
  fi

  CPU_MODEL="$(whiptail --backtitle "KompassOS VM Installer" --title "CPU MODEL" \
    --radiolist "Choose CPU model" 10 60 2 \
    "kvm64" "Default" ON \
    "host" "Host passthrough" OFF \
    3>&1 1>&2 2>&3)" || die "User aborted."

  v="$(whiptail --backtitle "KompassOS VM Installer" --title "CORES" \
    --inputbox "CPU cores" 8 58 "$CORES" 3>&1 1>&2 2>&3)" || die "User aborted."
  [[ "${v:-}" =~ ^[0-9]+$ ]] || die "Invalid cores."
  CORES="$v"

  v="$(whiptail --backtitle "KompassOS VM Installer" --title "RAM" \
    --inputbox "Memory in MiB" 8 58 "$RAM_MIB" 3>&1 1>&2 2>&3)" || die "User aborted."
  [[ "${v:-}" =~ ^[0-9]+$ ]] || die "Invalid RAM."
  RAM_MIB="$v"

  v="$(whiptail --backtitle "KompassOS VM Installer" --title "DISK" \
    --inputbox "Disk size in GiB (e.g. 64 or 64G)" 8 64 "${DISK_GIB}G" 3>&1 1>&2 2>&3)" || die "User aborted."
  DISK_GIB="$(normalize_gib "${v:-64G}")" || die "Invalid disk size. Use e.g. 64 or 64G."

  local cache_choice
  cache_choice="$(whiptail --backtitle "KompassOS VM Installer" --title "DISK CACHE" \
    --radiolist "Choose disk cache mode" 10 60 2 \
    "none" "Default" ON \
    "writethrough" "Write Through" OFF \
    3>&1 1>&2 2>&3)" || die "User aborted."
  if [[ "$cache_choice" == "writethrough" ]]; then
    DISK_CACHE="cache=writethrough,"
  else
    DISK_CACHE=""
  fi

  v="$(whiptail --backtitle "KompassOS VM Installer" --title "BRIDGE" \
    --inputbox "Network bridge" 8 58 "$BRIDGE" 3>&1 1>&2 2>&3)" || die "User aborted."
  BRIDGE="${v:-vmbr0}"

  v="$(whiptail --backtitle "KompassOS VM Installer" --title "VLAN" \
    --inputbox "VLAN tag (blank = none)" 8 58 "" 3>&1 1>&2 2>&3)" || die "User aborted."
  [[ -n "$v" ]] && VLAN=",tag=$v" || VLAN=""

  v="$(whiptail --backtitle "KompassOS VM Installer" --title "MTU" \
    --inputbox "MTU (blank = default)" 8 58 "" 3>&1 1>&2 2>&3)" || die "User aborted."
  [[ -n "$v" ]] && MTU=",mtu=$v" || MTU=""

  if whiptail --backtitle "KompassOS VM Installer" --title "CHECKSUM" \
    --yesno "Verify ISO checksum (best-effort)?" 10 60; then
    VERIFY_SUM="yes"
  else
    VERIFY_SUM="no"
  fi

  if whiptail --backtitle "KompassOS VM Installer" --title "START VM" \
    --yesno "Start VM after creation?" 10 60; then
    START_VM="yes"
  else
    START_VM="no"
  fi

  header
  echo -e "${TAB}${DGN}Advanced settings summary:${CL}\n"
  echo -e "${TAB}VMID:      ${VMID}"
  echo -e "${TAB}Hostname:  ${HN}"
  echo -e "${TAB}Machine:   ${MACHINE}"
  echo -e "${TAB}UEFI/OVMF: ${UEFI}"
  echo -e "${TAB}CPU:       ${CPU_MODEL}"
  echo -e "${TAB}Cores:     ${CORES}"
  echo -e "${TAB}RAM:       ${RAM_MIB} MiB"
  echo -e "${TAB}Disk:      ${DISK_GIB} GiB"
  echo -e "${TAB}Bridge:    ${BRIDGE}"
  echo -e "${TAB}Checksum:  ${VERIFY_SUM}"
  echo -e "${TAB}Start VM:  ${START_VM}\n"

  whiptail --backtitle "KompassOS VM Installer" --title "READY" \
    --yesno "Create VM with these settings?" 10 74 \
    || die "User aborted."
}

start_menu() {
  header
  whiptail --backtitle "KompassOS VM Installer" --title "KompassOS (HWE) VM" \
    --yesno "This will create a new KompassOS (HWE) VM.\nProceed?" 10 70 \
    || die "User aborted."

  if whiptail --backtitle "KompassOS VM Installer" --title "SETTINGS" \
    --yesno "Use default settings?" --no-button "Advanced" 10 60; then
    default_settings
  else
    advanced_settings
  fi
}

# -----------------
# Main
# -----------------
require_root
crlf_guard
require_cmds whiptail curl awk sed grep numfmt
require_pve
arch_check
ssh_warning

start_menu

header
info "Target ISO storage selection"
ISO_STORAGE="$(pick_storage_menu "iso" "ISO Storage" "Select where the KompassOS ISO should be stored.")"
ensure_iso_storage_writable "$ISO_STORAGE"
ok "Using ${ISO_STORAGE} for ISO storage."

info "Target VM disk storage selection"
VM_STORAGE="$(pick_storage_menu "images" "VM Disk Storage" "Select where the VM disk should be created.")"
ok "Using ${VM_STORAGE} for VM disk storage."

info "Resolving ISO path"
ISO_PATH="$(pvesm path "${ISO_STORAGE}:iso/${ISO_NAME}")"
ok "ISO path: ${ISO_PATH}"

download_iso_if_missing "$ISO_PATH"
if [[ "$VERIFY_SUM" == "yes" ]]; then
  verify_checksum_best_effort "$ISO_PATH"
fi

create_vm "$VMID" "$HN" "$MACHINE" "$UEFI" "$CPU_MODEL" "$CORES" "$RAM_MIB" "$DISK_GIB" "$DISK_CACHE" "$BRIDGE" "$VLAN" "$MTU" "$VM_STORAGE" "$ISO_STORAGE"

if [[ "$START_VM" == "yes" ]]; then
  info "Starting VM ${VMID}"
  qm start "$VMID" >/dev/null
  ok "VM started."
else
  ok "VM not started (per selection)."
fi

echo
ok "Done!"
echo "${TAB}Install via the Proxmox console (ISO is attached as CD-ROM)."
echo "${TAB}After install (optional): qm set ${VMID} -boot \"order=scsi0;ide2\""
echo "${TAB}KompassOS: https://www.kompassos.nl/"
echo "${TAB}Repo:     https://github.com/L0g0ff/KompassOS"
echo