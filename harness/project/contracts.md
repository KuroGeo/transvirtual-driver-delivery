# 当前实施边界

合同 revision=5。用户授权先发布完整原型 Flutter 的父/子 Issues，并按原型和架构推进功能。已有本地原生可靠性基线作为复用输入；本轮仅完成 Issue 计划，不把完整地图工作台、真实服务、真机性能或生产发布写成已完成。任务来源和执行接力见 [issue-plan](issue-plan.md)。

Flutter 3.44.2 / Dart 3.12.2；`app/` 是客户端，`harness/` 是项目执行工具与合同，`.agents/skills/` 是职能 skill，`harness/runs/` 是忽略的逐次原始运行记录。产品来源仍在 `docs/` 与 `prototype/`。

## 原生基线接口

- `models/delivery.dart`：纯 Dart 的 `DeliveryStatus { pending, completed, failed }`、不可变 `Stop`、`PendingUpdate`、`Ack`。Stop 字段 `id, reference, customerName, address, latitude, longitude, status, reason, operationId`；PendingUpdate 含 `seq, operationId, datasetId, stopId, status, reason`；Ack 含三项身份 `operationId, datasetId, stopId`。
- `data/delivery/delivery_repository.dart`：接口 `initialize()`, `loadStops() -> Future<List<Stop>>`, `submit(String stopId, DeliveryStatus status, {String? reason})`, `pendingUpdates() -> Future<List<PendingUpdate>>`, `acknowledge(Ack) -> Future<bool>`, `close()`。
- `data/delivery/sqlite_delivery_repository.dart`：构造参数 `databaseFactory`, `path`, `loadCsv`（`Future<String> Function()`），可选 `eventSink`（`void Function(Map<String,Object?>)`）；使用 sqflite DatabaseFactory 注入 host/native。首次整份校验导入、终态条件更新＋outbox 同事务、匹配 ack 持久确认，文件库重开不重导。故障测试使用受控 SQLite trigger，不另造故障框架。
- `data/delivery/sync_coordinator.dart`：`SyncTransport.send(PendingUpdate) -> Future<Ack>`；`UnavailableTransport` 默认，测试专用 `FakeSyncTransport`；`SyncCoordinator(repository:, transport:)` 提供 `sync()`, `pause()` 与 `isRunning`。单循环串行确认，失败保留、finally 释放。
- UI/ViewModel 只依赖数据契约，SQLite/CSV 映射留在数据实现；启动装配注入 sqflite factory 和 asset loader。

默认客户端表达本地已保存、待服务，不伪装上传。独立 `lib/harness_probe.dart` 原生测试入口才使用 fake：首进程保存两项，OS 真终止后下一进程核对原身份/原因/队列并串行模拟确认。输出 JSON 到业务库同目录，包含 phase、pass、operationIds、队列与事件；不自动发送客户数据，不改正式启动入口。

## 工具接口

主控维护 `harness/run.py` 与 `checks.py`，提供 preflight/check/quality/build/native/gate、source fingerprint 和实际日志/manifest；不依赖个人 skill 安装路径。独立工程 Agent 维护 `state.py`、`gate.py` 和对应 unittest。运行记录与锁在 runs；工具 lease 用 OS 文件锁，不猜活 Agent 是否已经结束，Agent 写域由主控实际 runtime 核对。

`state.lease(resources, run_dir, lock_root)` 上下文管理器独占资源；`state.validate_resume(report, candidate)` 拒绝候选变化/未释放 lease；实际中断与恢复须实跑。`gate.evaluate(manifest, current_fingerprint, base_dir)` 返回 `{allowed, reasons}`，验证生产所需 H01–H08 / G0–G6、当前候选与原始证据/hash、对应层级和产物；缺失/未知/失败/旧证一律不通过要求它的交付。

已实现工具证据合同 revision=4：G1 的 evidence kind 为 `quality-run`，引用 run.py 的原始 quality report；其前后候选必须一致，job 与 repository/tooling-tests/sdk/format/analyze/flutter-tests 各阶段通过，原始日志 hash 可核验。恢复和交付不以 entry 中的 passed 声明覆盖失败或旧报告。

## 完整产品增量：行为冻结与实现责任

当前源码接口继续有效；以下是本轮行为合同，具体 API 名称由 E00 的唯一接口负责人冻结，再交消费者开发，不表示这些字段或工具已经实现。

| 生产者 / 唯一写入者 | 输出与不变量 | 消费者 |
| --- | --- | --- |
| E02 models/Repository/schema/settings | time_window、失败备注/结果时间与必要确认投影；不可变提交快照；真实 v1 增量升级保身份/终态/outbox；少量 demo online 与 dataset/center/zoom 设置，设置失败不改变业务事务 | E03/E05/E06/E11，装配 E07 |
| E03 query/ViewModel/list | 搜索×状态×架构 Waiting only 的同一结果；全局/匹配计数、参考位置 Haversine 稳定排序/最近项；会话滚动与焦点，不在 build 反复计算 | E06 地图、E11 来源详情、E07 |
| E05 coordinator/transport | 显式 demo、默认 unavailable，单循环 seq/匹配确认、真实超时和退出唤醒、有界关闭；进度基于持久确认，不放数据库 SQL | E07 Toast/按钮、E04/E08 |
| E11 detail/failure | 来源 list/map/nearest，终态保存后留详情，表单校验/错误保草稿，返回恢复上下文；不写共享主题/schema | E07 导航装配、E08 |
| E06 MapView | 原坐标/状态聚合，读取查询结果、初始视口，发出手势结束视口回调；不访问 SQLite，不因 Toast 重置控制器 | E07 注入设置与导航、E08/E09 |
| E01 → E07 装配/主题/lock/导航 | E01 先独占共享配置；各开发归还写域后 E07 串行装配。原型本地品牌、明确运行配置、SafeArea/键盘/缩放 | 所有 UI；X00/X02 执行入口 |
| X00/X02 → E08/E09 | 统一 lease 的配置执行、完整产品后台 UI/进程/trace 观测；现有 native 仅 probe、test --target 仅 app/test，新增命令落地后更新使用说明 | 独立原生/性能职能 |
| X01 → X03 → X05 | 事实/依赖/需求映射检查 → 本地 gate 对完整需求/原始性能/资源证据校验 → 实际远端强制接线；本地 validator 通过不代表 enforcement deployed | X04 恢复评测、E10 本地交付、E12 生产门槛 |

E04 独立回归先审组件，再在 E07 集成候选重跑；E08/E09 对精确候选独立签原生/真机层。E10 是新增的本地 demo/client 交付任务，原产品图 E10 的生产责任移入 E12，门槛保留；生产 no-go 不以更名或局部关闭绕过。

这是执行合同，源码中的具体问题由负责人回报主控协调；不为实现习惯临时扩框架、平台或产品功能。
