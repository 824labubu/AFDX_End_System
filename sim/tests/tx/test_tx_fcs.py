"""TX-F09 FCS equality + actual independent CRC verification."""

import cocotb

from .common import TxFeatureCase, transaction


@cocotb.test(timeout_time=500, timeout_unit="us")
async def test_tx_f09_independent_fcs_each_network(dut):
    async with TxFeatureCase(dut, "test_tx_f09_independent_fcs_each_network", ["TX-F09"]) as case:
        for index, length in enumerate((1, 16, 17, 18, 64, 484, 516, 1471)):
            await case.send(transaction(f"fcs-{length}", length, port=index % 5+1, seed=0x55),
                            queued=index > 0)
        await case.finish()
