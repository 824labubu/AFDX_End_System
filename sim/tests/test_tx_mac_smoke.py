"""现有可选 AFDX_TX_MAC 的真实 GMII 连通 smoke，不检查协议封装。"""

import cocotb

from afdx.tb import AfdxTB, TX_MAC_APP, TX_MAC_GMII
from afdx.transactions import AppTransaction


@cocotb.test(timeout_time=200, timeout_unit="us")
async def tx_mac_app_to_ab_gmii(dut):
    # 兼容端口只设空闲值；该目标没有实现 RX 协议通路。
    dut.ff_tx_sop.value = 0
    for network in ("a", "b"):
        for name in ("p0_txc", "p0_col", "p0_crs", "reg_wr", "reg_rd", "reg_addr",
                     "reg_data_in"):
            getattr(dut, f"{name}_{network}").value = 0
    tb = AfdxTB(dut, app_names=TX_MAC_APP, gmii_names=TX_MAC_GMII, reset_name="reset")
    await tb.start()
    for index, length in enumerate((1, 16, 64)):
        # TB_ONLY_DEFAULT: 不把这些端口或载荷解释为正式应用请求。
        transaction = AppTransaction(bytes((i + index) % 256 for i in range(length)),
                                     40000 + index, 16000 + index, 3 + index,
                                     f"tx-mac-{index}")
        await tb.send_app(transaction, gap_cycles=int(index == 1))
        accepted = await tb.recv_app()
        assert accepted.payload == transaction.payload
        assert accepted.src_udp == transaction.src_udp
        assert accepted.dst_udp == transaction.dst_udp
        assert accepted.application_port == transaction.application_port
        for network in ("a", "b"):
            frame = await tb.recv_gmii(network)
            assert len(frame) >= 64, f"GMII {network}: no complete frame captured"
            assert not frame.error, f"GMII {network}: TX_ER asserted"
    assert tb.app.transactions_sent == 3
    tb.close()
