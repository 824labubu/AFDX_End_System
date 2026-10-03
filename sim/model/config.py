"""Explicit project configuration, separate from protocol encoding constants.

TB_ONLY_DEFAULT reproduces the documented current project setup for smoke
comparison; it does not freeze production addresses, VL mappings or SN policy.
No values are obtained by inspecting a DUT handle or reading RTL source.
"""

from dataclasses import dataclass
from ipaddress import IPv4Address
from types import MappingProxyType
from typing import Mapping


@dataclass(frozen=True)
class NetworkConfig:
    src_mac: bytes
    dst_mac: bytes

    def __post_init__(self):
        for name in ("src_mac", "dst_mac"):
            value = bytes(getattr(self, name))
            if len(value) != 6:
                raise ValueError(f"{name} must contain six bytes")
            object.__setattr__(self, name, value)


@dataclass(frozen=True)
class PortConfig:
    vl_id: int
    src_ip: int
    dst_ip: int
    networks: Mapping[str, NetworkConfig]

    def __post_init__(self):
        for name, bits in (("vl_id", 16), ("src_ip", 32), ("dst_ip", 32)):
            if not 0 <= getattr(self, name) < (1 << bits):
                raise ValueError(f"{name} must fit {bits} bits")
        if set(self.networks) != {"a", "b"}:
            raise ValueError("V2 dual-network profile requires independent A and B configuration")
        object.__setattr__(self, "networks", MappingProxyType(dict(self.networks)))


@dataclass(frozen=True)
class TxModelConfig:
    label: str
    ports: Mapping[int, PortConfig]
    max_payload_bytes: int
    min_frame_bytes: int       # DA through SN, without FCS
    max_frame_bytes: int       # DA through FCS
    pad_byte: int
    udp_checksum_mode: str
    ip_identification: int
    ip_flags: int
    ip_ttl: int
    ip_tos: int
    sequence_first: int
    sequence_last: int

    def __post_init__(self):
        if not self.ports or any(not 0 <= port <= 255 for port in self.ports):
            raise ValueError("ports must map byte-wide application identifiers")
        if self.max_payload_bytes < 1 or self.min_frame_bytes < 14:
            raise ValueError("invalid payload/minimum frame size")
        if self.max_frame_bytes < self.min_frame_bytes + 4:
            raise ValueError("maximum frame size includes FCS")
        if not 0 <= self.pad_byte <= 255:
            raise ValueError("pad_byte must fit one byte")
        if self.udp_checksum_mode != "zero":
            raise ValueError("V2 only models the configured zero UDP checksum profile")
        if not 1 <= self.sequence_first <= self.sequence_last <= 255:
            raise ValueError("V2 project sequence range must be within 1..255")
        object.__setattr__(self, "ports", MappingProxyType(dict(self.ports)))


def tb_only_default_config() -> TxModelConfig:
    # Explicit route table, rather than translating the RTL routing functions.
    rows = (
        (1, 1, "10.1.1.1", "244.244.0.1", "030000000001"),
        (2, 2, "10.1.1.2", "10.1.2.2", "030000000002"),
        (3, 3, "10.1.1.3", "10.1.2.3", "030000000003"),
        (4, 4, "10.1.1.4", "10.1.2.4", "030000000004"),
        (5, 5, "10.1.1.5", "10.1.2.5", "030000000005"),
    )
    ports = {}
    for port, vl, src_ip, dst_ip, dst_mac in rows:
        ports[port] = PortConfig(vl, int(IPv4Address(src_ip)), int(IPv4Address(dst_ip)), {
            "a": NetworkConfig(bytes.fromhex("020000010120"), bytes.fromhex(dst_mac)),
            "b": NetworkConfig(bytes.fromhex("020000010140"), bytes.fromhex(dst_mac)),
        })
    return TxModelConfig("TB_ONLY_DEFAULT", ports, 1471, 60, 1518, 0xaa, "zero",
                         0, 2, 1, 0, 1, 255)


TB_ONLY_DEFAULT_MODEL_CONFIG = tb_only_default_config()
