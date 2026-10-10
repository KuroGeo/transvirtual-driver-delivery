---
name: harness-engineering
description: Prepare, implement or audit the execution environment and feedback loops that let engineering agents work reliably. Use for agent-readable context, reproducible workspaces, mechanical architecture and release gates, observable tools, recovery and adversarial evaluations; not for implementing product features or declaring readiness from skills alone.
---

# Harness Engineering

负责 Agent 工作环境和闭环：能找到事实、运行候选、观察失败、得到具体反馈、修复和复验，且不能凭一句“完成”绕过门禁。复用现有 agent runtime，不为此另造平台。

## 职能和模式

用户只要求准备时，审计现状并交付环境/工具/门禁合同、缺口任务和评测用例；不能把文档称为已实现 harness。获准实施时，才在指定 tooling、CI、测试支持和可观测性边界落地，验证实际失败如何阻止交付。

主控负责业务依赖与调度，开发负责产品，测试负责行为回归，验收/性能负责实测；Harness 职能负责让这些动作可执行、可观察、可恢复、可强制校验，不自签它们的业务结果。

## 审计并补强

1. 读取短 AGENTS.md、需求/架构索引、Git/diff 和实际工具；核验相关命令、CI、设备与产物，缺失就记 missing/blocked。不要只问 Agent 有没有信心。
2. 按 [八项能力](references/readiness.md) 列出已有证据、缺口、单一负责人、验证方法。区分 planned、partial、demonstrated、blocked；检查代码/脚本实际存在和运行，不以规则文字代替执行能力。
3. 建立最小可运行环境：锁定 SDK/依赖、工作树/测试数据/服务隔离、可复现启动和快速检查。并行写入、安装和设备操作遵守资源租用；不抢用户前台。
4. 将关键架构/状态不变量写成测试或机械检查，错误输出指出违约位置和修复入口。工具反馈包含退出码、候选版本和原始日志；UI、进程、业务日志及性能可从实际支持表面读取。
5. 将候选与证据绑定，由 CI/发布流程实际执行门禁。缺失、失败、跳过、未知和旧版本证据默认拒绝要求它的交付；主控不能以文字打分覆盖。门禁未接入/可绕过则仍是缺口。
6. 用失败反例和独立 Agent 演练验证门禁、取消/恢复、重复派工和证据真实性。修正失败后重跑相关反例，再跑未用于修改的场景；保留成本和边界，不以一次通过推断可靠率。

Ocean Delivery 的 `local-gate` 校验完整当前 G1/G2/本地资源合同并固定 publish_allowed=false；生产 `gate` 仍要求全部 H01–H08/G0–G6。恢复门禁必须重新读取外部原始证据；候选指纹相同不表示日志、数据库备份或产物仍有效。取消/恢复的实际验证交 X04，原生功能交 E08，远端不可绕过的执行路径交 X05；职能间互相消费证据，不互相代签。

## 上线硬门槛

如果用户要求工程达到 Harness Engineering 才能上线，生产判定须满足当前候选所需八项能力 demonstrated、适用产品 gate 通过及发布授权。任何必要项 planned/partial/blocked 或证据不可复现均为 no-go。准备资料和本地试验可以继续；生产发布任务保持 blocked，不能通过把生产任务改名“本地交付”解锁。

具体阈值由项目合同决定；八项是工程评审框架，不是外部认证。原型 QA、skill 数量、Agent 的自述不能签发资格。用户之后明确变更范围时更新合同，不能默默降低门槛。

## 输出和反馈

使用 [审计模板](assets/audit-template.md)，给出 go/no-go、每项可核验证据及闭环任务。小审计通常一页加链接；完整日志/manifest 各保存一份。记录时间、审查轮数、失败率/flake、上下文和工具浪费；没有足够样本就只报告本次观察。

参考 [OpenAI Harness engineering](https://openai.com/index/harness-engineering/) 关于环境、仓库知识与机械反馈的实践。本 skill 的门槛是项目政策，不照搬该文的技术栈或合并策略。
