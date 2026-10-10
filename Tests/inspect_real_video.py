"""Convert and inspect real input using the production converter (no Photos writes).
Usage: python3 Tests/inspect_real_video.py input.mov output-directory [start] [cover]
Requires macOS and Xcode Command Line Tools. Output includes paired resources.
Successful checks establish resource integrity, not Lock Screen eligibility.
"""
from pathlib import Path
import subprocess
import tempfile
import sys
root = Path(__file__).resolve().parents[1]
if len(sys.argv) < 3:
    raise SystemExit(__doc__)
output = Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
if (output / "video.mov").exists() or (output / "photo.heic").exists():
    raise SystemExit("Use a fresh output directory to preserve existing resources.")
with tempfile.TemporaryDirectory(prefix="LiveBoxInspect-") as folder:
    temporary = Path(folder)
    source = (root / "LiveBox/LivePhotoMaker.swift").read_text().replace("private static func writeWallpaper", "static func writeWallpaper")
    for name in ["LiveBox/WallpaperMetadata.swift", "LiveBox/WallpaperMetadataInjector.swift", "Tests/InspectRealVideo.swift"]:
        source += "\n" + (root / name).read_text()
    combined = temporary / "Inspect.swift"
    combined.write_text(source)
    executable = temporary / "Inspect"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(temporary / "ModuleCache"), str(combined), "-o", str(executable)], check=True, timeout=120)
    args = [str(executable), str(Path(sys.argv[1]).resolve()), str(output), sys.argv[3] if len(sys.argv) > 3 else "0"]
    if len(sys.argv) > 4:
        args.append(str(Path(sys.argv[4]).resolve()))
    with (output / "inspection.log").open("w") as log:
        subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    print((output / "inspection.log").read_text())
