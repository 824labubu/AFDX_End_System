# AFDX 应用层 RTL 执行文档

**文档版本**：v1.1  
**目标**：基于当前 `AFDX_TX` 应用侧接口，完成 SNMP、TFTP/615A、RTC 三类应用模块 RTL，并完成应用层发送仲裁与 TX 联调。  
**适用范围**：第一版比赛实现。默认通信对端 IP 由 TX 侧按当前工程接口静态配置；本阶段不引入动态目的 IP、`context_id`、ARP、IP 分片等机制。当前 `tx_port`/应用端口/VL 的最终接口关系仍作为独立接口议题处理，本执行文档仅约束应用协议功能与 UDP Payload 收发行为。

---

## 1. 当前工程边界

应用层只负责生成或解析**UDP Payload**，不负责构造以下内容：

- UDP Header；
- IPv4 Header；
- Ethernet Header；
- VL / Destination MAC 映射；
- BAG；
- AFDX Sequence Number；
- Ethernet FCS；
- GMII 发送时序。

这些内容由 AFDX TX / 数据链路发送路径负责。

当前 TX 应用侧发送接口冻结为：

```verilog
input  [7:0]  tx_data;
input         tx_valid;
output        tx_ready;
input         tx_tlast;
input  [7:0]  tx_port;
input  [15:0] app_upd_src_port;
input  [15:0] app_upd_dst_port;
```

逻辑端口约定：

| tx_port | 名称 | 用途 |
|---:|---|---|
| 1 | SAM | Sampling Port |
| 2 | QUE | Queuing Port |
| 3 | SAP_SNMP | SNMP |
| 4 | SAP_RTC | RTC 同步 |
| 5 | SAP_615A | 615A/TFTP |

本阶段应用层只实现 `SAP_SNMP / SAP_RTC / SAP_615A`。

---

## 2. 应用层到 TX 的统一接口契约

### 2.1 字节传输

一次字节传输成立条件：

```text
fire = tx_valid && tx_ready
```

当 `fire=1` 时，TX 接收当前周期的 `tx_data`。

### 2.2 消息边界

一条应用消息由若干个有效字节组成：

```text
D0, D1, D2, ... , DN
```

最后一个字节满足：

```text
tx_valid = 1
tx_ready = 1
tx_tlast = 1
```

即：

```text
fire && tx_tlast
```

表示一条完整 UDP Payload 已提交。

`tx_tlast` 不允许脱离 `tx_valid` 单独产生。

### 2.3 元数据稳定规则

在一条消息从第一个有效字节被接受，直到最后一个 `fire && tx_tlast` 之间，下列信号必须保持稳定：

```text
tx_port
app_upd_src_port
app_upd_dst_port
```

应用模块不得在一条消息内部修改这些字段。

### 2.4 Backpressure

当 `tx_ready=0` 时：

- 应用保持当前 `tx_data`；
- 保持 `tx_valid=1`；
- 若当前字节是最后一个字节，则保持 `tx_tlast=1`；
- 直到出现 `tx_valid && tx_ready` 后才能进入下一个状态。

### 2.5 Payload 长度边界

公共 TX 能力目标：

```text
1 <= UDP Payload Length <= 1471 Byte
```

各应用第一版限制：

| 应用 | 第一版 Payload 限制 |
|---|---:|
| SNMP | 最大 484 B |
| TFTP/615A | 最大 516 B（基础 TFTP DATA） |
| RTC | 固定 16 B |

应用模块必须在本模块内部保证不会发送超过自身限制的报文。

### 2.6 功能正确性的共同实现原则

为降低纯硬件协议实现中的状态耦合，第一版三个应用均采用“**完整 UDP Payload 为一个处理事务**”的原则：

- RX 侧使用 `app_rx_last` 判定一个 UDP Payload 完成；
- 协议解析器不得在收到完整且通过基础格式检查的消息之前产生不可回滚的状态更新；
- SNMP 建议完整缓存一条消息后解析，缓存能力至少覆盖 484 B；
- TFTP 建议完整缓存当前控制包，DATA 数据可边接收边写文件缓冲，但只有 block/TID 校验通过后才提交本 block；
- RTC 必须收齐并校验 16 B 后一次性更新时间寄存器；
- 任何 malformed/长度非法消息结束后，解析器必须回到可接收下一消息的 IDLE 状态。

---

## 3. 应用层总体 RTL 架构

```text
                    +------------------+
RX application ---> |    SNMP Agent    | --+
                    +------------------+   |
                                             |
                    +------------------+   |
RX application ---> |  TFTP/615A Eng. | --+---> APP TX Arbiter ---> AFDX_TX
                    +------------------+   |
                                             |
                    +------------------+   |
RTC source/RX ----> |    RTC Engine    | --+
                    +------------------+
```

### 3.1 模块建议

```text
app_snmp_agent.sv
app_tftp_615a.sv
app_rtc_sync.sv
app_tx_arbiter.sv
app_layer_top.sv
```

如果项目使用 Verilog-2001，可使用 `.v`，接口含义保持一致。

---

## 4. 应用模块统一内部 TX 接口

为避免三个应用模块直接竞争 `AFDX_TX`，每个应用模块输出统一格式：

```verilog
output [7:0]  app_tx_data;
output        app_tx_valid;
input         app_tx_ready;
output        app_tx_last;
output [15:0] app_tx_src_udp;
output [15:0] app_tx_dst_udp;
```

`tx_port` 不要求各应用模块自行生成，可由 `app_tx_arbiter` 根据输入来源补充：

```text
SNMP  -> tx_port = 3
RTC   -> tx_port = 4
TFTP  -> tx_port = 5
```

这样协议模块只关心协议本身，不关心 AFDX 逻辑端口编号。

---

## 5. APP TX Arbiter 实现要求

### 5.1 基本要求

仲裁必须以**完整消息为粒度**，禁止在一条消息中途切换应用源。

例如：

```text
SNMP D0 D1 D2 D3 LAST
```

发送过程中，即使 RTC/TFTP 同时请求发送，也必须等待 SNMP 的最后一个字节被 TX 接收后才能切换。

### 5.2 Grant 生命周期

```text
IDLE
  |
  | 某应用 valid=1
  v
GRANT_APP
  |
  | app_valid && tx_ready && app_last
  v
IDLE
```

### 5.3 仲裁策略

第一版可采用：

- Round-Robin；或
- 固定优先级。

功能验收重点不是优先级算法，而是：

1. 不丢字节；
2. 不交叉两条消息；
3. Backpressure 正确；
4. 每条消息的 UDP 元数据保持对应。

---

## 6. SNMP Agent 执行任务

### 6.1 第一版功能范围

实现简化 SNMPv2c Agent：

- UDP server port：161；
- 支持 GetRequest；
- 支持 SetRequest；
- 生成 GetResponse；
- 固定/可配置 community；
- 有限 MIB/OID 表；
- OID 映射到内部状态寄存器或配置寄存器；
- BER 使用 definite-length 编码；
- 第一版建议限制单个 VarBind；
- 第一版不要求 GetNext、Trap、复杂 MIB 树遍历。

### 6.2 推荐内部模块

```text
snmp_rx_parser
snmp_ber_decoder
snmp_oid_lookup
snmp_mib_regs
snmp_response_builder
snmp_tx_streamer
```

### 6.3 SNMP TX 行为

```text
tx_port = 3
src UDP = 161
dst UDP = 对端请求中的源 UDP port，或测试环境约定的固定 manager port
payload = 完整 SNMPv2c Message BER 字节流
```

若第一版测试环境只使用固定 Manager，可以将目标 Manager UDP port 作为配置寄存器或测试参数。

### 6.4 SNMP BER / PDU 详细行为

第一版实现必须冻结以下规则：

1. SNMPv2c `version` 按 INTEGER 值 1 处理；community 为可配置 OCTET STRING；
2. Response 的 `request-id` 必须复制对应 Request 的 `request-id`，不得重新生成；
3. GetRequest 仅处理单个 VarBind；请求 VarBind 的 Value 按 NULL 接收，Response 中替换为 MIB 对象实际值；
4. 对不存在的对象，第一版按 SNMPv2c 语义在 VarBind Value 中返回 `noSuchObject` 或 `noSuchInstance`，`error-status=noError`、`error-index=0`；
5. SetRequest 在真正写寄存器前完成 OID、访问属性、数据类型和取值范围检查；验证失败不得产生部分写入；
6. Set 成功时 Response 回显对应 VarBind；失败时生成非零 `error-status` 和相应 `error-index`；
7. BER 只支持 definite-length。Length < 128 使用短格式；更长消息至少支持 `0x81/0x82` 长度格式，以覆盖 484 B 最大消息；
8. 所有外层/内层 SEQUENCE/PDU/VarBind 长度必须相互一致，越界、截断、嵌套长度不一致均判为 malformed；
9. 第一版必须支持 INTEGER、OCTET STRING、OBJECT IDENTIFIER、NULL、SEQUENCE 和所需 PDU tag；如果 MIB 使用 Counter32/Gauge32/TimeTicks，再按对象表显式增加对应应用类型；
10. malformed BER 或不支持的顶层 PDU 类型不得写寄存器，解析器回到 IDLE。

### 6.5 SNMP 单元测试

至少覆盖：

1. 合法 GetRequest -> 正确 GetResponse，request-id 保持一致；
2. 合法 SetRequest -> 写寄存器并响应；
3. 不存在 OID -> `noSuchObject/noSuchInstance`；
4. 只读对象 Set -> 不写寄存器并返回错误；
5. Set 类型/范围错误 -> 不产生部分写入；
6. BER 短长度、`0x81` 长长度、`0x82` 长长度；
7. 非法 BER length / 截断嵌套 -> 丢弃；
8. `tx_ready` 随机拉低；
9. 484 B 边界测试；
10. 最后一个 Byte 的 `tx_tlast` 位置正确。

---

## 7. TFTP / 615A 执行任务

### 7.1 第一版定位

第一版实现 **TFTP 基础传输子集**，作为 615A 数据装载/卸载的数据传输基础。不要在文档中宣称该版本已经覆盖完整 ARINC 615A 业务流程。

### 7.2 TFTP 功能范围

实现 RFC1350 基础格式：

- RRQ；
- WRQ；
- DATA；
- ACK；
- ERROR；
- mode 仅支持 `octet`；
- 默认 block size = 512 B；
- 第一版不实现 RFC2347/2348 option negotiation；
- DATA Payload 最大：`4 + 512 = 516 B`。

### 7.3 TID/UDP 端口处理

初始请求：

```text
dst UDP = 69
```

会话建立后：

```text
src UDP = local TID
dst UDP = remote TID
```

因此 TFTP 模块内部应保存：

```text
local_tid
remote_tid
block_number
transfer_direction
session_state
```

第一版对端 IP 固定，由 AFDX TX 的 `tx_port=5` 配置决定。

### 7.4 可靠传输状态要求

RFC1350 的 DATA/ACK 是 lock-step 传输。第一版虽然不实现 RFC2349 `timeout` option negotiation，但**必须实现本地固定超时与重传**。模块内部至少增加：

```text
tftp_timeout_timer
retry_count
retry_limit
last_tx_packet_type
last_tx_block
last_tx_packet_buffer
```

行为规则：

- 发送 RRQ/WRQ/DATA/ACK 后，若该报文需要对端后续响应，则启动本地 timeout timer；
- timeout 到期且 `retry_count < retry_limit` 时，重发上一条需要确认的报文，block number、TID 和 payload 不变；
- 超过 `retry_limit` 后终止当前 session，清理临时状态并上报 timeout error；
- 接收期望的 DATA(N)：只写入一次文件缓冲，随后发送 ACK(N)；
- 再次收到重复 DATA(N)：不得重复写文件，只重发 ACK(N)；
- 发送 DATA(N) 后只在收到 ACK(N) 时进入下一 block；重复的旧 ACK 不得使 block_number 再次前进；
- unexpected TID 不改变当前 session；可以发送 ERROR(Unknown transfer ID)；
- 最终 DATA 的 ACK 发送后保留短暂 dally 状态，以便最终 ACK 丢失时对重复 final DATA 再次 ACK。

### 7.5 推荐模块

```text
tftp_rx_parser
tftp_session_fsm
tftp_timeout_timer
tftp_file_buffer_if
tftp_packet_builder
tftp_tx_replay_buffer
tftp_tx_streamer
```

### 7.6 TFTP 单元测试

至少覆盖：

1. RRQ；
2. WRQ；
3. DATA block 1；
4. ACK block 1；
5. DATA < 512 B 结束；
6. 文件大小为 512 B 整数倍时的 0 B 最终 DATA；
7. block number 错误；
8. unexpected TID；
9. DATA/ACK 丢包 -> timeout 后正确重传；
10. 重复 DATA -> 不重复写文件且重发 ACK；
11. 重复旧 ACK -> 不重复推进 block number；
12. 最终 ACK 丢失 -> dally 阶段再次收到 final DATA 时重发 ACK；
13. retry 超限 -> session 正确终止并可重新建立；
14. `tx_ready` 随机反压；
15. 516 B 最大报文。

### 7.7 615A 第一版边界

第一版仅把 TFTP Engine 作为 615A 装载/卸载的数据传输基础，并提供一个简单文件缓冲接口。验收可以证明“能够通过 AFDX/UDP/TFTP 传送装载文件”，但不得宣称完整符合 ARINC 615A。

本阶段不实现或不承诺：

- 完整 615A 操作流程/角色状态机；
- 完整状态文件、列表文件及其全部字段语义；
- 多目标并发装载；
- 完整错误恢复、版本兼容和认证机制。

若后续赛题方明确 615A 必测业务，再在 TFTP 之上增加独立 `arinc615a_session_ctrl`，不要把 615A 业务语义硬编码进 TFTP FSM。

---

## 8. RTC 同步模块执行任务

### 8.1 第一版角色

AFDX ES 作为 RTC Slave。

### 8.2 项目自定义 RTC Payload v1

本格式是**项目定义**，不是 ARINC 664 Part 7 标准定义。

固定 16 B：

| Byte | 字段 | 宽度 |
|---:|---|---:|
| 0 | message_type | 1 B |
| 1 | version | 1 B |
| 2-3 | flags/reserved | 2 B |
| 4-7 | sequence | 4 B |
| 8-15 | timestamp | 8 B |

建议：

```text
message_type = 0x01 : SYNC
message_type = 0x02 : ACK/STATUS
version      = 0x01
```

`timestamp` 的单位和 epoch 必须在工程配置文档中固定，不允许模块间自行解释。

### 8.3 RTC 功能

- 接收 SYNC；
- 校验 version / message_type；
- 提取 sequence；
- 提取 timestamp；
- 更新本地 RTC；
- 可选发送 ACK/STATUS；
- 提供同步有效脉冲和当前时间输出。

### 8.4 RTC 时间基准与更新语义

第一版采用**硬步进（step）同步**，不实现频率伺服或渐进校时：

- `timestamp` 定义为相对于项目统一 epoch 的 64-bit 无符号时间值；
- 推荐单位固定为 ns；若系统时钟不能 1 ns 更新，则通过 `RTC_TICK_NS` 参数按本地时钟周期累加；
- 只有在完整 16 B SYNC 收齐、长度/type/version 全部合法后，才在单一时钟边界提交 `local_time <= rx_timestamp`；
- 同一周期产生单周期 `rtc_sync_valid`；
- 保存 `last_sequence`，重复 sequence 默认不再次触发时间更新，但允许重新发送 ACK；
- 明显旧于 `last_sequence` 的报文第一版可直接丢弃；
- ACK/STATUS 建议回显收到的 `sequence`，并携带更新后的当前本地时间。

epoch、单位、`RTC_TICK_NS` 必须在工程参数表中唯一确定。

### 8.5 RTC TX

```text
tx_port = 4
src UDP = 项目固定 RTC port
dst UDP = 项目固定 RTC port
payload length = 16 B
```

### 8.6 RTC 单元测试

至少覆盖：

1. 合法 SYNC；
2. 错误 version；
3. 错误 message_type；
4. sequence 连续；
5. timestamp 在完整报文校验通过后一次性更新；
6. 重复 sequence 不重复更新时间；
7. 旧 sequence 丢弃；
8. ACK 回显 sequence；
9. ACK 16 B 输出；
10. TX backpressure。

---

## 9. RX 侧依赖与临时适配层

当前执行任务重点是应用层 RTL，但完整 SNMP/TFTP/RTC 必须有 RX 输入。

在 RX 主模块接口冻结前，建议应用层内部统一使用抽象接口：

```verilog
input  [7:0]  app_rx_data;
input         app_rx_valid;
input         app_rx_last;
input  [7:0]  app_rx_port;
input  [15:0] app_rx_src_udp;
input  [15:0] app_rx_dst_udp;
```

第一版固定对端 IP，因此应用层不强制要求 `src_ip`。

后续由一个 `app_rx_adapter` 把实际 AFDX RX 输出映射到该接口，避免应用 RTL 跟随 RX 模块修改。

---

## 10. 顶层集成

推荐：

```text
AFDX RX
  |
  v
app_rx_adapter
  |
  +--> SNMP Agent -----+
  +--> TFTP/615A ------+--> app_tx_arbiter --> AFDX_TX
  +--> RTC ------------+
```

### 10.1 app_layer_top 对 TX 输出

```verilog
output [7:0]  tx_data;
output        tx_valid;
input         tx_ready;
output        tx_tlast;
output [7:0]  tx_port;
output [15:0] app_upd_src_port;
output [15:0] app_upd_dst_port;
```

这些端口可以直接连接当前 `AFDX_TX`。

---

## 11. 实施阶段

### Phase 0 - 冻结接口

完成：

- 本文档接口定义；
- TX 事务时序图；
- 应用 RX 抽象接口；
- port 编号；
- UDP port 配置表。

验收：所有应用开发者使用同一份接口定义。

### Phase 1 - 公共发送框架

实现：

- `app_tx_arbiter`；
- 简单 dummy source；
- random backpressure TB。

验收：三个 dummy source 同时请求时，消息不交叉、不丢失。

### Phase 2 - RTC

优先实现 RTC，因为固定 16 B、状态最简单，可首先验证整个应用->TX 链路。

验收：SYNC 接收 + ACK 发送 + TX waveform。

### Phase 3 - TFTP

实现基础 TFTP session FSM、DATA/ACK、timeout/retry 和重复包处理。

验收：完成至少一次 2-block 文件传输，并分别注入 DATA/ACK 丢包验证自动重传。

### Phase 4 - SNMP

实现 BER 解析、OID lookup、Get/Set/Response，并验证 request-id、异常 VarBind、Set 原子校验。

验收：读写至少 3 个内部管理对象，并通过短/长 BER length 与非法嵌套长度测试。

### Phase 5 - 三协议集成

同时使能三个应用模块，验证仲裁和端口映射。

### Phase 6 - 与 AFDX TX 联调

检查：

- `tx_port`；
- UDP src/dst port；
- payload 字节序；
- payload 长度；
- `tx_tlast`；
- backpressure；
- 不同应用消息连续发送。

---

## 12. 第一版明确不做的内容

为了控制比赛实现工作量，第一版不要求：

- 动态目的 IP；
- `context_id`；
- ARP；
- IPv4 fragmentation；
- SNMP GetNext/Trap；
- 完整通用 MIB；
- TFTP option negotiation（包括 RFC2349 timeout option；但本地固定 timeout/retry 必须实现）；
- 超过 512 B 的 TFTP block；
- 完整 ARINC 615A 全业务状态机；
- RTC 高精度时钟伺服算法。

如后续赛题要求明确，再单独扩展。

---

## 13. Definition of Done

应用层第一版完成的最低标准：

1. SNMP/TFTP/RTC 均有独立 RTL 和 TB；
2. 所有发送都经过统一应用 TX 接口；
3. 三个应用可同时发起请求，arbiter 不混包；
4. `tx_ready` 反压情况下数据稳定；
5. `tx_tlast` 只出现在最后一个有效 Byte；
6. UDP src/dst port 与协议状态一致；
7. `tx_port` 分别正确为 3/4/5；
8. 应用模块不生成 IP/MAC/VL/AFDX Header；
9. 集成 TB 能把三类 payload 正确送入 `AFDX_TX`；
10. TFTP 丢包后能够重传，重复 DATA 不重复写入；
11. SNMP Response request-id 与 Request 一致，非法 Set 不产生部分写入；
12. RTC 仅在完整合法 SYNC 后一次性更新时间；
13. 所有已定义定向测试通过。


---

## 14. 协议依据（用于功能正确性）

- SNMPv2 Protocol Operations：RFC 3416。第一版只实现本文明确列出的子集。
- TFTP：RFC 1350。timeout/retransmission、重复 DATA/ACK 的处理以基础 TFTP lock-step 语义为依据。
- RTC 16 B 报文为本项目自定义，不对应 ARINC 664 Part 7 的标准应用报文格式。
- ARINC 615A 本阶段只实现基于 TFTP 的传输基础，不声明完整协议符合性。
