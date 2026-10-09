# Driver Delivery App：原始题目与附件

材料于 2026-10-10 通过 Gmail 读取并保存。以下为原题的中文整理；英文原文和附件是需求依据。

## 来源与文件

- 邮件主题：George Ye — Mobile Engineer (Flutter): Take-Home Assignment (Driver Delivery App)
- 发件人：Xiaojie Zhang <xiaojie.zhang@transvirtual.com>
- 邮件发送时间：2026-10-09 22:41:50（北京时间，原邮件 Date 为 14:41:50 UTC）
- [Gmail 原邮件](https://mail.google.com/mail/u/?authuser=yeyufeng1998%40gmail.com#all/1a1211d1ff20d220)
- [邮件原文与邮件头](email.txt)
- [完整题目 PDF 原件](TakeHome-Mobile-Driver-Delivery-App.pdf)
- [题目英文全文](brief.en.txt)（Gmail 对两页 PDF 的完整文本提取，保留分页标记）
- [配送数据 CSV 原件](deliveries.csv)

PDF 和 CSV 从 Gmail 的原始 MIME 邮件中直接解码保存，完整保留原附件字节，未通过文本预览重建。两份文件的大小和 SHA-256 已在本机核对：

| 文件 | 实际大小 | 已验证 SHA-256 |
| --- | ---: | --- |
| TakeHome-Mobile-Driver-Delivery-App.pdf | 51044 bytes | `5789cdb297c2bb6adf6bff5d25b364e4281b4f1ca83916f74747c726d6c9761f` |
| deliveries.csv | 3111 bytes | `901a8c279f2c35a66ce888d9c7c583030fb6b7c5c213613669e827dab3365934` |

## 要做什么

用 Flutter 实现一个小而可运行的司机配送应用：查看当天配送站点并更新状态，采用离线优先设计。司机会在仓库或无信号区域工作，因此离线更新必须经得住应用重启。重点是能在模拟器上完成整个演示流程。

招聘方只提供 `deliveries.csv`，含 30 个配送站点。存储、同步方案、状态管理和其他工具由候选人选择，这些决策也会被评估。

## 八项要求

1. **数据**：将提供的 CSV 作为应用 asset，导入自选本地存储。原题举例 sqflite、Drift、Hive、Isar，均非指定方案。
2. **站点列表**：展示编号、客户、地址和状态，支持按状态筛选。
3. **详情和状态更新**：允许标记 completed，或标记 failed 并填写必填的失败原因。生命周期只能是 `pending → completed | failed`；completed 和 failed 均为终态。逻辑层必须拒绝无效更新，仅隐藏 UI 按钮不够。
4. **离线优先**：每次更新都在本地持久化，应用重启后保留；UI 中有可见的待同步队列。
5. **同步**：应用内提供在线/离线开关。离线时更新累积到队列；切换在线时发送至自选 mock 同步目标，并在 UI 反映已同步状态。目标可以是 stub server、带日志的 endpoint 或应用内 fake。
6. **状态管理**：自行选择，能够解释选择理由。
7. **测试**：至少两个有意义的测试。原题建议覆盖状态生命周期和离线队列行为。
8. **可运行演示**：在 Android emulator 或 iOS simulator 上运行，README 写明准确命令和目标设备，`flutter run` 可以。验收流程为：**离线 → 更新多个站点 → 重启应用 → 在线 → 观察队列同步**。

## 数据合同

原始 CSV 的七列为：

```text
reference,customer_name,address,latitude,longitude,status,time_window
```

已直接解析原件确认：30 条记录，30 个不同编号；24 pending、3 completed、3 failed。Gmail 表格预览中的 `index` 是提取工具添加的展示列，原 CSV 没有该列。原 CSV 也没有 `failure_reason` 或日期列；初始 failed 记录未提供失败原因。这些是对附件的核实结果。

## 时间、范围与 AI 使用

- 投入时间盒为 **4–6 小时**，收到题目后 **2 天内**交付；可主动申请第 3 天。到时间盒就停止，写下后续会做什么。原题明确接受未完成但有充分解释的交付。
- 鼓励使用 Claude Code、Copilot、Cursor 等 AI 工具。必须写一段 AI 使用说明：用了什么工具、哪些内容由 AI 生成、哪些为手写，以及**至少一个 AI 出错的例子和发现方式**。
- 可使用任何包。跳过认证、真实后端集成、推送及要求之外的功能。
- 最终面试开头会进行约 5 分钟的现场演示，并在面试中扩展应用；需要能够讲清自己的实现。

## 提交内容

- 完整源码的 Git 仓库链接或 ZIP。
- `README.md`：准确的运行命令、目标模拟器，以及本地存储、同步、状态管理的关键选择和理由；附后续改进清单。
- AI 使用说明，可放在 README 或单独文件中。

## 评估与面试

演示是核心交付。如果招聘方按文档无法运行，会给一次修复环境的机会；仍不能运行则无法推进申请。演示比单个功能更重要。

评估维度包括离线和同步设计、状态生命周期正确性、代码结构和状态管理、环境与工具选择、测试、README 中决策说明的质量，以及使用 AI 的判断力。

邮件说明后续为一场 **60 分钟**的最终面试：现场演示、随约束扩大进行设计答辩，以及如何帮助初级工程师学习 Flutter。PDF 提到的扩展话题包括数千个站点、照片/签名载荷、冲突解决和电池消耗。
