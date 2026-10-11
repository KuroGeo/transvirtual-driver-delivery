'use strict';
const $ = id => document.getElementById(id);
const roles = {owner:'组织所有者',admin:'组织管理员',dispatcher:'调度员',driver:'司机'};
const names = {harbour:'Harbour Logistics',coast:'Coast Courier'};
let state, pending, toastTimer;
const escape = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function reset() {
  clearTimeout(toastTimer); $('toast').hidden=true;
  state = {harbour:[{id:'mia',name:'Mia Chen',email:'mia@example.invalid',role:'owner',status:'active',sessions:1,version:1},{id:'jamie',name:'Jamie Davis',email:'jamie@example.invalid',role:'driver',status:'active',sessions:2,version:1},{id:'sam',name:'Sam Rivera',email:'sam@example.invalid',role:'dispatcher',status:'active',sessions:1,version:1},{id:'robin',name:'Robin Lee',email:'robin@example.invalid',role:'driver',status:'invited',sessions:0,version:1}],coast:[{id:'mia',name:'Mia Chen',email:'mia@example.invalid',role:'owner',status:'active',sessions:1,version:1},{id:'jamie',name:'Jamie Davis',email:'jamie@example.invalid',role:'driver',status:'disabled',sessions:0,version:1}],audit:{harbour:[],coast:[]}};
  $('readonly').checked=false; $('search').value=''; if($('action-dialog').open)$('action-dialog').close(); render();
}
function toast(message) { $('toast').textContent=message; $('toast').hidden=false; clearTimeout(toastTimer); toastTimer=setTimeout(()=>{$('toast').hidden=true;},3500); }
function render() {
  const workspace=$('workspace').value, members=state[workspace], readOnly=$('readonly').checked;
  $('subtitle').textContent=`管理 ${names[workspace]} 的成员、角色和会话。成员停用后，已保存的配送结果仍保留。`;
  $('actor-label').textContent=readOnly?'只读审计视角':'组织所有者'; $('invite').disabled=readOnly;
  $('member-count').textContent=members.length; $('active-count').textContent=members.filter(m=>m.status==='active').length; $('invite-count').textContent=members.filter(m=>m.status==='invited').length;
  const query=$('search').value.toLowerCase();
  $('member-rows').innerHTML=members.filter(m=>(m.name+' '+m.email).toLowerCase().includes(query)).map(m=>`<tr><td><strong>${escape(m.name)}</strong><small>${escape(m.email)}</small></td><td>${roles[m.role]}</td><td><span class="pill ${m.status}">${{active:'正常',disabled:'已停用',invited:'待接受邀请'}[m.status]}</span></td><td>${m.sessions} 个活跃会话</td><td><div class="actions">${m.status==='invited'?'<span>等待成员接受邀请</span>':`<button data-id="${m.id}" data-action="role" ${readOnly?'disabled':''}>修改角色</button><button data-id="${m.id}" data-action="status" ${readOnly?'disabled':''}>${m.status==='active'?'停用':'恢复'}</button><button data-id="${m.id}" data-action="sessions" ${readOnly||!m.sessions?'disabled':''}>撤销会话</button>`}</div></td></tr>`).join('') || '<tr><td colspan="5">没有匹配的成员</td></tr>';
  $('audit-list').innerHTML=state.audit[workspace].map(entry=>`<li><b>${escape(entry.action)}</b><span>${escape(entry.time)} · Mia Chen · ${escape(entry.target)} · ${escape(names[workspace])}</span></li>`).reverse().join('')||'<li><b>暂无本次演示操作</b><span>邀请、角色修改、停用或撤销会话后，记录将出现在这里。</span></li>';
}
function record(action,target) { state.audit[$('workspace').value].push({action,target,time:new Date().toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'})}); }
function show(action,id) {
  if($('readonly').checked)return;
  const workspace=$('workspace').value, member=state[workspace].find(m=>m.id===id);
  pending={action,id,workspace,version:member?.version}; $('dialog-error').textContent=''; $('dialog-fields').innerHTML=''; $('conflict').hidden=action==='invite';
  $('dialog-title').textContent={invite:'邀请新成员',role:'修改成员角色',status:member?.status==='active'?'停用此成员？':'恢复成员访问？',sessions:'撤销当前组织会话？'}[action];
  $('dialog-description').textContent=member?`${member.name} · ${names[workspace]}`:`新成员将通过受信公司身份接受邀请，角色只在 ${names[workspace]} 生效。`;
  $('impact').textContent={invite:'此处只生成内存中的邀请记录，不发送邮件或创建真实账号。',role:'修改后按新角色重新授权，当前组织会话将撤销。最后一位有效所有者不能被降级。',status:'只改变当前组织的访问资格，撤销本组织会话。配送结果和待同步记录保留，其他组织不受影响。',sessions:'本组织已登录设备需要重新登录。不会删除成员或配送数据。'}[action];
  if(action==='invite')$('dialog-fields').innerHTML='<label for="invite-name">姓名</label><input id="invite-name" required maxlength="60" placeholder="成员姓名"><label for="invite-email">公司邮箱</label><input id="invite-email" type="email" required placeholder="name@example.invalid">';
  if(action==='role'||action==='invite')$('dialog-fields').insertAdjacentHTML('beforeend',`<label for="member-role">${action==='invite'?'初始角色':'新角色'}</label><select id="member-role">${Object.entries(roles).filter(([key])=>action!=='invite'||key!=='owner').map(([key,label])=>`<option value="${key}" ${member?.role===key||(!member&&key==='driver')?'selected':''}>${label}</option>`).join('')}</select>`);
  $('action-dialog').showModal();
}
$('member-rows').addEventListener('click',event=>{const button=event.target.closest('button[data-action]');if(button&&!button.disabled)show(button.dataset.action,button.dataset.id);});
$('invite').onclick=()=>show('invite'); $('cancel').onclick=()=>$('action-dialog').close();
$('conflict').onclick=()=>{const member=state[pending.workspace].find(m=>m.id===pending.id);if(member)member.version++;toast('模拟另一名管理员已更新此成员');};
$('action-form').onsubmit=event=>{
  event.preventDefault(); if(!pending||$('readonly').checked||pending.workspace!==$('workspace').value)return;
  const {action,workspace,id}=pending, member=state[workspace].find(m=>m.id===id);
  if(member&&member.version!==pending.version){$('dialog-error').textContent='成员已被更新，请关闭后重新查看，再提交。';render();return;}
  const newRole=$('member-role')?.value;
  if(member?.role==='owner'&&member.status==='active'&&state[workspace].filter(m=>m.role==='owner'&&m.status==='active').length===1&&(action==='status'||action==='role'&&newRole!=='owner')){$('dialog-error').textContent='请先指定另一位所有者；当前组织至少需要一位有效所有者。';return;}
  let result;
  if(action==='invite'){
    const email=$('invite-email').value.trim();if(state[workspace].some(m=>m.email===email)){$('dialog-error').textContent='该邮箱在此组织已有成员或邀请记录。';return;}
    const name=$('invite-name').value.trim();if(!name){$('dialog-error').textContent='请输入姓名。';return;}
    state[workspace].push({id:'invite-'+state[workspace].length,name,email,role:newRole,status:'invited',sessions:0,version:1});result='邀请已生成（演示）';record(result,email);
  } else {
    if(action==='role'){member.role=newRole;member.sessions=0;result='角色已更新，会话已撤销';}
    if(action==='status'){member.status=member.status==='active'?'disabled':'active';member.sessions=0;result=member.status==='disabled'?'成员已停用，业务数据保留':'已恢复访问，请成员重新登录';}
    if(action==='sessions'){member.sessions=0;result='本组织会话已撤销';}
    member.version++;record(result,member.name);
  }
  $('action-dialog').close();render();toast(result);
};
$('workspace').onchange=()=>{if($('action-dialog').open)$('action-dialog').close();$('search').value='';render();}; $('readonly').onchange=()=>{if($('action-dialog').open)$('action-dialog').close();render();}; $('search').oninput=render; $('reset').onclick=reset;
for(const button of document.querySelectorAll('[data-page]'))button.onclick=()=>{const members=button.dataset.page==='members';document.querySelectorAll('[data-page]').forEach(b=>b.classList.toggle('selected',b===button));$('members-page').hidden=!members;$('audit-page').hidden=members;$('page-label').textContent=members?'成员与权限':'操作记录';render();};
reset();
