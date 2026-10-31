# -*- coding: utf-8 -*-
"""Record the reviewed union of actual on/off CU work, without inventing a run."""
import copy
import datetime
import hashlib
import json
from pathlib import Path

qa = Path('PHI-507')
out = qa / 'qa-evidence/r5'
on_job = 'DBL-23-DBL-23-BAL-input-retry-r5'
off_job = 'DBL-23-DBL-23-BAL-off-continuation-r5'
raw = Path('scratch-PHI507-r5') / off_job / 'raw'
index = json.loads((raw / 'index.json').read_text())
progress = json.loads(Path('scratch-PHI507-r5/balanced-off-provisional-review.json').read_text())
viewed = {}
for value in progress['viewed']:
    number = value['number']
    digest = hashlib.sha256((raw / index[number - 1]['file']).read_bytes()).hexdigest()
    assert digest == value['sha256']
    viewed[number] = digest
for number in [34, 35, 36, 37, 38, 39]:
    viewed[number] = hashlib.sha256((raw / index[number - 1]['file']).read_bytes()).hexdigest()
assert len(viewed) == 30
run = json.loads((out / (off_job + '-run.json')).read_text())
assert run['exit_code'] == 0 and run['computer_use_audit']['completed_mcp_event_count'] == 115
assert not run['computer_use_audit']['non_computer_use_calls']
assert not run['computer_use_audit']['non_computer_use_mcp_events']
on_review = json.loads((out / 'balanced-on-interruption-review.json').read_text())
assert len(on_review['completed_substeps']) == 6
on = json.loads((out / (on_job + '-observations.json')).read_text())['observations'][0]
off = json.loads((out / (off_job + '-observations.json')).read_text())['observations'][0]
assert len(off['steps_executed']) == 7
review = {
    'reviewer': 'Ripley',
    'reviewed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'unit_id': 'DBL-23-BAL',
    'decision': 'pass',
    'scope': '同一用例的两次真实执行分段合并评定：on六动作来自中断记录，off六动作及清理来自续做。没有新增或伪造一个CU运行，两次原始attempt都保持partial。',
    'sources': [on_job, off_job],
    'on_review': 'qa-evidence/r5/balanced-on-interruption-review.json',
    'off_audit': {'CU_events': 115, 'non_CU_events': 0, 'raw_images': 39, 'retained_images': 39},
    'off_raw_images_actually_viewed': [{'number': n, 'source_sha256': digest} for n, digest in sorted(viewed.items())],
    'completed_on': on_review['completed_substeps'],
    'completed_off': ['off-PS-left-open', 'off-PS-right-open', 'off-PS-left-closed', 'off-PS-right-closed', 'off-MS-closed', 'off-MS-open'],
    'basis': [
        'on/off各六动作的真实CU前后图均已复核。各已打开PS左右双击后两页原编号/KEEP保留；真正MS入口已打开双击后绑定两页原编号/KEEP保留，普通C/D对照原编号/KEEP保持。',
        'PS关闭前置由自身Close建立，真实关闭菜单无Close且出现closed项；重新打开均为新编号/空框，只记保存结构和打开动作保留。MS用File Close Tab先后关闭两侧，保存行和普通对照保留，再执行未打开分支。',
        'off续做以新CU现场读取确认同一run、已有保存项、普通对照，再操作；没有用中断前假设代替现场，也没有重跑或丢弃已有效on六动作。',
        '两次CU坐标输入返回noWindowsAvailable时窗口随后仍可读取，失败返回和图留档；用原生菜单与键盘定位输入后才实际执行核心动作，不将其记作产品崩溃。',
        'off末34/35清理本run的PS/MS，36关闭纯TC窗口，37/38完整图确认off/on、Balanced/System Default，39原报告页；旧/未知对象保留。',
        'on根实际查看30张关键原图；off根实际查看30张关键原图，其中24张进度图SHA与规范原图一致。on全部38张、off全部39张均保留；未声称逐张查看其余准备图。',
    ],
    'transcription_correction': '进度便笺对off3重开B编号的手工转录有笔误，完整规范观察与原图为c5fba7e4-38aa-4346-96a0-c22e963762e6；不据进度便笺定位或判定对象。',
    'product_bugs_confirmed': [],
}
assert len(review['completed_on'] + review['completed_off']) == 12
review_path = out / 'balanced-protected-combined-review.json'
review_path.write_text(json.dumps(review, ensure_ascii=False, indent=2))
ledger_path = qa / 'execution-ledger-r2.json'
rows = json.loads(ledger_path.read_text())
row = next(r for r in rows if r['key'] == 'DBL-23-BAL')
sources = [a for a in row['attempts'] if a.get('job') in (on_job, off_job)]
assert len(sources) == 2 and all(a['outcome'] == 'partial' for a in sources)
combined = copy.deepcopy(off)
combined.update(
    before=on['before'],
    active_before=on['active_before'],
    after='分段累计完成on六动作和off六动作；全部指定双击已执行，保存结构、对应实时文档及普通对照核对符合预期。' + off['after'],
    settings_observed='on段实读on/on；off段实读off/on；结束off/on。',
    steps_executed=on['steps_executed'] + off['steps_executed'],
    identity_checks=on['identity_checks'] + '\n续做off：' + off['identity_checks'],
    operator_errors=on['operator_errors'] + off['operator_errors'],
    not_executed_reason='',
    assessment_sources=[on_job, off_job],
    reconstructed_by='Ripley combined assessment; original execution records retained',
)
row.update(result='pass', actual=combined['after'], observation=combined, completion_basis=[on_job, off_job], notes='Ripley以两段真实CU执行合并评定，on/off各六动作全部核对；两段原始attempt均保持partial，中断和无效输入保留。详见balanced-protected-combined-review.json。')
row.pop('not_run_reason', None)
for record in [row, *sources]:
    for name in ['balanced-protected-combined-review.json', off_job + '-run.json']:
        path = 'qa-evidence/r5/' + name
        assert (qa / path).is_file()
        if path not in record['evidence']:
            record['evidence'].append(path)
for source in sources:
    for path in source['evidence']:
        if path not in row['evidence']:
            row['evidence'].append(path)
ledger_path.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
print('Recorded DBL-23-BAL pass from 6 actual on + 6 actual off actions; original partial attempts retained.')
