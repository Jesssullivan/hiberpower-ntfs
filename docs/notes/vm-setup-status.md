# Windows VM Setup Status

## Component Status

| Component | Status | Location |
|-----------|--------|----------|
| VM Disk Image | Ready | `images/qcow2/windows-frida.qcow2` (60GB) |
| UEFI Firmware | Ready | `images/qcow2/OVMF_VARS.fd` |
| VirtIO Drivers | Ready | `/usr/share/virtio-win/virtio-win.iso` |
| VM Start Script | Ready | `scripts/start-frida-vm.sh` |
| Frida Hooks | Ready | `vm-package/hooks.js` |
| Capture Controller | Ready | `vm-package/capture.py` |
| Windows Setup Script | Ready | `vm-package/windows-setup.ps1` |
| SP Toolbox | Ready | `downloads/SP_Toolbox_V4.1.2-20251128/` |
| **Windows ISO** | Ready | `images/Win10.iso` (5.8GB, Win10 22H2) |

## Windows 10 ISO Download Instructions

Microsoft's automated download protection is active. Manual download required:

### Option 1: Browser User-Agent Trick (Recommended)
1. Open Firefox/Chrome and go to: `https://www.microsoft.com/en-us/software-download/windows10ISO`
2. Press F12 → Network tab → Click "Responsive Design Mode" icon
3. Select "iPad" or "iPhone" as device
4. Refresh the page
5. You'll now see the direct ISO download option
6. Select "Windows 10 (multi-edition ISO)" and your language
7. Download the 64-bit ISO (~5.8 GB)

### Option 2: Using Rufus (on Windows)
1. Download Rufus from https://rufus.ie
2. Run Rufus, click the dropdown arrow next to SELECT
3. Choose "Download"
4. Select Windows 10, version 22H2, x64
5. Rufus will download the official ISO

### Option 3: Media Creation Tool (on Windows)
1. Download from: https://www.microsoft.com/software-download/windows10
2. Run, select "Create installation media"
3. Choose ISO file option

## After Downloading Windows ISO

1. Place the ISO file in a known location (e.g., `~/Downloads/`)

2. Start the VM in install mode:
   ```bash
   WIN_ISO=/path/to/Windows10.iso ./scripts/start-frida-vm.sh install
   ```

3. Install Windows:
   - Load VirtIO storage driver during installation (from D: drive)
   - Complete Windows installation normally

4. After Windows is installed, run `./scripts/start-frida-vm.sh run` for USB passthrough

## Next Steps After Windows Installation

1. In Windows, open PowerShell as Administrator
2. Run the setup script from the shared folder or paste:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process
   # Then run windows-setup.ps1
   ```

3. Install Python from https://www.python.org/downloads/
4. Install Frida: `pip install frida frida-tools`
5. Copy `hooks.js` and `capture.py` to `C:\HiberPower-Capture\`
6. Copy SP Toolbox from the shared folder
7. Run capture:
   ```
   cd C:\HiberPower-Capture
   python capture.py spawn "path\to\SP Toolbox.exe"
   ```
