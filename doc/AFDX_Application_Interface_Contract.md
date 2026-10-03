# 应用层 RTL 接口记录（Phase 0）

依据 `AFDX_Application_RTL_Execution_Plan.md`、`AFDX_Application_Layer_Functional_Spec.md` 和 `AFDX_Application_Config.md`。

- 所有 TX/RX 数据均为完整 UDP Payload 的 8 位字节流，多字节字段按网络字节序。
- TX 字节仅在 `valid && ready` 时被接收；`last` 必须与最后一个被接收的字节同拍。反压时 `data/valid/last` 和 UDP 元数据保持不变。
- 一条 TX 消息从首字节握手到末字节握手期间，`tx_port` 和源/目的 UDP 端口不变。仲裁器按整条消息授权：SNMP=3、RTC=4、TFTP=5。
- RX 抽象接口暂用文档的 `app_rx_data/valid/last/port/src_udp/dst_udp`；RX adapter 尚未定义。应用层只在完整且合法的消息结束后提交业务状态。
- `CLK_FREQ_HZ`、RTC epoch/tick/UDP 端口、TFTP 本地 TID 与文件容量、正式 MIB OID 均保持参数或显式配置接口；TB 中局部值标记 `TB_ONLY_DEFAULT`。
- `tx_port` 到通信端口/VL 的最终关系属于下层配置，本应用层不自行决定。

时序示例（每列一个上升沿，`x` 表示不关心）：

| 周期 | valid | ready | data | last | 结果 |
|---|---:|---:|---|---:|---|
| 0 | 1 | 1 | D0 | 0 | 接收首字节 |
| 1 | 1 | 0 | D1 | 0 | 停顿，D1 与元数据保持 |
| 2 | 1 | 1 | D1 | 0 | 接收 D1 |
| 3 | 1 | 1 | DN | 1 | 接收末字节并结束消息 |

正式端口/VL、MIB、RTC 与文件容量的 TBD 项在最终系统集成前仍需人工冻结。

## 统一下层 DUT 接口（2026-10-03）

`AFDX_End_System_top` 提供 `app_tx_*` 和对称的 `app_rx_*`
data/valid/ready/last/port/src_udp/dst_udp 接口。信号方向、应用模块接线和cocotb映射见
[统一DUT接口](AFDX_End_System_Top_Interface.md)。

下层 RX 的 ready 契约现已明确：应用/BFM驱动 `app_rx_ready`，下层在反压时保持
valid/data/last/元信息。本次只预留 RX 端口；真实RX尚未实现。
现有 `app_layer_top` 尚无RX ready输出，接真实RX前仍需实现应用接收流控或缓冲适配。
