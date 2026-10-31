"""Preserve actual pre-interruption observations and Ripley's screenshot review."""
from pathlib import Path
import json, hashlib, datetime

qa = Path('PHI-507')
ev = qa/'qa-evidence/r5'
job = 'POS-03_POS-04-balanced-basic-r5'
raw = Path('scratch-PHI507-r5')/job/'raw'
log = (raw/(job+'.log')).read_text()
observation = json.JSONDecoder().raw_decode(log.split('OBSERVATION: ',1)[1])[0]
assert observation['unit_id'] == 'POS-03-BAL'
data = {
    'base_case': '从中断前真实CU会话日志恢复的POS-03观察；没有生成新的浏览器动作。POS-04未开始。',
    'ending_state': '最后实际截图为POS-03的F活动，C/D/E/F保留。没有完成POS-04或偏好恢复；原租约随后由平台task_ended自动归还。',
    'observations': [observation], 'tools_outside_computer_use': [],
    'recovery_source': str(raw/(job+'.log')),
}
(ev/(job+'-observations.json')).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
audit = json.loads((raw/'audit.json').read_text())
run = {'job':job,'session_id':audit['session_id'],'round':5,
       'lease_id':'52a943f0-2b80-4fdf-9258-ff0ac91c8040',
       'state':'interrupted','exit_code':None,'observed_units':['POS-03-BAL'],
       'missing_units':['POS-04-BAL'],'recovered':True,
       'interruption':'顶层模型HTTP524；原前台driver结果未返回，不声称正常收尾。',
       'computer_use_audit':{'completed_mcp_event_count':audit['mcp_event_count'],
          'non_computer_use_calls':audit['non_computer_use_calls'],
          'non_computer_use_mcp_events':audit['non_computer_use_mcp_events'],
          'source_sha256':hashlib.sha256((raw/'audit.json').read_bytes()).hexdigest()}}
(ev/(job+'-run.json')).write_text(json.dumps(run,ensure_ascii=False,indent=2)+'\n')
jobs = {
 'POS-01_POS-02-balanced-basic-r5':[2,3,6,7,8,9,10,11,12,13,14,15,16,17,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34],
 job:[2,3,8,9,10,11,12,15,16,17,18,19,20,21,22,23,24,25,26],
}
review={'reviewer':'Ripley','reviewed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'basis':'POS01/02关键29原图已于前一上下文实际查看；POS03所列19原图本上下文实际查看。编号逐页核对；没有声称查看其余进度图。',
 'decisions':{'POS-01-BAL':'pass','POS-02-BAL':'pass','POS-03-BAL':'pass','POS-04-BAL':'pending'},
 'findings':['POS01：D活动，Above后D/E/F，D仍活动，三个原编号相同。',
 'POS02：C活动，Below后A/B/C，C仍活动，三个原编号相同。',
 'POS03：F活动，直接右键C，Above后C/D/E/F，F仍活动，四个原编号相同。',
 'POS03旧长run及空白setup原图保留；短run F返回后完成前置。批次中断没有执行POS04或恢复偏好，不能把整批判完成。'],
 'sources':[]}
for j,nums in jobs.items():
 p=Path('scratch-PHI507-r5')/j/'raw'
 index=json.loads((p/'index.json').read_text())
 for n in nums:
  item=index[n-1]
  review['sources'].append({'job':j,'number':n,'file':item['file'],'marker':item['marker'],
    'sha256':hashlib.sha256((p/item['file']).read_bytes()).hexdigest()})
(ev/'position-basic-recovery-review.json').write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n')
# Captions preserve the misleading intermediate capture without misrepresenting it.
p=ev/(job+'-evidence.json'); frames=json.loads(p.read_text())
for frame in frames:
 if frame['phase'] in ('setup-F-corrected','setup-F-committed','setup-F-wait'):
  frame['caption'] += ' 中间空白状态；不是完成前置的证明，完成前置见setup-F-return。'
 if frame['phase']=='setup-F':
  frame['caption'] += ' 初始过长批次的旧F；不是最终核心F文档。'
p.write_text(json.dumps(frames,ensure_ascii=False,indent=2)+'\n')
