"""公共 TB wrapper；通过显式映射适配不同 DUT。"""

from dataclasses import dataclass

from cocotbext.eth import GmiiSink, GmiiSource
from cocotb.triggers import FallingEdge

from .bfm import AppMonitor, AppSource, StreamSignals
from .config import TB_ONLY_DEFAULT
from .helpers import bounded, pulse_reset, start_clock


@dataclass(frozen=True)
class GmiiSignals:
    rx_clock: str
    rx_data: str
    rx_valid: str
    rx_error: str
    tx_clock: str
    tx_data: str
    tx_valid: str
    tx_error: str


APP_NAMES = {
    "data": "app_data",
    "valid": "app_valid",
    "ready": "app_ready",
    "last": "app_last",
    "src_udp": "app_src_udp",
    "dst_udp": "app_dst_udp",
    "application_port": "app_port",
}

HARNESS_GMII = {
    network: GmiiSignals(
        f"gmii_rx_clk_{network}", f"gmii_rxd_{network}",
        f"gmii_rx_dv_{network}", f"gmii_rx_er_{network}",
        f"gmii_tx_clk_{network}", f"gmii_txd_{network}",
        f"gmii_tx_en_{network}", f"gmii_tx_er_{network}",
    ) for network in ("a", "b")
}

TX_MAC_APP = dict(APP_NAMES, data="ff_tx_data", valid="tx_valid", ready="tx_ready",
                  last="ff_tx_tlast", src_udp="app_upd_src_port",
                  dst_udp="app_upd_dst_port", application_port="tx_port")

TX_MAC_GMII = {
    network: GmiiSignals(
        f"p0_rxc_{network}", f"p0_rxd_{network}",
        f"p0_rxdv_{network}", f"p0_rxer_{network}",
        f"p0_gtxc_{network}", f"p0_txd_{network}",
        f"p0_txen_{network}", f"p0_txer_{network}",
    ) for network in ("a", "b")
}


class AfdxTB:
    def __init__(self, dut, app_names=None, gmii_names=None, reset_name="reset_n",
                 clock_name="clk", config=TB_ONLY_DEFAULT, reset_active_level=0):
        self.dut = dut
        self.config = config
        self.clock = getattr(dut, clock_name)
        self.reset = getattr(dut, reset_name)
        self.reset_active_level = reset_active_level
        self.reset.value = reset_active_level
        self.clocks = []
        self.stream = StreamSignals.bind(dut, app_names or APP_NAMES)
        self.app = AppSource(self.stream, self.clock, self.reset, reset_active_level,
                             config.max_stall_cycles)
        self.app_monitor = AppMonitor(self.stream, self.clock, self.reset,
                                      reset_active_level=reset_active_level)
        self.gmii_rx = {}
        self.gmii_tx = {}
        self.gmii_names = HARNESS_GMII if gmii_names is None else gmii_names
        for network, names in self.gmii_names.items():
            # 直接例化第三方 GMII BFM，不实现字节级 GMII driver。
            self.gmii_rx[network] = GmiiSource(
                getattr(dut, names.rx_data), getattr(dut, names.rx_error),
                getattr(dut, names.rx_valid), getattr(dut, names.rx_clock),
                self.reset, reset_active_level=reset_active_level,
            )
            self.gmii_tx[network] = GmiiSink(
                getattr(dut, names.tx_data), getattr(dut, names.tx_error),
                getattr(dut, names.tx_valid), getattr(dut, names.tx_clock),
                self.reset, reset_active_level=reset_active_level,
            )

    async def start(self):
        self.clocks.append(start_clock(self.clock, self.config.system_clock_ns))
        started = set()
        for names in self.gmii_names.values():
            if names.rx_clock not in started:
                self.clocks.append(start_clock(getattr(self.dut, names.rx_clock),
                                               self.config.gmii_clock_ns))
                started.add(names.rx_clock)
        await self.reset_dut()

    async def reset_dut(self):
        await FallingEdge(self.clock)
        self.reset.value = self.reset_active_level
        self.app.idle()
        await pulse_reset(self.clock, self.reset, self.config.reset_cycles,
                          self.reset_active_level)

    async def send_app(self, transaction, gap_cycles=0):
        return await bounded(self.app.send(transaction, gap_cycles),
                             self.config.operation_timeout_us, "application send")

    async def recv_app(self):
        return await bounded(self.app_monitor.recv(), self.config.operation_timeout_us,
                             "application accepted transaction")

    async def inject_gmii(self, network, frame):
        await bounded(self.gmii_rx[network].send(frame), self.config.operation_timeout_us,
                      f"GMII {network.upper()} enqueue")
        await bounded(self.gmii_rx[network].wait(), self.config.operation_timeout_us,
                      f"GMII {network.upper()} RX injection")

    async def recv_gmii(self, network):
        return await bounded(self.gmii_tx[network].recv(), self.config.operation_timeout_us,
                             f"GMII {network.upper()} TX capture")

    def close(self):
        self.app_monitor.close()
        # 本地复位停止第三方 BFM，后续外部复位不会重启已关闭的实例。
        for bfm in (*self.gmii_rx.values(), *self.gmii_tx.values()):
            bfm.assert_reset(True)
            bfm.clear()
        for task in self.clocks:
            task.cancel()
