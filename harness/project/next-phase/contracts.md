# 下一阶段合同 revision 1

本包为 prepare，与旧 Flutter parity/revision 5–6 分开。业务细节见 [方案](../../../docs/next-phase-solution-design.md)，结构化来源为 backlog 与 requirement-matrix。

## 不变量与外部输入

1. U1：受信 `workspaceId+principalId` 是业务归属，issuer+subject 服务端映射；token、安全回调、数据容器、请求 generation 一致。旧库无归属时先隔离。
2. B1：服务端持久接受原 operationId/payload 后 ACK；客户端匹配 scope/dataset/operationId/stopId 后事务确认才移队列。换号或迟到确认不能接管新容器。
3. R1：道路距离/ETA 必须有 provider/configRevision/computedAt/expiry 与可信起点。导航打开不等于导航中/到站，返回保存来源；终态继续手动。
4. P1：计划独立存储；baseRevision/fingerprint/expiry/完整 pending 集一致才原子应用/Undo，不改终态/统计/配送 outbox。冷启恢复计划同版本。
5. A1：模型只有查询/提案工具，服务端注入 scope 并验证 schema/权限/ID/预算；来源/时间真实，注入不能拿到配送写工具。
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
