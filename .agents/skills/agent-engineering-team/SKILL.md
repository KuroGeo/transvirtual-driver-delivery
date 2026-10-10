---
name: agent-engineering-team
description: Coordinate an autonomous engineering team with distinct requirements, development, testing, acceptance, performance and delivery roles. Use when a user wants agents to jointly advance a project or prepare that team; not for one isolated implementation task.
---

# Agent Engineering Team

把工程推进责任交给一个主控，把重点职能交给可替换的专职 Agent。Skill 定义协作方式；实际并发、工具和生命周期由当前运行环境提供。

## 选择模式

- **prepare**：用户只要求准备 skills/方案时，交付任务包、能力清单、任务图和验收门槛。不得因此启动产品开发、构建或发布。
- **execute**：用户授权推进实现时，在当前任务内拆分、派发、集成、验收，持续到约定交付完成或真实外部依赖阻塞。
- **resume**：先恢复持久任务状态与源码版本，再继续；不要从聊天印象推断完成。
- **repair**：对验收缺陷建立有复现证据的修复任务，保留原验收要求。

用户当前指令决定模式；原型、架构和任务模板本身不构成执行授权。用户已授权的动作不再重复求确认。

## 主控工作

1. 读取项目 AGENTS.md、Git 状态、产品资料及现有任务包。用 `engineering-requirements-extract` 核对需求和版本差异，保留已有设计选择。
2. 沿用项目已有需求/接口合同、任务图与执行状态。参考 [任务模板](assets/task-board.yaml)，每项任务有需求 ID、依赖、单一负责人、写域、验证层级和交付物。重要决策随对应合同或任务记录维护，证据引用原始日志；只有新增独立用途才增加文件，不强行合并不同职责，也不重复建索引。
3. 用 `engineering-issue-authoring` 将任务图转成可独立验收的本地 issue 草稿；只有远端 issue 发布已授权时才向 GitHub 等外部仓库服务创建/更新 issue。核实现有 skills、协作工具、设备和权限。用 [职能与调度协议](references/team-protocol.md) 分配角色；不存在的工具/skill 记录为缺口，不能假称已调用。
4. 只派发依赖已满足、接口已确定的任务。以运行时实际 slot 数为上限；资源冲突任务串行。每项任务只加载所需工程 skill，不把整套手册塞给所有 Agent。
5. 接收简洁结构化结果，独立审阅对应源码和证据。摘要链接原始证据，不复制读资料流水账。Agent 的“完成”先进入 review；主控满足完成条件后才 accepted。串行集成后重验受影响的契约。
6. 自动把失败结果转成有复现路径的修复任务；证据不足转成补证任务。独立验收不由原实现者自签。收口时调用 `engineering-release-handoff`，说明完成层级及外部缺口。

用户要求 Harness Engineering 时用 `harness-engineering` 增设职能：审计并补执行环境、机械边界、可观察工具、实际门禁、恢复与评测。把必需 harness 任务排入依赖；只有执行证据达标才解锁生产交付。准备资料、文档试跑和主控自述不代签。

## 持久状态与恢复

任务状态：planned → ready → running → review → accepted；异常使用 rework 或 blocked。这些是工程任务状态，不调用目标工具改变整段对话状态。

准备和实施任务分开：prepare 只派发资料提取、skill 能力核验、issue 草稿、协议/行为验证等任务，不把实施 backlog 的“创建 App”变成 ready。已有完整准备包时只检查增量缺口，不为运行团队而重新生成同样材料。

主控是共享任务板与合同决策的唯一写入者；工作 Agent 各写自己的 result 文件。每次派发、集成、审查和阻塞变化后更新任务记录。复用 [派工和结果格式](references/work-orders.md)。恢复时比对 base SHA、当前 diff、产物 hash 和实际运行中的 Agent；无法确认的 running 任务进入 review/rework，不能再派一个并行写入者。

## 范围与行为边界

- 成熟工程质量不自动扩展产品功能。真实后端、账号、商业地图和发布目的地缺失时，明确相应交付层级，继续可独立完成的本地工作。
- 不新建用户可见聊天代替子 Agent；使用当前环境的协作工具。只有用户明确要求新聊天才创建。跨聊天发消息遵守独立授权规则。
- Skill 不能创建常驻进程或定时唤醒。没有协作工具时顺序扮演职能，并如实标记没有独立并发/评审；无人执行的任务不能记为完成。
- 浏览器和设备操作遵守项目后台共存规则。后台失败不授权抢占前台。只阻塞依赖该资源的任务。
- 重大功能/契约变化、不可逆动作和确需外部授权的步骤才向用户收口提问；例行实现、修复和复核在已授权范围内自治。

## 输出

准备模式交付可执行任务包与能力缺口；执行模式交付已验收源码、对应版本证据、实际产物和运行说明。不得用计划、网页测试、debug 构建或模拟器证据声称生产上线。
