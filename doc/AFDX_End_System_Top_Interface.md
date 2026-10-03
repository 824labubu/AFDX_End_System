# AFDX End System 统一 DUT 接口

接口版本：v1，2026-10-03。模块名：`AFDX_End_System_top`。
RTL 文件：`elinx/AFDX_End_System/AFDX_End_System.srcs/sources_1/new/AFDX_End_System_top.v`。

本接口确定 UDP Payload 与双网 GMII 之间的 DUT 边界，可由应用层 RTL 或 cocotb BFM 驱动。
顶层不实例化 SNMP/RTC/TFTP 应用模块；`app_layer_top` 是其上层使用者。
当前 TX 已连接真实 `AFDX_TX_MAC`，RX 仅预留接口、保持空闲，尚未实现接收功能。

## 1. 时钟和复位

| 信号 | 方向 | 语义 |
|---|---|---|
| `clk` | input | 应用 TX/RX 流共同使用的系统时钟，上升沿握手 |
| `reset_n` | input | 低有效复位，连接现有 TX 的低有效 `reset` |
| `gmii_rx_clk_a/b` | input | 各网络 GMII 接收时钟；当前发送器也使用这些时钟 |
| `gmii_tx_clk_a/b` | output | 当前直接跟随对应 `gmii_rx_clk_a/b`，BFM只能监视、不能驱动 |
| `phy_reset_n_a/b` | output | 低有效 PHY 复位，当前跟随 `reset_n` |

系统频率和 PHY 速率尚未冻结，不由接口命名推断频率。
当前 TX 必须有 A/B 两个持续运行的 GMII 时钟，缺少任一路会阻塞后续发送。
现有 TX 是异步断言复位；板级复位释放、时钟约束和 PHY 时钟模式仍需实现阶段确认。

## 2. 对称的应用流

以下方向全部相对于 **End System DUT**：TX 是应用送入 DUT，RX 是 DUT 送给应用。

| 字段 | TX 名称 | TX 方向 | RX 名称 | RX 方向 | 位宽 |
|---|---|---|---|---|---:|
| data | `app_tx_data` | input | `app_rx_data` | output | 8 |
| valid | `app_tx_valid` | input | `app_rx_valid` | output | 1 |
| ready | `app_tx_ready` | output | `app_rx_ready` | input | 1 |
| last | `app_tx_last` | input | `app_rx_last` | output | 1 |
| port | `app_tx_port` | input | `app_rx_port` | output | 8 |
| src_udp | `app_tx_src_udp` | input | `app_rx_src_udp` | output | 16 |
| dst_udp | `app_tx_dst_udp` | input | `app_rx_dst_udp` | output | 16 |

共同握手契约：

1. 每拍一个 UDP Payload 字节，不包括 UDP/IP/Ethernet Header、Pad、SN 或 FCS。
2. 传输仅发生于 `valid && ready`；末字节的 `valid && ready && last` 结束一条消息。
3. `last` 只能伴随 `valid`。没有单独 SOP：前一条消息结束/复位后，下一次首字节握手隐式开始新消息。
4. 发送者展示 `valid=1` 后，即使接收者尚未 ready 也必须保持 valid；反压期间 data、last 和元数据不变。
5. port/src_udp/dst_udp 从首字节展示开始保持至末字节握手完成；valid 空拍允许数据无效，但不得切换在途消息的元数据。
6. 接收者可以在首字节、中间或末字节反压；不得要求发送者先等待 ready 才置 valid。
7. 复位取消在途事务，复位期间 valid/last 为零；当前 DUT 还将 app_tx_ready 置零。复位释放后从新消息开始。
8. 当前字节流接口不表达零字节消息，不为其生成虚构 last 握手。

`port` 是本地应用/通信端口标识，不是 UDP 端口，也不是直接携带任意 VL ID。
当前 TX 的默认映射是 1=SAM、2=QUE、3=SNMP、4=RTC、5=TFTP；对应默认 VL ID 1..5。
这描述当前实现，正式通信端口/VL表仍需项目配置确认。

TX 的 src_udp 是本地源端口，dst_udp 是对端端口；RX 则是收到包的源/目的 UDP 端口，
即 src_udp 为对端源端口、dst_udp 为本地目的端口。RX port 由接收分发/配置决定。
本版本不增加动态目的 IP 或 context ID，沿用项目的固定对端配置范围。

### 应用层接线

| `app_layer_top` 端口 | 统一顶层端口 |
|---|---|
| `tx_data / tx_valid / tx_ready / tx_tlast / tx_port` | `app_tx_data / app_tx_valid / app_tx_ready / app_tx_last / app_tx_port` |
| `app_upd_src_port / app_upd_dst_port` | `app_tx_src_udp / app_tx_dst_udp` |
| `app_rx_data / app_rx_valid / app_rx_last / app_rx_port` | 同名 |
| `app_rx_src_udp / app_rx_dst_udp` | 同名 |

当前 `app_layer_top` **没有 RX ready 输出**，因此还不能宣称真实 RX 流控已与应用层集成。
后续必须给应用层增加可反压接收契约，或提供有容量/接纳策略的适配缓冲。
不能直接永久绑高 ready 并假定应用层总能接收。本次统一的是下层 DUT 接口，未修改应用协议 FSM。

## 3. 双网 GMII

对每个网络 `n=a/b`：

| 信号 | 方向 | 位宽 | 用途 |
|---|---|---:|---|
| `gmii_rx_clk_n` | input | 1 | BFM/PHY 驱动 RX 时钟；当前 TX 也使用它 |
| `gmii_rxd_n` | input | 8 | 网络接收字节 |
| `gmii_rx_dv_n` | input | 1 | 网络接收数据有效 |
| `gmii_rx_er_n` | input | 1 | 网络接收错误 |
| `gmii_tx_clk_n` | output | 1 | TX 时钟，供 BFM/PHY 采样 |
| `gmii_txd_n` | output | 8 | 网络发送字节 |
| `gmii_tx_en_n` | output | 1 | 网络发送使能 |
| `gmii_tx_er_n` | output | 1 | 网络发送错误，当前 TX 恒零 |

GMII 没有 ready；接收应用端反压必须由接收缓存吸收，不能暂停线上 GMII。
未来 RX 应只向应用提交完整、校验通过、满足接收规则的 UDP Payload；资源不足时的整包丢弃与统计策略需要随着 RX 实现确定。

当前没有真实 GMII RX MAC、FCS 校验、IP/UDP解析或 IC/RM。
所有 `app_rx_*` 输出为零，不因 GMII注入或 app_rx_ready 改变而产生事务。
测试环境必须明确标记真实 RX 用例尚不可验收，不能把空闲检查算作接收协议 PASS。

## 4. 现有 TX 端口取舍与参数

| 原 TX 端口组 | 顶层处理 | 理由 |
|---|---|---|
| 应用 data/valid/ready/tlast/port/UDP ports | 映射为 `app_tx_*` | 已有实际发送功能，握手兼容应用层 |
| `ff_tx_sop` | 内部绑零 | 当前 TX 忽略此引脚，首字节隐式 SOP |
| `p0_rxc/rxd/rxdv/rxer`、`p0_gtxc/txd/txen/txer` | 映射为 `gmii_*` | 提供统一双网网络边界；RX 输入当前预留 |
| `phy_rstb0_a/b` | 映射为 `phy_reset_n_a/b` | 当前复位输出有效 |
| `p0_txc`、`p0_col`、`p0_crs` | 内部绑零 | 当前 TX 不使用 |
| `reg_wr/rd/addr/data_in` | 内部绑零 | 当前旧寄存器访问接口无实际功能 |
| `reg_data_out/acc_bsy`、`mdc/mdio` | 内部不引出 | 输出常零/高阻，没有寄存器控制或 MDIO管理实现 |

顶层保留现有 TX 的参数及默认值：`MAX_PAYLOAD_BYTES=1471`、`MIN_FRAME_BYTES=60`、
`BAG_CYCLES=50000`、`IFG_CYCLES=12`、`DEST_MAC_PREFIX`、`ES1_USER_ID`、
`ES2_USER_ID`、`PAD_BYTE=AA`、`VL_COUNT=5`。
它们是已有实现值，不表示本次冻结了正式系统时钟、地址或BAG配置。
`MIN_FRAME_BYTES` 不含FCS，BAG以clk周期计，IFG以各网络发送时钟周期计。

TX 最大载荷、单帧缓存、双网完成等待、固定目的 IP/VL 映射等限制仍然适用。
无效端口或超长输入被TX消费后丢弃；应用侧完成握手只表示输入已接收，不是网络发送成功确认。
本接口暂不增加发送完成、错误计数或链路控制总线。

## 5. 工程入口与 cocotb 绑定

eLinx `.epr` 指定 `AFDX_End_System_top`，有效源集合只有：

```text
AFDX_End_System_top.v
AFDX_TX_MAC.v
afdx_mac_tx.v              # elinx 下的 8-bit 应用输入版本
afdx_gmii_tx.v
```

`AFDX_TX_SAM.v`、`AFDX_TX_QUE.v` 是未完成草稿，保留文件但从有效源集合移出。
不要将 `rtl/afdx_mac_tx.v` 加入此集合，其同名模块是另一套1024-bit AXI前端。
`hierarchy.xml` 是此前生成的缓存，需要由eLinx重新生成，不作为当前顶层依据。

已有公共 cocotb wrapper 提供统一映射：

```python
from afdx.tb import AfdxTB, END_SYSTEM_TX, END_SYSTEM_RX, END_SYSTEM_GMII

dut.app_rx_ready.value = 1  # 应用接收端/BFM控制；未来可注入反压
tb = AfdxTB(dut, app_names=END_SYSTEM_TX, gmii_names=END_SYSTEM_GMII,
            rx_names=END_SYSTEM_RX)
await tb.start()
# tb.send_app(...) / tb.recv_app(): TX驱动及实际输入握手监视
# tb.recv_gmii("a"/"b"): 真实TX输出捕获
# tb.inject_gmii("a"/"b", ...): 网络输入驱动
# tb.recv_app_rx(): 未来真实RX输出事务；当前RX未实现，将超时
```

`app_rx_ready` 由使用者驱动，wrapper的RX monitor不会替应用自动置ready。
当前使用 `.get_payload(strip_fcs=False)` 检查捕获帧，不将BFM连通性代替完整协议验收。

运行顶层检查：

```sh
sim/.venv/bin/python sim/run.py --sim icarus --target end-system
```

测试包含实际应用TX至双网GMII的载荷/UDP元信息/SN/FCS检查，以及RX预留空闲和复位检查。
测试参数 `BAG_CYCLES=16` 是 `TB_ONLY_DEFAULT`，没有修改RTL中的50000默认值。
