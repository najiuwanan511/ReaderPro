"""Fetch and pin the user's 1329 source pack for the separate CI audit."""
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

# The user's 1329 URL redirected to this immutable versioned file. Fail if
# it changes so an audit cannot silently compare a different collection.
URL = 'https://gcore.jsdelivr.net/gh/mumuceo/file01/202610/15338_ce8a3acac81065cb912936624a025c86.json'
EXPECTED = '9dc14b32311f377818df2aa92459c4da9137f0550644f360597a1732cb28e5f5'
data = urlopen(URL, timeout=90).read()
assert hashlib.sha256(data).hexdigest() == EXPECTED, '1329 pack changed; review before updating expectations'
entries = json.loads(data)
assert len(entries) == len({entry['bookSourceUrl'] for entry in entries}) == 320
Path('build').mkdir(exist_ok=True)
Path('build/source-pack-1329.json').write_bytes(data)
Path('build/source-pack-1329-input.json').write_text(json.dumps({
    'userURL': 'https://www.yckceo.com/yuedu/shuyuans/json/id/1329.json',
    'url': URL, 'sha256': EXPECTED, 'count': len(entries),
}, indent=2), encoding='utf-8')
print(f'Verified {len(entries)} unique 1329 sources, SHA256 {EXPECTED}')
