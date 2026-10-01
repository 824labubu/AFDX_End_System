#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/afdx-app-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
rtl_sources=(rtl/app/app_tx_arbiter.v rtl/app/app_rtc_sync.v
    rtl/app/app_tftp_615a.v rtl/app/app_snmp_agent.v
    rtl/app/app_snmp_oid_lookup.v rtl/app/app_layer_top.v)
for test in app_tx_arbiter app_rtc_sync app_tftp_615a app_snmp_agent app_layer_top; do
    iverilog -g2012 -s "tb_${test}" -o "$build_dir/$test" \
        "sim/app/tb_${test}.v" "${rtl_sources[@]}"
    timeout 30s vvp "$build_dir/$test"
done
printf '%s\n' 'PASS: application RTL regression'
