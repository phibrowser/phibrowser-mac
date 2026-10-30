"""Keep auditable native screenshot regions; do not redraw, composite or operate the browser."""
from pathlib import Path
from PIL import Image
import argparse,hashlib,json,re
p=argparse.ArgumentParser();p.add_argument('job');a=p.parse_args();root=Path.cwd();qa=root/'PHI-507';raw=root/'scratch-PHI507-r2'/a.job/'raw';index=json.loads((raw/'index.json').read_text());records=[];out=qa/'qa-evidence/r2';out.mkdir(exist_ok=True)
selected={}
for item in index:
 m=re.match(r'(\S+)\s+attempt(\d+)\s+(before|after|failure)$',item['marker'])
 if m:selected[(m[1],int(m[2]),m[3])]=item
for (unit,attempt,phase),item in selected.items():
 src=raw/item['file'];im=Image.open(src).convert('RGB');w,h=im.size
 full=phase=='failure' or unit.startswith(('VIS-','LIFE-10','LIFE-13','LIFE-14'))
 if full:box=(0,0,w,h);colors=128
 elif '-COM' in unit and '-COMMON' not in unit:box=(0,0,w,min(h,750));colors=8
 else:box=(0,0,min(w,660),min(h,1000));colors=8
 cropped=im.crop(box);cropped.thumbnail((1280,10000),Image.Resampling.LANCZOS)
 name=unit+'-a'+str(attempt)+'-'+phase+'.png';dst=out/name;cropped.quantize(colors=colors,dither=Image.Dither.NONE).save(dst,optimize=True)
 records.append({'unit_id':unit,'attempt':attempt,'phase':phase,'file':name,'source_file':item['file'],'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),'original_size':[w,h],'crop_box':list(box),'output_size':list(cropped.size),'palette_colors':colors,'caption':'Computer Use原始同屏关键区域裁切；未重绘、拼接或移动元素。' if box!=(0,0,w,h) else 'Computer Use原始完整窗口；仅缩放与调色板压缩。'})
(out/(a.job+'-evidence.json')).write_text(json.dumps(records,ensure_ascii=False,indent=2));print(len(records),'screenshots;',sum((out/x['file']).stat().st_size for x in records),'bytes')
