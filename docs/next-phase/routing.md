# 需求 1：路径规划与导航

本项单独对应用户的“当到站点的时候，可以有路径规划去导航”。原型采用已确认的站点→道路预览→外部地图→返回配送流程；方案状态为待实施设计。

## 原型与用户流程

[单项可点击原型](http://127.0.0.1:8764/next-phase/routing.html) · [原型源码](../../prototype/next-phase/routing.html)

1. 点击地图或列表中的待配送站点，查看目的地与时间窗。
2. 点击导航，预览从当前可信起点到该站点的道路路线、距离与预计到达。
3. 选择 Apple Maps/Google Maps，交给外部应用；返回后恢复原站点与入口。
4. 司机手动确认到站、完成或失败，导航行为不改变配送结果。

原型的道路数值、定位与导航交接均为模拟；它证明信息与操作流程，不证明真实道路/系统导航能力。截图与已有点击证据见 [原型证据](../../prototype/next-phase/README.md)。

## 技术方案

新增纯 Dart RouteRequest/RouteResult 与 RouteRepository，数据层对接受信账号的道路服务；platform 的 LocationGateway/NavigationGateway 负责系统定位与外部应用。保留现有 flutter_map 底图与 ViewModel/Repository 分层，由 NP10 单写启动装配、依赖、导航和平台工程配置。

RouteRequest 绑定 scope/dataset/stopId/inputRevision、起终点、定位时间/精度和出发时间。结果带 provider/configRevision/computedAt/expiresAt/departureAt/arrivalAt、距离、几何、时长模型与交通感知标识。静态路网估算注明不含实时交通；直线距离与固定测试点不能冒充道路 ETA。服务提供商由 NP00 冻结覆盖、许可、缓存、配额和定位阈值。

保留 OSM-compatible 地图/路线组合；Google Routes 若作为选项需另外验证其叠图/缓存政策。公共 OSM 瓦片不是生产或离线包方案。许可与官方协议来源见 [总方案的路线章节](../next-phase-solution-design.md#路线与外部导航)。

外部 URL 使用白名单目的地与合法编码，按 OS 冻结 Apple URL/兼容方案。记录 scope/dataset/stopId/origin/query/viewport，恢复后核验账号和站点；区分 unavailable、launchFailed、handoffRequested、returned。打开成功不能推断已开始导航或到站，外部应用独立算路的 ETA 可以不同。

权限拒绝/过旧定位允许司机明确选择可信起点；未安装地图或交接失败提供其他应用/复制地址。道路服务超时、不可达或限额时明确失败、取消和有界重试；缓存按供应商许可与有效期展示，过期不称实时。账号/站点/输入已变更时拒绝迟到结果。

## Harness 与 issue 拆分依据

覆盖 NP-R04–NP-R06；产品任务为 NP05 道路服务、NP06 系统导航、NP10 页面装配。NP01 提供新协议/fixture/观察，NP11 独立回归，NP12 原生交接/来源返回，NP13 真实道路与地图应用联调。

关闭证据必须包含：道路 A/B 请求乱序不覆盖、定位权限/年龄/精度降级、不可达/超时/限额、地图安装与未安装、返回原站点、换号拒绝旧返回、交接/到站不改 outbox；原生记录独立 PID/trace，真实供应商记录配置与计算来源。已有网页/旧 N1–N7 不代签。

先准备本项原型和技术方案，才以这些来源编写对应 issue。供应商和系统配置未取得时，真实接入任务保留 blocked。
