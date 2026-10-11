"""Check the rebuilt IPA against the verified upstream v4.6.0 release."""
import hashlib
import io
import json
from pathlib import Path
import plistlib
import struct
import zipfile

ROOT = Path(__file__).resolve().parent.parent
ORIGINAL = ROOT / "build/upstream-v4.6.0/original.ipa"
REBUILT = ROOT / "build/ScrcpyRemote-4.6.0-unsigned.ipa"
APP = "Payload/Scrcpy Remote.app/"


def dylibs(data):
    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise AssertionError("Expected an arm64 Mach-O binary")
    header = struct.unpack_from("<8I", data)
    assert header[1] == 0x100000C, "Expected an arm64 binary"
    result = []
    offset = 32
    for _ in range(header[4]):
        command, size = struct.unpack_from("<II", data, offset)
        if command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            relative = struct.unpack_from("<I", data, offset + 8)[0]
            name = data[offset + relative:offset + size].split(b"\0")[0].decode()
            result.append((name, command))
        offset += size
    return sorted(result)


def main():
    checks = []

    def check(name, passed):
        checks.append({"check": name, "passed": bool(passed)})

    with zipfile.ZipFile(ORIGINAL) as original, zipfile.ZipFile(REBUILT) as rebuilt:
        check("IPA ZIP integrity", rebuilt.testzip() is None)
        for relative in ("Info.plist", "Frameworks/VNCClient.framework/Info.plist",
                         "PlugIns/ScrcpyLiveActivityWidgetExtension.appex/Info.plist"):
            a = plistlib.loads(original.read(APP + relative))
            b = plistlib.loads(rebuilt.read(APP + relative))
            # The hosted runner's macOS patch/build is not the author's Mac.
            # Record that difference; never disguise it by rewriting metadata.
            for key in sorted(a.keys() | b.keys()):
                if key != "BuildMachineOSBuild":
                    check(f"{relative}: {key}", a.get(key) == b.get(key))

        binaries = ("Scrcpy Remote", "Frameworks/VNCClient.framework/VNCClient",
                    "PlugIns/ScrcpyLiveActivityWidgetExtension.appex/ScrcpyLiveActivityWidgetExtension")
        for relative in binaries:
            check(f"{relative}: linked libraries", dylibs(original.read(APP + relative)) == dylibs(rebuilt.read(APP + relative)))
        app = rebuilt.read(APP + "Scrcpy Remote")
        framework = rebuilt.read(APP + "Frameworks/VNCClient.framework/VNCClient")
        for marker in (b"Lavf62.12.101", b"Lavc62.28.101", b"go1.24.3", b"lts_20240722"):
            check(f"App dependency: {marker.decode()}", marker in app)
        check("No substituted Abseil 20240116", b"lts_20240116" not in app)
        for marker in (b"SDL-3.4.8-release-3.4.8", b"OpenSSL 1.1.1w", b"Lavc62.28.101"):
            check(f"Framework dependency: {marker.decode()}", marker in framework)
        check("No additional deprecated OpenSSL APIs", b"_ASN1_STRING_data\0" not in framework)
        with zipfile.ZipFile(io.BytesIO(rebuilt.read(APP + "scrcpy-server"))) as server:
            dex = server.read("classes.dex")
            check("Drawing Toolkit server retained", all(name in dex for name in (
                b"Lcom/genymobile/scrcpy/control/StylusInjector;", b"Lcom/genymobile/scrcpy/control/StylusPacket;")))

        def resource_names(archive):
            return {n[len(APP):] for n in archive.namelist() if n.startswith(APP) and not n.endswith("/")
                    and "_CodeSignature/" not in n and not n.endswith("embedded.mobileprovision")}

        check("Same packaged file inventory, excluding signatures", resource_names(original) == resource_names(rebuilt))
        for relative in resource_names(original):
            if relative in binaries or relative.endswith(("Info.plist", "Assets.car")) or relative == "scrcpy-server":
                continue
            check(f"Resource retained: {relative}", original.read(APP + relative) == rebuilt.read(APP + relative))

        original_info = plistlib.loads(original.read(APP + "Info.plist"))
        rebuilt_info = plistlib.loads(rebuilt.read(APP + "Info.plist"))
        report = {
            "checks": checks,
            "ipa_sha256": hashlib.sha256(REBUILT.read_bytes()).hexdigest(),
            "original_build_machine": original_info.get("BuildMachineOSBuild"),
            "rebuilt_build_machine": rebuilt_info.get("BuildMachineOSBuild"),
            "intentional_differences": ["Drawing Toolkit implementation", "Unsigned IPA instead of author's Ad Hoc signature",
                                       "Hosted runner macOS build metadata", "Recompiled code/assets and build identifiers"],
            "limits": "Static build parity checks do not prove identical runtime rendering or diagnose the AVD image issue.",
        }
    (ROOT / "build/build-parity.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    failures = [item["check"] for item in checks if not item["passed"]]
    if failures:
        raise SystemExit("Build parity check failed:\n" + "\n".join(failures))
    print(f"Passed {len(checks)} build parity checks")


if __name__ == "__main__":
    main()
