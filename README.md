# KompassOS Proxmox VM Helper

Create a **KompassOS virtual machine in Proxmox VE** with a guided
installer script.

This helper script downloads the **KompassOS HWE ISO**, verifies the
checksum (optional), and creates a ready-to-install VM in Proxmox.

The script follows the familiar **Proxmox Helper Scripts style
interface** with a simple interactive setup.

------------------------------------------------------------------------

## Features

-   Interactive **Default / Advanced configuration**
-   Automatic **VMID detection**
-   Select **Proxmox storage pools**
-   Automatic **KompassOS ISO download**
-   Optional **SHA256 checksum verification**
-   Creates a VM using **VirtIO devices**
-   Uses **OVMF / UEFI firmware**
-   Optional **auto-start VM after creation**

------------------------------------------------------------------------

## Requirements

-   **Proxmox VE 8.x or 9.x**
-   Root access to the Proxmox host
-   Internet access to download the KompassOS ISO

Architecture:

amd64 / x86_64

ARM / PiMox systems are **not supported**.

------------------------------------------------------------------------

## Quick Start

Run the script directly on your **Proxmox host**:

``` bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/R3inoudR/KompassOS_ProxmoxVE-HelperScript/main/kompassos-vm.sh)"
```

The installer will guide you through:

1.  Default or Advanced settings
2.  Storage selection
3.  ISO download
4.  VM creation

After the VM is created, open the **Proxmox console** to install
KompassOS.

------------------------------------------------------------------------

## Default VM Configuration

  Setting    Value
  ---------- -------------
  Machine    q35
  Firmware   OVMF / UEFI
  CPU        kvm64
  Cores      4
  RAM        8 GB
  Disk       64 GB
  Network    VirtIO
  Boot       Disk + ISO

These settings can be modified using **Advanced mode**.

------------------------------------------------------------------------

## KompassOS

KompassOS is a Linux distribution designed for modern hardware and
streamlined user experience.

Learn more:

Website\
https://www.kompassos.nl/

GitHub\
https://github.com/L0g0ff/KompassOS

ISO downloads\
https://isos.kompassos.nl/

------------------------------------------------------------------------

## License

This project is licensed under the **Apache License 2.0**.

See the LICENSE file for details.

https://www.apache.org/licenses/LICENSE-2.0

------------------------------------------------------------------------

## Contributing

Issues and pull requests are welcome.

If you encounter problems creating a VM or downloading the ISO, please
open an issue.

------------------------------------------------------------------------

## Disclaimer

This project is not affiliated with Proxmox Server Solutions GmbH.

Use at your own risk.
