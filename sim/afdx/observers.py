"""Passive public-interface observers supplement the application/GMII BFMs."""

from dataclasses import asdict, dataclass

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly
from cocotb.utils import get_sim_time


@dataclass
class ApplicationFlow:
    accepted_bytes: int = 0
    stalled_cycles: int = 0
    last_stalled_cycles: int = 0
    valid_gap_cycles: int = 0

    def to_dict(self):
        return asdict(self)


class ApplicationFlowObserver:
    """Counts observed flow events; never drives ready or infers DUT state."""

    def __init__(self, stream, clock, reset):
        self.stream, self.clock, self.reset = stream, clock, reset
        self.completed = []
        self.task = cocotb.start_soon(self._run())

    async def _run(self):
        current = None
        while True:
            await RisingEdge(self.clock)
            if not int(self.reset.value):
                current = None
                self.completed.clear()
                continue
            sample = self.stream.sample()
            if sample.valid and current is None:
                current = ApplicationFlow()
            if current is None:
                continue
            if not sample.valid:
                current.valid_gap_cycles += 1
            elif not sample.ready:
                current.stalled_cycles += 1
                current.last_stalled_cycles += int(bool(sample.last))
            else:
                current.accepted_bytes += 1
                if sample.last:
                    self.completed.append(current)
                    current = None

    def close(self):
        self.task.cancel()


class GmiiWireObserver:
    """Sample public GMII after output settling. Only record prefix and timing.

    The existing GmiiSink still captures/decodes complete Ethernet frames.
    end_cycle is the last cycle with TX_EN=1; gap counts intervening TX_EN=0
    samples, so idle_cycles = next_start - previous_end - 1. No BAG state.
    """

    def __init__(self, dut, names, network):
        self.clock = getattr(dut, names.tx_clock)
        self.data = getattr(dut, names.tx_data)
        self.enable = getattr(dut, names.tx_valid)
        self.error = getattr(dut, names.tx_error)
        self.reset = dut.reset_n
        self.network = network
        self.frames = []
        self.task = cocotb.start_soon(self._run())

    async def _run(self):
        cycle, current, previous = 0, None, None
        while True:
            await RisingEdge(self.clock)
            await ReadOnly()
            cycle += 1
            if not int(self.reset.value):
                current, previous = None, None
                continue
            now = float(get_sim_time(unit="ns"))
            if int(self.enable.value):
                if current is None:
                    current = {"network": self.network, "start_cycle": cycle, "start_ns": now,
                               "previous_end_cycle": previous[0] if previous else None,
                               "previous_end_ns": previous[1] if previous else None,
                               "idle_cycles": cycle-previous[0]-1 if previous else None,
                               "prefix": [], "wire_length": 0, "tx_error_cycles": 0}
                if current["wire_length"] < 8:
                    current["prefix"].append(int(self.data.value))
                current["wire_length"] += 1
                current["tx_error_cycles"] += int(self.error.value)
                current["end_cycle"], current["end_ns"] = cycle, now
            elif current is not None:
                self.frames.append(current)
                previous = (current["end_cycle"], current["end_ns"])
                current = None

    def close(self):
        self.task.cancel()
