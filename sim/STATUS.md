# AFDX 验证状态

日期：2026-10-03。分支：`app_dev`。参考模型基线提交：`a7f621c`，及当前TX feature验证改动。
需求依据：`doc/verification/AFDX_Verification_Plan.md`。
验证计划实际路径为`doc/verification/AFDX_Verification_Plan.md`，已更新TX基线/traceability，未移动文件。
接口依据：`doc/AFDX_End_System_Top_Interface.md`；统一DUT为`AFDX_End_System_top`。

**当前TX功能验收全部通过，TX-F07 = REMOVED。**
当前没有DUT mismatch或`BLOCKED_BY_DUT_DEFECT`项。
未修改协议RTL、顶层RTL或Reference Model/Decoder/Scoreboard的协议行为；RX保持stub且未进入当前验证范围。

## 验证组成

验证环境是一套共享实现，按功能组织：

- 公共事务、应用BFM、GMII BFM、流接口assertions、超时和复位工具。
- 独立TX Reference Model、Packet Decoder、协议builders/checksums和逐字段Scoreboard。
- `tests/tx/`中的payload、boundary、headers、sequence、padding、FCS、GMII timing和redundancy测试。
- GMII时序/双网语义checker及轻量Functional Coverage。
- 独立SV infrastructure smoke及统一运行入口。

完整回归日志：`/tmp/afdx_verification_regression.log`，临时目录清理后可重新运行。

## Feature追踪

测试位于`sim/tests/tx/`；每次完整帧比较使用公共Scoreboard。

| Feature ID | Status | Test case | Coverage/检查 |
|---|---|---|---|
| TX-F01 | PASS | `test_tx_f01_payload_lengths_continuous` / `payload_lengths_backpressure` / `zero_byte_interface_rejection` / `1472_byte_drop_and_recovery`（后3项同前缀`test_tx_f01_`） | 1/2/16/64/483/484/485/515/516/517/1471；真实反压；0接口拒绝、1472丢弃和恢复 |
| TX-F02 | PASS | `test_tx_f02_last_under_backpressure` / `valid_gap_before_last` / `back_to_back_messages`（同前缀） | single-byte last stall、2/16/516 valid gaps、4条无调用方等待消息；StreamAssertions检查稳定性 |
| TX-F03 | PASS | `test_tx_f03_udp_ports_lengths_checksum` | UDP端口0/1/65535及常见值，8+payload长度，显式zero checksum策略 |
| TX-F04 | PASS | `test_tx_f04_ipv4_fields_all_routes` | Version/IHL/TOS/ID/DF/offset/TTL/protocol/length/IP/checksum；全部5路 |
| TX-F05 | PASS | `test_tx_f05_ethernet_port_vl_mapping` | 全部5个有效port/VL；独立配置的DA、SA A/B、EtherType |
| TX-F06 | PASS | `test_tx_f06_interleaved_per_vl_independence` / `sequence_wrap_255_to_1` / `reset_restarts_all_vls`（同前缀） | 每VL独立、交错递增、1..255→1实际256帧、reset后全部VL重新从1开始 |
| TX-F07 | REMOVED | — | 无frame_interval >= BAG checker或BAG cross coverage |
| TX-F08 | PASS | `test_tx_f08_padding_boundary` | 1/2/16/17/18/64；Pad=AA、内容/长度正确，不进入UDP/IP长度 |
| TX-F09 | PASS | `test_tx_f09_independent_fcs_each_network` | 每路独立CRC，短/边界/64/484/516/1471，A/B全部验证 |
| TX-F10 | PASS | `test_tx_f10_preamble_sfd_on_wire` | 两路public GMII观察实际7×55+D5、wire长度、无TX_ER |
| TX-F11 | PASS | `test_tx_f11_ifg_idle_gmii_cycles` | A/B各7个相邻间隔；最低12个TX_EN低周期；无BAG判据 |
| RED-F01 | PASS | `test_red_f01_each_transaction_on_both_networks` | 全部路由A/B存在、有界捕获、分别decoder/scoreboard检查，不要求同周期开始 |
| RED-F02 | PASS | `test_red_f02_ab_logical_content_consistency` | IP/UDP/payload/SN字段语义；允许配置的SA/FCS差异 |

## Functional Coverage

收集器：`sim/functional_coverage/tx.py`。报告包括bins/counters、证据、缺失项、失败case及Removed标记。
只计入结果XML和Scoreboard均通过的case；失败不关闭bins。覆盖率不代替checker。

| Group | 命中/必需 |
|---|---:|
| Feature IDs | 12/12 |
| Payload | 9/9 |
| Ports / VLs | 5/5 + 5/5 |
| Flow | 5/5 |
| Sequence | 4/4 |
| Padding | 3/3 |
| Network | 2/2 |
| Invalid length contracts | 2/2 |
| Preamble / IFG × A/B | 4/4 |
| Key payload × backpressure | 7/7 |
| Each port/VL × increment/reset | 10/10 |
| Padding × payload | 8/8 |
| Network × valid FCS | 2/2 |
| Exact boundary neighborhoods | 9/9 |
| **Total** | **87/87** |

所有missing列表为空，passed_cases=19、failed_cases=0。
精确邻域为16/17/18、483/484/485、515/516/517。
不要求全部笛卡尔积；没有same/different VL × BAG bins。

## 完整回归与产物

```sh
sim/.venv/bin/python sim/run.py --sim icarus --regression
```

执行结果：退出码0。

- 模型纯Python：27项PASS；checker/coverage纯Python：14项PASS，共41项。
- 基础设施/顶层smoke：infrastructure 4项、tx-mac 1项、end-system 2项，共7项PASS。
- 基础DUT-reference：4项PASS、10个A/B帧匹配。
- TX Feature：19项PASS、770个A/B帧匹配，共385条有效逻辑消息；另覆盖拒绝/丢弃输入。
- cocotb总计30项PASS，无FAIL/SKIP；独立SV smoke PASS。
- 全部TX Feature Scoreboard：expected=observed=matched，pending=0、mismatch_count=0。

环境：Icarus 11.0、cocotb 2.0.1、cocotbext-eth 0.1.26，无新增第三方依赖。
ModelSim为**PENDING / team golden regression**：本机缺少vlib/vlog/vsim，不能把Linux PASS写成Golden PASS。
Verilator 5.008仍低于现有固定cocotb后端要求，未升级工具或作板级/综合验收。
VCS提供入口，尚未实测。

产物位于Git忽略的`sim/build/icarus/`：

- 八个`tx-*`目标目录：results.xml、每case的scoreboard.json和case.json。
- `coverage/functional_coverage.json`与`.txt`。
- 基础设施和reference目标使用infrastructure/tx-mac/end-system/tx-reference目录；SV沿用sv-smoke。

常用target/suite、最小case筛选和coverage复现说明见`sim/README.md`。

## 验收检查

| 编号 | 要求 | 状态/证据 |
|---|---|---|
| 1～6 | TX-F01～F06 | PASS，Feature表全部对应case |
| 7 | TX-F07明确Removed且无旧BAG checker | REMOVED，计划/代码/coverage一致 |
| 8～11 | TX-F08～F11 | PASS，padding/FCS/线上prefix/IFG |
| 12～13 | RED-F01/02 | PASS，双网分别reference检查及语义一致 |
| 14 | 关键payload长度 | PASS，1/16/64/484/516/1471及邻域 |
| 15 | gap/backpressure/last/back-to-back | PASS，实际握手观察和稳定性assertion |
| 16 | multi-VL/wrap/reset | PASS，实际DUT sequence测试及独立ReferenceState |
| 17 | A/B独立reference/scoreboard | PASS，770个分别匹配的A/B帧 |
| 18 | Functional Coverage报告及必需bins | PASS，87/87，JSON/TXT可输出 |
| 19 | 基础设施/模型检查无退化 | PASS，原27unit + 11cocotb + SV smoke |
| 20 | 可定位field-level diagnostic | PASS，复用Scoreboard诊断及prefix/IFG/A-B checker负路径单测 |

## 行为约定、诊断与边界

- Expected仅来自AppTransaction、显式TB_ONLY_DEFAULT配置和模型自己的ReferenceState。未读取DUT内部buffer/SN/CRC/BAG。
- 0 Byte只验证现有接口无法表达空消息，不虚构末字节；1472 Byte按接口文档消费后丢弃，并检查有限窗口无帧和后续SN恢复。
- Ready只由DUT产生。Last反压用忙碌期间展示下一条单字节消息完成，流接口assertion保持data/last/port/src_udp/dst_udp。
- Back-to-back没有调用方额外等待，保留AppSource cleanup空拍；不宣称本单缓存DUT支持每拍连续接受多条消息。
- GMII IFG单位为各路TX时钟字节周期；当前8 ns/周期、要求12周期，实际观察190～466周期。无start-to-start BAG检查。
- IFG测试覆盖本统一顶层忙碌输入下的最小规则，尚未证明独立MAC恰好12周期的极限吞吐率。
- 前导码独立观察公开GMII信号，不用第三方BFM裁剪结果作为其checker；完整帧仍由原GmiiSink捕获。
- RX保持stub，当前没有RX stimulus、接收解码、E2E、fault campaign、完整BAG/jitter或调度分析。
- TB_ONLY_DEFAULT不冻结生产时钟/通信表或宣称完整ARINC合规。SA、SN和UDP checksum沿用显式profile。
- 有限quiet窗口只能检查测试窗口内无额外帧，不能证明无限时间无输出。

本次没有DUT defect。将来若出现差异，首先保留失败JSON与稳定最小case，核对stimulus/config/model/DUT，
在此记录Feature ID与`BLOCKED_BY_DUT_DEFECT`，保持非零失败；不修改expected或自动修改协议RTL。
原旧`AFDX_TX.v`草稿编译问题不属于本统一DUT的有效源集合，未纳入当前统一DUT的缺陷统计。

当前验收止于以上TX功能范围，不进入后续RX/E2E或其他扩展。
