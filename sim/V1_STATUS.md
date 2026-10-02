# V1 执行结果

日期：2026-10-01。基线：`app_dev` 的 `848a7c3` 加当前验证基础设施改动。
实际需求文件：`doc/verification/AFDX_Verification_Plan.md`。

## 验收记录

| 要求 | 状态 | 证据和限制 |
|---|---|---|
| AppTransaction / AppSource / AfdxTB | Pass | 公共类已实现，事务经过真实 `app_tx_arbiter` 及可选 TX MAC |
| backpressure 与 metadata | Pass | 七种长度、valid 空拍、源/目的 UDP/application port、SV/Python assertion |
| A/B GMII 输出捕获 | Pass | 可选 `AFDX_TX_MAC` 的三条输入在 A/B 各捕获三帧；未验证协议封装内容 |
| GMII RX BFM 注入 | Pass（夹具） | `GmiiSource` 注入 A/B，寄存一拍的回环由 `GmiiSink` 捕获；真实 RX 通路仍 Blocked |
| 自动 timeout / PASS / FAIL | Pass | 永久反压、缺帧失败路径、在途和空拍复位恢复、XML 和进程退出检查 |
| Linux 同套 cocotb tests | Pass | Icarus 11.0，四项 infrastructure 加一项 tx-mac，共五项通过 |
| 独立 Verilog/SV smoke | Pass | Icarus，无第三方 Python 依赖，PASS 标记与超时失败 |
| ModelSim Golden 运行 | Blocked | 已提供统一入口；本机缺少 `vlib/vlog/vsim`，尚未在团队 ModelSim 实测 |
| 当前指定旧 TX 接入 | Blocked | `AFDX_TX.v:24` 语法错误；`legacy-tx` 编译诊断非零退出 |
| 真实 RX → APP | Blocked | RX/顶层接入未完成，ready/cache/adapter 契约未冻结 |
| 本机 Verilator | Blocked | 5.008 缺少 cocotb 2.0.1 需要的 VPI API；入口要求 >=5.036 |
| VCS | Not Run | 提供入口，本阶段 Linux 验收采用 Icarus |

## 重现命令

```sh
sim/.venv/bin/python sim/run.py --sim icarus
python3 sim/run.py --sim icarus --sv-smoke
sim/.venv/bin/python sim/run.py --sim modelsim --target infrastructure
sim/.venv/bin/python sim/run.py --sim icarus --target legacy-tx
sim/.venv/bin/python sim/run.py --sim verilator --target infrastructure
```

前两条应 PASS；本机后三条对应上述阻塞并非零退出。
日志及 `results.xml` 在 `sim/build/` 生成，不纳入版本控制。
依赖为 cocotb 2.0.1 / cocotbext-eth 0.1.26；第三方库产生 API 弃用提示，测试仍通过。

本次只新增 `sim/` 验证文件，没有修改协议 RTL、移动原验证计划或提交到 Git。
开始本次工作前已存在的 `sim/top_tb` 删除及未跟踪 MAC 文件保留原状。
以上 Pass 仅代表 V1 基础设施 smoke，通过项目协议验收仍需后续独立模型和 checker。
