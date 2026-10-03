"""TX-F06 exercises real public transactions, including all 256 SNs."""

import cocotb

from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG as CONFIG
from .common import TxFeatureCase, transaction


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f06_interleaved_per_vl_independence(dut):
    async with TxFeatureCase(dut, "test_tx_f06_interleaved_per_vl_independence", ["TX-F06"]) as case:
        for index, port in enumerate((1, 1, 2, 1, 2, 3, 4, 5, 3, 4, 5)):
            await case.send(transaction(f"interleave-{index}-vl-{port}", 16, port=port), queued=index > 0)
        await case.finish()


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_tx_f06_sequence_wrap_255_to_1(dut):
    async with TxFeatureCase(dut, "test_tx_f06_sequence_wrap_255_to_1", ["TX-F06"]) as case:
        # Drive every message through the public application interface. No force,
        # deposit, hierarchy access, or reference-only accelerated wrap setup.
        for index in range(CONFIG.sequence_last - CONFIG.sequence_first + 2):
            await case.send(transaction(f"wrap-{index}", 1, port=3, seed=index), queued=index > 0)
        await case.finish()


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f06_reset_restarts_all_vls(dut):
    async with TxFeatureCase(dut, "test_tx_f06_reset_restarts_all_vls", ["TX-F06"]) as case:
        for repeat in range(2):
            for port in CONFIG.ports:
                await case.send(transaction(f"pre-reset-{repeat}-{port}", 16, port=port), queued=True)
        await case.reset()
        for port in CONFIG.ports:
            await case.send(transaction(f"post-reset-{port}", 1, port=port), queued=port > 1)
        await case.finish()
