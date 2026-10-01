# 应用层 RTL 实现与当前验收状态

实现依据为 `doc/AFDX_Application_RTL_Execution_Plan.md`、
`doc/AFDX_Application_Layer_Functional_Spec.md` 和
`doc/AFDX_Application_Config.md`。这些模块尚未加入下层工程文件列表。

当前代码是可编译、可运行独立定向测试的应用层实现草稿，**尚未完成第一版全部验收**。

## 模块

| 文件 | 当前实现 |
|---|---|
| `app_tx_arbiter.v` | 三路消息级 Round-Robin 仲裁，首字节等待握手时锁定来源，末字节握手后释放 |
| `app_rtc_sync.v` | 16 B SYNC 收集、合法包提交、重复/旧序号处理、16 B ACK |
| `app_tftp_615a.v` | 单会话 octet-mode TFTP 服务端，RRQ/WRQ、DATA/ACK、文件读写抽象、超时重传、dally、接收 ERROR |
| `app_snmp_agent.v` | 单 VarBind 的 GET/SET/Response、definite-length BER、三个 MIB 对象、逐字节响应构造 |
| `app_snmp_oid_lookup.v` | 独立参数化测试对象 OID 表，默认 OID 长度为零表示未配置 |
| `app_layer_top.v` | 按 RX 应用类别分发 Payload，经仲裁器输出原 `AFDX_TX.v` 应用侧信号 |

## TBD 配置

`CLK_FREQ_HZ=0`、`RTC_TICK_NS=0`、`MAX_FILE_BYTES=0` 是尚未配置的占位值，
不代表正式系统配置；分别不会生成有效超时周期、不会推进 RTC、不会允许文件数据传输。
`FILE_ADDR_WIDTH=1` 是保持端口可声明的最小占位宽度，最终必须由系统填写。
RTC UDP 端口和 TFTP local TID 使用显式输入。正式企业 OID 保持未配置。
RTC 的 epoch 由外部统一定义，模块仅操作无符号 ns 时间值。
TB 局部参数已标注 `TB_ONLY_DEFAULT`。

## 回归

从项目根目录执行：

```sh
bash sim/app/run_tests.sh
```

当前五个独立/集成 TB 均通过，覆盖：

- 仲裁消息保持、末字节反压；
- RTC 完整 SYNC 提交、错误版本、重复/旧序号、错误长度、ACK 反压；
- TFTP RRQ/WRQ、两块文件、重复 DATA 不重复写、错误 TID、旧 ACK、
  整数倍长度的空最终 DATA、超时重传及 retry limit；
- SNMP GET/SET、只读/错误值拒绝、community 拒绝、未知 OID、
  畸形 BER、`0x81/0x82` 和 484 B 边界；
- 三应用并发待发送时的消息仲裁、元数据和长度。

Yosys 已通过 `read_verilog; hierarchy; proc; check`。
这不是目标器件综合、资源或时序达标证明。
Verilator 结构检查无错误，但存在待清理的位宽扩展/截断警告。
完整规范要求的随机化和所有定向场景仍需补齐，不能把当前测试结果视为 Phase 0–5 全部完成。

## 停止推进的原因

1. RX 事务流控尚未一致定义。参数文档第 4 节给出 `data/valid/ready/last`
   公共 Payload 契约；功能规范第 9 节和执行计划第 9 节的 RX 抽象接口没有
   `ready`，也没有约定忙时的容量、丢弃或排队规则。
   当前单消息缓存代码无法承诺在 TX 任意长反压时接受持续 RX；接入该类输入
   可能覆写尚在处理的 SNMP/TFTP Payload，RTC 待发 ACK 期间也不能保证每条
   新 SYNC 都得到 ACK。需要明确 RX adapter 是否支持反压、以及何时允许提交下一条消息。
2. 原 `AFDX_TX.v` 第 24 行有多余 `+`，Icarus 无法编译；此外其 `tx_tlast`
   没有参与组帧。Phase 6 的真实 TX 联调因此无法进行。
   下层设计不在当前授权修改范围内，原文件保持原样。

尚未定义的 TFTP 主动客户端启动/文件选择控制接口没有自行加入；当前服务端
能够响应网络 RRQ/WRQ。正式系统集成前还需确认主动客户端是否属于验收范围。
