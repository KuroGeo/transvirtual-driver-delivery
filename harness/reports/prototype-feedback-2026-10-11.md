# 原型反馈修复与模拟器交付

候选源码 `a6d473d2b9b91126d4d689dddfc4b9b8ee19e48f`，fingerprint `fcc573639cd8ba9fe4cf4a9951636cc5f8fbd1e94c8bc248f6906f2f27d9fff5`，261 个计入输入均与提交一致。

- 工具栏固定五个44px单列按钮。
- 地图实际双触点缩放15 → 16.4594 → 15；原生产交互配置已支持捏合，本轮补真实触点回归，未伪造camera操作。iOS Simulator使用Option拖动；物理OS触摸未测。
- 点击状态Tab关闭详情并适配当前查询结果和固定参考点；空结果定位参考点。被动通知不改变镜头。
- Browse默认采用原型的奶油色通栏抽屉、拖动柄、标题/计数/Nearest first、连续状态圆圈配送行。附加查询折叠，大字号标题进入实际滚动区，保留筛选和来源返回。

当前G1：7阶段通过，161 Harness（Darwin 1项Linux特有NA）、185 Flutter、format/analyze通过。当前N4/N7共10项定向原生回归由另一个Agent复核原始动作、OS PNG、SQLite、阶段hash及6个真实进程。仅当前402×874一设备宽度；大字号实际scale3.117647和iOS Reduce Motion。文本由driver模拟，OS键盘Insets/Save几何有截图；地图瓦片/ACK使用受控fixture。历史完整34项属于381730候选，本轮没有重新签全矩阵。

正式 `lib/main.dart` Demo无签名debug构建通过；84个产物文件和压缩包hash核验。已保留数据安装并启动Ocean Delivery Preview `D2B958C6-486D-4C17-A0CE-A8135717F3A6`，PID25842，30站/0outbox的升级前后业务投影完全相同。实际OS截图已加载公开街道瓦片并显示纵列工具栏。

旧N7失败原件保留：驱动在offset0朝错误方向滚，搜索框位于OS大字号标题下方；仅按实际几何选择滚动方向，原12次/15秒限制和命中判断保留。

[机械索引](prototype-feedback-2026-10-11.json) / [有界原始证据](prototype-feedback-2026-10-11.tar.gz)。包内包含质量/定向native原件、历史失败、原型截图、源清单、安装前后投影、安装/启动回执和独立复核；Runner二进制仍保留在本地正式build路径，未混入包。

生产no-go继续保留：#31真机G3、#32实际强制门禁、#33真实服务/资源/签名/发布授权。PR34供审查，未合并或上线。新HEAD的CI结果在push后另行记录，不借用旧CI。
