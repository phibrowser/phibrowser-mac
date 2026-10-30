"""Keep auditable native screenshot regions; do not redraw, composite or operate the browser."""
from pathlib import Path
from PIL import Image
import argparse,hashlib,json,re
p=argparse.ArgumentParser();p.add_argument('job');p.add_argument('--phases',default='before,after,failure');a=p.parse_args();phases=set(a.phases.split(','));root=Path.cwd();qa=root/'PHI-507';raw=root/'scratch-PHI507-r2'/a.job/'raw';index=json.loads((raw/'index.json').read_text());records=[];out=qa/'qa-evidence/r2';out.mkdir(exist_ok=True)
previous_path=out/(a.job+'-evidence.json');previous=json.loads(previous_path.read_text()) if previous_path.exists() else []
old_names={(x['unit_id'],x['attempt'],x['phase']):x['file'] for x in previous}
selected={}
for item in index:
 m=re.match(r'(\S+)\s+(?:identity-\S+\s+)?attempt(\d+)\s+([A-Za-z0-9_-]+)',item['marker'])
 if m and m[3] in phases:selected[(m[1],int(m[2]),m[3])]=item
 mplain=re.match(r'(\S+)\s+([A-Za-z0-9_-]+)(?:$|[（(])',item['marker'])
 if mplain and mplain[2] in phases:selected[(mplain[1],1,mplain[2])]=item
 mseq=re.match(r'(\S+)\s+sequence\s+(before|after)',item['marker'])
 if mseq and 'sequence-'+mseq[2] in phases:selected[(mseq[1],2,'sequence-'+mseq[2])]=item
 msetup=re.match(r'(\S+)\s+setup(\d+)\s+failure$',item['marker'])
 if msetup:selected[(msetup[1],int(msetup[2]),'setup-failure')]=item
for (unit,attempt,phase),item in selected.items():
 src=raw/item['file'];im=Image.open(src).convert('RGB');w,h=im.size
 full=phase in ('failure','setup-failure','settings','before-switch','after-restart-switches') or unit.endswith('-COMMON') or unit.startswith(('VIS-','LIFE-10','LIFE-13','LIFE-14'))
 if full:box=(0,0,w,h);colors=128
 elif '-COM' in unit and '-COMMON' not in unit:box=(0,0,w,min(h,750));colors=8
 else:box=(0,0,min(w,660),h);colors=8
 cropped=im.crop(box);cropped.thumbnail((1280,10000),Image.Resampling.LANCZOS)
 name=old_names.get((unit,attempt,phase),'')
 if not re.fullmatch(re.escape(unit)+r'-\d+\.png',name):
  numbers=[int(m[1]) for f in out.glob(unit+'-*.png') if (m:=re.fullmatch(re.escape(unit)+r'-(\d+)\.png',f.name))]
  name=unit+'-'+str(max(numbers,default=0)+1).zfill(2)+'.png'
 dst=out/name;
 preserve_rgb="failure" in phase or unit.startswith(("VIS-03","VIS-06"))
 if preserve_rgb:cropped.save(dst,optimize=True)
 else:
  accents=[(247,226,167),(220,180,60),(160,126,33),(238,216,255),(190,160,245),(110,75,185),(215,235,255),(90,160,230),(30,80,160),(225,245,225),(50,150,70),(20,95,50),(255,220,220),(220,50,40),(170,30,30),(255,228,245),(220,80,150),(155,35,100),(255,235,210),(230,135,45),(175,95,20),(215,245,250),(40,155,175),(20,100,115)]
  values=[v for color in accents for v in color]+[v for level in list(range(0,256,16))+[255] for v in (level,level,level)]
  values += [0]*(768-len(values));palette=Image.new('P',(1,1));palette.putpalette(values)
  cropped.quantize(palette=palette,dither=Image.Dither.NONE).save(dst,optimize=True)
 records.append({'unit_id':unit,'attempt':attempt,'phase':phase,'file':name,'source_file':item['file'],'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),'original_size':[w,h],'crop_box':list(box),'output_size':list(cropped.size),'palette_colors':None if preserve_rgb else 'fixed grayscale and basic accent palette; no adaptive removal of black/white','caption':'Computer Use原始同屏关键区域裁切；未重绘、拼接或移动元素。' if box!=(0,0,w,h) else 'Computer Use原始完整窗口；仅缩放与调色板压缩。'})
for old in previous:
 if old['file'] not in {x['file'] for x in records} and (out/old['file']).is_file():(out/old['file']).unlink()
(out/(a.job+'-evidence.json')).write_text(json.dumps(records,ensure_ascii=False,indent=2));print(len(records),'screenshots;',sum((out/x['file']).stat().st_size for x in records),'bytes')
