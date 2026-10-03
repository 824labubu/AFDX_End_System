"""Unified DUT: real TX composition and explicitly unimplemented RX boundary."""

import zlib

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge
from cocotbext.eth import GmiiFrame

from afdx.tb import AfdxTB, END_SYSTEM_TX, END_SYSTEM_RX, END_SYSTEM_GMII
from afdx.transactions import AppTransaction


def make_tb(dut):
    dut.app_rx_ready.value = 0
    return AfdxTB(dut, app_names=END_SYSTEM_TX, gmii_names=END_SYSTEM_GMII,
                  rx_names=END_SYSTEM_RX)


@cocotb.test(timeout_time=300, timeout_unit="us")
async def application_tx_to_ab_gmii(dut):
    tb = make_tb(dut)
    await tb.start()
    # TB_ONLY_DEFAULT: ports/payloads are integration vectors, not app requests.
    cases = ((1, 1), (3, 17), (4, 64), (5, 1471), (3, 16))
    sequence = {}
    for index, (port, length) in enumerate(cases):
        transaction = AppTransaction(bytes((i * 17 + index) % 256 for i in range(length)),
                                     40000 + index, 16000 + index, port)
        await tb.send_app(transaction, gap_cycles=int(index == 1))
        accepted = await tb.recv_app()
        assert (accepted.payload, accepted.src_udp, accepted.dst_udp,
                accepted.application_port) == (
                    transaction.payload, transaction.src_udp, transaction.dst_udp, port)
        sequence[port] = sequence.get(port, 0) + 1
        copies = []
        for network, suffix in (("a", 0x20), ("b", 0x40)):
            captured = await tb.recv_gmii(network)
            frame = bytes(captured.get_payload(strip_fcs=False))
            assert len(frame) == max(60, 43 + length) + 4
            assert frame[:6] == bytes.fromhex("0300000000") + bytes([port])
            assert frame[6:12] == bytes.fromhex("0200000101") + bytes([suffix])
            assert frame[34:36] == transaction.src_udp.to_bytes(2, "big")
            assert frame[36:38] == transaction.dst_udp.to_bytes(2, "big")
            assert frame[38:40] == (8 + length).to_bytes(2, "big")
            assert frame[42:42 + length] == transaction.payload
            assert frame[-5] == sequence[port]
            assert frame[-4:] == zlib.crc32(frame[:-4]).to_bytes(4, "little")
            assert not captured.error
            copies.append(frame)
        assert copies[0][12:-4] == copies[1][12:-4]
        assert int(dut.app_rx_valid.value) == 0
    # A pending next frame exercises backpressure during the previous IFG.
    assert tb.app_monitor.stalled_cycles > 0
    assert int(dut.phy_reset_n_a.value) == int(dut.phy_reset_n_b.value) == 1
    tb.close()


@cocotb.test(timeout_time=100, timeout_unit="us")
async def rx_reserved_idle_and_reset(dut):
    tb = make_tb(dut)
    await tb.start()
    # GMII injection is supported by the boundary, but RX is not a decoder yet.
    frame = GmiiFrame.from_payload(bytes.fromhex("0200000000100200000000200800")
                                   + bytes(range(46)))
    await tb.inject_gmii("a", frame)
    await tb.inject_gmii("b", frame)
    for ready in (1, 0, 1):
        await FallingEdge(dut.clk)
        dut.app_rx_ready.value = ready
        await ClockCycles(dut.clk, 4)
        for name in END_SYSTEM_RX.values():
            if name != "app_rx_ready":
                assert int(getattr(dut, name).value) == 0, name
    assert tb.rx_monitor.beats_seen == 0
    assert tb.gmii_tx["a"].empty() and tb.gmii_tx["b"].empty()
    await tb.reset_dut()
    await FallingEdge(dut.clk)
    dut.reset_n.value = 0
    await ClockCycles(dut.clk, 2)
    assert int(dut.app_tx_ready.value) == 0
    assert int(dut.app_rx_valid.value) == 0
    assert int(dut.gmii_tx_en_a.value) == int(dut.gmii_tx_en_b.value) == 0
    assert int(dut.phy_reset_n_a.value) == int(dut.phy_reset_n_b.value) == 0
    tb.close()
