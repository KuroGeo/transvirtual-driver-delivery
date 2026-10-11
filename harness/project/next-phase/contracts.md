# 下一阶段合同 revision 2

本包为 prepare，与旧 Flutter parity/revision 5–6 分开。业务细节见 [方案](../../../docs/next-phase-solution-design.md)，结构化来源为 backlog 与 requirement-matrix。

## 不变量与外部输入

1. U1：受信 `workspaceId+principalId` 是业务归属，issuer+subject 服务端映射；token、安全回调、数据容器、请求 generation 一致。旧库无归属时先隔离。
2. B1：服务端持久接受原 operationId/payload 后 ACK；客户端匹配 scope/dataset/operationId/stopId 后事务确认才移队列。换号或迟到确认不能接管新容器。
3. R1：道路距离/ETA 必须有 provider/configRevision/computedAt/expiry 与可信起点。导航打开不等于导航中/到站，返回保存来源；终态继续手动。
4. P1：计划独立存储；baseRevision/fingerprint/expiry/完整 pending 集一致才原子应用/Undo，不改终态/统计/配送 outbox。冷启恢复计划同版本。
5. A1：模型只有查询/提案工具；本期客户端独立 Executor/Core/Ports，后续 Go 服务执行同一协议；受信 scope/schema/ID/预算检查，远端读取独立鉴权；来源/时间真实，注入不能拿到配送写工具。
6. T1：提醒规则、可注入时钟、IANA 时区/窗口/停留和道路 ETA；无 ETA 只能提醒窗口临近，去重/暂缓按账号保存。

NP00 冻结 IdP/native client/回调/离线期限/撤权、业务数据与 ACK、服务实现仓库/负责人、地图路线许可/缓存/配额、模型/数据地区/保留/成本、OS/设备与容量性能预算。若实际服务在企业外部仓库，先把对应 issue 写域与候选版本登记后派工，不能假称 service/ 已有实现。

## 写域与交接

backlog.shared_file_owners 是机械单写表；任务 write_scope 必须被一个负责职能认领，目录包含也视为冲突。重叠写域只能沿 DAG 串行接管，不能并行。共享入口/lock/平台工程/主题由 NP10 写；schema/outbox 由 NP03 写；域模型按账号/路线/计划/提醒/助手明确文件各自归属。Harness/CI 由 NP01 先写，NP11/NP12 在后续依赖上接管其约定测试/门禁文件。主控独占 mission/contracts/backlog/work 与 issue 发布身份；NP11 的矩阵修改提交给主控集成。

当前所有任务 planned；owner/candidate/result/evidence 为空，不把资料准备映射为产品 accepted。实际派工后 work 由主控更新；此轮静态 checker 拒绝 prepare 包出现产品 running/passed/accepted。执行模式状态/证据验证由 NP01 增量实现后开启，不删掉校验以绕过限制。

## 验收合同与恢复

新增 host/native/live/device-performance 检查均 planned。最低场景族：NP-A（登录/切换/在途/迁移）、NP-R（路线/导航/来源返回）、NP-P（计划/Apply/Undo/时窗）、NP-T（提醒/权限/时钟）、NP-I（工具权限/注入/取消/预算）。NP01 冻结具体 ID、目标文件、观察事件和 gate schema，当前 Runner 不接受这些新 scenario ID。

每个报告保留原始日志/hash、精确 attempt/report、候选前后身份、服务/模型配置、设备、scope 脱敏标识和数据 provenance。失败/缺项/旧候选/错 scope/网页代签原生/fixture 代签真实服务均拒绝。取消只清理任务自有资源；恢复 fresh attempt 并保留历史字节，已持久配送/outbox 不回退。

NP11 独立测试与 held-out 评测，NP12 原生杀进程与系统交接，NP13 真实企业服务，NP14 物理设备性能并对接 #31/#32/#33；对应层级不能由实现者自己签。production_eligible=false，enforcement_deployed=false；本包不改变发布门槛。

补充冻结项：所有会话失效/退出/重登重置都推进 generation；道路时长注明静态/交通感知与 departureAt；EffectiveSnapshot 将本地未同步结果与服务端快照绑定同一指纹，只用于查询/提案不充当 ACK；启发式无方案不证明无解；提醒使用稳定服务日/窗口键保留 snooze。NP14 对 #31/#32/#33 为非阻塞交接引用，避免等待交付消费者形成循环，生产仍依赖其实际门槛。

B1：去重保留覆盖离线/重试；401暂停、403/业务永久拒绝需处理并留 outbox，不重复轰炸。U1：开始新认证推进generation，超时 ACK 拒收。A1/P1/T1 共用标注 clientReported 的 EffectiveSnapshot，远端刷新不覆盖未确认结果；提醒换号取消可见通知但保留设置与 snooze。NP11 必测本地已完成/服务端pending以及跨重算提醒。

## 2026-10-12 用户架构修正

F1 路线客户端直连第三方，不能新增自己的 routes/matrix/代理/OSRM 服务；ThirdPartyRoutePort 与外部 Maps 交接分开，基础导航不受道路配置阻塞，本站 token/身份不发给地图供应商。

F2 为全站 Go 用户/组织/RBAC/会话/审计，架构见 docs/next-phase/backend-go.md。NP15 单写 service/go.mod/go.sum/cmd/api/internal/platform/api/migrations；NP02 写 identity/session/delivery，NP16 写 authorization/workspace/membership/audit，NP09 写 modelproxy。所有域 schema/OpenAPI 需求提交 NP15 集成；域端不能各建启动或数据迁移。NP15→NP16→NP02→客户端/集成，避免共享写冲突。

F3 本期 LocalAssistantExecutor 与独立纯 Dart AgentCore/ToolPort/ModelPort，未来 RemoteAssistantExecutor/Go Agent。v1 Request/Response 和合同案例必须可序列化、可替换；同一 UseCase/页面/客户端 Apply/设备提醒不随执行位置改写。Go modelproxy 本期只转发受限模型请求，不执行 Agent loop。真实服务端迁移另立后续任务，remote-fixture 不代签。

新增 NP-R17 Go 架构、NP-R18 全站管理授权/审计、NP-R19 执行器迁移。新管理原型为 pending_user_review，不能借已确认司机原型签字；本地草稿继续 draft，远端正文与源码尚未更新发布。
