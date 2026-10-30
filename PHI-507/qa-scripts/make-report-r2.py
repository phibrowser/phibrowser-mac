"""Render Ripley's explicitly reviewed r2 ledger after the leased UI work is over."""
from pathlib import Path
from collections import Counter
from datetime import datetime,timezone
import argparse,json,shutil,re
p=argparse.ArgumentParser();p.add_argument('--plan-sha',required=True);p.add_argument('--verdict',choices=['pass','fail','blocked'],required=True);p.add_argument('--summary',required=True);p.add_argument('--round',type=int,default=2);p.add_argument('--checkpoint',action='store_true');p.add_argument('--webp',action='store_true');a=p.parse_args();assert a.round>=2
qa=Path('PHI-507');assert not Path('.lane/current.json').exists(),'Release the leased UI session before writing the report'
rows=json.loads((qa/'execution-ledger-r2.json').read_text());assert len(rows)==512 and len({r['key'] for r in rows})==512
assert a.checkpoint or not any(r['result']=='pending' for r in rows),'Resolve every pending item explicitly, preserving not-run reasons'
if a.checkpoint:assert a.verdict=='blocked','An incomplete checkpoint cannot pass'
identity=json.loads((qa/'qa-evidence/r2/installed-identity.json').read_text());out=qa/f'report-r{a.round}';out.mkdir(exist_ok=True);evroot=out/'evidence'
if evroot.exists():shutil.rmtree(evroot)
evroot.mkdir()
bugs=json.loads((qa/'bugs-r2.json').read_text()) if (qa/'bugs-r2.json').exists() else []
cases=[];published_sources={}
for prior_round in range(2,a.round):
 prior=json.loads((qa/f'report-r{prior_round}/report.json').read_text())
 for case in prior['cases']:
  for item in case.get('evidence',[]):
   if item.get('source_path') and item.get('path'):
    published_sources.setdefault(item['source_path'],f"https://argus-phi.github.io/phi-ai-test-reports/PHI-507/r{prior_round}/"+item['path'])
for r in rows:
 status='blocked' if r['result']=='partial' else ('skipped' if r['result']=='pending' else r['result']);assert status in ('pass','fail','blocked','skipped')
 direct=lambda s:s.replace('{before}','关闭左侧标签页' if r['layout']=='comfortable' else '关闭上方标签页').replace('{after}','关闭右侧标签页' if r['layout']=='comfortable' else '关闭下方标签页')
 evidence=[];seen=set();sequence=0
 def add(path,caption,attempt=None,outcome=None,provenance=None):
  source=qa/path;assert source.is_file(),str(source)
  key=(path,attempt,outcome)
  if key in seen:return
  seen.add(key);source_round=next((part for part in source.parts if re.fullmatch(r'r[0-9]+',part)),'shared');target_name=source.name
  if source_round!='shared' and int(source_round[1:])<a.round:
   assert path in published_sources,'Publish the source round before carrying its evidence forward: '+path
   item={'type':'link','url':published_sources[path],'caption':caption+'；先前轮次的完整原始证据，本轮未重跑','source_path':path}
   if attempt is not None:item['attempt']=attempt
   if outcome is not None:item['outcome']=outcome
   evidence.append(item)
   if source.suffix.lower()=='.png' and not any(e.get('carried_preview') for e in evidence):
    from PIL import Image
    dest=evroot/source_round/(r['key']+'-prior-preview.webp');dest.parent.mkdir(exist_ok=True)
    with Image.open(source) as im:
     preview=im.convert('RGB');preview.thumbnail((640,10000),Image.Resampling.LANCZOS);preview.save(dest,'WEBP',lossless=True,method=6)
    preview_item={'type':'image','path':str(dest.relative_to(out)),'caption':f'沿用{source_round}的实际截图缩略图；完整尺寸及全部尝试见同组先前证据链接，本轮未重跑。','carried_preview':True,'source_path':path}
    if attempt is not None:preview_item['attempt']=attempt
    if outcome is not None:preview_item['outcome']=outcome
    evidence.append(preview_item)
   return
  if a.webp and source.suffix.lower()=='.png':target_name=source.stem+'.webp'
  dest=evroot/source_round/target_name;dest.parent.mkdir(exist_ok=True)
  if not dest.exists():
   if a.webp and source.suffix.lower()=='.png':
    from PIL import Image
    with Image.open(source) as im:im.convert('RGB').save(dest,'WEBP',lossless=True,method=6)
   else:shutil.copy2(source,dest)
  item={'type':'image' if source.suffix=='.png' else 'log','path':str(dest.relative_to(out)),'caption':caption,'source_path':str(source.relative_to(qa))}

  if attempt is not None:item['attempt']=attempt
  if outcome is not None:item['outcome']=outcome
  if provenance:item['provenance']=provenance
  evidence.append(item)
 attempts=list(r.get('attempts',[]))
 for d in r.get('diagnostics',[]):attempts.append({**d,'outcome':'partial','scope':d['scope'],'evidence':[]})
 if not attempts and r.get('observation'):
  attempts=[{'job':r['id'],'outcome':r['result'],'observation':r['observation'],'evidence':r.get('evidence',[])}]
 for record in attempts:
  job=record['job'];record_round=record.get('round',2);meta=qa/record.get('evidence_metadata',f'qa-evidence/r{record_round}/{job}-evidence.json');frame_prefix=str(meta.parent.relative_to(qa))
  frames=[e for e in json.loads(meta.read_text()) if e['unit_id']==r['key']] if meta.is_file() else []
  family=lambda phase:re.sub(r'-(before|after|failure)$','',phase) if '-' in phase else 'main'
  max_by_family={}
  for frame in frames:
   fam=family(frame['phase']);max_by_family[fam]=max(frame['attempt'],max_by_family.get(fam,0))
  def frame_outcome(frame):
   if 'failure' in frame['phase']:return 'fail'
   if record.get('evidence_outcome') in ('pass','fail'):return record['evidence_outcome']
   if record['outcome']=='pass' and frame['attempt']==max_by_family[family(frame['phase'])]:return 'pass'
   return None
  groups=list(dict.fromkeys((family(e['phase']),e['attempt'],frame_outcome(e)) for e in frames))
  mapping={key:sequence+i+1 for i,key in enumerate(groups)};sequence+=len(groups) or 1
  for frame in frames:
   native=frame['attempt'];outcome=frame_outcome(frame)
   add(frame_prefix+'/'+frame['file'],f"{job}：{frame['phase']}（原生marker attempt{native}；子步骤观察不等于整例通过，准备/操作无效与产品缺陷分开）",mapping[(family(frame['phase']),native,outcome)],outcome,frame)
  if record.get('observation'):
   part=f"{frame_prefix}/{r['key']}-{job}-observation.json";original=qa/f'{frame_prefix}/{job}-observations.json'
   (qa/part).write_text(json.dumps({'unit_id':r['key'],'job':job,'scope':record.get('scope','本执行点的实际步骤'),'source':str(original.relative_to(qa)),'observation':record['observation']},ensure_ascii=False,indent=2)+'\n')
   add(part,record.get('scope','本执行点')+' 原始观察',sequence,'pass' if record['outcome']=='pass' else ('fail' if record['outcome']=='fail' else None))
  for path in record.get('evidence',[]):
   if not isinstance(path,str) or path.endswith(('-observations.json','-evidence.json')) or path.endswith('.png') and frames:continue
   add(path,job+' 原始观察/证据索引',sequence,'pass' if record['outcome']=='pass' else ('fail' if record['outcome']=='fail' else None))
 if isinstance(r.get('evidence'),list):
  for path in r['evidence']:
   if attempts and path.endswith(('-observations.json','-evidence.json')):continue
   if any(item.get('source_path')==path for item in evidence):continue
   add(path,'本轮实际观察与环境证据')
 o=r.get('observation',{})
 c={'id':r['key'],'title':r['title'],'priority':r['priority'],'mode':'gui','ac':r['id'],'precondition':direct(r['pre']),'steps':[direct(s) for s in r['steps']],'expected':'；'.join(direct(s) for s in r['expected']),'actual':r.get('actual') or r.get('not_run_reason') or ('本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。' if r['result']=='pending' else '未执行，详见备注。'),'status':status,'evidence':evidence,'bugs':[b['id'] for b in bugs if r['key'] in b.get('case_ids',[])],'notes':'；'.join(v for v in [r.get('notes',''),r.get('not_run_reason',''),'部分执行，未判通过。' if r['result']=='partial' else ('本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。' if r['result']=='pending' else '')] if v),'uses_chat':False,'layout':r['layout'],'language':o.get('language_observed',r['language'] or ('zh-Hans' if r['id']=='VIS-01' else '本项未独立实读')),'variant':r['variant'],'settings':o.get('settings_observed','本项未独立实读'),'object_sets':{'before':o.get('before'),'after':o.get('after'),'active_before':o.get('active_before'),'active_after':o.get('active_after'),'identity_checks':o.get('identity_checks')},'steps_executed':o.get('steps_executed',[]),'confirmation_choices':o.get('confirmation_choices','未执行/未另行记录'),'operator_errors':o.get('operator_errors',[]),'execution_scope':'handbook','evidence_rounds':sorted({record.get('round',2) for record in attempts}),'carried_forward':bool(attempts) and all(record.get('round',2)<a.round for record in attempts)}
 if c['carried_forward']:
  prior='、'.join('r'+str(n) for n in c['evidence_rounds']);c['actual']=f'沿用{prior}的本次Computer Use测试活动结果，本轮未重跑：'+c['actual'];c['notes']=f'先前有效结果保留，非本轮新增执行；完整证据来自{prior}。'+c['notes']
 cases.append(c)
counts=Counter(c['status'] for c in cases)
if a.verdict=='pass':assert not counts['blocked'] and not counts['skipped'] and not counts['fail'] and not any(b['severity'] in ('major','blocker') for b in bugs)
report={'issue':'PHI-507','based_on':'PHI-507/test-plan.md@'+a.plan_sha,'key':'PHI-507','title':'Phi TabClose 独立安装包完整手册测试','round':a.round,'kind':'test','work_type':'feature','verdict':a.verdict,'pr_allowed':False,'summary':a.summary,'sha':'b30ef8b3acbc832ee3f1aaa8ce682ebb28289654ff3fdb84fbdf04151bb59d0b','sha_kind':'installed_executable_sha256','branch':'feature/tab-close-improvements（指定二进制，含未提交修改；不是检出分支测试）','generated_at':datetime.now(timezone.utc).isoformat(),'source_base_commit':'d390230615c172c3a3f94132e0b36ce081dac0be','source_complete_commit':None,'source_diff_sha256':'6865cc137ce00f136bbf6ce303a7bbd2380a659dfb460b06b7e238948fc16d92','source_case_count':512,'source_case_counts':dict(counts),'checkpoint':a.checkpoint,'cumulative_CU_results':True,'carried_forward_case_ids':[c['id'] for c in cases if c.get('carried_forward')],'environment':{'系统/芯片':'macOS 26.6.2 (25G83) / arm64，仅此环境','app':'/Applications/Phi Tab Close QA.app；Wood已安装，本轮未替换/卸载','构建':'TC-QA-20261030.1 / 0.0.0 (1030.1)','渠道/Framework':'OpenSource / com.phibrowser.opensource.Mac / 156.0.8078.52','SHA口径':'本轮实际安装app的可执行文件SHA-256；没有重新取得或校验ZIP','手册':'2026-10-30-r2；166基础用例展开512项；原文快照已保留','浏览器手段':'仅租用e2e02中的Computer Use；本轮未使用CDP/API/DOM/JS/AppleScript/直接AX脚本','首次导航':'重启后一度Stop/空白；约73–75秒后实见fixture，后续重跑。无手册SLA，未据此判永久导航缺陷','官方/硬件/旧版':'缺失项逐项列出，不代表官方AI、Intel、最低系统或真实鼠标/触控板通过','源代码验证':'独立二进制黑盒任务；未运行或宣称源码单元测试/类型检查/构建通过','环境身份记录':json.dumps(identity,ensure_ascii=False),'会话清理':'见lane-release.json及cleanup观察；共享app及Wood预先挂载DMG保留'},'plan_docs':[{'title':'本轮完整测试计划与Computer Use手测方案','url':f'https://github.com/phibrowser/phibrowser-mac/blob/{a.plan_sha}/PHI-507/test-plan.md'},{'title':'本轮手册快照','url':f'https://github.com/phibrowser/phibrowser-mac/blob/{a.plan_sha}/PHI-507/handbook-snapshot-r2.md'},{'title':'原手册','url':'https://woodnotfound.github.io/phi-qa-handbooks/tab-closing/'},{'title':'r1历史报告（本轮不沿用任何测试结果）','url':'https://argus-phi.github.io/phi-ai-test-reports/PHI-507/r1/'}],'cases':cases,'bugs':bugs,'known_issues':[],'execution_deviations':['r1通过或失败均不作为r2结果；r2从头执行。','早期SET-08/SET-10在15–30秒加载状态停止前置；发现首次加载约75秒后成功，保留旧尝试并另开retry重跑。','部分CU坐标/原生元素定位无效尝试被保留并明确区分产品结果。','早期SET-03/SET-05各有一次把图片编码串成文本并截断的输出；该文本不作为截图，只使用实际保存且可解码的关键图。','SET-10源步骤分段补齐；错误限定横向row及off/on条件偏差均未冒充完整执行，最后按真实tabStripTab button和off/off补齐。','PNG可缩放和裁切关键区域，并用原图主色与保留黑白、原生强调色的调色板压缩；失败/外观关键帧保留RGB，来源SHA与裁切框见证据索引。']}
(out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
url=f'https://argus-phi.github.io/phi-ai-test-reports/PHI-507/r{a.round}/'
lines=['issue: PHI-507','based_on: PHI-507/test-plan.md@'+a.plan_sha,'',f'# 独立安装包 Computer Use 续测 r{a.round}','',f'报告站：{url}','','结论：`'+a.verdict+'`。'+a.summary,'','## 构建与执行边界','','- 已纳入Wood在触发评论中的补充；浏览器操作、状态读取、截图均通过e2e02的Computer Use，r1结果不继承。',f'- 构建与范围见 `report-r{a.round}/report.json`；可执行文件SHA-256为 `'+report['sha']+'`；base commit不是完整被测源SHA。','- 真实环境仅macOS 26.6.2 arm64、OpenSource。没有声称源代码检查或未取得环境通过。','- 手册全部512项均保留；部分执行不标pass，未执行按具体原因列blocked/skipped。','- 重启后的首次导航延迟最终恢复；没有继承r1的B1-1为当前阻断或缺陷。','','## 缺陷与范围外已知问题','']
lines += [f"- {b['id']} / {b['severity']}：{b['title']}；{b.get('repro','')}" for b in bugs] or ['没有已确认的当前产品缺陷。']
lines+=['','无旧构建基线证实的范围外既有问题；没有建立PBL。独立包无PR，不作PR放行。','','## 全量执行结果','','| 用例 | 优先级 | 布局/语言 | 结果 | 实际/未完成原因 | 证据 |','|---|---|---|---|---|---|']
for c in cases:
 vals=[c['id'],c['priority'],c['layout']+'/'+c['language'],c['status'],c['actual']+' '+c['notes'],'、'.join(e.get('source_path',e.get('path','')) for e in c['evidence']) or '无（未执行）']
 lines.append('| '+' | '.join(str(v).replace('|','／').replace('\n',' ') for v in vals)+' |')
(qa/f'test-report-r{a.round}.md').write_text('\n'.join(lines)+'\n');print('counts',dict(counts));print('evidence bytes',sum(f.stat().st_size for f in evroot.rglob('*') if f.is_file()))
