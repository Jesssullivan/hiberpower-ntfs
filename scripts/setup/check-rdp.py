#!/usr/bin/env python3
"""Check if RDP server is actually responding with proper protocol."""
import socket
import sys

def check_rdp(host='localhost', port=3389, timeout=5):
    """
    Send RDP connection request and check for valid response.
    RDP servers respond with X.224 Connection Confirm.
    """
    # X.224 Connection Request (TPKT + X.224 CR)
    # This is the initial RDP connection request
    connection_request = bytes([
        # TPKT Header
        0x03,  # Version
        0x00,  # Reserved
        0x00, 0x13,  # Length (19 bytes)
        # X.224 Connection Request
        0x0e,  # Length indicator
        0xe0,  # CR (Connection Request)
        0x00, 0x00,  # DST-REF
        0x00, 0x00,  # SRC-REF
        0x00,  # Class
        # Cookie (empty)
        0x01, 0x00, 0x08,  # RDP Negotiation Request
        0x00, 0x00, 0x00, 0x00  # Flags and protocols
    ])

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.send(connection_request)

        # Wait for response
        response = sock.recv(1024)
        sock.close()

        if len(response) >= 11:
            # Check for X.224 Connection Confirm (0xd0) or Negotiation Response
            if response[5] == 0xd0:
                return True, "RDP server responding (Connection Confirm)"
            elif response[5] == 0xf0:
                return True, "RDP server responding (Data)"

        return False, f"Unexpected response: {response[:20].hex()}"

    except socket.timeout:
        return False, "Connection timeout (no response)"
    except ConnectionRefusedError:
        return False, "Connection refused"
    except ConnectionResetError:
        return False, "Connection reset (port forwarded but no RDP server)"
    except Exception as e:
        return False, f"Error: {e}"

if __name__ == '__main__':
    host = sys.argv[1] if len(sys.argv) > 1 else 'localhost'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 3389

    success, message = check_rdp(host, port)
    print(f"RDP Check: {message}")
    sys.exit(0 if success else 1)
