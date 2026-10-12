<!-- ocean-delivery-next-task:NP05; contract:3 -->
类型：feature · 需求：NP-R04, NP-R08, NP-R12, NP-R13 · 状态：planned（未实施/未验收）

[父 Issue #42](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/42)

## 目标与来源

在客户端直连第三方道路路线与 ETA。基于 2026-10-12 已确认原型；[批准原型](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/c67a0dd29b8b8e10c3beabbb4e1a70a1861951e3/prototype/next-phase/README.md) · [方案](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/c67a0dd29b8b8e10c3beabbb4e1a70a1861951e3/docs/next-phase-solution-design.md) · [任务包](https://github.com/KuroGeo/transvirtual-driver-delivery/tree/c67a0dd29b8b8e10c3beabbb4e1a70a1861951e3/harness/project/next-phase)。现有产品源码基线 `e8276b4cc641b57fb70ee61401ccf3dd7e84871e`；新功能不可借旧 R01–R17 的证据关闭。

本条对应需求的原型与技术方案：

- 路径规划与导航：[单项原型](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/c67a0dd29b8b8e10c3beabbb4e1a70a1861951e3/prototype/next-phase/routing.html) · [单项技术方案](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/c67a0dd29b8b8e10c3beabbb4e1a70a1861951e3/docs/next-phase/routing.md)。

每个需求须先具备这两项材料，再发布/更新对应 issue；总方案不能替代单项来源。

当前任务按最新用户修正：路线客户端直连第三方且不建自己的路线后端；Go后端用户表/认证/会话支撑前端登录，不做B端/用户管理；AI 本期独立客户端执行器，后续同协议 Go Agent。登录沿用已确认原型，不再等待已取消的管理原型确认；发布回执与本地正文分开记录。

## 依赖与所有权

依赖：[NP03 #46](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/46)。内部依赖由主控核对 accepted 的实际证据，不凭 issue 关闭/PR 合并自动解锁。外部 #31/#32/#33 仅复用既有门槛，不代签本轮增量。

负责职能：`routing-engineer`；尚未派工，不预填人员账号或排期。允许写域：`app/lib/models/route.dart`, `app/lib/data/routes`, `app/test/route_repository_test.dart`。

执行前记录实际 owner、候选 SHA/fingerprint、合同 revision、结果路径和资源租用。共享 schema、模型协议、lock、启动装配、导航/主题与 CI 按任务包单一负责人接力；越界写入需主控调整合同。

Skill 接力：[flutter-development](https://github.com/KuroGeo/transvirtual-driver-delivery/blob/c67a0dd29b8b8e10c3beabbb4e1a70a1861951e3/.agents/skills/flutter-development/SKILL.md)。

## 验收条件

- [ ] 受信起点/定位时间精度、stop/inputRevision 请求道路路线；响应带 provider/configRevision/computedAt/expiresAt/几何/距离/时长。 响应包含 departureAt/durationBasis，静态路网耗时注明不含实时交通，不能冒称交通感知 ETA。 包含 arrivalAt、可取得的 roadDataVersion，多站 ETA 含窗口等待/服务时长。
- [ ] 迟到 A 路线不能覆盖新 B；权限拒绝/过旧定位支持显式手选起点，缺服务不以直线或固定测试点伪造 ETA。
- [ ] 覆盖 timeout、不可达、部分失败、限额及合法缓存；地图/归属/缓存契约合规，真实供应商测试另在 NP13。
- [ ] RouteRepository 直连第三方 SDK/API，不新增自己的 routes/matrix/代理服务；第三方请求不携本站 token/司机身份/备注。仅用允许分发的客户端凭据，需私密服务密钥的供应商不用于本期直连；基础 Maps 交接不依赖道路配置。

故障与恢复：取消与有界重试；过期缓存标旧，不称实时，服务配置变更拒绝恢复旧结果。

## Harness 与关闭证据

最低功能验证层级：`host`。本任务全部检查为 planned，evidence 为空；静态 check 通过只代表任务包合法。

- `python3 harness/run.py check` — now：合同/任务包结构，不证明功能。
- `python3 harness/run.py test --target test/route_repository_test.dart` — planned：实现目标文件及 NP01 协议后执行；当前不得运行或写 passed。

未来测试路径/新协议必须实际实现后执行；占位设备 ID 与评测入口必须替换为 NP00/NP01 冻结的有效值，不能复制成当前可运行命令。

交回：纯 Dart 路线合同与客户端第三方 adapter、许可/凭据约束、直连 trace 和受控道路/矩阵回归；没有自建 routes 服务。 NP14 交现有 #31/#32/#33；其余按 depends_on 反向消费者交接，主控接受后解锁。

报告使用 Harness 精确 attempt/report.json、原始日志/hash、候选前后指纹、运行配置、服务/模型版本、设备与数据来源、逐需求结论。缺失/失败/未运行/旧候选不得 passed；实现进入 review，独立测试/原生/真实服务/真机职能签对应层级后主控 accepted。

默认后台且使用任务专用资源；需要前台步骤时先说明并获得该步骤授权。生产继续 no-go；本条不授权部署、采购、创建凭据或发布。

<!-- ocean-f1-execution:4 -->
## 2026-10-12 F1 执行修正（优先于上述准备状态/依赖）

本轮 NP05/F1 已获实施授权。原 NP03 #46 是未来真实 AccountScope 数据容器的接口依赖，不是当前导航功能阻塞。当前接入显式本地 NavigationScope(workspaceId,principalId,sessionGeneration,datasetId)，所有迟到结果须绑定 scope/stop/inputRevision；NP03 继续 planned。F1 可执行前置为 NP00 合同冻结 + NP01 执行协议。道路供应商配置缺失时默认 unavailable，无 fixture/直线 ETA；该缺口只阻塞真实道路预览，不阻塞 NP06 Maps 交接。

来源为指定规划 SHA `5f32b66a91dbd6b92b692d252188e23e3e64276e`，源码基线重新核对为最新 main `53c2089`。实施合同见候选分支 `codex/f1-navigation` 的 `harness/project/next-phase/f1-execution.md`。实施、独立 host/native、真实第三方/物理设备、生产分别取证；生产仍 no-go。
