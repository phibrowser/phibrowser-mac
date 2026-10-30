# -*- coding: utf-8 -*-
"""Save Ripley's completed screenshot review; does not operate the browser."""
import datetime
import hashlib
import json
from pathlib import Path

qa = Path('PHI-507')
job = 'DBL-09_DBL-23-comfortable-protected-complete-r5'
raw = Path('scratch-PHI507-r5') / job / 'raw'
index = json.loads((raw / 'index.json').read_text())
meta_path = qa / 'qa-evidence/r5' / (job + '-evidence.json')
meta = json.loads(meta_path.read_text())
notes = {
    'off-P-before': ('capture-failure', '采集标记偏差：实际为普通M副本空框，不作为P前置；真正P前置见off-P-live-before。'),
    'off-M-before': ('off-M-extra-single-click-before', '额外单击入口后新开的未标记M，不是最初带KEEP的20ef91e3文档。原M证据见M-live-KEEP和off-M-original-live-after。'),
    'N-input-result': ('N-input-not-visible-failure', '准备输入未即时显示KEEP，未作为有效前置；后续N-KEEP-confirmed才证实标记。'),
}
for frame in meta:
    if frame['unit_id'] == 'DBL-09-COM' and frame['phase'] in notes:
        frame['original_phase'] = frame['phase']
        frame['phase'], frame['caption'] = notes[frame['phase']]
    if frame['unit_id'] == 'DBL-23-COM' and frame['phase'] == 'control-KEEP':
        frame['caption'] = '当时右D正文空白，仅左C有KEEP，不是完整对照前置；control-KEEP-recheck才实见C/D原编号和KEEP。'
        frame['phase'] = 'control-right-blank-capture-failure'
meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2))

reviewed = {}
for name in [
    'protected-comfortable-DBL09-provisional-review.json',
    'protected-comfortable-DBL23-provisional-review.json',
    'protected-comfortable-DBL23-provisional-review3.json',
]:
    for value in json.loads((Path('scratch-PHI507-r5') / name).read_text())['viewed']:
        number = value.get('number', value.get('source_image_number'))
        digest = hashlib.sha256((raw / index[number - 1]['file']).read_bytes()).hexdigest()
        assert digest == value['sha256'], (name, number)
        reviewed[number] = digest
for number in [1, 62, 66, 84, 86, 88, 90, 108, 109, 110, 111, 112, 113, 114, 115, 116]:
    reviewed[number] = hashlib.sha256((raw / index[number - 1]['file']).read_bytes()).hexdigest()
assert len(reviewed) == 71
review = {
    'reviewer': 'Ripley',
    'job': job,
    'reviewed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'audit': {'CU_events': 342, 'non_CU_events': 0, 'raw_images': 116, 'retained_images': 116},
    'raw_images_actually_viewed': [{'number': n, 'source_sha256': digest} for n, digest in sorted(reviewed.items())],
    'decisions': {'DBL-09-COM': 'pass', 'DBL-23-COM': 'pass'},
    'basis': [
        'DBL-09四个核心动作实见P与真正bookmarkBarItem入口。P原编号/KEEP不变；off/on书签双击均打开普通副本，最初入口文档20ef91e3与N1908a29a原编号/KEEP仍在。Comfortable书签打开普通页，不宣称纵向绑定。额外单击与错标before完整保留并更正。',
        'DBL-23十二核心动作均有前后CU图和实际返回。on/off已打开PS左右双击保持A/B原编号与KEEP；Close建立关闭前置后重开为新编号与空框，只记保存结构及打开动作保留，不声称跨显式Close保留草稿。',
        'MS四次真正保存入口双击均产生一个配对及额外单独C/D条目；on/off行为一致。原实时配对与普通C/D对照的编号/KEEP另行回读保持。额外单页未修掉或隐瞒；没有旧构建，不归因新回归。',
        '初始off/on和中途on/on、off/on有实际原生返回。收尾113在水平布局中确认书签栏隐藏；114/115完整图确认Balanced、System Default、off/on；116回原报告页。新保存项及专用窗口清理，旧/未知对象保留。',
        '根实际查看71张关键原图，先前55张进度图SHA匹配完整收取的原图。全部116张CU图整理保留；未声称逐张查看其余45张准备或中间图。',
    ],
    'limits': [
        '可选pin内另页导航未做，不属必需核心动作。',
        '没有逐个核对所有新增普通副本的每个编号；已核对保护对象的原文档、普通对照及各核心新配对。',
    ],
}
(qa / 'qa-evidence/r5/comfortable-protected-review.json').write_text(json.dumps(review, ensure_ascii=False, indent=2))
lines = (raw / (job + '.log')).read_text().splitlines()
preferences = [str(i + 1) + ': ' + line for i, line in enumerate(lines) if line.startswith('\t') and any(word in line for word in ['settings.tabs.doubleClickToClose', 'settings.tabs.directionalClosing', 'Always Show Bookmark Bar'])]
(qa / 'qa-evidence/r5/comfortable-protected-preferences.log').write_text('\n'.join(preferences) + '\n')
ledger_path = qa / 'execution-ledger-r2.json'
ledger = json.loads(ledger_path.read_text())
for row in ledger:
    if row['key'] in review['decisions']:
        for record in [row, *[a for a in row['attempts'] if a.get('job') == job]]:
            for name in ['comfortable-protected-review.json', 'comfortable-protected-preferences.log', job + '-run.json']:
                path = 'qa-evidence/r5/' + name
                assert (qa / path).is_file()
                if path not in record['evidence']:
                    record['evidence'].append(path)
ledger_path.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n')
print('Saved review, corrected captions without modifying screenshots, and linked evidence.')
