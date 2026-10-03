"""Layer-local encoders using byte layout from RFC 768 / RFC 791.

No DUT headers, frame buffers or per-cycle implementation are inputs.
"""

import struct

from .checksums import ethernet_fcs, ipv4_checksum

ETHERNET_HEADER_BYTES = 14
ETHERTYPE_IPV4 = 0x0800
IPV4_MIN_HEADER_BYTES = 20
IP_PROTOCOL_UDP = 17
UDP_HEADER_BYTES = 8


def _unsigned(name, value, width):
    if not isinstance(value, int) or not 0 <= value < (1 << width):
        raise ValueError(f"{name} must fit unsigned {width} bits")


def build_udp(payload: bytes, src_port: int, dst_port: int, *, checksum_mode: str) -> bytes:
    payload = bytes(payload)
    for name, value in (("src_port", src_port), ("dst_port", dst_port),
                        ("udp_length", UDP_HEADER_BYTES + len(payload))):
        _unsigned(name, value, 16)
    if checksum_mode != "zero":
        raise ValueError("V2 project profile only supports explicit UDP checksum_mode='zero'")
    return struct.pack("!HHHH", src_port, dst_port, UDP_HEADER_BYTES + len(payload), 0) + payload


def build_ipv4(payload: bytes, src_ip: int, dst_ip: int, *, identification: int,
               flags: int, ttl: int, tos: int, protocol: int = IP_PROTOCOL_UDP,
               options: bytes = b"") -> bytes:
    payload, options = bytes(payload), bytes(options)
    if len(options) > 40 or len(options) % 4:
        raise ValueError("IPv4 options must use at most ten four-byte words")
    header_len = IPV4_MIN_HEADER_BYTES + len(options)
    for name, value, width in (
        ("src_ip", src_ip, 32), ("dst_ip", dst_ip, 32),
        ("identification", identification, 16), ("flags", flags, 3),
        ("ttl", ttl, 8), ("tos", tos, 8), ("protocol", protocol, 8),
        ("ip_total_length", header_len + len(payload), 16),
    ):
        _unsigned(name, value, width)
    header = struct.pack("!BBHHHBBHII", (4 << 4) | (header_len // 4), tos,
                         header_len + len(payload), identification, flags << 13,
                         ttl, protocol, 0, src_ip, dst_ip) + options
    header = header[:10] + ipv4_checksum(header).to_bytes(2, "big") + header[12:]
    return header + payload


def build_ethernet(payload: bytes, src_mac: bytes, dst_mac: bytes, *, eth_type: int,
                   min_frame_bytes: int, pad_byte: int, trailer: bytes = b"") -> bytes:
    """Return DA..FCS. min_frame_bytes excludes FCS; padding precedes trailer.

    For AFDX the caller supplies SN as a one-byte trailer outside IP/UDP lengths.
    """
    payload, src_mac, dst_mac, trailer = map(bytes, (payload, src_mac, dst_mac, trailer))
    if len(src_mac) != 6 or len(dst_mac) != 6:
        raise ValueError("Ethernet addresses must each contain six bytes")
    if min_frame_bytes < ETHERNET_HEADER_BYTES:
        raise ValueError("min_frame_bytes must include the Ethernet header")
    _unsigned("pad_byte", pad_byte, 8)
    _unsigned("eth_type", eth_type, 16)
    header = struct.pack("!6s6sH", dst_mac, src_mac, eth_type)
    padding = bytes([pad_byte]) * max(0, min_frame_bytes - len(header + payload + trailer))
    body = header + payload + padding + trailer
    return body + ethernet_fcs(body)
