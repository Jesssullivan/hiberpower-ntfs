HiberPower Frida Capture Package
================================

This folder contains everything needed for capturing SP Toolbox commands.

INSTALLATION STEPS:
==================

1. Install Python 3.x from https://www.python.org/downloads/
   - Check "Add Python to PATH" during installation

2. Open PowerShell/CMD and install Frida:
   pip install frida frida-tools

3. Install SP Toolbox from Silicon Power website:
   https://www.silicon-power.com/web/download-toolbox

4. Copy this entire folder to a convenient location (e.g., C:\Capture)

USAGE:
======

Option A - Use capture.py (Recommended):
   cd C:\Capture
   python capture.py spawn "C:\Program Files\SP Toolbox\SPToolbox.exe"

   Interactive commands:
   - stats     : Show capture statistics
   - commands  : Show captured commands (JSON)
   - save FILE : Save to file
   - quit      : Exit

Option B - Direct Frida attach:
   1. Start SP Toolbox normally
   2. Find PID: tasklist | findstr SP
   3. Run: frida -p <PID> -l hooks.js

CAPTURE WORKFLOW:
=================

1. Start capture (using Option A above)
2. In SP Toolbox:
   - Wait for drive detection
   - Select the ASM2362 USB drive
   - Navigate to Secure Erase / Sanitize
   - DON'T execute if you want to preserve data
   - OR execute on a TEST drive to capture full sequence
3. In capture prompt:
   save captured_commands.json
4. Transfer JSON file back to Linux for analysis

EXPECTED COMMANDS:
==================

For secure erase, SP Toolbox typically sends:
- Identify Controller (0x06)
- Identify Namespace (0x06)
- Get Log Page / SMART (0x02)
- Get Features (0x0A)
- Format NVM (0x80) or Sanitize (0x84)

FILES IN THIS PACKAGE:
======================

- hooks.js      : Frida script for DeviceIoControl interception
- capture.py    : Python controller for programmatic capture
- README.txt    : This file
