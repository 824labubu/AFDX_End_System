# AFDX 应用层 RTL 实现参数表

**文档名称**：AFDX_Application_Config.md  
**文档版本**：v1.0  
**适用范围**：AFDX ES 第一版应用层 RTL  
**配套文档**：

1. `AFDX_Application_RTL_Execution_Plan.md`
2. `AFDX_Application_Layer_Functional_Spec.md`

---

# 1. 文档目的

本文档用于冻结 AFDX ES 应用层 RTL 实现过程中需要使用的工程参数，避免 RTL 开发或本地 Agent 在规范未明确处自行假设。

本文档只覆盖：

- SNMPv2c Agent；
- TFTP / 615A 基础传输 Engine；
- RTC Slave；
- 应用层公共 Payload 接口；
- 应用层内部缓冲与配置。

本文档不定义：

- UDP Header 生成；
- IPv4 Header 生成；
- Ethernet Header 生成；
- Communication Port 到 VL 的最终映射；
- VL ID；
- BAG；
- AFDX Sequence Number；
- Destination MAC；
- Ethernet FCS；
- GMII 时序。

这些内容属于 AFDX ES 下层发送/接收路径，不属于本应用层 RTL 参数范围。

---

# 2. 参数分类规则

所有参数分为以下四类。

## 2.1 Protocol Constant

协议或当前功能规范已经冻结的固定值。

实现要求：

- 使用 `localparam` 或固定编码；
- 不作为运行时可修改配置；
- 除非功能规范修改，否则不得调整。

示例：

```text
TFTP_SERVER_PORT = 69
TFTP_BLOCK_SIZE  = 512
RTC_MSG_BYTES    = 16
```

---

## 2.2 Compile-time Parameter

工程实现相关、综合前确定的参数。

实现要求：

- 优先使用 module `parameter`；
- 不允许在 FSM 中散落 magic number；
- 所有周期数必须由时钟频率和时间参数计算。

示例：

```text
CLK_FREQ_HZ
TFTP_RETRY_LIMIT
TFTP_TIMEOUT_MS
RTC_TICK_NS
```

---

## 2.3 Runtime Configuration

运行期间可能需要修改的参数。

实现要求：

- 通过配置寄存器、ROM、CSR 或显式配置接口提供；
- 不应硬编码在协议 parser / FSM 中。

示例：

```text
SNMP community
RTC UDP port
TFTP local TID
```

---

## 2.4 TBD Parameter

尚未确定的项目参数。

实现要求：

> 所有标记为 `TBD` 的参数不得由实现 Agent 自行决定。

对于 TBD 项：

- 优先保留为 `parameter`；
- 或保留独立配置寄存器/接口；
- 不得因为 TBD 而修改已冻结的协议状态机结构；
- 不得把 Agent 自选值写死到 RTL；
- TB 中可使用局部测试值，但必须明确标注为 `TB_ONLY_DEFAULT`。

---

# 3. 系统公共参数

| 参数 | 当前值 | 类型 | 说明 |
|---|---:|---|---|
| `CLK_FREQ_HZ` | `TBD` | Compile-time | 应用层工作时钟频率 |
| `RESET_ACTIVE_LOW` | `1` | Protocol/Project Constant | 当前工程 reset 低有效 |
| `APP_DATA_WIDTH` | `8` | Protocol/Project Constant | UDP Payload 接口宽度 |
| `MAX_APP_PAYLOAD_BYTES` | `1471` | Protocol/Project Constant | 应用层公共 UDP Payload 上限 |
| `NETWORK_BYTE_ORDER` | `BIG_ENDIAN` | Protocol Constant | 多字节网络字段高字节先发送 |
| `SUPPORT_DYNAMIC_DST_IP` | `0` | Project Constant | 第一版不支持动态目的 IP |
| `SUPPORT_CONTEXT_ID` | `0` | Project Constant | 第一版不实现 context_id |

---

## 3.1 字节序规则

所有来自网络协议的多字节字段统一采用 Network Byte Order：

```text
高有效 Byte 先发送
低有效 Byte 后发送
```

例如：

```text
16'h1234
```

在线路/字节流中的顺序：

```text
0x12
0x34
```

32-bit：

```text
32'h12345678
```

发送顺序：

```text
0x12
0x34
0x56
0x78
```

64-bit timestamp 同样遵循该规则。

---

# 4. 公共应用 Payload 接口参数

应用层统一按字节流处理 UDP Payload。

基本接口语义：

```verilog
data[7:0]
valid
ready
last
```

传输成立：

```text
fire = valid && ready
```

消息结束：

```text
message_done = valid && ready && last
```

当：

```text
valid = 1
ready = 0
```

发送端必须保持：

```text
data
valid
last
本消息相关元数据
```

不变。

---

# 5. SNMP 参数

## 5.1 SNMP 固定参数

| 参数 | 当前值 | 类型 | 说明 |
|---|---:|---|---|
| `SNMP_UDP_PORT` | `161` | Protocol Constant | SNMP Agent UDP server port |
| `SNMP_VERSION_VALUE` | `1` | Protocol Constant | SNMPv2c BER INTEGER value |
| `SNMP_MAX_MSG_BYTES` | `484` | Compile-time | 第一版硬件消息缓存上限 |
| `SNMP_MAX_VARBINDS` | `1` | Compile-time | 第一版仅支持单 VarBind |
| `SNMP_SUPPORT_GET` | `1` | Project Constant | 支持 GetRequest |
| `SNMP_SUPPORT_SET` | `1` | Project Constant | 支持 SetRequest |
| `SNMP_SUPPORT_GETNEXT` | `0` | Project Constant | 第一版不支持 |
| `SNMP_SUPPORT_GETBULK` | `0` | Project Constant | 第一版不支持 |
| `SNMP_SUPPORT_TRAP` | `0` | Project Constant | 第一版不支持 |
| `SNMP_SUPPORT_INFORM` | `0` | Project Constant | 第一版不支持 |

---

## 5.2 SNMP Community 参数

| 参数 | 当前值 | 类型 | 说明 |
|---|---|---|---|
| `SNMP_COMMUNITY_DEFAULT` | `"public"` | Runtime/Project Default | 默认 community |
| `SNMP_COMMUNITY_MAX_LEN` | `16` | Compile-time | 最大 community 长度 |
| `SNMP_COMMUNITY_WRITABLE` | `0` | Project Parameter | 第一版可先不支持运行时修改 |

实现要求：

- `community` 不应散落硬编码在 BER parser 中；
- parser 应输出 community 字段；
- 独立比较模块或配置寄存器完成匹配；
- community 不匹配时不得执行 Set；
- 第一版可直接丢弃 community 不匹配的请求。

---

# 6. SNMP MIB / OID 配置表

SNMP RTL 必须通过独立的 OID Lookup Table 实现：

```text
OID byte sequence
        ↓
OID Lookup
        ↓
object_id
        ↓
MIB Register / Status Source
```

禁止把具体 OID 匹配逻辑散落到 BER parser FSM 中。

---

## 6.1 企业 OID 前缀

| 参数 | 当前值 | 类型 |
|---|---|---|
| `MIB_ENTERPRISE_OID_PREFIX` | `TBD` | Project Configuration |

在该值确定前：

- Agent 应将 OID 表设计成独立 ROM/case table；
- TB 可使用测试 OID；
- 不得自行申请或虚构正式企业 OID。

---

## 6.2 第一版 MIB 表模板

下表中的 OID 仅为待填写项，不代表最终 OID。

| Object ID | OID | Value Type | 权限 | RTL 对象 | 位宽 | Reset | 范围/说明 |
|---:|---|---|---|---|---:|---:|---|
| `0x00` | `TBD` | INTEGER | RO | `device_status` | 8 | 0 | 设备状态 |
| `0x01` | `TBD` | Counter32 | RO | `rx_packet_count` | 32 | 0 | RX 包计数 |
| `0x02` | `TBD` | Counter32 | RO | `tx_packet_count` | 32 | 0 | TX 包计数 |
| `0x03` | `TBD` | Counter32 | RO | `rx_error_count` | 32 | 0 | RX 错误计数 |
| `0x04` | `TBD` | Counter32 | RO | `tx_error_count` | 32 | 0 | TX 错误计数 |
| `0x05` | `TBD` | INTEGER | RW | `enable_cfg` | 1 | 0 | 0/1 |
| `0x06` | `TBD` | INTEGER | RW | `mode_cfg` | 8 | 0 | 范围 TBD |
| `0x07` | `TBD` | TimeTicks / Counter32 | RO | `uptime` | 32 | 0 | 类型最终冻结后确定 |

当前至少应保证：

```text
>= 3 个 MIB 对象可用于 TB 验收
```

其中建议至少包含：

```text
1 个 RO 状态对象
1 个 RO 计数器对象
1 个 RW 配置对象
```

---

## 6.3 MIB 对象属性

每个对象至少保存：

```text
object_id
value_type
access_mode
value_width
min_value
max_value
```

推荐编码：

```text
access_mode:
00 = unsupported
01 = RO
10 = RW
```

MIB 写操作必须遵守：

```text
OID存在
AND
access_mode == RW
AND
Value类型正确
AND
Value范围正确
```

全部成立后才能提交写操作。

---

# 7. SNMP BER 实现参数

| 参数 | 当前值 | 类型 |
|---|---:|---|
| `SNMP_BER_SUPPORT_SHORT_LEN` | `1` | Constant |
| `SNMP_BER_SUPPORT_LEN_81` | `1` | Constant |
| `SNMP_BER_SUPPORT_LEN_82` | `1` | Constant |
| `SNMP_BER_SUPPORT_INDEFINITE_LEN` | `0` | Constant |

第一版 BER Length：

```text
Length < 128
    1 Byte short form

128 <= Length <= 255
    0x81 + 1 Byte length

256 <= Length <= 484
    0x82 + 2 Byte length
```

---

# 8. TFTP 固定参数

| 参数 | 当前值 | 类型 | 说明 |
|---|---:|---|---|
| `TFTP_SERVER_PORT` | `69` | Protocol Constant | 初始 server port |
| `TFTP_BLOCK_SIZE` | `512` | Protocol/Project Constant | 第一版固定 block size |
| `TFTP_MAX_PACKET_BYTES` | `516` | Constant | 4 B + 512 B |
| `TFTP_MODE` | `"octet"` | Protocol/Project Constant | 第一版唯一模式 |
| `TFTP_MAX_FILENAME_LEN` | `64` | Compile-time | 第一版工程限制 |
| `TFTP_SUPPORT_OPTIONS` | `0` | Project Constant | 不支持 option negotiation |
| `TFTP_MAX_SESSIONS` | `1` | Project Constant | 第一版仅单 session |

---

# 9. TFTP 超时与重传参数

| 参数 | 当前建议值 | 类型 | 说明 |
|---|---:|---|---|
| `TFTP_TIMEOUT_MS` | `1000` | Compile-time | 本地超时时间 |
| `TFTP_RETRY_LIMIT` | `3` | Compile-time | 最大重传次数 |
| `TFTP_DALLY_MS` | `1000` | Compile-time | final ACK 后 dally 时间 |
| `TFTP_LOCAL_TID_BASE` | `TBD` | Runtime/Compile-time | 本地 TID 生成策略 |

以上 `1000 ms / 3 次` 为第一版工程默认值，不是协议强制值。

周期数必须由时钟频率计算：

```text
TFTP_TIMEOUT_CYCLES
    = CLK_FREQ_HZ * TFTP_TIMEOUT_MS / 1000

TFTP_DALLY_CYCLES
    = CLK_FREQ_HZ * TFTP_DALLY_MS / 1000
```

RTL 中禁止直接硬编码类似：

```text
50_000_000
100_000_000
```

形式的周期常数。

---

# 10. TFTP Session 参数

TFTP Engine 第一版必须至少保存：

```text
session_valid
transfer_direction
local_tid
remote_tid
block_number
retry_count
last_tx_packet_type
last_tx_block
```

建议状态：

```text
IDLE
WAIT_DATA
WAIT_ACK
SEND_DATA
SEND_ACK
SEND_ERROR
DALLY
ABORT
```

具体 FSM 编码由实现自行选择，但不得改变功能规范中的 session 行为。

---

# 11. TFTP 文件缓冲接口

第一版 TFTP 模块不直接实现：

```text
Flash Controller
DDR Controller
文件系统
```

只提供抽象 byte-addressed file buffer interface。

---

## 11.1 文件缓冲参数

| 参数 | 当前值 | 类型 |
|---|---:|---|
| `FILE_DATA_WIDTH` | `8` | Constant |
| `FILE_ADDR_WIDTH` | `TBD` | Compile-time |
| `MAX_FILE_BYTES` | `TBD` | Compile-time |
| `FILE_SIZE_WIDTH` | `32` | Compile-time |

约束：

```text
MAX_FILE_BYTES <= 2^FILE_ADDR_WIDTH
```

---

## 11.2 推荐写接口

```verilog
output                  file_wr_en;
output [FILE_ADDR_WIDTH-1:0] file_wr_addr;
output [7:0]            file_wr_data;

output                  file_commit;
output [31:0]           file_size;
```

语义：

```text
file_wr_en
    当前 byte 写入临时文件缓冲

file_commit
    当前 TFTP 接收文件完整成功后提交
```

TFTP DATA block 在 TID / block number 未验证通过前，不允许产生不可回滚的 block commit。

---

## 11.3 推荐读接口

```verilog
output                  file_rd_req;
output [FILE_ADDR_WIDTH-1:0] file_rd_addr;

input  [7:0]            file_rd_data;
input                   file_rd_valid;
```

要求：

- TFTP TX 必须能等待 `file_rd_valid`；
- 不得假设文件数据零等待返回；
- 文件存储实现可以在 TB 中用简单 RAM model 代替。

---

# 12. RTC 固定参数

| 参数 | 当前值 | 类型 | 说明 |
|---|---:|---|---|
| `RTC_MSG_BYTES` | `16` | Constant | 固定 Payload 大小 |
| `RTC_VERSION` | `8'h01` | Constant | 协议版本 |
| `RTC_TYPE_SYNC` | `8'h01` | Constant | SYNC |
| `RTC_TYPE_ACK` | `8'h02` | Constant | ACK/STATUS |
| `RTC_TIME_WIDTH` | `64` | Constant | 时间宽度 |
| `RTC_SEND_ACK` | `1` | Compile-time | 第一版发送 ACK |

---

# 13. RTC 时间参数

| 参数 | 当前值 | 类型 |
|---|---:|---|
| `RTC_EPOCH` | `TBD` | Project Constant |
| `RTC_TIME_UNIT` | `ns` | Project Constant |
| `RTC_TICK_NS` | `TBD` | Compile-time |

如果：

```text
CLK_FREQ_HZ = 100 MHz
```

则：

```text
clock period = 10 ns
RTC_TICK_NS  = 10
```

本地时间：

```verilog
local_time <= local_time + RTC_TICK_NS;
```

实际 `RTC_TICK_NS` 必须和最终系统时钟一致。

---

## 13.1 RTC Epoch

当前：

```text
RTC_EPOCH = TBD
```

最终必须明确，例如：

```text
Unix Epoch
项目启动时刻
设备自定义 epoch
```

在 Epoch 未冻结前：

- RTC parser / counter RTL 可以开发；
- TB 使用测试 epoch；
- Agent 不得自行选择 Unix Epoch 并将其作为正式规范。

---

# 14. RTC UDP 配置

| 参数 | 当前值 | 类型 |
|---|---:|---|
| `RTC_LOCAL_UDP_PORT` | `TBD` | Runtime/Project Configuration |
| `RTC_REMOTE_UDP_PORT` | `TBD` | Runtime/Project Configuration |

RTC 第一版假定：

```text
固定通信对端
固定 UDP port
```

但具体数值当前不由 Agent 决定。

---

# 15. UDP Port 配置总表

| 应用 | Local UDP Port | Remote UDP Port | 类型 |
|---|---:|---:|---|
| SNMP Agent | `161` | Request source port / configured manager port | 动态或项目配置 |
| RTC | `TBD` | `TBD` | 固定配置 |
| TFTP Initial Client Request | local TID | `69` | Session |
| TFTP Initial Server Receive | `69` | request source TID | Session |
| TFTP Established Session | local TID | remote TID | Session |

注意：

SNMP Response：

```text
src UDP = 161
dst UDP = Manager Request 的 source UDP port
```

TFTP：

```text
初始 server port = 69
会话建立后双方使用 TID
```

---

# 16. 第一版不进入参数表的内容

以下信息当前不由应用层定义：

```text
source IP
destination IP
VL ID
Communication Port -> VL mapping
Destination MAC
Source MAC
BAG
LMAX
AFDX Sequence Number
Network A/B
IP checksum
UDP checksum策略
Ethernet FCS
GMII clock/timing
```

如果后续需要配置这些内容，应增加独立：

```text
AFDX_Port_Config.md
AFDX_VL_Config.md
```

不得将这些参数加入 SNMP/TFTP/RTC FSM。

---

# 17. 推荐 RTL 参数组织

## 17.1 SystemVerilog 工程

推荐建立：

```text
app_config_pkg.sv
```

示例：

```systemverilog
package app_config_pkg;

    parameter int unsigned CLK_FREQ_HZ = 100_000_000;

    parameter int unsigned MAX_APP_PAYLOAD_BYTES = 1471;

    parameter int unsigned SNMP_MAX_MSG_BYTES = 484;
    parameter int unsigned SNMP_MAX_VARBINDS  = 1;

    parameter int unsigned TFTP_BLOCK_SIZE      = 512;
    parameter int unsigned TFTP_MAX_PACKET_BYTES = 516;
    parameter int unsigned TFTP_TIMEOUT_MS      = 1000;
    parameter int unsigned TFTP_RETRY_LIMIT     = 3;
    parameter int unsigned TFTP_DALLY_MS        = 1000;

    parameter int unsigned RTC_MSG_BYTES  = 16;
    parameter int unsigned RTC_TIME_WIDTH = 64;

endpackage
```

注意：

上述 `CLK_FREQ_HZ=100 MHz` 只能在真实工程确认后使用；若工程频率未冻结，应继续保持为 module parameter。

---

## 17.2 Verilog-2001 工程

推荐优先使用 module parameter：

```verilog
module app_tftp_615a #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer TFTP_TIMEOUT_MS   = 1000,
    parameter integer TFTP_RETRY_LIMIT  = 3
)(
    ...
);
```

协议固定值使用：

```verilog
localparam [15:0] TFTP_SERVER_PORT = 16'd69;
localparam integer TFTP_BLOCK_SIZE = 512;
```

不建议大量依赖全局 `` `define ``。

---

# 18. 当前 TBD 清单

在进入最终系统集成前，需要人工冻结以下项目：

| 项目 | 当前状态 |
|---|---|
| `CLK_FREQ_HZ` | TBD |
| `MIB_ENTERPRISE_OID_PREFIX` | TBD |
| 各 MIB 对象最终 OID | TBD |
| `mode_cfg` 等 RW 对象最终范围 | TBD |
| `FILE_ADDR_WIDTH` | TBD |
| `MAX_FILE_BYTES` | TBD |
| `TFTP_LOCAL_TID_BASE` / TID 策略 | TBD |
| `RTC_EPOCH` | TBD |
| `RTC_TICK_NS` | TBD，依赖 CLK |
| `RTC_LOCAL_UDP_PORT` | TBD |
| `RTC_REMOTE_UDP_PORT` | TBD |

这些 TBD **不阻塞应用层 RTL 框架开发**。

Agent 必须：

```text
参数化
或
提供配置接口
```

而不是自行写死。

---

# 19. 本地 Agent 实现约束

本地 Agent 根据：

```text
AFDX_Application_RTL_Execution_Plan.md
AFDX_Application_Layer_Functional_Spec.md
AFDX_Application_Config.md
```

生成 RTL 时必须遵守：

1. 不修改已经冻结的协议功能范围；
2. 不新增动态目的 IP；
3. 不新增 context_id；
4. 不实现或修改 VL/BAG/MAC/IP 层；
5. 不自行填写 TBD 参数；
6. TBD 必须 parameterize 或留配置接口；
7. 禁止在协议 FSM 中散落 magic number；
8. 所有 timeout cycle 必须根据 `CLK_FREQ_HZ` 计算；
9. 所有网络多字节字段统一 big-endian；
10. 所有应用 TX/RX 均遵循完整 UDP Payload 事务边界；
11. 每个协议模块必须提供独立 TB；
12. 先通过模块级 TB，再进行应用层集成；
13. Port/VL 最终关系未冻结，应用协议模块内部不得依赖 VL ID。

---

# 20. 第一版开发所需参数是否充分

当前参数状态足以开始：

```text
SNMP parser / BER decoder
SNMP response builder
SNMP OID lookup framework

TFTP parser
TFTP session FSM
timeout / retry
packet builder
file buffer abstraction

RTC parser
RTC local timer
RTC ACK builder

应用层接口与 TB
```

当前 TBD 主要影响：

```text
最终 MIB 内容
最终文件容量
最终 RTC 端口
最终 RTC 时间基准
最终系统综合参数
```

因此：

> 当前参数表允许本地 Agent 立即开始应用层 RTL 开发，但不允许 Agent 擅自决定尚未冻结的系统配置。
