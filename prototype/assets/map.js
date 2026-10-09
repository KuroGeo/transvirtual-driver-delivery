/* Map instances stay outside Alpine's reactive state. Pins use the CSV coordinates. */
window.MapWorkspace = {
  map:null,clusters:null,markers:new Map(),driver:null,app:null,tiles:null,overviewHeight:190,
  start(app,element){
    this.app=app;
    const reduced=matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.map=L.map(element,{zoomControl:false,attributionControl:false,minZoom:9,maxZoom:19,zoomSnap:.25,scrollWheelZoom:true,zoomAnimation:!reduced,fadeAnimation:!reduced}).setView([-33.884,151.117],11);
    L.control.attribution({prefix:false,position:'topleft'}).addTo(this.map).addAttribution('© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors');
    this.clusters=L.markerClusterGroup({
      maxClusterRadius:48,disableClusteringAtZoom:14,showCoverageOnHover:false,animate:false,zoomToBoundsOnClick:false,
      iconCreateFunction:cluster=>{
        const counts={pending:0,completed:0,failed:0};
        cluster.getAllChildMarkers().forEach(m=>counts[m.options.stopStatus]++);
        const total=cluster.getChildCount(), a=counts.pending/total*360, b=(counts.pending+counts.completed)/total*360;
        const html='<span class="cluster-ring" style="--segments:conic-gradient(#ff6b38 0deg '+a+'deg,#245d43 '+a+'deg '+b+'deg,#8f2f2b '+b+'deg 360deg)"><span>'+total+'</span></span>';
        return L.divIcon({className:'stop-cluster',html,iconSize:[44,44],iconAnchor:[22,22]});
      }
    });
    this.clusters.on('clusterclick',e=>{
      this.map.fitBounds(e.layer.getBounds(),{paddingTopLeft:[38,205],paddingBottomRight:[38,this.bottomInset()],maxZoom:15,animate:!reduced});
    });
    this.clusters.on('layeradd animationend',()=>this.labelClusters());
    this.map.addLayer(this.clusters);
    const d=window.MAP_CONFIG.driver;
    const heading=((Number(d.headingDegrees)||0)%360+360)%360;
    this.driver=L.marker([d.latitude,d.longitude],{
      icon:L.divIcon({className:'driver-marker',html:'<span class="driver-aura"></span><svg class="driver-heading" aria-hidden="true" data-heading="'+heading+'" style="--heading:'+heading+'deg" viewBox="0 0 24 24"><path d="M12 2 21 21 12 17 3 21Z"/></svg><span class="driver-label">You</span>',iconSize:[28,28],iconAnchor:[14,14]}),
      title:'Your location · '+d.locality,alt:'Your location',keyboard:true,zIndexOffset:500
    }).addTo(this.map);
    this.driver.on('click',()=>this.locate());
    this.driver.getElement()?.setAttribute('aria-label','Your location · '+d.locality);
    this.sync();
    if(!app.mapFailed)this.loadTiles();
    this.fit();
    if(app.detailOpen)this.focus(app.selectedId,false);
  },
  loadTiles(){
    if(this.tiles)this.map.removeLayer(this.tiles);
    const app=this.app;let errors=0;
    this.tiles=L.tileLayer(window.MAP_CONFIG.tiles.url,{maxZoom:window.MAP_CONFIG.tiles.maxZoom,keepBuffer:1,updateWhenIdle:true});
    this.tiles.on('loading',()=>{errors=0;});
    this.tiles.on('tileload',()=>{if(!errors)app.mapFailed=false;});
    this.tiles.on('tileerror',()=>{errors++;app.mapFailed=true;});
    this.tiles.on('load',()=>{app.mapFailed=errors>0;});
    this.tiles.addTo(this.map);
  },
  labelClusters(){
    this.clusters?._featureGroup.eachLayer(layer=>{
      if(!layer.getChildCount)return;
      const el=layer.getElement();if(!el)return;
      const counts={pending:0,completed:0,failed:0};
      layer.getAllChildMarkers().forEach(m=>counts[m.options.stopStatus]++);
      el.setAttribute('aria-label','Zoom to '+layer.getChildCount()+' stops: '+counts.pending+' pending, '+counts.completed+' completed, '+counts.failed+' failed');
      el.setAttribute('role','button');
      el.dataset.references=layer.getAllChildMarkers().map(m=>m.options.stopReference).join('|');
      el.onclick=event=>{
        event.stopPropagation();
        this.map.fitBounds(layer.getBounds(),{paddingTopLeft:[38,205],paddingBottomRight:[38,this.bottomInset()],maxZoom:15,animate:!matchMedia('(prefers-reduced-motion: reduce)').matches});
      };
    });
  },
  pin(stop){
    const queued=this.app.isQueued(stop.reference);
    const glyph=stop.status==='pending'?'<span class="pending-ring" aria-hidden="true"></span>':window.MAP_ICONS[stop.status==='completed'?'check':'warning'];
    const active=this.app.detailOpen&&this.app.selectedId===stop.reference;
    return L.divIcon({className:'stop-marker '+stop.status+(active?' selected':'')+(queued?' queued':''),
      html:'<span class="pin-surface">'+glyph+'</span>'+(queued?'<span class="pin-unsynced" aria-hidden="true"></span>':''),
      iconSize:[40,40],iconAnchor:[20,20]});
  },
  sync(){
    if(!this.map)return;
    const app=this.app,layers=[];
    for(const stop of app.stops){
      let marker=this.markers.get(stop.reference);
      if(!marker){
        marker=L.marker([stop.latitude,stop.longitude],{title:stop.customer_name,alt:stop.customer_name,stopReference:stop.reference,keyboard:true});
        marker.on('click',()=>app.openStop(stop.reference));
        marker.on('add',()=>{
          const el=marker.getElement();
          if(el){
            el.dataset.ref=stop.reference;
            el.dataset.status=marker.options.stopStatus;
            el.setAttribute('aria-label','Open '+stop.customer_name+', '+stop.reference+', '+app.label(marker.options.stopStatus));
            el.setAttribute('role','button');
            el.onclick=event=>{event.stopPropagation();app.openStop(stop.reference);};
          }
        });
        this.markers.set(stop.reference,marker);
      }
      marker.options.stopStatus=stop.status;
      marker.setIcon(this.pin(stop));
      if(app.visible(stop.reference))layers.push(marker);
    }
    this.clusters.clearLayers();
    this.clusters.addLayers(layers);
    this.labelClusters();
  },
  focus(reference,animate=true){
    const stop=this.app.stops.find(s=>s.reference===reference);if(!stop)return;
    const reduced=matchMedia('(prefers-reduced-motion: reduce)').matches;
    const center=this.map.unproject(this.map.project([stop.latitude,stop.longitude],15).add([0,this.app.mapFailed?55:105]),15);
    this.map.setView(center,15,{animate:animate&&!reduced});
    this.sync();
  },
  bottomInset(){const height=this.app.$refs.runOverview?.offsetHeight;if(height)this.overviewHeight=height;return Math.max(215,this.overviewHeight+65)},
  fit(){
    const points=this.app.filteredStops.map(s=>[s.latitude,s.longitude]);
    const driver=window.MAP_CONFIG.driver;
    points.push([driver.latitude,driver.longitude]);
    if(points.length===1){this.locate();return;}
    this.map.fitBounds(points,{paddingTopLeft:[22,this.app.mapFailed?350:260],paddingBottomRight:[22,this.bottomInset()],maxZoom:14,animate:false});
    this.labelClusters();
  },
  locate(){
    const d=window.MAP_CONFIG.driver;
    const center=this.map.unproject(this.map.project([d.latitude,d.longitude],14).add([0,35]),14);
    this.map.setView(center,14,{animate:!matchMedia('(prefers-reduced-motion: reduce)').matches});
  },
  zoom(delta){this.map.setZoom(this.map.getZoom()+delta);},
  retry(){this.app.mapFailed=false;this.loadTiles();},
  resize(){this.map?.invalidateSize({pan:false});}
};
