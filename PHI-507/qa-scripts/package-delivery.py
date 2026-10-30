# -*- coding: utf-8 -*-
"""Package committed QA artifacts and the published static report."""
from pathlib import Path
import hashlib
import subprocess
import zipfile

out = Path('deliverables')
out.mkdir(exist_ok=True)
head = subprocess.check_output(['git', '-C', 'artifacts-wt', 'rev-parse', 'HEAD'], text=True).strip()
site = Path.home() / '.cache/phi-test-reports/phi-ai-test-reports'
sitehead = subprocess.check_output(['git', '-C', str(site), 'rev-parse', 'HEAD'], text=True).strip()
readme = f'''PHI-507 独立安装包测试 r1 备份

结论：blocked；完整手册未完成，不能判通过。
原手册512项：4 pass、23 blocked、485 skipped；另有1项导航诊断 fail。
27个语言/布局项均未完成。

报告站：https://argus-phi.github.io/phi-ai-test-reports/PHI-507/r1/
产物提交：{head}
报告站提交：{sitehead}
被测 ZIP SHA-256：205e51fd09427beeb9a24d813888f780efb1f5d16d4a8c63f280e34386575470

离线阅读：打开 report-site/PHI-507/r1/index.html。
原始产物：artifacts/PHI-507/test-report-r1.md、test-plan.md、report/report.json、execution-ledger.json。
证据：artifacts/PHI-507/qa-evidence/r1/；manifest.json 列出原始证据的长度和 SHA-256。
报告站图片经过固定发布脚本转换，原始证据及哈希以 qa-evidence/r1 为准。
网络失败与无效操作尝试分别保留；文件单项通过不代表正常网页或完整验收。
未提供配套旧构建，未判定导航缺陷是否由本批修改引入。
会话已归还；未包含安装包二进制、真实账号、密钥或 Cookie。
'''
zpath = out / 'PHI-507-r1-backup.zip'
with zipfile.ZipFile(zpath, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    z.writestr('README.txt', readme)
    for base, prefix in [(Path('artifacts-wt/PHI-507'), 'artifacts/PHI-507'), (site/'PHI-507', 'report-site/PHI-507')]:
        for f in sorted(base.rglob('*')):
            if f.is_file():
                z.write(f, str(Path(prefix) / f.relative_to(base)))
with zipfile.ZipFile(zpath) as z:
    assert z.testzip() is None
    assert 'report-site/PHI-507/r1/index.html' in z.namelist()
    assert 'artifacts/PHI-507/report/report.json' in z.namelist()
sha = hashlib.sha256(zpath.read_bytes()).hexdigest()
(out/'PHI-507-r1-backup.sha256').write_text(sha+'  '+zpath.name+'\n')
print('Archive verified:', zpath.stat().st_size, 'bytes; sha256', sha)
