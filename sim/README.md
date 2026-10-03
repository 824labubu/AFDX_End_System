# AFDX ES 验证环境

需求依据为仓库中实际存在的
[`doc/verification/AFDX_Verification_Plan.md`](../doc/verification/AFDX_Verification_Plan.md)。
用户引用的 `docs/verification/` 当前不存在；计划保留在 `doc/verification/`，按功能维护TX基线及traceability。

公共基础设施提供事务、应用流 Driver/Monitor、时钟/复位/超时、接口 assertion、
A/B GMII BFM 和 smoke 运行入口；协议检查由独立 Reference Model、Decoder 和 Scoreboard完成。
GMII 完全复用 [cocotbext-eth](https://github.com/alexforencich/cocotbext-eth)
的 `GmiiSource`、`GmiiSink` 和 `GmiiFrame`。

2026-10-03 新增统一 DUT：`AFDX_End_System_top`，应用侧为对称的
`app_tx_*` / `app_rx_*`，网络侧为双路 `gmii_*`。实际TX已连接，RX暂时保持空闲。
接口说明见 [统一DUT接口](../doc/AFDX_End_System_Top_Interface.md)。
`--target end-system` 运行此顶层，不把下面的基础设施回环当作真实RX。

## TX Reference 验证

独立 TX Reference Model、Packet Decoder 和 Basic Scoreboard通过公开应用流及GMII，
检查当前 `AFDX_End_System_top`。状态与Feature追踪见 [STATUS.md](STATUS.md)。
RX保持stub。

```sh
# 无仿真器/第三方Python依赖的模型单元测试。
python3 sim/run.py --model-unit
# 也可直接运行纯Python测试。
PYTHONPATH=sim python3 -m unittest discover -s sim/tests -p test_model_unit.py -v

# 仅运行4类DUT-vs-Reference测试。
sim/.venv/bin/python sim/run.py --sim icarus --target tx-reference

# 完整入口：unit tests、基础设施、TX Reference、TX Features、SV smoke和coverage。
sim/.venv/bin/python sim/run.py --sim icarus --regression
```

模型与checker使用标准库；仿真继续使用 `AppTransaction`、`AppSource/AppMonitor`、
`AfdxTB`、cocotb和cocotbext-eth。默认不带`--regression`时运行基础设施、TX MAC及顶层smoke目标。
其他仿真器沿用`--target tx-reference`入口；本机验收为Icarus，不能据此声明ModelSim通过。

### 模型、解析器与比较器

```text
AppTransaction + TxModelConfig + ReferenceState
  → AfdxTxReferenceModel.build() → expected A / expected B

AFDX_End_System_top → GmiiSink → get_payload(strip_fcs=False)
  → decode_tx_frame() → actual fields

TxScoreboard → 字段比较 + 原始字节比较 + 独立实际帧CRC/IP checksum检查
```

- `model/checksums.py`：独立CRC32与Internet/IPv4 checksum。
- `model/builders.py`：UDP、IPv4、Ethernet分层编码。
- `model/config.py`：集中配置，禁止从DUT或RTL推导expected。
- `model/tx_reference.py`：按VL维护模型自己的SN，一条逻辑帧分配一次，分别编码A/B及FCS。
- `decoder/tx_frame_decoder.py`：原始帧解析，无协议正确性assert；只检查可安全解析的字段边界。
- `scoreboard/tx_scoreboard.py`：每网络FIFO匹配，检测字段不符、缺帧、多帧、错误顺序和TX_ER。
- `tests/test_model_unit.py`：标准库unittest，无RTL或cocotb依赖；含独立字节样本和比较器失败路径自检。
- `tests/test_tx_reference_smoke.py`：普通/1 B/1471 B/同VL连续两帧，共四项系统用例。

CRC使用`binascii.crc32`参考实现，验证`123456789 → CBF43926`，没有复制RTL逐位CRC循环。
数值CRC采用CRC-32/ISO-HDLC的反射约定，FCS四字节按little-endian追加。
IPv4校验和先清零首部checksum字段，再计算16-bit one's-complement；
检查已填首部使用`internet_checksum(header)==0`。参考来源：
[Python binascii文档](https://docs.python.org/3/library/binascii.html)、
[RFC 1071](https://www.rfc-editor.org/rfc/rfc1071.html)、
[RFC 791](https://www.rfc-editor.org/rfc/rfc791.html)、
[RFC 768](https://www.rfc-editor.org/rfc/rfc768.html)。

模型/解析器之间共享结构类型，原始完整帧字节也必须匹配；单元测试另有独立固定编码样本，
避免仅靠builder/decoder互相round-trip就判定正确。
解析器可读取IHL定位UDP，不实现分片/重组；当前参考profile固定IPv4 IHL=5、未分片UDP。

### 测试配置与帧边界

`TB_ONLY_DEFAULT_MODEL_CONFIG`为测试配置，不冻结正式设备ICD或声明完整规范合规：

| 配置 | 测试值 |
|---|---|
| application port → VL | 1..5 → 1..5，显式路由表 |
| 源IPv4 | 表中10.1.1.1..5 |
| 目的IPv4 | port 1为244.244.0.1；其余为10.1.2.2..5 |
| DA | 各路由表中03:00:00:00:00:01..05，A/B分别配置 |
| SA A/B | 02:00:00:01:01:20 / 02:00:00:01:01:40 |
| IPv4 | TOS=0、ID=0、DF=1、TTL=1、protocol=UDP |
| UDP checksum策略 | 显式配置`zero`，不实现其他策略 |
| Payload/帧上限 | 1471 B / 1518 B（DA到FCS） |
| 最小长度/Pad | 60 B不含FCS；Pad=AA |
| SN | 当前项目profile首帧1，255后回到1，按VL独立；不是完整规范复位行为的验收声明 |

固定配置来自当前接口文档/项目配置基线，集中记录，不读RTL生成配置。
若地址或SN规则后续冻结为其他值，应独立更新配置与规范记录，不依据Actual Frame自动学习。

Reference输出及Decoder输入均为`DA..FCS`。
固定版cocotbext-eth的`get_payload(strip_fcs=False)`基于SFD位置剥离前导码/SFD并保留FCS，
不调用BFM的`check_fcs()`作为验收判据。SN是FCS前一字节，Pad位于IP数据结束与SN之间。
UDP长度决定应用payload，IP长度决定Ethernet Pad边界，两者不一致不会被解析器自动修正。
`tx-reference`目标检查DA..FCS；线上前导码和IFG由TX feature tests检查。
测试末尾的有限额外帧观察窗口不是BAG/IFG checker。

### 失败诊断与产物

`sim/build/<simulator>/tx-reference/results.xml`给出四项cocotb结果。
每个用例另有`<test_name>.scoreboard.json`，包含expected/observed/matched/pending计数、
每次比较的原始expected/actual帧和field-level mismatch。
诊断包含test name、transaction ID、协议、A/B、时间(ns)、帧长、首个差异字节和值。
缺帧有有界timeout，多帧和顺序错误由网络队列检测。

示例失败格式：

```text
TX FRAME MISMATCH
test=... transaction=... network=A timestamp_ns=...
protocol=Ethernet/IPv4/UDP/AFDX expected_length=64 actual_length=64
field                    expected                           actual
udp_length               0x18 (24)                          0x19 (25)
...
first_difference: byte_offset=39 expected=0x18 (24) actual=0x19 (25)
```

DUT mismatch首先保持测试失败，保存JSON与日志，再按DUT/model/config分类定位；
不能改Reference去匹配观察到的错误输出。不修改协议RTL，不扩展RX、应用peer、
BAG/jitter、复杂调度器、完整fault injection或coverage closure。

## TX Feature 验证

当前范围与结果见 [STATUS.md](STATUS.md)。
统一DUT为`AFDX_End_System_top`，共享应用/GMII BFM、协议模型、decoder和scoreboard。
执行TX-F01～F06、TX-F08～F11、RED-F01/02，**TX-F07 = REMOVED**。

```sh
# 完整验收：所有units、smoke、TX Reference、TX Features、SV smoke及coverage。
sim/.venv/bin/python sim/run.py --sim icarus --regression

# 按功能运行test suite。
sim/.venv/bin/python sim/run.py --sim icarus --suite payload
sim/.venv/bin/python sim/run.py --sim icarus --suite headers
sim/.venv/bin/python sim/run.py --sim icarus --suite sequence
sim/.venv/bin/python sim/run.py --sim icarus --suite ethernet
sim/.venv/bin/python sim/run.py --sim icarus --suite redundancy
sim/.venv/bin/python sim/run.py --sim icarus --suite tx  # 全部TX feature tests

# 纯Python单元测试，无cocotb/仿真器依赖。
python3 sim/run.py --unit
python3 sim/run.py --model-unit
python3 sim/run.py --checker-unit

# 从现有TX artifacts汇总coverage；完整验收重新运行--regression。
python3 sim/run.py --sim icarus --coverage

# 单目标及单case最小复现。
sim/.venv/bin/python sim/run.py --sim icarus --target tx-sequence
sim/.venv/bin/python sim/run.py --sim icarus --target tx-sequence --test-filter 'test_tx_f06_sequence_wrap_255_to_1$'
```

`--test-filter`要求单独`--target`。筛选运行会重新生成该目标的XML/JSON，不能代替完整验收。
`--suite`运行对应DUT功能测试；`--unit`运行纯Python模型/checker/coverage自检。
默认smoke入口保留。ModelSim可用相同入口，但本机Golden状态为PENDING。
运行不创建Git提交。

| Target | Feature IDs | 文件/用例数 |
|---|---|---|
| `tx-payload` | TX-F01 | `tests/tx/test_tx_payload.py`，4项 |
| `tx-boundary` | TX-F01/02 | `tests/tx/test_tx_boundary.py`，3项 |
| `tx-headers` | TX-F03/04/05 | `tests/tx/test_tx_headers.py`，3项 |
| `tx-sequence` | TX-F06 | `tests/tx/test_tx_sequence.py`，3项 |
| `tx-padding` | TX-F08 | `tests/tx/test_tx_padding.py`，1项 |
| `tx-fcs` | TX-F09 | `tests/tx/test_tx_fcs.py`，1项 |
| `tx-timing` | TX-F10/11 | `tests/tx/test_tx_timing.py`，2项 |
| `tx-redundancy` | RED-F01/02 | `tests/tx/test_tx_redundancy.py`，2项 |

### 流量、边界与时序定义

- 载荷实际覆盖1/2/16/64/483/484/485/515/516/517/1471 B；Padding另覆盖16/17/18 B边界。
- 0 B由现有`AppTransaction`接口拒绝，验证无虚构last握手及后续恢复；不声称发送了零长度DUT帧。
- 1472 B依接口文档检查输入被消费后整包丢弃，在1600个系统周期的有限窗口内无帧，随后合法包恢复且SN不错误递增。
- Ready仅由DUT驱动。前包使发送器忙碌时立即调用下一次发送，观察实际首字节反压；下一条1-byte消息同时覆盖last反压。
- Back-to-back表示调用方不插入等待，保留AppSource自身的cleanup空拍；不是声称DUT可以无停顿连续接受整包。
- `AppMonitor`继续检查`valid && ready && last`边界及反压期间data/last/port/UDP元数据稳定；`ApplicationFlowObserver`只记录实际流量。
- Wrap通过256条真实应用消息覆盖1..255→1，不force内部SN；reset同时重置DUT与ReferenceState。
- `GmiiWireObserver`在各路公开TX clock上升沿ReadOnly阶段记录前8字节、TX_EN帧长和起止周期，不替代`GmiiSink`。
- 前导码检查线上`55`×7 + `D5`，不依据第三方库裁剪后的字节数推断。
- IFG定义为上一帧最后一个TX_EN=1采样与下一帧首个TX_EN=1采样之间的低使能周期数：`next_start_cycle - previous_end_cycle - 1 >= 12`。
  单位是各路GMII字节周期，当前TB_ONLY_DEFAULT时钟为8 ns；首帧及reset之前/之后之间不配对。
  当前单缓存发送器实际gap大于12，此测试检查忙碌输入下的最小间隔规则，不证明恰好12周期的吞吐率。
- IFG仅为MAC timing检查，**没有**BAG start-to-start checker、jitter model或BAG coverage。
- A/B各自由独立配置生成完整expected并检查FCS；另外比较IP/UDP/payload/SN语义，允许配置的MAC/FCS差异，不要求同时开始。

### 诊断与Functional Coverage

每个目标产物位于`sim/build/<simulator>/tx-*/`：

- `results.xml`：cocotb自动结果，失败/跳过/零测试均使runner非零退出。
- `<test_name>.scoreboard.json`：复用字段和完整字节诊断，test name包含Feature ID。
- `<test_name>.case.json`：Feature IDs、PASS/FAIL及failure文本、实际应用流事件、匹配后的帧字段和GMII观察记录。

字段错误由Scoreboard输出：Feature ID、transaction ID、A/B、field、expected/actual、首差异offset。
前导码错误额外定位prefix byte offset；IFG错误包含previous_end/next_start、observed/required GMII周期。
完整入口在某一目标失败后继续收集其余目标结果，最终保持非零退出，不把DUT defect转成xfail或跳过。

轻量收集器为`functional_coverage/tx.py`，结果位于：

```text
sim/build/<simulator>/coverage/functional_coverage.json
sim/build/<simulator>/coverage/functional_coverage.txt
```

报告提供每bin计数、最多5条证据、缺失bins、失败cases及TX-F07 REMOVED标记。
只有XML和Scoreboard通过的case计入覆盖，缺帧/失败不关闭bins；coverage不替代checker。
必需87个bins覆盖feature、payload、每port/VL、flow、SN、padding、A/B和GMII，以及有限交叉：
关键payload×实际backpressure、每port/VL×increment/reset、padding×payload、network×FCS。
另有16/17/18、483/484/485、515/516/517的精确邻域bins，不要求完整笛卡尔积。

已知DUT defect应保留稳定最小用例与JSON，在`STATUS.md`标记`BLOCKED_BY_DUT_DEFECT`；
不通过修改expected适配实际错误。当前功能验收完成后停止，不进入RX、E2E、fault campaign或完整BAG/jitter。

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
| `tests/test_end_system_top.py` | 统一顶层的真实TX数据/UDP端口/SN/FCS和RX预留空闲/复位检查 |
| `smoke/tb_afdx_infrastructure_smoke.sv` | 无 cocotb 依赖的独立比赛兜底 TB |
| `run.py` | ModelSim/Questa、Icarus、Verilator、VCS 的统一入口 |

## 安装与运行

需要 Python 3.10 或更新版本及 PATH 中的仿真器；依赖固定在 `requirements.txt`。

```sh
python3 -m venv sim/.venv
sim/.venv/bin/python -m pip install -r sim/requirements.txt

# Linux：默认依次运行 infrastructure、tx-mac、end-system 三个目标。
sim/.venv/bin/python sim/run.py --sim icarus
sim/.venv/bin/python sim/run.py --sim verilator  # 需要 Verilator >= 5.036

# 团队 Golden Simulator：vlib、vlog、vsim 必须在 PATH 中。
sim/.venv/bin/python sim/run.py --sim modelsim

# 单独运行公共夹具，或独立查看可选 TX MAC。
sim/.venv/bin/python sim/run.py --sim icarus --target infrastructure
sim/.venv/bin/python sim/run.py --sim icarus --target tx-mac
sim/.venv/bin/python sim/run.py --sim icarus --target end-system

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
统一顶层用 `END_SYSTEM_TX`、`END_SYSTEM_RX`、`END_SYSTEM_GMII` 映射；
通过 `rx_names=END_SYSTEM_RX` 绑定可选RX monitor，使用者驱动 `app_rx_ready`。
`recv_app()` 收集已接受TX输入；`recv_app_rx()` 等待RX输出，当前RX未实现时会超时。

## 测试及结果判定

| 测试 | 自动检查 |
|---|---|
| `app_stream_smoke` | 1/4/16/64/484/516/1471 B，三类 application port，元信息，反压，valid 空拍，真实仲裁输出 |
| `gmii_ab_loopback_smoke` | 两个第三方 RX Source 并发注入，两个 TX Sink 捕获，比较 SFD 后原始字节，单网后续帧与隔离 |
| `reset_and_timeout_smoke` | 永久反压超时、在途复位中止、复位后恢复、缺失 GMII 帧超时 |
| `assertion_and_transaction_guards` | 非法事务拒绝和 assertion 失败路径 |
| `tx_mac_app_to_ab_gmii` | 接收三条应用事务，A/B 各捕获三个真实 TX MAC 帧，无 TX_ER |
| `application_tx_to_ab_gmii` | 统一顶层TX至双网，UDP元信息、载荷、SN、长度、CRC和上游反压 |
| `rx_reserved_idle_and_reset` | RX预留端口绑定，GMII注入仍无应用事务，双向接口/PHY复位 |
| 独立 SV smoke | 首/末字节反压、四个字节及元信息、A/B 回环连线 |

每项 cocotb 测试有仿真时间上限；公共操作另有有界等待。
runner 对编译、许可证等待和仿真设置墙钟上限，POSIX 超时会终止整个进程组。
缺少工具、编译失败、异常、超时、XML 缺失、零测试、失败或跳过测试均返回非零。
SV 路径同时要求成功退出和 TB 的 PASS 标记，不能把无测试输出当作通过。

回环比较仅是 BFM 连通性检查；由第三方 BFM 生成 FCS，不执行独立 CRC checker。
`GmiiSink` 对前导码的采样行为由第三方库定义，因此回环比较使用库提供的
`get_payload(strip_fcs=False)`，不将本测试当作前导码/SFD 协议验收。
旧 `tx-mac` smoke仅检查收帧和接口；`end-system`含少量定向字段检查，
独立模型、Decoder、Scoreboard检查使用`tx-reference`目标。

## 当前阻塞和验证边界

1. 团队指定的旧 `AFDX_TX.v` 第 24 行多余 `+` 仍导致编译失败。
   文件内部还有未完成内容；其 GMII 输出与整包 last 联调尚不能验收。
   `legacy-tx` 入口保留该阻塞的可重复诊断，不修改下层 RTL。
2. `AFDX_End_System_top.v` 已连接实际TX，`rtl/afdx_rx` 仍为空。
   顶层RX应用流ready契约已定义，但真实 GMII RX → UDP Payload → APP
   的解码、缓存与应用适配尚未实现。RX预留空闲检查不能证明处理了帧。
3. 默认第二个目标是已有的 **可选 `AFDX_TX_MAC`**，不是将其宣布为团队指定的旧 TX 替代品。
   它的 RX 引脚是兼容占位，不实现接收协议；GMII 时钟沿用其实际 `p0_rxc` 输入。
   `rtl/afdx_mac_rx.v` 和 `rtl/afdx_mac_tx.v` 的另一套宽 AXI 接口也不是 GMII 边界，
    不新增 MAC/PCS 或协议适配 RTL。
4. 本机没有 `vlib/vlog/vsim`，ModelSim 入口已提供但运行验收被工具缺失阻塞。
   不能将 Linux PASS 写成 Golden Simulator PASS。
5. 本机 Verilator 为 5.008，与固定的 cocotb 2.0.1 不兼容，构建缺少
   `VerilatedVpi::evalNeeded/doInertialPuts`；入口提前报告版本阻塞。
   [cocotb 2.0 官方要求 Verilator 5.036 或更新版本](https://docs.cocotb.org/en/v2.0.0/simulator_support.html#verilator)。
   Linux 实际验收采用已通过的 Icarus 11.0，没有为此改装系统仿真器。

所有测试数值配置均为 `TB_ONLY_DEFAULT`，未冻结正式Port/VL/IP/MAC/BAG或系统时钟。
统一顶层TX/RX流接口契约已定义，真实RX实现仍待完成。
已提供基本TX Reference Model、packet decoder、CRC/IP checksum及字段Scoreboard；
已完成当前TX profile的SN/VL、GMII时序、双网feature回归及轻量functional coverage。
仍未实现完整BAG/jitter、应用peer、RX、完整fault injection或完整系统scoreboard。
