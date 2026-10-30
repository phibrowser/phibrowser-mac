"""Keep relevant native screenshots, diagnostic logs and responses for the QA report."""
from pathlib import Path
import shutil,subprocess
root=Path('PHI-507');src=root/'qa-evidence/r1';raw=Path('scratch-raw-PHI507-r1')
if not raw.exists():src.rename(raw)
src.mkdir(parents=True,exist_ok=True)
for p in raw.iterdir():
 if p.suffix in ('.json','.log','.txt'):shutil.copy2(p,src/p.name)
images={
 'ENV-01-COMMON-01.png':'ENV-01-COMMON-03.jpg',
 'ENV-01-COMMON-02.png':'ENV-01-COMMON-04.jpg',
 'ENV-02-COMMON-01.png':'ENV-02-COMMON-05.png',
 'ENV-02-COMMON-02.png':'ENV-02-COMMON-09.png',
 'ENV-03-COMMON-attempt1-01.png':'ENV-03-COMMON-attempt1-04.jpg',
 'ENV-03-COMMON-attempt1-02.png':'ENV-03-COMMON-attempt1-05.jpg',
 'ENV-03-COMMON-attempt2-01.png':'ENV-03-COMMON-attempt2-07.jpg',
 'ENV-03-COMMON-attempt2-02.png':'ENV-03-COMMON-attempt2-08.jpg',
 'ENV-03-COMMON-attempt3-01.png':'ENV-03-COMMON-attempt3-02.jpg',
 'ENV-03-COMMON-attempt3-02.png':'ENV-03-COMMON-attempt3-03.jpg',
 'ENV-03-COMMON-file-01.png':'ENV-03-COMMON-file-sequence-01.jpg',
 'ENV-03-COMMON-file-02.png':'ENV-03-COMMON-file-sequence-21.jpg',
 'ENV-04-COMMON-01.png':'ENV-03-COMMON-file-sequence-01.jpg',
 'ENV-04-COMMON-02.png':'ENV-03-COMMON-file-sequence-21.jpg',
 'POS-03-BAL-attempt1-01.png':'POS-03-BAL-attempt1-02.jpg',
 'POS-03-BAL-attempt1-02.png':'POS-03-BAL-attempt1-03.jpg',
 'POS-03-BAL-attempt2-01.png':'POS-03-BAL-attempt2-01.jpg',
 'POS-03-BAL-attempt2-02.png':'POS-03-BAL-attempt2-12.jpg',
 'POS-03-BAL-attempt3-01.png':'POS-03-BAL-attempt3-01.jpg',
 'POS-03-BAL-attempt3-02.png':'POS-03-BAL-attempt3-04.jpg',
 'POS-03-BAL-attempt3-03.png':'POS-03-BAL-attempt3-06.jpg',
 'CONTROL-HTTP-01.png':'CONTROL-HTTP-01.png',
 'CLEANUP-01.png':'CLEANUP-01.jpg',
 'CLEANUP-02.png':'CLEANUP-04.jpg',
}
for dst,original in images.items():
 assert (raw/original).is_file(),original
 subprocess.run(['sips','-s','format','png','-Z','1280',str(raw/original),'--out',str(src/dst)],check=True,stdout=subprocess.DEVNULL)
size=sum(p.stat().st_size for p in src.rglob('*') if p.is_file());assert size<20*1024*1024,size
print(len(images),'screenshots;',size,'evidence bytes')
