# AFDX 验证环境 V2 执行结果

日期：2026-10-03。当前分支：`app_dev`；执行基线提交：`cb93f3e`，加本次sim验证环境改动。
执行依据：根目录 `AFDX_Verification_V2_Execution_Guide.md`。
验证计划实际位于 `doc/verification/AFDX_Verification_Plan.md`；用户引用的`docs/verification/`不存在，未移动或修改计划。
接口依据：`doc/AFDX_End_System_Top_Interface.md`。

**V2 Exit Criteria全部满足，停止扩展。** 当前验收仅覆盖独立TX检查基础设施与四类基础系统用例。
RX仍为stub；未修改协议RTL、顶层RTL或eLinx配置，未实现BAG/jitter checker。

## 1. Phase A → H执行记录

每阶段先通过其纯Python单元测试，再进入依赖阶段。以下unit数量为该阶段的累计数量。

| Phase | 交付 | 结果 |
|---|---|---|
| A | CRC32及Internet/IPv4 checksum | 4项unit PASS；固定CRC和首部向量，RFC1071数值例 |
| B | Packet Decoder | 累计8项unit PASS；固定字节样本，保留错误字段，结构边界检查 |
| C | UDP/IPv4/Ethernet Builders | 累计13项unit PASS；独立literal编码及decoder round-trip |
| D | TX Reference Model与ReferenceState | 累计18项unit PASS；按VL而非应用端口计数、连续递增、255→1、复位 |
| E | A/B分别生成expected | 累计20项unit PASS；独立DA/SA/FCS，一条逻辑帧只分配一次SN |
| F | Basic Scoreboard | 累计27项unit PASS；字段/字节差异与错误计数、缺帧、多帧、顺序错误诊断 |
| G | 四类统一DUT-vs-Reference用例 | 4项cocotb PASS，5条应用事务、10个A/B帧全部匹配 |
| H | 完整V1可运行基线回归 | 7项cocotb PASS；独立SV smoke PASS；总入口退出码0 |

最后一次完整执行：

```sh
sim/.venv/bin/python sim/run.py --sim icarus --v2
```

运行环境：Icarus 11.0、cocotb 2.0.1、cocotbext-eth 0.1.26。
纯Python unit测试使用标准库unittest，不要求仿真器、cocotb或Scapy。
没有新增安装依赖。

## 2. Exit Criteria逐项验收

| 编号 | 要求 | 状态 | 证据 |
|---|---|---|---|
| 1 | 捕获帧可解析为结构化Ethernet/IPv4/UDP/AFDX对象 | PASS | `DecodedTxFrame`及实际DUT四类帧 |
| 2 | 独立Ethernet CRC32通过unit | PASS | `123456789 → CBF43926`，FCS线上字节`26 39 F4 CB`，literal帧 |
| 3 | 独立IPv4 checksum通过unit | PASS | 固定首部`B861`、RFC1071示例、清零生成与已填首部验证 |
| 4 | 从AppTransaction生成完整Expected TX Frame | PASS | 三层builder组合，DA至FCS完整字节和结构字段 |
| 5 | 每VL独立SN | PASS | 不同VL递增、两个应用端口共用VL的unit，不读取DUT状态 |
| 6 | A/B分别生成Expected Frame | PASS | A/B配置独立，分别计算FCS，SN共享 |
| 7 | Scoreboard输出field-level mismatch | PASS | 合成错误unit验证UDP length、payload、checksum/FCS、首差异字节及上下文 |
| 8 | 普通payload DUT vs Reference | PASS | `tx_reference_normal_payload`，16 B，port/VL 3，A/B各1帧 |
| 9 | 1-byte payload | PASS | `tx_reference_one_byte`，port/VL 4，A/B各1帧 |
| 10 | 1471-byte payload | PASS | `tx_reference_maximum_payload`，port/VL 5，A/B各1帧 |
| 11 | 连续两帧SN递增 | PASS | `tx_reference_two_consecutive_frames`，port/VL 3，两帧SN分别1、2，A/B各2帧 |
| 12 | V1 regression保持PASS | PASS | infrastructure 4项、tx-mac 1项、end-system 2项、独立SV smoke |

纯Python开发阶段和最终验收均先于/独立于DUT期望值比较。
失败路径unit是checker自检，不是向RTL扩展完整fault injection。

## 3. 产物与复现

| 文件 | 用途 |
|---|---|
| `model/checksums.py` | 标准库CRC参考、Internet/IPv4 checksum |
| `model/builders.py` | Layer-local UDP/IPv4/Ethernet编码 |
| `model/config.py` | 显式、只读的TB_ONLY_DEFAULT地址/端口/VL/长度/校验和/SN配置 |
| `model/tx_reference.py` | ExpectedTxFrame、ReferenceState、AfdxTxReferenceModel |
| `decoder/tx_frame_decoder.py` | 字节解析；无协议正确性assert |
| `scoreboard/tx_scoreboard.py` | 字段比较、实际帧校验和校验、网络队列及JSON诊断 |
| `tests/test_model_unit.py` | 27项纯Pythonunit |
| `tests/test_tx_reference_smoke.py` | 4项真实统一DUT检查 |
| `run.py` / `README.md` | model-unit / tx-reference / v2运行入口及说明 |

分别复现：

```sh
python3 sim/run.py --model-unit
sim/.venv/bin/python sim/run.py --sim icarus --target tx-reference
sim/.venv/bin/python sim/run.py --sim icarus
python3 sim/run.py --sim icarus --sv-smoke
```

永久产物由运行入口写入被Git忽略的`sim/build/`：

```text
sim/build/icarus/tx-reference/results.xml
sim/build/icarus/tx-reference/tx_reference_normal_payload.scoreboard.json
sim/build/icarus/tx-reference/tx_reference_one_byte.scoreboard.json
sim/build/icarus/tx-reference/tx_reference_maximum_payload.scoreboard.json
sim/build/icarus/tx-reference/tx_reference_two_consecutive_frames.scoreboard.json
sim/build/icarus/infrastructure/results.xml
sim/build/icarus/tx-mac/results.xml
sim/build/icarus/end-system/results.xml
sim/build/icarus/sv-smoke/smoke.vvp
```

JSON同时保存成功/失败比较：test、transaction ID、协议、network、观察时间(ns)、
expected/actual长度、字段差异、首差异offset和值以及完整expected/actual十六进制字节。
所有本次DUT JSON的`mismatch_count=0`、`pending={a:0,b:0}`，expected/observed/matched计数一致。
四个结果XML均检查无failure/error/skipped，不能只依据屏幕最后一行判断通过。
临时完整运行日志：`/tmp/afdx_v2_exit_regression.log`，/tmp清理后可按命令重建。

## 4. 独立性与配置假设

- 模型仅接受`AppTransaction + TxModelConfig + ReferenceState`，不接受DUT句柄或RTL路径。
- CRC使用`binascii.crc32`，不是翻译DUT逐位循环；checksum使用首部字节的一般反码和。
- Decoder、builders的单元测试包含独立literal样本；完整原始字节也必须匹配，避免仅共享parser导致错误PASS。
- DUT测试只驱动/监视公开应用流和GMII，复用V1 BFM；不读内部frame buffer、header、SN或CRC。
- 当前配置以接口文档和项目基线为依据，显式记录为`TB_ONLY_DEFAULT`；配置不从Actual Frame学习。
- 路由为port/VL 1..5；源IP为10.1.1.1..5，目的port1为244.244.0.1，其他为10.1.2.2..5。
- DA配置为03:00:00:00:00:01..05；SA A/B分别为02:00:00:01:01:20和02:00:00:01:01:40。
- IPv4 IHL=5、TOS=0、ID=0、DF=1、TTL=1、Protocol=17；UDP checksum策略显式为零。
- Pad=AA；最小长度60 B不含FCS，最大1518 B包含FCS，最大应用载荷1471 B。
- SN采用当前接口定义的测试profile：首帧1，255后回到1；这不是完整ARINC复位行为的规范验收声明。
- 每个case开始使用新的ReferenceState并复位DUT；一个逻辑事务仅消耗一次SN，A/B共用该值。
- GMII数据用`get_payload(strip_fcs=False)`归一化为DA..FCS；SN也被包含在CRC范围中。
- `BAG_CYCLES=16`只用于缩短仿真，模型没有BAG、IFG、jitter或scheduler state。
- 测试结束的32个clk周期只用于观察多余帧，不作任何帧间隔判据，无法证明无限时间内无额外输出。
- 本次正式MAC/IP/VL/时钟等TBD值未冻结；需要生产ICD/指定规范版本完成更完整验收。

协议参考与解释见`sim/README.md`中的RFC及Python标准库文档链接。

## 5. Mismatch记录与限制

**本次四类DUT-vs-Reference测试没有mismatch。** 未改变参考模型规则以迎合DUT，未修改RTL。
Scoreboard自检中的合成坏帧用于证明诊断能力，不列为DUT defect。

以后发生mismatch时先保留失败、原始帧和JSON，再核对规格及显式配置，分类为
`DUT defect` / `model defect` / `config mismatch`，不通过学习实际输出修改expected。
任何协议RTL修复需要作为单独确认和处理的任务。

当前V2验收没有阻塞项。沿用V1的工具/系统限制：

- 本机缺少`vlib/vlog/vsim`，ModelSim Golden未运行；Linux PASS不代表Golden PASS。
- 本机Verilator为5.008，固定cocotb版本需要更高版本；本次没有升级工具。
- 旧`AFDX_TX.v`编译诊断仍因语法错误失败，不属于当前统一DUT的有效源集合或通过基线。
- RX仍为stub；本次没有RX decoder/reference、真实RX、冗余消除或应用peer。
- 不验收完整TX特性、Preamble/SFD、IFG、BAG/jitter、故障恢复或coverage closure。
- 未运行目标器件综合/时序或板级测试。

V2工作止于本报告的Exit Criteria，不继续进入V3系统扩展。
