# 需求 2：登录与用户系统

本项单独对应用户的“让用户可以用自己的系统登录”。工程默认是企业已有身份系统；具体协议/供应商/公司配置由 NP00 冻结，非 OIDC 系统可采用服务端身份桥接。

## 原型与用户流程

[单项可点击原型](http://127.0.0.1:8764/next-phase/identity.html) · [原型源码](../../prototype/next-phase/identity.html)

1. 输入公司工作区，进入公司的身份登录流程，登录后展示本人当天任务。
2. 账号页查看司机与所属公司、偏好和退出入口。
3. 会话过期时提示重新登录；已保存的待同步结果保留，原账号恢复后继续。
4. 退出清登录凭据并锁业务视图，明确保留待同步数量；另一个账号使用独立数据。

原型身份与认证为模拟，尚未连接 IdP、安全存储或真实 A/B 账号。原型确认记录与证据见 [README](../../prototype/next-phase/README.md)。

## 技术方案

SessionRepository 提供登录/刷新/过期/退出状态机；platform 提供系统浏览器认证回调与安全存储。采用受信公司配置、Authorization Code + PKCE、一次消费 state/nonce、issuer/audience 与回调核验；App 不持 client secret，不收企业密码。身份认证与业务派单授权分开，官方依据见 [总方案账号章节](../next-phase-solution-design.md#账号与同步一致性)。

服务端将受信 issuer+subject 映射为 workspaceId+principalId，邮箱/昵称不作为身份主键。所有派单、结果、路线、工具及 ACK 都验证 scope/dataset/站点权限；同 operationId 不同 payload 拒绝，服务端持久接受并去重后才 ACK。去重保留覆盖最大离线与重试期；401 暂停待原账号重认证，403/撤权/永久业务拒绝保留结果/outbox 和依据并停止自动重发。

每 scope 独立业务容器、SQLite、计划/提醒设置与同步协调器。退出、授权失效、开始新认证、换号均递增 sessionGeneration；旧查询/refresh/路线/AI 不得恢复会话或污染新 UI/凭据。尚未超时且匹配原请求的 ACK 可在开放的隔离旧容器收尾，不能触碰新账号；超时 ACK 拒收。原账号重新认证可以恢复其原 operationId 队列。

SQLite v2 旧库无账号归属，先进入 legacy/demo 隔离区，只有服务端证明 dataset 归属才事务迁移；迁移失败回滚。退出不删除业务记录，清除本地数据是独立显式操作。refresh 单一在途，按 IdP 旋转或 sender constraint 处理重放防护；安全存储失败不宣告登录成功。离线读写期限与撤权由企业策略冻结，超限锁操作但保留已保存结果。

## Harness 与 issue 拆分依据

覆盖 NP-R01–NP-R03；拆分 NP02 服务授权与 ACK、NP03 账号数据隔离、NP04 登录生命周期，NP10 负责共享装配。NP01 先实现 scope/generation/身份 fixture 和门禁，NP11 独立回归，NP12 真正杀原生进程恢复，NP13 真实企业身份与派单联调。

必须验证：A 离线保存→退出→B 无法读/发送 A→A 重登保留原队列；A 在途 ACK 后切 B 只收尾 A；同 email 不同 issuer 不合并；退出后迟到刷新不能复活；持久接受但响应丢失重试一次；本地 ACK 落盘失败不清队列；迁移/凭据失败可恢复。真实 SSO、撤权与后台服务日志单独签字，fixture 不代签。

先准备本项原型和技术方案，再以这些来源编写对应 issue。真实 IdP、客户端/回调、角色账号、派单服务与离线策略属于外部依赖，不预先创建密钥或部署服务。
