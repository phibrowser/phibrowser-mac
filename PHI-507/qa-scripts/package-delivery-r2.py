"""Create independently valid, bounded r2 QA archives; never include browser profiles or credentials."""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,io,json,subprocess,zipfile
p=argparse.ArgumentParser();p.add_argument('--max-bytes',type=int,default=3500000);p.add_argument('--round',type=int,default=2);a=p.parse_args();assert 1000000<=a.max_bytes<=3500000
artifacts=Path('artifacts-wt');qa=artifacts/'PHI-507';report=json.loads((qa/f'report-r{a.round}/report.json').read_text());assert report['round']==a.round and report['key']=='PHI-507';assert not Path('.lane/current.json').exists(),'Release UI session before final delivery'
head=subprocess.check_output(['git','-C',str(artifacts),'rev-parse','HEAD'],text=True).strip();site=Path.home()/'.cache/phi-test-reports/phi-ai-test-reports';sitehead=subprocess.check_output(['git','-C',str(site),'rev-parse','HEAD'],text=True).strip();assert (site/f'PHI-507/r{a.round}/index.html').is_file()
out=Path(f'deliverables/r{a.round}');out.mkdir(parents=True,exist_ok=True);entries=[]
for name in ['test-plan.md','execution-ledger-r2.json','handbook-snapshot-r2.md','handbook-data.json','fixture-source-r2.html','handbook-ui-source.html']+[f'test-report-r{n}.md' for n in range(2,a.round+1)]:
 f=qa/name;assert f.is_file();entries.append(('artifacts/PHI-507/'+name,f.read_bytes()))
for sub in ['test-site']+[f'qa-evidence/r{n}' for n in range(2,a.round+1)]:
 for f in sorted((qa/sub).rglob('*')):
  if f.is_file() and '__pycache__' not in f.parts:entries.append(('artifacts/PHI-507/'+str(f.relative_to(qa)),f.read_bytes()))
for n in range(2,a.round+1):
 f=qa/f'report-r{n}/report.json';assert f.is_file();entries.append((f'artifacts/PHI-507/report-r{n}/report.json',f.read_bytes()))
for f in sorted((qa/'qa-scripts').iterdir()):
 if f.is_file() and (f.name.endswith(('-r2.py','-r2.txt')) or f.name.startswith(('run-cu-','curate-cu-','record-cu-','cu-operator-','cu-observation.'))):entries.append(('artifacts/PHI-507/qa-scripts/'+f.name,f.read_bytes()))
for n in range(2,a.round+1):
 folder=site/f'PHI-507/r{n}';assert (folder/'index.html').is_file()
 for f in sorted(folder.rglob('*')):
  if f.is_file():entries.append((f'report-site/PHI-507/r{n}/'+str(f.relative_to(folder)),f.read_bytes()))
manifest={'key':'PHI-507','round':a.round,'artifact_commit':head,'report_site_commit':sitehead,'generated_at':datetime.now(timezone.utc).isoformat(),'files':[{'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for name,data in entries]}
entries.append((f'manifest-r{a.round}.json',(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode()))
counts=report['source_case_counts'];readme=f'''PHI-507 Computer Use 续测 r{a.round} 备份\n\n结论：{report['verdict']}；512项计数：{json.dumps(counts,ensure_ascii=False)}\n报告站：https://argus-phi.github.io/phi-ai-test-reports/PHI-507/r{a.round}/\n产物提交：{head}\n报告站提交：{sitehead}\n被测可执行文件SHA-256：{report['sha']}\n\n将全部 PHI-507-r{a.round}-backup-NN.zip 解压到同一目录，各ZIP均独立有效。\n离线报告：report-site/PHI-507/r{a.round}/index.html\n台账和报告：artifacts/PHI-507/execution-ledger-r2.json、test-report-r{a.round}.md、report-r{a.round}/report.json\nmanifest-r{a.round}.json记录全部文件长度和SHA-256。parts.sha256校验各ZIP。\n安装包二进制、真实账号、浏览器profile、token、Cookie不在备份中。\n无效操作/补执行与产品结果分开；r1结果不作为r2通过证据。\n'''.encode();entries.insert(0,(f'RESTORE-r{a.round}.txt',readme))
def archive(batch):
 stream=io.BytesIO()
 with zipfile.ZipFile(stream,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
  for name,data in batch:z.writestr(name,data)
 return stream.getvalue()
parts=[];batch=[];upper_bound=0
for entry in entries:
 single_size=len(archive([entry]));assert single_size<=a.max_bytes,'A single artifact exceeds attachment limit: '+entry[0]
 # Sum of singleton ZIP lengths is a conservative bound: combined ZIP has only one end record.
 if batch and upper_bound+single_size>a.max_bytes:
  parts.append(archive(batch));batch=[];upper_bound=0
 batch.append(entry);upper_bound+=single_size
if batch:parts.append(archive(batch))
assert all(len(data)<=a.max_bytes for data in parts)
checks=[];restored={}
for i,data in enumerate(parts,1):
 name=f'PHI-507-r{a.round}-backup-{i:02}.zip';dst=out/name;dst.write_bytes(data)
 with zipfile.ZipFile(io.BytesIO(data)) as z:
  assert z.testzip() is None
  for name2 in z.namelist():assert name2 not in restored;restored[name2]=z.read(name2)
 checks.append(hashlib.sha256(data).hexdigest()+'  '+name)
assert restored==dict(entries),'Archive content mismatch'
(out/'parts.sha256').write_text('\n'.join(checks)+'\n');(out/f'RESTORE-r{a.round}.txt').write_bytes(readme)
print(json.dumps({'parts':len(parts),'bytes':[len(x) for x in parts],'artifact_commit':head,'site_commit':sitehead,'verified_files':len(restored)},indent=2))
