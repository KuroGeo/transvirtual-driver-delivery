#!/usr/bin/env python3
"""Paced recording using the existing native workbench, never a new acceptance stamp.
Use an isolated source root with the verified workbench Runner.app and video_driver.dart.
"""
import argparse, contextlib, hashlib, json, re, signal, subprocess, sys, threading, time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlparse
from urllib.request import Request, urlopen

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--lock-root',type=Path,required=True)
args=parser.parse_args();args.root=args.root.resolve();args.output=args.output.resolve()
sys.path.insert(0,str(args.root))
from harness import native_workbench as nw
from harness.checks import fingerprint
from harness.state import lease

class ViewportFixture(nw.Fixture):
    """Proxy only tiles requested by the real visible viewport; no prefetch/download loop."""
    def __init__(self,*a,**kw):
        super().__init__(*a,**kw)
        base=self.server.RequestHandlerClass;owner=self
        self.cache={};self.cache_lock=threading.Lock()
        class Handler(base):
            def do_GET(self):
                path=urlparse(self.path).path
                if not re.fullmatch(r'/tiles/\d+/\d+/\d+\.png',path):
                    return super().do_GET()
                with owner.cache_lock:
                    if path not in owner.cache:
                        if len(owner.cache)>=120:raise RuntimeError('Viewport-only tile bound exceeded')
                        url='https://tile.openstreetmap.org/'+path.removeprefix('/tiles/')
                        try:
                            with urlopen(Request(url,headers={'User-Agent':'OceanDelivery-InterviewDemo/0.1 (https://github.com/KuroGeo/transvirtual-driver-delivery)'}),timeout=10) as response:
                                raw=response.read(1024*1024)
                            assert raw.startswith(b'\x89PNG')
                            source='OpenStreetMap standard visible-viewport request'
                        except Exception as error:
                            raw=nw.TILE;source='flat task-fixture fallback: '+type(error).__name__
                        owner.cache[path]=(raw,source)
                    raw,source=owner.cache[path]
                with owner.lock:
                    owner.record({'kind':'tile','path':path,'status':200,'source':source,'sha256':hashlib.sha256(raw).hexdigest()})
                self.reply(200,raw,'image/png')
        self.server.RequestHandlerClass=Handler

nw.Fixture=ViewportFixture
class RecordingWorkbench(nw.Workbench):
    recorder=None
    def __init__(self,*a,**kw):
        super().__init__(*a,**kw);self.markers=[];self.record_start=None
    def mark(self,event,**values):
        self.markers.append({'event':event,'utc':datetime.now(timezone.utc).isoformat(),'elapsed':round(time.monotonic()-self.record_start,3) if self.record_start else None,**values})
        print(event,values,flush=True)
    def start_recording(self):
        self.command('status_bar',self.device,'override','--time','09:41','--batteryState','charged','--batteryLevel','100')
        self.record_start=time.monotonic()
        self.video_log=(self.output/'recording.log').open('w')
        self.recorder=subprocess.Popen(['xcrun','simctl','io',self.device,'recordVideo','--codec=h264','--mask=black',str(self.output/'raw.mov')],stdout=self.video_log,stderr=self.video_log,pass_fds=self.fds)
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            if self.recorder.poll() is not None:raise RuntimeError('recordVideo exited early')
            if 'Recording started' in (self.output/'recording.log').read_text():
                self.mark('recording-ready');return
            time.sleep(.2)
        raise TimeoutError('recordVideo did not start')
    def stop_recording(self):
        if self.recorder and self.recorder.poll() is None:
            self.recorder.send_signal(signal.SIGINT)
            self.recorder.wait(timeout=30)
            self.video_log.close();self.mark('recording-stopped')
    def command(self,*a,**kw):
        if a and a[0]=='shutdown':self.stop_recording()
        return super().command(*a,**kw)
    def launch(self,phase,fixture):
        if self.record_start is None:self.start_recording()
        fixture.control({'sync':'delayed','delayMs':1400})
        self.mark('launch-start',phase=phase)
        result=super().launch(phase,fixture)
        self.mark('launch-ready',phase=phase,pid=result[0]);return result
    def drive(self,phase,pid,uri,fixture):
        self.mark('driver-start',phase=phase,pid=pid)
        result=super().drive(phase,pid,uri,fixture)
        self.mark('driver-finish',phase=phase,pid=pid,queue=len(result[1]['outbox']));return result
    def terminate(self,pid):
        self.mark('os-terminate-start',pid=pid)
        result=super().terminate(pid)
        self.mark('os-terminate-confirmed',pid=pid)
        time.sleep(1);return result

native_args=SimpleNamespace(output=args.output,driver_target='integration_test/video_driver.dart',candidate=fingerprint(args.root),runtime='com.apple.CoreSimulator.SimRuntime.iOS-26-4',device_type='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',configuration='demo',fixture=None)
with lease(['device:ios-task-simulator','app-workspace:'+str(args.root)],args.output,args.lock_root) as held:
    work=RecordingWorkbench(native_args,args.root,held['lock_fds'])
    try:
        with (args.output/'workbench-output.log').open('w') as stream,contextlib.redirect_stdout(stream):
            code=work.execute()
    finally:
        work.stop_recording()
        (args.output/'recording-markers.json').write_text(json.dumps(work.markers,indent=2)+'\n')
    work.report.update(scope='paced-native-demo-recording',business_acceptance=False,tile_source='task-local proxy for visible OSM viewport; see tile journal',recording='raw.mov')
    work.report.get('fixture',{}).pop('tile_sha256',None)
    work.save()
    print(json.dumps({'status':work.report['status'],'phases':work.report['phases'],'device_cleaned':work.report.get('device_cleaned'),'output':str(args.output)},indent=2))
    sys.exit(code)
