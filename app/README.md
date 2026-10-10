# Ocean Delivery 配送工作台

Flutter 正式入口为 `lib/main.dart`，采用地图优先界面、真实 SQLite 和事务性 outbox。功能范围来自现有原型与 [架构设计](../docs/solution-design.md)，具体合同和验证状态见 [Harness 入口](../harness/README.md)。

地图、列表和最近站点共享搜索、状态与待同步筛选；详情按来源返回。完成/失败在本地同事务保存不可变结果与 outbox 事件。失败表单支持预设原因、可选备注与必填的 Other 文本；写入失败保留输入并允许重试。直接同步反馈保留当前查询与详情上下文。

Online 设置和合法地图视口随数据库持久化；冷启重置搜索、临时卡片和列表会话。同步按队列串行执行，仅在匹配身份的确认持久提交后移除 outbox。瓦片错误不阻断业务保存，清地图缓存不清业务数据。真正进程恢复必须重开同一安装文件，不能用 hot reload 或清数据代替。

## 运行配置

缺省或 `--dart-define=OCEAN_MODE=local-client` 选择 UnavailableTransport，界面标记 `Local client · service unavailable`。没有实际服务时保存仍保留本机队列，不显示已上传。业务文件为 `ocean_delivery.sqlite`。

`--dart-define=OCEAN_MODE=demo` 使用模拟确认，界面标记 `Demo · simulated confirmations`，业务文件为独立的 `ocean_delivery-demo.sqlite`。demo 不复用 local-client 队列，也不表示客户结果已上传。

批准的开发样本为 assets/deliveries.csv 的30站原始七列；字体、图标和地图依赖许可保存在 assets/licenses。生产业务数据、地图/瓦片与离线服务的使用条件仍需单独核验。

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
