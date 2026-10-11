const phone=document.getElementById('phone');
const names={A:'地图提醒',B:'下一站卡片',C:'助手工作台'};
const scenes={home:'地图工作台',login:'公司账号登录',stop:'站点详情',navigation:'导航预览',assistant:'Ocean 助手',plan:'建议派送顺序',profile:'账号与偏好',offline:'离线状态',expired:'登录过期',unavailable:'助手不可用',stale:'建议过期'};
const params=new URLSearchParams(location.search);
const feature=document.body.dataset.feature;
const defaultScene=document.body.dataset.defaultScene||'home';
let variant=!feature&&['A','B','C'].includes(params.get('variant'))?params.get('variant'):'A';
let scene=params.get('scene')||(feature?defaultScene:variant==='C'?'assistant':'home');
function syncReview(){document.querySelectorAll('[data-variant]').forEach(b=>{const active=b.dataset.variant===variant;b.classList.toggle('selected',active);b.setAttribute('aria-pressed',active)});document.querySelectorAll('[data-scene]').forEach(b=>b.classList.toggle('active',b.dataset.scene===scene));document.getElementById('variant-caption').textContent=variant+' · '+names[variant];document.getElementById('scene-caption').textContent=(scenes[scene]||scene)+' · 方案 '+variant;const p=new URLSearchParams({variant,scene});history.replaceState(null,'',location.pathname+'?'+p)}
function send(type,value){phone.contentWindow.postMessage({type,...value},location.origin)}
function setScene(value){scene=value;send('ocean-scene',{scene});syncReview()}
function setVariant(value){variant=value;scene=value==='C'?'assistant':'home';send('ocean-variant',{variant});syncReview()}
document.querySelectorAll('[data-scene]').forEach(b=>b.addEventListener('click',()=>setScene(b.dataset.scene)));
document.querySelectorAll('[data-variant]').forEach(b=>b.addEventListener('click',()=>setVariant(b.dataset.variant)));
function cycle(direction){if(feature)return;const keys=Object.keys(names);setVariant(keys[(keys.indexOf(variant)+direction+3)%3])}
document.getElementById('previous').onclick=()=>cycle(-1);document.getElementById('next').onclick=()=>cycle(1);document.getElementById('restart').onclick=()=>{scene=feature?defaultScene:'home';phone.src='phone.html?state=idle&variant='+variant+'&scene='+scene;syncReview()};
document.addEventListener('keydown',e=>{if(/INPUT|TEXTAREA|SELECT/.test(e.target.tagName)||e.target.isContentEditable)return;if(e.key==='ArrowLeft')cycle(-1);if(e.key==='ArrowRight')cycle(1)});
window.addEventListener('message',event=>{if(event.origin!==location.origin||event.source!==phone.contentWindow||event.data?.type!=='ocean-state')return;const panel=event.data.panel;if(scenes[panel]){scene=panel;syncReview()}});
phone.src='phone.html?state=idle&variant='+variant+'&scene='+encodeURIComponent(scene);syncReview();
