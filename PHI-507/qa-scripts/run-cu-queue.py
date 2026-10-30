"""Run independent exact UI-operation jobs sequentially; never grade their results."""
from pathlib import Path
import datetime,json,subprocess,sys
qa=Path('PHI-507');jobs=sys.argv[1:];state=qa/'qa-evidence/r2/queue-state.json'
for i,job in enumerate(jobs):
 if (qa/'qa-evidence/r2/stop-after-current').exists():break
 state.write_text(json.dumps({'current':job,'index':i,'total':len(jobs),'state':'running','time':datetime.datetime.now(datetime.timezone.utc).isoformat()},indent=2))
 args=job.split(':');cmd=['python3',str(qa/'qa-scripts/run-cu-case.py'),args[0]]
 if len(args)>1:cmd+=['--language',args[1]]
 timeout=7200 if args[0]=='LIFE-11' else 2400
 cmd+=['--timeout',str(timeout)]
 print('START',job,flush=True);r=subprocess.run(cmd);print('END',job,'exit',r.returncode,flush=True)
 if r.returncode:state.write_text(json.dumps({'current':job,'state':'operator_error','exit_code':r.returncode},indent=2));sys.exit(r.returncode)
else:state.write_text(json.dumps({'state':'finished','jobs':jobs},indent=2))
