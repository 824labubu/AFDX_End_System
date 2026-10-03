#!/usr/bin/env python3
"""统一仿真入口；ModelSim 使用 cocotb Questa 的 VPI 后端。"""

import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import xml.etree.ElementTree as ET


SIM_DIR = Path(__file__).resolve().parent
ROOT = SIM_DIR.parent
LEGACY_DIR = ROOT / "elinx/AFDX_End_System/AFDX_End_System.srcs/sources_1/new"
TX_SUITES = {
    "payload": ("tx-payload", "tx-boundary"),
    "headers": ("tx-headers",),
    "sequence": ("tx-sequence",),
    "ethernet": ("tx-padding", "tx-fcs", "tx-timing"),
    "redundancy": ("tx-redundancy",),
}
TX_TEST_MODULES = {target: "tx.test_tx_" + target.removeprefix("tx-")
                   for targets in TX_SUITES.values() for target in targets}
TX_SUITES["tx"] = tuple(TX_TEST_MODULES)


def sources_for(target):
    if target == "infrastructure":
        return "afdx_infrastructure_harness", [
            ROOT / "rtl/app/app_tx_arbiter.v",
            SIM_DIR / "fixtures/app_stream_assertions.sv",
            SIM_DIR / "fixtures/afdx_infrastructure_harness.sv",
        ], "test_infrastructure", {}
    if target == "tx-mac":
        # TB_ONLY_DEFAULT: 缩短 smoke 的等待时间，不修改 RTL 参数默认值。
        return "AFDX_TX_MAC", [
            LEGACY_DIR / "AFDX_TX_MAC.v",
            LEGACY_DIR / "afdx_mac_tx.v",
            LEGACY_DIR / "afdx_gmii_tx.v",
        ], "test_tx_mac_smoke", {"BAG_CYCLES": 16}
    if target in ("end-system", "tx-reference") or target in TX_TEST_MODULES:
        return "AFDX_End_System_top", [
            LEGACY_DIR / "AFDX_End_System_top.v",
            LEGACY_DIR / "AFDX_TX_MAC.v",
            LEGACY_DIR / "afdx_mac_tx.v",
            LEGACY_DIR / "afdx_gmii_tx.v",
        ], (TX_TEST_MODULES[target] if target in TX_TEST_MODULES else
            "test_tx_reference_smoke" if target == "tx-reference" else "test_end_system_top"), {
            "BAG_CYCLES": 16,  # TB_ONLY_DEFAULT; no BAG/jitter checker
        }
    return "AFDX_TX", [LEGACY_DIR / "AFDX_TX.v"], None, {}


def require_tools(names):
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        raise RuntimeError("BLOCKED: missing simulator executable(s): " + ", ".join(missing))


def verify_results(path):
    if not path.is_file():
        raise RuntimeError(f"FAIL: simulator produced no result XML: {path}")
    cases = ET.parse(path).getroot().findall(".//testcase")
    bad = [case for case in cases if any(case.find(tag) is not None
                                       for tag in ("failure", "error", "skipped"))]
    if not cases or bad:
        raise RuntimeError(f"FAIL: {len(bad)} failed/skipped tests out of {len(cases)}")
    print(f"PASS: {len(cases)} cocotb tests ({path})", flush=True)


def worker(args):
    sys.path.insert(0, str(SIM_DIR / "tests"))
    simulator = "questa" if args.sim in ("modelsim", "questa") else args.sim
    tools = {"icarus": ("iverilog", "vvp"), "questa": ("vlib", "vlog", "vsim"),
             "verilator": ("verilator", "make"), "vcs": ("vcs",)}
    require_tools(tools[simulator])
    if simulator == "verilator":
        version = subprocess.check_output(["verilator", "--version"], text=True)
        match = re.search(r"Verilator (\d+)\.(\d+)", version)
        if not match or tuple(map(int, match.groups())) < (5, 36):
            raise RuntimeError("BLOCKED: cocotb 2.0.1 requires Verilator >= 5.036; "
                               f"found {version.strip()}")
    try:
        from cocotb_tools.runner import get_runner
    except ImportError as exc:
        raise RuntimeError("Install sim/requirements.txt in the active Python environment") from exc
    top, sources, test_module, parameters = sources_for(args.target)
    build = SIM_DIR / "build" / args.sim / args.target
    results = build / "results.xml"
    results.unlink(missing_ok=True)
    if args.target in TX_TEST_MODULES:
        for pattern in ("*.case.json", "*.scoreboard.json"):
            for artifact in build.glob(pattern):
                artifact.unlink()
    runner = get_runner(simulator)
    build_args = ["-Wno-fatal"] if simulator == "verilator" else []
    runner.build(sources=sources, hdl_toplevel=top, parameters=parameters,
                 build_dir=build, always=True, waves=args.waves, build_args=build_args)
    if test_module is None:
        raise RuntimeError("BLOCKED: legacy TX has no complete binding; this is a compile probe")
    python_path = os.pathsep.join(filter(None, (
        str(SIM_DIR), str(SIM_DIR / "tests"), os.environ.get("PYTHONPATH", ""),
    )))
    # 显式选择 VPI，使 Verilog 验证不依赖 ModelSim 的 VHDL FLI 支持。
    test_args = ["-voptargs=+acc"] if simulator == "questa" else []
    runner.test(hdl_toplevel=top, test_module=test_module, build_dir=build,
                test_dir=build, results_xml=str(results), waves=args.waves,
                parameters=parameters, gpi_interfaces=["vpi"], test_args=test_args,
                test_filter=args.test_filter,
                extra_env={"PYTHONPATH": python_path})
    verify_results(results)


def run_bounded(command, cwd, seconds, required_output=None):
    # 墙钟超时负责终止仿真进程组，包括编译和许可证等待。
    process = subprocess.Popen(command, cwd=cwd, start_new_session=(os.name == "posix"),
                               stdout=subprocess.PIPE if required_output else None,
                               stderr=subprocess.STDOUT if required_output else None,
                               text=True)
    try:
        if required_output:
            output, _ = process.communicate(timeout=seconds)
            print(output, end="", flush=True)
            code = process.returncode
        else:
            code = process.wait(timeout=seconds)
    except subprocess.TimeoutExpired as exc:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait()
        raise RuntimeError(f"TIMEOUT: command exceeded {seconds} s") from exc
    if code != 0:
        raise RuntimeError(f"FAIL: command returned exit code {code}")
    if required_output and required_output not in output:
        raise RuntimeError("FAIL: independent SV test did not report its PASS marker")


def sv_smoke(args):
    # 独立 SV 路径不导入 cocotb，也不需要 Python 第三方依赖。
    simulator = "questa" if args.sim in ("modelsim", "questa") else args.sim
    if simulator not in ("icarus", "questa"):
        raise RuntimeError("SV fallback supports --sim icarus or --sim modelsim")
    build = SIM_DIR / "build" / args.sim / "sv-smoke"
    build.mkdir(parents=True, exist_ok=True)
    _, sources, _, _ = sources_for("infrastructure")
    sources.append(SIM_DIR / "smoke/tb_afdx_infrastructure_smoke.sv")
    if simulator == "icarus":
        require_tools(("iverilog", "vvp"))
        binary = build / "smoke.vvp"
        run_bounded(["iverilog", "-g2012", "-s", "tb_afdx_infrastructure_smoke", "-o", str(binary),
                     *map(str, sources)], build, args.wall_timeout)
        run_bounded(["vvp", str(binary)], build, args.wall_timeout,
                    "PASS: independent AFDX infrastructure smoke")
    else:
        require_tools(("vlib", "vlog", "vsim"))
        run_bounded(["vlib", "work"], build, args.wall_timeout)
        run_bounded(["vlog", "-sv", *map(str, sources)], build, args.wall_timeout)
        run_bounded(["vsim", "-c", "-onfinish", "exit", "work.tb_afdx_infrastructure_smoke",
                     "-do", "onerror {quit -code 1}; onbreak {quit -code 1}; "
                            "run -all; quit -code 0"],
                    build, args.wall_timeout,
                    "PASS: independent AFDX infrastructure smoke")
    print("PASS: independent SV smoke", flush=True)


def model_units(args):
    # Runs without importing cocotb or compiling RTL. sim is the working
    # directory so the reference packages are importable without installation.
    run_bounded([sys.executable, "-m", "unittest", "discover", "-s", "tests",
                 "-p", "test_model_unit.py", "-v"], SIM_DIR, args.wall_timeout,
                required_output="\nOK\n")
    print("PASS: pure Python model unit tests", flush=True)


def run_targets(args, targets):
    for target in targets:
        command = [sys.executable, str(Path(__file__).resolve()), "--worker",
                   "--sim", args.sim, "--target", target]
        if args.waves:
            command.append("--waves")
        if args.test_filter:
            command.extend(("--test-filter", args.test_filter))
        run_bounded(command, ROOT, args.wall_timeout)


def checker_units(args):
    run_bounded([sys.executable, "-m", "unittest", "discover", "-s", "tests",
                 "-p", "test_checker_unit.py", "-v"], SIM_DIR, args.wall_timeout,
                required_output="\nOK\n")
    print("PASS: checker and coverage unit tests", flush=True)


def coverage_report(args):
    from functional_coverage.tx import collect
    report_dir = SIM_DIR / "build" / args.sim / "coverage"
    report = collect([SIM_DIR / "build" / args.sim / target for target in TX_TEST_MODULES], report_dir)
    print(f"TX coverage: {report['hit_bin_count']}/{report['required_bin_count']} ({report_dir})", flush=True)
    if not report["complete"]:
        raise RuntimeError("FAIL: required TX coverage bins or feature cases incomplete")


def regression(args):
    # Continue through every target to retain diagnostics if any feature fails.
    # Failure remains nonzero; no xfail or checker adaptation for DUT defects.
    failures = []
    for unit in (model_units, checker_units):
        try:
            unit(args)
        except RuntimeError as exc:
            failures.append(str(exc))
    for target in ("infrastructure", "tx-mac", "end-system", "tx-reference", *TX_TEST_MODULES):
        try:
            run_targets(args, [target])
        except RuntimeError as exc:
            failures.append(f"{target}: {exc}")
    for check in (sv_smoke, coverage_report):
        try:
            check(args)
        except (RuntimeError, OSError, ValueError) as exc:
            failures.append(str(exc))
    if failures:
        raise RuntimeError("FAIL: complete verification regression\n" + "\n".join(failures))
    print(f"PASS: complete verification regression + SV smoke on {args.sim}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", choices=("modelsim", "questa", "icarus", "verilator", "vcs"),
                        default="icarus")
    parser.add_argument("--target", choices=("infrastructure", "tx-mac", "end-system",
                                            "tx-reference", "legacy-tx", *TX_TEST_MODULES))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--model-unit", action="store_true", help="run pure Python model unit tests")
    mode.add_argument("--checker-unit", action="store_true", help="run pure Python checker/coverage units")
    mode.add_argument("--unit", action="store_true", help="run all pure Python unit tests")
    mode.add_argument("--regression", action="store_true", help="run complete regression, SV smoke and coverage")
    mode.add_argument("--coverage", action="store_true", help="report coverage from existing TX results")
    mode.add_argument("--suite", choices=tuple(TX_SUITES), help="run a functional TX test suite")
    parser.add_argument("--sv-smoke", action="store_true")
    parser.add_argument("--waves", action="store_true")
    parser.add_argument("--test-filter", help="cocotb test name regex for a single --target")
    parser.add_argument("--wall-timeout", type=int, default=180)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.wall_timeout <= 0:
        parser.error("--wall-timeout must be positive")
    if (args.model_unit or args.checker_unit or args.unit or args.regression or args.coverage or args.suite) and (
            args.target or args.sv_smoke or args.worker):
        parser.error("unit/regression/coverage/suite modes cannot be combined with --target/--sv-smoke/--worker")
    if args.test_filter and not args.target:
        parser.error("--test-filter requires a single --target")
    try:
        if args.model_unit:
            model_units(args)
        elif args.unit:
            model_units(args)
            checker_units(args)
        elif args.regression:
            regression(args)
        elif args.checker_unit:
            checker_units(args)
        elif args.coverage:
            coverage_report(args)
        elif args.suite:
            run_targets(args, TX_SUITES[args.suite])
            print(f"PASS: TX {args.suite} suite on {args.sim}", flush=True)
        elif args.sv_smoke:
            sv_smoke(args)
        elif args.worker:
            worker(args)
        else:
            targets = [args.target] if args.target else ["infrastructure", "tx-mac", "end-system"]
            run_targets(args, targets)
            label = ("TX feature regression" if targets[0] in TX_TEST_MODULES else
                     "TX reference smoke" if targets == ["tx-reference"] else "smoke regression")
            print(f"PASS: {label} on {args.sim}", flush=True)
    except (RuntimeError, OSError, SystemExit, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
