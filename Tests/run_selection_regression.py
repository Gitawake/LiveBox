"""Exercise the production selection lifecycle with reordered callbacks."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / "LiveBox/ContentView.swift").read_text()
lifecycle = source.split("// Selection lifecycle is independent of callback delivery order.")[1].split("// End selection lifecycle.")[0]
checks = """
private var session = MaterialSelectionSession()
private let first = MaterialRequest(kind: .image)
private let replacement = MaterialRequest(kind: .image)
private let video = MaterialRequest(kind: .video)
precondition(first.id != replacement.id)
session.begin(first)
session.begin(replacement)
precondition(!session.isCurrent(first))
precondition(!session.finish(first)) // Old load/cancel cannot release the new selection.
precondition(session.isCurrent(replacement))
precondition(session.finish(replacement))
precondition(!session.finish(replacement)) // Duplicate completion cannot commit twice.
session.begin(video)
precondition(session.finish(video)) // Explicit cancellation invalidates later callbacks.
precondition(!session.isCurrent(video))
session.begin(first)
session.begin(video)
precondition(!session.isCurrent(first)) // Cross-kind callbacks cannot replace current media.
precondition(session.isCurrent(video))
print("PASS reordered, cancelled, duplicate and cross-kind selection callbacks")
"""
with tempfile.TemporaryDirectory(prefix="LiveBoxSelection-") as folder:
    path = Path(folder)
    swift = path / "Selection.swift"
    swift.write_text("import Foundation\n" + lifecycle + checks)
    subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(path / "ModuleCache"), str(swift), "-o", str(path / "Selection")], check=True)
    subprocess.run([str(path / "Selection")], check=True)
