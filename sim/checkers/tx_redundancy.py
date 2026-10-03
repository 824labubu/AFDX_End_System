"""Compare logical A/B semantics in addition to separate per-network reference checks."""

from scoreboard.tx_scoreboard import FieldMismatch


SEMANTIC_FIELDS = (
    "ip_version", "ip_ihl", "ip_tos", "ip_total_length", "ip_identification",
    "ip_flags", "ip_fragment_offset", "ip_ttl", "ip_protocol", "src_ip", "dst_ip",
    "ip_options", "udp_src_port", "udp_dst_port", "udp_length", "udp_checksum",
    "payload", "ip_trailing_bytes", "sequence_number",
)


class AbSemanticMismatch(AssertionError):
    def __init__(self, transaction_id, mismatches):
        self.transaction_id, self.mismatches = transaction_id, tuple(mismatches)
        super().__init__("\n".join(
            f"[RED-F02][id={transaction_id}][A/B] field={m.field} "
            f"expected(A)={m.expected!r} actual(B)={m.actual!r}" for m in mismatches))


def check_ab_semantics(frame_a, frame_b, transaction_id):
    # MAC addresses and FCS are deliberately excluded; each is separately
    # checked against its own network's independent configured reference.
    mismatches = [FieldMismatch(name, getattr(frame_a, name), getattr(frame_b, name))
                  for name in SEMANTIC_FIELDS
                  if getattr(frame_a, name) != getattr(frame_b, name)]
    if mismatches:
        raise AbSemanticMismatch(transaction_id, mismatches)
