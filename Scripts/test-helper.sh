#!/bin/bash
set -euo pipefail
helper_test_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 -B - "$helper_test_root" <<'PYTHON'
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="codexbar-helper-tests-", dir="/tmp") as directory:
    stage = Path(directory)
    source = stage / "Sources/CodexBarHelperCore"
    source.mkdir(parents=True)
    for name in ("HelperRuntime.swift", "OwnershipStore.swift", "Pmset.swift", "HelperError.swift"):
        (source / name).symlink_to(root / "CodexBarHelper" / name)
    for name in ("CodexBarHelperXPC.swift", "BoundedProcess.swift"):
        (source / name).symlink_to(root / "Shared" / name)
    shutil.copytree(root / "Tests/Helper", stage / "Tests/CodexBarHelperCoreTests")
    (stage / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CodexBarHelperCore", platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CodexBarHelperCore", swiftSettings: [.define("CODEXBAR_HELPER_TESTING")]),
        .testTarget(name: "CodexBarHelperCoreTests", dependencies: ["CodexBarHelperCore"])
    ]
)
''')
    result = subprocess.run([
        "xcrun", "swift", "test", "--package-path", str(stage),
        "--scratch-path", str(stage / ".build"),
        "--cache-path", str(stage / ".cache"),
        "--disable-dependency-cache", "--manifest-cache", "none"
    ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in result.stdout.splitlines():
        if result.returncode or "Test run with" in line or "passed" in line or "error:" in line:
            print(line)
    sys.exit(result.returncode)
PYTHON
