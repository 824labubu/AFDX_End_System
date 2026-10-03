"""Reference infrastructure unit tests; standard-library unittest, no RTL."""

import unittest
from dataclasses import replace

from model.checksums import ethernet_crc32, ethernet_fcs, internet_checksum, ipv4_checksum
from decoder.tx_frame_decoder import decode_tx_frame, FrameDecodeError
from model.builders import build_udp, build_ipv4, build_ethernet
from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG, NetworkConfig
from model.tx_reference import AfdxTxReferenceModel
from afdx.transactions import AppTransaction
from scoreboard.tx_scoreboard import TxScoreboard, TxFrameMismatch, compare_tx_frame


# Fixed, independently encoded fixture; not produced by the builders/model
# under test. IPv4 lengths count UDP only; 13 AA padding bytes precede SN=7.
GOLDEN_FRAME = bytes.fromhex(
    "0300000001230200000000010800"
    "450000200000400001118d96c0000201c6336402"
    "12345678000c0000deadbeef"
    "aaaaaaaaaaaaaaaaaaaaaaaaaa07"
    "aeb3231d"
)


class ChecksumTests(unittest.TestCase):
    def test_crc_known_vector_and_wire_order(self):
        self.assertEqual(ethernet_crc32(b"123456789"), 0xcbf43926)
        self.assertEqual(ethernet_fcs(b"123456789"), bytes.fromhex("2639f4cb"))
        self.assertEqual(ethernet_crc32(b""), 0)

    def test_rfc1071_numerical_example(self):
        # RFC 1071 section 3 gives the folded sum 0xddf2 for these octets.
        self.assertEqual(internet_checksum(bytes.fromhex("0001f203f4f5f6f7")), 0x220d)
        self.assertEqual(internet_checksum(bytes.fromhex("010203")), 0xfbfd)
        self.assertEqual(internet_checksum(bytes.fromhex("ffffffffffff")), 0)

    def test_ipv4_known_header(self):
        # Fixed IPv4 vector. The value is a literal oracle; it is not generated
        # by the builder under test or obtained from a DUT transmission.
        header = bytes.fromhex("450000730000400040110000c0a80001c0a800c7")
        self.assertEqual(ipv4_checksum(header), 0xb861)
        valid = header[:10] + bytes.fromhex("b861") + header[12:]
        self.assertEqual(internet_checksum(valid), 0)
        self.assertEqual(ipv4_checksum(valid), 0xb861)
        self.assertNotEqual(internet_checksum(valid[:-1] + b"\xc6"), 0)

    def test_ipv4_rejects_partial_header(self):
        for header in (b"", bytes(19), bytes(21), bytes(64)):
            with self.assertRaises(ValueError):
                ipv4_checksum(header)


class DecoderTests(unittest.TestCase):
    def test_independent_literal_fixture(self):
        frame = decode_tx_frame(GOLDEN_FRAME)
        self.assertEqual(frame.frame_length, 64)
        self.assertEqual(frame.dst_mac.hex(), "030000000123")
        self.assertEqual(frame.src_mac.hex(), "020000000001")
        self.assertEqual(frame.eth_type, 0x0800)
        self.assertEqual((frame.ip_version, frame.ip_ihl, frame.ip_total_length), (4, 5, 32))
        self.assertEqual((frame.src_ip, frame.dst_ip), (0xc0000201, 0xc6336402))
        self.assertEqual((frame.ip_protocol, frame.ip_ttl, frame.ip_flags), (17, 1, 2))
        self.assertEqual(frame.ip_checksum, 0x8d96)
        self.assertEqual((frame.udp_src_port, frame.udp_dst_port, frame.udp_length),
                         (0x1234, 0x5678, 12))
        self.assertEqual(frame.payload, bytes.fromhex("deadbeef"))
        self.assertEqual(frame.padding, bytes([0xaa]) * 13)
        self.assertEqual(frame.sequence_number, 7)
        self.assertEqual(frame.fcs, 0x1d23b3ae)
        self.assertEqual(frame.ip_trailing_bytes, b"")

    def test_decoder_does_not_validate_checksums_or_protocol_fields(self):
        bad = bytearray(GOLDEN_FRAME)
        bad[12:14] = bytes.fromhex("88b5")
        bad[14] = 0x65
        bad[23] = 6
        bad[24:26] = b"\x00\x00"
        bad[-1] ^= 1
        frame = decode_tx_frame(bad)
        self.assertEqual((frame.eth_type, frame.ip_version, frame.ip_protocol), (0x88b5, 6, 6))
        self.assertEqual(frame.ip_checksum, 0)
        self.assertEqual(frame.fcs, 0x1c23b3ae)

    def test_ip_and_udp_ranges_remain_distinct(self):
        bad = bytearray(GOLDEN_FRAME)
        bad[38:40] = (11).to_bytes(2, "big")
        frame = decode_tx_frame(bad)
        self.assertEqual(frame.payload, bytes.fromhex("deadbe"))
        self.assertEqual(frame.ip_trailing_bytes, b"\xef")
        self.assertEqual(frame.padding, bytes([0xaa]) * 13)

    def test_structural_truncation_errors(self):
        for raw in (GOLDEN_FRAME[:30], GOLDEN_FRAME[:-18]):
            with self.assertRaises(FrameDecodeError):
                decode_tx_frame(raw)
        bad = bytearray(GOLDEN_FRAME)
        bad[38:40] = (0xffff).to_bytes(2, "big")
        with self.assertRaisesRegex(FrameDecodeError, "udp_length"):
            decode_tx_frame(bad)
        # Removing only trailing bytes still leaves parsable declared ranges;
        # length/FCS correctness belongs to the checker rather than the parser.
        self.assertEqual(decode_tx_frame(GOLDEN_FRAME[:-10]).frame_length, 54)


class BuilderTests(unittest.TestCase):
    def test_udp_literal_encoding(self):
        packet = build_udp(b"\x01\x02\x03", 0x1234, 0x5678, checksum_mode="zero")
        self.assertEqual(packet, bytes.fromhex("12345678000b0000010203"))
        with self.assertRaisesRegex(ValueError, "checksum_mode"):
            build_udp(b"x", 1, 2, checksum_mode="unknown")

    def test_ipv4_literal_encoding(self):
        packet = build_ipv4(bytes(95), 0xc0a80001, 0xc0a800c7,
                            identification=0, flags=2, ttl=64, tos=0)
        self.assertEqual(packet[:20], bytes.fromhex(
            "45000073000040004011b861c0a80001c0a800c7"))
        self.assertEqual(len(packet), 115)

    def test_layer_round_trip_matches_independent_fixture(self):
        udp = build_udp(bytes.fromhex("deadbeef"), 0x1234, 0x5678, checksum_mode="zero")
        ip = build_ipv4(udp, 0xc0000201, 0xc6336402,
                        identification=0, flags=2, ttl=1, tos=0)
        raw = build_ethernet(ip, bytes.fromhex("020000000001"), bytes.fromhex("030000000123"),
                             eth_type=0x0800, min_frame_bytes=60, pad_byte=0xaa, trailer=b"\x07")
        self.assertEqual(raw, GOLDEN_FRAME)
        frame = decode_tx_frame(raw)
        self.assertEqual(frame.payload, bytes.fromhex("deadbeef"))
        self.assertEqual(frame.sequence_number, 7)
        self.assertEqual(frame.fcs, ethernet_crc32(raw[:-4]))
        self.assertEqual(internet_checksum(frame.ip_header), 0)

    def test_options_are_located_by_ihl(self):
        udp = build_udp(b"hello", 1, 2, checksum_mode="zero")
        ip = build_ipv4(udp, 1, 2, identification=1, flags=2, ttl=1, tos=0,
                        options=bytes.fromhex("01010000"))
        raw = build_ethernet(ip, bytes(6), bytes(6), eth_type=0x0800,
                             min_frame_bytes=60, pad_byte=0, trailer=b"\x01")
        frame = decode_tx_frame(raw)
        self.assertEqual(frame.ip_ihl, 6)
        self.assertEqual(frame.ip_options, bytes.fromhex("01010000"))
        self.assertEqual(frame.payload, b"hello")

    def test_builder_input_bounds(self):
        with self.assertRaises(ValueError):
            build_udp(b"x", 65536, 2, checksum_mode="zero")
        with self.assertRaises(ValueError):
            build_ipv4(b"x", 1, 2, identification=0, flags=2, ttl=1, tos=0, options=b"x")
        with self.assertRaises(ValueError):
            build_ethernet(b"x", bytes(5), bytes(6), eth_type=0x0800,
                           min_frame_bytes=60, pad_byte=0)


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.model = AfdxTxReferenceModel(TB_ONLY_DEFAULT_MODEL_CONFIG)

    def transaction(self, port=3, length=16):
        return AppTransaction(bytes(i % 256 for i in range(length)), 40000, 161, port, "unit-tx")

    def test_frame_sizes_and_application_fields(self):
        for length, frame_length, padding in ((1, 64, 16), (16, 64, 1), (1471, 1518, 0)):
            with self.subTest(length=length):
                expected = self.model.build(self.transaction(length=length))[0]
                self.assertEqual(len(expected.frame_bytes), frame_length)
                self.assertEqual(expected.decoded.payload, self.transaction(length=length).payload)
                self.assertEqual(expected.decoded.padding, bytes([0xaa]) * padding)
                self.assertEqual(expected.decoded.udp_length, length + 8)
                self.assertEqual(expected.decoded.ip_total_length, length + 28)

    def test_sequence_progression_and_vl_independence(self):
        actual = [self.model.build(self.transaction(port))[0].sequence_number for port in (3, 3, 4, 3, 4)]
        self.assertEqual(actual, [1, 2, 1, 3, 2])
        self.assertEqual(self.model.state.sequence_by_vl, {3: 3, 4: 2})

    def test_sequence_is_keyed_by_vl_not_application_port(self):
        cfg = TB_ONLY_DEFAULT_MODEL_CONFIG
        routes = dict(cfg.ports)
        routes[4] = replace(routes[4], vl_id=3)
        model = AfdxTxReferenceModel(replace(cfg, ports=routes))
        self.assertEqual(model.build(self.transaction(3))[0].sequence_number, 1)
        self.assertEqual(model.build(self.transaction(4))[0].sequence_number, 2)

    def test_wrap_and_reset_are_reference_owned(self):
        for sequence in range(1, 256):
            self.assertEqual(self.model.build(self.transaction())[0].sequence_number, sequence)
        self.assertEqual(self.model.build(self.transaction())[0].sequence_number, 1)
        self.model.reset()
        self.assertEqual(self.model.build(self.transaction())[0].sequence_number, 1)

    def test_rejected_configuration_input_does_not_advance_state(self):
        for transaction in (self.transaction(6), self.transaction(length=1472)):
            with self.assertRaises(ValueError):
                self.model.build(transaction)
        self.assertEqual(self.model.state.sequence_by_vl, {})
        cfg = replace(TB_ONLY_DEFAULT_MODEL_CONFIG, max_frame_bytes=64)
        model = AfdxTxReferenceModel(cfg)
        with self.assertRaises(ValueError):
            model.build(self.transaction(length=64))
        self.assertEqual(model.state.sequence_by_vl, {})


class DualNetworkTests(unittest.TestCase):
    def test_independent_network_addresses_and_fcs_share_one_sequence(self):
        cfg = TB_ONLY_DEFAULT_MODEL_CONFIG
        ports = dict(cfg.ports)
        networks = dict(ports[3].networks)
        networks["b"] = NetworkConfig(bytes.fromhex("020000112233"), bytes.fromhex("030000000099"))
        ports[3] = replace(ports[3], networks=networks)
        model = AfdxTxReferenceModel(replace(cfg, ports=ports))
        a, b = model.build(AppTransaction(b"hello", 1234, 5678, 3))
        self.assertEqual((a.network, b.network), ("a", "b"))
        self.assertEqual((a.sequence_number, b.sequence_number), (1, 1))
        self.assertEqual(model.state.sequence_by_vl, {3: 1})
        self.assertNotEqual(a.decoded.src_mac, b.decoded.src_mac)
        self.assertNotEqual(a.decoded.dst_mac, b.decoded.dst_mac)
        self.assertNotEqual(a.decoded.fcs, b.decoded.fcs)
        self.assertEqual(a.frame_bytes[12:-4], b.frame_bytes[12:-4])
        for expected in (a, b):
            self.assertEqual(expected.decoded.fcs, ethernet_crc32(expected.frame_bytes[:-4]))

    def test_configuration_is_snapshotted(self):
        cfg = TB_ONLY_DEFAULT_MODEL_CONFIG
        ports = dict(cfg.ports)
        snapshot = replace(cfg, ports=ports)
        ports.clear()
        self.assertEqual(len(snapshot.ports), 5)
        with self.assertRaises(TypeError):
            snapshot.ports[1] = cfg.ports[1]


class ScoreboardTests(unittest.TestCase):
    def setUp(self):
        self.expected = AfdxTxReferenceModel(TB_ONLY_DEFAULT_MODEL_CONFIG).build(
            AppTransaction(bytes(range(16)), 40000, 161, 3, "txn-scoreboard"))

    def compare(self, raw):
        return compare_tx_frame(self.expected[0], raw, test_name="unit-checker",
                                network="a", timestamp_ns=123.5)

    def test_field_diagnostics_and_byte_difference(self):
        raw = bytearray(self.expected[0].frame_bytes)
        raw[39] += 1
        report = self.compare(raw)
        self.assertFalse(report.passed)
        names = {m.field for m in report.mismatches}
        self.assertTrue({"udp_length", "payload_length", "payload", "fcs_valid"} <= names)
        self.assertEqual(report.first_difference.offset, 39)
        for text in ("TX FRAME MISMATCH", "unit-checker", "txn-scoreboard", "network=A",
                     "timestamp_ns=123.5", "udp_length", "expected_length", "byte_offset=39"):
            self.assertIn(text, report.format())
        self.assertEqual(report.to_dict()["actual_bytes"], raw.hex())

    def test_corrupt_fcs_is_not_repaired_by_decoder(self):
        raw = bytearray(self.expected[0].frame_bytes)
        raw[-1] ^= 1
        self.assertEqual({m.field for m in self.compare(raw).mismatches}, {"fcs", "fcs_valid"})

    def test_ip_checksum_failure(self):
        raw = bytearray(self.expected[0].frame_bytes)
        raw[24] ^= 1
        raw[-4:] = ethernet_fcs(raw[:-4])
        names = {m.field for m in self.compare(raw).mismatches}
        self.assertTrue({"ip_checksum", "ip_checksum_valid", "fcs"} <= names)
        self.assertNotIn("fcs_valid", names)

    def test_structural_error_is_a_report_not_an_unhandled_exception(self):
        report = self.compare(self.expected[0].frame_bytes[:30])
        self.assertFalse(report.passed)
        self.assertIn("decode_error", {m.field for m in report.mismatches})
        self.assertEqual(report.first_difference.offset, 30)

    def test_counts_missing_and_duplicate_frames(self):
        scoreboard = TxScoreboard("unit-accounting")
        scoreboard.expect(self.expected)
        a, b = self.expected
        scoreboard.observe("a", a.frame_bytes, timestamp_ns=1)
        with self.assertRaises(TxFrameMismatch):
            scoreboard.finish(timestamp_ns=2)
        self.assertEqual(scoreboard.summary()["pending"], {"a": 0, "b": 1})
        with self.assertRaisesRegex(TxFrameMismatch, "unexpected_frame"):
            scoreboard.observe("a", a.frame_bytes, timestamp_ns=3)

    def test_network_order_and_successful_finish(self):
        scoreboard = TxScoreboard("unit-success")
        scoreboard.expect(self.expected)
        for expected in reversed(self.expected):
            scoreboard.observe(expected.network, expected.frame_bytes, timestamp_ns=1)
        scoreboard.finish(timestamp_ns=2)
        self.assertEqual(scoreboard.summary()["matched"], {"a": 1, "b": 1})
        self.assertEqual(scoreboard.summary()["mismatch_count"], 0)

    def test_out_of_order_transaction_and_gmii_error(self):
        model = AfdxTxReferenceModel(TB_ONLY_DEFAULT_MODEL_CONFIG)
        first = model.build(AppTransaction(b"first", 1, 2, 3, "first"))
        second = model.build(AppTransaction(b"second", 1, 2, 3, "second"))
        scoreboard = TxScoreboard("unit-order")
        scoreboard.expect(first)
        scoreboard.expect(second)
        with self.assertRaises(TxFrameMismatch) as raised:
            scoreboard.observe("a", second[0].frame_bytes, timestamp_ns=1)
        self.assertEqual(raised.exception.report.transaction_id, "first")
        report = compare_tx_frame(first[0], first[0].frame_bytes, test_name="unit-error",
                                  network="a", timestamp_ns=1, gmii_error=True)
        self.assertEqual([m.field for m in report.mismatches], ["gmii_tx_error"])


if __name__ == "__main__":
    unittest.main()
