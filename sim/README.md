# AFDX ES 验证环境 V1

需求依据为仓库中实际存在的
[`doc/verification/AFDX_Verification_Plan.md`](../doc/verification/AFDX_Verification_Plan.md)。
用户引用的 `docs/verification/` 当前不存在；本次不移动或改写验证计划。

V1 提供事务、应用流 Driver/Monitor、时钟/复位/超时、接口 assertion、
A/B GMII BFM 和 smoke 运行入口，不提供协议 Reference Model 或 Scoreboard。
GMII 完全复用 [cocotbext-eth](https://github.com/alexforencich/cocotbext-eth)
的 `GmiiSource`、`GmiiSink` 和 `GmiiFrame`。

## 文件组织

| 文件 | 用途 |
|---|---|
| `afdx/transactions.py` | 不可变 `AppTransaction`，保存 payload、UDP src/dst、application port、事务 ID |
| `afdx/bfm/app.py` | `AppSource` 驱动流，`AppMonitor` 按实际握手收集完整事务 |
| `afdx/tb.py` | `AfdxTB` 集中创建应用 BFM 和 A/B GMII BFM，支持显式信号映射 |
| `afdx/helpers.py` | 时钟、低/高有效复位和有界异步等待 |
| `afdx/config.py` | 集中保存 `TB_ONLY_DEFAULT` 时钟、复位长度和期限 |
| `afdx/assertions.py` | Python 流接口 checker |
| `fixtures/app_stream_assertions.sv` | 可直接例化的 SV 流接口 assertion |
| `fixtures/afdx_infrastructure_harness.sv` | 真实应用仲裁器和独立 A/B GMII 一拍回环夹具 |
| `tests/test_infrastructure.py` | 公共基础设施 smoke 和异常退出自检 |
| `tests/test_tx_mac_smoke.py` | 可选现有 `AFDX_TX_MAC` 的实际 GMII 输出 smoke |
| `smoke/tb_afdx_v1_smoke.sv` | 无 cocotb 依赖的独立比赛兜底 TB |
| `run.py` | ModelSim/Questa、Icarus、Verilator、VCS 的统一入口 |

## 安装与运行

需要 Python 3.10 或更新版本及 PATH 中的仿真器；依赖固定在 `requirements.txt`。

```sh
python3 -m venv sim/.venv
sim/.venv/bin/python -m pip install -r sim/requirements.txt

# Linux：同一套 cocotb tests，默认依次运行两个目标。
sim/.venv/bin/python sim/run.py --sim icarus
sim/.venv/bin/python sim/run.py --sim verilator  # 需要 Verilator >= 5.036

# 团队 Golden Simulator：vlib、vlog、vsim 必须在 PATH 中。
sim/.venv/bin/python sim/run.py --sim modelsim

# 单独运行公共夹具，或独立查看可选 TX MAC。
sim/.venv/bin/python sim/run.py --sim icarus --target infrastructure
sim/.venv/bin/python sim/run.py --sim icarus --target tx-mac

# 不依赖 cocotb 或 cocotbext-eth 的 SV 兜底。
python3 sim/run.py --sim icarus --sv-smoke
python3 sim/run.py --sim modelsim --sv-smoke

# 当前指定旧 TX 的编译诊断；当前预期报告编译失败。
sim/.venv/bin/python sim/run.py --sim icarus --target legacy-tx
```

Windows 使用虚拟环境中的 `sim\.venv\Scripts\python.exe` 调用同一个 `sim/run.py`。
ModelSim 路径使用 cocotb 2.0.1 的 Questa runner（`vlib/vlog/vsim`）和 Verilog VPI，
开启 `-voptargs=+acc` 保留接口可见性；Python 与仿真器须使用匹配的进程位宽。
此路线依据 [cocotb 仿真器支持文档](https://docs.cocotb.org/en/v2.0.0/simulator_support.html)。
VCS 入口为 `--sim vcs`，本机暂未运行该目标。

`--waves` 可开启波形，`--wall-timeout 180` 指定每个目标的墙钟期限。
生成物在 `sim/build/<simulator>/<target>/`，包含 cocotb `results.xml`；构建目录和
虚拟环境由 `sim/.gitignore` 排除。运行不创建 Git 提交。

## 应用接口契约

`AppTransaction(payload, src_udp, dst_udp, application_port, transaction_id="")`
只表示一条字节流，不解释 SNMP、TFTP 或 RTC。空载荷无法形成末字节握手，
因此立即拒绝；src/dst 检查 16 位，application port 检查 8 位。
1471 B 等长度只作为 smoke 向量，不给通用 Driver 设置协议长度上限。

```python
transaction = AppTransaction(b"\x01\x02", 40000, 161, 3, "smoke-0")
await tb.send_app(transaction, gap_cycles=0)
accepted = await tb.recv_app()
```

Driver 在下降沿驱动，使用上升沿 `valid && ready` 判断接收，只有完成握手才推进字节；
`last` 与最后一个字节同时有效。首、中、末字节遇到反压均保持数据和元信息。
`gap_cycles` 在已接收字节间插入 valid 空拍；并发 `send` 调用通过锁串行化。
复位中发送被拒绝；发送中复位终止事务，后续不继续发送旧数据。
超时后未接收的字节仍保持有效，调用方须复位后再开始新事务。

Python 与 SV assertion 检查：有效控制/数据无 X/Z、last 伴随 valid、
反压保持 valid/data/last/metadata、整包 metadata 不变。
Python 中 X/Z 转整数失败也会直接使测试失败。

`AfdxTB` 默认绑定 `app_*` 和 `gmii_*` 接口；不同 DUT 用 `app_names`、
`gmii_names`、`clock_name`、`reset_name`、`reset_active_level` 显式适配。
缺少信号或位宽不符立即失败。`gmii_names={}` 可禁用网络 BFM，供应用级测试使用。
未来 RX ready 未冻结，当前没有通过假造 ready 将真实 RX 接到 APP。

## 测试及结果判定

| 测试 | 自动检查 |
|---|---|
| `app_stream_smoke` | 1/4/16/64/484/516/1471 B，三类 application port，元信息，反压，valid 空拍，真实仲裁输出 |
| `gmii_ab_loopback_smoke` | 两个第三方 RX Source 并发注入，两个 TX Sink 捕获，比较 SFD 后原始字节，单网后续帧与隔离 |
| `reset_and_timeout_smoke` | 永久反压超时、在途复位中止、复位后恢复、缺失 GMII 帧超时 |
| `assertion_and_transaction_guards` | 非法事务拒绝和 assertion 失败路径 |
| `tx_mac_app_to_ab_gmii` | 接收三条应用事务，A/B 各捕获三个真实 TX MAC 帧，无 TX_ER |
| 独立 SV smoke | 首/末字节反压、四个字节及元信息、A/B 回环连线 |

每项 cocotb 测试有仿真时间上限；公共操作另有有界等待。
runner 对编译、许可证等待和仿真设置墙钟上限，POSIX 超时会终止整个进程组。
缺少工具、编译失败、异常、超时、XML 缺失、零测试、失败或跳过测试均返回非零。
SV 路径同时要求成功退出和 TB 的 PASS 标记，不能把无测试输出当作通过。

回环比较仅是 BFM 连通性检查；由第三方 BFM 生成 FCS，不执行独立 CRC checker。
`GmiiSink` 对前导码的采样行为由第三方库定义，因此回环比较使用库提供的
`get_payload(strip_fcs=False)`，不将本测试当作前导码/SFD 协议验收。
实际 TX smoke 仅检查收帧和接口，不解码或比较 Ethernet/IP/UDP/AFDX 字段。

## 当前阻塞和验证边界

1. 团队指定的旧 `AFDX_TX.v` 第 24 行多余 `+` 仍导致编译失败。
   文件内部还有未完成内容；其 GMII 输出与整包 last 联调尚不能验收。
   `legacy-tx` 入口保留该阻塞的可重复诊断，不修改下层 RTL。
2. `AFDX_End_System_top.v` 没有实例化实际收发链路，`rtl/afdx_rx` 为空。
   真实 GMII RX → UDP Payload → APP 的适配和缓存/ready 契约尚未提供。
   RX 注入通过夹具验证，不能宣称真实 RX 已处理帧。
3. 默认第二个目标是已有的 **可选 `AFDX_TX_MAC`**，不是将其宣布为团队指定的旧 TX 替代品。
   它的 RX 引脚是兼容占位，不实现接收协议；GMII 时钟沿用其实际 `p0_rxc` 输入。
   `rtl/afdx_mac_rx.v` 和 `rtl/afdx_mac_tx.v` 的另一套宽 AXI 接口也不是 GMII 边界，
   V1 不新增 MAC/PCS 或协议适配 RTL。
4. 本机没有 `vlib/vlog/vsim`，ModelSim 入口已提供但运行验收被工具缺失阻塞。
   不能将 Linux PASS 写成 Golden Simulator PASS。
5. 本机 Verilator 为 5.008，与固定的 cocotb 2.0.1 不兼容，构建缺少
   `VerilatedVpi::evalNeeded/doInertialPuts`；入口提前报告版本阻塞。
   [cocotb 2.0 官方要求 Verilator 5.036 或更新版本](https://docs.cocotb.org/en/v2.0.0/simulator_support.html#verilator)。
   Linux 实际验收采用已通过的 Icarus 11.0，没有为此改装系统仿真器。

所有测试配置均为 `TB_ONLY_DEFAULT`，未冻结 Port/VL/IP/MAC/BAG、RX 契约或系统时钟。
本阶段没有实现协议模型、packet decoder、CRC/IP checksum checker、BAG/jitter、
SN/VL checker、应用 peer、完整 fault injection、functional coverage 或完整 scoreboard。
