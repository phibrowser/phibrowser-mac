"""Export only evidence emitted by the native Computer Use session; never inspect the browser."""
import base64,json,pathlib,re,sys
session,prefix=sys.argv[1:];folder=pathlib.Path('qa-raw-r2')/prefix;folder.mkdir(parents=True,exist_ok=True)
f=next(pathlib.Path.home().glob('.codex/sessions/**/rollout-*'+session+'*.jsonl'));texts=[];index=[];i=0;calls=[]
for line in f.open():
 d=json.loads(line);p=d.get('payload',{})
 if p.get('type')=='custom_tool_call':
  value=p.get('input','');names=re.findall(r'tools\.([a-zA-Z0-9_]+)\s*\(',value);calls.extend(names)
 if p.get('type')=='custom_tool_call_output':
  marker='';state=''
  output=p.get('output',[])
  if not isinstance(output,list):
   if isinstance(output,str) and len(output)<4000:texts.append(output)
   continue
  for x in output:
   if not isinstance(x,dict):continue
   if x.get('type')=='input_text':
    t=x.get('text','')
    m=re.search(r'^EVIDENCE:\s*(.+)',t,re.M)
    if m:marker=m[1].strip();texts.append(t)
    if t.startswith(('App=','Computer Use state')):state=t;texts.append(t)
    if 'error' in t.lower() and len(t)<4000:texts.append(t)
   elif x.get('type')=='input_image':
    v=x.get('image_url','')
    if isinstance(v,str) and v.startswith('data:image/'):
     i+=1;ext='.jpg' if v.startswith('data:image/jpeg') else '.png';name=prefix+'-'+str(i).zfill(3)+ext;(folder/name).write_bytes(base64.b64decode(v.split(',',1)[1]));index.append({'file':name,'marker':marker,'state_head':state[:700]})
 if p.get('type')=='message' and p.get('role')=='assistant':
  for x in p.get('content',[]):
   if x.get('type')=='output_text':texts.append(x['text'])
(folder/(prefix+'.log')).write_text('\n\n'.join(texts));(folder/'index.json').write_text(json.dumps(index,ensure_ascii=False,indent=2));(folder/'audit.json').write_text(json.dumps({'session_id':session,'tools_called':sorted(set(calls)),'non_computer_use_calls':[n for n in calls if not n.startswith('mcp__computer_use__')]},indent=2));print(prefix,'images',i,'other_tools',sorted(set(n for n in calls if not n.startswith('mcp__computer_use__'))))
