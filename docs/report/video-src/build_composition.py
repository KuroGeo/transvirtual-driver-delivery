#!/usr/bin/env python3
"""Create a fixed-phone, timed-proof-panel composition for the measured recording."""
import argparse,json,shutil
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('project',type=Path);a=p.parse_args();project=a.project.resolve()
project.mkdir(parents=True,exist_ok=True)
duration=82.0
panels=[
(0,5,'OCEAN DELIVERY / NATIVE DEMO','离线时，\n也能完成配送。','30 个悉尼站点，真实 Flutter 工作台。\n看一次保存、重启与确认的完整链路。','iOS SIMULATOR  ·  受控 DEMO','map → local save → durable ACK'),
(5,14,'01 / GO OFFLINE','先离线，\n继续工作。','通过界面切到 Offline，再进入站点列表。\n业务保存不依赖实时网络。','OFFLINE','初始：24 pending / 3 completed / 3 failed'),
(14,21,'02 / COMPLETE A STOP','完成第一站。','TV-300002 的配送结果保存在本机。\n结果与不可变 outbox 在同一事务中提交。','LOCAL SAVE','completed  ·  等待同步'),
(21,27,'03 / RECORD A FAILURE','失败，也有记录。','为 TV-300004 选择 Recipient unavailable，\n填写说明，再提交失败结果。','REASON REQUIRED','真实表单操作  ·  driver 模拟文本输入'),
(27,43,'04 / TWO DURABLE EVENTS','结果已经保存，\n确认仍在等待。','离线队列中保留两条更新。\nWaiting to sync 不等于已经收到确认。','QUEUE  2','SQLite + outbox  ·  Offline 已持久化'),
(43,49,'05 / REAL OS RESTART','真正退出进程。','系统终止应用，再在同一安装启动。\n画面保留了实际退出与重新启动。','PID  21377 → 21604','simctl terminate / launch  ·  保留数据库'),
(49,54,'06 / RECOVER FROM DISK','重新打开，\n两条更新还在。','新进程重开原数据库。\n结果、失败说明、Offline 与操作身份保留。','RECOVERED  2','初始快照 + 主机 SQLite 备份核对'),
(54,59,'07 / MATCHING CONFIRMATION','回到 Online，\n串行发送。','受控 HTTP 返回匹配的模拟确认。\n确认先落盘，随后删除对应队列事件。','SIMULATED ACK','operationId / datasetId / stopId 均须匹配'),
(59,66,'08 / QUEUE DRAINED','两条更新，\n都已确认。','确认事务完成，待发队列为 0。\n模拟服务用于演示，真实后端尚未接入。','QUEUE  0','持久化 ACK  ·  原操作身份不变'),
(66,71,'09 / VERIFY ANOTHER LAUNCH','再启动一次。','第二次系统重启，核验确认结果仍在。\n已确认事件不再留在待发队列。','PID  21604 → 21697','同安装 / 同数据库 / 第三个真实进程'),
(71,82,'THE CONSISTENCY CONTRACT','保存可靠，\n确认可追溯。','离线提交 → 跨进程恢复 → 匹配确认落盘。\n客户端保留与重试，真实服务幂等仍需合同。','VERIFIED  2 → 0 → 0','三次真实进程  ·  录制演示，不扩大原生验收范围'),
]
from html import escape
items=[];tweens=[]
for i,(start,end,kicker,title,body,badge,proof) in enumerate(panels):
 items.append(f'<section id="panel-{i}" class="clip panel" data-start="{start}" data-duration="{end-start}" data-track-index="{i+2}"><div class="panel-inner"><p class="kicker">{escape(kicker)}</p><h1>{escape(title).replace(chr(10),"<br>")}</h1><p class="body">{escape(body).replace(chr(10),"<br>")}</p><div class="proof"><b>{escape(badge)}</b><span>{escape(proof)}</span></div></div></section>')
 tweens.append(f'tl.fromTo("#panel-{i} .panel-inner",{{opacity:0,y:12}},{{opacity:1,y:0,duration:.25,ease:"power2.out"}},{start});')
html=f'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=1920,height=1080"><script src="gsap.min.js"></script><style>
@font-face{{font-family:"Hiragino Sans GB";src:local("Hiragino Sans GB");font-weight:400}}@font-face{{font-family:"PingFang SC";src:local("PingFang SC");font-weight:100 900}}*{{box-sizing:border-box;margin:0}}html,body,#root{{width:1920px;height:1080px;overflow:hidden;background:#f5f3eb}}body{{font-family:"Hiragino Sans GB","PingFang SC",sans-serif;color:#262b25}}.header{{position:absolute;left:800px;top:82px;font-family:"JetBrains Mono",monospace;font-size:22px;letter-spacing:2px}}.brand{{color:#b35225;font-weight:700}}.rule{{position:absolute;left:800px;top:137px;width:940px;height:1px;background:#dddcd2}}.phone-shell{{position:absolute;left:192px;top:60px;width:438px;height:952px;border-radius:44px;background:#262b25;box-shadow:0 16px 34px #262b2526}}video{{position:absolute;left:192px;top:60px;width:438px;height:952px;object-fit:contain;border-radius:44px}}.panel{{position:absolute;left:800px;top:225px;width:940px;height:640px}}.panel-inner{{width:940px;height:640px}}.kicker{{font-family:"JetBrains Mono",monospace;font-size:22px;letter-spacing:1px;color:#b35225;margin-bottom:28px}}h1{{font-size:72px;line-height:1.3;letter-spacing:-2px;font-weight:700}}.body{{font-size:30px;line-height:1.8;color:#656c60;margin-top:32px}}.proof{{margin-top:40px;background:#fffdf7;border:1px solid #dddcd2;border-left:5px solid #c65b29;border-radius:20px;padding:25px 30px;display:flex;flex-direction:column;gap:14px}}.proof b{{font-family:"JetBrains Mono",monospace;font-size:28px;color:#446b41}}.proof span{{font-size:22px;color:#656c60}}.footer{{position:absolute;left:800px;top:936px;width:940px;font-size:22px;line-height:1.7;color:#656c60}}.footer b{{color:#262b25}}.progress{{position:absolute;left:800px;top:1020px;height:4px;width:940px;background:#dddcd2}}.fill{{width:940px;height:4px;background:#c65b29;transform-origin:left}}.source{{position:absolute;left:192px;top:1025px;font-size:18px;color:#656c60}}.mono{{font-family:"JetBrains Mono",monospace}}
</style></head><body><div id="root" data-composition-id="main" data-start="0" data-duration="{duration}" data-width="1920" data-height="1080">
<div id="video-header" class="clip header" data-start="0" data-duration="{duration}" data-track-index="0"><span class="brand">↗ ocean delivery</span> / GEORGE YE</div><div class="rule"></div><div class="phone-shell" data-layout-ignore></div><video id="native" class="clip" src="assets-native.mp4" muted playsinline data-start="0" data-duration="{duration}" data-track-index="1"></video>{''.join(items)}
<div id="video-footer" class="clip footer" data-start="0" data-duration="{duration}" data-track-index="14"><b>真实 iOS 模拟器录屏 · 受控模拟确认</b><br>workbench_entry.dart · 无真机、真实服务或签名发布声明</div><div class="progress"><div class="fill"></div></div><div class="source">© OpenStreetMap contributors</div></div><script>
window.__timelines=window.__timelines||{{}};const tl=gsap.timeline({{paused:true}});{''.join(tweens)}tl.fromTo('.fill',{{scaleX:0}},{{scaleX:1,duration:{duration},ease:'none'}},0);window.__timelines['main']=tl;
</script></body></html>'''
(project/'index.html').write_text(html)
(project/'index.motion.json').write_text(json.dumps({'duration':duration,'assertions':[{'kind':'appearsBy','selector':'#panel-0 .panel-inner','bySec':.5},{'kind':'staysInFrame','selector':'video'},{'kind':'staysInFrame','selector':'#panel-0 .proof'}]},indent=2)+'\n')
(project/'cues.json').write_text(json.dumps([{'start':r[0],'end':r[1],'title':r[3]}for r in panels],ensure_ascii=False,indent=2)+'\n')
print('Built',duration,'second composition with fixed native recording and',len(panels),'proof panels.')
