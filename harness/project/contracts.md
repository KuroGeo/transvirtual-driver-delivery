# 当前实施边界

合同 revision=5。父/子 Issues 已发布，用户将会话/sub-agent 编排交主控，当前进入完整原型 Flutter 实施。已有本地原生可靠性基线作为复用输入；实现/测试/原生/真机与生产完成分别取证。任务来源和执行接力见 [issue-plan](issue-plan.md)。

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

## E00 冻结 API（2026-10-10）

- `models/delivery.dart`：Stop 新增可空 `timeWindow, note, recordedAt, acknowledgedAt`，PendingUpdate 新增可空 `note, recordedAt`；时间统一 `DateTime`/UTC，SQL 映射由数据层负责。历史缺失时间/备注保持 null，不编造。
- `DeliveryRepository.submit(stopId, status, {reason, note})`：note 为可选命名参数；结果/原 operationId/发生时间/note 的不可变快照同事务保存。Other 由表单转换为真实原因后提交，不保存字面 Other。数据负责人同时适配已有测试 Repository 替身签名，查询 Agent 不改该旧测试文件。
- 新的纯模型 `models/workbench.dart` 定义 `ClientMode { demo, localClient }`、`MapViewport(datasetId, latitude, longitude, zoom)`、`DeliverySettings(datasetId, online, viewport)`；settings 缺失默认 demo online=true，视口 null。loadSettings 初始化后必须返回当前 datasetId，saveViewport 拒绝不同批次视口。connected 不在本轮。地图固定参考位置来自原型配置，须明示 Test reference。
- `data/delivery/delivery_settings_store.dart` 是独立契约：`Future<DeliverySettings> loadSettings()`, `Future<void> saveOnline(bool)`, `Future<void> saveViewport(MapViewport)`；SqliteDeliveryRepository 同时实现它。ViewModel 通过可选 settingsStore 注入；旧 Repository 替身不必增加设置方法。settings 与业务共库、表与事务分开，保存失败不先宣布持久切换成功。
- schema v2 增量升级：保 datasetId/stopId/operationId/seq/终态/队列；time_window 仅在已识别 asset 的 reference/名称/地址/坐标匹配时安全回填，其他旧值保 null。旧 note/time 无从恢复不补造。初导入要求原题七列；迁移失败不清库，回滚后可重试。
- Query/会话由 E03 写：`WorkbenchQuery(search, status, waitingOnly)` 与 `WorkbenchResult(stops, nearest, matchedCount, totalQueueCount)` 位于 UI 查询边界；默认 All/空搜索/Waiting off。list/map/nearest 来源为类型化枚举，会话滚动/选中 reference 保存；冷启不恢复搜索/筛选/临时卡片。UI 不导入 SQLite/CSV。
- E03 owns DeliveryViewModel 和查询/列表；E11 owns detail/failure，E06 owns map，均通过明确参数/回调消费 ViewModel，不各自新增应用级状态。UI/Map 配置要求先交 E03 或主控，不越界写其文件；E07 接收写域后整合唯一 VM/Coordinator。
- `SyncCoordinator` 保留 `sync/pause/isRunning`，E05 增加有界 requestTimeout 和纯 Dart 事件监听；进度只统计持久确认。ViewModel 订阅事件更新局部进度 notifier，不在数据层引 Flutter。demo 显式 fake，local-client 默认 unavailable 且 UI 不伪发送/清队列。
- 显式启动 `--dart-define=OCEAN_MODE=demo`；缺省或 local-client 选择 UnavailableTransport。默认 local-client 保留旧文件名 `ocean_delivery.sqlite`，demo 独立 `ocean_delivery-demo.sqlite`；不复用默认队列给 fake 确认。正式产品仍 `lib/main.dart`，窄 probe 保持独立。E01 仅注入运行模式/品牌壳，E07 接线完整 settings/query/map。
- iOS simulator 是本轮 G2 首目标，iOS26.4 专用任务设备后台 CLI 操作；真机 profile/release gate 仍 blocked。基础样本30站；性能另加约定密集负载，预算在 E09 指定设备测量前冻结，不能从30站样本预签容量。

共享写域：主控/E01 独占 pubspec/lock/资源/主题/启动装配；E02 独占模型/Repository/schema/settings及旧测试替身签名；E05 之后接协调器/transport；E03/E11/E06 按上述边界并行。构建/安装/依赖操作串行租用 workspace/device，独立 Agent 的 host 测试也走 Harness。

E02 的签名适配写域明确增加 `app/test/ui/fake_delivery_repository.dart` 与 `app/test/ui/delivery_view_model_lifecycle_test.dart`，仅改 submit 参数/快照兼容；E03 的新查询测试写独立目录，不同时改这两个文件。E01 阶段用 `app/lib/app/runtime_configuration.dart` 解析模式（尚未依赖 E02 的新模型），E07 装配时将其映射到 ClientMode，避免 E01→E02 的接口循环。

这是执行合同，源码中的具体问题由负责人回报主控协调；不为实现习惯临时扩框架、平台或产品功能。
