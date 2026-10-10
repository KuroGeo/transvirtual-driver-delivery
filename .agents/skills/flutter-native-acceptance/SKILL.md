---
name: flutter-native-acceptance
description: Accept or reject Flutter delivery candidates through native user flows, lifecycle recovery and actual device evidence. Use after implementation or for a release candidate; not as a substitute for unit/widget tests or performance profiling.
---

# Flutter Native Acceptance

从用户任务判定交付，不从测试数量判定交付。验收者独立于对应实现者，记录精确版本和执行环境。

## 前置检查

读取需求 ID、运行命令、候选源码/产物指纹和数据配置。核实设备、OS、SDK、build mode、数据库与传输来源。先用现有格式/分析/测试和构建结果排除不能运行的候选；`flutter-build-verify` 的 debug APK / 无签名 simulator app 只证明对应本地构建。

故障场景从测试职能接收受控 fixture/注入配置、预期结果、目标支持范围及测试数据回收方式。缺少安全故障入口时建立补测能力任务，相关故障项保持 blocked；验收者不自行修改业务代码或清用户数据。

以现有设备工具、ADB、simctl 和可用 Flutter 工具优先进行后台操作。命令按实际 app ID 与设备 ID 生成。需要前台权限时按项目共存规则请求该步骤；继续可以后台完成的工作。不得偷偷激活窗口、清空用户应用数据或切换用户标签。

## 执行与判定

按 [原生验收方法](references/native-flows.md) 为每个重点需求运行正常、失败、恢复流程。生命周期测试必须真正结束进程并重开同一个安装数据；hot reload/hot restart 不能替代。UI 结果与持久存储/测试端日志相互核对。

Ocean Delivery 按 [34项检查合同](../../../harness/project/native-acceptance-contract.json) 与 [执行入口](../../../harness/README.md) 选择独立 driver 和 scenario。默认原生工具 smoke 不签 G2；所有源写入者冻结后才运行。实际系统设置、MediaQuery、OS 截图、UI 动作、SQLite backup 和进程身份相互绑定；文本模拟不签 OS 键盘，系统设置回执不签实际字号/动画结果。原始失败保留，验收摘要不能改写缺失的动作或生命周期事实。

每项结果使用 passed / failed / blocked / not_run / not_applicable，并填写理由。未执行不能算通过；没有对应版本的原始证据不能复用旧报告。

描述式输入先标 reported/unverified。原始证据清单记录 ID、路径、候选版本、采集者/时间、kind、raw/summary 和文件 hash，摘要必须引用实际原文件，不能循环引用其他摘要证明通过。

故障输出实际/预期、最短复现、设备/数据条件、证据和影响；交给开发者修复。验收过程中不修改业务代码或改低门槛。修复后重跑缺陷路径及其影响的正常链。

## 输出

使用 [验收报告](assets/acceptance-template.md)。分别说明模拟器功能、真机功能、性能、真实服务、签名和外部交付状态。只有对应层级实测才判定其通过。

参考 [Flutter integration tests](https://docs.flutter.dev/testing/integration-tests)。测试框架内重建 UI 不自动证明跨进程恢复。
