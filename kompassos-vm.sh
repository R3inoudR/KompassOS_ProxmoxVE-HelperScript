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

  qm set "$vmid" --efidisk0 "${disk_storage}:0,format=raw,efitype=4m,pre-enrolled-keys=1"
  qm set "$vmid" --scsi0 "${disk_storage}:${disk},format=raw,ssd=1,discard=on,iothread=1"
  qm set "$vmid" --ide2 "${iso_vol},media=cdrom"
  qm set "$vmid" --vga virtio --tablet 1

  # IMPORTANT: Proxmox expects semicolons in boot order
  qm set "$vmid" --boot "order=ide2;scsi0"

  ok "VM created."
  info "Next steps:"
  echo "  1) Start the VM in the PVE GUI"
  echo "  2) Open the console and install KompassOS"
  echo "  3) After install, switch boot order to disk-first:"
  echo "     qm set $vmid --boot \"order=scsi0;ide2\""
}