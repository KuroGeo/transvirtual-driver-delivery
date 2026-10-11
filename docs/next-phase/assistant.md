# 需求 3：AI 助手与智能派送

本项单独对应用户提出的超时提醒、下一站查询与站点派送智能规划。AI 建议需要司机确认；提醒和路线约束由确定性代码计算。

## 原型与用户流程

[单项可点击原型](http://127.0.0.1:8764/next-phase/assistant.html) · [原型源码](../../prototype/next-phase/assistant.html)

1. 首页显示下一站与时间窗风险，司机可暂缓或关闭提醒。
2. 打开助手查询下一站、超时风险与派送建议，回答显示来源和更新时间。
3. 预览当前/建议站序、道路指标与理由，司机手动应用，可在版本有效时撤销。
4. 提案过期阻止应用；离线与助手失败各有明确状态，仍可普通配送与导航。

回复、数值与优化为模拟，没有调用模型、道路优化或通知/语音系统。已有确认与点击证据见 [README](../../prototype/next-phase/README.md)。

## 技术方案

PlanRepository 持久保存独立 activeStopOrder/revision；ReminderPolicy 使用可注入时钟与时间窗规则；AgentGateway 通过受信服务访问模型与受限工具。保持现有 ViewModel/Data 边界，客户端不持模型 secret，NP10 单写主页和依赖装配。

查询、提醒与规划共用 EffectiveSnapshot：受信 scope、assignment/serverSnapshotRevision、明确 clientReported 的 localRevision、未同步终态/operationId overlay、activePlanRevision/inputFingerprint。服务端核验权限、站点、基线、合法状态与唯一性，排除本地已完成但服务端仍 pending 的站点；overlay 只能用于查询/提案，不能充当 ACK。远端刷新不覆盖未确认的结果、原因、note 和 outbox；响应指纹已变化则拒绝。

规划以道路矩阵、完整 pending 集、服务日期/IANA 时区、窗口、停留与固定顺序求可行站序，并逐站验证覆盖和约束。30 站为初始工作负载。启发式/预算耗尽只说明限时内未找到可行方案，不能称已证明无解或全局最优；不可达/部分覆盖必须逐站解释。算法来源、预算及供应商在 NP00 冻结，官方依据见 [总方案](../next-phase-solution-design.md#派送计划与提醒)。

PlanProposal 绑定 scope/dataset/baseRevision/inputFingerprint/expiry/完整站点集合；人工 Apply 再次核验后事务落盘，双击幂等、失败不改 UI。Undo 仅原版本与输入有效时允许；配送完成/新派单/位置约束变化使旧提案失效。调序不更改配送终态、统计、失败原因或创建/移除配送 outbox；重启恢复同版计划。

提醒用 scope+dataset+serviceDate+stop+windowId+rule 稳定键去重与暂缓，planRevision 仅检查新鲜度；重算不重置 snooze。换号取消旧可见/系统通知，保留其设置和去重记录。有道路 ETA 才判断迟到风险，无 ETA 仅提示窗口临近。首版前台提醒，通知按权限降级；持续后台定位、麦克风/语音识别没有纳入承诺。

工具白名单为 getNextStop/getDeliveryRisks/previewPlan，服务端注入 scope，验证 schema、权限、ID、状态、版本、成本、配额、总时限/轮数；没有 completeDelivery/clearOutbox。备注与用户文本是不可信数据，注入不能扩大工具权限。回答包含来源/观察时间/新鲜度和未确认标识；超时、拒绝、越权、限流、工具失败可取消/重试，不伪造 ETA 或同步成功。实现依据见 [AI 服务章节](../next-phase-solution-design.md#ai-服务与权限)。

## Harness 与 issue 拆分依据

覆盖 NP-R07–NP-R11；拆分 NP07 计划/Apply/Undo、NP08 提醒、NP09 AI 服务与工具、NP10 页面集成。依赖账号隔离及道路服务；NP01 提供确定性 fixture/观察/门禁，NP11 独立 held-out 评测，NP12 原生计划/提醒恢复，NP13 真实模型/道路联调，NP14 真机性能与成本交接。

必须验证：过期提案/双击/落盘失败/撤销冲突；无遗漏/重复/越权站；本地已完成与服务端 pending 一致处理且 outbox 不变；跨午夜/DST/时钟变化/重算 snooze；注入、未知工具/额外参数/错误数值/超限/取消/预算；真正杀进程后的计划和提醒恢复。每案例保留输入、参数、版本、原日志与正确/拒绝/恢复结论。模型输出或网页演示不能自签业务通过。

先准备本项原型和技术方案，再编写对应 issue。模型/数据地区/保留策略、企业权限、服务配额与物理设备预算仍需真实输入；生产继续 no-go。
