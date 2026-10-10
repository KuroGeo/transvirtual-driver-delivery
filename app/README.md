# Ocean Delivery 配送工作台

Flutter 正式入口为 `lib/main.dart`，采用地图优先界面、真实 SQLite 和事务性 outbox。功能范围来自现有原型与 [架构设计](../docs/solution-design.md)，具体合同和验证状态见 [Harness 入口](../harness/README.md)。

地图、列表和最近站点共享搜索、状态与待同步筛选；详情按来源返回。完成/失败在本地同事务保存不可变结果与 outbox 事件。失败表单支持预设原因、可选备注与必填的 Other 文本；写入失败保留输入并允许重试。直接同步反馈保留当前查询与详情上下文。

Online 设置和合法地图视口随数据库持久化；冷启重置搜索、临时卡片和列表会话。同步按队列串行执行，仅在匹配身份的确认持久提交后移除 outbox。瓦片错误不阻断业务保存，清地图缓存不清业务数据。真正进程恢复必须重开同一安装文件，不能用 hot reload 或清数据代替。

状态由 `ChangeNotifier` / `Listenable` 驱动：ViewModel 管理查询、面板和短期交互，Repository 管理业务文件、事务与确认队列。当前工作台用明确依赖注入和少量可观察状态，避免为这一范围引入额外状态框架。SQLite 让配送结果与 outbox 同事务提交；串行同步及身份匹配的持久 ACK 让中断后的重试复用原事件。地图瓦片缓存可丢弃，业务文件保留，二者分别管理。

## 运行配置

缺省或 `--dart-define=OCEAN_MODE=local-client` 选择 UnavailableTransport，界面标记 `Local client · service unavailable`。没有实际服务时保存仍保留本机队列，不显示已上传。业务文件为 `ocean_delivery.sqlite`。

`--dart-define=OCEAN_MODE=demo` 使用模拟确认，界面标记 `Demo · simulated confirmations`，业务文件为独立的 `ocean_delivery-demo.sqlite`。demo 不复用 local-client 队列，也不表示客户结果已上传。

批准的开发样本为 assets/deliveries.csv 的30站原始七列；字体、图标和地图依赖许可保存在 assets/licenses。生产业务数据、地图/瓦片与离线服务的使用条件仍需单独核验。

人工交互演示使用独立检出和明确的任务专用模拟器 UDID，在 app/ 目录运行正式入口。先结束占用相同工作区或设备的 Harness 任务，再选择一种配置；不要自动选取用户正在使用的设备。

```sh
OCEAN_TASK_DEVICE_UDID='replace-with-task-owned-simulator-UDID'
flutter run --target lib/main.dart --device-id "$OCEAN_TASK_DEVICE_UDID" --dart-define=OCEAN_MODE=demo
flutter run --target lib/main.dart --device-id "$OCEAN_TASK_DEVICE_UDID" --dart-define=OCEAN_MODE=local-client
```

后台自动启动验证用 `python3 harness/run.py native --scope startup --configuration demo --isolated`；local-client 对应替换 configuration。它从正式入口采集启动 PID 与 OS 截图，结束回收任务设备。完整三进程功能验收使用下面的独立 driver。

## 验证与构建

从仓库根目录运行，使用固定 Flutter3.44.2 / Dart3.12.2 与 pubspec.lock：

```sh
python3 harness/run.py quality --isolated
python3 harness/run.py build --configuration local-client --isolated
python3 harness/run.py build --configuration demo --isolated
```

质量命令包含完整 Harness 回归、依赖锁、格式、分析及全部 Flutter host/widget 测试。构建缺省为无签名 iOS simulator debug；它证明构建，不签真机、性能或生产发布。所有源写入者冻结后执行依赖、测试和构建，workspace/device 操作由 Harness 资源租用保护。

## 原生验收

`integration_test/workbench_entry.dart` 是私有仪器入口，挂载相同正式 App/Repository，但从首次挂载起使用任务 HTTP 瓦片与明确的测试传输；正式 main 不导入它。外部 driver 通过实际 UI 操作，snapshot 桥只读。宿主创建后台任务设备，采集 OS PNG、实际 SQLite backup、事务日志和进程身份，结束后只回收自己的资源。

默认 probe/startup/workbench 是各自的工具或启动 smoke。完整本地功能由独立 acceptance_driver 与 [34项原生检查合同](../harness/project/native-acceptance-contract.json) 判定；没有实际执行与独立审查的组保持未验收。OS 键盘、字号、Reduce Motion 需要实际 Insets/MediaQuery/截图，文本模拟和设置命令成功不能代签。

完整原生运行命令、故障 fixture、恢复与门禁规则见 Harness 入口。iOS simulator 功能、真机 profile/release、实际后端、签名、远端强制门禁与生产发布分别取证；当前生产 no-go。

## 约五分钟演示顺序

使用 N1 的当前原生证据或重新执行以下命令。Harness 创建专用设备并通过真实 UI 操作，OS 终止后重开同一安装，结束回收自己的设备；它不会打开或抢占用户的 Simulator 窗口。

```sh
python3 harness/run.py native --scope workbench --driver-target integration_test/acceptance_driver.dart --scenario N1 --configuration demo --isolated --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4 --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro --timeout 1200
```

1. 第一分钟：展示地图、查询和列表，进入 Offline，说明参考位置与直线距离。
2. 第二分钟：完成一个站点，给另一个站点记录失败及 Other 说明；展示 SQLite 结果和对应 outbox 身份。此时是本地 commit。
3. 第三分钟：查看实际结束进程和同安装重开的两组 PID/截图；结果、Other 原因文本、队列及 Offline 设置保持。此 N1 示例的 note 为 null，不把原因文本称为备注。
4. 第四分钟：切回 Online，查看串行 HTTP 模拟确认和持久 ACK 后排空；重试复用原 operationId/seq。
5. 第五分钟：第三个实际进程不再重发。对照 local-client 的 N1：真实服务不可用时队列保留，界面不宣称上传成功。

每次原始动作、OS PNG、SQLite backup、事件和进程身份位于该次 `attempts/<编号>/native/`。完整检查与最终交付状态以 [迭代报告](../harness/reports/iteration-2026-10-11.md) 和实际门禁为准。

## 升级与故障恢复

升级从真实 v1 文件迁移到当前 schema，保留 dataset/stop/operation 身份、队列 seq 与未知历史原因；迁移失败回滚到原版本，保留文件并允许实际 Retry。不要通过删数据库处理升级失败，也不要假设旧客户端能读新 schema。生产回退方案仍需发布任务确认。

业务保存失败保留表单，确认事务失败保留 outbox，只有持久化匹配 ACK 后移除；重新发送使用原身份。清地图缓存只清瓦片，合法 viewport 随业务文件恢复，损坏或非有限视口回退到可用地图。详细反例在 N2/N3/N5/N6 原生组与 host 回归中分别验证。

## AI 使用记录

本迭代的 Flutter、测试与 Harness 代码由 Codex 主控及分工子 Agent 生成、审查和修复；产品原型、附件与架构取舍来自仓库既有资料和用户指令。没有将生成代码标为人工手写。主控维护任务板和资源串行执行，独立验收者读取源码与原始证据。

实际发现过地图遮挡、最大字号内容裁切、截图与 viewport 落盘时序不一致，以及 Linux 分析退出后子进程仍存活。失败记录保留，修复增加相应行为回归后重新执行。完整修复过程与测试范围在迭代报告，不以生成代码或测试数量代替验收。
