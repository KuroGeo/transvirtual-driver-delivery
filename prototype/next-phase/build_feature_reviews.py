"""Separate the approved shared prototype into one review entry per requirement."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
FEATURES = {
    'routing': ('路径规划与导航', '到下一站，<br>路线清楚。', '站点详情 → 道路路线预览 → 选择导航应用 → 返回原站点。',
                [('stop','01','站点与目的地','从当前派送任务开始'),('navigation','02','道路路线预览','距离、预计到达与路线来源'),('home','03','返回配送工作台','下一站与地图上下文')]),
    'identity': ('登录与用户系统', '用自己的账号，<br>接回自己的任务。', '公司工作区 → 已有身份系统 → 司机任务；过期与退出时保留原账号待同步结果。',
                 [('login','01','公司已有账号登录','工作区与公司身份系统'),('profile','02','账号与所属公司','身份、偏好与退出入口'),('expired','03','登录过期与待同步','原账号重新登录恢复'),('home','04','登录后的当天任务','回到地图配送工作台')]),
    'assistant': ('AI 助手与智能派送', '下一站和时效，<br>随时有依据。', '时间窗提醒 → 下一站与风险查询 → 比较派送方案 → 手动应用与撤销。',
                  [('home','01','时效提醒与下一站','融入地图首页'),('assistant','02','有依据的助手回答','下一站、风险和派送建议'),('plan','03','比较与应用派送顺序','人工应用与撤销'),('stale','04','方案已过期','重新计算后才能应用'),('offline','05','离线时查询','缓存事实与在线能力分开'),('unavailable','06','助手服务失败','重试与普通配送入口')]),
}
template = (ROOT/'index.html').read_text()
for feature,(title,headline,summary,scenes) in FEATURES.items():
    additions = {
        'routing':'客户端直连第三方道路能力，不新增自己的路线后端。预览不可用时仍可交接地图导航。',
        'identity':'Go后端只做用户表、认证与会话，前端登录/退出/恢复；不做B端或用户管理。',
        'assistant':'本期客户端执行器与核心/工具分层，后续切换 Go 服务端执行器；用户交互保持一致。',
    }
    flow = ''.join(f'<button data-scene="{scene}"><span>{number}</span><div><strong>{label}</strong><small>{hint}</small></div><span>↗</span></button>' for scene,number,label,hint in scenes)
    panel = f'''<aside class="review-panel"><a class="review-brand" href="index.html"><img src="../assets/app-icon-180.png" alt=""><span>ocean delivery</span><span class="review-stage">{title}</span></a>
<p class="review-eyebrow">单项需求原型</p><h1>{headline}</h1><p class="review-summary">{summary}</p>
<nav class="review-flow" aria-label="{title}评审流程">{flow}</nav>
<div class="review-boundary"><span class="boundary-dot"></span><p>采用已确认的手机交互，账号、道路路线、导航交接和 AI 均为模拟。{additions[feature]} 本项技术方案与验收映射在对应需求文档。</p></div>
<p class="canvas-hint"><a href="index.html">返回三项需求总览</a></p></aside>'''
    page = re.sub(r'<aside class="review-panel">.*?</aside>',panel,template,flags=re.S)
    page = page.replace('<body>',f'<body data-feature="{feature}" data-default-scene="{scenes[0][0]}">')
    page = page.replace('Ocean Delivery · 下一阶段原型评审',f'Ocean Delivery · {title}原型')
    page = page.replace('</head>','<style>.variant-switcher{display:none}</style></head>')
    (ROOT/f'{feature}.html').write_text(page)
