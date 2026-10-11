# Ocean Delivery 下一阶段方案：账号、导航与 AI 助手

状态：方案与任务准备，2026-10-12；产品实现尚未开始。来源是用户已确认的 [交互原型](../prototype/next-phase/README.md)，现有 [架构](solution-design.md) 与当前源码基线 `e8276b4`。用户授权发布带 Harness 的父子 issue，不构成部署或发布授权。可执行任务包见 [next-phase](../harness/project/next-phase/README.md)。

每项需求的原型与技术方案分别在 [路径规划与导航](next-phase/routing.md)、[登录与用户系统](next-phase/identity.md)、[AI 助手与智能派送](next-phase/assistant.md)。本总方案只记录跨需求合同；单项 issue 必须绑定对应需求材料，不能仅引用本总方案代替。

## 产品行为与默认选择

沿用推荐的 A 地图首页：地图、当前下一站、时间窗提醒和导航入口共存，助手按需打开。用户确认了原型整体，未单独指定 A/B/C。用户登录解释为司机通过企业已有身份系统登录；首版使用受信公司配置与 OIDC，公司内部非 OIDC 系统通过服务端身份桥接。用户最新澄清只需要Go用户表/认证/会话与前端登录，取消B端和用户管理；不增加组织成员/邀请/角色配置。详见 [登录方案](next-phase/identity.md) 与 [Go 架构](next-phase/backend-go.md)。自助注册与任意身份服务器不默认开放。

站点详情进入道路路线预览，显示来源、计算时间、道路距离和 ETA；用户选择外部导航应用。返回后恢复原站点与来源，用户手动确认到站/配送结果。打开导航、推测到站或 AI 提醒均不能自动完成配送。

AI 本期使用可替换的客户端执行器，目标迁到 Go 服务端；模型代理不承担 Agent 循环。AI 提供下一站、时效风险和派送顺序建议。提醒与约束计算由确定性代码执行，模型负责理解问题和解释已验证结果。规划先展示原方案/建议方案与原因，人工应用，可在版本未变化时撤销。首版没有持续后台定位、后台自动派送决策和自动修改配送结果。

## 当前基础与增量边界

现有 Flutter 使用 View/ViewModel、Repository、SQLite/outbox、串行 SyncCoordinator；当前 Transport 只有 demo/unavailable。SQLite v2 与 PendingUpdate/Ack 尚无企业/司机身份维度；查询层按固定参考点 Haversine 排序。必须先增加受信账号作用域和独立计划站序，不能把旧数据库默认归属新登录用户，也不能把直线距离作为道路 ETA。

继续复用 `flutter_map` 与现有 Flutter/Harness，不引入另一套客户端状态框架或 Runner。域模型保持纯 Dart；I/O 放 data，系统登录回调、安全存储、定位、通知和外部应用交接放 platform，启动装配仍由一个负责人维护。Go后端采用模块化单体/PostgreSQL/REST；模块为identity/users/session、delivery、modelproxy，统一用户记录/认证/会话和数据归属。NP15单写Go依赖、启动、OpenAPI和迁移，NP02/NP09写领域模块；详见 [Go 架构](next-phase/backend-go.md)。路线客户端直连第三方，不增加本站 routes/matrix 服务。

| 边界 | 建议接口/职责 | 所有者任务 |
| --- | --- | --- |
| 共享域协议 | AccountScope、Session、RouteRequest/Result、PlanSnapshot/Proposal、Reminder、AssistantReply | NP00 冻结；实现写入者 NP03（账号）/NP05（路线）/NP07（计划）/NP08（提醒）/NP09（助手） |
| Go 平台 | 统一启动/依赖、OpenAPI、schema/迁移、HTTP/DB/日志基础 | NP15 单写 |
| 用户认证与数据归属 | 用户表、受信登录/会话、本人资源校验和持久ACK | NP02 |
| 助手执行协议 | AssistantUseCase/Executor、独立 AgentCore/ToolPort/ModelPort；本期客户端，后续 Go | NP09 |
| 账号容器 | 按作用域业务库、迁移、会话 generation、Transport 与同步生命周期 | NP03 |
| 登录与系统能力 | OIDC 系统浏览器、凭据、安全回调；定位/外部地图；通知 | NP04 / NP06 / NP08 各自独占对应 platform 子目录 |
| 装配与页面 | main/runtime、pubspec/lock、平台工程配置、导航、主题、主页/列表/详情集成 | NP10；消费者先提交依赖/配置需求 |
| Harness 与 CI | 契约/fixture/观察/证据门禁；回归/原生/真实服务签字 | NP01 → NP11 → NP12 → NP13 → NP14 串行交接 |

## 账号与同步一致性

`AccountScope = (workspaceId, principalId)` 使用服务端验证的内部标识；服务端以受信 issuer 与 subject 映射身份，不以邮箱或 UI 输入决定归属。客户端配置只允许已注册公司/issuer/audience/redirect；ID token 不能当配送 API 的授权依据。原生登录走系统浏览器与 Authorization Code + PKCE，校验 state/nonce/issuer/audience/回调并限制一次消费；不在 WebView 中收企业密码，不把 client secret 放 App。参考 [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252) 与 [OAuth 安全最佳实践 RFC 9700](https://www.rfc-editor.org/rfc/rfc9700)。

服务端 session 返回受信 scope、权限、expiry 与服务配置版本。所有数据、路线、规划、AI 工具与 ACK 都校验 scope/dataset。服务端需持久去重 operationId，验证终态转换，并在持久接受后返回完整匹配确认；客户端匹配 scope、dataset、operationId、stopId 后事务落盘才移出 outbox。迟到/重复确认保持幂等，错账号确认拒收。

每 scope 一个业务容器/数据库及计划、提醒设置；token 放系统安全存储，业务数据不能混入 token。登录状态分为 signedOut、authenticating、active、refreshing、reauthRequired、switching。换账号、退出、授权失效与重登重置均递增 sessionGeneration，取消旧请求、停用旧 ViewModel/工具，等待或隔离旧容器在途提交后关闭。新账号 token 不得授权其他 scope 队列；原账号重新认证后可恢复其原队列；旧 ACK 只允许按原凭据和 scope 收尾原库；旧查询、路线、模型与 refresh 不能更新新 UI、凭据或恢复旧会话。

过期暂停联网同步，保留原账号本地结果与 operationId；原账号重新验证后恢复。离线可读/可写期限与撤权策略由企业配置冻结；超出离线授权范围锁住相应业务操作，但不删除已持久结果。refresh 为单一在途操作，按 IdP 的旋转或 sender constraint 合同处理重放防护；退出后的迟到刷新不能恢复会话。退出立即清凭据并锁住业务视图，保留原账号待同步数据，界面明确保留数量；切换账号创建另一个容器。需清除本地数据时必须有单独显式用户动作，不能把退出当删除。SQLite v2 旧库先保留为 legacy/demo 隔离区，仅在服务端验证 dataset 归属后迁移到对应 scope；无法证明归属时禁止自动绑定。迁移事务失败回滚，保留可重试旧库与待同步记录。

## 路线与外部导航

用户明确“后端”仅指自己的后端，第三方能力可用。本期 RouteRepository 通过客户端 SDK/API 直连第三方道路/矩阵服务；不新增 Go routes API、私密密钥代理、自托管 OSRM 或道路缓存服务。本站账号/派单接口提供既有数据，不参与算路。供应商必须允许移动端调用、凭据分发和当前地图展示；不满足则换方案或降级外部地图，不能默默增加后端。具体合同见 [导航方案](next-phase/routing.md)。

RouteRequest/Result 保留 scope/dataset/stop/inputRevision 和来源/时间/geometry/distance/duration/trafficAware；scope 只用于本地隔离，不把本站 token/身份/备注发给道路供应商。第三方失败/缺配置显示预览不可用，基础 Maps URL/Intent 导航仍可使用。URL 交接不返回可用于应用内 ETA/矩阵的结构化道路结果。Google Maps URL 不需要 API key，见 [官方文档](https://developers.google.com/maps/documentation/urls/get-started)；Apple 见 [官方 Maps URLs](https://developer.apple.com/documentation/mapkit/unified-map-urls)。

旧结果/定位失效/不可达/限额/缓存过期均明确处理。现有 OSM 底图继续署名；道路供应商的展示/缓存政策必须核验，[OSM 瓦片政策](https://operations.osmfoundation.org/policies/tiles/) 和 [Google Routes 政策](https://developers.google.com/maps/documentation/routes/policies) 保留。仅交接导航不新增道路后台，第三方在线依赖与本站后端分别记录。

保存 scope/dataset/stop/origin/query/viewport，返回核验当前用户和站点；handoffRequested/returned 不代表导航启动/到站。定位可交给地图应用；未安装/失败提供另一应用/浏览器地图/复制地址。配送终态继续手动。

## 派送计划与提醒

`PlanSnapshot` 保存 scope/dataset、planId/revision、仅 pending 的站序、服务日期、IANA 时区、每站时间窗/服务时长与来源。原 CSV timeWindow 字符串不能直接承担真实调度；无法解析/缺失窗口要显式标记 unknown，不能编造截止时间。用业务时区解析窗口，用可注入时钟和定位来源计算风险，跨午夜与 DST 单测覆盖。

单独维护 activeStopOrder/nextStop；列表计划顺序与地图编号一致，最近距离继续标为直线距离。优化器使用道路矩阵、时间窗、停留时间和固定/已完成站约束，先构造可行解，再做有界优化；30 站作为现有工作负载，扩大容量须重新冻结预算。模型不创造路线数值。状态区分可行、部分不可达、搜索预算耗尽与已证明约束冲突；启发式未找到方案只能表达“本次未找到可行方案”，不能声称已证明无解或全局最优。每个可应用方案逐站验证覆盖与约束，失败不能标为已优化。

`PlanProposal` 包含 baseRevision、inputFingerprint、scope/dataset、站点集合、位置/时间版本、expiresAt、原/新指标与计算来源。应用事务再次检查完整输入：用户/批次、pending 集合、终态、当前计划、位置/时间有效性和服务配置；任一变化使提案失效。双击只应用一次；落盘失败不改 UI。Undo 只允许 proposal-applied revision 未变化且输入仍有效；发生新配送/调序时拒绝旧 Undo，改为重新计算。

调序仅改计划，不能改 Stop 终态、完成数量、失败原因或创建/清除配送 outbox。计划成功落盘后再发进度事件；重启恢复同一版本。若未来同步共享计划，用独立的幂等计划提交合同，不复用配送结果 outbox。

提醒由风险规则触发：截止风险、下一个 pending 站、路线/登录不可用。按 scope+serviceDate+stop+windowId+rule 稳定键去重与暂缓，planRevision 仅校验新鲜度；普通重算不能重复弹出或重置 snooze，设置可持久化；终态、换账号和提案过期清理对应提醒。首版优先前台提醒，授权后可用本地通知；未授权不循环申请，通知锁屏内容按隐私设置最小化，不能声称后台持续精确跟踪。恢复前台重新计算计划与通知，时区/时钟变化重算。

## AI 服务与权限

本期采用 View/ViewModel → AssistantUseCase → AssistantExecutor → LocalAssistantExecutor/AgentCore → ModelPort/ToolPort。AgentCore 纯 Dart，不依赖 Flutter、SQLite 或系统插件。未来 RemoteAssistantExecutor 访问 Go Agent，复用 v1 JSON 协议/工具 schema/错误码/合同案例；页面、客户端 Apply 事务与提醒分发继续复用。详见 [AI 单项方案与迁移步骤](next-phase/assistant.md)。

Go modelproxy 本期只保护模型 secret、身份/配额/预算/取消，不执行 Agent loop。工具仅 getNextStop/getDeliveryRisks/previewPlan，没有 completeDelivery/clearOutbox；执行器注入受信 scope，本地工具验证当前快照，远端读取仍由 Go 独立授权。相同 EffectiveSnapshot 排除本地已完成/远端 pending，clientReported overlay 不充当 ACK；返回附 inputFingerprint、来源、时间与事实，旧 scope/generation/fingerprint 拒绝。

本期验收 Local→受控 Remote adapter 的协议/事实/拒绝等价及核心依赖边界，不称真实 Go Agent 已交付。后续 Go 运行器独立重建服务端权限、校验 overlay，完成真实服务验收再按 workspace 切换；remote 失败禁止静默 local 重放。工具预算/轮数/配额/总时限/取消/日志脱敏按 NP00 冻结。离线只显示可访问缓存事实，模型不可用不阻塞普通配送。函数调用背景见 [官方文档](https://developers.openai.com/api/docs/guides/function-calling)。

## Harness 与实施顺序

下一阶段使用 NP-R01–NP-R17、NP-R19 与 NP00–NP15（NP-R18/NP16管理项已取消） 独立命名空间，不改写旧 R01–R17/已接受任务。此次增加的静态检查验证需求覆盖、无环依赖、共享写域、计划状态、命令分类和 issue 正文/发布身份；纳入原型源码与方案指纹。它验证任务包结构，不证明新功能已实现。新增 host/native/live 检查均 planned。

```mermaid
flowchart LR
  NP00[NP00 合同/外部配置] --> NP01[NP01 Harness 新协议]
  NP01 --> NP15[NP15 Go 平台/协议/迁移]
  NP15 --> NP02[NP02 Go 用户/登录/会话/ACK]
  NP02 --> NP03[NP03 账号数据隔离]
  NP03 --> NP04[NP04 登录生命周期]
  NP03 --> NP05[NP05 第三方道路直连]
  NP04 --> NP06[NP06 基础外部导航]
  NP05 --> NP07[NP07 计划应用/撤销]
  NP07 --> NP08[NP08 提醒]
  NP07 --> NP09[NP09 客户端可迁移执行器]
  NP04 --> NP10[NP10 页面/装配]
  NP06 --> NP10
  NP08 --> NP10
  NP09 --> NP10
  NP10 --> NP11[NP11 独立回归/恢复/AI评测]
  NP11 --> NP12[NP12 原生验收]
  NP12 --> NP13[NP13 真实服务联调]
  NP13 --> NP14[NP14 真机性能/交付对接]
```

NP01 扩展现有 native 合同、fixture、可观察工具和门禁，支持新验收 ID 与服务配置指纹；当前 Runner 只有旧 N1–N7，不能用它们代签登录/导航/Agent。要求账号 A/B、超时/撤销/旧回调、在途 ACK、路线失败、错 scope、stale plan、原子应用失败、时区、重复提醒、注入和限流等确定性 fixture。独立原生进程检查需真正杀进程重开，记录数据库/站序/operationId、导航系统返回及原始 trace；真实企业 SSO、道路/模型服务与物理设备另签 NP13/NP14。

NP15提供Go与受控PostgreSQL基线，NP11加入可信首次登录并发、本人用户/数据归属、会话轮换/UTC过期/恢复、Local/Remote-fixture协议替换及路线直连反例。B端/用户管理已取消，不保留管理原型审批或后续实施任务。NP11 用 held-out 故障与对抗样本测“正确/拒绝/恢复”，记录逐案例判定、输入来源、模型/服务配置版本、工具参数与预算；网页、fixture、debug、模拟器和真实服务证据分别表达。运行报告沿用候选前后指纹、设备/资源租用、精确 attempt 路径、原日志 hash；旧报告只作为 historical，不复签当前候选。取消工具任务时只清理自有后代与租用，保留已落盘记录，恢复创建新 attempt。

首次产品派工前 NP00 要确认身份 issuer/client/redirect/scopes、业务授权和 ACK、供应商/缓存许可、数据时区和窗口、服务实现源、模型/隐私/配额、设备/容量/性能预算。外部值未取得则对应任务 blocked，不妨碍已准备好的合同校验与 fixture 工作。真正执行仍须另有产品实施指令。

已有 [#31 真机性能](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/31)、[#32 强制发布门禁](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/32)、[#33 真实资源/签名/发布](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/33) 保留。NP14 提供本轮增量证据并交给这些任务；旧 issue 的通过不会自动证明新功能。生产继续 no-go，只有实际 H01–H08/G0–G6、外部资源、强制执行与交付授权全部满足才可能解锁。

NP14 对 #31/#32/#33 是非阻塞证据交接引用；它不等待发布任务完成才产生发布前证据。生产门禁仍要求这些任务实际满足。

## 审查补充合同

EffectiveSnapshot 的基线是 assignment/serverSnapshotRevision，带明确 clientReported 的 localRevision、未同步终态及 activePlanRevision。查询、提醒与优化共用该快照；远端刷新不得覆盖未确认的本地结果、失败原因、note、operationId 或 outbox。冲突显式显示并重新计算提案，事实区域仅展示来源校验后的结构化数值。

退出、授权失效、切换与开始新认证均推进 sessionGeneration；原 AccountScope 与持久 operationId 不因此改变。只有尚未超时且匹配原请求的 ACK 能在开放的隔离旧容器收尾；超时后的迟到结果不进入确认路径。旧 refresh/登录回调绝不保存新凭据或复活会话。

提醒稳定键还包含 dataset；同窗口 snooze/关闭状态跨计划重算保留，风险升级按明确规则触发。换号取消旧账号可见提醒和系统通知，保留其设置、去重和暂缓记录。路线结果包含 requestedDepartureAt/arrivalAt、durationModel/trafficAware 与可取得的 roadDataVersion，多站 ETA 含等待/服务时长；NP00 冻结定位年龄/精度与重算阈值及目标 OS 的 Apple URL/兼容方式。

B1 去重记录保留期覆盖最大允许离线期与重试周期；401 暂停待原账号重认证，403/撤权、业务冲突或永久拒绝进入需处理状态，保留结果/outbox/拒绝依据并停止自动重复发送。网络、限流和暂时服务故障按预算重试；拒绝不能生成 ACK。NP00 冻结优化能力由现有服务、外部服务或维护算法提供，不因此自动新建求解平台。
