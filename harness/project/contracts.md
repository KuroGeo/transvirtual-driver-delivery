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

主控维护 `harness/run.py` 与 `checks.py`，提供 preflight/check/pub/quality/test/build/native/integration/gate、配置化隔离执行、source fingerprint 和实际日志/manifest；不依赖个人 skill 安装路径。独立工程 Agent 维护 `state.py`、`gate.py` 和对应 unittest。运行记录与锁在 runs；工具 lease 用 OS 文件锁，不猜活 Agent 是否已经结束，Agent 写域由主控实际 runtime 核对。

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

## E08 / X03 原生验收与证据合同

完整本地功能验收采用 [原生检查合同](native-acceptance-contract.json) 的 revision6：N1–N7 共34个明确检查，与 R01–R14 逐项绑定。默认 probe/startup/workbench smoke 继续保留各自范围，不能提供完整 G2。独立验收 driver 走相同私有工作台入口、正式 App、原生 SQLite、真实 UI 和三次 OS 进程启动；只读 snapshot 不提供业务变更方法。

共享写域分别为：主控维护 run.py/CLI/合同/固定双击手势与聚合交付；原生验收负责人维护 acceptance_driver/native_acceptance_support/native_driver_support；原生宿主负责人维护 native.py/native_workbench.py 与对应回归；门禁负责人维护 gate.py 与对应回归。所有源写入者冻结后才执行 quality/pub/build/native。测试候选验证原目录和隔离副本的前后指纹，原始失败不会被下一次运行覆盖。

独立 driver 明确选择 `--scenario N1..N7`。运行时/设备类型必须存在于实际 CoreSimulator inventory，宿主只创建、设置、终止和删除任务设备。系统 text size 与 Reduce Motion 设置回执不能替代 App 实际 MediaQuery；2x 字号、disableAnimations、OS 键盘 Insets/截图/可点击 Save 区域均须实际观察。iOS 没有 Android hardware Back，表单和来源返回仍需真实 UI 操作。验收阶段上限300秒、宿主 driver330秒，UI 动作8秒、观察条件15秒、产品同步超时5秒；默认 smoke 上限保持原值。

冷启故障只能在 saved PID 已退出、recovered 尚未启动时修改当前任务数据库的 delivery_settings 视口列；保留前后 SQLite backup，并证明 online/批次/站点/outbox/ACK 未变。故障类型为 corrupt 和 nonfinite，不能构造不存在的 viewport_json 或外国批次来替代真实 schema。迁移故障只能在真正的 v1 fixture 上用具名 SQL trigger，失败后保存 v1/schema/seq/业务状态；移除该 trigger 后通过实际 Retry 升级同一文件，不清库。

双击终态检查用私有 `DoubleComplete` 指令：固定查找 detail-complete 的真实中心，在一个 Driver 命令中顺序发送两次 pointer tap，不接受 host 提供 finder/坐标/业务参数；回执记录完成次数与实际间隔，之后验证仅一条不可变结果与 outbox 事件。普通 Driver 点击、文本模拟与实际 OS 键盘分别记录，不替换实现层来让验收通过。

聚合报告绑定原始 runner/collector/编译产物清单、各 phase receipt、action/observation JSONL、只读快照、OS PNG、SQLite backup/projection、事务/coordinator 与 fixture journals；每份引用重新计算 hash。固定检查语义优先于报告中的 passed 字段和自定义断言。`local-gate` 只判定完整本地 G1/G2/资源合同，始终返回 publish_allowed=false；`gate` 仍要求 H01–H08/G0–G6。两种门禁恢复时都重新检查当前外部证据，不能复用旧 passed 日志。生产真机/许可/签名/远端强制接线保持独立门槛。

## E03 消费 API 冻结（本轮）

`ui/delivery/query/workbench_query.dart` 输出纯 `WorkbenchQuery({search="", DeliveryStatus? status, waitingOnly=false})` 与 `WorkbenchResult(stops, nearest, matchedCount, totalQueueCount, distanceMeters(Stop), awaitsService(Stop))`。`TestReference` 为 latitude=-33.9004、longitude=151.139、headingDegrees=35；查询结果不被地图视口截断。

DeliveryViewModel 暴露 `query/result`、`setSearch/setStatus/setWaitingOnly/resetQuery`；`WorkbenchPanel {map,list,detail}` 和 `DetailOrigin {list,map,nearest}`，通过 `openList/closeList/openDetail(stopId,{required origin})/closeDetail` 操作。`selectedStop` 读取全量 stops；`detailContext` 包含 stopId/origin/列表会话；`listSession` 保存 scrollOffset/focusedReference，经 `rememberListSession` 更新。列表可复用组件 `StopListWorkspace(viewModel:, onOpenStop:, onClose:)` 只发回调，不自行建应用级 Navigator/Repository。

E06/E11/E07 依此消费；E03 开发后主控审查实际 API，签入组件接受记录。视口保存边界为有限 latitude[-90,90]/longitude[-180,180]/zoom[0,22]、当前 dataset；地图使用同一范围，不将合法持久值静默改写。

## 组件消费 API（E05/E06/E11 冻结）

E05：纯 Dart `SyncStage {started,sending,acknowledged,paused,failed,finished}`、不可变 `SyncProgress(stage,runId,confirmedCount,operationId?,error?)` 与监听器；Coordinator `addListener/removeListener`、`progress`，保留 sync/pause/isRunning 与 legacy eventSink。默认 requestTimeout=5s；确认数只在持久 acknowledge 成功后增加，runId 区分前后循环，退出释放 owner 后才能发终结回调，新 owner 不被旧 finally 清除。

E06：`DeliveryMapWorkspace(result,datasetId,onOpenStop(Stop,DetailOrigin),initialViewport?,controller?,tileUrlTemplate,tileProvider?,fitPadding,toolbarTop?,selectedStopId?,onViewportChanged?,onSync?,syncing=false,onAttributionTap?,tileCacheClearer?)`；`DeliveryMapController` 持稳定 MapController、loading/ready/error notifier，提供 zoomIn/zoomOut/fitMatches/locateTestReference/retryTiles/clearTileCache。回调来源固定 map；默认产品交互底图 OSM、maxNativeZoom=19，自动化一律注入任务 HTTP/provider fixture。清瓦片仅删缓存和其 image keys，不动业务数据；根装配按实际安全区域覆盖 fitPadding。

E11：`DeliveryDetailCard(viewModel,onClose)` 读取全量 selectedStop/typed origin，表单启动 `showDeliveryFailureSheet(context,stop,onSubmit) -> Future<FailureSubmission?>`；onSubmit 返回持久提交事实 bool，true 后仅关闭表单并留终态详情。提交已成功但 refresh 失败，详情可保持已知终态和原因/备注的本地只读投影，明确 Reload，未知发生时间/opId 不补造；VM loadError 阻止把旧列表当刷新成功。键盘/系统返回先关表单，再按原来源关闭详情；所有 Repository/Coordinator 仍由根装配单独持有。

## E07 formal assembly consumer contract (revision5 implementation detail)

Root owns main/factory/VM/settings/feedback/assembly and original Carbon helper. `createLocalViewModel({RuntimeConfiguration? configuration, DatabaseFactory? databaseFactoryOverride, String? databaseDirectory, Future<String> Function()? loadCsv, SyncTransport? transport, Duration? requestTimeout, void Function(Map<String,Object?>)? eventSink})` wires the same production Repository/settings/coordinator. Default local-client Unavailable, demo DemoTransport720ms; optional overrides are explicit dependency injection, never selected by mode accident. `OceanDeliveryApp` accepts first-mount `tileProvider`, `tileUrlTemplate`, optional externally-owned `mapController`; formal main supplies no driver/fault source.

VM constructor adds optional `settingsStore`, `mode` (ClientMode.localClient), `automaticSync=false` for component hosts; formal factory explicitly enables true. VM exposes `settings` (nullable until initialized), `online`, `isChangingOnline`, `settingsError`, `canRecord`, `hasUnrefreshedResult(stopId)`, `notice` (ValueNotifier<WorkbenchNotice?>), `syncProgress` (ValueNotifier<SyncProgress?>), `setOnline(bool)`, `saveViewport(MapViewport)`, `retrySettings()`, `showNotice(message,{kind,persistent})`, `clearNotice(id)`. Durable enqueue/reconnect/manual triggers all reach coordinator.sync; UI joining does not suppress a wakeup. Settings writes serialize and publish flags only after commit. Close awaits all own storage/sync operations. Successful submit plus failed read retains only known terminal/reason/note in VM until Reload; unknown op/time/ack are never invented, all record actions stay disabled while snapshots stale.

Single writers delegated by root for E07 consumer integration: E03/E06 owner may modify only map/list workspace + their tests; E11 owner only detail card + its tests. Map may add `overlayBuilder(context,constraints)` inside its map area excluding always-visible attribution footer, `showTools=true`, and explicit controller `focusStop(Stop)` using current fitPadding. 用户2026-10-11模拟器复核修正：工具在出现时始终为44px单列，Sync同宽，Browse打开仍隐藏工具。用户显式点击顶部状态Tab后关闭详情，在下一帧将当前匹配站点与固定测试参考位置共同取景，maxZoom14；保留搜索与Waiting交集。普通查询状态通知、异步同步/确认和Toast不触发取景。双触点缩放在实际地图手势通路验证，不能以InteractiveFlag静态配置代替。Browse默认按原型Stops on the map底部列表；架构附加查询通过list-query-controls显式展开，保留原有keys与会话恢复。Selection is an explicit user camera action; transient notices/query/ack updates never focus or move camera. List adds optional `onSync` action/key `list-sync`, no queue drawer. Existing component tests and native proof rerun after all source freeze.

Root UI stable keys: `online-toggle`, `open-search`, `map-search`, `map-clear-search`, `header-filter-all/pending/completed/failed`, `browse-stops`, `nearest-stop`, `map-waiting-only`, `workbench-notice`, `notice-message`, `reload-data`, `clear-map-cache`, `attribution-link`. Existing map/list/detail/failure keys remain. Native instrumentation will import the same factory/App from integration_test; no product lib import beyond app/lib.

E07 independent test delegations: TE07F exclusively writes formal_workbench_test.dart/formal_workbench_fixture.dart; TE07W exclusively rewrites widget_test.dart. Root retains all product, main/factory, models and matrix ownership. Test authors consume frozen parameter/key contracts and report actual regressions, without executing shared pub/test/build while any source author is active.

E07 geometry repair extension: Map accepts `showTileError=true` and optional `fitPaddingBuilder(BoxConstraints)` evaluated only on explicit focus/fit using the measured map area excluding footer. Formal host owns a bounded combined tile-error/notice region beside tools; list reserves a separate 88px feedback lane; card height/focus padding derive from the same measured area. Settings errors clear only their matching committed write, so successful viewport persistence cannot hide a failed Online retry. Bootstrap reserves one opening Future synchronously before factory execution.

E07 cached-tile repair: a local synchronous ImageInfo fixture reproduces pinned flutter_map8.3.2 instantaneous pruning against the old inherited camera during a fit event; strict standalone and workspace failures retain their source/hash evidence. Synchronous completion remains a valid cache boundary. The map owner implements a private, stable, per-subscription frame-aligned TileUpdateTransformer: coalesce the latest non-tap event until the camera frame has rebuilt, then synchronously deliver loading/pruning; preserve map/controller/provider lifetime and latest user position. Cancellation drops pending events and cancels input; pause/resume/done/error remain observable. No arbitrary delay, full-map reload, fixture weakening or public test-only product API. A named stock dependency characterization is separate from the unchanged positive workspace readiness/geometry gate. Independent review and fresh quality must accept the candidate before E07 closes.

## X02 controlled native workbench interface

E07 formal source is accepted. X02 may add private instrumentation under `app/integration_test/` and a background-only Harness native workbench scope; formal main cannot import the driver/instrumentation. Public build entrypoint restrictions remain. Root owns this shared interface; Python orchestrator and Dart bridge/driver have distinct writers. Existing probe/startup and production gates retain their meanings.

- `native --scope workbench` builds the fixed private `integration_test/workbench_entry.dart`, leases app-workspace plus task iOS device, supplies localhost tile URL before first App mount, and drives the actual formal App/factory/SQLite through an external FlutterDriver. Its default `integration_test/workbench_driver.dart` is X02 tooling smoke, not E08 full acceptance. A future independent driver may be explicitly selected with a validated existing integration_test Dart target; probe/startup reject driver targets.
- Bridge accepts only readonly `snapshot` requestData (unknown commands fail). Schema1 includes process ID, candidate passed by task launch, runtime mode/transport label, formal model/load/save/sync/settings/query/panel/detail origin/stops/result/outbox membership, map camera/tile readiness, actual logical screen/textScale/safeArea/viewInsets/reducedMotion and keyed rendered bounds where needed, plus actual repository/coordinator journal. Observation may read business state and event history; it may not submit, sync, set query/online, close cards or manipulate UI. App actions use actual keyed tap/scroll/text/back through driver.
- Process-launch-only configuration uses the fixed `Documents/native-workbench-launch.json` in the verified task-owned container, atomically written before each launch after the prior process has terminated. Schema1 contains mode (demo/local-client), candidate, session (fresh nonce), tileUrl and optional syncUrl; the private Dart entry reads bounded JSON from actual getDatabasesPath before first App mount. The host records its digest and path; PID/VM/snapshot/session must agree. Actual iOS execution did not expose the assumed SIMCTL_CHILD values to Dart, so configuration no longer depends on environment forwarding. No business mutation is available through this input. Normal CSV is the actual approved30-stop asset; test-only transport is injected through existing factory override, default local-client has no transport override. `demo` fixtures are labelled simulated. Mode database names remain isolated; OS restart does not clear or reimport data.
- Local HTTP fixture serves controlled tile PNG/503 and captures immutable sync requests. Matching ACK release, wrong ACK or never completing request are explicit fixture states; actual coordinator timeout stays5s. Host controls operate fixtures, not app business/query/UI state. Both host-control and simulated sync POSTs send exact UTF-8 bytes with explicit Content-Length; ambiguous/chunked/oversized/incomplete framing fails before any fixture mutation, with bounded token-filtered raw error receipts. Native SQL triggers may be installed only in a verified path beneath the newly-created simulator/app data container. No fixture may touch user devices/containers or invent an acknowledged result.
- Native lifecycle uses explicit task simctl create/boot/install/launch/terminate/relaunch receipts, fresh native PID plus launch session nonce matched to bounded VM connection, readonly snapshot and same-session journal, same installation/data for cold recovery, actual SQLite backup+event journal and keyed driver action logs. All long-lived descendants inherit resource lock FDs; cancellation reaps owned drivers/services and removes only the created UDID. All observation/action deadlines fail rather than warn/return success.
- X02 retains raw actions/observations, simctl receipts, PNG, PID/data/transport/source identity and optional debug trace sample. Keyboard text entered through emulation and actual OS keyboard geometry/screenshots are separate labels; reduced motion/text accessibility settings reflect actual observed MediaQuery. Debug/simulator trace is not G3 physical performance. X02 author cannot self-sign E08 business acceptance; current production no-go persists.

## 原生观察协议 revision6

Issue/任务拆分合同仍为 revision5；原生34项协议单独升为 revision6，保留全部检查ID与需求绑定。锁定Flutter的iOS引擎将系统Reduce Motion写入`dart:ui.AccessibilityFeatures.reduceMotion`，不会设置`MediaQuery.disableAnimations`。原生只读桥保留两项实际值；iOS门禁必须验证实际平台reduceMotion=true及系统设置/语义证据，不能靠MediaQuery覆盖值或设置命令通过。产品同步旋转与失败表单转场需响应该真实标志，Android继续使用其实际disableAnimations。见[Flutter官方属性说明](https://api.flutter.dev/flutter/widgets/MediaQueryData/disableAnimations.html)。此前失败证据保持原样，不按新协议回签。
