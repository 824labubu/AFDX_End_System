"""Pure GMII prefix/IFG checks. There is deliberately no BAG comparison."""

PREAMBLE_SFD = bytes([0x55]*7 + [0xd5])


class WireMismatch(AssertionError):
    def __init__(self, feature, transaction_id, network, field, expected, actual, **context):
        self.details = dict(feature=feature, transaction_id=transaction_id, network=network,
                            field=field, expected=expected, actual=actual, **context)
        super().__init__(f"[{feature}][id={transaction_id}][{network.upper()}] "
                         f"field={field} expected={expected!r} actual={actual!r} "
                         + " ".join(f"{k}={v}" for k, v in context.items()))


def check_preamble(record, transaction_id):
    prefix = bytes(record["prefix"])
    if prefix != PREAMBLE_SFD:
        offset = next(i for i in range(max(len(prefix), len(PREAMBLE_SFD)))
                      if prefix[i:i+1] != PREAMBLE_SFD[i:i+1])
        raise WireMismatch("TX-F10", transaction_id, record["network"], "preamble_sfd",
                           PREAMBLE_SFD.hex(), prefix.hex(), byte_offset=offset,
                           next_start=record["start_ns"])


def check_ifg(record, transaction_id, required_cycles):
    gap = record["idle_cycles"]
    if gap is not None and gap < required_cycles:
        raise WireMismatch("TX-F11", transaction_id, record["network"], "ifg_idle_cycles",
                           required_cycles, gap, previous_end=record["previous_end_ns"],
                           next_start=record["start_ns"], observed_cycles=gap,
                           required_cycles=required_cycles)
