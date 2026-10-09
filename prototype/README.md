# ocean delivery · 司机配送 App 原型

当前第三版已整体改成地图工作台：附件里的 30 个站点按真实坐标落点，配送状态同时由颜色和图形表示；蓝色方向箭头表示固定在这些站点附近的当前位置。点击站点展开底部任务卡，搜索、筛选和站点浏览都围绕地图操作。底部显示最近匹配站点与直线距离；详情按进入来源返回地图或列表；左侧更新按钮直接执行同步，通过 Toast 反馈进度和结果。视觉延续鲜明橙色、奶油白与本地 Inter 字体。设计与验收见 [map-design.md](map-design.md)。

这是浏览器设计原型。Flutter 应用、模拟器验收及正式提交材料尚未实现，本轮验证不代替题目要求的 Android / iOS 运行证据。

## 预览

- [地图工作台](http://127.0.0.1:8764/index.html)：当前可交互版本，390 × 844 手机画布。
- [前后对比](http://127.0.0.1:8764/style-explorer.html)：左侧保留第二版清单，右侧运行第三版地图。
- 原来的 `focus.html`、`windows.html` 均进入地图版；旧设计归档在 `archive/round1/` 和 `archive/round2/`。

在仓库根目录启动：

```sh
python3 prototype/serve.py
```

字体、图标、地图组件均在本地；OpenStreetMap 底图需要联网。底图不可用时仍显示站点标记、当前位置和重试入口，可以浏览站点并离线保存配送结果。对比页的新版使用本地预览地址，需保持服务运行。

直接打开地图页面会将配送结果、失败原因、待同步队列和应用内 Online / Offline 状态保存到当前浏览器的本地存储。刷新同一地址可读回；不同端口或浏览器属于不同存储空间。`?state=idle` 是干净的设计预览入口，不用于验证跨刷新恢复。

## 固定当前位置

`assets/map-config.json` 独立保存当前位置和固定箭头朝向（`headingDegrees: 35`）：纬度 `-33.9004`，经度 `151.139`，悉尼 Newtown 附近，位于附件站点的坐标范围内。它是用户授权的固定原型位置，不是 CSV 自带的司机定位，也不读取设备 GPS 或方向传感器。修改配置后执行下方重建命令即可更新页面。

## 完整操作

1. 放大聚合标记并点击站点，或打开 Browse stops。列表按当前坐标的直线距离从近到远排列并显示距离，最近是 Silverline Supplies（2.4 km）。搜索和筛选结果也保持最近优先。
2. 在右上角切换 Offline，点击 Complete delivery：站点立即变绿，待同步角标与队列计数更新。
3. 返回地图，再选择 Skyline Pharma；Report a failed delivery 必须选择原因，Other 必须填非空说明。提交后标记变为红棕色。
4. 从 Stop list 进入的详情返回列表，再关闭列表回地图；从地图或最近站点进入的详情直接返回地图。点击左侧更新按钮直接尝试同步；Offline 时用 Toast 告知更新已保存，刷新页面后结果、失败原因、连接状态和队列均保留。
5. 切换 Online 自动同步，或在失败后点击左侧更新按钮重试；进度和结果通过 Toast 提示，按钮与站点上的待同步角标随确认更新。

发送目标是应用内 fake，约 720ms 确认一条，没有真实网络上传。Online 开关控制题目要求的应用内连接状态，不读取设备网络；它与底图能否加载是两件事。

原始数据来自未修改的 `docs/assignment/deliveries.csv`：24 pending、3 completed、3 failed。CSV 已有 failed 没有原因，详情明确显示来源未提供。配送状态遵守 `pending → completed | failed`；终态不可再改。保存失败时保留表单输入，不提前改变标记或追加队列；同步中切回 Offline，未确认记录仍留在队列。

## 设计和证据

- [map-design.md](map-design.md)：地图结构、视觉取舍、动效、范围与验收说明。
- `evidence/round3/home/page.png`：当前首屏。
- `evidence/round3/states/`：任务卡、失败表单、离线队列、完成、底图错误和站点抽屉。
- `evidence/round3/zoom/`：任务卡和失败表单的 2 倍截图。
- `evidence/round3/record-entry/`、`record-select/`、`record-complete/`：首次出场、选择站点和离线完成的录屏与三帧。
- `evidence/round3/comparison/`：前后对比。
- `evidence/round3/visual-review.md`：独立视觉评审及修正记录。
- `evidence/round3/qa-run-1.json`、`qa-run-2.json`、`qa-run-3.json`：最终修改后连续三轮，分别 45/45 通过。

45 项验证覆盖全部真实坐标、聚合数量、固定当前位置、地图标记真实点击、筛选与搜索、缩放、状态变更、失败原因、离线保存、刷新恢复、发送中断、写入错误、底图不可用后继续保存与重试，以及 320 / 390 / 430 / 1280px 宽度。桌面保留 390px 手机画布。

最新反馈已全部调整：方向箭头、简洁 Pending 圆点、按距离排序的 Stop list、无底部页签、左侧同步工具、宽松的两行状态栏及新 App 图标。说明见 [feedback-design.md](feedback-design.md)。最新证据在 `evidence/round3-feedback/`，最终三轮分别 57/57 通过；此前 45 项报告作为改版基线保留。

## 重建

```sh
python3 prototype/build_prototype.py
```

生成器读取题目 CSV 和地图配置，生成地图 HTML、旧入口跳转及前后对比页。地图页面使用仓库内缓存的图标和运行依赖，重建只需 Python 3。若安装了 Oil UI，则同时重新生成对比页；可用 `OIL_UI_HOME` 指定其目录。未安装时保留仓库内已生成的对比页，地图页面照常重建。第三方资源及许可证见 [assets/THIRD_PARTY.md](assets/THIRD_PARTY.md)。

最新一轮交互调整见 [direct-sync-design.md](direct-sync-design.md)：直接同步与 Toast、最近站点入口、详情按来源返回；App 图标按用户选择采用第一版圆环箭头。

当前最终验收：`evidence/direct-sync/qa-run-1.json`、`qa-run-2.json`、`qa-run-3.json`，分别 75/75 通过。

最新返回规则与验收见 [origin-return-design.md](origin-return-design.md)：按进入来源返回，最终三轮各 78/78 通过。
