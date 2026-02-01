#!/usr/bin/env python3
"""
Frida-based command capture controller for SP Toolbox.

This script provides programmatic control over the Frida hooks for capturing
SCSI/NVMe passthrough commands from Windows applications.

Usage:
    python capture.py spawn "C:\\Program Files\\SP Toolbox\\SPToolbox.exe"
    python capture.py attach <PID>
    python capture.py attach --name "SPToolbox.exe"

Requirements:
    pip install frida frida-tools
"""

import argparse
import json
import os
import signal
import sys
import time
from pathlib import Path

try:
    import frida
except ImportError:
    print("Error: frida not installed. Run: pip install frida frida-tools")
    sys.exit(1)


class CommandCapture:
    """Controller for Frida-based command capture."""

    def __init__(self, script_path: str = None):
        self.device = frida.get_local_device()
        self.session = None
        self.script = None
        self.pid = None
        self.captured_commands = []

        # Default to hooks.js in same directory
        if script_path is None:
            script_path = Path(__file__).parent / "hooks.js"
        self.script_path = Path(script_path)

        if not self.script_path.exists():
            raise FileNotFoundError(f"Frida script not found: {self.script_path}")

    def _on_message(self, message, data):
        """Handle messages from Frida script."""
        if message['type'] == 'send':
            payload = message['payload']
            print(f"[Frida] {payload}")
        elif message['type'] == 'error':
            print(f"[Frida Error] {message['stack']}")
        else:
            print(f"[Frida] {message}")

    def spawn(self, program: str, args: list = None) -> int:
        """Spawn a new process and attach Frida."""
        print(f"Spawning: {program}")
        spawn_args = [program]
        if args:
            spawn_args.extend(args)

        self.pid = self.device.spawn(spawn_args)
        print(f"Spawned PID: {self.pid}")

        self._attach(self.pid)
        self.device.resume(self.pid)
        print("Process resumed")

        return self.pid

    def attach_pid(self, pid: int):
        """Attach to an existing process by PID."""
        print(f"Attaching to PID: {pid}")
        self.pid = pid
        self._attach(pid)

    def attach_name(self, name: str):
        """Attach to an existing process by name."""
        print(f"Looking for process: {name}")
        try:
            self.pid = self.device.get_process(name).pid
            print(f"Found PID: {self.pid}")
            self._attach(self.pid)
        except frida.ProcessNotFoundError:
            print(f"Error: Process '{name}' not found")
            sys.exit(1)

    def _attach(self, pid: int):
        """Internal: attach to process and load script."""
        self.session = self.device.attach(pid)
        self.session.on('detached', self._on_detached)

        script_code = self.script_path.read_text()
        self.script = self.session.create_script(script_code)
        self.script.on('message', self._on_message)
        self.script.load()
        print("Frida script loaded")

    def _on_detached(self, reason):
        """Handle session detachment."""
        print(f"\n[Frida] Detached: {reason}")

    def get_captured_commands(self) -> list:
        """Get all captured commands from the script."""
        if self.script:
            return self.script.exports.get_captured_commands()
        return []

    def get_statistics(self) -> dict:
        """Get capture statistics."""
        if self.script:
            return self.script.exports.get_stats()
        return {}

    def get_devices(self) -> dict:
        """Get tracked device handles."""
        if self.script:
            return self.script.exports.get_devices()
        return {}

    def clear_capture(self):
        """Clear captured commands."""
        if self.script:
            return self.script.exports.clear_capture()

    def export_json(self) -> str:
        """Export captured commands as JSON."""
        if self.script:
            return self.script.exports.export_json()
        return "[]"

    def save_to_file(self, filename: str):
        """Save captured commands to a JSON file."""
        commands = self.get_captured_commands()
        with open(filename, 'w') as f:
            json.dump(commands, f, indent=2)
        print(f"Saved {len(commands)} commands to {filename}")

    def detach(self):
        """Detach from the process."""
        if self.session:
            self.session.detach()
            print("Detached from process")

    def interactive(self):
        """Run in interactive mode."""
        print("\n" + "=" * 60)
        print("Interactive Mode - Commands:")
        print("=" * 60)
        print("  stats     - Show capture statistics")
        print("  devices   - Show tracked device handles")
        print("  commands  - Show captured commands (JSON)")
        print("  save FILE - Save commands to file")
        print("  clear     - Clear captured commands")
        print("  quit      - Exit")
        print("=" * 60 + "\n")

        try:
            while True:
                try:
                    cmd = input("capture> ").strip()
                except EOFError:
                    break

                if not cmd:
                    continue

                parts = cmd.split()
                action = parts[0].lower()

                if action in ('quit', 'exit', 'q'):
                    break
                elif action == 'stats':
                    stats = self.get_statistics()
                    print(json.dumps(stats, indent=2))
                elif action == 'devices':
                    devices = self.get_devices()
                    print(json.dumps(devices, indent=2))
                elif action == 'commands':
                    print(self.export_json())
                elif action == 'save' and len(parts) > 1:
                    self.save_to_file(parts[1])
                elif action == 'clear':
                    self.clear_capture()
                    print("Cleared")
                else:
                    print(f"Unknown command: {cmd}")

        except KeyboardInterrupt:
            print("\nInterrupted")

        finally:
            self.detach()


def main():
    parser = argparse.ArgumentParser(
        description="Capture SCSI/NVMe commands from Windows applications using Frida"
    )
    subparsers = parser.add_subparsers(dest='action', required=True)

    # Spawn subcommand
    spawn_parser = subparsers.add_parser('spawn', help='Spawn a new process')
    spawn_parser.add_argument('program', help='Program to spawn')
    spawn_parser.add_argument('args', nargs='*', help='Arguments to pass')
    spawn_parser.add_argument('-o', '--output', help='Output file for captured commands')

    # Attach subcommand
    attach_parser = subparsers.add_parser('attach', help='Attach to existing process')
    attach_group = attach_parser.add_mutually_exclusive_group(required=True)
    attach_group.add_argument('pid', type=int, nargs='?', help='Process ID')
    attach_group.add_argument('-n', '--name', help='Process name')
    attach_parser.add_argument('-o', '--output', help='Output file for captured commands')

    # List subcommand
    list_parser = subparsers.add_parser('list', help='List running processes')

    args = parser.parse_args()

    if args.action == 'list':
        device = frida.get_local_device()
        print("\nRunning processes:")
        print("-" * 60)
        for proc in device.enumerate_processes():
            print(f"  {proc.pid:6d}  {proc.name}")
        return

    # Create capture controller
    capture = CommandCapture()

    # Handle Ctrl+C gracefully
    def signal_handler(sig, frame):
        print("\n\nCaught interrupt, saving and exiting...")
        if args.output:
            capture.save_to_file(args.output)
        capture.detach()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)

    # Attach or spawn
    if args.action == 'spawn':
        capture.spawn(args.program, args.args)
    elif args.action == 'attach':
        if args.pid:
            capture.attach_pid(args.pid)
        else:
            capture.attach_name(args.name)

    # Run interactive mode
    capture.interactive()

    # Save on exit if output specified
    if args.output:
        capture.save_to_file(args.output)


if __name__ == '__main__':
    main()
