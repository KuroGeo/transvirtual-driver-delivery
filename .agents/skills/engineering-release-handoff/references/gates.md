# 交付门槛

先分别明确工作 mode（prepare/execute）、运行 configuration（demo/local-client/connected）、要求的平台和 delivery scope（准备资料/本地候选/正式发布/外部交付）。逐项记录 required_for_scope 与 not_applicable_reason。准备交付只要求准备资料可复现；演示、本地客户端和生产发布按其实际范围要求门槛，不以缺 G6 阻塞本地交付，也不以本地通过代签生产门槛。

用户要求 Harness Engineering 才能上线时，Harness 准入与 G0–G6 为相互独立且均必需的条件。核查项目规定的执行环境、机械检查、可观察工具、候选门禁及恢复/评测实测；规则 YAML 不是已部署门禁。任一必要项缺证或未接入即生产 no-go，准备和补强可继续。

| Gate | 通过依据 | 不能代替它的资料 |
| --- | --- | --- |
| G0 合同 | 范围/平台/数据配置/需求 ID 明确 | 只有原型截图 |
| G1 代码质量 | 格式、分析、关键行为/故障测试通过 | 覆盖率或测试数孤立达标 |
| G2 原生功能 | 指定原生目标关键用户链及真实进程恢复 | web 刷新、hot restart、build 成功 |
| G3 硬件/性能 | 目标真机功能、profile 预算及 release 体验 | debug/模拟器的视觉流畅 |
| G4 数据与资源 | 不丢结果/outbox、适用升级/恢复、地图/数据/依赖许可 | 清库升级、OSM 开源标签 |
| G5 发布准备 | 对应平台 release/签名/版本、hash、运行/支持说明 | debug APK、未签 simulator build |
| G6 外部交付 | 授权目的地的成功回执和对应实测 | 本地打包、上传请求发出 |

演示配置允许 mock，但必须如实标注。商业联网使用还需要真实业务接受/幂等、访问权限及适用数据/地图条件；这些属于对应交付范围的外部能力，不因当前客户端任务而自动开发整套用户系统。

G4 分项记录 local（事务/恢复）、resource（数据/地图/依赖权利）和适用时的 connected（真实持久接受/访问权限）。子项状态互不掩盖，整体门槛只有当前范围所需子项全部通过才 passed。

发布前更新地图服务条款/合同核验。公共 OSM 瓦片不提供 SLA、禁止为离线批量下载；自动化地图压测用授权受控来源。[OSMF tile policy](https://operations.osmfoundation.org/policies/tiles/)。
