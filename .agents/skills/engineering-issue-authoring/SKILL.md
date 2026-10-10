---
name: engineering-issue-authoring
description: Draft or create focused engineering issues with traceable scope, dependencies, testable acceptance and closure evidence. Use when converting requirements or verified defects into issues; not for implementing them or publishing unrequested backlog items.
---

# Engineering Issue Authoring

一个 Issue 是一个可独立验收的工程交付单元。提高信息质量，不以数量表示工程进度。

## 输入和职责

接收需求合同或已复现缺陷、仓库上下文、现有 issue 和交付范围。需求尚不清楚时使用 `engineering-requirements-extract` 补足；不是每次重新分析整个产品。

只负责粒度、表述、依赖、可验收性、去重和 issue 生命周期信息。开发者决定具体实现，测试/验收提供关闭证据，主控负责派发/集成。不要用未验证根因规定修复方法。

## 起草标准

按 [Issue 标准](references/issue-standard.md) 选择 bug、feature、engineering、verification 或 release 工作类型，用 [Issue 模板](assets/issue-template.md) 写出：

- 清楚的行为/结果标题、需求 ID 和来源。
- 当前状态、目标行为、范围及本次排除项。
- 依赖/阻塞、负责职能、涉及共享边界。
- 可观察的验收条件、验证层级、关闭证据。
- bug 的复现和实际/预期；工程任务的具体产物与收益。

不凭空填写负责人账号、排期、标签或已通过状态。只引用存在的 issue 编号。依赖未发布时使用本地稳定 ID；取得真实编号后更新链接。

## 去重与发布

起草前查询可用仓库 issue 清单，按需求 ID、模块和行为匹配；重复需求优先更新已有 issue 或说明关联。没有仓库访问时仅起草并记录 dedupe 未核验，不能声称查过。

用户只要求准备 skill/任务包时保留本地草稿。用户明确要求“提 issues”等发布动作时，在已授权仓库用可用 connector 或 CLI 创建/更新；写入前复核目标 repo 和提交正文，不额外要求例行确认。多行正文使用结构化参数或 `--body-file`。

创建后记录真实 URL、编号和状态；失败时保留本地草稿，先查询是否已经创建再重试，防止重复。优先级按实际影响和阻塞关系标注，不为所有任务统一写 P0。

## 完成与关闭

产出应能让不知聊天历史的开发者直接执行，并让验收者独立判断。Issue 关闭要引用对应需求的实际证据与候选版本；PR 合并不自动证明设备/发布任务完成。范围扩大就更新/拆分合同，而不是默默塞到原 issue。
