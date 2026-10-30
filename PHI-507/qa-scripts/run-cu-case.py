"""Run one precisely specified native UI case through the leased Computer Use operator."""
from pathlib import Path
import argparse,datetime,json,re,subprocess,sys
p=argparse.ArgumentParser();p.add_argument('base');p.add_argument('--language');p.add_argument('--layout');p.add_argument('--unit');p.add_argument('--tag');p.add_argument('--instructions');p.add_argument('--timeout',type=int,default=1800);a=p.parse_args()
root=Path.cwd();qa=root/'PHI-507';lane=Path('/Users/phi/multica_workspaces_mca/phi-7b4ee50429fe/phi-507-e5a0d2f5aff4/codex-home/skills/phi-e2e-lane/scripts/lane')
round_state=qa/'active-qa-round.json'
round_no=json.loads(round_state.read_text())['round'] if round_state.exists() else 2
assert isinstance(round_no,int) and round_no>=2
evidence_dir=qa/'qa-evidence'/f'r{round_no}';evidence_dir.mkdir(parents=True,exist_ok=True)
lease=json.loads((root/'.lane/current.json').read_text())
remaining=(datetime.datetime.fromisoformat(lease['expires_at'].replace('Z','+00:00'))-datetime.datetime.now(datetime.timezone.utc)).total_seconds()
if remaining<a.timeout+1800:
 subprocess.run(['python3',str(lane),'extend','--ttl','8h'],check=True)
bases=a.base.split(',')
units=[x for x in json.loads((qa/'execution-ledger-r2.json').read_text()) if x['id'] in bases and (a.layout is None or x['layout']==a.layout) and (a.language is None or x['language']==a.language) and (a.unit is None or x['key']==a.unit)]
units.sort(key=lambda x:({'once':0,'performance':1,'balanced':2,'comfortable':3}[x['layout']],bases.index(x['id'])))
assert units,a.base
job=a.base.replace(',','_')+('-'+a.layout if a.layout else '')+('-'+a.language if a.language else '')+('-'+a.unit if a.unit else '')+('-'+a.tag if a.tag else '');remote=lease['env']['LANE_WORKDIR']+f'/qa-evidence/r{round_no}/observations/'+job+'.json'
payload=[]
for u in units:
 direct=lambda s:s.replace('{before}','关闭左侧标签页' if u['layout']=='comfortable' else '关闭上方标签页').replace('{after}','关闭右侧标签页' if u['layout']=='comfortable' else '关闭下方标签页')
 payload.append({'unit_id':u['key'],'title':u['title'],'layout':u['layout'],'language':u['language'] or ('zh-Hans' if a.base=='VIS-01' else '当前en'),'variant':u['variant'],'precondition':direct(u['pre']),'steps':[direct(s) for s in u['steps']],'expected_for_recording_only':[direct(s) for s in u['expected']],'reset':u['reset']})
state=evidence_dir/'ending-state.txt';background=state.read_text() if state.exists() else '当前TC-QA-PHI507-r2，六个HTTPS测试A-F，B活动且有KEEP-B-507-r2；Balanced。旧窗口Default Chrome Web Store保留。Settings已关闭；本次仍需重新读取。'
prompt=(qa/'qa-scripts/cu-operator-prefix.txt').read_text()+'\n\n本次限定执行批次：'+a.base+'。只执行下面列出的精确动作，不规划或添加其他用例。每个unit独立重建前置，按给定次序执行；同布局内不重复切换布局，最后统一恢复偏好。\n前次结束背景（不是当前事实，须实际重读）：'+background+'\n指定执行点数据：\n'+json.dumps(payload,ensure_ascii=False,indent=2)
if a.language or a.base=='VIS-01':
 labels=json.loads((qa/'handbook-data.json').read_text())['labels'].get(a.language or 'zh-Hans',{})
 prompt+='\n本语言手册规定的确切文案（仅作观察对照，不代替实读）：\n'+json.dumps(labels,ensure_ascii=False,indent=2)
if a.instructions:prompt+='\n本任务额外操作约束：\n'+Path(a.instructions).read_text()
subprocess.run(['python3',str(lane),'run','--','mkdir','-p',lease['env']['LANE_WORKDIR']+f'/qa-evidence/r{round_no}/observations'],check=True)
scratch=root/f'scratch-PHI507-r{round_no}'/job;scratch.mkdir(parents=True,exist_ok=True);log=scratch/(job+'-console.log');started=datetime.datetime.now(datetime.timezone.utc).isoformat();(evidence_dir/'runner-state.json').write_text(json.dumps({'job':job,'started_at':started,'state':'running','units':[u['key'] for u in units]},indent=2))
cmd=['python3',str(lane),'gui','--timeout',str(a.timeout),'--','codex','exec','--skip-git-repo-check','--output-schema',lease['env']['LANE_WORKDIR']+'/qa-tools/cu-observation.schema.json','--output-last-message',remote,prompt]
with log.open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
text=log.read_text();m=re.search(r'session id: ([a-f0-9-]+)',text);sid=m[1] if m else None
result={'job':job,'exit_code':r.returncode,'session_id':sid,'round':round_no,'lease_id':lease['lease_id'],'started_at':started,'ended_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'units':[u['key'] for u in units]}
if sid:
 subprocess.run(['python3',str(lane),'run','--timeout','60','--','python3','qa-tools/extract.py',sid,job,str(round_no)],check=True)
if r.returncode==0:
 subprocess.run(['python3',str(lane),'pull',remote,str(evidence_dir/(job+'-observations.json'))],check=True)
 data=json.loads((evidence_dir/(job+'-observations.json')).read_text());seen=[v['unit_id'] for v in data['observations']]
 result['observed_units']=seen;result['missing_units']=sorted(set(result['units'])-set(seen));result['duplicate_units']=len(seen)!=len(set(seen));state.write_text(data['ending_state'])
subprocess.run(['python3',str(lane),'pull',f'qa-raw-r{round_no}/'+job+'/',str(scratch/'raw/')],check=True)
(evidence_dir/(job+'-run.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2));(evidence_dir/'runner-state.json').write_text(json.dumps({**result,'state':'finished'},ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2));sys.exit(r.returncode)
