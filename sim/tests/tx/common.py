"""TX feature orchestration and diagnostics; no protocol model is implemented here."""

from pathlib import Path
import json

from cocotb.triggers import ClockCycles
from cocotb.utils import get_sim_time

from afdx.observers import ApplicationFlowObserver, GmiiWireObserver
from checkers.tx_wire import check_preamble, check_ifg
from afdx.tb import AfdxTB, END_SYSTEM_TX, END_SYSTEM_GMII
from afdx.transactions import AppTransaction
from decoder.tx_frame_decoder import decode_tx_frame
from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG
from model.tx_reference import AfdxTxReferenceModel
from scoreboard.tx_scoreboard import TxScoreboard


def transaction(name, length, port=3, src_udp=40003, dst_udp=16003, seed=0):
    return AppTransaction(bytes((17*i + length + seed) % 256 for i in range(length)),
                          src_udp, dst_udp, port, name)


def require(condition, feature, transaction_id, network, field, expected, actual, **context):
    if not condition:
        details = " ".join(f"{key}={value}" for key, value in context.items())
        raise AssertionError(f"[{feature}][id={transaction_id}][{network.upper()}] "
                             f"field={field} expected={expected!r} actual={actual!r} {details}")


class TxFeatureCase:
    """One independent reference state + per-network FIFO scoreboard per case."""

    def __init__(self, dut, name, features, *, wire=False):
        self.dut, self.name, self.features = dut, name, tuple(features)
        dut.app_rx_ready.value = 0  # RX is stub and intentionally not exercised.
        self.tb = AfdxTB(dut, app_names=END_SYSTEM_TX, gmii_names=END_SYSTEM_GMII)
        self.flow = ApplicationFlowObserver(self.tb.stream, dut.clk, dut.reset_n)
        self.wire = {network: GmiiWireObserver(dut, names, network)
                     for network, names in END_SYSTEM_GMII.items()} if wire else {}
        self.model = AfdxTxReferenceModel(TB_ONLY_DEFAULT_MODEL_CONFIG)
        self.scoreboard = TxScoreboard(f"{'/'.join(self.features)}::{name}")
        self.inputs, self.outputs, self.rejections = [], [], []
        self.expected = {}
        self.epoch = 0
        self.status, self.failure = "RUNNING", None

    async def __aenter__(self):
        await self.tb.start()
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        self.status = "PASS" if exc is None else "FAIL"
        self.failure = None if exc is None else f"{type(exc).__name__}: {exc}"
        self.scoreboard.write_artifact(Path(f"{self.name}.scoreboard.json"))
        Path(f"{self.name}.case.json").write_text(json.dumps({
            "test_name": self.name, "features": self.features, "status": self.status,
            "failure": self.failure, "inputs": self.inputs, "outputs": self.outputs,
            "rejections": self.rejections,
            "wire": {network: observer.frames for network, observer in self.wire.items()},
        }, indent=2) + "\n", encoding="utf-8")
        self.flow.close()
        for observer in self.wire.values():
            observer.close()
        self.tb.close()
        return False

    async def send(self, tx, gap_cycles=0, *, expected=True, queued=False):
        if any(record["transaction_id"] == tx.transaction_id for record in self.inputs):
            raise ValueError(f"duplicate transaction ID in {self.name}: {tx.transaction_id}")
        if expected:
            copies = self.model.build(tx)
            self.scoreboard.expect(copies)
            for copy in copies:
                self.expected[(copy.network, copy.transaction_id)] = copy
        await self.tb.send_app(tx, gap_cycles=gap_cycles)
        accepted = await self.tb.recv_app()
        require((accepted.payload, accepted.src_udp, accepted.dst_udp, accepted.application_port)
                == (tx.payload, tx.src_udp, tx.dst_udp, tx.application_port),
                self.features[0], tx.transaction_id, "app", "accepted_transaction",
                repr(tx), repr(accepted))
        flow = self.flow.completed.pop(0)
        require(flow.accepted_bytes == len(tx), self.features[0], tx.transaction_id,
                "app", "accepted_bytes", len(tx), flow.accepted_bytes)
        record = {"transaction_id": tx.transaction_id, "length": len(tx),
                  "port": tx.application_port, "epoch": self.epoch, "expected": expected,
                  "queued_without_user_delay": queued, **flow.to_dict()}
        self.inputs.append(record)
        return record

    async def drain(self):
        for network in ("a", "b"):
            while self.scoreboard.pending[network]:
                try:
                    frame = await self.tb.recv_gmii(network)
                except AssertionError:
                    self.scoreboard.finish(timestamp_ns=float(get_sim_time(unit="ns")))
                    raise
                raw = bytes(frame.get_payload(strip_fcs=False))
                report = self.scoreboard.observe(
                    network, raw, timestamp_ns=float(get_sim_time(unit="ns")),
                    gmii_error=bool(frame.error and any(frame.error)))
                expected = self.expected[(network, report.transaction_id)]
                decoded = decode_tx_frame(raw)
                self.outputs.append({"transaction_id": report.transaction_id, "network": network,
                                     "length": decoded.payload_length, "vl": expected.vl_id,
                                     "sn": decoded.sequence_number, "pad_length": len(decoded.padding),
                                     "epoch": self.epoch, "fcs_valid": True})

    async def quiet(self, cycles=32):
        await ClockCycles(self.dut.clk, cycles)
        for network in ("a", "b"):
            while not self.tb.gmii_tx[network].empty():
                frame = await self.tb.recv_gmii(network)
                self.scoreboard.observe(network, bytes(frame.get_payload(strip_fcs=False)),
                                        timestamp_ns=float(get_sim_time(unit="ns")),
                                        gmii_error=bool(frame.error and any(frame.error)))

    async def finish(self):
        await self.drain()
        await self.quiet()
        self.scoreboard.finish(timestamp_ns=float(get_sim_time(unit="ns")))

    async def reset(self):
        await self.drain()
        await self.quiet()
        await self.tb.reset_dut()
        self.model.reset()
        self.epoch += 1

    def actual(self, transaction_id, network):
        report = next(r for r in self.scoreboard.reports
                      if r.transaction_id == transaction_id and r.network == network)
        return decode_tx_frame(report.actual_bytes)

    def check_wire(self, *, preamble=False, ifg=False):
        for network, observer in self.wire.items():
            reports = [r for r in self.scoreboard.reports if r.network == network]
            require(len(observer.frames) == len(reports), "TX-F10/TX-F11", self.name, network,
                    "wire_frame_count", len(reports), len(observer.frames))
            for record, report in zip(observer.frames, reports):
                record["transaction_id"] = report.transaction_id
                require(record["wire_length"] == len(report.actual_bytes)+8,
                        "TX-F10", report.transaction_id, network, "wire_length",
                        len(report.actual_bytes)+8, record["wire_length"])
                require(record["tx_error_cycles"] == 0, "TX-F10", report.transaction_id,
                        network, "gmii_tx_error", 0, record["tx_error_cycles"])
                if preamble:
                    check_preamble(record, report.transaction_id)
                    record["preamble_valid"] = True
                if ifg:
                    check_ifg(record, report.transaction_id, self.tb.config.gmii_ifg_cycles)
                    record["ifg_valid"] = record["idle_cycles"] is not None
