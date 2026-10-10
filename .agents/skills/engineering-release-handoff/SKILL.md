---
name: engineering-release-handoff
description: Close engineering delivery gates and prepare traceable source, artifacts, release notes and recovery instructions. Use for a handoff, PR or release candidate; external publication only within the user's authorized destination and scope.
---

# Engineering Release Handoff

确认交付物与证据属于同一候选版本，并准确区分准备、构建、安装、上传和上线。

## 收口

1. 对照需求 ID 和 [交付门槛](references/gates.md)，核验测试、独立原生验收、性能及数据/许可门槛。blocked、not_run、旧版本报告不能转成通过。
   用户明确要求 Harness Engineering 达标才上线时，另核验 `harness-engineering` 的项目审计/状态及实际强制门禁证据。必要能力未 demonstrated 或门禁未接入时生产 no-go；不以平均分、skills 完成或改交付名称绕过。
2. 固定候选 SHA、依赖 lockfile、SDK、配置和真实产物 hash。未提交变更需保存 source fingerprint/patch，并标明不可仅用 HEAD 复现。
3. 完成可复现 README、变更/已知缺口、数据迁移与故障恢复说明。使用 [交付模板](assets/handoff-template.md)。日志不含凭据/客户详情。
4. 按用户已授权范围准备或执行 Git/PR/发布动作。技能存在不等于获准公开仓库、上传包、提交商店或发送给他人。若外部最终动作需授权，先完成本地可审阅结果，再明确目的地和所需动作。
5. 实际创建 PR 后使用可用 attachment 工具附到当前任务。merge/CI/部署/真实运行分别取证；不能以 PR 已创建代替合并，以 CI 通过代替生产验证。

## Flutter 特有边界

本地 debug APK、无签名 simulator app、web build 都不等于正式发布。原生发布检查目标平台 release 产物、签名、版本/渠道及其安装运行；某平台没验证就单独列出。

升级不能靠清数据验证。保留旧 schema/待发结果的升级证据；回滚不能默认旧程序能读新 schema。迁移策略需要兼容回退、保留数据的前滚修复或明确恢复流程。

没有真实服务时仅判定本地客户端/演示交付；fake/mock 已确认要注明测试配置，不能报告客户结果已上传。商业地图/业务数据和签名条件未落实时保持相关 gate 未满足。

## 完成标准

提交/交付对象实际存在且可复现；每个完成声明有对应版本证据；外部目的地的状态有真实回执。只要求准备时交付 manifest 和门槛清单，不执行发布。
