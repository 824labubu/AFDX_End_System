"""Functional coverage from observed, successfully checked TX transactions.

Coverage is not a checker. Failing cases never close bins. Required crosses
are explicit finite sets, not a full Cartesian product or a BAG analysis.
"""

from pathlib import Path
import json
import xml.etree.ElementTree as ET

from model.config import TB_ONLY_DEFAULT_MODEL_CONFIG


FEATURES = ("TX-F01", "TX-F02", "TX-F03", "TX-F04", "TX-F05", "TX-F06",
            "TX-F08", "TX-F09", "TX-F10", "TX-F11", "RED-F01", "RED-F02")
KEY_LENGTHS = (1, 2, 16, 64, 484, 516, 1471)


class TxFunctionalCoverage:
    def __init__(self, config=TB_ONLY_DEFAULT_MODEL_CONFIG):
        self.config = config
        self.boundary = config.min_frame_bytes - (14+20+8+1)
        required = {
            "feature": FEATURES,
            "payload": ("0", "1", "short", "16", "64", "around_484", "around_516", "1471", "1472"),
            "port": tuple(str(p) for p in config.ports),
            "vl": tuple(str(v) for v in sorted({r.vl_id for r in config.ports.values()})),
            "flow": ("continuous", "valid_gap", "backpressure", "last_backpressure", "back_to_back"),
            "sequence": ("increment", "multi_vl", "wrap", "reset"),
            "padding": ("padding_yes", "padding_no", "boundary"),
            "network": ("a", "b"),
            "rejection": ("0_interface_reject", "1472_dut_drop"),
            "wire": ("a:preamble", "b:preamble", "a:ifg", "b:ifg"),
            "payload_x_backpressure": tuple(str(n) for n in KEY_LENGTHS),
            "port_vl_x_sequence": tuple(f"{p}:{r.vl_id}:{mode}" for p, r in config.ports.items()
                                         for mode in ("increment", "reset")),
            "padding_x_payload": ("1:yes", "16:yes", "17:no", "18:no", "64:no",
                                  "484:no", "516:no", "1471:no"),
            "network_x_fcs": ("a:valid", "b:valid"),
            # Boundary neighborhoods are exact bins, so an 'around' category
            # alone cannot hide the missing -1 or +1 stimulus.
            "neighborhood": tuple(str(n) for n in (16, 17, 18, 483, 484, 485, 515, 516, 517)),
        }
        self.bins = {group: {key: 0 for key in keys} for group, keys in required.items()}
        self.evidence = {group: {key: [] for key in keys} for group, keys in required.items()}
        self.passed_cases, self.failed_cases = [], []

    def hit(self, group, key, evidence):
        key = str(key)
        if key not in self.bins[group]:
            raise ValueError(f"undeclared coverage bin {group}/{key}")
        self.bins[group][key] += 1
        if len(self.evidence[group][key]) < 5:
            self.evidence[group][key].append(evidence)

    def optional_hit(self, group, key, evidence):
        if str(key) in self.bins[group]:
            self.hit(group, key, evidence)

    def payload(self, length, evidence):
        self.optional_hit("payload", length, evidence)
        self.optional_hit("neighborhood", length, evidence)
        if 1 < length < self.boundary:
            self.hit("payload", "short", evidence)
        if 483 <= length <= 485:
            self.hit("payload", "around_484", evidence)
        if 515 <= length <= 517:
            self.hit("payload", "around_516", evidence)

    def ingest(self, case, scoreboard):
        name = case["test_name"]
        if "TX-F07" in case["features"]:
            raise ValueError("TX-F07 is REMOVED and must not be exercised")
        if case["status"] != "PASS" or scoreboard["mismatch_count"]:
            self.failed_cases.append({"test_name": name, "failure": case.get("failure")})
            return
        if any(scoreboard["pending"].values()) or not scoreboard["comparisons"]:
            raise ValueError(f"{name}: coverage requires completed scoreboard checks")
        if not all(report["passed"] for report in scoreboard["comparisons"]):
            raise ValueError(f"{name}: unsuccessful comparison cannot close coverage")
        if len(case["outputs"]) != len(scoreboard["comparisons"]):
            raise ValueError(f"{name}: incomplete observed-frame telemetry")
        self.passed_cases.append(name)
        for feature in case["features"]:
            self.hit("feature", feature, name)
        for rejection in case["rejections"]:
            self.payload(rejection["length"], name)
            self.hit("rejection", f"{rejection['length']}_{rejection['kind']}", name)

        outputs = {(r["transaction_id"], r["network"]): r for r in case["outputs"]}
        previous, visited = {}, set()
        for record in case["inputs"]:
            if not record["expected"]:
                continue
            txid, length, port = record["transaction_id"], record["length"], record["port"]
            source = f"{name}/{txid}"
            route = self.config.ports[port]
            a = outputs[(txid, "a")]
            b = outputs[(txid, "b")]
            if a["length"] != length or b["length"] != length or record["accepted_bytes"] != length:
                raise ValueError(f"{source}: incomplete payload observation")
            self.payload(length, source)
            self.hit("port", port, source)
            self.hit("vl", a["vl"], source)
            visited.add(a["vl"])
            if record["valid_gap_cycles"]:
                self.hit("flow", "valid_gap", source)
            else:
                self.hit("flow", "continuous", source)
            if record["stalled_cycles"]:
                self.hit("flow", "backpressure", source)
                self.optional_hit("payload_x_backpressure", length, source)
                if record["queued_without_user_delay"]:
                    # Next message was actually presented while TX was busy;
                    # caller inserts no delay beyond the application driver.
                    self.hit("flow", "back_to_back", source)
            if record["last_stalled_cycles"]:
                self.hit("flow", "last_backpressure", source)
            key = (record["epoch"], a["vl"])
            prev = previous.get(key)
            mode = None
            if prev == self.config.sequence_last and a["sn"] == self.config.sequence_first:
                mode = "wrap"
            elif prev is not None and a["sn"] == prev+1:
                mode = "increment"
            elif prev is None and record["epoch"] > 0 and a["sn"] == self.config.sequence_first:
                mode = "reset"
            if mode:
                self.hit("sequence", mode, source)
                self.optional_hit("port_vl_x_sequence", f"{port}:{route.vl_id}:{mode}", source)
                if mode == "increment" and len(visited) > 1:
                    self.hit("sequence", "multi_vl", source)
            previous[key] = a["sn"]
            for output in (a, b):
                network = output["network"]
                self.hit("network", network, source)
                padding = "yes" if output["pad_length"] else "no"
                self.hit("padding", f"padding_{padding}", source)
                self.optional_hit("padding_x_payload", f"{length}:{padding}", source)
                if length == self.boundary:
                    self.hit("padding", "boundary", source)
                if output["fcs_valid"]:
                    self.hit("network_x_fcs", f"{network}:valid", source)
        for network, records in case.get("wire", {}).items():
            for record in records:
                if record.get("preamble_valid"):
                    self.hit("wire", f"{network}:preamble", name)
                if record.get("ifg_valid"):
                    self.hit("wire", f"{network}:ifg", name)

    def summary(self):
        missing = {group: [key for key, hits in bins.items() if not hits]
                   for group, bins in self.bins.items()}
        total = sum(len(bins) for bins in self.bins.values())
        hit = sum(bool(hits) for bins in self.bins.values() for hits in bins.values())
        return {"profile": self.config.label, "removed": {"TX-F07": "REMOVED"},
                "required_bin_count": total, "hit_bin_count": hit,
                "complete": not any(missing.values()) and not self.failed_cases,
                "bins": self.bins, "missing": missing, "evidence": self.evidence,
                "passed_cases": self.passed_cases, "failed_cases": self.failed_cases,
                "notes": ["0 B is host interface rejection, not a DUT zero-length packet",
                          "1472 B is observed DUT drop with finite quiet window and recovery",
                          "back-to-back uses application driver cleanup cycles; no caller-added delay",
                          "no BAG, jitter, RX or full Cartesian cross coverage"]}

    def write(self, directory):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        report = self.summary()
        (directory / "functional_coverage.json").write_text(json.dumps(report, indent=2)+"\n")
        lines = [f"TX Functional Coverage: {report['hit_bin_count']}/{report['required_bin_count']}",
                 "TX-F07 = REMOVED", f"passed_cases={len(self.passed_cases)} failed_cases={len(self.failed_cases)}"]
        for group, bins in self.bins.items():
            lines.append(f"{group}: {sum(bool(v) for v in bins.values())}/{len(bins)} "
                         f"missing={report['missing'][group]}")
        (directory / "functional_coverage.txt").write_text("\n".join(lines)+"\n")
        return report


def collect(target_directories, report_directory):
    collector = TxFunctionalCoverage()
    for directory in target_directories:
        results = Path(directory) / "results.xml"
        if not results.is_file():
            collector.failed_cases.append({"test_name": str(directory), "failure": "no result XML"})
            continue
        cases = ET.parse(results).getroot().findall(".//testcase")
        passed = {case.attrib["name"] for case in cases
                  if not any(case.find(tag) is not None for tag in ("failure", "error", "skipped"))}
        files = sorted(Path(directory).glob("*.case.json"))
        if not files:
            collector.failed_cases.append({"test_name": str(directory), "failure": "no TX case artifacts"})
        for path in files:
            scoreboard_path = path.with_name(path.name.replace(".case.json", ".scoreboard.json"))
            case = json.loads(path.read_text())
            if case["test_name"] not in passed:
                case["status"], case["failure"] = "FAIL", "test did not pass result XML"
            collector.ingest(case, json.loads(scoreboard_path.read_text()))
    return collector.write(report_directory)
