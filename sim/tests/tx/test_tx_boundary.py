"""TX-F02 accepted last, valid gaps and queued messages."""

import cocotb

from .common import TxFeatureCase, transaction, require


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f02_last_under_backpressure(dut):
    async with TxFeatureCase(dut, "test_tx_f02_last_under_backpressure", ["TX-F01", "TX-F02"]) as case:
        await case.send(transaction("busy-frame", 64))
        tx = transaction("one-byte-stalled-last", 1, port=4)
        flow = await case.send(tx, queued=True)
        require(flow["last_stalled_cycles"] > 0, "TX-F02", tx.transaction_id, "app",
                "last_stalled_cycles", ">0", flow["last_stalled_cycles"])
        await case.finish()


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f02_valid_gap_before_last(dut):
    async with TxFeatureCase(dut, "test_tx_f02_valid_gap_before_last", ["TX-F01", "TX-F02"]) as case:
        for length in (2, 16, 516):
            tx = transaction(f"gap-before-last-{length}", length)
            flow = await case.send(tx, gap_cycles=2)
            require(flow["valid_gap_cycles"] >= 2*(length-1), "TX-F02", tx.transaction_id,
                    "app", "valid_gap_cycles", f">={2*(length-1)}", flow["valid_gap_cycles"])
            await case.drain()
            await case.quiet()
        await case.finish()


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f02_back_to_back_messages(dut):
    async with TxFeatureCase(dut, "test_tx_f02_back_to_back_messages", ["TX-F01", "TX-F02"]) as case:
        # No caller-inserted delay. AppSource retains its documented cleanup
        # idle cycles; the next message is presented while TX is busy.
        for index, length in enumerate((1, 2, 16, 64)):
            await case.send(transaction(f"queued-{index}", length, src_udp=index,
                                        dst_udp=65535-index), queued=index > 0)
        await case.finish()
