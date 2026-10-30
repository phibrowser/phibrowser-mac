# -*- coding: utf-8 -*-
"""Preserve reviewed CU observations after the operator's HTTP 502 interruption."""
import datetime
import hashlib
import json
from pathlib import Path

qa = Path('PHI-507')
job = 'DBL-23-DBL-23-BAL-input-retry-r5'
raw = Path('scratch-PHI507-r5') / job / 'raw'
out = qa / 'qa-evidence/r5'
index = json.loads((raw / 'index.json').read_text())
provisional = json.loads(Path('scratch-PHI507-r5/balanced-input-provisional-review.json').read_text())
for value in provisional['viewed']:
    assert hashlib.sha256((raw / index[value['number'] - 1]['file']).read_bytes()).hexdigest() == value['sha256']
viewed = sorted({v['number'] for v in provisional['viewed']} | set(range(18, 39)))
assert len(viewed) == 30
review = {
    'reviewer': 'Ripley',
    'job': job,
    'decision': 'partial',
    'scope': '操作器没有返回最终结构化JSON；此记录由Ripley依据已取回的真实CU原图、原生返回和动作日志重建，不伪称操作器完成整例。',
    'audit': {'CU_events': 109, 'non_CU_events': 0, 'raw_images': 38, 'retained_images': 38},
    'viewed_raw_images': [{'number': n, 'source_sha256': hashlib.sha256((raw / index[n - 1]['file']).read_bytes()).hexdigest()} for n in viewed],
    'completed_substeps': ['on-PS-left-open', 'on-PS-right-open', 'on-PS-left-closed', 'on-PS-right-closed', 'on-MS-closed', 'on-MS-open'],
    'remaining_substeps': ['off-PS-left-open', 'off-PS-right-open', 'off-PS-left-closed', 'off-PS-right-closed', 'off-MS-closed', 'off-MS-open', 'cleanup-and-restore'],
    'basis': [
        'on已打开PS两次双击后A/B原编号和KEEP仍实见；普通C/D对照原编号及KEEP实见。',
        '两次PS自身Close后保留保存块，再双击左右分别重开为新编号及空框；真实关闭菜单包含unpinClosedPinnedSplit/convertClosedPinnedSplitLayout且无Close。',
        '真正MS保存入口首次双击打开独立绑定C/D，输入专属KEEP后再次双击，绑定编号及KEEP仍实见；原普通对照另行回读保持。',
        '之后Command-comma实际打开Guest设置页，辅助函数在该页查开关报toggle missing；尚未点击off。随后嵌套模型服务5次重连后HTTP502退出，属于执行环境中断及操作定位错误，不是产品缺陷。',
        '未执行off六动作或本批清理恢复；当前状态仅记录最后CU返回，不假设仍在前台。',
    ],
}
(out / 'balanced-on-interruption-review.json').write_text(json.dumps(review, ensure_ascii=False, indent=2))
lines = (raw / (job + '.log')).read_text().splitlines()
(out / 'balanced-on-interruption.log').write_text('\n'.join(lines[-59:]) + '\n\nRunner exit1 after five reconnects: HTTP 502 Bad Gateway from model service; no final observation JSON.\n')
observation = {
    'unit_id': 'DBL-23-BAL',
    'precondition_actual': '本次唯一run TC-PHI507-r5-DBL-23-BAL-input-retry-r5-179339941；四个普通文档先标记，原生构造PS A/B固定split、MS C/D保存项、独立普通C/D对照；截图确认Balanced。',
    'before': 'PS A/B；MS C/D保存项未打开；普通C/D配对对照；旧P/M和未知项目保留。',
    'after': 'on六动作完成后PS保存块在且最后一次重开A/B为空输入；真正MS绑定C/D原编号和KEEP保留；普通C/D原编号和KEEP保留。随后设置Guest页打开，尚未执行off或清理。',
    'active_before': '核心开始PS A/B；各子动作活动页见真实前后图。',
    'active_after': '最后有截图的状态为普通C/D对照C活动；之后最后CU文字返回为Guest设置页，PID10708。',
    'settings_observed': 'General Balanced/System Default；Advanced on/on；没有实读到off切换完成。',
    'layout_observed': 'Balanced；纵向外部列表及真实General截图。',
    'language_observed': 'System Default；英文原生界面。',
    'steps_executed': review['completed_substeps'],
    'identity_checks': 'PS初始A224e5b25-2762-46b8-9f37-1ee62ae8e768、B5d6c8c6e-e94a-4d55-8c0a-9440215f9268，KEEP-A/B-DBL23-input-retry-r5；on左重开A5311fc98-adfb-4413-b789-f89d52c9fb9e、Ba67a4f12-2ed8-4b96-a10c-8b7407106021；on右重开A5377e1d9-01e6-4401-9381-2ed25921c62e、Bc5fa7815-adc0-45dc-af60-10fa49256885。普通C5dc551bd-a178-4694-91af-7170f4f2729d、Db1e0adaa-8f39-4c02-88bb-ea631821b84d及KEEP不变。真正MS C5eec3dcc-b71f-4c6a-89ae-06b1359718ab、D340603ef-e105-4ef9-a101-fc3e22a12df1，KEEP-MS-C/D-on-input-retry-r5，双击前后保持。',
    'confirmation_choices': 'PS Close和保存入口双击未出现确认；菜单通过明确Cancel退出。',
    'operator_errors': ['D初次输入图仍占位，切页回看才实见完整KEEP，未重复输入。', '设置Guest页未点Advanced即用helper查toggle，返回toggle missing。', '随后模型服务HTTP502中断，最终JSON没有生成；本观察由Ripley重建且仅涵盖实际证据。'],
    'not_executed_reason': 'off六个核心动作及清理恢复未执行，原因是嵌套模型服务HTTP502中断；后续独立续做，保留本次部分结果。',
    'evidence_markers': [r['marker'] for r in index],
}
(out / (job + '-observations.json')).write_text(json.dumps({'base_case': 'Ripley reconstructed interrupted on-only observations', 'observations': [observation], 'ending_state': 'Last CU return: fixed QA PID10708, Guest Settings open; off not executed, cleanup not done. Must reread current UI.', 'tools_outside_computer_use': [], 'reconstructed_by': 'Ripley', 'source': job + '-run.json'}, ensure_ascii=False, indent=2))
meta_path = out / (job + '-evidence.json')
meta = json.loads(meta_path.read_text())
for frame in meta:
    if frame['phase'] == 'D-input':
        frame['phase'] = 'D-input-not-visible-failure'
        frame['caption'] = '首次输入后未显示KEEP，非有效输入前置；随后D-input-recheck才实见相同编号及完整标记。'
meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2))
print('Preserved interrupted on-only observations and explicit remaining work.')
