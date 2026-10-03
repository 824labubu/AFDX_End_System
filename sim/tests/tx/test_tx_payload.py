"""TX-F01 payload lengths, actual flow modes and invalid contracts."""

import cocotb
from afdx.transactions import AppTransaction
from .common import TxFeatureCase, transaction, require


LENGTHS = (1, 2, 16, 64, 483, 484, 485, 515, 516, 517, 1471)


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_tx_f01_payload_lengths_continuous(dut):
    async with TxFeatureCase(dut, "test_tx_f01_payload_lengths_continuous", ["TX-F01"]) as case:
        for length in LENGTHS:
            tx = transaction(f"continuous-{length}", length)
            flow = await case.send(tx)
            require(flow["valid_gap_cycles"] == 0, "TX-F01", tx.transaction_id,
                    "app", "valid_gap_cycles", 0, flow["valid_gap_cycles"])
            await case.drain()
            await case.quiet()
        await case.finish()


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_tx_f01_payload_lengths_backpressure(dut):
    async with TxFeatureCase(dut, "test_tx_f01_payload_lengths_backpressure", ["TX-F01"]) as case:
        for length in LENGTHS:
            await case.send(transaction(f"primer-{length}", 16))
            tx = transaction(f"stalled-{length}", length)
            flow = await case.send(tx, queued=True)
            require(flow["stalled_cycles"] > 0, "TX-F01", tx.transaction_id,
                    "app", "stalled_cycles", ">0", flow["stalled_cycles"])
            await case.drain()
            await case.quiet()
        await case.finish()


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f01_zero_byte_interface_rejection(dut):
    async with TxFeatureCase(dut, "test_tx_f01_zero_byte_interface_rejection", ["TX-F01"]) as case:
        before = case.tb.app_monitor.beats_seen
        try:
            AppTransaction(b"", 40000, 16000, 3, "zero-byte")
        except ValueError as exc:
            case.rejections.append({"length": 0, "kind": "interface_reject", "reason": str(exc)})
        else:
            require(False, "TX-F01", "zero-byte", "app", "empty_transaction",
                    "ValueError; no fictitious last handshake", "accepted")
        await case.quiet()
        require(case.tb.app_monitor.beats_seen == before, "TX-F01", "zero-byte", "app",
                "accepted_bytes", before, case.tb.app_monitor.beats_seen)
        await case.send(transaction("after-zero-reject", 16))
        await case.finish()


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f01_1472_byte_drop_and_recovery(dut):
    async with TxFeatureCase(dut, "test_tx_f01_1472_byte_drop_and_recovery", ["TX-F01"]) as case:
        tx = transaction("oversize-1472", 1472)
        try:
            case.model.build(tx)
        except ValueError:
            pass
        else:
            require(False, "TX-F01", tx.transaction_id, "model", "max_payload",
                    "reject 1472", "accepted")
        await case.send(tx, expected=False)
        # Finite no-frame observation based on maximum frame serialization + margin;
        # it is not a BAG or frame-interval checker.
        await case.quiet(cycles=1600)
        case.rejections.append({"length": 1472, "kind": "dut_drop", "reason": "documented oversize"})
        await case.send(transaction("after-oversize-drop", 16))
        await case.finish()
