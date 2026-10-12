#!/usr/bin/env python3
"""Decode the user's local game logo into an ignored tvOS asset catalog."""
from pathlib import Path
import json
import struct
import sys
import zipfile
import zlib

root = Path(__file__).resolve().parent.parent
archive = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'ref/mk64.o2r'
with zipfile.ZipFile(archive) as game:
    name = 'textures/other_textures/logo_mario_kart_64'
    if game.getinfo(name).file_size != 131152:
        raise SystemExit('Unexpected original logo resource size')
    resource = game.read(name)
kind, width, height, length = struct.unpack_from('<4I', resource, 64)
if (kind, width, height, length) != (1, 256, 128, 131072) or len(resource) != 80 + length:
    raise SystemExit('Unexpected original logo resource format')
pixels = resource[80:]
out = root / 'tvos/LocalBranding.xcassets'

def metadata(path, **fields):
    path.mkdir(parents=True, exist_ok=True)
    (path / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}, **fields}, indent=2) + '\n')

def png(path, w, h, icon=False, background=False):
    # Decode directly into the destination canvas. Keep the original pixel art.
    rows = bytearray()
    scale = min(w * .86 / width, h * .80 / height) if icon else 1
    dw, dh = int(width * scale), int(height * scale)
    left, top = (w - dw) // 2, (h - dh) // 2
    for y in range(h):
        rows.append(0)
        for x in range(w):
            if not background and left <= x < left + dw and top <= y < top + dh:
                sx, sy = min(width - 1, int((x-left)/scale)), min(height-1, int((y-top)/scale))
                offset = (sy * width + sx) * 4
                r, g, b, a = pixels[offset:offset+4]
                rows.extend((r,g,b,a))
            else:
                rows.extend((15,20,33,255) if background else (0,0,0,0))
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR',struct.pack('>2I5B',w,h,8,6,0,0,0)) + chunk(b'IDAT',zlib.compress(rows)) + chunk(b'IEND',b''))

metadata(out)
logo = out / 'LocalGameLogo.imageset'
metadata(logo, images=[{'idiom':'universal','filename':'logo.png'}])
png(logo / 'logo.png', width, height)
brand = out / 'AppIcon.brandassets'
metadata(brand, assets=[{'idiom':'tv','size':'400x240','role':'primary-app-icon','filename':'AppIcon.imagestack'}, {'idiom':'tv','size':'1280x768','role':'primary-app-icon','filename':'AppIcon-AppStore.imagestack'}])
for name, w, h, scales in [('AppIcon',400,240,[1,2]), ('AppIcon-AppStore',1280,768,[1])]:
    stack = brand / (name + '.imagestack')
    metadata(stack, layers=[{'filename':'Content.imagestacklayer'}, {'filename':'Background.imagestacklayer'}])
    layer = stack / 'Content.imagestacklayer'
    metadata(layer)
    image = layer / 'Content.imageset'
    metadata(image, images=[{'idiom':'tv','filename':f'icon-{s}x.png','scale':f'{s}x'} for s in scales])
    for s in scales: png(image / f'icon-{s}x.png', w*s,h*s,True)
    background = stack / 'Background.imagestacklayer'
    metadata(background)
    image = background / 'Content.imageset'
    metadata(image, images=[{'idiom':'tv','filename':f'background-{s}x.png','scale':f'{s}x'} for s in scales])
    for s in scales: png(image / f'background-{s}x.png', w*s,h*s,True,True)
settings_path = root / 'ref/local-branding.json'
settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
settings['display_name'] = 'Mario Kart 64'
settings_path.write_text(json.dumps(settings, indent=2) + '\n')
print(f'Local-only original logo and tvOS icons: {out}')
