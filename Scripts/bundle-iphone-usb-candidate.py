#!/usr/bin/env python3
"""Opt-in build-time USB-tool candidate; never discovers, pairs or changes a device.

Inventory pins the existing local Homebrew payload and supplied source/license
recipes. Install relocates only that exact Mach-O closure into a built capture
bundle. This is not proof of clean-Mac, new-iOS, TLS or notarization support.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

TOOLS = ("idevice_id", "ideviceinfo", "idevicesyslog", "ideviceinstaller")
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
RELATIVE_ROOT = Path("Contents/Frameworks/CaptureUSBTools.app")
MANIFEST_RELATIVE = Path("Contents/Resources/CaptureUSBTools/candidate-manifest.json")
SCHEMA = 1


def run(arguments, *, env=None):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True, timeout=30, env=env)
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} failed: {result.stderr.strip()[:800]}")
    return result.stdout.strip()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def dependencies(path):
    lines = run(("/usr/bin/otool", "-L", path)).splitlines()[1:]
    return [line.strip().split(" (compatibility version", 1)[0] for line in lines if line.strip()]


def rpaths(path):
    result = []
    lines = run(("/usr/bin/otool", "-l", path)).splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for candidate in lines[index + 1:index + 5]:
                match = re.match(r"\s*path (.+) \(offset \d+\)", candidate)
                if match:
                    result.append(match.group(1))
                    break
    return result


def node(path, *, kind, name):
    architecture = run(("/usr/bin/lipo", "-archs", path)).split()
    if architecture != ["arm64"]:
        raise RuntimeError(f"Candidate requires an exact arm64 payload: {path.name}: {architecture}")
    return {"name": name, "kind": kind, "source": str(path), "sha256": digest(path), "bytes": path.stat().st_size,
            "architectures": architecture, "load_commands": dependencies(path), "rpaths": rpaths(path)}


def provenance(prefix, paths):
    cellar = (prefix / "Cellar").resolve()
    result = []
    roots = set()
    for path in paths:
        parts = path.relative_to(cellar).parts
        if len(parts) < 3:
            raise RuntimeError("Dependency must come from a versioned Cellar prefix")
        roots.add(cellar / parts[0] / parts[1])
    for root in sorted(roots):
        receipt = root / "INSTALL_RECEIPT.json"
        recipe = root / ".brew" / (root.parent.name + ".rb")
        if not receipt.is_file() or not recipe.is_file():
            raise RuntimeError(f"Missing installed source/bottle provenance: {root.parent.name}")
        files = [recipe]
        files += sorted(file for file in root.iterdir() if file.is_file() and
                        file.name.upper().startswith(("COPYING", "LICENSE", "LICENCE", "NOTICE", "AUTHORS", "COPYRIGHT")))
        if len(files) < 2:
            raise RuntimeError(f"No supplied license notice found: {root.parent.name}")
        info = json.loads(receipt.read_text())
        # Public build/source fields only; do not package broad receipt environment data.
        result.append({"formula": root.parent.name, "version": root.name,
                       "source_metadata": {key: value for key, value in info.get("source", {}).items() if key in ("spec", "tap", "tap_git_head", "versions")},
                       "built_as_bottle": info.get("built_as_bottle"), "poured_from_bottle": info.get("poured_from_bottle"),
                       "files": [{"source": str(file), "name": file.name, "sha256": digest(file), "bytes": file.stat().st_size}
                                 for file in files]})
    return result


def inventory(prefix):
    prefix = prefix.resolve()
    tool_paths = [(prefix / "bin" / name).resolve(strict=True) for name in TOOLS]
    pending = list(tool_paths)
    visited = set()
    libraries = {}
    system = set()
    while pending:
        path = pending.pop()
        if path in visited:
            continue
        visited.add(path)
        for dependency in dependencies(path):
            if dependency.startswith(SYSTEM_PREFIXES):
                system.add(dependency)
                continue
            if not dependency.startswith(str(prefix) + "/"):
                raise RuntimeError(f"Unreviewed non-system dependency: {dependency}")
            resolved = Path(dependency).resolve(strict=True)
            if resolved == path:
                continue  # LC_ID_DYLIB
            previous = libraries.setdefault(resolved.name, resolved)
            if previous != resolved:
                raise RuntimeError(f"Conflicting library basename: {resolved.name}")
            pending.append(resolved)
    nodes = [node(path, kind="tool", name=name) for name, path in zip(TOOLS, tool_paths)]
    nodes += [node(path, kind="library", name=name) for name, path in sorted(libraries.items())]
    return {"schema_version": SCHEMA, "architecture": "arm64", "status": "candidate_not_clean_mac_verified",
            "prefix": str(prefix), "tools": list(TOOLS), "nodes": nodes,
            "provenance": provenance(prefix, visited), "system_dependencies": sorted(system),
            "runtime_daemon": "macOS existing usbmuxd; no replacement daemon installed",
            "limits": ["Mach-O load-command closure only; OS pairing/trust, iOS compatibility and SSL provider/config behavior require clean-Mac acceptance",
                       "Supplied notices and installed source recipes are inventoried; source availability/relinking obligations require release review",
                       "Version/help probes contact no devices and do not prove USB logging or installed-app access"]}


def verify_sources(lock):
    if lock.get("schema_version") != SCHEMA or lock.get("architecture") != "arm64" or lock.get("tools") != list(TOOLS):
        raise RuntimeError("Unsupported candidate lock schema/architecture/tool set")
    seen = set()
    for item in lock["nodes"]:
        name = item["name"]
        if name in seen or Path(name).name != name or name in (".", "..") or item["kind"] not in ("tool", "library"):
            raise RuntimeError("Candidate nodes must have unique simple filenames and known kinds")
        seen.add(name)
        path = Path(item["source"])
        if not path.is_absolute() or not path.resolve().is_relative_to(Path(lock["prefix"]) / "Cellar"):
            raise RuntimeError("Candidate source escaped its reviewed versioned prefix")
        if not path.is_file() or digest(path) != item["sha256"] or dependencies(path) != item["load_commands"]:
            raise RuntimeError(f"Pinned candidate source changed: {item['name']}; review a deliberate new inventory")
    if {item["name"] for item in lock["nodes"] if item["kind"] == "tool"} != set(TOOLS):
        raise RuntimeError("Candidate tool payload does not match the allowed utilities")
    for formula in lock["provenance"]:
        if Path(formula["formula"]).name != formula["formula"] or Path(formula["version"]).name != formula["version"]:
            raise RuntimeError("Invalid source provenance identity")
        for item in formula["files"]:
            if Path(item["name"]).name != item["name"] or item["name"] in (".", ".."):
                raise RuntimeError("Invalid source/license filename")
            if digest(Path(item["source"])) != item["sha256"]:
                raise RuntimeError(f"Pinned source/license recipe changed: {formula['formula']}/{item['name']}")


def ensure_capture_app(app):
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("MobileCaptureCompanion") is not True:
        raise RuntimeError("USB candidates belong only in the independently built Mobile Capture.app")
    for helper in ("mobile-capture-host", "mobile-capture-proxy"):
        if not os.access(app / "Contents/MacOS" / helper, os.X_OK):
            raise RuntimeError(f"Built capture helper is missing: {helper}")


def install(app, lock, identity):
    app = app.resolve(strict=True)
    ensure_capture_app(app)
    verify_sources(lock)
    destination = app / RELATIVE_ROOT
    if destination.exists():
        raise RuntimeError("Candidate destination already exists; use a fresh build/copy rather than replacing an unknown payload")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging_parent = Path(tempfile.mkdtemp(prefix=".usb-candidate-", dir=destination.parent))
    stage = staging_parent / "CaptureUSBTools.app"
    try:
        (stage / "Contents/MacOS").mkdir(parents=True)
        (stage / "Contents/Frameworks").mkdir()
        (stage / "Contents/Resources/licenses").mkdir(parents=True)
        with (app / "Contents/Info.plist").open("rb") as handle:
            host_info = plistlib.load(handle)
        (stage / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": host_info["CFBundleIdentifier"] + ".usb-tools", "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "idevice_id", "CFBundleName": "Capture USB Tools", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "0.1.0", "LSMinimumSystemVersion": "26.0", "LSUIElement": True,
            "MobileCaptureUSBCandidate": True}))
        by_source = {str(Path(item["source"]).resolve()): item for item in lock["nodes"]}
        for item in lock["nodes"]:
            target = stage / ("Contents/MacOS" if item["kind"] == "tool" else "Contents/Frameworks") / item["name"]
            shutil.copy2(item["source"], target)
            target.chmod(0o755 if item["kind"] == "tool" else 0o644)
            for dependency in item["load_commands"]:
                if dependency.startswith(SYSTEM_PREFIXES):
                    continue
                resolved = str(Path(dependency).resolve())
                if resolved == str(Path(item["source"]).resolve()):
                    continue
                dependency_node = by_source.get(resolved)
                if dependency_node is None:
                    raise RuntimeError("Load command escaped the reviewed dependency closure")
                rewritten = "@loader_path/" + ("../Frameworks/" if item["kind"] == "tool" else "") + dependency_node["name"]
                run(("/usr/bin/install_name_tool", "-change", dependency, rewritten, target))
            for rpath in item.get("rpaths", []):
                if rpath.startswith(lock["prefix"] + "/"):
                    run(("/usr/bin/install_name_tool", "-delete_rpath", rpath, target))
            if item["kind"] == "library":
                run(("/usr/bin/install_name_tool", "-id", "@rpath/" + item["name"], target))
            options = ("--options", "0", "--timestamp=none") if identity == "-" else ("--options", "runtime", "--timestamp")
            run(("/usr/bin/codesign", "--force", "--sign", identity, *options, target))
        for formula in lock["provenance"]:
            directory = stage / "Contents/Resources/licenses" / (formula["formula"] + "-" + formula["version"])
            directory.mkdir()
            for item in formula["files"]:
                shutil.copy2(item["source"], directory / item["name"])
        (stage / "Contents/Resources/source.lock.json").write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
        # Sign the nested app after all its resources exist. Sealing metadata is outside this
        # app so adding it cannot invalidate the nested app's resource signature.
        run(("/usr/bin/codesign", "--force", "--sign", identity, *options, stage))
        run(("/usr/bin/codesign", "--verify", "--deep", "--strict", stage))
        records = []
        for file in sorted(path for path in stage.rglob("*") if path.is_file()):
            records.append({"path": str(file.relative_to(stage)), "sha256": digest(file), "bytes": file.stat().st_size})
        sealed = {"schema_version": SCHEMA, "status": lock["status"],
                  "source_lock_sha256": digest(stage / "Contents/Resources/source.lock.json"), "files": records,
                  "limits": lock["limits"]}
        stage.rename(destination)
        manifest = app / MANIFEST_RELATIVE
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps(sealed, indent=2, sort_keys=True) + "\n")
    finally:
        shutil.rmtree(staging_parent, ignore_errors=True)
    print(f"Installed opt-in USB candidate: {len(TOOLS)} tools, {sum(item['kind'] == 'library' for item in lock['nodes'])} libraries. Outer app must be signed again.")


def smoke(app):
    app = app.resolve(strict=True)
    ensure_capture_app(app)
    root = app / RELATIVE_ROOT
    manifest = json.loads((app / MANIFEST_RELATIVE).read_text())
    lock = json.loads((root / "Contents/Resources/source.lock.json").read_text())
    expected = {item["path"] for item in manifest["files"]}
    actual = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file()}
    if actual != expected:
        raise RuntimeError("Candidate inventory has missing or extra files")
    for item in manifest["files"]:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError("Candidate manifest path escaped its payload")
        target = root / relative
        if target.is_symlink() or digest(target) != item["sha256"]:
            raise RuntimeError(f"Candidate changed after sealing: {item['path']}")
    for item in lock["nodes"]:
        target = root / ("Contents/MacOS" if item["kind"] == "tool" else "Contents/Frameworks") / item["name"]
        for dependency in dependencies(target):
            if dependency.startswith(SYSTEM_PREFIXES):
                continue
            if item["kind"] == "library" and dependency == "@rpath/" + item["name"]:
                continue
            expected = "@loader_path/" + ("../Frameworks/" if item["kind"] == "tool" else "")
            if not dependency.startswith(expected):
                raise RuntimeError(f"Candidate still requires an external loader path: {item['name']}: {dependency}")
        if any(path.startswith(lock["prefix"] + "/") for path in rpaths(target)):
            raise RuntimeError("External Homebrew runtime search path remains")
        run(("/usr/bin/codesign", "--verify", "--strict", target))
    environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "OPENSSL_CONF": "/dev/null"}
    for name in TOOLS:
        value = run((root / "Contents/MacOS" / name, "--version"), env=environment)
        if not value or len(value) > 512:
            raise RuntimeError(f"Unexpected version-only output: {name}")
        print(value)
    print("USB candidate static closure/signatures and clean-PATH version probes passed. No devices contacted; clean-Mac/iOS/trust/logging/notarization remain unverified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("inventory", "install", "smoke"))
    parser.add_argument("--prefix", type=Path, default=Path("/opt/homebrew"))
    parser.add_argument("--lock", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--sign", default="-")
    args = parser.parse_args()
    if args.command == "inventory":
        if args.lock is None or args.lock.exists():
            raise RuntimeError("Provide a new --lock path; reviewed inventories are never overwritten implicitly")
        args.lock.parent.mkdir(parents=True, exist_ok=True)
        args.lock.write_text(json.dumps(inventory(args.prefix), indent=2, sort_keys=True) + "\n")
        print(f"Pinned local candidate and supplied source/license provenance: {args.lock}")
    elif args.command == "install":
        if args.app is None or args.lock is None:
            raise RuntimeError("install requires --app and an explicitly reviewed --lock")
        install(args.app, json.loads(args.lock.read_text()), args.sign)
    else:
        if args.app is None:
            raise RuntimeError("smoke requires --app")
        smoke(args.app)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
