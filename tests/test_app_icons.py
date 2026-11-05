import json
from pathlib import Path
import struct
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ANDROID = '{http://schemas.android.com/apk/res/android}'


def png_header(path):
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'不是 PNG：{path}')
    return struct.unpack('>IIBB', data[16:26])


class AppIconTests(unittest.TestCase):
    def test_ios_catalog_has_opaque_light_and_dark_icons(self):
        catalog = ROOT / 'apps/ios/Assets.xcassets/AppIcon.appiconset'
        images = json.loads((catalog / 'Contents.json').read_text())['images']
        self.assertEqual(len(images), 2)
        self.assertNotIn('appearances', images[0])
        self.assertEqual(images[1]['appearances'], [{'appearance': 'luminosity', 'value': 'dark'}])
        for image in images:
            self.assertEqual(image['idiom'], 'universal')
            self.assertEqual(image['platform'], 'ios')
            self.assertEqual(image['size'], '1024x1024')
            width, height, depth, color = png_header(catalog / image['filename'])
            self.assertEqual((width, height, depth), (1024, 1024, 8))
            self.assertIn(color, (0, 2))  # iOS 图标不能带 alpha 通道。

    def test_ios_build_includes_catalog_and_selects_app_icon(self):
        project = (ROOT / 'apps/ios/project.yml').read_text()
        self.assertIn('- path: Assets.xcassets', project)
        self.assertIn('ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon', project)

    def test_android_manifest_uses_launcher_and_round_icons(self):
        app = ET.parse(ROOT / 'apps/android/AndroidManifest.xml').getroot().find('application')
        self.assertEqual(app.get(ANDROID + 'icon'), '@mipmap/ic_launcher')
        self.assertEqual(app.get(ANDROID + 'roundIcon'), '@mipmap/ic_launcher_round')

    def test_android_adaptive_icons_reference_packaged_layers(self):
        resources = ROOT / 'apps/android/res'
        for name in ('ic_launcher', 'ic_launcher_round'):
            icon = ET.parse(resources / f'mipmap-anydpi-v26/{name}.xml').getroot()
            self.assertEqual(icon.tag, 'adaptive-icon')
            self.assertEqual(icon.find('background').get(ANDROID + 'drawable'), '@color/ic_launcher_background')
            self.assertEqual(icon.find('foreground').get(ANDROID + 'drawable'), '@mipmap/ic_launcher_foreground')
        colors = ET.parse(resources / 'values/icon_colors.xml').getroot()
        self.assertEqual(colors.find("color[@name='ic_launcher_background']").text, '#FFFFFF')

    def test_android_all_densities_have_square_icons_and_transparent_foregrounds(self):
        for density, icon_size, layer_size in (
            ('mdpi', 48, 108), ('hdpi', 72, 162), ('xhdpi', 96, 216),
            ('xxhdpi', 144, 324), ('xxxhdpi', 192, 432),
        ):
            folder = ROOT / f'apps/android/res/mipmap-{density}'
            for name in ('ic_launcher', 'ic_launcher_round'):
                self.assertEqual(png_header(folder / f'{name}.png')[:3], (icon_size, icon_size, 8))
            self.assertEqual(png_header(folder / 'ic_launcher_foreground.png'), (layer_size, layer_size, 8, 6))


if __name__ == '__main__':
    unittest.main()
