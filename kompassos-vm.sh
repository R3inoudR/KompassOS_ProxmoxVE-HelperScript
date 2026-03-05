#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# KompassOS Proxmox VE Helper Script (HWE ISO)
# GitHub: https://github.com/L0g0ff/KompassOS
# Website: https://www.kompassos.nl/
#
# This script helps you download the KompassOS HWE ISO and create a Proxmox VE VM
# configured for an interactive ISO installation.
#
# Requirements:
# - Proxmox VE 7/8
# - curl or wget
# - whiptail (usually present on PVE; if not: apt-get update && apt-get install -y whiptail)
#
# Notes:
# - Only the HWE build is used.
# - The ISO URL is provided by kompassos.nl and currently points to:
#   https://isos.kompassos.nl/kompassos-dx-hwe.iso
#
# Apache 2.0 License applies to this script.

set -Eeuo pipefail

# ----------------------------
# Constants
# ----------------------------
SCRIPT_NAME="KompassOS HWE VM Helper"
ISO_URL="https://isos.kompassos.nl/kompassos-dx-hwe.iso"
ISO_SHA_URL="https://isos.kompassos.nl/kompassos-dx-hwe.iso-CHECKSUM"
DEFAULT_ISO_NAME="kompassos-dx-hwe.iso"
DEFAULT_VM_NAME="KompassOS-HWE"
MIN_DISK_GB=32

# ----------------------------
# UI helpers
# ----------------------------
color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
info()  { echo -e "$(color '1;34' '[INFO]')  $*"; }
warn()  { echo -e "$(color '1;33' '[WARN]')  $*"; }
error() { echo -e "$(color '1;31' '[ERROR]') $*"; }
ok()    { echo -e "$(color '1;32' '[OK]')    $*"; }

die() { error "$*"; exit 1; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root."
}

need_cmd() {
  command -v "$1" &>/dev/null || die "Missing dependency: $1"
}

have_cmd() {
  command -v "$1" &>/dev/null
}

banner() {
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
  echo "  ${SCRIPT_NAME}"
  echo "  GitHub: https://github.com/L0g0ff/KompassOS"
  echo "  Site:   https://www.kompassos.nl/"
  echo
}

# ----------------------------
# Whiptail wrappers
# ----------------------------
wt_menu() {
  local title="$1" prompt="$2"
  shift 2
  whiptail --title "$title" --menu "$prompt" 18 72 10 "$@" 3>&1 1>&2 2>&3
}

wt_input() {
  local title="$1" prompt="$2" default="${3:-}"
  whiptail --title "$title" --inputbox "$prompt" 10 72 "$default" 3>&1 1>&2 2>&3
}

wt_yesno() {
  local title="$1" prompt="$2"
  whiptail --title "$title" --yesno "$prompt" 10 72
}

wt_msg() {
  local title="$1" msg="$2"
  whiptail --title "$title" --msgbox "$msg" 12 72
}

# ----------------------------
# Proxmox helpers
# ----------------------------
pve_checks() {
  need_cmd pvesh
  need_cmd qm
  need_cmd pvesm

  # Soft-check version
  if have_cmd pveversion; then
    local ver
    ver="$(pveversion 2>/dev/null | head -n1 || true)"
    info "Detected: ${ver:-unknown}"
  fi
}

pick_storage() {
  # Return first "iso" capable storage as default suggestion, but let user choose.
  local storages
  storages="$(pvesm status -content iso 2>/dev/null | awk 'NR>1 {print $1}' | xargs || true)"

  [[ -n "${storages}" ]] || die "No storage found that supports ISO content. Add/enable ISO content on a storage in PVE first."

  local default_storage
  default_storage="$(echo "$storages" | awk '{print $1}')"

  local menu_items=()
  local s
  for s in $storages; do
    menu_items+=("$s" "ISO-capable storage")
  done

  local choice
  choice="$(wt_menu "$SCRIPT_NAME" "Select ISO storage (content=iso)" "${menu_items[@]}")" || return 1

  echo "$choice"
}

iso_path_for_storage() {
  local storage="$1"
  # We prefer the standard ISO template directory: /var/lib/vz/template/iso
  # but storage path varies. We'll ask pvesm for the path.
  local path
  path="$(pvesm path "${storage}:iso/${DEFAULT_ISO_NAME}" 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    echo "$path"
    return 0
  fi

  # Fallback: attempt common local dir (works for local/local-lvm setups using 'local' for ISO)
  echo "/var/lib/vz/template/iso/${DEFAULT_ISO_NAME}"
}

download_iso() {
  local storage="$1"
  local iso_dir

  # If pvesm supports "path storage:iso", we can derive the dir by using a dummy path.
  local iso_full_path
  iso_full_path="$(iso_path_for_storage "$storage")"
  iso_dir="$(dirname "$iso_full_path")"
  mkdir -p "$iso_dir"

  info "Target ISO directory: $iso_dir"
  info "Downloading: $ISO_URL"
  info "Checksum file: $ISO_SHA_URL"

  local tmp_iso="${iso_dir}/.${DEFAULT_ISO_NAME}.partial"
  local out_iso="${iso_dir}/${DEFAULT_ISO_NAME}"
  local sum_file="${iso_dir}/${DEFAULT_ISO_NAME}-CHECKSUM"

  if have_cmd curl; then
    curl -fL --retry 3 --retry-delay 2 -o "$tmp_iso" "$ISO_URL"
    curl -fL --retry 3 --retry-delay 2 -o "$sum_file" "$ISO_SHA_URL" || true
  elif have_cmd wget; then
    wget -O "$tmp_iso" "$ISO_URL"
    wget -O "$sum_file" "$ISO_SHA_URL" || true
  else
    die "Neither curl nor wget found."
  fi

  mv -f "$tmp_iso" "$out_iso"
  ok "ISO downloaded: $out_iso"

  # Try to verify checksum (best-effort; checksum format may vary)
  if [[ -s "$sum_file" ]] && have_cmd sha256sum; then
    if grep -qiE 'sha256|\.iso' "$sum_file"; then
      info "Attempting checksum verification (best-effort)..."
      # Accept either: "<hash>  filename" or lines containing the iso name.
      local expected
      expected="$(grep -i "${DEFAULT_ISO_NAME}" "$sum_file" | head -n1 | awk '{print $1}' || true)"
      if [[ -n "$expected" ]]; then
        local got
        got="$(sha256sum "$out_iso" | awk '{print $1}')"
        if [[ "$expected" == "$got" ]]; then
          ok "Checksum OK (sha256)."
        else
          warn "Checksum mismatch or unsupported format."
          warn "Expected: $expected"
          warn "Got:      $got"
        fi
      else
        warn "Could not parse checksum file automatically. Skipping verification."
      fi
    else
      warn "Checksum file present but format not recognized. Skipping verification."
    fi
  else
    warn "No checksum verification performed (missing checksum file or sha256sum)."
  fi
}

remove_iso() {
  local storage="$1"
  local iso_full_path
  iso_full_path="$(iso_path_for_storage "$storage")"
  local sum_file
  sum_file="$(dirname "$iso_full_path")/${DEFAULT_ISO_NAME}-CHECKSUM"

  if [[ -f "$iso_full_path" ]]; then
    rm -f "$iso_full_path"
    ok "Removed ISO: $iso_full_path"
  else
    warn "ISO not found: $iso_full_path"
  fi

  if [[ -f "$sum_file" ]]; then
    rm -f "$sum_file"
    ok "Removed checksum: $sum_file"
  fi
}

ensure_iso_present() {
  local storage="$1"
  local iso_full_path
  iso_full_path="$(iso_path_for_storage "$storage")"
  if [[ -f "$iso_full_path" ]]; then
    ok "ISO present: $iso_full_path"
    return 0
  fi

  if wt_yesno "$SCRIPT_NAME" "KompassOS HWE ISO not found on storage '$storage'. Download now?"; then
    download_iso "$storage"
  else
    return 1
  fi
}

next_vmid() {
  # Find a free VMID (simple approach)
  local id
  for id in $(seq 100 999999); do
    if ! qm status "$id" &>/dev/null; then
      echo "$id"
      return 0
    fi
  done
  return 1
}

create_vm() {
  local iso_storage="$1"

  ensure_iso_present "$iso_storage" || die "ISO is required to create the VM."

  local vmid name cores mem disk bridge
  vmid="$(wt_input "$SCRIPT_NAME" "VMID" "$(next_vmid)")" || return 1
  [[ "$vmid" =~ ^[0-9]+$ ]] || die "Invalid VMID."

  name="$(wt_input "$SCRIPT_NAME" "VM Name" "$DEFAULT_VM_NAME")" || return 1
  cores="$(wt_input "$SCRIPT_NAME" "CPU Cores" "4")" || return 1
  mem="$(wt_input "$SCRIPT_NAME" "Memory (MiB)" "8192")" || return 1
  disk="$(wt_input "$SCRIPT_NAME" "Disk size (GiB) - recommended ${MIN_DISK_GB}+" "64")" || return 1
  bridge="$(wt_input "$SCRIPT_NAME" "Network bridge" "vmbr0")" || return 1

  [[ "$cores" =~ ^[0-9]+$ ]] || die "Invalid cores."
  [[ "$mem" =~ ^[0-9]+$ ]] || die "Invalid memory."
  [[ "$disk" =~ ^[0-9]+$ ]] || die "Invalid disk size."

  if (( disk < MIN_DISK_GB )); then
    warn "Disk size is below recommended minimum (${MIN_DISK_GB} GiB)."
  fi

  # Choose VM disk storage (any storage with images content)
  local img_storages
  img_storages="$(pvesm status -content images 2>/dev/null | awk 'NR>1 {print $1}' | xargs || true)"
  [[ -n "$img_storages" ]] || die "No storage found that supports VM images."

  local menu_items=()
  local s
  for s in $img_storages; do
    menu_items+=("$s" "VM disk storage")
  done

  local disk_storage
  disk_storage="$(wt_menu "$SCRIPT_NAME" "Select VM disk storage (content=images)" "${menu_items[@]}")" || return 1

  local iso_vol="${iso_storage}:iso/${DEFAULT_ISO_NAME}"

  info "Creating VM $vmid ($name)..."

  # Create base VM (UEFI + q35 is best for modern OS)
  qm create "$vmid" \
    --name "$name" \
    --machine q35 \
    --bios ovmf \
    --cores "$cores" \
    --memory "$mem" \
    --balloon 0 \
    --cpu host \
    --scsihw virtio-scsi-pci \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --net0 virtio,bridge="$bridge" \
    --rng0 source=/dev/urandom

  # EFI disk
  qm set "$vmid" --efidisk0 "${disk_storage}:0,format=raw,efitype=4m,pre-enrolled-keys=1"

  # Main disk
  qm set "$vmid" --scsi0 "${disk_storage}:${disk},format=raw,ssd=1,discard=on,iothread=1"

  # ISO as CDROM
  qm set "$vmid" --ide2 "$iso_vol",media=cdrom

  # Display + USB tablet + audio off (safe defaults)
  qm set "$vmid" --vga virtio --tablet 1

  # Boot order: CDROM first for installer
  qm set "$vmid" --boot order=ide2,scsi0

  ok "VM created."
  info "Next steps:"
  echo "  1) Start the VM in the PVE GUI"
  echo "  2) Open the console and install KompassOS"
  echo "  3) After install: set boot order to scsi0 first (optional):"
  echo "     qm set $vmid --boot order=scsi0,ide2"
}

# ----------------------------
# Main
# ----------------------------
main_menu() {
  while true; do
    banner
    local choice
    choice="$(wt_menu "$SCRIPT_NAME" "Choose an action" \
      "1" "Download/Update KompassOS HWE ISO" \
      "2" "Create KompassOS HWE VM (interactive install)" \
      "3" "Remove KompassOS HWE ISO from storage" \
      "4" "Exit")" || exit 0

    case "$choice" in
      1)
        local st
        st="$(pick_storage)" || continue
        download_iso "$st"
        wt_msg "$SCRIPT_NAME" "Done.\n\nISO downloaded to storage: $st\nFile: $DEFAULT_ISO_NAME"
        ;;
      2)
        local st
        st="$(pick_storage)" || continue
        create_vm "$st"
        wt_msg "$SCRIPT_NAME" "Done.\n\nVM created. Start it from the PVE GUI and install KompassOS from ISO."
        ;;
      3)
        local st
        st="$(pick_storage)" || continue
        if wt_yesno "$SCRIPT_NAME" "Remove KompassOS HWE ISO from storage '$st'?"; then
          remove_iso "$st"
          wt_msg "$SCRIPT_NAME" "Done.\n\nIf you want it back later, use the Download option."
        fi
        ;;
      4) exit 0 ;;
      *) ;;
    esac
  done
}

need_root
pve_checks
if ! have_cmd whiptail; then
  die "whiptail not found. Install it: apt-get update && apt-get install -y whiptail"
fi

main_menu