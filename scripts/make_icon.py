"""static/icon.svg → 맥 앱 아이콘(.icns)

    .venv/bin/python scripts/make_icon.py build/AppIcon.icns

맥 아이콘 규격에 맞춰 1024px 캔버스 안 824px 크기로 가운데에 그린다.
"""
import os
import subprocess
import sys
import tempfile

from AppKit import (NSBitmapImageRep, NSCompositingOperationSourceOver, NSGraphicsContext, NSImage,
                    NSMakeRect, NSPNGFileType)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZES = [16, 32, 128, 256, 512]


def render(svg, px, path):
    rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, px, px, 8, 4, True, False, 'NSDeviceRGBColorSpace', 0, 0)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.setCurrentContext_(NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))
    inset = px * 100 / 1024.0
    svg.drawInRect_fromRect_operation_fraction_(
        NSMakeRect(inset, inset, px - 2 * inset, px - 2 * inset), NSMakeRect(0, 0, 0, 0),
        NSCompositingOperationSourceOver, 1.0)
    NSGraphicsContext.restoreGraphicsState()
    with open(path, 'wb') as f:
        f.write(bytes(rep.representationUsingType_properties_(NSPNGFileType, {})))


def main(out):
    svg = NSImage.alloc().initWithContentsOfFile_(os.path.join(ROOT, 'static', 'icon.svg'))
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, 'AppIcon.iconset')
        os.makedirs(iconset)
        for s in SIZES:
            render(svg, s, os.path.join(iconset, 'icon_%dx%d.png' % (s, s)))
            render(svg, s * 2, os.path.join(iconset, 'icon_%dx%d@2x.png' % (s, s)))
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', out], check=True)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 'AppIcon.icns'))
