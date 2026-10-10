---
name: engineering-flutter-testing
description: Independently test Flutter engineering contracts and failure recovery at the appropriate unit, widget or native boundary. Use for risk-driven regressions and developer-output review; hardware profiling and delivery qualification belong to their own roles.
---

# Engineering Flutter Testing

测试合同和真实风险，给开发可用的失败反馈。先读本次需求/接口、实现和已有测试，找缺失的行为覆盖，不把开发者所有测试再抄一套。

| 层级 | 重点结果 |
| --- | --- |
| unit / host 文件库 | 输入全量拒绝、终态、原子提交、身份/错 ack、确认回滚、并发/pause/错误释放 |
| widget | 用户操作、保存反馈、校验、错误保留输入、返回与在途关闭 |
| native | 插件/真实文件库、OS 进程恢复和关键用户链，交原生验收职能执行 |

隔离每个测试的数据；需要故障时用可控 fixture/SQLite trigger/Completer，避免随机延迟和不可控睡眠。异步测试推进到明确状态，持续动画不使用无限 pumpAndSettle。只为稳定且经审查的视觉合同加 golden。

独立检查实现者的证据层级和候选。关键缺陷保存复现、实际/预期、影响、失败日志；修复后重跑相关回归与一个未用于修改的风险场景。无足够样本不宣称稳定率。以 host 重开代替 OS 进程终止、以模拟器代替真机均不能签相应门槛。

用项目 Harness 或约定测试入口执行，尊重构建/设备 lease。临时源代码只写本次唯一且不存在的路径，保留退出码后清理；发现可复现缺陷优先转成正式回归。不得删原有测试、清业务数据或降低合同使测试通过。

交回聚焦结果与原始日志索引，说明数据来源、执行平台、通过/失败及未测项；测试职能不改业务实现掩盖验收缺陷。
