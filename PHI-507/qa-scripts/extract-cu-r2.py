"""Export only evidence emitted by the native Computer Use session; never inspect the browser."""
import base64,json,pathlib,re,sys,collections
session,prefix=sys.argv[1:3];round_no=int(sys.argv[3]) if len(sys.argv)>3 else 2;folder=pathlib.Path(f'qa-raw-r{round_no}')/prefix;folder.mkdir(parents=True,exist_ok=True)
f=next(pathlib.Path.home().glob('.codex/sessions/**/rollout-*'+session+'*.jsonl'));texts=[];index=[];i=0;calls=[];actions=[];warnings=[]
for line in f.open():
 d=json.loads(line);p=d.get('payload',{})
 if p.get('type')=='custom_tool_call':
  value=p.get('input','');actions.append({'timestamp':d.get('timestamp'),'input':value});names=re.findall(r'tools\.([a-zA-Z0-9_]+)\s*\(',value);names+=re.findall(r'[\"\'](mcp__[a-zA-Z0-9_]+)[\"\']',value);calls.extend(names)
 if p.get('type')=='custom_tool_call_output':
  marker='';state=''
  output=p.get('output',[])
  if not isinstance(output,list):output=[{'type':'input_text','text':output}] if isinstance(output,str) else []
  queue=collections.deque(output)
  while queue:
   x=queue.popleft()
   if not isinstance(x,dict):continue
   if x.get('type')=='input_text':
    t=x.get('text','')
    m=re.search(r'^EVIDENCE:\s*(.+)',t,re.M)
    if m:marker=m[1].strip();texts.append(t if len(t)<4000 else m[0])
    start=t.find('{"content":')
    if start>=0:
     try:serialized,_=json.JSONDecoder().raw_decode(t[start:])
     except Exception:serialized=None
     if isinstance(serialized,dict) and isinstance(serialized.get('content'),list):
      converted=[]
      for block in serialized['content']:
       if not isinstance(block,dict):continue
       if block.get('type')=='text':converted.append({'type':'input_text','text':block.get('text','')})
       elif block.get('type')=='image' and block.get('data'):converted.append({'type':'input_image','image_url':'data:'+block.get('mimeType','image/jpeg')+';base64,'+block['data']})
      queue.extendleft(reversed(converted));continue
    if t.startswith(('App=','Computer Use state')):state=t;texts.append(t)
    if 'error' in t.lower() and len(t)<4000:texts.append(t)
    elif not t.startswith(('App=','Computer Use state')) and not m and t.strip() and len(t)<50000:texts.append(t)
   elif x.get('type')=='input_image':
    v=x.get('image_url','')
    if isinstance(v,str) and v.startswith('data:image/'):
     try:blob=base64.b64decode(v.split(',',1)[1],validate=True)
     except (ValueError,UnicodeError) as error:
      warnings.append({'marker':marker,'reason':'invalid/truncated serialized image: '+str(error)});continue
     if not (blob.endswith(b'\xff\xd9') if v.startswith('data:image/jpeg') else blob.endswith(b'IEND\xaeB`\x82')):
      warnings.append({'marker':marker,'reason':'image end marker absent; not exported'});continue
     i+=1;ext='.jpg' if v.startswith('data:image/jpeg') else '.png';name=prefix+'-'+str(i).zfill(3)+ext;(folder/name).write_bytes(blob);index.append({'file':name,'marker':marker,'state_head':state[:700]})
 if p.get('type')=='message' and p.get('role')=='assistant':
  for x in p.get('content',[]):
   if x.get('type')=='output_text':texts.append(x['text'])
(folder/'actions.json').write_text(json.dumps(actions,ensure_ascii=False,indent=2));(folder/(prefix+'.log')).write_text('\n\n'.join(texts));(folder/'index.json').write_text(json.dumps(index,ensure_ascii=False,indent=2));(folder/'audit.json').write_text(json.dumps({'session_id':session,'audit_scope':'tool references in saved CU orchestration; no browser introspection','tools_called':sorted(set(calls)),'extraction_warnings':warnings,'non_computer_use_calls':[n for n in calls if not n.startswith('mcp__computer_use__')]},indent=2));print(prefix,'images',i,'other_tools',sorted(set(n for n in calls if not n.startswith('mcp__computer_use__'))))
