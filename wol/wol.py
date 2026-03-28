
import socket
import binascii

def send_wol(mac_address, broadcast_ip, port=9):
    # Clean up MAC address
    mac_clean = mac_address.replace(':', '').replace('-', '').upper()
    
    # Convert to bytes
    mac_bytes = binascii.unhexlify(mac_clean)
    
    # Build magic packet: 6 x FF + 16 x MAC
    magic_packet = b'\xFF' * 6 + mac_bytes * 16
    
    # Send it
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.sendto(magic_packet, (broadcast_ip, port))
    sock.close()
    
    print(f"Sent {len(magic_packet)} byte magic packet to {broadcast_ip}:{port}")

# Test with your actual MAC and IP
send_wol("2c:f0:5d:e2:cd:94", "192.168.68.255")