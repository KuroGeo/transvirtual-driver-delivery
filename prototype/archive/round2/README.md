# Transvirtual 司机配送 App 原型

第二版已按用户反馈重做：鲜明橙色、奶油白、本地 Inter Variable 字体、合并页头和紧凑列表，详情突出交付地址。当前主推 A 作业清单。核心流程共用：站点筛选、详情、完成配送、必填失败原因、离线保存、可见待同步队列和重新联网后的逐条发送。第二版说明见 `round2-design.md`。

这些是浏览器设计原型。Flutter 应用、模拟器验收及正式提交材料尚未实现；本轮验证不代替题目要求的 Android / iOS 运行证据。

## 预览

- `style-explorer.html`：第一版与第二版对比，自包含，可离线打开。左侧是保留基线，右侧是新版；默认手机 390 × 844 视口，进入「单张」可操作。
- `index.html`：A 清单优先，推荐。
- `focus.html`：B 当前站点优先，主操作在当前任务旁。
- `windows.html`：C 时间窗优先，同一窗口的站点归组。

开发预览地址：`http://127.0.0.1:8764/style-explorer.html`。

启动方式，在仓库根目录执行：

```sh
python3 -m http.server 8764 --bind 127.0.0.1 --directory prototype
```

直接打开独立页面会把状态保存在当前浏览器的本地存储，三个方案的数据相互隔离。对比页中的交互使用 Oil UI 提供的内存存储，关闭页面后清空；需要验证刷新恢复时，使用独立页面及同一地址。不同端口属于不同存储空间。

## 如何走完整流程

1. 打开 A，点击右上角 Online 开关进入 Offline。
2. 打开 Silverline Supplies，点击 Complete delivery，再返回列表。
3. 打开 Skyline Pharma，点击 Report a failed delivery，选择失败原因并提交。
4. 打开 Sync：两条更新的配送终态和待同步状态分别显示。
5. 刷新独立页面：两条更新、失败原因、Offline 和待同步队列都保留。
6. 在 Sync 中切换 Online：队列逐条发送，成功记录进入 Recently synced。

发送目标是应用内 fake，约 720ms 确认一条，只用于观察同步 UI；没有真实网络上传。右上角开关控制题目要求的应用内连接状态，不读取设备网络。原始数据全部来自题目 CSV，初始为 24 pending、3 completed、3 failed。CSV 中已有的 failed 没有原因，详情明确显示来源未提供；没有编造补填。

原型遵守 `pending → completed | failed`；终态在逻辑和界面两层保护。失败原因必填，Other 必须有非空文字。保存失败时，不提前修改状态或追加队列，保留当前表单与输入。同步中切回 Offline，未确认的记录仍在队列中。

## 设计文件和证据

- `round2-design.md`：当前视觉方向、结构变化和新版证据。
- `evidence/round2/home/page.png`、`states/`：新版首屏和五种主要状态。
- `evidence/round2/comparison/page.png`：前后对比。
- `evidence/round2/visual-review.md`：独立视觉评审及逐项修正。
- `evidence/round2/qa-run-1.json`、`qa-run-2.json`、`qa-run-3.json`：新版最后修改后 41 项检查，三轮分别 41/41 通过。
- `design-notes.md`：第一轮方向、版式取舍、状态和动效规范。
- `evidence/a/page.png`、`evidence/b/page.png`、`evidence/c/page.png`：三个首屏。
- `evidence/states/`：详情、失败表单、离线队列、完成和保存错误画面。
- `evidence/zoom/`：详情和失败表单 2 倍截图。
- `evidence/record-entry/`：首次进入动效。
- `evidence/record-filter/`：状态筛选滑块。
- `evidence/record-complete/`：进入详情、完成与保存反馈。
- `evidence/record-sync/`：队列逐条发送。
- `evidence/motion/report.json`：首次进入和主操作的动效探测。
- `evidence/qa-run-1.json`、`qa-run-2.json`、`qa-run-3.json`：每轮 39 项，三轮全部通过。

已检查 320、390、430 和 1280px 宽度，没有横向溢出；桌面保留 390px App 画布。首屏、详情、失败表单和队列截图未报告文字对比度、正文过小或加载错误。对比页外壳的三个方案编号原本对比度偏低，生成后已覆盖文字色并复查通过。

第一轮版式比较阶段只做自检；第二版已将首屏、详情、失败表单、队列、三处动效证据交给隔离上下文的独立视觉评审。当前记录见 `evidence/round2/`，旧证据与第一版保留。

## 重建

在已安装 Oil UI 的本机执行 `python3 prototype/build_prototype.py`。它从 CSV 生成三套 HTML，使用 Oil UI 自带生成器组装对比页，保留默认手机视口与对比页编号对比度修正。图标已缓存到 `assets/icons.json`，无需再次联网。

图标来自 IBM Carbon / Iconify，见 `assets/THIRD_PARTY.md`。没有在线字体、图片或 CDN 依赖。
