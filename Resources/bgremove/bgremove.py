"""Convertly 정밀 배경 제거: BiRefNet(rembg). 사용: python bgremove.py <입력> <출력.png> [모델]"""
import os
import sys

os.environ.setdefault("U2NET_HOME", os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageOps  # noqa: E402
from rembg import new_session, remove  # noqa: E402

src, dst = sys.argv[1], sys.argv[2]
model = sys.argv[3] if len(sys.argv) > 3 else "birefnet-general"
img = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
out = remove(img, session=new_session(model, providers=["CPUExecutionProvider"]))
out.save(dst)
print(dst)
