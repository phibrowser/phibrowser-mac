"""Persist reviewed real evidence and distinguish invalid preparation from completed cores."""
from pathlib import Path
import datetime, hashlib, json

qa=Path('PHI-507');ev=qa/'qa-evidence/r6';job='POS-04_POS-05-balanced-basic-r6'
raw=Path('scratch-PHI507-r6')/job/'raw'
index=json.loads((raw/'index.json').read_text())
provisional=json.loads((ev/'position-basic-provisional-review.json').read_text())
sources=[]
for old in provisional['sources']:
    item=index[old['number']-1]
    h=hashlib.sha256((raw/item['file']).read_bytes()).hexdigest()
    assert h==old['sha256'] and item['marker']==old['marker']
    sources.append({**old,'file':item['file'],'canonical_sha_match':True})
for n in [30,31,32,34,35,36,37,38]:
    item=index[n-1]
    sources.append({'number':n,'file':item['file'],'marker':item['marker'],
                    'sha256':hashlib.sha256((raw/item['file']).read_bytes()).hexdigest()})
review={'reviewer':'Ripley','reviewed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'job':job,'decisions':{'POS-04-BAL':'pass','POS-05-BAL':'pass'},
        'basis':'实际查看17张关键原图；前9张中途原图与正式收回原图逐一SHA相同。原始观察与134个CU事件审计、零非CU调用同时核对。',
        'findings':['POS04：F活动直接右键C，Below后仅A/B/C，活动C；A/B/C原编号与前置一致，正文可见。',
                    'POS05：A前方、C后方及唯一A的两方向均存在且禁用；唯一A的Close Other Tabs也禁用。',
                    '收尾只将doubleClick on→off，directional保持on；General为Balanced/SystemDefault；专用窗口清理后回旧NewTab。',
                    '首次过长run截断、之后既有LAUNCH导航空白、一次正常重开、过期菜单索引与s2编排ReferenceError均分别保留，不认定产品缺陷或正常核心。'],
        'sources':sources}
(ev/'position-basic-balanced-review.json').write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n')
p=ev/(job+'-evidence.json');frames=json.loads(p.read_text())
for f in frames:
    if f['unit_id']=='POS-04-BAL' and f['attempt']==1:
        if f['phase']=='identity-F':
            f['phase']='setup-run-length-failure'
            f['caption']+=' 初始过长run被原始fixture按48字符截断，非最终核心前置；夹具约定，不是产品关闭缺陷。'
        elif f['phase'] in ('launch-corrected','launch-ready','launch-wait','reload-result'):
            f['phase']+='-loading-failure'
            f['caption']+=' 缩短run重新导航后正文空白；不是有效前置或存活证明，正常重开后另以attempt2独立构造。'
p.write_text(json.dumps(frames,ensure_ascii=False,indent=2)+'\n')
finding={'issue':'PHI-507','id':'F6-01','classification':'investigation','status':'open',
         'title':'既有LAUNCH页缩短run后重新导航，标题更新但正文持续空白；正常重开后新窗口可建立前置',
         'repro':['Balanced/on-on，File→New Window直接打开LAUNCH，先实见入口及首个F正文。',
                 '为修正过长run关闭F，并在LAUNCH的地址栏导航短run；标题更新，正文空白。',
                 '分段实读163.783秒仍空白；一次Reload后187.663秒再读仍空白。'],
         'comparisons':['一次正常Quit后PID44628→47109；新建独立窗口直接打开短run LAUNCH及六页，均实见正文和编号，POS04核心随后执行。'],
         'limits':['没有旧构建基线；尚未区分产品渲染和Computer Use交互条件，不作为已确认产品缺陷或修复结论。',
                   '首次长run截断来自原始fixture的48字符约定；后续准备从一开始使用短run，避免无必要的导航纠正。',
                   '本记录不替代POS04有效attempt2或POS05结果；原始空白现场单独保留。'],
         'evidence':['qa-evidence/r6/'+job+'-observations.json','qa-evidence/r6/'+job+'-run.json','qa-evidence/r6/'+job+'-evidence.json','qa-evidence/r6/position-basic-balanced-review.json']}
(ev/'navigation-path-finding.json').write_text(json.dumps(finding,ensure_ascii=False,indent=2)+'\n')
