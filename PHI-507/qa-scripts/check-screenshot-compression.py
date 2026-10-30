"""Measure non-generative screenshot compression while preserving visible QA content."""
from pathlib import Path
from PIL import Image
p=Path('scratch-PHI507-r2/ENV-04-COMMON/raw/ENV-04-COMMON-009.jpg');im=Image.open(p).convert('RGB');im.thumbnail((1280,1280),Image.Resampling.LANCZOS)
for colors in [128,64,32,16]:
 out=Path('scratch-PHI507-r2')/('compression-'+str(colors)+'.png');im.quantize(colors=colors,dither=Image.Dither.NONE).save(out,optimize=True);print(colors,out.stat().st_size,str(out))
