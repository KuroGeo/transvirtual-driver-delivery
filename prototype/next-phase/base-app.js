document.addEventListener('alpine:init',()=>{
 Alpine.data('deliveryApp',()=>{const base={
  stops:[],queue:[],history:[],online:true,syncing:false,lastSync:null,page:'stops',filter:'pending',search:'',searchOpen:false,detailOpen:false,failureOpen:false,selectedId:'TV-300002',reason:'',note:'',reasonError:false,saveError:'',toast:'',toastType:'success',toastIsSync:false,toastTimer:null,windowFilter:'all',focusAll:false,syncToken:0,ephemeral:false,listOpen:false,detailFromList:false,listScrollTop:0,listRestorePending:false,mapFailed:false,
  get isMap(){return document.body.dataset.map==='true'},
  get key(){return 'transvirtual-prototype-v1-'+document.body.dataset.variant},
  get selected(){return this.stops.find(s=>s.reference===this.selectedId)||this.stops[1]||{}},
  get filterIndex(){return ['all','pending','completed','failed'].indexOf(this.filter)},
  count(status){return status==='all'?this.stops.length:this.stops.filter(s=>s.status===status).length},
  init(){
   const state=new URLSearchParams(location.search).get('state');this.ephemeral=!!state;
   let saved=null;try{saved=JSON.parse(localStorage.getItem(this.key))}catch(_){}
   if(saved&&saved.schema===1&&Array.isArray(saved.stops)&&saved.stops.length===30&&!state){Object.assign(this,{stops:saved.stops,queue:saved.queue||[],history:saved.history||[],online:saved.online,lastSync:saved.lastSync})}
   else this.stops=JSON.parse(JSON.stringify(window.DELIVERIES));
   if(this.isMap)this.filter='all';
   if(state&&state!=='idle')this.applyPreview(state);
   this.$el.classList.add('entry');setTimeout(()=>this.$el.classList.remove('entry'),800);
   if(this.online&&this.queue.length)this.flush();
   this.$watch('failureOpen',open=>{this.$nextTick(()=>{if(open)this.$refs.reasonFirst?.focus();else if(this.detailOpen)this.$refs.failTrigger?.focus()})});
   if(this.isMap){
    for(const key of ['stops','queue','filter','search','detailOpen'])this.$watch(key,()=>this.$nextTick(()=>this.syncMap()));
    this.$nextTick(()=>MapWorkspace.start(this,this.$refs.mapCanvas));
    this.$watch('mapFailed',()=>this.$nextTick(()=>{if(this.detailOpen)MapWorkspace.focus(this.selectedId,false);else MapWorkspace.fit()}));
   }
  },
  applyPreview(state){
   if(['offline','queued','sync','syncerror','error'].includes(state))this.online=false;
   if(['detail','failure','done','error'].includes(state))this.detailOpen=true;
   if(state==='failure'){this.failureOpen=true;this.reason='';}
   if(state==='done'){this.stops[1].status='completed';this.stops[1].updatedAt='2026-10-10T01:42:00.000Z';this.queue=[{reference:'TV-300002',status:'completed',reason:'',at:'2026-10-10T01:42:00.000Z'}];this.online=false;}
   if(['queued','sync','syncing','synced','syncerror'].includes(state)){for(const [i,status] of [[1,'completed'],[3,'failed']]){const s=this.stops[i];s.status=status;s.failureReason=status==='failed'?'Business closed':'';s.updatedAt='2026-10-10T01:42:00.000Z';this.queue.push({reference:s.reference,status,reason:s.failureReason,at:s.updatedAt})}}
   if(state==='synced'){this.history=this.queue.map(event=>({...event,syncedAt:event.at}));this.queue=[];this.lastSync=this.history[0].syncedAt;this.notifySync('2 updates synced.')}
   if(state==='syncerror')this.notifySync('Could not sync. 2 updates are still saved.','error');
   if(state==='uptodate')this.notifySync('Everything is up to date.');
   if(state==='error')this.saveError='Could not save this update. Nothing has changed. Please try again.';
   if(state==='list')this.listOpen=true;
   if(state==='maperror')this.mapFailed=true;
  },
  snapshot(overrides={}){return {schema:1,stops:JSON.parse(JSON.stringify(this.stops)),queue:JSON.parse(JSON.stringify(this.queue)),history:JSON.parse(JSON.stringify(this.history)),online:this.online,lastSync:this.lastSync,...overrides}},
  write(next){try{if(!this.ephemeral)localStorage.setItem(this.key,JSON.stringify(next));return true}catch(_){this.saveError='Could not save this update. Nothing has changed. Please try again.';return false}},
  notify(message,type='success',duration=3600,isSync=false){this.toast=message;this.toastType=type;this.toastIsSync=isSync;clearTimeout(this.toastTimer);if(duration)this.toastTimer=setTimeout(()=>this.toast='',duration)},
  notifySync(message,type='success',duration=3600){this.notify(message,type,duration,true)},
  syncUpdates(){
   if(this.syncing){this.notifySync('Syncing '+this.updateCountLabel+'…','progress',0);return}
   if(!this.online){this.notifySync(this.queue.length?'Offline · '+this.updateCountLabel+' saved for later.':'Offline · connect to check for updates.','info');return}
   if(!this.queue.length){this.notifySync('Everything is up to date.');return}
   return this.flush();
  },
  toggleOnline(){const next=this.snapshot({online:!this.online});if(!this.write(next))return;this.online=next.online;this.syncToken++;if(this.online)this.flush()},
  visible(reference){const s=this.stops.find(s=>s.reference===reference);if(!s)return false;return(this.filter==='all'||s.status===this.filter)&&(!this.search||(s.customer_name+' '+s.address+' '+s.reference).toLowerCase().includes(this.search.toLowerCase()))},
  get visibleCount(){return this.stops.filter(s=>this.visible(s.reference)).length},
  distanceMeters(stop){
   const driver=window.MAP_CONFIG.driver,r=Math.PI/180;
   const a=Math.sin((stop.latitude-driver.latitude)*r/2)**2+Math.cos(driver.latitude*r)*Math.cos(stop.latitude*r)*Math.sin((stop.longitude-driver.longitude)*r/2)**2;
   const bounded=Math.min(1,Math.max(0,a));
   return 6371000*2*Math.atan2(Math.sqrt(bounded),Math.sqrt(1-bounded));
  },
  distanceLabel(stop){const meters=this.distanceMeters(stop);return meters<1000?Math.round(meters)+' m':(meters/1000).toFixed(1)+' km'},
  get filteredStops(){const stops=this.stops.filter(s=>this.visible(s.reference));return this.isMap?stops.sort((a,b)=>this.distanceMeters(a)-this.distanceMeters(b)||a.reference.localeCompare(b.reference)):stops},
  get nearestStop(){return this.filteredStops[0]||null},
  get toastBottom(){return (this.$refs.runOverview?.offsetHeight||154)+47},
  isQueued(reference){return this.queue.some(q=>q.reference===reference)},
  status(reference){return this.stops.find(s=>s.reference===reference)?.status||'pending'},
  label(status){return {pending:'Pending',completed:'Completed',failed:'Failed'}[status]||status},
  openStop(reference,source='map'){this.listRestorePending=false;this.detailFromList=source==='list';this.listScrollTop=this.$refs.stopListScroll?.scrollTop||0;this.selectedId=reference;this.detailOpen=true;this.failureOpen=false;this.saveError='';this.reasonError=false;if(this.isMap){this.listOpen=false;this.page='stops';this.searchOpen=false}this.$nextTick(()=>{this.$refs.backButton.focus();if(this.isMap)MapWorkspace.focus(reference)})},
  closeDetail(){this.detailOpen=false;this.failureOpen=false;this.saveError='';if(this.isMap){this.listOpen=this.detailFromList;this.listRestorePending=this.detailFromList;this.page='stops';this.$nextTick(()=>{if(this.detailFromList)this.restoreListWhenReady();else MapWorkspace.map.getContainer().focus({preventScroll:true})})}else this.$nextTick(()=>document.getElementById('stop-'+this.selectedId)?.focus())},
  restoreListWhenReady(){if(!this.listRestorePending)return;if(!this.listOpen||this.detailOpen){this.listRestorePending=false;return}const panel=this.$refs.stopListPanel;if(panel.checkVisibility()&&!panel.classList.contains('sheet-enter')&&!panel.classList.contains('sheet-leave'))this.restoreListContext();else requestAnimationFrame(()=>this.restoreListWhenReady())},
  restoreListContext(){if(!this.listRestorePending||!this.listOpen||this.detailOpen)return;const row=document.getElementById('stop-'+this.selectedId);this.$refs.stopListScroll.scrollTop=this.listScrollTop;(row||this.$refs.stopListClose)?.focus({preventScroll:true});this.listRestorePending=false},
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
   this.syncing=true;this.saveError='';const token=this.syncToken;let sent=0,failed=false;
   this.notifySync('Syncing '+this.updateCountLabel+'…','progress',0);
   try{while(this.queue.length&&this.online&&token===this.syncToken){const event=this.queue[0];await new Promise(r=>setTimeout(r,720));if(!this.online||token!==this.syncToken)break;
    const at=new Date().toISOString();const stops=JSON.parse(JSON.stringify(this.stops));stops.find(s=>s.reference===event.reference).syncedAt=at;
    const next=this.snapshot({stops,queue:this.queue.slice(1),history:[{...event,syncedAt:at},...this.history].slice(0,30),lastSync:at});if(!this.write(next)){failed=true;break}this.stops=stops;this.queue=next.queue;this.history=next.history;this.lastSync=at;sent++;
   }}catch(_){failed=true}finally{
    this.syncing=false;
    if(this.online&&this.queue.length&&token!==this.syncToken)this.flush();
    else if(failed)this.notifySync('Could not sync. '+this.updateCountLabel+' '+(this.queue.length===1?'is':'are')+' still saved.','error');
    else if(!this.online&&this.queue.length)this.notifySync('Offline · '+this.updateCountLabel+' saved for later.','info');
    else if(!this.queue.length)this.notifySync(sent+' update'+(sent===1?'':'s')+' synced.');
   }
  },
  chooseNext(){const s=this.stops.find(s=>s.status==='pending');if(s)this.selectedId=s.reference},
  time(at){return new Date(at).toLocaleTimeString('en-AU',{hour:'2-digit',minute:'2-digit',hour12:false})},
  get street(){return this.selected.address?.split(',')[0]||''},get locality(){return this.selected.address?.split(',').slice(1).join(',').trim()||''},
  get updateCountLabel(){return this.queue.length+' update'+(this.queue.length===1?'':'s')},
  windowCount(time){return this.stops.filter(s=>s.time_window===time&&this.visible(s.reference)).length},
  openSearch(){this.searchOpen=!this.searchOpen;if(!this.searchOpen)this.search='';if(this.isMap){this.detailOpen=false;this.listOpen=false;this.page='stops'}this.$nextTick(()=>this.$refs.searchInput?.focus())},
  closeSearch(){this.searchOpen=false;this.search='';if(this.isMap)this.$nextTick(()=>MapWorkspace.fit())},
  syncMap(){if(this.isMap)MapWorkspace.sync()},
  setFilter(status){this.filter=status;this.detailOpen=false;this.$nextTick(()=>{this.syncMap();MapWorkspace.fit()})},
  fitMap(){this.detailOpen=false;this.listOpen=false;this.page='stops';this.$nextTick(()=>{this.syncMap();MapWorkspace.fit()})},
  locateDriver(){this.detailOpen=false;this.listOpen=false;this.page='stops';this.$nextTick(()=>MapWorkspace.locate())},
  zoomMap(delta){MapWorkspace.zoom(delta)},
  retryMap(){MapWorkspace.retry()},
  openList(){this.detailOpen=false;this.listOpen=true;this.page='stops'},
  escape(){if(this.failureOpen)this.failureOpen=false;else if(this.detailOpen)this.closeDetail();else if(this.searchOpen)this.closeSearch();else if(this.listOpen)this.listOpen=false}
  ,trapSheet(event){const controls=Array.from(event.currentTarget.querySelectorAll('button,textarea,input')).filter(el=>!el.disabled&&el.offsetParent);const first=controls[0],last=controls[controls.length-1];if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}}
 };return window.enhanceDeliveryPrototype(base);});
});
