"""Retain key native CU frames from the initial jobs that predate EVIDENCE markers."""
from pathlib import Path
import json,hashlib,shutil
from PIL import Image
qa=Path('PHI-507');out=qa/'qa-evidence/r2';scratch=Path('scratch-PHI507-r2');archive=scratch/'initial-raw';archive.mkdir(exist_ok=True)
for f in out.glob('*.jpg'):shutil.move(str(f),str(archive/f.name))
items=[('ENV-01-COMMON',scratch/'ENV-01-COMMON/raw/ENV-01-COMMON-011.jpg','about'),('ENV-01-COMMON',scratch/'ENV-01-COMMON/raw/ENV-01-COMMON-015.jpg','advanced'),('ENV-02-COMMON',archive/'ENV-02-COMMON-04.jpg','shortcuts-partial'),('ENV-02-COMMON',archive/'ENV-02-COMMON-11.jpg','empty-test-space'),('ENV-03-COMMON',archive/'ENV-03-COMMON-12.jpg','initial-F'),('ENV-04-COMMON',scratch/'ENV-04-COMMON/raw/ENV-04-COMMON-002.jpg','B-before'),('ENV-04-COMMON',scratch/'ENV-04-COMMON/raw/ENV-04-COMMON-009.jpg','B-after'),('SET-01-COMMON',scratch/'SET-01-COMMON/raw/SET-01-COMMON-004.jpg','advanced-before'),('SET-01-COMMON',scratch/'SET-01-COMMON/raw/SET-01-COMMON-008.jpg','advanced-after-drag')]
records=[]
for unit,src,phase in items:
 name=unit+'-initial-'+phase+'.png';im=Image.open(src).convert('RGB');original=im.size;im.thumbnail((1280,10000),Image.Resampling.LANCZOS);im.save(out/name,optimize=True)
 records.append({'unit_id':unit,'file':name,'phase':phase,'source_file':str(src),'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),'original_size':original,'output_size':im.size,'caption':'初始Computer Use原始完整窗口，仅缩放；此批早于EVIDENCE marker规范'})
(out/'initial-evidence.json').write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n')
for job in ['ENV-04-COMMON','SET-01-COMMON']:
 shutil.copy2(scratch/job/'raw'/(job+'.log'),out/(job+'.log'))
ledger=qa/'execution-ledger-r2.json';rows=json.loads(ledger.read_text())
for r in rows:
 matching=[x for x in records if x['unit_id']==r['key']]
 if not matching:continue
 r['evidence']=['qa-evidence/r2/'+x['file'] for x in matching]+['qa-evidence/r2/'+r['key']+'.log']
 if r['id']=='ENV-01':r['evidence']+=['qa-evidence/r2/installed-identity.json','qa-evidence/r2/signature-verification.log']
ledger.write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
print('curated initial',len(records),'frames; raw originals archived outside deliverable')
