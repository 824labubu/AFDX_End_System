"""TX-F08 boundary follows Ethernet+IPv4+UDP+SN frame sizes."""

import cocotb

from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG as CONFIG
from .common import TxFeatureCase, transaction


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f08_padding_boundary(dut):
    async with TxFeatureCase(dut, "test_tx_f08_padding_boundary", ["TX-F08"]) as case:
        boundary = CONFIG.min_frame_bytes - (14+20+8+1)
        for index, length in enumerate((1, 2, 16, boundary-1, boundary, boundary+1, 64)):
            await case.send(transaction(f"padding-{index}-{length}", length, port=index % 5+1), queued=index > 0)
        await case.finish()
