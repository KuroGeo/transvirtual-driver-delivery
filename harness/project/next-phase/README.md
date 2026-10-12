本轮 F1 导航已于 2026-10-12 获用户实施授权，执行状态与依赖拆分见 [F1 执行合同](f1-execution.md) 和 [执行叠加层](execution.json)。其余需求仍 prepare；下方为原准备包及发布回执。

# 下一阶段工程准备包

来源为 2026-10-12 已确认原型；用户要求方案与带 Harness 的父子 issue。当前 `mode=prepare`，没有启动产品实现、原生或真实服务验收。

- [需求](mission.md) 与 [接口/所有权合同](contracts.md)
- [每项需求的原型和技术方案映射](feature-contracts.json)：F1 导航、F2 登录、F3 助手；任务须绑定对应 feature，缺任一材料时检查拒绝。
- [方案](../../../docs/next-phase-solution-design.md) 与 [已确认原型](../../../prototype/next-phase/README.md)
- [任务 DAG](backlog.json)、[需求检查矩阵](requirement-matrix.json)、[执行状态](work.json)
- [Issue 索引](issue-plan.md) 与 [父 issue 正文](issues/EPIC.md)

复用 `python3 harness/run.py check` 和 `quality`。新 `harness/next_phase.py` 只签任务包结构；所有产品检查为 planned、evidence=[]。NP01 必须实际扩展原生/服务工具和门禁，才能执行/接受新能力；现有 N1–N7 与旧发布证据保持原范围。

发布使用本地确定正文，`python3 harness/project/next-phase/render_issues.py` 可重新渲染；它不会向 GitHub 写入。发布身份、父子关系和 blocked-by 读回记录在 backlog/publication.json；发布时真实编号与正文 hash 必须一致，未知结果先查 marker 再重试。

产品实施需另有用户授权。派工由主控以 DAG、实际 owner、候选 SHA/fingerprint、合同 revision、结果路径和资源租用记录；NP00 先冻结外部配置和预算，NP01 提供机械边界，再派产品工作。缺服务/设备阻塞对应任务，不编造通过。

生产维持 no-go；NP14 交接既有 #31/#32/#33 的门槛，本包不创建重复发布任务或默默扩大旧验收范围。

最新合同revision3：导航第三方直连/无自建路线后端；Go用户表/认证/会话+前端登录（NP15/NP02），删除B端/用户管理NP16与NP-R18；AI本期客户端可迁移执行器。登录原型沿用已确认版本，取消管理原型审批前置。draft hash不代表远端读回证据。
