"""Basic TX scoreboard. No internal DUT signals, timing or scheduler model."""

from collections import deque
from dataclasses import dataclass, fields
from pathlib import Path
import json
from typing import Any

from decoder.tx_frame_decoder import DecodedTxFrame, FrameDecodeError, decode_tx_frame
from model.checksums import ethernet_crc32, internet_checksum
from model.tx_reference import ExpectedTxFrame


def _json_value(value):
    return value.hex() if isinstance(value, bytes) else value


def _display(value):
    if isinstance(value, bytes):
        return value[:16].hex() + (f"... ({len(value)} B)" if len(value) > 16 else "")
    if isinstance(value, int) and not isinstance(value, bool):
        return f"0x{value:x} ({value})"
    return str(value)


@dataclass(frozen=True)
class FieldMismatch:
    field: str
    expected: Any
    actual: Any


@dataclass(frozen=True)
class ByteDifference:
    offset: int
    expected: int | None
    actual: int | None


@dataclass(frozen=True)
class TxComparison:
    test_name: str
    transaction_id: str
    network: str
    timestamp_ns: float
    expected_length: int
    actual_length: int
    mismatches: tuple[FieldMismatch, ...]
    first_difference: ByteDifference | None
    expected_bytes: bytes
    actual_bytes: bytes

    @property
    def passed(self):
        return not self.mismatches

    def to_dict(self):
        return {
            "test_name": self.test_name, "transaction_id": self.transaction_id,
            "protocol": "Ethernet/IPv4/UDP/AFDX", "network": self.network,
            "timestamp_ns": self.timestamp_ns, "expected_length": self.expected_length,
            "actual_length": self.actual_length, "passed": self.passed,
            "mismatches": [{"field": m.field, "expected": _json_value(m.expected),
                            "actual": _json_value(m.actual)} for m in self.mismatches],
            "first_difference": vars(self.first_difference) if self.first_difference else None,
            "expected_bytes": self.expected_bytes.hex(), "actual_bytes": self.actual_bytes.hex(),
        }

    def format(self):
        title = "TX FRAME MATCH" if self.passed else "TX FRAME MISMATCH"
        lines = [title, f"test={self.test_name} transaction={self.transaction_id} "
                       f"network={self.network.upper()} timestamp_ns={self.timestamp_ns}",
                 "protocol=Ethernet/IPv4/UDP/AFDX "
                 f"expected_length={self.expected_length} actual_length={self.actual_length}",
                 f"{'field':24} {'expected':34} actual"]
        lines.extend(f"{m.field:24} {_display(m.expected):34} {_display(m.actual)}"
                     for m in self.mismatches)
        if self.first_difference:
            first = self.first_difference
            lines.append(f"first_difference: byte_offset={first.offset} "
                         f"expected={_display(first.expected)} actual={_display(first.actual)}")
        return "\n".join(lines)


class TxFrameMismatch(AssertionError):
    def __init__(self, report: TxComparison):
        self.report = report
        super().__init__(report.format())


def _first_difference(expected, actual):
    for offset in range(max(len(expected), len(actual))):
        e = expected[offset] if offset < len(expected) else None
        a = actual[offset] if offset < len(actual) else None
        if e != a:
            return ByteDifference(offset, e, a)
    return None


def compare_tx_frame(expected: ExpectedTxFrame | None, actual: bytes | DecodedTxFrame,
                     *, test_name: str, network: str, timestamp_ns: float,
                     gmii_error: bool = False) -> TxComparison:
    raw = actual.raw_bytes if isinstance(actual, DecodedTxFrame) else bytes(actual)
    expected_raw = expected.frame_bytes if expected is not None else b""
    differences = []

    def check(name, e, a):
        if e != a:
            differences.append(FieldMismatch(name, e, a))

    if expected is None:
        differences.append(FieldMismatch("unexpected_frame", "no pending transaction", "frame observed"))
    else:
        check("network", expected.network, network)
        check("frame_length", len(expected_raw), len(raw))
        try:
            decoded = actual if isinstance(actual, DecodedTxFrame) else decode_tx_frame(raw)
        except FrameDecodeError as exc:
            differences.append(FieldMismatch("decode_error", "complete declared field ranges", str(exc)))
        else:
            for field in fields(DecodedTxFrame):
                if field.name not in {"raw_bytes", "ip_header"}:
                    check(field.name, getattr(expected.decoded, field.name), getattr(decoded, field.name))
            check("payload_length", expected.decoded.payload_length, decoded.payload_length)
            # Verify actual checksums independently, even if a caller hands us
            # expected fields with a self-consistent but incorrect checksum.
            check("ip_checksum_valid", True, internet_checksum(decoded.ip_header) == 0)
            check("fcs_valid", True, ethernet_crc32(raw[:-4]) == decoded.fcs)
    check("gmii_tx_error", False, bool(gmii_error))
    first = _first_difference(expected_raw, raw)
    if first is not None and not differences:
        differences.append(FieldMismatch("wire_bytes", "exact expected bytes", "byte difference"))
    return TxComparison(test_name, expected.transaction_id if expected else "<unexpected>",
                        network, timestamp_ns, len(expected_raw), len(raw), tuple(differences),
                        first, expected_raw, raw)


class TxScoreboard:
    def __init__(self, test_name: str):
        self.test_name = test_name
        self.pending = {network: deque() for network in ("a", "b")}
        self.expected_count = {network: 0 for network in self.pending}
        self.observed_count = {network: 0 for network in self.pending}
        self.matched_count = {network: 0 for network in self.pending}
        self.reports = []

    def expect(self, frames):
        frames = tuple(frames)
        if any(frame.network not in self.pending for frame in frames):
            raise ValueError("expected frames must identify network a or b")
        for frame in frames:
            self.pending[frame.network].append(frame)
            self.expected_count[frame.network] += 1

    def observe(self, network, raw_frame, *, timestamp_ns, gmii_error=False):
        if network not in self.pending:
            raise ValueError("actual network must be a or b")
        self.observed_count[network] += 1
        expected = self.pending[network].popleft() if self.pending[network] else None
        report = compare_tx_frame(expected, raw_frame, test_name=self.test_name,
                                  network=network, timestamp_ns=timestamp_ns, gmii_error=gmii_error)
        self.reports.append(report)
        if not report.passed:
            raise TxFrameMismatch(report)
        self.matched_count[network] += 1
        return report

    def finish(self, *, timestamp_ns):
        if not sum(self.expected_count.values()):
            raise AssertionError("scoreboard has no expected frames")
        for network, queue in self.pending.items():
            if queue:
                report = compare_tx_frame(queue[0], b"", test_name=self.test_name,
                                          network=network, timestamp_ns=timestamp_ns)
                self.reports.append(report)
                raise TxFrameMismatch(report)
        if any(not report.passed for report in self.reports):
            raise TxFrameMismatch(next(r for r in self.reports if not r.passed))

    def summary(self):
        return {
            "test_name": self.test_name, "expected": dict(self.expected_count),
            "observed": dict(self.observed_count), "matched": dict(self.matched_count),
            "pending": {n: len(q) for n, q in self.pending.items()},
            "mismatch_count": sum(not report.passed for report in self.reports),
            "comparisons": [report.to_dict() for report in self.reports],
        }

    def write_artifact(self, path):
        Path(path).write_text(json.dumps(self.summary(), indent=2) + "\n", encoding="utf-8")
