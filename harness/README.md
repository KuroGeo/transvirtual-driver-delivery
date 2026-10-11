# 工程入口

下一阶段账号/导航/AI 已确认原型的方案与父子任务见 [next-phase 准备包](project/next-phase/README.md)。`check/quality` 同时核对其结构和候选输入；新产品检查仍 planned，实施与原生/真实服务门禁扩展由 NP00/NP01 后续启动。

先读 [需求合同](project/mission.md) 与 [接口合同](project/contracts.md)，按 [产品任务图](project/backlog.json) 选择依赖已满足的任务，在 [执行任务板](project/work.json) 分配负责人、写域和审查。[本轮 Issue 拆分与接力](project/issue-plan.md) 说明原型/架构增量、真实父子 Issue 和 Skill/Harness 联动。任务图保存产品路线，执行板记录具体派工；已通过的可靠性基线可复用，领取任务时按当前候选复核。

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

Python 3、Flutter **3.44.2** / Dart **3.12.2**；SDK 记录在 `app/.fvmrc`，依赖由 `app/pubspec.lock` 锁定。从仓库根目录执行，依赖准备与测试使用同一资源租用：

```sh
python3 harness/run.py pub
python3 harness/run.py quality --isolated
```

`quality` 检查链接、需求覆盖、任务 DAG、Dart 层次依赖、Harness 回归、SDK、锁定依赖、格式、静态分析及全部 Flutter host/widget 测试。`--isolated` 在候选指纹一致的任务副本执行，同时核对原工作区和执行副本末态；产物保留后只清理自己的副本。只检查仓库和 Harness 用 `check`；迭代单个行为用 `test --target test/widget_test.dart`。错误给文件、命令、退出码和原始日志。

配置用 `--configuration demo|local-client`，缺省为 local-client（UnavailableTransport）；demo 的模拟确认使用独立业务库。构建支持 `--build-mode debug|profile|release` 与 `--ios-target simulator|device`，模拟器只支持 debug，device 为本地 unsigned/no-codesign 候选。`--entrypoint lib/<实际文件>.dart` 只能选 app/lib 内现存入口；不自动改正式启动。

`integration --target integration_test/<实际文件>.dart --device <显式设备ID>` 是独立的原生测试入口，仅当文件存在且设备已明确分配时执行，不从用户设备自动选取。

macOS + Xcode + iOS 26.4 runtime（当前 Flutter iOS 工程使用 Swift Package Manager）：`python3 harness/run.py build` 构建正式启动入口，`native` 构建独立探针，在任务专用模拟器用三个 OS 进程验证保存、重启恢复、模拟串行确认和不重发。`native --scope startup --configuration demo --isolated` 从正式入口验证启动 PID 与截图；它是 startup smoke，不能代签完整 UI 验收。全程 CLI 后台执行，结束仅删除自己创建的设备；debug/fake 结果仅证明本地可靠性。native 子工具须继承 runner 实际持有的 flock FD，直调或伪环境声明不能绕过资源租用。

完整工作台的原生工具使用固定私有入口 `integration_test/workbench_entry.dart`，挂载正式 App、原生 SQLite 和批准的 CSV；底图从首次挂载起只访问任务 HTTP fixture。只读桥观测候选、实际 VM/PID、每次启动的 session、业务库、地图与界面。所有业务动作通过外部 FlutterDriver 操作真实 UI，宿主负责 OS 终止/重启、SQLite backup、截图和任务设备清理：

```sh
python3 harness/run.py native --scope workbench --configuration demo --isolated --timeout 600
python3 harness/run.py native --scope workbench --configuration local-client --isolated --timeout 600
```

默认 driver 是工具 smoke，验证三进程接线，不签完整产品 G2。独立验收可用 `--driver-target integration_test/<现存验收driver>.dart`；它与配置、私有入口、fixture 一同进入恢复身份。`--fixture legacy-v1-identity-seq` 只供独立 driver，在新任务容器尚无业务库时建立真正的 v1 数据，保留原身份、队列序号和未知历史字段。默认客户端仍使用 UnavailableTransport；demo 的 HTTP ACK 明确标记模拟服务。原生键盘需实际 Insets 与 OS 截图证明，driver 文本模拟另行标记。后台能力不足的项单独记录，不升级到用户前台。

完整原生验收按 [34项检查合同](project/native-acceptance-contract.json) 分组执行；各组实际结果见当前报告，代码存在不等于场景已验收。每个分组选择 `--scenario N1..N7`，报告保留各 phase 的动作、快照、OS PNG 与 SQLite backup。示例：

```sh
python3 harness/run.py native --scope workbench --driver-target integration_test/acceptance_driver.dart --scenario N1 --configuration demo --isolated --timeout 1200
python3 harness/run.py native --scope workbench --driver-target integration_test/acceptance_driver.dart --scenario N6 --fixture legacy-v1-identity-seq --migration-fault --configuration demo --isolated --timeout 1200
```

`--runtime` / `--device-type` 使用实际 CoreSimulator ID；`--content-size` / `--reduce-motion` 只作用于新任务设备，验收仍检查 App 实际 MediaQuery 与平台 AccessibilityFeatures（iOS Reduce Motion 是独立 reduceMotion 标志）。N5 可选 `--initial-tiles 503 --cold-fixture viewport-corrupt|viewport-nonfinite`，故障只在两个已区分的进程之间修改任务视口设置，不触碰业务行。所有源写入者冻结后再执行这些命令；同一资源上的依赖、构建和设备工作由 Harness 串行租用。

## 协作、恢复与门禁

[团队 skill](../.agents/skills/agent-engineering-team/SKILL.md) 协调需求提取、Issue、开发、测试、原生验收、性能、Harness 和交付。每次只调用任务所需职能；共享接口、依赖锁、schema、启动装配和 CI 各由一个负责人写，独立职能审查后接受。

运行记录在 `harness/runs/<时间-命令>/`，命令操作由 OS lease 保护。每次执行写入新的 `attempts/000001/` 等目录，门禁引用该次叶子 `report.json` 与原始日志；运行根目录的状态镜像和 `latest.json` 只用于发现最新执行。后续恢复保留前次叶子报告、失败日志和产物原字节。旧格式运行也保留原文件，不就地重写。

同候选可用 `python3 harness/run.py quality --resume harness/runs/<原运行目录>`。恢复核对候选、配置/入口/设备/阶段计划、最新指针、原始 hash、活 PID 和实际锁；隔离工作区重新运行阶段，两种证据门禁重新读取外部证据。SIGTERM/Ctrl-C 请求终止自己的进程组并记录实际退出/回收事实；原生应用阶段有单独的有限清理窗口，设备和 App 的清理仍由原生采集器证明。SIGKILL 后清理状态未知时拒绝恢复，不能把锁释放或 Agent 返回当作设备已清理。父进程关闭自己的锁 FD，存活的继承者仍保持实际 flock；不删锁文件绕过。Agent 是否活跃由协作 runtime 判断。当前恢复实现是否验收以 X04 的实际评测报告为准。

本地交付执行 `python3 harness/run.py local-gate --manifest <仓库根目录的本地manifest.json>`，判定当前完整 G1/G2/本地资源证据，publish_allowed 始终为 false。生产执行 `python3 harness/run.py gate --manifest <仓库根目录的生产manifest.json>`。[门禁](gate.py) 校验 H01–H08 / G0–G6、当前候选、原始证据 hash、设备/性能层级、签名与授权。所有原始引用都必须处于 manifest 的规范根目录内，不能用 symlink 或目录跳转替代；报告中的实际绝对路径保留原值。G1 必须引用 `quality-run` 原始报告，验证前后候选、全部必需阶段及日志 hash。两种门禁 resume 都重新执行。缺证失败是正确结果；CI/发布强制接线未部署，当前生产 **no-go**。

## 历史证据

本地 `harness/archive/2026-10-10-engineering.tar.gz` 原始归档 含419个保全文件和 `ARCHIVE-MANIFEST.json`，每个文件保存 SHA-256 与长度。归档 SHA-256：`d3b7fc7275f7672a050f346449d4e9d8e726bea2e6997eada8c29f253cb45f59`。该包含原始题目资料，已取消 Git 跟踪并加入 ignore，仅保留本地原件。完整日志、旧准备稿和原候选源码均在其中，当前结论见 [演练报告](reports/rehearsal.md)。

持有本地原件并需要复查时，解包到独立临时目录，保留归档中的原路径；不能解包覆盖当前源码，也不能将旧原生证据改签为当前版本：

```sh
archive_dir=$(mktemp -d)
tar -xzf harness/archive/2026-10-10-engineering.tar.gz -C "$archive_dir"
```
