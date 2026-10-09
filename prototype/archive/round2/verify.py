"""Run inside Browser Harness against the dedicated prototype browser.

BU_NAME=transvirtualqa BU_CDP_URL=http://127.0.0.1:9333 browser-harness <<'PY'
exec(open('/Users/yeyufeng/code/transvirtual-driver-delivery/prototype/verify.py').read())
PY
"""
import json, time

BASE='http://127.0.0.1:8764/'
APP="Alpine.$data(document.querySelector('main'))"
checks=[]
def verify(value,message):
    if not value:raise AssertionError(message)
    checks.append(message)
def until(expression,timeout=5):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if js(expression):return
        time.sleep(.04)
    raise AssertionError('Timed out: '+expression)
def load(file,reset=True):
    cdp('Page.navigate',url=BASE+file)
    wait_for_load()
    until("typeof Alpine !== 'undefined' && "+APP+".stops.length === 30")
    if reset:
        js('localStorage.removeItem('+APP+'.key)')
        cdp('Page.reload')
        wait_for_load()
        until(APP+'.stops.length === 30')
def click(name,partial=False,last=False,role=None):
    cdp('Runtime.evaluate',expression='new Promise(requestAnimationFrame)',awaitPromise=True)
    until("document.querySelectorAll('.detail-enter,.detail-leave,.sheet-enter,.sheet-leave').length === 0")
    deadline=time.monotonic()+5
    targets=[]
    while not targets and time.monotonic()<deadline:
        nodes=cdp('Accessibility.getFullAXTree')['nodes']
        targets=[n for n in nodes if not n.get('ignored') and n.get('role',{}).get('value') in ([role] if role else ['button','toggleButton','switch']) and ((n.get('name',{}).get('value','').startswith(name)) if partial or name in ['All','Pending','Completed','Failed'] else n.get('name',{}).get('value')==name)]
        if not targets:time.sleep(.04)
    if not targets:raise AssertionError('Missing accessible control: '+name)
    target=targets[-1] if last else targets[0]
    q=cdp('DOM.getBoxModel',backendNodeId=target['backendDOMNodeId'])['model']['content']
    x,y=sum(q[0::2])/4,sum(q[1::2])/4
    info=page_info()
    if not(0<x<info['w'] and 0<y<info['h']):raise AssertionError('Control outside viewport: '+name)
    click_at_xy(x,y)
    cdp('Runtime.evaluate',expression='new Promise(requestAnimationFrame)',awaitPromise=True)
def type_into(name,text):
    matches=[]
    deadline=time.monotonic()+5
    while not matches and time.monotonic()<deadline:
        nodes=cdp('Accessibility.getFullAXTree')['nodes']
        matches=[n for n in nodes if not n.get('ignored') and n.get('role',{}).get('value') in ['textbox','searchbox'] and n.get('name',{}).get('value')==name]
        if not matches:time.sleep(.04)
    assert matches,name
    q=cdp('DOM.getBoxModel',backendNodeId=matches[0]['backendDOMNodeId'])['model']['content']
    click_at_xy(sum(q[0::2])/4,sum(q[1::2])/4)
    cdp('Input.insertText',text=text)
    cdp('Runtime.evaluate',expression='new Promise(requestAnimationFrame)',awaitPromise=True)
def snapshot():
    return js('('+APP+').snapshot()')

cdp('Emulation.setDeviceMetricsOverride',width=390,height=844,deviceScaleFactor=1,mobile=True)
cdp('Emulation.setFocusEmulationEnabled',enabled=True)
load('index.html')
verify(js(APP+'.count("pending")')==24,'Original CSV: 30 stops, 24 pending')
click('All');until(APP+'.filter === "all"');verify(js(APP+'.visibleCount')==30,'All filter includes all 30 stops')
click('Completed');until(APP+'.filter === "completed"');verify(js(APP+'.visibleCount')==3,'Completed filter includes the three imported terminal records')
click('Pending');until(APP+'.filter === "pending"')
click('Search stops');until(APP+'.searchOpen')
type_into('Find a customer or reference','TV-300020');until(APP+'.visibleCount === 1');verify(True,'Search finds an exact reference')
load('index.html')
click('Online connection',role='switch');until('!'+APP+'.online')
click('Open Silverline Supplies, TV-300002');until(APP+'.detailOpen')
click('Complete delivery');until(APP+'.selected.status === "completed"')
first=snapshot();verify(len(first['queue'])==1,'Offline completion produces one durable queue entry')
verify(not js(APP+".update('failed')"),'Terminal completed record rejects a second update in logic')
verify(len(snapshot()['queue'])==1,'Rejected terminal update cannot append a duplicate queue item')
click('Back to stops');until("getComputedStyle(document.querySelector('.detail-overlay')).display === 'none'")
click('Open Skyline Pharma, TV-300004');until(APP+'.detailOpen')
click('Report a failed delivery');until(APP+'.failureOpen')
click('Mark delivery as failed');until(APP+'.reasonError')
verify(snapshot()['stops'][3]['status']=='pending','Missing failure reason preserves the pending stop')
click('Other');type_into('Describe the reason (required)','  ')
click('Mark delivery as failed');until(APP+'.reasonError')
verify(snapshot()['stops'][3]['status']=='pending','Whitespace-only failure reason is rejected')
click('Business closed');click('Mark delivery as failed');until(APP+'.selected.status === "failed"')
second=snapshot();verify(len(second['queue'])==2 and second['stops'][3]['failureReason']=='Business closed','Valid failed update saves its reason and a second queue entry')
verify(not js(APP+".update('completed')"),'Terminal failed record rejects another transition in logic')
load('index.html',reset=False)
restored=snapshot();verify(not restored['online'] and len(restored['queue'])==2 and restored['stops'][1]['status']=='completed' and restored['stops'][3]['failureReason']=='Business closed','Reload restores both offline updates, reason and queue')
click('Sync',partial=True);until(APP+'.page === "sync"')
click('Online connection',role='switch',last=True);until(APP+'.syncing')
verify(len(snapshot()['queue'])>0,'Sync UI exposes the in-progress queue before acknowledgements')
click('Online connection',role='switch',last=True);until('!'+APP+'.online && !'+APP+'.syncing')
verify(len(snapshot()['queue'])==2,'Going offline during sending retains both unacknowledged updates')
click('Online connection',role='switch',last=True);until(APP+'.syncing')
until(APP+'.queue.length === 0 && !'+APP+'.syncing')
synced=snapshot();verify(len(synced['history'])==2 and all(synced['stops'][i].get('syncedAt') for i in [1,3]),'Fake target acknowledges both records and clears the durable queue')
load('index.html',reset=False);verify(len(snapshot()['queue'])==0 and len(snapshot()['history'])==2,'Acknowledged queue remains empty after another reload')

load('index.html')
click('Online connection',role='switch');until('!'+APP+'.online')
click('Open Silverline Supplies, TV-300002');until(APP+'.detailOpen')
click('Report a failed delivery');until(APP+'.failureOpen')
click('Other');type_into('Describe the reason (required)','Gate locked at loading dock.')
js("window.originalSetItem=Storage.prototype.setItem;Storage.prototype.setItem=function(){throw new DOMException('Injected storage failure','QuotaExceededError')}")
click('Mark delivery as failed');until(APP+'.saveError.length > 0')
failed=snapshot();verify(failed['stops'][1]['status']=='pending' and len(failed['queue'])==0 and js(APP+'.failureOpen && '+APP+'.note === "Gate locked at loading dock."'),'Save failure keeps the form, input and stop unchanged')
js('Storage.prototype.setItem=window.originalSetItem')
click('Mark delivery as failed');until(APP+'.selected.status === "failed"')
verify(snapshot()['stops'][1]['failureReason']=='Gate locked at loading dock.','Retry after storage recovery saves the retained reason')

load('focus.html')
verify(js("[...document.querySelectorAll('.compact-row')].filter(x=>x.offsetParent).every(x=>"+APP+".status(x.dataset.ref)==='pending')"),'Focus layout shows only other pending stops')
click('Online connection',role='switch');until('!'+APP+'.online')
click('Complete delivery');until(APP+'.selected.status === "completed"')
click('Select another pending stop',partial=True);until(APP+'.selectedId === "TV-300004"')
verify(js(APP+'.count("pending")')==23,'Focus completion updates remaining count and explicitly selects another pending stop')
load('focus.html',reset=False);verify(snapshot()['stops'][1]['status']=='completed' and len(snapshot()['queue'])==1,'Focus layout persists its own offline record')

load('windows.html')
click('10–12');until(APP+'.windowFilter === "10:00-12:00"')
until("[...document.querySelectorAll('.window-row')].filter(x=>x.offsetParent).length === 8")
verify(js("[...document.querySelectorAll('.window-row')].filter(x=>x.offsetParent).length")==8,'Time-window filter shows the eight pending 10:00–12:00 records')
click('Completed');until(APP+'.filter === "completed"')
until("[...document.querySelectorAll('.window-row')].filter(x=>x.offsetParent).length === 1")
verify(js("[...document.querySelectorAll('.window-row')].filter(x=>x.offsetParent).length")==1,'Status and time-window filters compose correctly')

for file in ['index.html','focus.html','windows.html']:
    load(file)
    for w,h in [(320,740),(390,844),(430,932),(1280,900)]:
        cdp('Emulation.setDeviceMetricsOverride',width=w,height=h,deviceScaleFactor=1,mobile=w<600)
        until('document.documentElement.clientWidth === '+str(w))
        verify(js('document.documentElement.scrollWidth <= document.documentElement.clientWidth'),file+' has no horizontal overflow at '+str(w)+'px')
        if w==1280:verify(js("document.querySelector('.phone').getBoundingClientRect().width")==390,file+' keeps a 390px app viewport on desktop')
cdp('Emulation.setDeviceMetricsOverride',width=390,height=844,deviceScaleFactor=1,mobile=True)
load('index.html')
cdp('Emulation.setEmulatedMedia',features=[{'name':'prefers-reduced-motion','value':'reduce'}])
click('Open Silverline Supplies, TV-300002');until(APP+'.detailOpen')
verify(js("getComputedStyle(document.querySelector('.detail-overlay')).animationName")== 'none','Reduced-motion setting preserves the details interaction')
cdp('Emulation.setEmulatedMedia',features=[])
verify(js("document.querySelector('.detail-body').innerText.includes('Delivery window')"),'Redesigned details retain the required delivery time window')
click('Stops')
until("getComputedStyle(document.querySelector('.detail-overlay')).display === 'none'")
click('Search stops');until(APP+'.searchOpen')
type_into('Find a customer or reference','Pacific')
until(APP+'.visibleCount === 1')
click('Close search');until('!'+APP+'.searchOpen && '+APP+'.search === ""')
verify(js(APP+'.visibleCount')==24,'Closing the compact search restores the unfiltered pending list')
print(json.dumps({'passed':len(checks),'checks':checks},ensure_ascii=False))
