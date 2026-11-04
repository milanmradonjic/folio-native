#!/usr/bin/env python3
"""Fetch one pinned, non-V8 PDFium distribution. No package manager or shell hooks."""
import argparse
import hashlib
import pathlib
import platform
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
PINS = {
    "arm64": "4939bd935ac83ddc09a3a4f038bc43a19cea1660316a3667f26cb07a070e139d",
    "x86_64": "8a5193535b80c7215d8932f6647ae5097465b6dba2811602c21e120c2af112b0",
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=PINS, default=platform.machine())
    parser.add_argument("--download", action="store_true", help="Allow the initial HTTPS download")
    args = parser.parse_args()
    cpu = {"arm64": "arm64", "x86_64": "x64"}[args.arch]
    base = ROOT / "vendor/pdfium"
    cache = base / "cache" / f"pdfium-mac-{cpu}.tgz"
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.exists():
        if not args.download:
            raise SystemExit("Dependency not cached. Run: python3 scripts/fetch-pdfium.py --download")
        url = f"https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/8125/pdfium-mac-{cpu}.tgz"
        request = urllib.request.Request(url, headers={"User-Agent": "Folio-Native-build"})
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = response.read(16 * 1024 * 1024 + 1)
        if len(payload) > 16 * 1024 * 1024 or hashlib.sha256(payload).hexdigest() != PINS[args.arch]:
            raise SystemExit("PDFium download did not match its pinned SHA-256")
        cache.write_bytes(payload)
    if hashlib.sha256(cache.read_bytes()).hexdigest() != PINS[args.arch]:
        raise SystemExit("Cached PDFium archive did not match its pinned SHA-256")
    # Re-extract the verified archive, so edits to an old vendor directory cannot enter a build.
    with tempfile.TemporaryDirectory(dir=base) as temporary:
        folder = pathlib.Path(temporary)
        with tarfile.open(cache, "r:gz") as archive:
            members = archive.getmembers()
            if sum(m.size for m in members) > 96 * 1024 * 1024:
                raise SystemExit("Unexpected expanded dependency size")
            for member in members:
                path = pathlib.PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile()):
                    raise SystemExit("Unsafe path or entry in dependency archive")
                destination = folder.joinpath(*path.parts)
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, destination.open("wb") as output:
                        shutil.copyfileobj(source, output)
        configuration = (folder / "args.gn").read_text()
        for required in ("pdf_enable_v8 = false", "pdf_enable_xfa = false", "pdf_is_standalone = true"):
            if required not in configuration:
                raise SystemExit(f"Unsupported PDFium configuration: {required}")
        target = base / args.arch
        if target.exists():
            shutil.rmtree(target)
        shutil.move(str(folder), str(target))
    print(f"Verified PDFium 8125 ({args.arch}; V8/XFA disabled)")

if __name__ == "__main__":
    main()
