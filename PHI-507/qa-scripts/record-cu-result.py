"""Persist explicit Ripley decisions after reviewing CU observations and screenshots."""
from pathlib import Path
import argparse,json,datetime
p=argparse.ArgumentParser();p.add_argument('job');p.add_argument('--grades',required=True,help='unit=result comma-separated, or *=result');p.add_argument('--note',default='');p.add_argument('--accept-completion-note',action='store_true',help='Parent explicitly reviewed a nonempty not_executed_reason as a completion explanation, not a missing step');a=p.parse_args()
qa=Path('PHI-507');round_state=qa/'active-qa-round.json';round_no=json.loads(round_state.read_text())['round'] if round_state.exists() else 2;assert isinstance(round_no,int) and round_no>=2;evprefix=f'qa-evidence/r{round_no}';lp=qa/'execution-ledger-r2.json';rows=json.loads(lp.read_text());data=json.loads((qa/f'{evprefix}/{a.job}-observations.json').read_text());ep=qa/f'{evprefix}/{a.job}-evidence.json';ev=json.loads(ep.read_text()) if ep.exists() else []
grades=dict(part.split('=',1) for part in a.grades.split(','));assert set(grades.values())<={'pass','fail','blocked','partial','skipped'}
for o in data['observations']:
 result=grades.get(o['unit_id'],grades.get('*'))
 if result is None:continue
 r=next(r for r in rows if r['key']==o['unit_id'])
 if result=='pass':assert not o['not_executed_reason'] or a.accept_completion_note, 'Explicit review of nonempty execution note required before passing'
 prior_evidence=r.get('evidence',[]) if isinstance(r.get('evidence'),list) else []
 prior_rounds=[int(part[1:]) for path in prior_evidence for part in Path(path).parts if part.startswith('r') and part[1:].isdigit()]
 prior_round=min(prior_rounds,default=round_no)
 for old in r.get('attempts',[]):
  if 'job' not in old:
   old.update(job=old.get('prefix',r['id']+'-initial'),round=prior_round,outcome=old.get('outcome',r['result']),actual=old.get('actual',r.get('actual','')),evidence=old.get('evidence',prior_evidence),scope='此前实际执行记录，保留其原始结果')
 if not r.get('attempts') and (r.get('observation') or prior_evidence):
  initial={'job':r['id'],'round':prior_round,'outcome':r['result'],'actual':r.get('actual',''),'evidence':prior_evidence,'notes':r.get('notes',''),'scope':'此前实际执行记录，保留其原始结果'}
  if r.get('observation'):initial['observation']=r['observation']
  r['attempts']=[initial]
 evidence=[f'{evprefix}/{a.job}-observations.json']+[f"{evprefix}/{e['file']}" for e in ev if e['unit_id']==r['key']]
 record={'job':a.job,'round':round_no,'outcome':result,'actual':o['after'],'observation':o,'evidence':evidence,'evidence_metadata':str(ep.relative_to(qa)),'notes':a.note,'scope':'本次指定执行点的实际动作；见observation中的未执行说明','reviewed_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 assert not any(t['job']==a.job and t.get('reviewed_at') for t in r.get('attempts',[])), 'Already recorded: '+a.job
 r.setdefault('attempts',[]).append(record);r.update(result=result,actual=o['after'],observation=o,evidence=evidence,notes=a.note,method='Computer Use',reviewed_by='Ripley',review_basis='原始CU观察、工具审计与关键前后截图；自动化无效尝试单列')
 if result in ('blocked','partial','skipped'):r['not_run_reason']=o['not_executed_reason'] or a.note
 else:r.pop('not_run_reason',None)
for row in rows:
 assert row['result'] in ('pending','pass','fail','blocked','partial','skipped')
 for name in row.get('evidence',[]) if isinstance(row.get('evidence'),list) else []:assert (qa/name).is_file(),name
lp.write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n');print('Recorded explicit grades for',a.job)
