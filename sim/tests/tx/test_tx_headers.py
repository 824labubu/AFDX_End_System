"""all checks use independently configured expected frames."""

import cocotb

from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG as CONFIG
from .common import TxFeatureCase, transaction, require


@cocotb.test(timeout_time=500, timeout_unit="us")
async def test_tx_f03_udp_ports_lengths_checksum(dut):
    async with TxFeatureCase(dut, "test_tx_f03_udp_ports_lengths_checksum", ["TX-F03"]) as case:
        for index, (length, src, dst) in enumerate(((1, 0, 65535), (16, 65535, 0),
                (64, 1, 1), (484, 161, 40000), (516, 69, 49152), (1471, 12345, 54321))):
            tx = transaction(f"udp-{index}", length, port=index % 5 + 1, src_udp=src, dst_udp=dst)
            await case.send(tx, queued=index > 0)
        await case.finish()
        for record in case.inputs:
            for network in ("a", "b"):
                actual = case.actual(record["transaction_id"], network)
                require(actual.udp_length == 8+record["length"], "TX-F03", record["transaction_id"],
                        network, "udp_length", 8+record["length"], actual.udp_length)


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f04_ipv4_fields_all_routes(dut):
    async with TxFeatureCase(dut, "test_tx_f04_ipv4_fields_all_routes", ["TX-F04"]) as case:
        for port in CONFIG.ports:
            await case.send(transaction(f"ipv4-port-{port}", 16+port, port=port), queued=port > 1)
        await case.finish()


@cocotb.test(timeout_time=300, timeout_unit="us")
async def test_tx_f05_ethernet_port_vl_mapping(dut):
    async with TxFeatureCase(dut, "test_tx_f05_ethernet_port_vl_mapping", ["TX-F05"]) as case:
        for iteration in range(2):
            for port in CONFIG.ports:
                await case.send(transaction(f"ethernet-{iteration}-port-{port}", 16, port=port),
                                queued=bool(iteration or port > 1))
        await case.finish()
