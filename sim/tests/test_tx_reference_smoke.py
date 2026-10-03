"""V2 Phase G: public application inputs versus independently modeled A/B TX."""

from pathlib import Path

import cocotb
from cocotb.triggers import ClockCycles
from cocotb.utils import get_sim_time

from afdx.tb import AfdxTB, END_SYSTEM_TX, END_SYSTEM_RX, END_SYSTEM_GMII
from afdx.transactions import AppTransaction
from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG
from model.tx_reference import AfdxTxReferenceModel
from scoreboard.tx_scoreboard import TxScoreboard


async def run_reference_case(dut, name, transactions):
    # The model only sees the intended transaction and explicit test config.
    # Monitor inputs confirm handshake delivery; captured outputs never feed
    # back into expected headers, sequence state, address tables or checksums.
    dut.app_rx_ready.value = 1
    tb = AfdxTB(dut, app_names=END_SYSTEM_TX, gmii_names=END_SYSTEM_GMII,
                rx_names=END_SYSTEM_RX)
    model = AfdxTxReferenceModel(TB_ONLY_DEFAULT_MODEL_CONFIG)
    scoreboard = TxScoreboard(name)
    artifact = Path(f"{name}.scoreboard.json")
    try:
        await tb.start()
        for transaction in transactions:
            scoreboard.expect(model.build(transaction))
            await tb.send_app(transaction)
            accepted = await tb.recv_app()
            assert (accepted.payload, accepted.src_udp, accepted.dst_udp,
                    accepted.application_port) == (
                        transaction.payload, transaction.src_udp, transaction.dst_udp,
                        transaction.application_port), "application handshake transaction changed"
        for _ in transactions:
            for network in ("a", "b"):
                try:
                    captured = await tb.recv_gmii(network)
                except AssertionError:
                    # Turn a missing capture into a transaction/field diagnostic
                    # when possible; the original timeout remains a failure.
                    scoreboard.finish(timestamp_ns=float(get_sim_time(unit="ns")))
                    raise
                scoreboard.observe(network, bytes(captured.get_payload(strip_fcs=False)),
                                   timestamp_ns=float(get_sim_time(unit="ns")),
                                   gmii_error=bool(captured.error and any(captured.error)))
        # Finite observation window for extra output, NOT a BAG/IFG checker.
        await ClockCycles(dut.clk, 32)
        for network in ("a", "b"):
            while not tb.gmii_tx[network].empty():
                captured = await tb.recv_gmii(network)
                scoreboard.observe(network, bytes(captured.get_payload(strip_fcs=False)),
                                   timestamp_ns=float(get_sim_time(unit="ns")))
        scoreboard.finish(timestamp_ns=float(get_sim_time(unit="ns")))
        assert tb.rx_monitor.beats_seen == 0, "RX must remain stub in V2"
        dut._log.info("V2 REFERENCE PASS: %s matched=%s", name, scoreboard.matched_count)
    except Exception as exc:
        scoreboard.write_artifact(artifact)
        dut._log.error("V2 failed: %s; diagnostics=%s", exc, artifact.resolve())
        raise
    finally:
        scoreboard.write_artifact(artifact)
        tb.close()


def transaction(name, port, length):
    # TB_ONLY_DEFAULT test payload and UDP ports, not an application peer model.
    return AppTransaction(bytes((17 * i + length) % 256 for i in range(length)),
                          40000 + port, 16000 + port, port, name)


@cocotb.test(timeout_time=200, timeout_unit="us")
async def tx_reference_normal_payload(dut):
    await run_reference_case(dut, "tx_reference_normal_payload",
                             [transaction("normal-16", 3, 16)])


@cocotb.test(timeout_time=200, timeout_unit="us")
async def tx_reference_one_byte(dut):
    await run_reference_case(dut, "tx_reference_one_byte", [transaction("minimum-1", 4, 1)])


@cocotb.test(timeout_time=200, timeout_unit="us")
async def tx_reference_maximum_payload(dut):
    await run_reference_case(dut, "tx_reference_maximum_payload", [transaction("maximum-1471", 5, 1471)])


@cocotb.test(timeout_time=200, timeout_unit="us")
async def tx_reference_two_consecutive_frames(dut):
    await run_reference_case(dut, "tx_reference_two_consecutive_frames",
                             [transaction("consecutive-0", 3, 16),
                              transaction("consecutive-1", 3, 16)])
