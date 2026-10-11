#!/usr/bin/env python3
"""Render exact local issue bodies; never publish or execute product tasks."""
import hashlib
import json
from pathlib import Path

PACKAGE = Path(__file__).resolve().parent


def render():
    path = PACKAGE / 'backlog.json'
    backlog = json.loads(path.read_text())
    tasks = {task['id']: task for task in backlog['tasks']}
    features = {feature['id']:feature for feature in json.loads((PACKAGE/'feature-contracts.json').read_text())['features']}
    base = f"https://github.com/{backlog['repository']}"
    ref = backlog['source_ref']
    sources = f"[批准原型]({base}/blob/{ref}/prototype/next-phase/README.md) · [方案]({base}/blob/{ref}/docs/next-phase-solution-design.md) · [任务包]({base}/tree/{ref}/harness/project/next-phase)"
    parent = backlog['github_parent']
    for task in tasks.values():
        parent_text = f"[父 Issue #{parent['number']}]({parent['url']})" if parent else '父 Issue：发布时绑定真实 GitHub 身份。'
        dependencies = []
        for dependency in task['depends_on']:
            other = tasks[dependency]
            github = other['github']
            dependencies.append(f"[{dependency} #{github['number']}]({github['url']})" if github else dependency)
        dependencies += [f"[#{number}]({base}/issues/{number})" for number in task['external_dependencies']]
        body = f"<!-- ocean-delivery-next-task:{task['id']}; contract:{backlog['contract_revision']} -->\n"
        body += f"类型：{task['kind']} · 需求：{', '.join(task['requirements'])} · 状态：planned（未实施/未验收）\n\n{parent_text}\n\n"
        body += f"## 目标与来源\n\n{task['title']}。基于 2026-10-12 已确认原型；{sources}。现有产品源码基线 `{backlog['source_baseline']}`；新功能不可借旧 R01–R17 的证据关闭。\n\n"
        body += '本条对应需求的原型与技术方案：\n\n'
        for feature_id in task['features']:
            feature = features[feature_id]
            body += f"- {feature['title']}：[单项原型]({base}/blob/{ref}/{feature['prototype']}) · [单项技术方案]({base}/blob/{ref}/{feature['technical_design']})。\n"
            if feature_id=='F2':
                body += f"  [Go 用户与认证架构]({base}/blob/{ref}/{feature['backend_architecture']})。\n"
        body += '\n每个需求须先具备这两项材料，再发布/更新对应 issue；总方案不能替代单项来源。\n\n'
        body += '本地草稿按最新用户修正：路线客户端直连第三方且不建自己的路线后端；Go后端用户表/认证/会话支撑前端登录，不做B端/用户管理；AI 本期独立客户端执行器，后续同协议 Go Agent。登录沿用已确认原型，不再等待已取消的管理原型确认；远端回执与本地草稿分开记录。\n\n'
        body += '## 依赖与所有权\n\n'
        body += f"依赖：{', '.join(dependencies) if dependencies else '无；合同冻结起点'}。内部依赖由主控核对 accepted 的实际证据，不凭 issue 关闭/PR 合并自动解锁。外部 #31/#32/#33 仅复用既有门槛，不代签本轮增量。\n\n"
        body += f"负责职能：`{task['role']}`；尚未派工，不预填人员账号或排期。允许写域：" + ', '.join(f'`{scope}`' for scope in task['write_scope']) + '。\n\n'
        body += '执行前记录实际 owner、候选 SHA/fingerprint、合同 revision、结果路径和资源租用。共享 schema、模型协议、lock、启动装配、导航/主题与 CI 按任务包单一负责人接力；越界写入需主控调整合同。\n\n'
        body += 'Skill 接力：' + ' → '.join(f'[{skill}]({base}/blob/{ref}/.agents/skills/{skill}/SKILL.md)' for skill in task['skills']) + '。\n\n'
        body += '## 验收条件\n\n' + '\n'.join(f'- [ ] {item}' for item in task['acceptance']) + '\n\n'
        body += f"故障与恢复：{task['recovery']}\n\n"
        body += f"## Harness 与关闭证据\n\n最低功能验证层级：`{task['verification']['level']}`。本任务全部检查为 planned，evidence 为空；静态 check 通过只代表任务包合法。\n\n"
        for command in task['commands']:
            body += f"- `{command['command']}` — {command['availability']}：{command['purpose']}。\n"
        body += '\n未来测试路径/新协议必须实际实现后执行；占位设备 ID 与评测入口必须替换为 NP00/NP01 冻结的有效值，不能复制成当前可运行命令。\n\n'
        body += '交回：' + '；'.join(task['outputs']) + f" {task['handoff']}\n\n"
        body += '报告使用 Harness 精确 attempt/report.json、原始日志/hash、候选前后指纹、运行配置、服务/模型版本、设备与数据来源、逐需求结论。缺失/失败/未运行/旧候选不得 passed；实现进入 review，独立测试/原生/真实服务/真机职能签对应层级后主控 accepted。\n\n'
        body += '默认后台且使用任务专用资源；需要前台步骤时先说明并获得该步骤授权。生产继续 no-go；本条不授权部署、采购、创建凭据或发布。\n'
        (PACKAGE / 'issues' / f"{task['id']}.md").write_text(body)
        task['body_sha256'] = hashlib.sha256(body.encode()).hexdigest()
        # Rendering prepares local expectations; it never manufactures remote receipts.
    body = f"<!-- ocean-delivery-next-epic:NEXT-PHASE; contract:{backlog['contract_revision']} -->\n"
    body += '# 已确认原型后的账号、导航和 AI 助手工程任务\n\n'
    body += '用户于 2026-10-12 确认原型，并授权方案设计与带 Harness 的父子 issue。默认 A 地图首页、企业已有身份系统、外部地图导航、AI 提案人工应用。产品实施尚未开始；创建任务包不代表功能通过或生产发布。\n\n' + sources + '\n\n'
    body += '每项需求的材料：\n\n'
    for feature in features.values():
        body += f"- {feature['title']}：[原型]({base}/blob/{ref}/{feature['prototype']}) · [技术方案]({base}/blob/{ref}/{feature['technical_design']})。\n"
        if feature['id']=='F2':
            body += f"  [Go 用户与认证架构]({base}/blob/{ref}/{feature['backend_architecture']})。\n"
    body += '\n'
    body += '最新范围：导航直连第三方，不建自己的路线后端；Go用户表/认证/会话与前端登录，无B端/用户管理；AI 本期可迁移客户端执行器、后续 Go Agent。管理原型和管理任务已取消，不再是发布前置；本地 draft hash 不是远端读回证据。\n\n'
    body += '## 子任务与顺序\n\n| 任务 | 结果 | 依赖 |\n| --- | --- | --- |\n'
    for task in tasks.values():
        github = task['github']
        link = f"[{task['id']} #{github['number']}]({github['url']})" if github else task['id']
        body += f"| {link} | {task['title']} | {', '.join(task['depends_on']) or '无'} |\n"
    body += '\nGitHub 原生 sub-issues 和 blocked-by 待按本地 DAG 读回核验；当前草稿不证明远端关系完整。全部任务 planned，未虚构负责人/排期。每项正文包含写域、Skill、故障恢复、可运行/未来命令和关闭证据。\n\n'
    body += '## 不变量与完成条件\n\n'
    body += '- [ ] 账号 A/B、legacy、在途 ACK 和 token 生命周期隔离；仅受信持久确认移出原 outbox。\n'
    body += '- [ ] 道路路线/ETA 有来源；外部交接与到站分开，返回正确来源，配送结果继续手动。\n'
    body += '- [ ] 计划 Apply/Undo 原子且版本匹配；站序、下一站、列表一致，不改配送终态/outbox。\n'
    body += '- [ ] 提醒由确定性规则计算，AI 工具权限/schema/配额有效，查询有来源，建议需司机应用。\n'
    body += '- [ ] NP-R01–NP-R17及NP-R19（NP-R18取消） 按候选逐项验收，fixture/网页/模拟器/真机/真实服务不互相代签；NP01 新协议真正实现。\n'
    body += '- [ ] Go用户表/受信首次登录/会话/本人数据归属和时间TTL完成隔离与并发反例；可迁移 AssistantExecutor 合同与受控替换通过；路线不经过自建服务。\n'
    body += '- [ ] 独立回归、原生、真实服务和增量真机性能证据完整，并交接既有发布门槛。\n\n'
    body += f"外部门槛保留 [#31 真机性能]({base}/issues/31)、[#32 强制执行]({base}/issues/32)、[#33 资源/签名/交付]({base}/issues/33)。缺企业 IdP/后端/地图合同/模型配置/设备/预算时对应任务 blocked；本父 issue 关闭不代表生产部署或交付。\n\n"
    body += '当前静态入口 `python3 harness/run.py check` 会核对本包需求、依赖、写域、状态和发布正文；`quality` 验证当前本地基线。新 host/native/live 检查仍为 planned，现有 N1–N7 不覆盖登录/路线/AI。默认后台操作，不占用用户前台。\n'
    (PACKAGE / 'issues/EPIC.md').write_text(body)
    backlog['epic_body_sha256'] = hashlib.sha256(body.encode()).hexdigest()
    path.write_text(json.dumps(backlog, ensure_ascii=False, indent=2) + '\n')
    index = '# 下一阶段 issue 任务图\n\n| 任务 | GitHub | 依赖 |\n| --- | --- | --- |\n'
    for task in tasks.values():
        gh = task['github']
        index += f"| {task['id']} | {[gh['url']][0] if gh else '待发布'} | {', '.join(task['depends_on']) or '无'} |\n"
    (PACKAGE / 'issue-plan.md').write_text(index + '\n全部为 planned。真实负责人/接受证据在 work.json；派工前需用户授权产品实施。\n')


if __name__ == '__main__':
    render()
