/* PROTOTYPE ONLY: in-memory identity, scripted route/agent answers, no external writes. */
window.enhanceDeliveryPrototype = function (base) {
  const baseInit = base.init, baseEscape = base.escape, baseUpdate = base.update, baseFlush=base.flush;
  Object.assign(base, {
    variant:'A', signedIn:true, sessionName:'Jamie', nextPanel:'', loginStep:'org', loginBusy:false,
    organization:'harbour-logistics', organizationLabel:'Harbour Logistics', loginError:'',
    remindersOn:true, voiceOn:false, alertDismissed:false, sessionExpired:false,
    urgentId:'TV-300021', navigationId:'TV-300021', navigationProvider:'', navigationReturn:'',
    agentInput:'', agentQuestion:'', agentAnswer:'', agentSource:'', agentBusy:false,
    answerKind:'', agentUnavailable:false, planView:'suggested', planApplied:false, planStale:false,
    currentOrder:['TV-300016','TV-300022','TV-300021','TV-300017'],
    suggestedOrder:['TV-300021','TV-300016','TV-300022','TV-300017'], routeLayer:null, routeRevision:0,
    init(){
      // A clean, isolated interaction study; delivery persistence in the original is untouched.
      const params=new URLSearchParams(location.search);
      if(!params.has('state'))history.replaceState(null,'',location.pathname+'?state=idle&'+params.toString());
      baseInit.call(this);this.ephemeral=true;this.selectedId=this.urgentId;
      this.variant=['A','B','C'].includes(params.get('variant'))?params.get('variant'):'A';
      this.$watch('variant',()=>{this.$el.dataset.nextVariant=this.variant});
      this.$el.dataset.nextVariant=this.variant;
      this.$watch('remindersOn',v=>{if(!v)this.alertDismissed=true;else this.alertDismissed=false});
      this.$watch('online',v=>{if(!v&&this.nextPanel==='plan')this.planStale=true});
      this.$nextTick(()=>this.setScene(params.get('scene')||(this.variant==='C'?'assistant':'home')));
      window.addEventListener('message',event=>{
        if(event.origin!==location.origin || event.source!==parent)return;
        if(event.data?.type==='ocean-scene')this.setScene(event.data.scene);
        if(event.data?.type==='ocean-variant')this.setVariant(event.data.variant);
      });
      this.$watch('nextPanel',()=>{if(this.nextPanel)this.toast='';this.reportState()});this.reportState();
    },
    reportState(){parent.postMessage({type:'ocean-state',panel:this.nextPanel||'home',variant:this.variant,planApplied:this.planApplied,online:this.online,signedIn:this.signedIn},location.origin)},
    setVariant(variant){if(!['A','B','C'].includes(variant))return;this.variant=variant;this.setScene(variant==='C'?'assistant':'home')},
    setScene(scene){
      this.detailOpen=false;this.listOpen=false;this.failureOpen=false;this.nextPanel='';this.clearRoute();
      if(scene==='login'){this.signedIn=false;this.nextPanel='login';this.loginStep='org';return}
      if(!this.signedIn){this.signedIn=true;this.sessionName='Jamie'}
      if(scene==='home')return;
      if(scene==='stop'){this.openStop(this.urgentId,'map');return}
      if(scene==='navigation'){this.previewNavigation(this.urgentId);return}
      if(scene==='assistant'){this.openAssistant('home');return}
      if(scene==='plan'){this.showPlan();return}
      if(scene==='profile'){this.nextPanel='profile';return}
      if(scene==='offline'){this.online=false;this.openAssistant('home');return}
      if(scene==='expired'){this.seedPending();this.syncToken++;this.online=false;this.sessionExpired=true;this.nextPanel='expired';return}
      if(scene==='unavailable'){this.agentUnavailable=true;this.openAssistant('home');this.askAgent('Where is my next stop?');return}
      if(scene==='stale'){this.showPlan();this.planStale=true;return}
    },
    discoverOrganization(){if(!this.organization.trim()){this.loginError='Enter your company workspace.';return}this.organizationLabel=this.organization.trim()==='harbour-logistics'?'Harbour Logistics':this.organization.trim().replace(/[-_]/g,' ').replace(/\b\w/g,c=>c.toUpperCase());this.loginError='';this.loginStep='provider'},
    signIn(){this.loginBusy=true;setTimeout(()=>{this.loginBusy=false;this.signedIn=true;this.sessionExpired=false;this.online=true;this.nextPanel='';this.sessionName='Jamie';this.notify('Your Sydney run is ready.');if(this.queue.length)this.flush();this.reportState()},600)},
    seedPending(){if(this.queue.length)return;const stop=this.stops.find(s=>s.status==='pending'&&s.reference!==this.urgentId);if(stop){stop.status='completed';this.queue=[{reference:stop.reference,status:'completed',at:new Date().toISOString()}]}},
    requestSignOut(){this.nextPanel=this.queue.length?'signout':'login';if(!this.queue.length)this.signOut()},
    signOut(){this.syncToken++;this.signedIn=false;this.online=false;this.nextPanel='login';this.loginStep='org';this.clearRoute()},
    resumeSession(){this.signedIn=true;this.sessionExpired=false;this.online=true;this.nextPanel='';this.notify('Signed in again. Saved updates are ready to sync.');this.flush();this.reportState()},
    stopById(id){return this.stops.find(s=>s.reference===id)||{}},
    previewNavigation(id){this.navigationId=id||this.selectedId;this.navigationReturn=this.nextPanel;this.nextPanel='navigation';this.drawRoute([this.navigationId])},
    closeNextPanel(){this.nextPanel=this.navigationReturn==='assistant'?'assistant':'';this.navigationReturn='';this.clearRoute()},
    openNavigationStop(){const id=this.navigationId;this.nextPanel='';this.clearRoute();this.openStop(id,'map')},
    launchNavigator(provider){this.navigationProvider=provider;this.nextPanel='handoff'},
    arriveAtStop(){this.nextPanel='';this.clearRoute();this.openStop(this.navigationId,'map');this.notify('You’re at the stop. Record the delivery when you’re ready.')},
    clearRoute(){this.routeRevision++;if(this.routeLayer&&window.MapWorkspace.map){window.MapWorkspace.map.removeLayer(this.routeLayer);this.routeLayer=null}},
    drawRoute(ids){this.clearRoute();this.$nextTick(()=>{const map=window.MapWorkspace.map;if(!map)return;map.stop();const d=window.MAP_CONFIG.driver;const points=[[d.latitude,d.longitude]];for(const id of ids){const s=this.stopById(id);if(!s.latitude)continue;const last=points[points.length-1];points.push([last[0],s.longitude],[s.latitude,s.longitude])}this.routeLayer=L.polyline(points,{color:'#386CB9',weight:5,opacity:.9,lineCap:'round',dashArray:'7 7'}).addTo(map);const revision=this.routeRevision;const fit=()=>{if(revision!==this.routeRevision||!this.routeLayer)return;if(map._animatingZoom||map._panAnim?._inProgress){setTimeout(fit,40);return}map.fitBounds(this.routeLayer.getBounds(),{paddingTopLeft:[55,230],paddingBottomRight:[55,420],maxZoom:13,animate:false})};setTimeout(fit,40)})},
    openAssistant(topic){this.nextPanel='assistant';this.navigationReturn='';if(topic==='plan')this.askAgent('Plan my remaining deliveries');else if(topic==='risk')this.askAgent('Which stops could be late?')},
    dismissReminder(){this.alertDismissed=true;this.notify('Reminder paused for 5 minutes.');setTimeout(()=>{if(this.remindersOn)this.alertDismissed=false},300000)},
    askAgent(question){
      const q=(question||'').trim();if(!q||this.agentBusy)return;
      this.agentQuestion=q;this.agentAnswer='';this.agentBusy=true;this.answerKind='';
      setTimeout(()=>{
        this.agentBusy=false;
        if(this.agentUnavailable){this.agentAnswer='I couldn’t reach the assistant right now. Your deliveries and navigation are still available.';this.answerKind='unavailable';this.agentUnavailable=false;this.agentSource='No delivery changes made.'}
        else if(!this.online){const stop=this.nextRecommendedStop;this.agentAnswer=stop?.reference?'Your saved next stop is '+stop.customer_name+', '+stop.address+'. I can’t check live travel times or make a fresh plan while you’re offline.':'All saved stops on this run are finished.';this.answerKind='offline';this.agentSource='Saved run · last updated 09:42'}
        else if(/plan|order|optim|规划|路线|安排/i.test(q)){this.agentAnswer=this.urgentPending?'I suggest visiting Wattle Corner Store first, then Banksia Medical. That protects the 10:00 window. Review the full stop order before applying it.':'The tight-window stop is already finished. Your current stop order works for the remaining delivery windows.';this.answerKind=this.urgentPending?'plan':'info';this.agentSource=this.count('pending')+' pending stops · excludes finished stops · route estimates at 09:42'}
        else if(/late|risk|attention|超时|提醒/i.test(q)){this.agentAnswer=this.urgentPending?'Wattle Corner Store is the only stop at risk in the current order. Its window closes at 10:00. Going there next gives you an estimated 6 minutes to complete the delivery.':'The tight-window stop is finished. No remaining stops are flagged in this plan.';this.answerKind=this.urgentPending?'next':'info';this.agentSource=this.urgentPending?'TV-300021 · delivery window 08:00–10:00 · route estimate at 09:42':'Today’s pending stops · route estimates at 09:42'}
        else if(/next|where|下一|哪里/i.test(q)){const stop=this.nextRecommendedStop;this.agentAnswer=stop?.reference?(this.urgentPending?'Your recommended next stop is Wattle Corner Store at 21 Wattle Street. It’s a 12-minute drive. The estimated arrival is 09:54, before its 10:00 deadline.':'Your next stop is '+stop.customer_name+' at '+stop.address+'. The tight-window stop is already finished.'):'All deliveries on this run are finished.';this.answerKind=stop?.reference?'next':'info';this.agentSource=(stop?.reference||'Today’s run')+' · today’s assigned run · route estimate at 09:42'}
        else if(/complete|delivered|完成|签收/i.test(q)){this.agentAnswer='Open the stop’s delivery details to record the result. I can help plan the route, but a route change won’t mark any delivery as completed.';this.answerKind='info';this.agentSource='Delivery confirmation stays with you.'}
        else{this.agentAnswer='I can help you find the next stop, check delivery windows, or review a new stop order. Which would you like to do?';this.answerKind='info';this.agentSource='Today’s assigned run · 30 stops'}
        this.$nextTick(()=>this.$refs.assistantScroll?.scrollTo({top:this.$refs.assistantScroll.scrollHeight,behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'}));
      },650)
    },
    showPlan(){this.nextPanel='plan';this.planView='suggested';this.planStale=false;this.drawRoute(this.suggestedOrder)},
    planArrival(index){return (this.planView==='suggested'?['09:54','10:10','10:24','10:42']:['09:48','10:00','10:06','10:24'])[index]},
    refreshPlan(){this.planStale=false;this.drawRoute(this.suggestedOrder)},
    applyPlan(){if(!this.online||this.planStale)return;this.planApplied=true;this.nextPanel='';this.clearRoute();this.alertDismissed=true;this.notify('Stop order updated. Wattle Corner Store is next.');this.reportState()},
    undoPlan(){this.planApplied=false;this.alertDismissed=false;this.notify('Your previous stop order is restored.');this.reportState()},
    escape(){if(this.nextPanel){if(this.nextPanel==='login'||this.nextPanel==='expired')return;if(this.nextPanel==='navigator'||this.nextPanel==='handoff'){this.nextPanel='navigation';return}this.closeNextPanel();return}baseEscape.call(this)},
    update(status){if(this.planApplied)this.planStale=true;return baseUpdate.call(this,status)},
    flush(){if(!this.signedIn||this.sessionExpired)return;return baseFlush.call(this)}
  });
  Object.defineProperties(base,{
    navigationStop:{get(){return this.stopById(this.navigationId)}},
    navigationEstimate:{get(){return ({'TV-300021':{minutes:12,distance:'6.3',arrival:'09:54'},'TV-300016':{minutes:6,distance:'1.8',arrival:'09:48'},'TV-300022':{minutes:9,distance:'3.2',arrival:'09:51'},'TV-300017':{minutes:14,distance:'6.5',arrival:'09:56'}})[this.navigationId]||{minutes:18,distance:'8.4',arrival:'10:00'}}},
    urgentPending:{get(){return this.stopById(this.urgentId).status==='pending'}},
    nextRecommendedStop:{get(){return this.stopById(this.suggestedOrder.find(id=>this.stopById(id).status==='pending'))?.reference?this.stopById(this.suggestedOrder.find(id=>this.stopById(id).status==='pending')):this.stops.find(s=>s.status==='pending')}},
    displayedPlan:{get(){return (this.planView==='suggested'?this.suggestedOrder:this.currentOrder).filter(id=>this.stopById(id).status==='pending')}},
    filteredStops:{get(){const stops=this.stops.filter(s=>this.visible(s.reference));const order=this.planApplied?this.suggestedOrder:this.currentOrder;const rank=s=>s.status==='pending'&&order.includes(s.reference)?order.indexOf(s.reference):999;return stops.sort((a,b)=>rank(a)-rank(b)||this.distanceMeters(a)-this.distanceMeters(b)||a.reference.localeCompare(b.reference))}},
    nearestStop:{get(){if(this.planApplied){const stop=this.stopById(this.suggestedOrder.find(id=>this.stopById(id).status==='pending'));if(stop?.reference&&this.visible(stop.reference))return stop}return this.filteredStops[0]||null}}
  });
  return base;
};
