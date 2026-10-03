"""RED-F01 both networks, RED-F02 semantic rather than byte identity."""

import cocotb

from checkers.tx_redundancy import check_ab_semantics
from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG as CONFIG
from .common import TxFeatureCase, transaction, require


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_red_f01_each_transaction_on_both_networks(dut):
    async with TxFeatureCase(dut, "test_red_f01_each_transaction_on_both_networks", ["RED-F01"]) as case:
        for port in CONFIG.ports:
            await case.send(transaction(f"dual-network-port-{port}", 16, port=port), queued=port > 1)
        await case.finish()
        for network in ("a", "b"):
            require(case.scoreboard.matched_count[network] == len(CONFIG.ports), "RED-F01", case.name,
                    network, "matched_frame_count", len(CONFIG.ports), case.scoreboard.matched_count[network])


@cocotb.test(timeout_time=500, timeout_unit="us")
async def test_red_f02_ab_logical_content_consistency(dut):
    async with TxFeatureCase(dut, "test_red_f02_ab_logical_content_consistency", ["RED-F02"]) as case:
        for index, length in enumerate((1, 16, 64, 484, 516, 1471)):
            await case.send(transaction(f"ab-content-{index}", length, port=index % 5+1,
                                        src_udp=index, dst_udp=65535-index), queued=index > 0)
        await case.finish()
        for record in case.inputs:
            txid = record["transaction_id"]
            a, b = case.actual(txid, "a"), case.actual(txid, "b")
            check_ab_semantics(a, b, txid)
            require(a.src_mac != b.src_mac, "RED-F02", txid, "a/b", "configured_src_mac_difference",
                    "distinct A/B source MACs in TB_ONLY_DEFAULT", (a.src_mac.hex(), b.src_mac.hex()))
