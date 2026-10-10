# Ocean Delivery 本地原生基线

这是用于验证执行 Harness 的 Flutter 客户端基线：读取整份 30 站 CSV，显示列表和详情，把完成/失败状态与 outbox 事件事务性保存到 SQLite。失败原因必填；保存失败保留表单输入并允许重试。不是完整地图产品，也没有生产配送服务。

`lib/main.dart` 注入原生 sqflite factory、asset loader、Repository 和 SyncCoordinator。正式入口使用 `UnavailableTransport`；页面明确显示“本地客户端 · 服务待接入”。同步失败保留本机队列，不显示已上传。

## Host 检查

在 `app/` 运行：

```sh
flutter test --no-pub test/widget_test.dart test/ui/delivery_view_model_lifecycle_test.dart --reporter expanded
dart analyze lib/main.dart lib/app lib/ui lib/harness_probe.dart test/ui test/widget_test.dart
dart format --output=none --set-exit-if-changed lib/main.dart lib/app lib/ui lib/harness_probe.dart test/ui test/widget_test.dart
```

Widget 测试使用内存仓库 fixture 和真实 UnavailableTransport/SyncCoordinator，覆盖初始错误、完成/失败保存、失败输入保留、重试、队列反馈、保存成功后刷新失败，以及 390 × 844 的键盘滚动。另有受控 completer 生命周期回归：关闭停止新操作、等待在途加载/保存/同步确认、阻止后续刷新，再一次性关闭仓库。它们不证明原生 SQLite 插件或进程恢复。

## 独立原生探针

`lib/harness_probe.dart` 是单独的测试启动入口；正式 `main.dart` 不引用它。探针使用相同的 SQLite Repository 和业务资产，只有探针使用 `FakeSyncTransport`。构建与原生进程操作由主控执行，并遵守后台和资源 lease 约束。

一个隔离的数据容器中，主控应启动三次独立 OS 进程，在每次报告成功后终止进程，然后保留应用数据再次启动。Hot reload/restart 不能代替进程重开。不要在这三次之间清数据、卸载应用、重置探针 manifest 或更换数据库。

报告位于原生 `getDatabasesPath()` 返回的目录：

- `ocean_delivery_harness.sqlite`：与正式客户端 `ocean_delivery.sqlite` 分开的测试业务库。
- `harness-probe-manifest.json`：首进程原始 queue 的 seq、operationId、datasetId、stopId、status、reason，以及首/恢复进程 ID。
- `harness-probe.json`：本次 phase、pass、processId、operationIds、queueCount、reason、事件和失败详情。主控必须等待本次期望 phase，不能把上一进程的报告当作本次通过。

| OS 启动 | phase | 通过条件 |
| --- | --- | --- |
| 首次 | `saved` | 导入 30 站，完成一待配送站、失败另一站；保存原 operationIds、失败原因和 2 条待发队列 |
| 第二次 | `recovered` | 同一文件库核对原 IDs/seq/原因/两条待发事件；fake 串行发送并持久确认，beforeQueueCount=2、afterQueueCount=0 |
| 第三次 | `confirmed` | 再次重开后 30 站与原终态/IDs/原因保留，队列为空且不再发送 |

报告只证明对应原生执行和测试传输的本地可靠性；真实服务、真机体验、性能和生产 Harness 门禁仍需各自证据。
