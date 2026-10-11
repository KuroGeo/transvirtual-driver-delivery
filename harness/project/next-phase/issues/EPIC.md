<!-- ocean-delivery-next-epic:NEXT-PHASE; contract:2 -->
# 已确认原型后的账号、导航和 AI 助手工程任务

用户于 2026-10-12 确认原型，并授权方案设计与带 Harness 的父子 issue。默认 A 地图首页、企业已有身份系统、外部地图导航、AI 提案人工应用。产品实施尚未开始；创建任务包不代表功能通过或生产发布。

[批准原型](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/prototype/next-phase/README.md) · [方案](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/docs/next-phase-solution-design.md) · [任务包](https://github.com/KuroGeo/transvirtual-driver-delivery/tree/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/harness/project/next-phase)

每项需求的材料：

- 路径规划与导航：[原型](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/prototype/next-phase/routing.html) · [技术方案](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/docs/next-phase/routing.md)。
- 全站用户、组织与权限：[原型](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/prototype/next-phase/identity.html) · [技术方案](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/docs/next-phase/identity.md)。
  [全站管理原型（待确认）](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/prototype/next-phase/identity-admin.html) · [Go 架构](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/docs/next-phase/backend-go.md)。
- AI 助手与智能派送：[原型](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/prototype/next-phase/assistant.html) · [技术方案](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/5b8c7f49edb7255877bf587b3d6a04ac0bcbc832/docs/next-phase/assistant.md)。

最新范围：导航直连第三方，不建自己的路线后端；全站 Go 用户/组织/RBAC；AI 本期可迁移客户端执行器、后续 Go Agent。管理原型尚待用户确认，远端发布暂缓；本地 draft hash 不是远端读回证据。

## 子任务与顺序

| 任务 | 结果 | 依赖 |
| --- | --- | --- |
| [NP00 #43](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/43) | 冻结账号、导航和助手合同及真实接入配置 | 无 |
| [NP01 #44](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/44) | 扩展 Harness 的账号、路线与 Agent 观察和门禁 | NP00 |
| [NP02 #45](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/45) | 用 Go 实现受信身份、会话和派单持久 ACK | NP15, NP16 |
| [NP03 #46](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/46) | 按账号隔离 SQLite、计划与在途同步 | NP02 |
| [NP04 #47](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/47) | 完成企业登录、刷新、过期和退出的客户端生命周期 | NP03 |
| [NP05 #48](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/48) | 在客户端直连第三方道路路线与 ETA | NP03 |
| [NP06 #49](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/49) | 交接外部地图并返回正确站点 | NP04 |
| [NP07 #50](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/50) | 原子应用时间窗派送计划并支持有条件撤销 | NP05 |
| [NP08 #51](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/51) | 以确定性规则提供时效提醒与下一站提示 | NP04, NP07 |
| [NP09 #52](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/52) | 提供可迁移的客户端 AI 执行器与受限工具 | NP02, NP07, NP08 |
| [NP10 #53](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/53) | 将登录、导航、提醒和助手接入已确认配送首页 | NP06, NP08, NP09 |
| [NP11 #54](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/54) | 独立评测账号恢复、规划不变量和 AI 越权拒绝 | NP10, NP16 |
| [NP12 #55](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/55) | 独立原生验收登录、导航返回与杀进程恢复 | NP11 |
| [NP13 #56](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/56) | 验收真实企业身份、派单 ACK、道路和模型服务 | NP12 |
| [NP14 #57](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/57) | 验证增量真机性能并交接现有发布门槛 | NP13 |
| NP15 | 建立全站 Go 后端模块、OpenAPI 与迁移基线 | NP00, NP01 |
| NP16 | 实现全站组织成员、角色权限与管理审计 | NP15 |

GitHub 原生 sub-issues 和 blocked-by 待按本地 DAG 读回核验；当前草稿不证明远端关系完整。全部任务 planned，未虚构负责人/排期。每项正文包含写域、Skill、故障恢复、可运行/未来命令和关闭证据。

## 不变量与完成条件

- [ ] 账号 A/B、legacy、在途 ACK 和 token 生命周期隔离；仅受信持久确认移出原 outbox。
- [ ] 道路路线/ETA 有来源；外部交接与到站分开，返回正确来源，配送结果继续手动。
- [ ] 计划 Apply/Undo 原子且版本匹配；站序、下一站、列表一致，不改配送终态/outbox。
- [ ] 提醒由确定性规则计算，AI 工具权限/schema/配额有效，查询有来源，建议需司机应用。
- [ ] NP-R01–NP-R19 按候选逐项验收，fixture/网页/模拟器/真机/真实服务不互相代签；NP01 新协议真正实现。
- [ ] Go 全站组织/成员/权限/会话/审计完成隔离和并发反例；可迁移 AssistantExecutor 合同与受控替换通过；路线不经过自建服务。
- [ ] 独立回归、原生、真实服务和增量真机性能证据完整，并交接既有发布门槛。

外部门槛保留 [#31 真机性能](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/31)、[#32 强制执行](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/32)、[#33 资源/签名/交付](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/33)。缺企业 IdP/后端/地图合同/模型配置/设备/预算时对应任务 blocked；本父 issue 关闭不代表生产部署或交付。

当前静态入口 `python3 harness/run.py check` 会核对本包需求、依赖、写域、状态和发布正文；`quality` 验证当前本地基线。新 host/native/live 检查仍为 planned，现有 N1–N7 不覆盖登录/路线/AI。默认后台操作，不占用用户前台。
