# Ocean Delivery 工程协作

团队工程工作先读取 [.agents/skills/agent-engineering-team/SKILL.md](.agents/skills/agent-engineering-team/SKILL.md)，任务包见 [harness/README.md](harness/README.md)。单项工作只加载对应职能 skill。

已有原型和架构；Flutter 客户端位于 app/，工程执行入口和状态位于 harness/。当前执行范围是 Harness 与 Flutter 本地可靠性基线；完整产品按任务图后续推进。用户指令决定范围，实施文档不自动授权外部发布。

功能范围为现有原型配送工作台。最新直接同步和按来源返回修正规则优于历史同步抽屉资料；架构负责 SQLite/outbox 和确认可靠性；网页证据不能当 Flutter 证据。

主控维护共享任务板和决策。接口、pubspec/lock、schema、启动装配、导航、主题和 CI 各由指定单一负责人写；子 Agent 在约定文件范围内工作并提交版本与证据。

用户要求 Harness Engineering 达标才准上线。先读 [Harness 审计](harness/reports/readiness.md) 和 [状态](harness/reports/status.json)，由 [Harness 职能](.agents/skills/harness-engineering/SKILL.md) 补执行环境、机械边界、可观察工具、门禁和恢复评测。当前生产 no-go；准备材料或 skill 测试不授予上线资格。用 `python3 harness/run.py quality` 验证候选；独立原生进程测试用 `native`。发布任务不得绕过实际 Harness 与产品门槛。

## 浏览器和桌面共存

交互式 Chrome 工作先读 `jev-browser`，由其选择 Jev 或 Browser Harness；用户指定工具时遵从用户。公共信息检索用普通 web 工具。

默认后台，优先 CLI/API/连接器和任务专用标签。不能导航、切换、关闭或激活用户窗口/标签，不能打断视频、全屏和焦点。Browser Harness 后台 attach/switch 可用，`activate_tab` 等前台操作需用户明确授权。

后台失败不授权升级为前台鼠标/键盘操作。确需前台步骤先说明具体需要并等待授权，继续独立后台工作。原生验收/性能同样遵守。
