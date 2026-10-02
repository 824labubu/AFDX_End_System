"""公共时钟、复位和有界等待。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, SimTimeoutError, with_timeout


def start_clock(signal, period_ns):
    # 时钟句柄只由一处驱动。
    return cocotb.start_soon(Clock(signal, period_ns, unit="ns").start())


async def pulse_reset(clock, reset, cycles=5, active_level=0):
    # 在下降沿切换复位，避免与 DUT 上升沿采样竞争。
    await FallingEdge(clock)
    reset.value = active_level
    await ClockCycles(clock, cycles)
    await FallingEdge(clock)
    reset.value = 1 - active_level
    await ClockCycles(clock, 2)


async def bounded(awaitable, timeout_us, label):
    # 超时统一转成含操作名称的测试失败。
    try:
        return await with_timeout(awaitable, timeout_us, "us")
    except SimTimeoutError as exc:
        raise AssertionError(f"TIMEOUT: {label} after {timeout_us} us") from exc
