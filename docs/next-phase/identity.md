# 需求 2：Go 用户表与前端登录

2026-10-12 用户最新澄清：不做 B 端或用户管理，只需后端用户表、设计和认证架构，以及前端登录等用户能力。保留 Go 技术选择，详细设计见 [Go 用户与认证架构](backend-go.md)。

## 原型与用户流程

[已确认的登录原型](http://127.0.0.1:8764/next-phase/identity.html) · [源码](../../prototype/next-phase/identity.html)

1. 用户通过受信公司身份系统登录，回到本人派单。
2. 账号页展示本人基本资料、偏好和退出入口。
3. 会话过期时原账号重新登录，已保存的结果和待同步数据保留。
4. 退出清凭据并锁视图，另一个账号使用隔离数据；原账号恢复后继续原队列。

沿用已确认的手机流程，删除此前扩展的管理原型；没有管理原型审批前置条件。原型身份/认证仍为模拟，不能代签 Go 或真实登录。

## 技术方案

Go 模块化单体 + PostgreSQL，模块为 identity/users/session、delivery 和 modelproxy。用户表包含内部 userId、基础资料、status/auth_revision 与创建/更新/登录时间；external_identities以 issuer+subject唯一关联，sessions/refresh_tokens/login_transactions负责访问会话、刷新轮换和一次性登录。具体字段、索引/事务、时间/TTL、API、目录和部署恢复见 [backend-go.md](backend-go.md)。

没有管理员端、用户列表/管理 API、组织成员、邀请或角色配置/RBAC平台。既有 workspaceId 只作为受信数据 namespace 保持协议兼容，不增加组织管理实体。首次可信登录按策略事务创建/取得用户，App 只读自己的 /me 和派单，服务端依据会话/用户/资源归属鉴权。

原生端系统浏览器 OIDC Code+PKCE，Go 验证受信身份/一次性登录事务后签发短期本站会话；App安全存储、单一在途refresh，服务器SQL锁/CAS保证多副本轮换原子性。登录方式沿用原型工程默认；企业具体配置在 NP00 冻结，不自动新增注册/找回密码。用户表/会话状态属于后端基础设施，不等于用户管理产品。

每 AccountScope 独立 SQLite/计划/提醒和同步协调器；退出/换号/授权失效/重登推进 sessionGeneration，旧 refresh/路线/AI 不污染新 UI 或凭据。legacy/demo库只有受信dataset归属才迁移，失败回滚；离线超期锁操作但保留记录。服务端持久接受原operationId/payload才ACK，客户端匹配并事务落盘才清outbox；401待重认证，403/永久拒绝保留结果和依据，停止自动重发。

## Harness 与任务

NP-R01–NP-R03为登录/用户数据/同步可靠性；NP-R17为Go基础用户认证架构。NP15负责Go基础/schema/OpenAPI/迁移，NP02用户/认证/会话/派单ACK，NP03客户端隔离，NP04登录，NP10装配。删除NP16用户管理及NP-R18管理需求，不把它们改名留在后续产品任务里。

NP01提供Go/HTTP/数据库/会话观察与门禁，NP11独立用户隔离/首次登录并发/refresh/时钟/恢复回归，NP12原生登录退出/真正杀进程，NP13真实IdP/Go联调。旧网页/fixture不能代签。原型与方案现已分别对应本项，不再等待已取消的管理原型确认；产品实现未开始。
