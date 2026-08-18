#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shutil
import sys
import unicodedata
from pathlib import Path

MANIFEST = ".hangulfix-e2e-manifest.json"
MAGIC = "HangulFix-E2E-v1"

def nfc(value: str) -> str:
    return unicodedata.normalize("NFC", value)

def nfd(value: str) -> str:
    return unicodedata.normalize("NFD", value)

def bpath(root: bytes, components):
    result = root
    for component in components:
        result = os.path.join(result, os.fsencode(component))
    return result

def mkdir_exact(root: bytes, components):
    path = root
    for component in components:
        path = os.path.join(path, os.fsencode(component))
        if not os.path.exists(path):
            os.mkdir(path)
    return path

def write_exact(path: bytes, data: bytes):
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    try:
        view = memoryview(data)
        offset = 0
        while offset < len(view):
            written = os.write(fd, view[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
    finally:
        os.close(fd)

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def sha256_file(path: bytes) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def rel_string(components):
    return "/".join(components)

def add_dir(manifest, initial_components, *, package_internal=False):
    manifest["items"].append({
        "kind": "directory",
        "initial": rel_string(initial_components),
        "expected": rel_string(initial_components if package_internal else [nfc(c) for c in initial_components]),
        "package_internal": package_internal,
    })

def add_file(manifest, root_b, components, data: bytes, *, package_internal=False, track_inode=False):
    path = bpath(root_b, components)
    write_exact(path, data)
    stat = os.lstat(path)
    item = {
        "kind": "file",
        "initial": rel_string(components),
        "expected": rel_string(components if package_internal else [nfc(c) for c in components]),
        "package_internal": package_internal,
        "sha256": sha256_bytes(data),
        "size": len(data),
    }
    if track_inode:
        item["device"] = stat.st_dev
        item["inode"] = stat.st_ino
    manifest["items"].append(item)

def add_symlink(manifest, root_b, components, target: str):
    path = bpath(root_b, components)
    os.symlink(os.fsencode(target), path)
    manifest["items"].append({
        "kind": "symlink",
        "initial": rel_string(components),
        "expected": rel_string([nfc(c) for c in components]),
        "package_internal": False,
        "target": target,
    })

def create_fixture(root: Path):
    root = root.expanduser().resolve()
    if root.exists():
        raise SystemExit(f"Refusing to overwrite existing path: {root}\nRemove it manually or choose another --path.")
    root.mkdir(parents=True)
    root_b = os.fsencode(str(root))

    manifest = {
        "magic": MAGIC,
        "root": str(root),
        "items": [],
        "notes": {
            "expected_behavior": "Run HangulFix on the fixture root, then run check.",
            "package_rule": "Sample.app descendants must remain untouched."
        }
    }

    single = nfd("한글_테스트.txt")
    add_file(manifest, root_b, [single], b"single-file\n")

    already = nfc("이미_NFC_정상.txt")
    add_file(manifest, root_b, [already], b"already-nfc\n", track_inode=True)

    project = nfd("프로젝트_자료")
    meeting = nfd("회의_문서")
    report = nfd("최종_회의록.txt")
    mkdir_exact(root_b, [project])
    add_dir(manifest, [project])
    mkdir_exact(root_b, [project, meeting])
    add_dir(manifest, [project, meeting])
    add_file(manifest, root_b, [project, meeting, report], b"nested-content\n")

    mixed = nfd("혼합_자료")
    mkdir_exact(root_b, [mixed])
    add_dir(manifest, [mixed])
    add_file(manifest, root_b, [mixed, "English_report.txt"], b"ascii-noop\n", track_inode=True)
    add_file(manifest, root_b, [mixed, nfd("보고서 2026 (최종).pdf")], b"fake-pdf-content\n")
    add_file(manifest, root_b, [mixed, nfd("🚀_한글_파일.txt")], "emoji+hangul\n".encode("utf-8"))
    add_file(manifest, root_b, [mixed, nfd(".숨김_파일.txt")], b"hidden\n")
    add_file(manifest, root_b, [mixed, nfd("zero_한글.dat")], b"")
    add_file(manifest, root_b, [mixed, nfd("café_한글.txt")], "accent\n".encode("utf-8"))
    binary = bytes(range(256)) * 4096
    add_file(manifest, root_b, [mixed, nfd("binary_한글.bin")], binary)

    batch = "batch"
    mkdir_exact(root_b, [batch])
    add_dir(manifest, [batch])
    for index in range(128):
        name = nfd(f"문서_{index:03d}_최종.txt")
        payload = f"batch-{index:03d}\n".encode("utf-8")
        add_file(manifest, root_b, [batch, name], payload)

    add_file(manifest, root_b, ["link-target.txt"], b"symlink-target\n", track_inode=True)
    add_symlink(manifest, root_b, [nfd("정상_링크")], "link-target.txt")
    add_symlink(manifest, root_b, [nfd("끊어진_링크")], "/definitely/missing/hangulfix-target")

    package = "Sample.app"
    contents = "Contents"
    mkdir_exact(root_b, [package])
    add_dir(manifest, [package])
    mkdir_exact(root_b, [package, contents])
    add_dir(manifest, [package, contents], package_internal=True)
    internal = nfd("내부_파일.txt")
    add_file(manifest, root_b, [package, contents, internal], b"package-internal\n", package_internal=True)

    manifest_path = root / MANIFEST
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

    changed = sum(
        item["initial"].split("/")[-1].encode("utf-8")
        != nfc(item["initial"].split("/")[-1]).encode("utf-8")
        for item in manifest["items"]
        if not item["package_internal"]
    )
    print(f"Created HangulFix E2E fixture: {root}")
    print(f"Tracked items: {len(manifest['items'])}")
    print(f"Expected rename candidates: {changed}")
    print("")
    print("Next:")
    print(f"  1. Open HangulFix and drop this folder: {root}")
    print("  2. Run NFC conversion.")
    print(f"  3. Verify with: python3 scripts/e2e_fixture.py check {root}")

def load_manifest(root: Path):
    manifest_path = root / MANIFEST
    if not manifest_path.is_file():
        raise SystemExit(f"Missing fixture manifest: {manifest_path}")
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if data.get("magic") != MAGIC:
        raise SystemExit(f"Not a HangulFix E2E fixture: {root}")
    return data

def exact_exists(root_b: bytes, relative: str) -> bool:
    path = root_b
    components = relative.split("/") if relative else []
    for component in components:
        try:
            names = os.listdir(path)
        except OSError:
            return False
        wanted = os.fsencode(component)
        if wanted not in names:
            return False
        path = os.path.join(path, wanted)
    return True

def walk_raw(root_b: bytes):
    stack = [(root_b, b"")]
    while stack:
        directory, rel = stack.pop()
        with os.scandir(directory) as scan:
            for entry in scan:
                name = entry.name if isinstance(entry.name, bytes) else os.fsencode(entry.name)
                child_rel = os.path.join(rel, name) if rel else name
                yield child_rel, entry
                if entry.is_dir(follow_symlinks=False):
                    stack.append((entry.path, child_rel))

def check_fixture(root: Path):
    root = root.expanduser().resolve()
    manifest = load_manifest(root)
    root_b = os.fsencode(str(root))
    failures = []

    for item in manifest["items"]:
        expected = item["expected"]
        if not exact_exists(root_b, expected):
            failures.append(f"missing exact expected path: {expected}")
            continue

        expected_b = bpath(root_b, expected.split("/") if expected else [])
        kind = item["kind"]

        try:
            st = os.lstat(expected_b)
        except OSError as exc:
            failures.append(f"cannot stat {expected}: {exc}")
            continue

        if kind == "file":
            if not os.path.isfile(expected_b):
                failures.append(f"expected file: {expected}")
                continue
            actual_hash = sha256_file(expected_b)
            if actual_hash != item["sha256"]:
                failures.append(f"content hash changed: {expected}")
            if st.st_size != item["size"]:
                failures.append(f"size changed: {expected}")
            if "inode" in item and (st.st_ino != item["inode"] or st.st_dev != item["device"]):
                failures.append(f"untouched file inode changed: {expected}")
        elif kind == "directory":
            if not os.path.isdir(expected_b):
                failures.append(f"expected directory: {expected}")
        elif kind == "symlink":
            if not os.path.islink(expected_b):
                failures.append(f"expected symlink: {expected}")
                continue
            actual_target = os.readlink(expected_b)
            if isinstance(actual_target, bytes):
                actual_target = os.fsdecode(actual_target)
            if actual_target != item["target"]:
                failures.append(f"symlink target changed: {expected}")

    package_prefix = os.fsencode("Sample.app") + os.sep.encode()
    for rel_b, entry in walk_raw(root_b):
        if rel_b == os.fsencode(MANIFEST):
            continue
        if b".hangulfix-" in rel_b:
            failures.append(f"temporary entry left behind: {os.fsdecode(rel_b)}")
        if rel_b.startswith(package_prefix):
            continue
        for component_b in rel_b.split(os.sep.encode()):
            component = os.fsdecode(component_b)
            if component.encode("utf-8") != nfc(component).encode("utf-8"):
                failures.append(f"non-NFC name remains: {os.fsdecode(rel_b)}")
                break

    package_item = next(
        (item for item in manifest["items"]
         if item["package_internal"] and item["kind"] == "file" and item["initial"].endswith("내부_파일.txt")),
        None
    )
    if package_item:
        initial = package_item["initial"]
        if not exact_exists(root_b, initial):
            failures.append("package descendant was modified; Sample.app contents must be skipped")
        leaf = initial.split("/")[-1]
        if leaf.encode("utf-8") == nfc(leaf).encode("utf-8"):
            failures.append("fixture package internal filename was not NFD as intended")

    if failures:
        print(f"E2E verification FAILED ({len(failures)} issue(s)):")
        for failure in failures[:30]:
            print(f"  - {failure}")
        if len(failures) > 30:
            print(f"  ... and {len(failures) - 30} more")
        raise SystemExit(1)

    print("E2E verification PASSED")
    print(f"Fixture: {root}")
    print(f"Verified tracked items: {len(manifest['items'])}")
    print("Verified: exact NFC bytes, contents, symlinks, no temp files, package skip, NFC no-op inode")

def main():
    parser = argparse.ArgumentParser(description="Create and verify HangulFix real-filesystem E2E fixtures.")
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create", help="Create an E2E fixture tree.")
    create.add_argument("path", nargs="?", default=str(Path.home() / "Desktop" / "HangulFix-E2E-Test"))

    check = sub.add_parser("check", help="Verify a converted E2E fixture tree.")
    check.add_argument("path", nargs="?", default=str(Path.home() / "Desktop" / "HangulFix-E2E-Test"))

    args = parser.parse_args()
    if args.command == "create":
        create_fixture(Path(args.path))
    elif args.command == "check":
        check_fixture(Path(args.path))

if __name__ == "__main__":
    main()
