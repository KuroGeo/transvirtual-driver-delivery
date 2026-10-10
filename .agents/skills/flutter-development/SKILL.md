---
name: flutter-development
description: Implement a bounded Flutter engineering task from a frozen behavior contract, including model, data or UI changes and focused regressions. Use for delegated development; acceptance, profiling and release remain separate roles.
---

# Flutter Development

把已约定行为变成一条可运行切片。先读项目短入口、对应需求、当前接口和已有实现，只加载任务相关资料。

- 确认依赖已接受、单一负责人、写域和完成层级；共享接口/锁/schema/装配需由指定负责人修改。消费者契约变化先通知主控。
- 按现有分层实现：纯模型、Repository 契约、数据实现、ViewModel/UI、启动装配。校验放输入边界，状态不变量留业务/事务内；不把每层重复防御当健壮性。
- 注入本任务需要的存储/transport，不为一次切片造通用框架。正式配置不得自动选 fake；运行模式来自项目合同。
- 在会丢数据、错误确认、异步竞态和输入丢失的风险处保留行为回归。测试验证输出与持久结果，不锁私有实现。
- 用项目 Harness 跑窄测试后跑受影响质量检查；不旁路活着的构建/设备 lease。自审重复逻辑、无用抽象、资源关闭及错误反馈，再交回独立审查。

结果通常十几行：需求 ID、改动理由、命令/退出码、候选和证据路径、未验证范围。开发完成进入 review，不自签 native、真机性能或生产资格。收到有复现的缺陷后先重现，再作必要修正并复验。
