# 统一 DUT 接口入口

当前统一顶层是 `AFDX_End_System_top`，位于
`elinx/AFDX_End_System/AFDX_End_System.srcs/sources_1/new/AFDX_End_System_top.v`。

应用边界使用对称的 `app_tx_*`、`app_rx_*` 字节流，网络边界使用双网 `gmii_*`。
详细信号方向、握手、元数据、时钟、RX预留行为和cocotb绑定见
[AFDX End System统一DUT接口](AFDX_End_System_Top_Interface.md)。
