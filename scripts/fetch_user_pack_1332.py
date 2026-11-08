"""Fetch the user-requested 1332 pack as pinned CI input, never an app asset."""
import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen

URL = "https://www.yckceo.com/yuedu/shuyuans/json/id/1332.json"
EXPECTED = "88f5993829896bbac61f6e3e5b8939e587b85b4a86b659850053fd002c8eca5f"


def main():
    with urlopen(Request(URL, headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"}), timeout=90) as response:
        data = response.read(32 * 1024 * 1024 + 1)
    assert hashlib.sha256(data).hexdigest() == EXPECTED, "1332 input changed; review the new data before changing the pin"
    entries = json.loads(data)
    assert isinstance(entries, list) and len(entries) == 82
    assert all(isinstance(s, dict) and s.get("bookSourceUrl") for s in entries)
    output = Path("build")
    output.mkdir(exist_ok=True)
    (output / "source-pack-1332.json").write_bytes(data)
    (output / "source-pack-1332-input.json").write_text(json.dumps({"url": URL, "sha256": EXPECTED, "count": len(entries)}, indent=2), encoding="utf-8")
    print(f"Verified 1332 input: {len(entries)} entries, SHA256 {EXPECTED}")


if __name__ == "__main__":
    main()
