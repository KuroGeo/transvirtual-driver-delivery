---
name: flutter-performance
description: Profile Flutter startup, UI/raster frames, memory and workload bottlenecks on native devices. Use for a performance budget, measured regression or production readiness; not for guessing speed from code, debug mode or simulator screenshots.
---

# Flutter Performance

先量化问题，再改有证据的热点。结果必须对应同一个设备、工作负载和候选版本。

## 建立测量合同

记录目标平台/最低设备、OS、刷新率、数据规模、地图来源、网络/缓存条件、build mode、场景、指标定义和预算。项目未定预算时提出带依据的初始预算并记录为 provisional，不能自称已经达标或以它替代产品确认的 SLA。

正式 native 性能结论使用目标真机 profile 测量，release 复核实际体验。debug 和模拟器可用于定位，不充当发布性能依据。没有真机时执行代码/重建风险分析和测量准备，将性能 gate 保持 blocked。参考 [官方性能 profiling](https://docs.flutter.dev/perf/ui-performance)。

候选源码也不可访问时记录 source-unavailable，只做测量合同和依赖准备；不从架构/原型推断实际热点或优化收益。

## 测量重点

按 [测量协议](references/profiling.md) 分别记录冷启动至业务可操作、地图可用、UI/raster 帧、内存趋势和持续负载。使用已有 DevTools/VM service/integration 性能能力，保存可读取的原始 trace 或导出报告，不编造工具参数或统计数字。

对地图类应用优先查看站标/聚合、地图拖缩、列表滚动、搜索排序、保存/同步反馈组合。区别业务本地读取与瓦片网络等待；用授权受控底图来源压测，不自动批量请求公共地图服务。

## 诊断和修复协作

先区分 UI isolate 计算、build/layout、raster、数据库/I/O、解码内存和原生插件热点。提出带 trace 证据的最小修复任务。改变实现要有指定文件责任与授权；性能审查者不直接越界重写业务层。

RepaintBoundary 不消除 build/layout；async 不自动把 CPU 工作移到别的 isolate；全局状态框架迁移、地图 SDK 更换、分页和 isolate 均需实际热点依据。修复后同条件测量受影响指标，同时检查正确性和内存代价。

## 输出

填写 [性能报告](assets/performance-template.md)：样本数、p50/p95/最大值或原始工具统计、慢帧定义及比例、内存趋势、原始证据、变更前后比较。样本量不足以可靠估计分位数时报告单次/范围并注明限制，不给虚假的 p95。

原始证据清单记录 ID、path、candidate、collector/time、kind、raw/summary、hash；输入只有口述统计时标 reported/unverified。

分别判定 measured_pass / measured_fail / blocked / provisional；超预算和缺关键证据均不允许标记生产性能通过。
