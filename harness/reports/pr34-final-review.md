# PR34 最终审查与修复

Browse stops 增加右侧进入箭头，保留原按钮身份、来源返回行为与 44px 点击区域。按完整 PR 对主线进行审查，原始 156 个变更文件全部有审查记录；新增有界修复单独交给非作者复核。

审查发现并修复三项 P2：

- UI-01：受支持的横屏下，剩余地图高度不足会裁掉 Locate/Sync，固定 fit padding 也会耗尽取景空间。工具保持 44px 单列，短地图内支持纵向滚动；取景 padding 留出完整 44px marker 高度。实际拖动、点击和正式 844×390 搜索/Tab/Browse 返回回归先失败，再通过。
- HREV-1：门禁原先未读取 stage completion，缺失清理凭据或仍存活的进程组可能被外层 passed 接受。现在逐项验证严格类型、实际 PID、reaped/returncode/group_alive 和 cleanup_errors。
- HREV-2：零 skip 的截断/summary-only unittest 日志原先可被接受。现在 0/1 skip 都要求完整 verbose 行数匹配 Ran N，保留唯一精确 Darwin 平台不适用条件。

数据、事务性 outbox、确认身份、同步串行与生命周期分区没有额外 P1/P2。代码作者不签自己的修复；原始发现报告和红测试保留，独立 reviewer 对修复及证据另行判断。

候选 source fingerprint 为 `9ca3cc8caf2d0a1eb46570153b38205a3bb1f831266e00551f4c0ea07719f69d`，261 个计入输入均已逐项对 Git 源码提交 `cae7fca40760e67567c3e29d39b9b295ffa002e5` 验证。原始执行时含未提交改动，最终提交与原始执行指纹一致。

当前验证范围以 [机械索引](pr34-final-review.json) 与 [状态](status.json) 为准。全量 G1 的 7 阶段通过：162 Harness（Darwin 1 项 Linux 专属 N/A）、188 Flutter、锁定依赖、格式与静态分析。实际 UI 横屏是 host/widget 回归，尚未把它称为 OS 旋转验收。

新版 N4 与最大实际 OS 字号/Reduce Motion N7 的 10 项定向原生检查已通过独立复核：274 个原始 artifact、27 份 SQLite、6 个实际进程。首次 N4 因磁盘 ENOSPC 中断，原始失败与清理回执保留；相同条件重新完整执行通过。模拟器、受控瓦片和模拟确认、框架双触点输入分别注明，不移用历史候选的完整 34 项证明。正式 Demo 构建使用 `lib/main.dart`，84 个展开文件与压缩包成员已逐字节核验，私有仪器入口标记不在正式 Kernel 中。构建层与实际安装启动分开记录。合入判定还核验同候选、新 HEAD 的 Linux CI；GitHub PR 的实际合入回执另行记录。

历史完整 34 项与早先原型反馈证据保持原文件，最新范围没有替换旧记录。生产 no-go 保留：E09/#31 真机 G3、X05/#32 强制发布路径、E12/#33 真实服务/资源/签名与具体发布交付。用户本次授权是审查后合入 main。
