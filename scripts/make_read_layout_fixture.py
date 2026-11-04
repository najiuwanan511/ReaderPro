"""Build the tiny original layout test package (developer tool, not needed in CI).

Requires fonttools and Pillow. No third-party font or artwork is bundled.
"""
import io
import json
import zipfile
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from PIL import Image

font = FontBuilder(1000, isTTF=True)
font.setupGlyphOrder([".notdef", "space", "A"])
glyphs = {}
for name in [".notdef", "space", "A"]:
    pen = TTGlyphPen(None)
    if name != "space":
        pen.moveTo((100, 0)); pen.lineTo((300, 700)); pen.lineTo((500, 0)); pen.closePath()
    glyphs[name] = pen.glyph()
font.setupGlyf(glyphs)
font.setupCharacterMap({32: "space", 65: "A"})
font.setupHorizontalMetrics({name: (600, 0) for name in glyphs})
font.setupHorizontalHeader(ascent=800, descent=-200)
font.setupNameTable({"familyName": "ReaderPro Layout Fixture", "styleName": "Regular", "uniqueFontIdentifier": "ReaderProLayoutFixture-Regular", "fullName": "ReaderPro Layout Fixture Regular", "psName": "ReaderProLayoutFixture-Regular"})
font.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
font.setupPost()
font.setupMaxp()
font.font["head"].created = font.font["head"].modified = 3800000000
font_data = io.BytesIO(); font.save(font_data)
image_data = io.BytesIO(); Image.new("RGB", (24, 24), "#ECDDBA").save(image_data, format="PNG")
config = {
    "name": "排版导入样例", "bgStr": "paper.png", "bgType": 2, "bgAlpha": 100,
    "bgStrNight": "#102030", "textColorNight": "#C0D0E0", "textColor": "#243648",
    "textSize": 24, "textFont": "fixture.ttf", "textBold": 1, "letterSpacing": -0.05,
    "lineSpacingExtra": 12, "paragraphSpacing": 6, "paragraphIndent": "　　",
    "pageAnim": 2, "pageAnimEInk": 4,
    "paddingLeft": 12, "paddingRight": 12, "paddingTop": 10, "paddingBottom": 10,
    "titleMode": 1, "unmappedFutureField": {"retain": True}
}
target = Path(__file__).parent / "fixtures" / "read-layout.zip"
with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name, data in [("readConfig.json", json.dumps(config, ensure_ascii=False).encode()), ("paper.png", image_data.getvalue()), ("fixture.ttf", font_data.getvalue())]:
        entry = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0)); entry.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(entry, data)
print(target)
