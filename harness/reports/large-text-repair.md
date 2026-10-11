# 大字模式修复 LTX-01

当前状态：**实现并安装到 Preview；原生验收部分通过，磁盘阻塞，PR37 保持 Draft。** [Issue36](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/36) 保持开放。

源码 `256de9fd360040a52ed3e7ec5948dbbaf4529e90`，262 项输入指纹 `7b077f55197263c571fb33fce1b561f7ccd5cdc0d2a7252aab34c15a9eb184bf`；[JSON 原件索引](large-text-repair.json) 记录路径、SHA256、独立审查与范围。

地图完整显示剩余配送数和带箭头的 Browse stops。大字模式使用完整安全区的摘要、列表和详情，业务文字继续按系统字号缩放；筛选独立滚动，返回保留查询、滚动、焦点和地图视口。摘要支持实际 Tab、Escape 和系统返回。普通字号保留原型布局。

| 验证层级 | 当前结果 | 范围 |
| --- | --- | --- |
| G1 | 7 阶段通过；196 Flutter；Harness166 项，其中 Darwin165 通过、1 平台不适用 | 格式、分析、业务/布局/故障回归 |
| 源码 Linux CI | [38135929033](https://github.com/KuroGeo/transvirtual-driver-delivery/actions/runs/38135929033) 通过；Harness166/0skip/0NA、Flutter196 | 精确源码256de9f；后续元数据 HEAD 的 CI 单独核实 |
| 最大字号 iPhone17Pro | 402×874、实际 OS 最大字号、Reduce Motion；3 独立 PID、681 条必需断言、28 张真实 OS PNG | 4 个唯一 N7 条目独立接受；两尺寸条目仍按原门禁拒绝单视口 |
| 冷启动与保存 | outbox2→0→0；受控 HTTP0→2→2，真实 fixture ACK 与持久 ack_committed 对应；第三进程无重发 | 模拟器受控服务，非真实业务后端 |
| 最大字号 iPhone16 | 两轮 ENOSPC 失败，原日志和清理错误保留 | 393×852 所需复验尚未接受；不将部分画面或失败改写成通过 |
| 普通字号原生/两尺寸聚合 | 当前候选未执行完成 | G1 的普通字号回归通过不能替代这些原生检查 |
| 正式入口 Demo | lib/main.dart 无签名 simulator 构建，84 文件与归档一致，已安装/启动 | 使用真实公共地图；不含私有 driver/fixture/tile 覆盖 |
| 升级保留数据 | 安装前、安装后启动前及启动后全部业务行相同：30 stops、0 outbox | 用户原数据未重置；行快照仅本地保存 |

[当前正式地图画面](../runs/preview/20261011T113855Z-large-text/formal-maximum-text-map.png) 来自实际系统截图，Browse 箭头和23剩余完整可见；该单帧的顶部状态筛选仅部分露出，不能声称整个页头首屏可见。列表/详情和实际滚动阅读的同源码证据由独立 UI 审查接受。OS 输入区截图包含 QuickPath 初次使用界面；文字由 driver 输入，不声称物理按键输入。

[正式产物审查](../runs/large-text-repair/formal-v7-113713/formal-build-independent.md)、[安装审查](../runs/preview/20261011T113855Z-large-text/final-preview-independent.md)、[画面审查](../runs/large-text-repair/global-map-v7-max17-visual-accepted.md)、[数据审查](../runs/large-text-repair/native-v7-max17-independent.md) 与 [环境失败审查](../runs/large-text-repair/storage/intermediate-115158-independent.md) 分别签署自身范围。

磁盘目前约1.9GiB空闲，需约5GiB总空闲再执行完整新进程复验。只回收已核实且可由原始归档恢复的本任务副本和完成构建后的隔离中间产物，保留原件；未删除用户其他模拟器。等待空间解决后，以相同262输入运行 fresh max16 和 normal17，再独立核验真实两尺寸聚合；ENOSPC attempts 不覆盖、不转成通过。

```sh
python3 harness/run.py native --scope workbench --driver-target integration_test/acceptance_driver.dart --scenario N7 --configuration demo --isolated --timeout 1200 --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4 --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-16 --content-size accessibility-extra-extra-extra-large --reduce-motion
python3 harness/run.py native --scope workbench --driver-target integration_test/acceptance_driver.dart --scenario N7 --configuration demo --isolated --timeout 1200 --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4 --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
```

原 Preview 设备 `D2B958C6-486D-4C17-A0CE-A8135717F3A6` 中已安装当前 Demo，当前 OS 字号为最大。安装/捕获 PID71667，后台操作未改变用户前台。若需恢复旧字号，可对该设备执行 `xcrun simctl ui D2B958C6-486D-4C17-A0CE-A8135717F3A6 content_size large`；业务数据库保留。

[PR37](https://github.com/KuroGeo/transvirtual-driver-delivery/pull/37) 尚未合入。旧 PR34 已合入，但它的完整/局部原生结果不能冒充当前候选。完整34项原生矩阵和真机/真实服务/生产资源/签名发布仍未在此候选接受；#31/#32/#33 与生产 no-go 保留。

[可回读证据包](large-text-partial-evidence.tar.gz)包含 560 个原始/独立审查文件，各成员字节和 SHA256 已逐项验证；[索引](large-text-evidence-index.json)说明二进制归档和用户业务行未公开。包内保留两次 ENOSPC 失败，不代表完整验收。
