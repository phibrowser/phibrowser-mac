"""Preserve verified partial observations from an interrupted CU session.

This is a parent reconstruction from saved CU events and images, explicitly
distinct from the final structured message that the operator never produced.
"""
from pathlib import Path
import datetime, hashlib, json

qa = Path('PHI-507'); ev = qa/'qa-evidence/r6'
job = 'DBL-19-performance-controls-r6'
raw = Path('scratch-PHI507-r6')/job/'raw'
log = (raw/(job+'.log')).read_text()
console = Path('scratch-PHI507-r6')/job/(job+'-console.log')
assert 'lane-runner: timeout after 5400.0s, killed' in console.read_text()
assert '未发送关闭按钮双击' in log
audit = json.loads((raw/'audit.json').read_text())
assert audit['mcp_event_count'] == 210
assert not audit['non_computer_use_calls'] and not audit['non_computer_use_mcp_events']
ix = json.loads((raw/'index.json').read_text()); assert len(ix)==57
progress = json.loads((ev/'dbl19-performance-progress-review.json').read_text())
sources=[]
for old in progress['viewed_original_progress_frames']:
    item=ix[old['raw_number']-1]
    digest=hashlib.sha256((raw/item['file']).read_bytes()).hexdigest()
    assert digest==old['sha256'] and item['marker']==old['marker']
    sources.append({**old,'canonical_file':item['file'],'canonical_sha256':digest})
for n in [2,3,51,52,54,55,57]:
    item=ix[n-1]
    sources.append({'raw_number':n,'canonical_file':item['file'],
        'canonical_sha256':hashlib.sha256((raw/item['file']).read_bytes()).hexdigest(),
        'marker':item['marker'],'viewed_as':'canonical original'})
review={'reviewer':'Ripley','reviewed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'job':job,'decision':'partial','basis':'实际查看17张关键原图；10张进度原图均SHA匹配正式原图；210CU/零非CU。',
    'sources':sources,'findings':[
      '普通tab、普通split、组内split的静音图标各实际双击一次；各自目标、伙伴/邻页、原编号和KEEP未见新增关闭。净图标仍wave，不声称看见中间切换。',
      'close分支重建为新c1文档；三个结构都未显示明确Close控件，未发送其核心双击。查找结束的after不代表关闭动作已完成。',
      '两次有限drag未产生可用悬停；普通split尝试选中了页面文字，原图保留，不算产品关闭动作。',
      '最后Settings定位失败：Missing required argument: x，图仍是c1浏览器窗口；90分钟到点中断，未生成最终JSON，偏好/窗口收尾未在该运行完成。另有独立cleanup运行。']}
(ev/'dbl19-performance-interrupted-review.json').write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n')
observation={
 'unit_id':'DBL-19-PER',
 'precondition_actual':'CU经独立TC窗口准备m1普通A/B/C，输入并核对各自KEEP与原编号；正常原生配对B/C，再放入本项组。close分支另建c1三页，实际开始/停止测试音后查找关闭控件。当前窗口还包含NewTab及旧TC保存项，不描述为仅ABC。',
 'steps_executed':[
  '普通tab mute：A实际播放，坐标x=100,y=588发送click_count=2；A/B/C仍列出，A原编号/KEEP保留。',
  '普通split mute：B/C均播放，B图标x=84,y=660发送click_count=2；原配对、两页编号/KEEP保留。',
  '组内split mute：本项组内B的speaker-wave按钮索引37发送click_count=2；两页仍配对，原编号/KEEP保留。',
  '普通tab close：新c1 A停止音频后未见明确x或对应Close控件；有限定位尝试仍不可用，未发送按钮双击。',
  '普通split close：新c1 B/C已配对且停止音频；有限drag选中网页说明文字而非有效悬停；未发送按钮双击。',
  '组内split close：新c1 B/C放入本项组，原图/树仍无明确Close控件；未发送按钮双击。',
  '收尾尝试未完成：Settings定位报Missing required argument: x，最终仍为浏览器c1窗口；GUI在5400秒时限终止。'],
 'before':'m1普通A/B/C及独立编号/KEEP；普通及组内split真实B/C配对。close分支独立c1普通A/B/C，再配B/C及入本项组。NewTab和旧TC保存项也列出。',
 'after':'静音三分支后目标均存活；close查找结束仍为c1 A及组内B/C split，未执行三个关闭核心动作。最后图57仍为c1 A正文，无Settings；该运行未完成窗口/偏好清理。',
 'active_before':'普通mute A；split mute B半格；组内mute目标B图标。',
 'active_after':'三个mute动作后文档/配对保留；close查找中正常激活C半格，最终切回A。不要把这些准备激活写成关闭导致的焦点变化。',
 'settings_observed':'原始Balanced/System Default，双击off/位置on；经CU设Performance、双击on/位置on。原运行最终恢复未完成。',
 'language_observed':'英文原生界面，General为System Default；未切语言。',
 'layout_observed':'Performance实见选中及纵向chrome；未完成原运行结束恢复。',
 'identity_checks':'m1 A=39bee8cc-b7a0-49a9-a72d-e1477db0a8aa/KEEP-A-m1；B=ff56bcee-c383-457e-8988-4f91d45616d8/KEEP-B-m1；C=6ea6d17d-e3e8-40d0-b6e5-a252fdcfbbfd/KEEP-C-m1。c1 A=099181e3-6699-44ff-9230-a6070f922345/KEEP-A-c1；B=8939dea5-9b24-45a0-ac89-4f3772e13383/KEEP-B-c1；C=505c34d9-5634-4e9d-bf39-79a5c3416a4c/KEEP-C-c1。固定app/PID47109，前后原图已核对。',
 'confirmation_choices':'本次已查看核心/控件查找图未见关闭确认；未发送Close控件动作，不宣称验证其确认路径。',
 'not_executed_reason':'3个mute子步骤已执行；普通tab close、普通split close、组内split close均缺可明确命中的原生Close控件，核心双击未发送。原运行收尾又遇定位错误和5400秒时限，最终结构化输出缺失；本记录为父层据CU原图/事件恢复。',
 'operator_errors':['网页播放/输入部分画面经切页回看才更新，保留更新前后准备图。','两次有限drag没有有效定位，split尝试还选中文字；不作为hover或关闭测试。','收尾设置定位调用缺少x参数，原图57保留；未完成收尾即到GUI时限。'],
 'evidence_markers':['EVIDENCE: '+x['marker'] for x in ix]
}
provenance={'reconstructed_by':'Ripley','not_original_final_output':True,
 'source_session':'01a19129-7dab-7411-a1e3-fe3ca3c11275','source_log_sha256':hashlib.sha256((raw/(job+'.log')).read_bytes()).hexdigest(),
 'source_actions_sha256':hashlib.sha256((raw/'actions.json').read_bytes()).hexdigest(),
 'source_console_sha256':hashlib.sha256(console.read_bytes()).hexdigest(),
 'reason':'GUI timeout; final structured file absent. Only actual saved CU steps and reviewed images reconstructed.'}
(ev/(job+'-observations.json')).write_text(json.dumps({'base_case':'DBL19PER中断运行的父层恢复记录，非操作器最终JSON','provenance':provenance,
 'ending_state':observation['after'],'observations':[observation],'tools_outside_computer_use':[]},ensure_ascii=False,indent=2)+'\n')
run={'job':job,'exit_code':1,'gui_exit_code':0,'gui_reported_timeout':True,
 'session_id':provenance['source_session'],'round':6,'lease_id':'8c1d8779-4eeb-4400-a591-7ecd2585843f',
 'started_at':'2026-10-31T08:52:57.365413+00:00','timeout_seconds':5400,
 'recovered_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'units':['DBL-19-PER'],'observed_units':['DBL-19-PER'],'observed_units_source':'parent reconstruction of partial steps; no original final output',
 'original_final_output_missing':True,'provenance':provenance,
 'collection_errors':[{'step':'original_final_observations_pull','exit_code':23,'reason':'No final file after GUI timeout; raw evidence subsequently pulled separately'}],
 'computer_use_audit':{'source_sha256':hashlib.sha256((raw/'audit.json').read_bytes()).hexdigest(),
 'scope':audit['audit_scope'],'completed_mcp_event_count':audit['mcp_event_count'],
 'non_computer_use_calls':[],'non_computer_use_mcp_events':[],'extraction_warnings':audit['extraction_warnings']}}
(ev/(job+'-run.json')).write_text(json.dumps(run,ensure_ascii=False,indent=2)+'\n')
lines=log.splitlines(); selected=[]
for i,line in enumerate(lines):
 if line.startswith('REQUEST:') or '未发送关闭按钮双击' in line or 'Missing required argument: x' in line:
  selected.extend(lines[max(0,i-2):min(len(lines),i+4)])
selected+=['GUI console tail (original):']+console.read_text().splitlines()[-8:]
(ev/'dbl19-performance-interruption-errors.log').write_text('\n'.join(selected)+'\n')
print('Recovered explicit partial facts; no original final message or completion invented')
