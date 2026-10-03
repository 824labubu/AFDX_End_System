"""Parse the current untagged Ethernet/IPv4/UDP + pad + AFDX SN profile.

Input starts at DA and includes FCS; preamble/SFD are NOT input. At the BFM
boundary use bytes(GmiiFrame.get_payload(strip_fcs=False)). The pinned library
locates SFD and returns subsequent bytes unchanged; default strip_fcs=True
would silently remove the FCS needed here. No GmiiFrame.check_fcs() is used.

Checks below are only structural bounds needed to locate fields. This parser
does not reject incorrect MACs, EtherType/version/protocol values, checksums,
padding, SN or minimum-frame size: those are checker responsibilities.
"""

from dataclasses import dataclass
import struct


class FrameDecodeError(ValueError):
    """Frame cannot be safely separated into the declared header/data ranges."""


@dataclass(frozen=True)
class DecodedTxFrame:
    raw_bytes: bytes
    dst_mac: bytes
    src_mac: bytes
    eth_type: int
    ip_version: int
    ip_ihl: int
    ip_tos: int
    ip_total_length: int
    ip_identification: int
    ip_flags: int
    ip_fragment_offset: int
    ip_ttl: int
    ip_protocol: int
    src_ip: int
    dst_ip: int
    ip_checksum: int
    ip_header: bytes
    ip_options: bytes
    udp_src_port: int
    udp_dst_port: int
    udp_length: int
    udp_checksum: int
    payload: bytes
    ip_trailing_bytes: bytes
    sequence_number: int
    padding: bytes
    fcs: int

    @property
    def frame_length(self):
        return len(self.raw_bytes)

    @property
    def payload_length(self):
        return len(self.payload)


def decode_tx_frame(frame: bytes) -> DecodedTxFrame:
    raw = bytes(frame)
    if len(raw) < 14 + 20 + 8 + 1 + 4:
        raise FrameDecodeError(f"frame_length={len(raw)}: truncated Ethernet/IPv4/UDP/SN/FCS")
    dst_mac, src_mac, eth_type = struct.unpack_from("!6s6sH", raw)
    (version_ihl, tos, total_length, identification, flags_offset,
     ttl, protocol, checksum, src_ip, dst_ip) = struct.unpack_from("!BBHHHBBHII", raw, 14)
    ihl = version_ihl & 15
    header_length = ihl * 4
    sequence_offset = len(raw) - 5
    udp_offset = 14 + header_length
    ip_end = 14 + total_length
    if ihl < 5 or udp_offset + 8 > sequence_offset:
        raise FrameDecodeError(f"ip_ihl={ihl}: cannot locate complete IPv4/UDP headers")
    if total_length < header_length + 8 or ip_end > sequence_offset:
        raise FrameDecodeError(f"ip_total_length={total_length}: IP range overlaps headers or SN/FCS")
    src_port, dst_port, udp_length, udp_checksum = struct.unpack_from("!HHHH", raw, udp_offset)
    udp_end = udp_offset + udp_length
    if udp_length < 8 or udp_end > sequence_offset:
        raise FrameDecodeError(f"udp_length={udp_length}: UDP range overlaps headers or SN/FCS")
    # UDP length controls app extraction; IP length controls Ethernet padding.
    # Their disagreement is preserved for the scoreboard, not silently fixed.
    return DecodedTxFrame(
        raw, dst_mac, src_mac, eth_type, version_ihl >> 4, ihl, tos,
        total_length, identification, flags_offset >> 13, flags_offset & 0x1fff,
        ttl, protocol, src_ip, dst_ip, checksum, raw[14:udp_offset], raw[34:udp_offset],
        src_port, dst_port, udp_length, udp_checksum, raw[udp_offset + 8:udp_end],
        raw[udp_end:ip_end], raw[sequence_offset], raw[ip_end:sequence_offset],
        int.from_bytes(raw[-4:], "little"),
    )
