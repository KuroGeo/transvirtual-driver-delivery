# 大字模式修复 LTX-01

当前状态：**大字模式实现、指定原生验收及正式 Preview 安装已接受；等待最终提交 CI 后合入 PR37。** [Issue36](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/36) 在实际合入后关闭。

源码 `256de9fd360040a52ed3e7ec5948dbbaf4529e90`，262项输入指纹 `7b077f55197263c571fb33fce1b561f7ccd5cdc0d2a7252aab34c15a9eb184bf`。[交付JSON](large-text-repair.json)记录路径、SHA256和独立审查范围。

系统业务字号保留。大字模式的摘要、列表和详情占满安全区，客户/单号/状态、地址和保存结果可滚动阅读；筛选单独展开并返回结果。地图完整显示剩余数和带箭头的 Browse stops，展开摘要可读最近客户/单号/距离/反馈。实际 Tab、Escape、平台返回保留正确来源、焦点、查询与地图视口。普通字号保留原型层级。

| 验证 | 当前结果与边界 |
| --- | --- |
| G1 | 7阶段通过；Flutter196；Darwin Harness166项=165通过+1平台不适用 |
| LinuxCI | 源码256的38135929033、元数据1f80的[38138790695](https://github.com/KuroGeo/transvirtual-driver-delivery/actions/runs/38138790695)实际/独立通过：Harness166、零skip/NA，Flutter196；最终新元数据CI单独取证 |
| 最大字号两实际机型 | iPhone17Pro402×874与iPhone16 393×852，实际最大OS字号+ReduceMotion；完整阅读/入口/保存/返回接受 |
| 普通字号 | actualOSlarge/scale1/ReduceMotionfalse；原型工作台/详情/反馈真实OS阅读，typed返回与G1普通列表回归接受；未采独立普通列表OS帧 |
| N7门禁 | 5唯一ID、13通过实例、普通字号2真实NA、1382必需断言、9不同PID、40最大字号命名capture、62真实saved OS PNG；仅two-sizes原样本扩大为真实同候选superset，其他样本不改，原单run拒绝保留 |
| SQL/ACK | max两档outbox2→0→0/HTTP0→2→2，普通档1→0→0/HTTP0→1→1；真实受控fixtureACK、持久ack_committed、第三进程不重发 |
| 正式Demo | lib/main.dart，未生产签名的simulator包(ad hoc CodeSignature)，84文件与原归档一致，已安装到Ocean Delivery Preview；非私有driver入口 |
| 数据保留 | 安装前、安装后启动前和启动后全部业务行相同：30stops/0outbox；用户行快照仅本地 |

[正式地图OS画面](large-text-map-preview.png)、[最大字号17Pro列表](large-text-native-list.png)及[最大字号16列表](large-text-native-list-iphone16.png)为逐字节原图。正式单地图帧的顶部状态筛选仅部分露出，完整页头通过真实滚动/同源N7验证；不宣称所有内容同帧可见。OS键盘区含QuickPath首次使用界面，文字由driver输入，不宣称物理按键输入。

独立数据与画面综合验收分别为包内 `native-v7-three-config-independent` 和 `global-map-v7-three-config-visual-accepted` 原件。复核应读取[最终原始证据包](large-text-final-evidence.tar.gz)及[逐项索引](large-text-final-evidence-index.json)，路径保持仓库原路径。1084个payload的字节和SHA256全部核验；编译二进制归档与用户原业务行不公开，准确二进制SHA/84文件manifest随报告，原二进制本地保留。

两次max16 ENOSPC及log-reader清理错误保持失败原件，随包保留；空间恢复与严格核验的本任务重复产物/已完成构建中间产物回收后，以相同源码fresh重跑接受。未删除用户其他模拟器。早期[partial归档](large-text-partial-evidence.tar.gz)及[partial索引](large-text-evidence-index.json)保留。元数据317d418的[CI失败38138406290](https://github.com/KuroGeo/transvirtual-driver-delivery/actions/runs/38138406290)因忽略目录中的文档链接在cleanclone不存在；已改tracked原图/归档路径，保留[原始失败日志](large-text-metadata-ci-failed.log)，后续1f80CI实际通过，门禁未放宽。

复现命令（SDK/设备串行租用，源码冻结）：

```sh
python3 harness/run.py quality
python3 harness/run.py native --scope workbench --driver-target integration_test/acceptance_driver.dart --scenario N7 --configuration demo --isolated --timeout 1200 --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4 --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro --content-size accessibility-extra-extra-extra-large --reduce-motion
python3 harness/run.py native --scope workbench --driver-target integration_test/acceptance_driver.dart --scenario N7 --configuration demo --isolated --timeout 1200 --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4 --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-16 --content-size accessibility-extra-extra-extra-large --reduce-motion
python3 harness/run.py native --scope workbench --driver-target integration_test/acceptance_driver.dart --scenario N7 --configuration demo --isolated --timeout 1200 --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-4 --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro --content-size large
```

原报告stage_spec保留当次准确argv。

Preview设备 `D2B958C6-486D-4C17-A0CE-A8135717F3A6` 已安装上述同源码Demo，安装/捕获PID71667、OS最大字号。全部操作后台进行。可按需将原Preview字号恢复为large：`xcrun simctl ui D2B958C6-486D-4C17-A0CE-A8135717F3A6 content_size large`。升级保留业务库；不通过清库检验，也未声称旧版本回滚数据库兼容性。

[PR37](https://github.com/KuroGeo/transvirtual-driver-delivery/pull/37)的实际合入回执在GitHub及最终排除目录记录中单独读取。此修复接受指定N7和Demo安装，完整当前34项/G2、真机/真实服务/生产资源/签名发布仍由#31/#32/#33跟踪，生产no-go保留。旧PR34与全本地基线为历史，不冒充当前完整矩阵。
