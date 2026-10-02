"""8 位应用流 Driver 和被动事务 Monitor。"""

from dataclasses import dataclass

import cocotb
from cocotb.queue import Queue
from cocotb.triggers import FallingEdge, Lock, RisingEdge

from ..assertions import StreamAssertions, StreamSample
from ..transactions import AppTransaction


@dataclass(frozen=True)
class StreamSignals:
    data: object
    valid: object
    ready: object
    last: object
    src_udp: object
    dst_udp: object
    application_port: object

    @classmethod
    def bind(cls, dut, names):
        # 缺少接口时立即报错，避免静默跳过接入。
        signals = {field: getattr(dut, name) for field, name in names.items()}
        result = cls(**signals)
        for field, width in (("data", 8), ("valid", 1), ("ready", 1), ("last", 1),
                             ("src_udp", 16), ("dst_udp", 16), ("application_port", 8)):
            if len(getattr(result, field)) != width:
                raise ValueError(f"{field}: expected {width}-bit signal")
        return result

    def sample(self):
        # valid 为零时载荷不参与检查，允许 DUT 的空闲数据为 X。
        valid = int(self.valid.value)
        controls = {"valid", "ready", "last"}
        return StreamSample(**{
            field: int(getattr(self, field).value) if valid or field in controls else 0
            for field in self.__dataclass_fields__
        })


class AppSource:
    def __init__(self, signals, clock, reset, reset_active_level=0, max_stall_cycles=2048):
        self.signals = signals
        self.clock = clock
        self.reset = reset
        self.reset_active_level = reset_active_level
        self.max_stall_cycles = max_stall_cycles
        self.lock = Lock()
        self.transactions_sent = 0
        self.beats_sent = 0
        self.idle()

    def idle(self):
        self.signals.valid.value = 0
        self.signals.last.value = 0
        self.signals.data.value = 0
        self.signals.src_udp.value = 0
        self.signals.dst_udp.value = 0
        self.signals.application_port.value = 0

    async def send(self, transaction, gap_cycles=0):
        if not isinstance(transaction, AppTransaction):
            raise TypeError("send expects AppTransaction")
        if not isinstance(gap_cycles, int) or gap_cycles < 0:
            raise ValueError("gap_cycles must be a nonnegative integer")
        # 串行化并发调用，避免两个事务同时驱动接口。
        async with self.lock:
            completed = False
            try:
                await FallingEdge(self.clock)
                if int(self.reset.value) == self.reset_active_level:
                    raise RuntimeError("AppSource: cannot send while reset is active")
                self.signals.src_udp.value = transaction.src_udp
                self.signals.dst_udp.value = transaction.dst_udp
                self.signals.application_port.value = transaction.application_port
                for index, byte in enumerate(transaction.payload):
                    self.signals.data.value = byte
                    self.signals.last.value = int(index == len(transaction) - 1)
                    self.signals.valid.value = 1
                    stalled = 0
                    while True:
                        # 上升沿读取握手值，不等待 DUT 的时序更新覆盖 ready。
                        await RisingEdge(self.clock)
                        if int(self.reset.value) == self.reset_active_level:
                            raise RuntimeError("AppSource: transaction aborted by reset")
                        if int(self.signals.ready.value):
                            self.beats_sent += 1
                            break
                        stalled += 1
                        if stalled >= self.max_stall_cycles:
                            raise AssertionError(
                                f"TIMEOUT: AppSource id={transaction.transaction_id} "
                                f"byte={index} stalled {stalled} cycles"
                            )
                    await FallingEdge(self.clock)
                    if int(self.reset.value) == self.reset_active_level:
                        raise RuntimeError("AppSource: transaction aborted by reset")
                    if gap_cycles and index != len(transaction) - 1:
                        self.signals.valid.value = 0
                        self.signals.last.value = 0
                        for _ in range(gap_cycles):
                            await FallingEdge(self.clock)
                            if int(self.reset.value) == self.reset_active_level:
                                raise RuntimeError("AppSource: transaction aborted by reset")
                self.transactions_sent += 1
                completed = True
                self.idle()
            finally:
                # 超时保留未握手字节，只有完成或复位才允许撤销 valid。
                await FallingEdge(self.clock)
                if completed or int(self.reset.value) == self.reset_active_level:
                    self.idle()


class AppMonitor:
    def __init__(self, signals, clock, reset, name="application", reset_active_level=0):
        self.signals = signals
        self.clock = clock
        self.reset = reset
        self.reset_active_level = reset_active_level
        self.assertions = StreamAssertions(name)
        self.queue = Queue()
        self.beats_seen = 0
        self.stalled_cycles = 0
        self.task = cocotb.start_soon(self._run())

    async def _run(self):
        payload = bytearray()
        while True:
            await RisingEdge(self.clock)
            if int(self.reset.value) == self.reset_active_level:
                payload.clear()
                self.assertions.clear()
                continue
            sample = self.signals.sample()
            self.assertions.check(sample)
            if sample.valid and not sample.ready:
                self.stalled_cycles += 1
            # 仅接受 fire 字节，并在 last 握手时发布完整事务。
            if sample.valid and sample.ready:
                self.beats_seen += 1
                payload.append(sample.data)
                if sample.last:
                    self.queue.put_nowait(AppTransaction(
                        bytes(payload), sample.src_udp, sample.dst_udp,
                        sample.application_port,
                    ))
                    payload.clear()

    async def recv(self):
        return await self.queue.get()

    def close(self):
        self.task.cancel()
