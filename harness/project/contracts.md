# 当前实施边界

用户授权补可执行 Harness、整理目录，要求复杂度恰到好处。建立本地原生可靠性基线来验证工具闭环；不把完整地图工作台、真实服务、真机性能或生产发布写成已完成。

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

工具证据合同 revision=4：G1 的 evidence kind 为 `quality-run`，引用 run.py 的原始 quality report；其前后候选必须一致，job 与 repository/tooling-tests/sdk/format/analyze/flutter-tests 各阶段通过，原始日志 hash 可核验。恢复和交付不以 entry 中的 passed 声明覆盖失败或旧报告。

这是执行合同，源码中的具体问题由负责人回报主控协调；不为实现习惯临时扩框架、平台或产品功能。
