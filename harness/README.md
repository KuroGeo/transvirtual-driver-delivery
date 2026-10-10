# 工程入口

先读 [需求合同](project/mission.md) 与 [接口合同](project/contracts.md)，按 [产品任务图](project/backlog.json) 选择依赖已满足的任务，在 [执行任务板](project/work.json) 分配负责人、写域和审查。任务图保存产品路线，执行板记录具体派工；已通过的可靠性基线可复用，领取任务时按当前候选复核。

| 位置 | 职责 |
| --- | --- |
| `app/` | Flutter 客户端、平台配置与行为测试 |
| `.agents/skills/` | 九个按需调用的工程职能 |
| `harness/project/` | 需求、接口、任务图和执行记录，职责分别维护 |
| `harness/*.py`、`tests/` | 命令、仓库边界、资源锁、生产门禁、原生探针及回归 |
| `harness/reports/` | [能力审计](reports/readiness.md)、[验证状态](reports/status.json)、[协作演练结论](reports/rehearsal.md) |
| `harness/runs/` | 自动生成的逐次日志、报告与资源锁，不进入 Git |
| `harness/archive/` | 历史准备材料、完整演练证据及当时源码快照 |

产品题目和架构在 `docs/`，交互设计在 `prototype/`。工具模块和职能 skill 保留独立边界；历史记录归档，不作为当前实施说明。

## 日常命令

Python 3、Flutter **3.44.2** / Dart **3.12.2**；SDK 记录在 `app/.fvmrc`，依赖由 `app/pubspec.lock` 锁定。从仓库根目录首次解析依赖：

```sh
cd app
flutter pub get --enforce-lockfile
cd ..
python3 harness/run.py quality
```

`quality` 检查链接、需求覆盖、任务 DAG、Dart 层次依赖、Harness 回归、SDK、格式、静态分析及全部 Flutter host/widget 测试。只检查仓库和 Harness 用 `check`；迭代单个行为用 `test --target test/widget_test.dart`。错误给文件、命令、退出码和原始日志。

macOS + Xcode + CocoaPods + iOS 26.4 runtime：`python3 harness/run.py build` 构建正式启动入口，`native` 构建独立探针，在任务专用模拟器用三个 OS 进程验证保存、重启恢复、模拟串行确认和不重发。全程 CLI 后台执行，结束仅删除自己创建的设备；debug/fake 结果仅证明本地可靠性。

## 协作、恢复与门禁

[团队 skill](../.agents/skills/agent-engineering-team/SKILL.md) 协调需求提取、Issue、开发、测试、原生验收、性能、Harness 和交付。每次只调用任务所需职能；共享接口、依赖锁、schema、启动装配和 CI 各由一个负责人写，独立职能审查后接受。

运行记录在 `harness/runs/<时间-命令>/`，命令操作由 OS lease 保护。SIGTERM/Ctrl-C 终止子进程并归还锁；同候选可用 `python3 harness/run.py quality --resume harness/runs/<原运行目录>`。恢复核对候选、活 PID、实际锁和日志 hash；Agent 是否活跃由协作 runtime 判断。

生产执行 `python3 harness/run.py gate --manifest harness/runs/<交付目录>/manifest.json`。[门禁](gate.py) 校验 H01–H08 / G0–G6、当前候选、原始证据 hash、设备/性能层级、签名与授权。G1 必须引用 `quality-run` 原始报告，并验证前后候选、全部必需阶段及日志 hash。缺证失败是正确结果；CI/发布强制接线未部署，当前生产 **no-go**。

## 历史证据

[2026-10-10 原始归档](archive/2026-10-10-engineering.tar.gz) 含419个保全文件和 `ARCHIVE-MANIFEST.json`，每个文件保存 SHA-256 与长度。归档 SHA-256：`d3b7fc7275f7672a050f346449d4e9d8e726bea2e6997eada8c29f253cb45f59`。完整日志、旧准备稿和原候选源码均在其中，当前结论见 [演练报告](reports/rehearsal.md)。

需要复查时解包到独立临时目录，保留归档中的原路径；不能解包覆盖当前源码，也不能将旧原生证据改签为当前版本：

```sh
archive_dir=$(mktemp -d)
tar -xzf harness/archive/2026-10-10-engineering.tar.gz -C "$archive_dir"
```
