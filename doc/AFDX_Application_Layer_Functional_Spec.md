# AFDX 应用层功能规范

**文档版本**：v1.1  
**模块范围**：SNMP、TFTP/615A、RTC、应用发送仲裁与适配层。  
**定位**：本规范定义 AFDX ES 第一版应用层 RTL 的功能和上下层接口。比赛方未明确规定的协议裁剪项均作为“本设计约定”，不视为 ARINC 664/615A/SNMP/TFTP 标准强制要求。当前应用端口、Communication Port 与 VL 的最终映射关系不在本次功能补充范围内；本文只冻结应用协议与 UDP Payload 的功能语义。

---

# 1. 系统分层

```text
+--------------------------------------------------+
| Application Layer                                |
|                                                  |
|  SNMP Agent   TFTP/615A Engine   RTC Engine      |
|       \             |              /             |
|        +------ APP TX Arbiter ----+              |
+-----------------------|--------------------------+
                        | UDP Payload Interface
+-----------------------v--------------------------+
| AFDX TX                                           |
| UDP -> IPv4 -> AFDX/VL -> Ethernet -> GMII A/B   |
+--------------------------------------------------+
```

应用层输出的是**完整 UDP Payload**。

应用层不得直接产生：

- UDP header；
- IPv4 header；
- Ethernet header；
- Destination MAC；
- VL ID；
- BAG；
- AFDX Sequence Number；
- FCS。

---

# 2. AFDX TX 应用接口规范

## 2.1 信号

| 信号 | 方向（相对 AFDX_TX） | 位宽 | 含义 |
|---|---|---:|---|
| `tx_data` | input | 8 | UDP Payload 字节 |
| `tx_valid` | input | 1 | 当前字节有效 |
| `tx_ready` | output | 1 | TX 可接受当前字节 |
| `tx_tlast` | input | 1 | 当前字节为本条 Payload 最后一个字节 |
| `tx_port` | input | 8 | 逻辑通信端口 |
| `app_upd_src_port` | input | 16 | UDP 源端口 |
| `app_upd_dst_port` | input | 16 | UDP 目的端口 |

## 2.2 逻辑端口编号

```text
0x01 SAM
0x02 QUE
0x03 SAP_SNMP
0x04 SAP_RTC
0x05 SAP_615A
```

应用层只使用 0x03、0x04、0x05。

## 2.3 数据传输

字节被接受：

```text
transfer = tx_valid && tx_ready
```

消息结束：

```text
message_done = tx_valid && tx_ready && tx_tlast
```

`tx_valid=1 && tx_ready=0` 时，应用必须保持数据和元数据稳定。

## 2.4 元数据生命周期

从一条消息的第一个 transfer 到 `message_done`：

```text
tx_port
app_upd_src_port
app_upd_dst_port
```

必须保持不变。

下一条消息可以立即切换为另一组元数据，但不能在上一条消息未结束时改变。

---

# 3. 地址与路由责任划分

第一版采用**固定对端 IP / 固定 Port-to-VL 路由配置**。

应用层负责：

```text
逻辑应用类型
UDP source port
UDP destination port
UDP payload
```

AFDX TX 负责：

```text
source IP
destination IP
VL ID
destination MAC
source MAC
BAG
Sequence Number
UDP/IP/Ethernet 封装
```

第一版不支持同一个应用端口按每次事务选择不同目的 IP。

---

# 4. 公共 Payload 长度规范

AFDX TX 公共目标最大 UDP Payload：

```text
1471 B
```

第一版应用限制：

| 应用 | 最小长度 | 最大长度 | 备注 |
|---|---:|---:|---|
| SNMP | 协议决定 | 484 B | 第一版硬件 Agent 限制 |
| TFTP | 4 B | 516 B | DATA = 4 B header + 0~512 B data |
| RTC | 16 B | 16 B | 本设计固定格式 |

超出应用自身限制的消息不得进入 TX。

## 4.1 RX 事务提交原则

所有协议解析均以一个完整 UDP Payload 为事务边界：

- `app_rx_last` 到达前允许做字段收集，但不得提交不可回滚的业务状态；
- 长度、Opcode/PDU、嵌套长度等基础合法性在事务结束前完成；
- malformed 消息不得产生 MIB 写入、文件 block 提交或 RTC 更新时间；
- 错误消息处理结束后必须能无 reset 地接收下一条合法消息。

---

# 5. SNMP 功能规范

## 5.1 协议定位

第一版实现简化 **SNMPv2c Agent**。

传输：

```text
UDP / IPv4
```

服务端 UDP Port：

```text
161
```

## 5.2 支持的 PDU

必做：

```text
GetRequest
SetRequest
GetResponse
```

第一版不要求：

```text
GetNextRequest
GetBulkRequest
Trap
Inform
```

## 5.3 BER 范围

必须支持本项目消息所需的：

- INTEGER；
- OCTET STRING；
- OBJECT IDENTIFIER；
- NULL；
- SEQUENCE；
- SNMP PDU tag；
- definite-length BER。

第一版不要求 indefinite-length BER。

## 5.4 SNMP Message 逻辑结构

```text
Message
├── version
├── community
└── PDU
    ├── request-id
    ├── error-status
    ├── error-index
    └── VarBindList
        └── VarBind
            ├── OID
            └── Value
```

第一版建议仅支持 1 个 VarBind/Request。

## 5.5 MIB/OID

使用有限表映射：

```text
OID -> object_id -> internal register
```

对象至少分为：

- 只读状态；
- 可读写配置；
- 不支持对象。

未命中的 OID 不得访问非法寄存器；GetRequest 第一版按 SNMPv2c 异常值语义返回 `noSuchObject`/`noSuchInstance`，SetRequest 则按写操作错误路径返回相应错误状态。

## 5.6 BER 编码约束

第一版 BER 仅支持 definite-length：

```text
Length < 128        : 1 Byte short form
128 <= Length <=255 : 0x81 + 1 Byte length
256 <= Length <=484 : 0x82 + 2 Byte length
```

所有 SEQUENCE、PDU、VarBindList、VarBind 的 Length 必须和实际子内容严格一致。出现越界、截断、Length 嵌套不一致时整条消息判为 malformed。

INTEGER 编码采用 BER 有符号整数最短编码；OBJECT IDENTIFIER 按 BER base-128 子标识符规则编码。第一版解析器只需要支持本项目 MIB 表实际使用的 Value 类型。

## 5.7 Request / Response 语义

- SNMPv2c `version` 为 INTEGER 1；
- Response 的 `request-id` 必须复制收到的 Request；
- GetRequest 第一版只接受单 VarBind；请求 Value 可按 NULL 处理；
- Get 成功：`error-status=noError`、`error-index=0`，Response VarBind 返回实际对象值；
- OID 不存在：VarBind Value 使用 `noSuchObject`/`noSuchInstance` 异常语义，`error-status` 保持 `noError`；
- SetRequest 必须先检查 OID 存在、可写属性、Value 类型与范围，然后再写寄存器；检查失败时不得产生部分写入；
- Set 成功后 Response 回显对应 VarBind；失败使用非零 `error-status` 和对应 `error-index`；
- malformed BER、不支持的 PDU、community/version 不匹配时不得修改内部状态。

## 5.8 SNMP TX

```text
tx_port = 0x03
src UDP = 161
dst UDP = Manager source port / 配置 Manager port
```

Payload 为完整 BER SNMP Message，不包含 UDP header。

---

# 6. TFTP / 615A 功能规范

## 6.1 定位

本版本实现 TFTP 基础传输能力，作为 615A 文件装载/卸载通路的传输基础。

本版本不宣称覆盖完整 ARINC 615A 应用层状态机。

## 6.2 支持报文

```text
RRQ   Opcode 1
WRQ   Opcode 2
DATA  Opcode 3
ACK   Opcode 4
ERROR Opcode 5
```

Mode：

```text
octet only
```

## 6.3 DATA

```text
Opcode       2 B
Block Number 2 B
Data         0~512 B
```

总 UDP Payload：

```text
4~516 B
```

结束判定：

- DATA < 512 B：最后一个 block；
- 文件长度是 512 B 的整数倍：发送额外的 0 B DATA block。

## 6.4 UDP 端口/TID

初始服务端 Port：

```text
69
```

会话建立后使用 TID：

```text
src UDP = local_tid
dst UDP = remote_tid
```

TFTP 模块必须保存当前 session 的：

```text
local_tid
remote_tid
block_number
state
direction
```

第一版远端 IP 固定，不通过应用 TX 接口动态提供。

## 6.5 超时、重传与重复包

即使第一版不实现 RFC2349 `timeout` option negotiation，也必须实现本地固定 timeout/retry。

状态至少包含：

```text
timeout_timer
retry_count
retry_limit
last_tx_packet_type
last_tx_block
last_tx_packet_buffer
```

规则：

1. RRQ/WRQ/DATA/ACK 中需要等待后续响应的发送动作启动 timeout timer；
2. timeout 后重传上一条需要确认的报文，TID、block number、payload 保持不变；
3. 达到 `retry_limit` 后终止 session，并清除当前传输状态；
4. 期望的 DATA(N) 只向文件缓冲提交一次，然后发送 ACK(N)；
5. 重复 DATA(N) 不重复写文件，只重发 ACK(N)；
6. DATA 发送端仅收到 ACK(N) 后推进到 N+1；旧 ACK/重复 ACK 不允许再次推进；
7. unexpected TID 不改变当前 session，可返回 ERROR code 5；
8. final DATA 被 ACK 后进入短暂 dally 状态；若重复收到 final DATA，再发送一次 final ACK。

## 6.6 第一版不支持

- blksize option；
- RFC2349 timeout option negotiation（本地固定 timeout/retry 仍必须实现）；
- tsize option；
- netascii；
- 多并发 TFTP session。

## 6.7 615A 功能边界

第一版仅定义“通过 AFDX/UDP/TFTP 完成文件块上传/下载”的传输基础。TFTP Engine 与文件缓冲接口功能正确，不等价于完整 ARINC 615A Loader。

本阶段不声明支持完整的 615A 业务状态机、全部状态/列表文件语义、多目标并发装载或完整错误恢复流程。后续若有明确验收要求，应在 TFTP 上层增加独立 `arinc615a_session_ctrl`。

---

# 7. RTC 同步功能规范

## 7.1 角色

AFDX ES 为 RTC Slave。

## 7.2 Payload

RTC 格式为项目自定义 v1，不是 ARINC 664 Part 7 规定格式。

固定 16 B：

```text
Byte 0       message_type
Byte 1       version
Byte 2..3    flags/reserved
Byte 4..7    sequence
Byte 8..15   timestamp
```

字段解释：

| 字段 | 说明 |
|---|---|
| `message_type` | 0x01=SYNC，0x02=ACK/STATUS |
| `version` | 0x01 |
| `flags` | 第一版保留，发送 0 |
| `sequence` | 消息序号 |
| `timestamp` | 64-bit 时间值 |

`timestamp` 的 epoch 和单位由系统配置统一定义。

## 7.3 时间基准

第一版采用 64-bit 无符号整数时间。工程必须统一冻结：

```text
RTC_EPOCH
RTC_TIME_UNIT = ns（推荐）
RTC_TICK_NS
```

本地 RTC 在每个系统时钟周期按 `RTC_TICK_NS` 递增。第一版采用硬步进同步，不实现频率伺服。

## 7.4 RX 行为

收到 SYNC：

1. 检查长度=16；
2. 检查 version；
3. 检查 message_type；
4. 提取 sequence；
5. 提取 timestamp；
6. 只有完整报文全部合法后，在单一时钟边界执行 `local_time <= timestamp`；
7. 同周期产生单周期 `rtc_sync_valid`；
8. 保存 `last_sequence`；
9. 重复 sequence 默认不再次更新时间，但可重新发送 ACK；
10. 明显旧 sequence 第一版直接丢弃；
11. 可选生成 ACK。

## 7.5 TX 行为

```text
tx_port = 0x04
payload length = 16 B
```

UDP source/destination port 为项目配置值。

---

# 8. APP TX Arbiter 功能规范

## 8.1 输入源

```text
SNMP
TFTP/615A
RTC
```

## 8.2 最小要求

- 任意时刻只能有一个应用驱动 AFDX TX；
- grant 必须保持到本消息 `last` 被接受；
- 不允许 byte-level interleave；
- 被阻塞的应用必须保持 valid/data/last；
- UDP src/dst port 必须和当前 grant 同步；
- `tx_port` 按 grant 自动生成。

## 8.3 输出映射

| Grant | tx_port |
|---|---:|
| SNMP | 0x03 |
| RTC | 0x04 |
| TFTP/615A | 0x05 |

---

# 9. RX 应用接口要求

由于实际 RX 模块接口尚未在本文中冻结，应用层采用内部抽象接口：

```verilog
app_rx_data[7:0]
app_rx_valid
app_rx_last
app_rx_port[7:0]
app_rx_src_udp[15:0]
app_rx_dst_udp[15:0]
```

要求 RX adapter 向应用层输出**已经去除 Ethernet/IP/UDP Header 后的 UDP Payload**。

`app_rx_port` 用于区分 SNMP/RTC/615A。

第一版对端 IP 固定，因此该接口不要求 `src_ip`。

---

# 10. 错误处理规范

应用层不得因非法报文破坏当前 session 或写入非法寄存器。

通用行为：

```text
长度非法     -> 丢弃/协议错误响应
Opcode非法   -> 丢弃/ERROR
BER非法      -> 丢弃，不写MIB
OID不存在    -> SNMPv2c异常VarBind（noSuchObject/noSuchInstance）
TFTP超时     -> 重传；超过retry_limit后终止session
TFTP重复DATA -> 不重复写文件，重发ACK
TFTP旧ACK    -> 忽略，不推进block
RTC格式非法  -> 丢弃，不更新时间
RTC重复seq   -> 不重复更新时间，可重发ACK
```

所有模块必须能在错误报文之后继续接收下一条合法报文。

---

# 11. Reset 行为

Reset 后：

- 所有 TX valid 拉低；
- 无残留 message；
- arbiter 回到 IDLE；
- TFTP session 回到 IDLE；
- SNMP parser 回到 Message 起始状态；
- RTC parser 回到 Header 起始状态；
- RTC 本地时间寄存器是否清零由系统级需求决定；
- 不允许 reset 释放后自动发送未请求报文。

---

# 12. 验证要求

## 12.1 接口级

必须验证：

- 单字节 Payload；
- 多字节 Payload；
- 最大 Payload；
- `tx_ready` 反压；
- last 周期反压；
- 相邻两条不同应用消息；
- 三应用同时请求。

## 12.2 SNMP

- GET；
- SET；
- valid OID；
- invalid OID；
- malformed BER；
- request-id 回显；
- noSuchObject/noSuchInstance；
- Set 只读/类型错误且无部分写入；
- BER `0x81/0x82` length；
- 484 B boundary。

## 12.3 TFTP

- RRQ/WRQ；
- DATA/ACK；
- 512 B DATA；
- <512 B final DATA；
- exact-multiple file termination；
- wrong block/TID；
- DATA 丢失重传；
- ACK 丢失重传；
- duplicate DATA 不重复写入；
- duplicate old ACK 不推进 block；
- final ACK 丢失后的 dally/re-ACK；
- retry limit abort。

## 12.4 RTC

- valid SYNC；
- bad version；
- bad length；
- timestamp 仅在完整合法包后更新；
- duplicate/old sequence；
- ACK sequence 回显；
- ACK。

---

# 13. 第一版设计边界

本规范第一版明确采用以下工程取舍：

```text
固定对端 IP
无 context_id
无动态 dst_ip
单 TFTP session
SNMP 有限 MIB
SNMP 单 VarBind
TFTP 512 B block + 固定本地 timeout/retry
RTC 自定义固定 16 B + step 同步
```

这些是本设计的实现边界，不代表对应协议标准只能这样实现。

---

# 14. 接口冻结结论

基于当前 `AFDX_TX` 接口，可以直接开始 SNMP、TFTP/615A、RTC 应用层 RTL 开发。

第一版应用层向 TX 只需要提供：

```text
tx_port
UDP src port
UDP dst port
payload byte stream
valid/ready
last
```

IP、MAC、VL、BAG、Sequence Number 等由 TX 层负责，不进入应用 RTL 的职责范围。


---

# 15. 协议依据与符合性声明

- SNMPv2 PDU 与请求/响应语义参考 RFC 3416；本规范只实现明确列出的 SNMPv2c 子集。
- TFTP 报文、lock-step ACK、timeout/retransmission 与终止语义参考 RFC 1350；不实现 RFC2347/2348/2349 option negotiation。
- RTC Payload、时间单位与 step 同步语义属于本项目自定义。
- 615A 部分仅声明具备基于 TFTP 的文件传输基础，不声明完整 ARINC 615A 协议符合性。
