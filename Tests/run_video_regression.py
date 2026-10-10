"""Run the actual converter against synthetic videos without saving to Photos."""
from pathlib import Path
import subprocess
import tempfile
import wave
import math
import struct

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="LiveBoxRegression-") as folder:
    temporary = Path(folder)
    audio = temporary / "audio.wav"
    with wave.open(str(audio), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(44100)
        output.writeframes(b"".join(struct.pack("<hh", value, value) for value in (int(12000 * math.sin(2 * math.pi * 440 * index / 44100)) for index in range(44100 * 6))))
    # Expose the private converter only in this temporary test compilation.
    source = (root / "LiveBox/LivePhotoMaker.swift").read_text().replace(
        "private static func writeWallpaper", "static func writeWallpaper"
    )
    source += "\n" + (root / "LiveBox/WallpaperMetadata.swift").read_text()
    source += "\n" + (root / "LiveBox/WallpaperMetadataInjector.swift").read_text()
    source += "\n" + (root / "Tests/VideoConversionRegression.swift").read_text()
    combined = temporary / "Regression.swift"
    combined.write_text(source)
    executable = temporary / "Regression"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
        str(temporary / "ModuleCache"), str(combined), "-o", str(executable)
    ], check=True, timeout=120)
    subprocess.run([str(executable), str(audio)], check=True, timeout=90)
