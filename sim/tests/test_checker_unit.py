"""Checker and coverage self-tests: genuine negative paths, independent of RTL."""

import unittest
from dataclasses import replace
from pathlib import Path
import json
import tempfile

from checkers.tx_wire import PREAMBLE_SFD, WireMismatch, check_preamble, check_ifg
from checkers.tx_redundancy import AbSemanticMismatch, check_ab_semantics
from afdx.transactions import AppTransaction
from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG
from model.tx_reference import AfdxTxReferenceModel
from scoreboard.tx_scoreboard import TxScoreboard
from functional_coverage.tx import TxFunctionalCoverage, collect


class WireCheckerTests(unittest.TestCase):
    def record(self, gap=None, prefix=PREAMBLE_SFD):
        return {"network": "b", "prefix": list(prefix), "start_ns": 1000,
                "previous_end_ns": 800, "idle_cycles": gap}

    def test_valid_preamble(self):
        check_preamble(self.record(), "tx-id")

    def test_missing_preamble_byte_reports_offset(self):
        with self.assertRaises(WireMismatch) as caught:
            check_preamble(self.record(prefix=bytes([0x55]*6+[0xd5])), "tx-id")
        self.assertEqual(caught.exception.details["byte_offset"], 6)
        self.assertIn("[TX-F10][id=tx-id][B]", str(caught.exception))

    def test_bad_sfd(self):
        with self.assertRaises(WireMismatch) as caught:
            check_preamble(self.record(prefix=bytes([0x55]*8)), "sfd-id")
        self.assertEqual(caught.exception.details["byte_offset"], 7)

    def test_ifg_first_frame_or_at_least_twelve(self):
        for gap in (None, 12, 13, 1000):
            check_ifg(self.record(gap), "gap-id", 12)

    def test_short_ifg_has_times_and_cycle_diagnostic(self):
        with self.assertRaises(WireMismatch) as caught:
            check_ifg(self.record(11), "gap-id", 12)
        details = caught.exception.details
        self.assertEqual((details["observed_cycles"], details["required_cycles"]), (11, 12))
        self.assertEqual((details["previous_end"], details["next_start"]), (800, 1000))


class RedundancyCheckerTests(unittest.TestCase):
    def setUp(self):
        copies = AfdxTxReferenceModel(TB_ONLY_DEFAULT_MODEL_CONFIG).build(
            AppTransaction(b"hello", 123, 456, 3, "ab-unit"))
        self.a, self.b = (copy.decoded for copy in copies)

    def test_configured_mac_and_fcs_difference_is_allowed(self):
        self.assertNotEqual(self.a.src_mac, self.b.src_mac)
        self.assertNotEqual(self.a.fcs, self.b.fcs)
        check_ab_semantics(self.a, self.b, "ab-unit")

    def test_sequence_or_payload_difference_is_a_field_mismatch(self):
        for field, value in (("sequence_number", 2), ("payload", b"wrong")):
            with self.assertRaises(AbSemanticMismatch) as caught:
                check_ab_semantics(self.a, replace(self.b, **{field: value}), "ab-unit")
            self.assertEqual(caught.exception.mismatches[0].field, field)
            self.assertIn("[RED-F02][id=ab-unit][A/B]", str(caught.exception))


class CoverageTests(unittest.TestCase):
    def sample(self, items=None):
        items = items or [(3, 16, 0, 0, 0, False, 0)]
        model = AfdxTxReferenceModel(TB_ONLY_DEFAULT_MODEL_CONFIG)
        scoreboard = TxScoreboard("coverage-unit")
        case = dict(test_name="coverage-unit", features=["TX-F06"], status="PASS",
                    failure=None, inputs=[], outputs=[], rejections=[], wire={})
        last_epoch = 0
        for index, (port, length, stalls, last_stalls, gaps, queued, epoch) in enumerate(items):
            if epoch != last_epoch:
                model.reset()
                last_epoch = epoch
            txid = f"id-{index}"
            frames = model.build(AppTransaction(bytes([index % 256])*length, 1, 2, port, txid))
            scoreboard.expect(frames)
            case["inputs"].append(dict(transaction_id=txid, length=length, port=port,
                                       epoch=epoch, expected=True, accepted_bytes=length,
                                       stalled_cycles=stalls, last_stalled_cycles=last_stalls,
                                       valid_gap_cycles=gaps, queued_without_user_delay=queued))
            for frame in frames:
                scoreboard.observe(frame.network, frame.frame_bytes, timestamp_ns=index)
                case["outputs"].append(dict(transaction_id=txid, network=frame.network,
                    length=length, vl=frame.vl_id, sn=frame.sequence_number,
                    pad_length=len(frame.decoded.padding), epoch=epoch, fcs_valid=True))
        scoreboard.finish(timestamp_ns=100)
        return case, scoreboard.summary()

    def test_failed_case_cannot_close_bins(self):
        case, sb = self.sample()
        case["status"], case["failure"] = "FAIL", "DUT mismatch"
        coverage = TxFunctionalCoverage()
        coverage.ingest(case, sb)
        self.assertEqual(coverage.summary()["hit_bin_count"], 0)
        self.assertEqual(len(coverage.failed_cases), 1)

    def test_bag_feature_cannot_be_reintroduced(self):
        case, sb = self.sample()
        case["features"].append("TX-F07")
        with self.assertRaisesRegex(ValueError, "REMOVED"):
            TxFunctionalCoverage().ingest(case, sb)

    def test_backpressure_cross_uses_observed_stall(self):
        coverage = TxFunctionalCoverage()
        case, sb = self.sample([(3, 16, 0, 0, 0, True, 0)])
        coverage.ingest(case, sb)
        self.assertEqual(coverage.bins["payload_x_backpressure"]["16"], 0)
        self.assertEqual(coverage.bins["flow"]["back_to_back"], 0)
        case, sb = self.sample([(3, 1, 4, 4, 0, True, 0)])
        coverage.ingest(case, sb)
        self.assertGreater(coverage.bins["flow"]["last_backpressure"], 0)
        self.assertGreater(coverage.bins["payload_x_backpressure"]["1"], 0)

    def test_sequence_bins_from_actual_per_vl_epoch(self):
        case, sb = self.sample([(3, 16, 0, 0, 0, False, 0), (4, 16, 0, 0, 0, False, 0),
                               (3, 16, 0, 0, 0, False, 0), (3, 1, 0, 0, 0, False, 1)])
        coverage = TxFunctionalCoverage()
        coverage.ingest(case, sb)
        for bin_name in ("increment", "multi_vl", "reset"):
            self.assertGreater(coverage.bins["sequence"][bin_name], 0)
        self.assertEqual(coverage.bins["sequence"]["wrap"], 0)

    def test_missing_observations_cannot_close_coverage(self):
        case, sb = self.sample()
        case["outputs"].pop()
        with self.assertRaisesRegex(ValueError, "incomplete observed-frame"):
            TxFunctionalCoverage().ingest(case, sb)

    def test_report_holes_remain_visible(self):
        coverage = TxFunctionalCoverage()
        coverage.ingest(*self.sample())
        with tempfile.TemporaryDirectory() as directory:
            report = coverage.write(directory)
            saved = json.loads((Path(directory)/"functional_coverage.json").read_text())
            self.assertFalse(report["complete"])
            self.assertEqual(saved["removed"], {"TX-F07": "REMOVED"})
            self.assertIn("1471", saved["missing"]["payload"])
            self.assertEqual(saved["hit_bin_count"], report["hit_bin_count"])

    def test_xml_failure_overrides_pass_artifact(self):
        case, sb = self.sample()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/"target"
            target.mkdir()
            (target/"coverage-unit.case.json").write_text(json.dumps(case))
            (target/"coverage-unit.scoreboard.json").write_text(json.dumps(sb))
            (target/"results.xml").write_text('<testsuite><testcase name="coverage-unit"><failure/></testcase></testsuite>')
            report = collect([target], Path(directory)/"report")
            self.assertEqual(report["hit_bin_count"], 0)
            self.assertEqual(len(report["failed_cases"]), 1)


if __name__ == "__main__":
    unittest.main()
