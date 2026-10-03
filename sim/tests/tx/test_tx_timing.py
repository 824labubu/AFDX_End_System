"""TX-F10/F11 on each actual GMII TX clock; no start-to-start rule."""

import cocotb

from .common import TxFeatureCase, transaction, require


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f10_preamble_sfd_on_wire(dut):
    async with TxFeatureCase(dut, "test_tx_f10_preamble_sfd_on_wire", ["TX-F10"], wire=True) as case:
        for index, length in enumerate((1, 16, 64, 1471)):
            await case.send(transaction(f"preamble-{length}", length), queued=index > 0)
        await case.finish()
        case.check_wire(preamble=True)


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f11_ifg_idle_gmii_cycles(dut):
    async with TxFeatureCase(dut, "test_tx_f11_ifg_idle_gmii_cycles", ["TX-F11"], wire=True) as case:
        for index, length in enumerate((1, 1, 2, 16, 64, 1, 16, 1)):
            await case.send(transaction(f"ifg-{index}", length), queued=index > 0)
        await case.finish()
        case.check_wire(ifg=True)
        for network, observer in case.wire.items():
            require(sum(r["idle_cycles"] is not None for r in observer.frames) == 7,
                    "TX-F11", case.name, network, "checked_gaps", 7,
                    sum(r["idle_cycles"] is not None for r in observer.frames))
