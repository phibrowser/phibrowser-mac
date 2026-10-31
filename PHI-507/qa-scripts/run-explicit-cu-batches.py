"""Execute an explicit list of CU-only batches synchronously, with durable collection."""
from pathlib import Path
import datetime, json, subprocess, sys

qa=Path('PHI-507')
config=Path(sys.argv[1])
jobs=json.loads(config.read_text())
round_no=json.loads((qa/'active-qa-round.json').read_text())['round']
ev=qa/f'qa-evidence/r{round_no}'
for i,args in enumerate(jobs):
    if (ev/'stop-after-current').exists():
        (ev/'queue-state.json').write_text(json.dumps({'state':'stopped_before_next','remaining':jobs[i:]},indent=2)+'\n')
        break
    state={'state':'running','index':i,'total':len(jobs),'args':args,'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (ev/'queue-state.json').write_text(json.dumps(state,indent=2)+'\n')
    print('START',json.dumps(args),flush=True)
    result=subprocess.run(['python3',str(qa/'qa-scripts/run-cu-case.py'),*args])
    print('END',result.returncode,flush=True)
    if result.returncode:
        (ev/'queue-state.json').write_text(json.dumps({**state,'state':'operator_error','exit_code':result.returncode,'remaining':jobs[i+1:]},indent=2)+'\n')
        sys.exit(result.returncode)
else:
    (ev/'queue-state.json').write_text(json.dumps({'state':'finished','jobs':jobs},indent=2)+'\n')
