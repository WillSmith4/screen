"""Fetch the exact v4.6.0 headers/resources used to reproduce its build."""
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/upstream-v4.6.0"
COMMIT = "cdbc6ac7d9d2eca1d1cada5281a8f46d800d5b09"
SOURCES = {
    "source.zip": (
        f"https://github.com/wsvn53/scrcpy-mobile/archive/{COMMIT}.zip",
        "bfd14ee7b5f30db9ef32d68dca4455318b8abec0bd9b2c999d52821725e1df0e",
    ),
    "original.ipa": (
        "https://github.com/wsvn53/scrcpy-mobile/releases/download/v4.6.0/Scrcpy-Remote-v4.6.0.ipa",
        "aadfbedcc4f6dcd779a41223f420a5bd772a3250da34bb27bb06af459ad5428b",
    ),
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (url, expected) in SOURCES.items():
        path = OUT / name
        if not path.exists() or sha256(path) != expected:
            with urllib.request.urlopen(url, timeout=120) as source, path.open("wb") as target:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
        if sha256(path) != expected:
            raise RuntimeError(f"Reference checksum mismatch: {name}")

    headers = OUT / "include/openssl"
    headers.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT / "source.zip") as archive:
        prefix = f"scrcpy-mobile-{COMMIT}/porting/libs/include/openssl/"
        count = 0
        for name in archive.namelist():
            if name.startswith(prefix) and name.endswith(".h"):
                relative = name[len(prefix):]
                if "/" in relative or "\\" in relative:
                    raise RuntimeError(f"Unexpected header path: {name}")
                (headers / relative).write_bytes(archive.read(name))
                count += 1
        if count < 100:
            raise RuntimeError("Incomplete upstream OpenSSL headers")

    resources = OUT / "resources"
    resources.mkdir(exist_ok=True)
    with zipfile.ZipFile(OUT / "original.ipa") as archive:
        for relative in ("CONTINUOUS_UPDATES_IMPLEMENTATION.md", "en.lproj/Localizable.strings.xml"):
            member = "Payload/Scrcpy Remote.app/" + relative
            (resources / Path(relative).name).write_bytes(archive.read(member))
    (OUT / "reference.json").write_text(json.dumps({
        "commit": COMMIT, "archives": {name: {"url": url, "sha256": sha} for name, (url, sha) in SOURCES.items()},
        "openssl_headers": count,
    }, indent=2), encoding="utf-8")
    print(f"Verified v4.6.0 reference and {count} original OpenSSL headers")


if __name__ == "__main__":
    main()
