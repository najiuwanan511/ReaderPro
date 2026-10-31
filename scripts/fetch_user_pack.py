"""Fetch the user's exact source pack as CI input, never as an app resource."""
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

URL = 'https://gcore.jsdelivr.net/gh/mumuceo/file01/202610/15320_712f79e6df0d9fad5e4a331a960ebfdd.json'
EXPECTED = '66260db91c962fe82e33de410e54f68daf712d054d07faab1809da4af671624a'
data = urlopen(URL, timeout=90).read()
assert hashlib.sha256(data).hexdigest() == EXPECTED, 'Source pack changed; review new input before updating expectations'
entries = json.loads(data)
assert len(entries) == len({s['bookSourceUrl'] for s in entries}) == 1466
Path('build').mkdir(exist_ok=True)
Path('build/source-pack-1325.json').write_bytes(data)
Path('build/source-pack-audit.json').write_text(json.dumps({'url': URL, 'sha256': EXPECTED, 'count': len(entries)}, indent=2))
print(f'Verified {len(entries)} unique user sources, SHA256 {EXPECTED}')
