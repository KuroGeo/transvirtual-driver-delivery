document.addEventListener('alpine:init',()=>{
 Alpine.data('deliveryApp',()=>({
  stops:[],queue:[],history:[],online:true,syncing:false,lastSync:null,page:'stops',filter:'pending',search:'',detailOpen:false,failureOpen:false,selectedId:'TV-300002',reason:'',note:'',reasonError:false,saveError:'',toast:'',toastTimer:null,windowFilter:'all',focusAll:false,syncToken:0,ephemeral:false,
  get key(){return 'transvirtual-prototype-v1-'+document.body.dataset.variant},
  get selected(){return this.stops.find(s=>s.reference===this.selectedId)||this.stops[1]||{}},
  get filterIndex(){return ['all','pending','completed','failed'].indexOf(this.filter)},
  count(status){return status==='all'?this.stops.length:this.stops.filter(s=>s.status===status).length},
  init(){
   const state=new URLSearchParams(location.search).get('state');this.ephemeral=!!state;
   let saved=null;try{saved=JSON.parse(localStorage.getItem(this.key))}catch(_){}
   if(saved&&saved.schema===1&&Array.isArray(saved.stops)&&saved.stops.length===30&&!state){Object.assign(this,{stops:saved.stops,queue:saved.queue||[],history:saved.history||[],online:saved.online,lastSync:saved.lastSync})}
   else this.stops=JSON.parse(JSON.stringify(window.DELIVERIES));
   if(state&&state!=='idle')this.applyPreview(state);
   this.$el.classList.add('entry');setTimeout(()=>this.$el.classList.remove('entry'),800);
   if(this.online&&this.queue.length)this.flush();
   this.$watch('failureOpen',open=>{this.$nextTick(()=>{if(open)this.$refs.reasonFirst?.focus();else if(this.detailOpen)this.$refs.failTrigger?.focus()})});
  },
  applyPreview(state){
   if(['offline','queued','sync','error'].includes(state))this.online=false;
   if(['detail','failure','done','error'].includes(state))this.detailOpen=true;
   if(state==='failure'){this.failureOpen=true;this.reason='';}
   if(state==='done'){this.stops[1].status='completed';this.stops[1].updatedAt='2026-10-10T01:42:00.000Z';this.queue=[{reference:'TV-300002',status:'completed',reason:'',at:'2026-10-10T01:42:00.000Z'}];this.online=false;}
   if(['queued','sync'].includes(state)){for(const [i,status] of [[1,'completed'],[3,'failed']]){const s=this.stops[i];s.status=status;s.failureReason=status==='failed'?'Business closed':'';s.updatedAt='2026-10-10T01:42:00.000Z';this.queue.push({reference:s.reference,status,reason:s.failureReason,at:s.updatedAt})}this.page='sync'}
   if(state==='error')this.saveError='Could not save this update. Nothing has changed. Please try again.';
  },
  snapshot(overrides={}){return {schema:1,stops:JSON.parse(JSON.stringify(this.stops)),queue:JSON.parse(JSON.stringify(this.queue)),history:JSON.parse(JSON.stringify(this.history)),online:this.online,lastSync:this.lastSync,...overrides}},
  write(next){try{if(!this.ephemeral)localStorage.setItem(this.key,JSON.stringify(next));return true}catch(_){this.saveError='Could not save this update. Nothing has changed. Please try again.';return false}},
  notify(message){this.toast=message;clearTimeout(this.toastTimer);this.toastTimer=setTimeout(()=>this.toast='',3100)},
  toggleOnline(){const next=this.snapshot({online:!this.online});if(!this.write(next))return;this.online=next.online;this.syncToken++;if(this.online)this.flush()},
  visible(reference){const s=this.stops.find(s=>s.reference===reference);if(!s)return false;return(this.filter==='all'||s.status===this.filter)&&(!this.search||(s.customer_name+' '+s.address+' '+s.reference).toLowerCase().includes(this.search.toLowerCase()))},
  get visibleCount(){return this.stops.filter(s=>this.visible(s.reference)).length},
  isQueued(reference){return this.queue.some(q=>q.reference===reference)},
  status(reference){return this.stops.find(s=>s.reference===reference)?.status||'pending'},
  label(status){return {pending:'Pending',completed:'Completed',failed:'Failed'}[status]||status},
  openStop(reference){this.selectedId=reference;this.detailOpen=true;this.failureOpen=false;this.saveError='';this.reasonError=false;this.$nextTick(()=>this.$refs.backButton.focus())},
  closeDetail(){this.detailOpen=false;this.failureOpen=false;this.saveError='';this.$nextTick(()=>document.getElementById('stop-'+this.selectedId)?.focus())},
  openFailure(){if(this.selected.status!=='pending'){this.notify('This stop has already been finalised.');return}this.reason='';this.note='';this.reasonError=false;this.failureOpen=true},
  update(status){
   const current=this.selected;if(!current||current.status!=='pending'||!['completed','failed'].includes(status)){this.notify('This stop has already been finalised.');return false}
   const reason=(this.reason==='Other'?this.note:this.reason).trim();if(status==='failed'&&!reason){this.reasonError=true;return false}
   const at=new Date().toISOString();const stops=JSON.parse(JSON.stringify(this.stops));const stop=stops.find(s=>s.reference===current.reference);stop.status=status;stop.failureReason=status==='failed'?reason:'';stop.failureNote=status==='failed'&&this.reason!=='Other'?this.note.trim():'';stop.updatedAt=at;
   const event={reference:stop.reference,status,reason:stop.failureReason,at};const next=this.snapshot({stops,queue:[...this.queue,event]});if(!this.write(next))return false;
   this.stops=stops;this.queue=next.queue;this.saveError='';this.failureOpen=false;this.notify(this.online?'Delivery '+(status==='completed'?'completed':'marked failed')+'. Saved.':'Delivery '+(status==='completed'?'completed':'marked failed')+'. Saved · waiting to sync.');if(this.online)this.flush();return true;
  },
  async flush(){
   if(this.syncing||!this.online||!this.queue.length)return;
   this.syncing=true;const token=this.syncToken;
   try{while(this.queue.length&&this.online&&token===this.syncToken){const event=this.queue[0];await new Promise(r=>setTimeout(r,720));if(!this.online||token!==this.syncToken)break;
    const at=new Date().toISOString();const stops=JSON.parse(JSON.stringify(this.stops));stops.find(s=>s.reference===event.reference).syncedAt=at;
    const next=this.snapshot({stops,queue:this.queue.slice(1),history:[{...event,syncedAt:at},...this.history].slice(0,30),lastSync:at});if(!this.write(next))break;this.stops=stops;this.queue=next.queue;this.history=next.history;this.lastSync=at;
   }}finally{this.syncing=false;if(this.online&&this.queue.length&&token!==this.syncToken)this.flush();else if(this.online&&!this.queue.length)this.notify('All updates synced.')}
  },
  chooseNext(){const s=this.stops.find(s=>s.status==='pending');if(s)this.selectedId=s.reference},
  time(at){return new Date(at).toLocaleTimeString('en-AU',{hour:'2-digit',minute:'2-digit',hour12:false})},
  get street(){return this.selected.address?.split(',')[0]||''},get locality(){return this.selected.address?.split(',').slice(1).join(',').trim()||''},
  get syncTitle(){return this.syncing?'Syncing updates':this.queue.length?this.queue.length+' updates waiting':'Everything is up to date'},
  get syncSub(){return this.syncing?'Your saved updates are being sent.':this.queue.length?(this.online?'Ready to send.':'Go online to send your saved updates.'):'No pending updates on this device.'},
  windowCount(time){return this.stops.filter(s=>s.time_window===time&&(this.filter==='all'||s.status===this.filter)).length},
  escape(){if(this.failureOpen)this.failureOpen=false;else if(this.detailOpen)this.closeDetail()}
  ,trapSheet(event){const controls=Array.from(event.currentTarget.querySelectorAll('button,textarea,input')).filter(el=>!el.disabled&&el.offsetParent);const first=controls[0],last=controls[controls.length-1];if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}}
 }));
});
