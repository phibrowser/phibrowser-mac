# issue: PHI-507
# based_on: handbook-snapshot-r2.md (2026-10-30-r2), original fixture SHA-256 d2b6a75d142a7c2624836557e90c07d0a15c8dd9ed0adb60f5fe2e152c951627
"""Real HTTP loading/download conditions; no browser control or introspection."""
import argparse,datetime,hashlib,html,json,os,re,time,uuid
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs,urlsplit
p=argparse.ArgumentParser();p.add_argument('--site-root',default='test-site');p.add_argument('--offset',type=int,default=1);p.add_argument('--log',default='qa-tools/condition-server-events.jsonl');a=p.parse_args()
first,last=map(int,os.environ['LANE_SITE_PORT_RANGE'].split('-'));port=first+a.offset;assert first<=port<=last
fixture=Path(a.site_root,'index.html').read_bytes();events=Path(a.log);events.parent.mkdir(parents=True,exist_ok=True)
def log(event):
 with events.open('a',encoding='utf-8') as f:f.write(json.dumps({'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),**event},ensure_ascii=False)+'\n')
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def do_GET(self):
  parsed=urlsplit(self.path);q=parse_qs(parsed.query);route=parsed.path
  run=q.get('run',['TC-PHI507-r2-condition'])[0][:64];tab=q.get('tab',['A'])[0][:16]
  if route=='/ready':
   body=json.dumps({'port':port,'fixture_sha256':hashlib.sha256(fixture).hexdigest(),'routes':['/fixture/','/slow','/download']}).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
  if route in ('/','/fixture/'):
   self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(fixture)));self.end_headers();self.wfile.write(fixture);return
  if route not in ('/slow','/download'):
   self.send_error(404);return
  try:duration=min(180,max(10,float(q.get('seconds',['120'])[0])))
  except ValueError:duration=120
  instance=str(uuid.uuid4());began=time.monotonic();sent=0;outcome='complete'
  self.send_response(200);self.send_header('Cache-Control','no-store');self.send_header('Connection','close');self.close_connection=True
  if route=='/download':
   name='TC-PHI507-r2-'+re.sub('[^A-Za-z0-9_-]','-',run)[:40]+'.txt';size=1024*1024
   self.send_header('Content-Type','text/plain; charset=utf-8');self.send_header('Content-Disposition','attachment; filename="'+name+'"');self.send_header('Content-Length',str(size));self.end_headers()
   chunk=(b'Disposable Phi QA slow transfer.\n'*256)[:4096];count=(size+len(chunk)-1)//len(chunk)
   try:
    for i in range(count):
     data=chunk[:min(len(chunk),size-sent)];self.wfile.write(data);self.wfile.flush();sent+=len(data);time.sleep(duration/count)
   except (BrokenPipeError,ConnectionResetError):outcome='client_disconnected'
  else:
   self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers()
   body=('''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>TC-'''+html.escape(tab)+' · '+html.escape(run)+'''</title><style>body{font:24px/1.6 system-ui;padding:30px}textarea{display:block;width:80%;height:140px;font:inherit}code{overflow-wrap:anywhere}</style></head><body><main><h1>TC-'''+html.escape(tab)+'''</h1><p>批次：<code>'''+html.escape(run)+'''</code></p><p>本次打开编号：<code>'''+instance+'''</code></p><p>真实 HTTP 主体正在传输；本页不是加载动画模拟。</p><label>存活标记<textarea placeholder="仅输入TC测试标记"></textarea></label><!--'''+(' '*8192)+'-->').encode()
   try:
    self.wfile.write(body);self.wfile.flush();sent+=len(body)
    while time.monotonic()-began<duration:
     time.sleep(min(1,max(0.01,duration-(time.monotonic()-began))));data=b'<!-- transfer heartbeat -->\n';self.wfile.write(data);self.wfile.flush();sent+=len(data)
    data=b'<p>HTTP transfer complete.</p></main></body></html>';self.wfile.write(data);self.wfile.flush();sent+=len(data)
   except (BrokenPipeError,ConnectionResetError):outcome='client_disconnected'
  log({'route':route,'run':run,'tab':tab,'request_id':instance,'bytes_sent':sent,'elapsed_seconds':round(time.monotonic()-began,3),'outcome':outcome})
log({'event':'listening','port':port,'fixture_sha256':hashlib.sha256(fixture).hexdigest()})
ThreadingHTTPServer(('127.0.0.1',port),Handler).serve_forever()
