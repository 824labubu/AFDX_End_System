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
    if target == "end-system":
        return "AFDX_End_System_top", [
            LEGACY_DIR / "AFDX_End_System_top.v",
            LEGACY_DIR / "AFDX_TX_MAC.v",
            LEGACY_DIR / "afdx_mac_tx.v",
            LEGACY_DIR / "afdx_gmii_tx.v",
        ], "test_end_system_top", {"BAG_CYCLES": 16}  # TB_ONLY_DEFAULT
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
    runner = get_runner(simulator)
    build_args = ["-Wno-fatal"] if simulator == "verilator" else []
    runner.build(sources=sources, hdl_toplevel=top, parameters=parameters,
                 build_dir=build, always=True, waves=args.waves, build_args=build_args)
    if test_module is None:
        raise RuntimeError("BLOCKED: legacy TX has no complete V1 binding; this is a compile probe")
    results = build / "results.xml"
    results.unlink(missing_ok=True)
    python_path = os.pathsep.join(filter(None, (
        str(SIM_DIR), str(SIM_DIR / "tests"), os.environ.get("PYTHONPATH", ""),
    )))
    # 显式选择 VPI，使 Verilog 验证不依赖 ModelSim 的 VHDL FLI 支持。
    test_args = ["-voptargs=+acc"] if simulator == "questa" else []
    runner.test(hdl_toplevel=top, test_module=test_module, build_dir=build,
                test_dir=build, results_xml=str(results), waves=args.waves,
                parameters=parameters, gpi_interfaces=["vpi"], test_args=test_args,
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
    sources.append(SIM_DIR / "smoke/tb_afdx_v1_smoke.sv")
    if simulator == "icarus":
        require_tools(("iverilog", "vvp"))
        binary = build / "smoke.vvp"
        run_bounded(["iverilog", "-g2012", "-s", "tb_afdx_v1_smoke", "-o", str(binary),
                     *map(str, sources)], build, args.wall_timeout)
        run_bounded(["vvp", str(binary)], build, args.wall_timeout,
                    "PASS: independent AFDX V1 infrastructure smoke")
    else:
        require_tools(("vlib", "vlog", "vsim"))
        run_bounded(["vlib", "work"], build, args.wall_timeout)
        run_bounded(["vlog", "-sv", *map(str, sources)], build, args.wall_timeout)
        run_bounded(["vsim", "-c", "-onfinish", "exit", "work.tb_afdx_v1_smoke",
                     "-do", "onerror {quit -code 1}; onbreak {quit -code 1}; "
                            "run -all; quit -code 0"],
                    build, args.wall_timeout,
                    "PASS: independent AFDX V1 infrastructure smoke")
    print("PASS: independent SV smoke", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", choices=("modelsim", "questa", "icarus", "verilator", "vcs"),
                        default="icarus")
    parser.add_argument("--target", choices=("infrastructure", "tx-mac", "end-system", "legacy-tx"))
    parser.add_argument("--sv-smoke", action="store_true")
    parser.add_argument("--waves", action="store_true")
    parser.add_argument("--wall-timeout", type=int, default=180)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.wall_timeout <= 0:
        parser.error("--wall-timeout must be positive")
    try:
        if args.sv_smoke:
            sv_smoke(args)
        elif args.worker:
            worker(args)
        else:
            targets = [args.target] if args.target else ["infrastructure", "tx-mac", "end-system"]
            for target in targets:
                command = [sys.executable, str(Path(__file__).resolve()), "--worker",
                           "--sim", args.sim, "--target", target]
                if args.waves:
                    command.append("--waves")
                run_bounded(command, ROOT, args.wall_timeout)
            print(f"PASS: V1 smoke regression on {args.sim}", flush=True)
    except (RuntimeError, OSError, SystemExit, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
