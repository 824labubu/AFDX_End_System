"""Transaction-level reference: protocol builders + configuration + own state."""

from dataclasses import dataclass, field

from afdx.transactions import AppTransaction
from decoder.tx_frame_decoder import DecodedTxFrame, decode_tx_frame
from .builders import ETHERTYPE_IPV4, build_ethernet, build_ipv4, build_udp
from .config import TxModelConfig


@dataclass
class ReferenceState:
    sequence_by_vl: dict[int, int] = field(default_factory=dict)

    def allocate(self, vl_id: int, first: int, last: int) -> int:
        previous = self.sequence_by_vl.get(vl_id)
        if previous is not None and not first <= previous <= last:
            raise ValueError("stored reference sequence is outside the configured range")
        value = first if previous is None or previous == last else previous + 1
        self.sequence_by_vl[vl_id] = value
        return value

    def reset(self):
        self.sequence_by_vl.clear()


@dataclass(frozen=True)
class ExpectedTxFrame:
    network: str
    transaction_id: str
    frame_bytes: bytes
    decoded: DecodedTxFrame
    vl_id: int
    sequence_number: int


class AfdxTxReferenceModel:
    def __init__(self, config: TxModelConfig, state: ReferenceState | None = None):
        self.config = config
        self.state = state if state is not None else ReferenceState()

    def reset(self):
        self.state.reset()

    def build(self, transaction: AppTransaction) -> tuple[ExpectedTxFrame, ExpectedTxFrame]:
        cfg = self.config
        if transaction.application_port not in cfg.ports:
            raise ValueError(f"unconfigured application port {transaction.application_port}")
        if len(transaction) > cfg.max_payload_bytes:
            raise ValueError(f"payload length {len(transaction)} exceeds model configuration")
        route = cfg.ports[transaction.application_port]
        udp = build_udp(transaction.payload, transaction.src_udp, transaction.dst_udp,
                        checksum_mode=cfg.udp_checksum_mode)
        ip = build_ipv4(udp, route.src_ip, route.dst_ip,
                        identification=cfg.ip_identification, flags=cfg.ip_flags,
                        ttl=cfg.ip_ttl, tos=cfg.ip_tos)
        if max(cfg.min_frame_bytes, 14 + len(ip) + 1) + 4 > cfg.max_frame_bytes:
            raise ValueError("constructed frame exceeds configured maximum frame size")
        sn = self.state.allocate(route.vl_id, cfg.sequence_first, cfg.sequence_last)
        copies = []
        # Allocate SN once per logical frame. Encode Ethernet and FCS separately
        # for each network, using that network's own address configuration.
        for name in ("a", "b"):
            network = route.networks[name]
            raw = build_ethernet(ip, network.src_mac, network.dst_mac,
                                 eth_type=ETHERTYPE_IPV4, min_frame_bytes=cfg.min_frame_bytes,
                                 pad_byte=cfg.pad_byte, trailer=bytes([sn]))
            copies.append(ExpectedTxFrame(name, transaction.transaction_id, raw,
                                           decode_tx_frame(raw), route.vl_id, sn))
        return tuple(copies)
