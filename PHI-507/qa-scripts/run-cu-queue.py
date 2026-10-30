"""Run independent exact UI-operation jobs sequentially; never grade their results."""
from pathlib import Path
import datetime,json,subprocess,sys
qa=Path('PHI-507');jobs=sys.argv[1:];state=qa/'qa-evidence/r2/queue-state.json'
for i,job in enumerate(jobs):
 if (qa/'qa-evidence/r2/stop-after-current').exists():
  state.write_text(json.dumps({'state':'stopped_before_next','next':job,'remaining':jobs[i:]},indent=2));break
 state.write_text(json.dumps({'current':job,'index':i,'total':len(jobs),'state':'running','time':datetime.datetime.now(datetime.timezone.utc).isoformat()},indent=2))
 args=job.split(':');cmd=['python3',str(qa/'qa-scripts/run-cu-case.py'),args[0]]
 if len(args)>1 and args[1]:cmd+=['--language',args[1]]
 if len(args)>2 and args[2]:cmd+=['--tag',args[2]]
 if args[0] in ('VIS-01','VIS-02','VIS-04'):
  cmd+=['--instructions',str(qa/'qa-scripts/native-menu-only-r2.txt')]
 if args[0]=='DBL-19':cmd+=['--instructions',str(qa/'qa-scripts/dbl19-controls-r2.txt')]
 timeout=7200 if args[0]=='LIFE-11' else (5400 if args[0]=='DBL-19' else 2400)
 cmd+=['--timeout',str(timeout)]
 print('START',job,flush=True);r=subprocess.run(cmd);print('END',job,'exit',r.returncode,flush=True)
 if r.returncode:state.write_text(json.dumps({'current':job,'state':'operator_error','exit_code':r.returncode},indent=2));sys.exit(r.returncode)
else:state.write_text(json.dumps({'state':'finished','jobs':jobs},indent=2))
