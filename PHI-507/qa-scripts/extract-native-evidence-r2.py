"""Export images and UI text from the exact nested computer-use session used by QA."""
import base64,json,pathlib,sys
session,prefix=sys.argv[1:]
f=next(pathlib.Path.home().glob('.codex/sessions/**/rollout-*'+session+'*.jsonl'))
texts=[];i=0
for line in f.open():
 d=json.loads(line);p=d.get('payload',{})
 if p.get('type')=='custom_tool_call_output':
  for x in p.get('output',[]):
   if x.get('type')=='input_image':
    v=x.get('image_url','')
    if isinstance(v,str) and v.startswith('data:image/'):
     i+=1;ext='.jpg' if v.startswith('data:image/jpeg') else '.png'
     path=pathlib.Path('qa-evidence/r2')/(prefix+'-'+str(i).zfill(2)+ext);path.write_bytes(base64.b64decode(v.split(',',1)[1]))
   elif x.get('type')=='input_text' and (x.get('text','').startswith(('App=','Computer Use state'))):texts.append(x['text'])
 if p.get('type')=='message' and p.get('role')=='assistant':
  for x in p.get('content',[]):
   if x.get('type')=='output_text':texts.append(x['text'])
pathlib.Path('qa-evidence/r2',prefix+'.log').write_text('\n\n'.join(texts))
print(prefix,'screenshots',i)
