"""Checksum primitives independent of the DUT.

Internet checksum: RFC 1071, including end-around carry and odd-byte padding.
CRC-32/ISO-HDLC uses the standard-library implementation, not an RTL-derived
bit loop: poly=0x04c11db7, init/xorout=0xffffffff, refin/refout=True.
The returned CRC is a number; Ethernet transmits its four bytes little-endian.
CRC covers DA through padding AND the AFDX SN, excluding preamble/SFD/FCS.
"""

import binascii
import struct


def ethernet_crc32(data: bytes) -> int:
    # The library API already handles the initial/final complements. Supplying
    # an initial value of 0xffffffff here would apply the wrong API convention.
    return binascii.crc32(data) & 0xffffffff


def ethernet_fcs(data: bytes) -> bytes:
    return ethernet_crc32(data).to_bytes(4, "little")


def internet_checksum(data: bytes) -> int:
    data = bytes(data)
    if len(data) % 2:
        data += b"\x00"
    total = sum(word[0] for word in struct.iter_unpack("!H", data))
    while total >> 16:
        total = (total & 0xffff) + (total >> 16)
    return total ^ 0xffff


def ipv4_checksum(header: bytes) -> int:
    """Generate the checksum after clearing the IPv4 checksum field.

    Call internet_checksum(header) to verify an already-populated header;
    a valid header then gives zero. This generator accepts header bytes only.
    """
    header = bytes(header)
    if len(header) < 20 or len(header) > 60 or len(header) % 4:
        raise ValueError("IPv4 header must contain 20..60 bytes in four-byte words")
    return internet_checksum(header[:10] + b"\x00\x00" + header[12:])
