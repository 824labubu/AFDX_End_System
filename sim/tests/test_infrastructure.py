"""V1 夹具 smoke：接口基础设施验证，不表示协议验证通过。"""

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, Timer
from cocotbext.eth import GmiiFrame

from afdx.assertions import StreamAssertions, StreamSample
from afdx.bfm import AppMonitor, StreamSignals
from afdx.config import TestConfig
from afdx.helpers import bounded
from afdx.tb import AfdxTB
from afdx.transactions import AppTransaction


def observed_stream(dut):
    return StreamSignals.bind(dut, {
        "data": "observed_data", "valid": "observed_valid", "ready": "observed_ready",
        "last": "observed_last", "src_udp": "observed_src_udp",
        "dst_udp": "observed_dst_udp", "application_port": "observed_port",
    })


@cocotb.test(timeout_time=200, timeout_unit="us")
async def app_stream_smoke(dut):
    dut.observed_ready.value = 0
    tb = AfdxTB(dut)
    output = AppMonitor(observed_stream(dut), dut.clk, dut.reset_n, "arbiter output")
    await tb.start()

    async def backpressure():
        # 固定模式覆盖首字节、中间字节和末字节等待。
        for cycle in range(1000):
            await FallingEdge(dut.clk)
            dut.observed_ready.value = int(cycle % 5 in (3, 4))

    ready_task = cocotb.start_soon(backpressure())
    for index, length in enumerate((1, 4, 16, 64, 484, 516, 1471)):
        # TB_ONLY_DEFAULT: 元信息和载荷仅是接口测试值。
        transaction = AppTransaction(bytes((i + index) % 256 for i in range(length)),
                                     40000 + index, 16000 + index, 3 + index % 3,
                                     f"stream-{index}")
        await tb.send_app(transaction, gap_cycles=int(index == 2))
        accepted = await tb.recv_app()
        forwarded = await bounded(output.recv(), 50, "arbiter output transaction")
        for actual in (accepted, forwarded):
            assert actual.payload == transaction.payload
            assert actual.src_udp == transaction.src_udp
            assert actual.dst_udp == transaction.dst_udp
            assert actual.application_port == transaction.application_port
    assert tb.app.transactions_sent == 7
    assert output.beats_seen == sum((1, 4, 16, 64, 484, 516, 1471))
    assert tb.app_monitor.stalled_cycles > 0
    ready_task.cancel()
    output.close()
    tb.close()


@cocotb.test(timeout_time=200, timeout_unit="us")
async def gmii_ab_loopback_smoke(dut):
    dut.observed_ready.value = 1
    tb = AfdxTB(dut)
    await tb.start()
    # TB_ONLY_DEFAULT: 原始 Ethernet 字节仅验证 BFM 连通性。
    header = bytes.fromhex("02000000001002000000002088b5")
    expected = {network: GmiiFrame.from_payload(header + bytes([0xA0 + index]) * 46)
                for index, network in enumerate(("a", "b"))}
    jobs = [cocotb.start_soon(tb.inject_gmii(network, frame))
            for network, frame in expected.items()]
    for network, frame in expected.items():
        actual = await tb.recv_gmii(network)
        assert actual.get_payload(strip_fcs=False) == frame.get_payload(strip_fcs=False), (
            f"GMII {network}: loopback bytes after SFD changed"
        )
        assert not actual.error
    for job in jobs:
        await job
    # 接收下一帧，确认 BFM 可复用且 A/B 没有串网。
    second = GmiiFrame.from_payload(header + bytes(range(64)))
    await tb.inject_gmii("a", second)
    actual = await tb.recv_gmii("a")
    assert actual.get_payload(strip_fcs=False) == second.get_payload(strip_fcs=False)
    assert tb.gmii_tx["b"].empty()
    tb.close()


@cocotb.test(timeout_time=200, timeout_unit="us")
async def reset_and_timeout_smoke(dut):
    dut.observed_ready.value = 0
    tb = AfdxTB(dut, config=TestConfig(max_stall_cycles=8))
    await tb.start()
    transaction = AppTransaction(b"\x10\x20", 1, 2, 3, "blocked")
    try:
        await tb.send_app(transaction)
    except AssertionError as exc:
        assert "TIMEOUT" in str(exc)
    else:
        assert False, "permanent backpressure must time out"
    # 失败恢复前复位 DUT，清除被中断的消息锁定。
    await tb.reset_dut()
    job = cocotb.start_soon(tb.send_app(transaction))
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.reset_n.value = 0
    try:
        await job
    except RuntimeError as exc:
        assert "reset" in str(exc)
    else:
        assert False, "reset must abort an in-flight transaction"
    await tb.reset_dut()
    await FallingEdge(dut.clk)
    dut.observed_ready.value = 1
    await tb.send_app(transaction)
    assert (await tb.recv_app()).payload == transaction.payload
    assert tb.app_monitor.queue.empty()
    # valid 空拍期间的复位也必须中止旧事务。
    gap_job = cocotb.start_soon(tb.send_app(transaction, gap_cycles=20))
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)
    dut.reset_n.value = 0
    try:
        await gap_job
    except RuntimeError as exc:
        assert "reset" in str(exc)
    else:
        assert False, "reset during a valid gap must abort the transaction"
    await tb.reset_dut()
    await tb.send_app(transaction)
    assert (await tb.recv_app()).payload == transaction.payload
    assert tb.app_monitor.queue.empty()
    # 公共超时必须自动报告失败，而不是无限等待。
    try:
        await bounded(tb.gmii_tx["a"].recv(), 1, "deliberately absent frame")
    except AssertionError as exc:
        assert "TIMEOUT" in str(exc)
    else:
        assert False, "absent frame must time out"
    tb.close()


@cocotb.test(timeout_time=10, timeout_unit="us")
async def assertion_and_transaction_guards(dut):
    # 检查非法事务和接口 assertion 的失败路径。
    for args in ((b"", 1, 2, 3), (b"x", 65536, 2, 3), (b"x", 1, -1, 3),
                 (b"x", 1, 2, 256)):
        try:
            AppTransaction(*args)
        except ValueError:
            pass
        else:
            assert False, f"invalid transaction accepted: {args}"
    checker = StreamAssertions("negative self-test")
    checker.check(StreamSample(1, 0, 0x11, 0, 1, 2, 3))
    try:
        checker.check(StreamSample(1, 1, 0x22, 0, 1, 2, 3))
    except AssertionError:
        pass
    else:
        assert False, "stalled data mutation was not detected"
    checker.clear()
    try:
        checker.check(StreamSample(0, 1, 0, 1, 1, 2, 3))
    except AssertionError:
        pass
    else:
        assert False, "last without valid was not detected"
    await Timer(1, unit="ns")
