#!/usr/bin/env python3
"""Remove invalid address-space qualifiers from Metal resource parameters."""
from pathlib import Path
import os
import sys
import zipfile

path = Path(sys.argv[1])
shader = 'shaders/metal/default.shader.metal'
with zipfile.ZipFile(path) as archive:
    data = archive.read(shader)
    fixed = data.replace(b'thread const texture2d<float>', b'texture2d<float>').replace(b'thread const sampler', b'sampler')
    if fixed == data:
        if b'texture2d<float> tex' not in data or b'sampler texSmplr' not in data:
            raise SystemExit('Unexpected Metal shader template; review before patching')
        print(f'Metal resource parameters already corrected: {path}')
        raise SystemExit(0)
    temporary = path.with_name(path.name + '.metal-tmp')
    try:
        with zipfile.ZipFile(temporary, 'w') as destination:
            for entry in archive.infolist():
                destination.writestr(entry, fixed if entry.filename == shader else archive.read(entry))
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
print(f'Corrected Metal resource parameters: {path}')
