# 需求 2：全站登录、用户与组织权限

2026-10-12 用户修正：用户管理是全站需求，后端采用 Go，必须完成后端架构设计。本项覆盖统一身份、组织/成员、角色权限、会话和审计，供司机端、管理端及后续站内应用共用。详细设计见 [全站 Go 后端架构](backend-go.md)。

## 原型与用户流程

[司机登录原型](http://127.0.0.1:8764/next-phase/identity.html) · [全站用户管理原型](http://127.0.0.1:8764/next-phase/identity-admin.html)

1. 司机选择公司，使用受信企业身份登录，进入本人派单；账号页查看组织与退出。
2. 会话过期/退出时保留原账号待同步数据；原账号恢复，其他账号/组织隔离。
3. 管理员选择有权限的组织，查看成员和角色，邀请成员、修改普通角色、停用成员或撤销会话。
4. 管理操作需确认影响：停用本组织访问，不删除配送/outbox 或影响其他组织；审计可查看变更。
5. 只读角色看不到可写能力，版本冲突/最后 owner 保护有明确拒绝；邀请期限与受信身份核验由后台合同单独验收。

司机流程沿用已确认原型；全站管理为此次范围扩展的新原型，待用户确认，不借旧原型确认签字。原型数据、成员、权限与审计全在内存，不发送邀请或调用真实后台。

## 技术方案

Go 模块化单体 + PostgreSQL + REST/OpenAPI，按 identity/session、workspace/membership、authorization、delivery、audit、modelproxy 划分。统一 userId 与 issuer+subject 外部身份映射；同 email 不自动合并。成员资格是 workspace+user，受保护资源必须校验租户和角色/资源权限。组织 admin 不得停用全站用户或越权升角色；管理变更、会话撤销/授权版本和审计保持事务一致。

原生端使用系统浏览器 OIDC Code+PKCE，Go 验证受信身份与一次性登录事务后签发本站会话；Web 使用同源 BFF/HttpOnly cookie/CSRF。本站短期访问会话和轮换 refresh、撤销、企业再验证/离线期限独立建模。App 不收企业密码或持 client secret。跨端 API、模块依赖、Go 目录、表/唯一约束、租户防御、API 草案、并发与部署/恢复均见 [backend-go.md](backend-go.md)。

服务端持久接受原 operationId/payload 后才 ACK；客户端匹配 scope/dataset/operationId/stopId 并事务确认后才移 outbox。去重覆盖离线/重试，401 待重认证，403/永久拒绝保留结果/outbox/依据并停止自动重发。登录和管理变更不删除配送结果；原 scope 有效已接受 ACK 只能收尾原隔离容器。

每 scope 独立 SQLite/计划/提醒与同步协调器；退出、换号、授权失效和重登推进 sessionGeneration，旧 refresh/路线/AI 不污染新 UI 或凭据。legacy/demo 库只有受信 dataset 归属证据才事务迁移，失败回滚。离线超过策略期限锁操作但保留已保存记录。

## Harness 与任务

NP-R01–NP-R03 保留司机生命周期；新增 NP-R17 全站 Go 架构、NP-R18 管理/RBAC/审计。NP15 Go 基础与共享 schema/OpenAPI/迁移，NP02 身份/会话/派单 ACK，NP16 管理 API/权限/审计，NP03 客户端数据隔离，NP04 登录，NP10 装配。管理 Web 原型明确 API 消费边界，生产管理 Web 实施可另拆后续任务，本轮不把浏览器原型当其交付。

NP01 补 Go/数据库/HTTP 观察及门禁，NP11 独立租户/权限/并发/恢复测试，NP12 原生生命周期，NP13 真实 IdP/Go 服务。必须验证 A 离线保存→B 隔离→A 原队列恢复、同 email 不同 issuer、ACK 丢响应/落盘失败、退出后刷新迟到、会话撤销、新请求权限拒绝、跨组织管理员操作、最后 owner 并发保护、邀请/审计事务、Go 进程/数据库重启及迁移恢复。

本项管理原型与新架构齐备后供用户评审，再整理对应 issue。真实 IdP/企业配置、数据库环境和离线期限在 NP00 冻结，产品实现与部署未开始。
