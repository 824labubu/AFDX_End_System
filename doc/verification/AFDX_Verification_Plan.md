# AFDX ES Verification Plan

**Document Version**: v0.1  
**Status**: Verification Baseline  
**Scope**: AFDX ES RTL v1  
**Phase**: V0 — Test Plan  
**Last Updated**: 2026-10-01  

---

# 1. 文档目的

本文档定义 AFDX ES 第一版 RTL 的总体验证范围、验证层次、功能点、异常场景、覆盖目标和验收原则。

本文档作为后续验证环境开发的主参考，不描述具体 BFM、Driver、Monitor、Scoreboard 的代码实现细节。

后续文档职责划分如下：

```text
docs/verification/AFDX_Verification_Plan.md
        ↓
定义“验证什么”

sim/README.md
        ↓
定义“验证环境如何组织、如何运行”

sim/bfm / model / scoreboard / tests
        ↓
实现具体验证
```

---

# 2. 验证目标

验证环境需要证明以下内容：

1. SNMP / TFTP / RTC 应用层功能符合当前功能规范；
2. 应用层与 AFDX 收发模块之间的数据和握手行为正确；
3. TX 能正确完成 UDP、IPv4、AFDX、Ethernet 封装并输出 GMII 帧；
4. RX 能正确解析 GMII 输入并向应用层提交 UDP Payload；
5. VL、BAG、Sequence Number 等 AFDX 行为正确；
6. A/B 双冗余网络输出和接收行为正确；
7. 异常报文不会导致错误状态提交或模块失去恢复能力；
8. reset、backpressure、连续报文和边界长度条件下行为正确；
9. 最终能够完成：

```text
GMII RX
   ↓
AFDX RX
   ↓
Application
   ↓
AFDX TX
   ↓
GMII TX
```

的端到端自动验证。

---

# 3. 验证层次

验证分为五个层次：

```text
L0  Module Verification
    SNMP / TFTP / RTC / OID / CRC 等单模块

L1  Application Integration
    UDP Payload → Application → UDP Payload

L2  TX Path Verification
    Application → AFDX TX → GMII

L3  RX Path Verification
    GMII → AFDX RX → Application

L4  End-to-End Verification
    Remote Peer → AFDX ES → Remote Peer
```

当前优先完成：

```text
L0
L1
L2
```

L3 和 L4 在 RX 接口及缓存契约冻结后完成。

---

# 4. 验证对象边界

## 4.1 Application Side

应用层抽象事务：

```text
payload
src_udp
dst_udp
application / communication port
```

TX 数据流接口：

```text
data
valid
ready
last
```

有效传输：

```text
fire = valid && ready
```

RX 最终接口计划采用相同的：

```text
data
valid
ready
last
```

模型。

RX 接口尚未最终冻结，因此当前验证环境不得强依赖具体 RX RTL 接口实现。

---

## 4.2 Network Side

系统级网络边界：

```text
GMII A
GMII B
```

验证环境需要能够：

- 产生合法 Ethernet / AFDX 帧；
- 注入异常 Ethernet / AFDX 帧；
- 捕获 TX 帧；
- 将 GMII 字节流恢复为报文事务。

---

# 5. TX 功能验证点

## TX-F01 Payload Capture

验证：

- 1 Byte Payload；
- 普通长度 Payload；
- 最大长度 Payload；
- 连续 Payload；
- `valid` 间断；
- `ready` 反压。

通过条件：

```text
DUT最终发送的UDP Payload
==
输入Application Payload
```

---

## TX-F02 Message Boundary

验证：

```text
last
```

只在最后一个有效字节完成事务。

重点覆盖：

```text
1 Byte message
last 与 ready 同时有效
last 遇到 backpressure
连续两个 message
```

---

## TX-F03 UDP Header

检查：

```text
Source Port
Destination Port
UDP Length
Checksum策略
```

其中：

```text
UDP Length = 8 + Payload Length
```

---

## TX-F04 IPv4 Header

检查：

```text
Version
IHL
Protocol = UDP
Total Length
Source IP
Destination IP
Header Checksum
Fragment相关字段
```

第一版不验证 IP fragmentation 功能。

Payload 超出系统允许范围时应作为非法输入处理，而不是依靠 IP fragmentation。

---

## TX-F05 Ethernet Header

检查：

```text
Destination MAC
Source MAC
EtherType
```

以及应用 / 通信配置与最终地址映射的一致性。

---

## TX-F06 AFDX Sequence Number

验证每个 VL 独立维护 Sequence Number。

检查：

```text
连续发送：
SN递增

不同VL：
SN独立

SN达到最大值：
按设计规则回绕
```

异常情况下不得错误增加其他 VL 的 SN。

---

## TX-F08 Ethernet Padding

覆盖短 Payload。

检查最终 Ethernet frame 满足最小帧要求，Padding：

- 长度正确；
- 内容符合项目定义；
- 不计入 UDP Payload 长度。

---

## TX-F09 FCS

独立 Reference Model 计算 Ethernet CRC32。

检查：

```text
Expected FCS == DUT FCS
```

A/B 两路分别计算。

---

## TX-F10 Preamble / SFD

GMII Monitor 检查：

```text
55 55 55 55 55 55 55 D5
```

随后进入 Ethernet Frame。

---

## TX-F11 IFG

检查相邻 Ethernet Frame 间隔满足当前实现定义的 IFG。

---

# 6. A/B 双冗余网络验证点

## RED-F01 双网同时发送

同一应用事务应在：

```text
Network A
Network B
```

均产生对应报文。

---

## RED-F02 Payload 一致性

A/B 网络以下字段应一致：

```text
VL
IP
UDP
Payload
Sequence Number
```

---

## RED-F03 网络相关字段差异

允许根据设计存在差异的字段单独检查，例如：

```text
Source MAC
FCS
```

Reference Model 分别生成 A/B 期望值。

---

## RED-F04 单网异常隔离

后续 RX 验证覆盖：

```text
A正常 / B异常
A异常 / B正常
```

正常网络仍应能够提供有效数据。

---

# 7. Application Verification

现有模块级 TB 保留，统一验证环境重点验证模块之间的组合行为。

## APP-F01 SNMP GET

发送合法 GetRequest。

检查：

```text
Request ID正确返回
OID查询正确
Value正确
UDP端口正确
```

---

## APP-F02 SNMP SET

合法 RW OID：

```text
写入成功
Response正确
```

非法情况：

```text
RO对象
非法OID
错误类型
越界Value
```

不得修改 MIB 状态。

---

## APP-F03 SNMP 异常报文

覆盖：

```text
BER Length错误
消息截断
非法Tag
community错误
未知OID
```

要求：

```text
Parser恢复IDLE
后续合法请求仍能处理
```

---

## APP-F04 RTC SYNC

发送合法 SYNC。

检查：

```text
local_time更新
sequence保存
sync_valid产生
ACK正确
```

---

## APP-F05 RTC Duplicate

重复 Sequence：

```text
不得重复更新时间
允许重新ACK
```

---

## APP-F06 TFTP RRQ / WRQ

验证：

```text
RRQ
WRQ
DATA
ACK
ERROR
```

基本会话状态转换。

---

## APP-F07 TFTP Block

覆盖：

```text
Block 1
连续Block
最后Block < 512B
文件长度为512整数倍
0 Byte终止Block
```

---

## APP-F08 TFTP Retry

覆盖：

```text
ACK丢失
DATA丢失
timeout
retry_limit
```

检查：

```text
重发内容与原报文一致
超过retry_limit正确终止session
```

---

## APP-F09 TFTP Duplicate

检查：

```text
重复DATA：
不得重复写文件
重新ACK

重复ACK：
不得重复推进block
```

---

# 8. RX 验证点

以下功能点先进入 Test Plan，等 RX 接口冻结后实现。

## RX-F01 Ethernet Frame Parse

检查：

```text
MAC
EtherType
Frame Length
FCS
```

---

## RX-F02 IPv4 Parse

检查：

```text
Header Length
Protocol
Total Length
Destination IP
Checksum
```

---

## RX-F03 UDP Parse

检查：

```text
src_udp
dst_udp
UDP length
Payload extraction
```

---

## RX-F04 Application Dispatch

根据配置将 Payload 分发至：

```text
SNMP
RTC
TFTP
```

不能发生跨协议数据污染。

---

## RX-F05 Backpressure

当 Application：

```text
ready = 0
```

时：

- 不丢 byte；
- 不重复 byte；
- metadata 保持稳定；
- 恢复 ready 后继续正确传输。

---

## RX-F06 Invalid Frame Drop

覆盖：

```text
FCS error
wrong MAC
wrong IP
wrong UDP port
invalid length
```

非法报文不得提交到 Application。

---

# 9. AFDX RX 完整性验证

RX RTL 完成后重点加入。

## AFDX-RX-F01 Sequence Number

覆盖：

```text
正常递增
重复SN
SN跳变
SN回绕
```

---

## AFDX-RX-F02 Duplicate Network Frame

A/B 网络收到同一 AFDX 数据时：

```text
不得向Application重复提交
```

具体冗余管理规则根据 RX 最终架构冻结。

---

## AFDX-RX-F03 Network Failure

覆盖：

```text
A Down
B Down
A Error
B Error
```

只要存在合法冗余帧，应能够继续正常工作。

---

# 10. Fault Injection

GMII RX Driver 必须支持至少以下故障：

```text
drop_frame
duplicate_frame
corrupt_fcs
corrupt_ip_checksum
corrupt_sequence
truncate_frame
wrong_dst_mac
wrong_dst_ip
wrong_udp_port
delay_frame
network_a_down
network_b_down
```

异常测试原则：

> 错误输入不能破坏之后合法事务的处理能力。

---

# 11. Reset Verification

覆盖：

```text
Idle Reset
Payload中途Reset
TX等待BAG时Reset
TFTP Session中Reset
SNMP处理中Reset
RTC SYNC处理中Reset
```

Reset 后要求：

```text
FSM回到IDLE
valid状态清除
session状态清除
未完成报文不得继续发送
系统能够重新处理合法事务
```

---

# 12. Backpressure Verification

TX 和 RX 均需要覆盖：

```text
无backpressure
首Byte backpressure
Payload中间backpressure
最后Byte backpressure
随机backpressure
长时间backpressure
```

核心检查：

```text
valid && !ready
```

期间：

```text
data
last
metadata
```

必须保持稳定。

---

# 13. Payload Length Coverage

至少覆盖：

| 长度 | 用途 |
|---:|---|
| 1 B | 最小事务 |
| 4 B | TFTP ACK 等小报文 |
| 16 B | RTC |
| 64 B | 普通小包 |
| 484 B | SNMP 第一版上限 |
| 516 B | TFTP DATA 最大报文 |
| 1471 B | AFDX 应用 Payload 上限 |

额外覆盖：

```text
0 Byte非法事务
1472 Byte超长事务
```

---

# 14. Protocol Coverage

至少覆盖：

| Protocol | 功能 |
|---|---|
| SNMP | GET |
| SNMP | SET |
| SNMP | invalid OID |
| SNMP | malformed BER |
| RTC | SYNC |
| RTC | duplicate sequence |
| TFTP | RRQ |
| TFTP | WRQ |
| TFTP | DATA |
| TFTP | ACK |
| TFTP | timeout |
| TFTP | duplicate packet |

---

# 15. VL Coverage

最终 VL 配置冻结后至少覆盖：

```text
单VL连续发送
多个VL轮流发送
两个VL同时有待发送报文
不同BAG配置
SN独立递增
最大Payload
最小Payload
```

V0 阶段不要求确定具体 VL 数量和最终 Port → VL 映射。

---

# 16. 功能覆盖矩阵

主要交叉覆盖：

```text
Protocol
×
Payload Length
×
VL
×
Network A/B
×
Backpressure
×
Error Type
```

不要求对全部组合做笛卡尔积。

优先保证高价值组合覆盖：

```text
SNMP × malformed
TFTP × timeout
TFTP × duplicate
RTC × duplicate sequence

MAX_PAYLOAD × backpressure

same VL × traffic shaping
different VL × scheduler interaction

A error × B valid
B error × A valid
```

---

# 17. Reference Model 原则

Reference Model 必须独立于 DUT 实现。

禁止：

```text
直接复制RTL中的CRC算法
直接读取DUT内部frame buffer作为expected
直接读取DUT内部SN/BAG状态作为判定依据
```

Reference Model 只根据：

```text
输入Transaction
+
系统Configuration
```

生成 Expected Result。

---

# 18. Scoreboard 输出要求

每次失败至少报告：

```text
Test Name
Transaction ID
Protocol
Network A/B
Expected Length
Actual Length
First Mismatch Byte
Expected Value
Actual Value
Timestamp
```

协议级错误额外报告：

```text
MAC
IP
UDP
SN
FCS
BAG
```

对应检查项。

---

# 19. PASS / FAIL 原则

正式验证结果必须由自动 Checker / Scoreboard / Assertion 判定。

波形只用于 Debug，不作为正式验收依据。

每个 Test 的结果定义：

### PASS

满足：

```text
所有期望Transaction均完成
所有Scoreboard比较通过
无Assertion Failure
无Timeout
```

### FAIL

出现以下任意情况：

```text
数据错误
协议字段错误
时序约束错误
Assertion Failure
多发 / 少发事务
非法状态更新
```

### TIMEOUT

超过测试定义的最大仿真周期仍未完成事务：

```text
TIMEOUT = FAIL
```

---

# 20. 当前 TBD / 未冻结事项

| Item | Status | Impact |
|---|---|---|
| RX `valid/ready/last` contract | TBD | V3 |
| RX Packet Buffer 行为 | TBD | V3 |
| RX Dispatcher 最终接口 | TBD | V3 |
| Communication Port → VL mapping | TBD | V2 / V3 |
| A/B RX redundancy policy | TBD | V3 / V4 |
| 最终 VL 配置 | TBD | Coverage |
| 最终 BAG 配置 | TBD | Timing |
| 最终系统时钟参数 | TBD | Timing |
| UDP checksum 最终策略 | TBD | TX/RX |
| 最终 Port / IP / MAC 配置 | TBD | Reference Model |

TBD 项目不得由验证环境自行假设成正式规范。

若测试必须使用临时值，应统一放入 Test Configuration，并标记：

```text
TB_ONLY_DEFAULT
```

---

# 21. 验证追踪表

该表在 V1 之后持续维护。

| Feature ID | Test Case | Checker | Coverage | Status |
|---|---|---|---|---|
| TX-F01 | `tx_payload_basic` | TX Scoreboard | Payload Length | Planned |
| TX-F02 | `tx_message_boundary` | Stream Checker | last/backpressure | Planned |
| TX-F03 | `tx_udp_header` | UDP Checker | UDP fields | Planned |
| TX-F04 | `tx_ipv4_header` | IPv4 Checker | IP fields/checksum | Planned |
| TX-F05 | `tx_eth_header` | Ethernet Checker | MAC/EtherType | Planned |
| TX-F06 | `tx_sn_sequence` | SN Checker | VL × wrap | Planned |
| TX-F08 | `tx_padding` | Ethernet Checker | short payload | Planned |
| TX-F09 | `tx_fcs` | CRC32 Reference | A/B FCS | Planned |
| TX-F10 | `tx_preamble_sfd` | GMII Monitor | Preamble/SFD | Planned |
| TX-F11 | `tx_ifg` | GMII Timing Checker | IFG | Planned |
| RED-F01 | `tx_dual_network` | A/B Scoreboard | A/B | Planned |
| RED-F02 | `tx_ab_consistency` | A/B Scoreboard | payload/SN | Planned |
| APP-F01 | Existing SNMP GET TB | SNMP Checker | GET/OID | Existing |
| APP-F02 | Existing SNMP SET TB | SNMP Checker | SET/error | Existing |
| APP-F04 | Existing RTC TB | RTC Checker | SYNC | Existing |
| APP-F06 | Existing TFTP TB | TFTP Checker | RRQ/WRQ | Existing |
| APP-F08 | Existing TFTP retry TB | TFTP Checker | timeout/retry | Existing |
| RX-F01 | `rx_eth_parse` | RX Scoreboard | Ethernet | Blocked |
| RX-F03 | `rx_udp_parse` | RX Scoreboard | UDP | Blocked |
| RX-F05 | `rx_backpressure` | Stream Checker | stall position | Blocked |
| AFDX-RX-F02 | `rx_ab_duplicate` | Redundancy Checker | A/B duplicate | Blocked |

Status 可使用：

```text
Planned
In Progress
Pass
Fail
Blocked
Existing
```

---

# 22. 当前可以立即验证的范围

```text
SNMP
TFTP
RTC
Application TX
AFDX TX
UDP/IP framing
Ethernet framing
FCS
GMII TX
A/B TX
BAG
Sequence Number
```

---

# 23. 当前等待接口冻结的范围

```text
AFDX RX → Application handshake
RX Packet Buffer行为
RX Dispatcher最终接口
Communication Port → VL最终映射
A/B RX冗余管理策略
```

这些未冻结项不得阻塞 V1～V3 验证环境开发。

---

# 24. V0 Exit Criteria

V0 完成需要满足：

1. 所有待验证功能均拥有唯一 Feature ID；
2. 每个 Feature 明确 Stimulus、Expected Behavior 和 Checker；
3. TX、RX、Application、AFDX、A/B、异常和时序行为均进入计划；
4. 当前未冻结接口明确标记为 TBD；
5. PASS / FAIL / TIMEOUT 原则明确；
6. Reference Model 独立性原则明确；
7. Verification Traceability Table 已建立；
8. 后续验证不依赖人工查看波形作为主要判定手段。

满足以上条件后，V0 结束。

---

# 25. 下一阶段

进入：

```text
V1 — Verification Infrastructure

Transaction
+
Driver
+
Monitor
+
GMII BFM
```

V1 只负责搭建公共验证基础设施，不修改 DUT 协议功能。
