"""Keep auditable native screenshot regions; do not redraw, composite or operate the browser."""
from pathlib import Path
from PIL import Image
import argparse,hashlib,json,re
p=argparse.ArgumentParser();p.add_argument('job');p.add_argument('--phases',default='before,after,failure');p.add_argument('--exact-phases',action='store_true');p.add_argument('--full',action='store_true');p.add_argument('--compact-ui',action='store_true');p.add_argument('--full-phases',default='');p.add_argument('--append',action='store_true',help='Retain all existing frames and metadata verbatim; only add previously unretained sources');a=p.parse_args();phases=set(a.phases.split(','));root=Path.cwd();qa=root/'PHI-507';round_state=qa/'active-qa-round.json';round_no=json.loads(round_state.read_text())['round'] if round_state.exists() else 2;assert isinstance(round_no,int) and round_no>=2;raw=root/f'scratch-PHI507-r{round_no}'/a.job/'raw';index=json.loads((raw/'index.json').read_text());records=[];out=qa/'qa-evidence'/f'r{round_no}';out.mkdir(exist_ok=True)
previous_path=out/(a.job+'-evidence.json');previous=json.loads(previous_path.read_text()) if previous_path.exists() else []
if a.append:records=list(previous)
old_names={(x['unit_id'],x['attempt'],x['phase']):x['file'] for x in previous}
selected={}
def keep(unit,attempt,phase,item):
 key=(unit,attempt,phase)
 if "failure" in phase:selected.setdefault(key,item)
 else:selected[key]=item
for item in index:
 marker=item['marker'];parts=marker.split(maxsplit=1)
 if len(parts)<2:continue
 unit,rest=parts;rest=re.split(r'[（(]',rest,maxsplit=1)[0].strip()
 m=re.search(r'\battempt(\d+)\s+([A-Za-z0-9_-]+)',rest)
 if m:
  surface=rest[:m.start()].strip().replace(' ','-');attempt=int(m[1]);phase=m[2]
  if surface and not surface.startswith('identity-'):phase=surface+'-'+phase
 else:
  setup=re.match(r'setup(\d+)\s+failure',rest)
  if setup:keep(unit,int(setup[1]),'setup-failure',item);continue
  phase=rest.replace(' ','-');attempt=2 if phase.startswith('sequence-') else 1
 if phase in phases or (not a.exact_phases and phase.rsplit('-',1)[-1] in phases) or 'failure' in phase:keep(unit,attempt,phase,item)
for (unit,attempt,phase),item in selected.items():
 if a.append and any(r.get('source_file')==item['file'] and r.get('original_marker')==item['marker'] for r in previous):continue
 src=raw/item['file'];im=Image.open(src).convert('RGB');w,h=im.size
 full=a.full or any(tag in phase for tag in ('settings','switch','layout','language')) or phase in set(a.full_phases.split(',')) or h<800 or 'failure' in phase or phase in ('failure','setup-failure','settings','before-switch','after-restart-switches') or unit.endswith('-COMMON') or unit.startswith(('VIS-','LIFE-10','LIFE-13','LIFE-14'))
 if full:box=(0,0,w,h);colors=128
 elif a.compact_ui:
  box=(0,0,w,min(h,round(w*0.36)));colors=64
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
  accents += [(0,122,255),(255,95,87),(255,189,46),(39,201,63),(205,174,64),(41,166,192)]
  dominant=cropped.quantize(colors=24,method=Image.Quantize.MEDIANCUT).getpalette()[:72]
  values=dominant+[v for color in accents for v in color]+[v for level in list(range(0,256,16))+[255] for v in (level,level,level)]
  values += [0]*(768-len(values));palette=Image.new('P',(1,1));palette.putpalette(values)
  cropped.quantize(palette=palette,dither=Image.Dither.NONE).save(dst,optimize=True)
 records.append({'unit_id':unit,'attempt':attempt,'phase':phase,'file':name,'original_marker':item['marker'],'source_file':item['file'],'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),'original_size':[w,h],'crop_box':list(box),'output_size':list(cropped.size),'palette_colors':None if preserve_rgb else '24 image dominant colors plus reserved black/white, grayscale and native accent colors','caption':'Computer Use原始同屏关键区域裁切；未重绘、拼接或移动元素。' if box!=(0,0,w,h) else 'Computer Use原始完整窗口；仅缩放与调色板压缩。'})
for old in previous:
 if old['file'] not in {x['file'] for x in records} and (out/old['file']).is_file():(out/old['file']).unlink()
(out/(a.job+'-evidence.json')).write_text(json.dumps(records,ensure_ascii=False,indent=2));print(len(records),'screenshots;',sum((out/x['file']).stat().st_size for x in records),'bytes')
