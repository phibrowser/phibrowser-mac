"""Run independent exact UI-operation jobs sequentially; never grade their results."""
from pathlib import Path
import datetime,json,subprocess,sys
qa=Path('PHI-507');round_state=qa/'active-qa-round.json';round_no=json.loads(round_state.read_text())['round'] if round_state.exists() else 2;assert isinstance(round_no,int) and round_no>=2;evdir=qa/'qa-evidence'/f'r{round_no}';evdir.mkdir(parents=True,exist_ok=True);jobs=sys.argv[1:];state=evdir/'queue-state.json'
for i,job in enumerate(jobs):
 if (evdir/'stop-after-current').exists():
  state.write_text(json.dumps({'state':'stopped_before_next','next':job,'remaining':jobs[i:]},indent=2));break
 state.write_text(json.dumps({'current':job,'index':i,'total':len(jobs),'state':'running','time':datetime.datetime.now(datetime.timezone.utc).isoformat()},indent=2))
 args=job.split(':');cmd=['python3',str(qa/'qa-scripts/run-cu-case.py'),args[0]]
 if len(args)>1 and args[1]:cmd+=['--language',args[1]]
 if len(args)>2 and args[2]:cmd+=['--tag',args[2]]
 if args[0] in ('VIS-01','VIS-02','VIS-04'):
  cmd+=['--instructions',str(qa/'qa-scripts/native-menu-only-r2.txt')]
 if args[0]=='DBL-19':cmd+=['--instructions',str(qa/'qa-scripts/dbl19-retry-r2.txt')]
 timeout=7200 if args[0]=='LIFE-11' else (5400 if args[0] in ('DBL-13','DBL-14','DBL-16','DBL-17','DBL-19','DBL-23','GRP-13','GRP-14','GRP-15') else 3600)
 cmd+=['--timeout',str(timeout)]
 print('START',job,flush=True);r=subprocess.run(cmd);print('END',job,'exit',r.returncode,flush=True)
 if r.returncode:state.write_text(json.dumps({'current':job,'state':'operator_error','exit_code':r.returncode},indent=2));sys.exit(r.returncode)
else:state.write_text(json.dumps({'state':'finished','jobs':jobs},indent=2))
