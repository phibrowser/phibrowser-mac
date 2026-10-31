"""Record the parent's completed visual review; no browser access."""
from pathlib import Path
import datetime, hashlib, json

qa = Path('PHI-507')
ev = qa / 'qa-evidence/r6'
job = 'POS-01_POS-02-comfortable-basic-r6'
metadata = json.loads((ev / (job + '-evidence.json')).read_text())
numbers = [2,3,6,7,8,13,14,15,16,17,18,24,25,26,28,29,30,31,32,33,35,36,37]
sources = []
for number in numbers:
    item = next(x for x in metadata if x['source_file'] == f'{job}-{number:03}.jpg')
    raw = Path('scratch-PHI507-r6') / job / 'raw' / item['source_file']
    digest = hashlib.sha256(raw.read_bytes()).hexdigest()
    assert digest == item['source_sha256']
    sources.append(dict(raw_number=number, raw_file=raw.name, raw_sha256=digest,
        viewed_file=item['file'], viewed_sha256=hashlib.sha256((ev/item['file']).read_bytes()).hexdigest(),
        marker=item['original_marker']))
review = dict(reviewer='Ripley', reviewed_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    job=job, decision='pass', basis='实际查看23张关键完整窗口缩放图并核对原图SHA；101次CU、零非CU；原生观察与动作记录核对。前五张在压缩前已查看，其余18张在续跑中查看。',
    findings=[
        'Comfortable/System Default/on-on实见；屏幕顺序A/B/C/D/E/F，原生枚举反向，结论以屏幕实际顺序为准。',
        'POS01活动D右键D关闭左侧，剩余D/E/F且D活动；D/E/F逐页原编号一致。',
        'POS02独立页面活动C右键C关闭右侧，剩余A/B/C且C活动；A/B/C逐页原编号一致。',
        '前置遗漏：未在本批重新点击具名TC Space或独立确认名称；同一专属租约/PID连续继承上一项已确认的TC Space，未记录切换Default。只在独立纯TC窗口执行核心；不声称本批重新验证了Space隔离。',
        '两个专用窗口正常清理；结束Comfortable/System Default/on-on供连续队列，整轮最终恢复尚未执行。'
    ], sources=sources)
(ev/'comfortable-position-basic-review.json').write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n')
print('Saved review of', len(sources), 'actual viewed sources')
