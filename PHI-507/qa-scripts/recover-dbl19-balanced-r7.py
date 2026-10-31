"""Retain partial CU facts with explicit reconstruction provenance."""
from pathlib import Path
import datetime, hashlib, json

qa = Path('PHI-507'); ev = qa/'qa-evidence/r7'
job = 'DBL-19-balanced-controls-r7'; raw = Path('scratch-PHI507-r7')/job/'raw'
run = json.loads((ev/(job+'-run.json')).read_text())
assert run['gui_reported_timeout'] and run['exit_code'] == 1
assert not run['computer_use_audit']['non_computer_use_calls']
assert not run['computer_use_audit']['non_computer_use_mcp_events']
log = (raw/(job+'.log')).read_text()
subs = [json.loads(line[len('OBSERVATION: '):]) for line in log.splitlines() if line.startswith('OBSERVATION: ')]
assert [s['substep'] for s in subs] == ['普通tab mute', '普通split mute', '组内split mute']
ix = json.loads((raw/'index.json').read_text()); assert len(ix) == 66
provenance = dict(reconstructed_by='Ripley', not_original_final_output=True,
 source_session=run['session_id'], reason='GUI timed out at 5400 seconds; final structured message absent.',
 source_log_sha256=hashlib.sha256((raw/(job+'.log')).read_bytes()).hexdigest(),
 source_actions_sha256=hashlib.sha256((raw/'actions.json').read_bytes()).hexdigest(),
 source_console_sha256=hashlib.sha256((raw.parent/(job+'-console.log')).read_bytes()).hexdigest())
observation = dict(unit_id='DBL-19-BAL',
 precondition_actual='Balanced/on-on实读。m1普通A/B/C分别实见编号和不同KEEP，A/B/C真实开始测试音；B/C正常配对，再通过New Tab Group建立具名m1组。关闭分支独立c1普通三页及KEEP，音频未启动；分别检查普通tab、普通split及组内split结构。另列NewTab、旧TC-P/M，不称只有ABC。',
 steps_executed=[step for s in subs for step in s['steps_executed']] + [
  '普通tab close：独立c1 A实见编号/KEEP且无播放指示；右键/Cancel后仍未见明确x/独立Close，未发送其双击。',
  '普通split close：新c1 B/C真实配对；两页显示测试音未启动，无播放指示，右键/Cancel仍无明确Close，未发送其双击。',
  '组内split close：新c1 B/C放入具名c1组；右键/Cancel仍无明确Close，未发送其双击。',
  '原运行已清理m1音频及c1组/普通页，末图66为NewTab和旧TC-P/M；未完成偏好恢复即到5400秒时限，另开CU收尾维护。'],
 before='m1 A/B/C普通页，再普通B/C split，再组内B/C split；close另建c1 A/B/C及对应三个结构。',
 after='三个mute步骤后目标/伙伴/邻页仍在，净图标为speaker-wave；三个close核心未发送。末图66无本项c1 A/B/C或组，剩NewTab与旧TC-P/M；偏好结束值尚未在原运行核实。',
 active_before='普通mute A；普通split与组内mute B；close查找分别A/B。',
 active_after='mute后原目标仍在；查close时为准备切换B/C，非关闭后的焦点结论。末图NewTab。',
 settings_observed='Balanced、System Default；双击on/位置on已实读。原运行没有结束偏好核验。',
 language_observed='English/System Default；未切语言。', layout_observed='Balanced纵向列表。',
 identity_checks=subs[-1]['identity_checks']+'；c1 A=be7fbec4-fc44-4b29-bedc-86d15823a859/KEEP-A-c1，B=23b48f89-3b05-429a-8e60-86b0907eeb93/KEEP-B-c1；C的KEEP-C-c1和编号尾段见close图，完整编号保留原图，不在本恢复记录凭尾段补写。PID71724。',
 confirmation_choices='Close按钮核心未发送，不能声称验证其确认路径。清理为本项TC对象正常原生操作，不算核心测试。',
 not_executed_reason='3个mute子步骤实际执行；3个close按钮子步骤均缺可明确命中的控件，未发送。GUI时限中断，没有最终JSON；本记录是原始CU子观察、事件及关键图的父层恢复，非操作器最终输出。',
 operator_errors=['部分输入画面切页后才更新，保留原图。','split close前图59左B暂空，图60原编号与KEEP重新可见；未执行Close，不归因为关闭结果。','90分钟到点，最终结构化消息及偏好恢复未完成。'],
 evidence_markers=['EVIDENCE: '+x['marker'] for x in ix])
out = ev/(job+'-observations.json'); assert not out.exists()
out.write_text(json.dumps(dict(base_case='DBL19BAL partial parent reconstruction', provenance=provenance,
 observations=[observation], ending_state=observation['after'], tools_outside_computer_use=[]),ensure_ascii=False,indent=2)+'\n')
run.update(original_final_output_missing=True, provenance=provenance,
 observed_units_source='Parent reconstruction of partial steps; no operator final message')
(ev/(job+'-run.json')).write_text(json.dumps(run,ensure_ascii=False,indent=2)+'\n')
meta_path=ev/(job+'-evidence.json'); meta=json.loads(meta_path.read_text())
for frame in meta:
 if frame['phase']=='split-close-before':
  frame['phase']='split-close-precondition-blank-failure'
  frame['caption']+=' 原始标记split-close-before；实际左B暂空，为准备异常，不是Close核心结果；下一图60恢复。'
meta_path.write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n')
print('Saved partial reconstruction; original final output remains explicitly absent.')
