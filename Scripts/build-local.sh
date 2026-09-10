#!/bin/bash
set -euo pipefail
local_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$local_root" <<'PYTHON'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
output = Path(os.environ.get("CODEXBAR_LOCAL_OUTPUT", str(Path.home() / "Library/Caches/CodexBar/LocalBuild")))
configuration = os.environ.get("CODEXBAR_BUILD_CONFIGURATION", "Debug")
if configuration not in ("Debug", "Release"):
    raise SystemExit("CODEXBAR_BUILD_CONFIGURATION 必须为 Debug 或 Release")
app_name = "CodexBar Debug.app" if configuration == "Debug" else "CodexBar.app"
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="codexbar-local-build.", dir="/tmp") as directory:
    stage = Path(directory)
    for item in root.iterdir():
        if item.name == "CodexBar.xcodeproj":
            shutil.copytree(item, stage / item.name)
        elif not item.name.startswith(".") and item.name not in ("Build", "DerivedData"):
            (stage / item.name).symlink_to(item)

    # 仅修改临时副本的格式标记, 保留仓库工程
    project = stage / "CodexBar.xcodeproj/project.pbxproj"
    content = project.read_text().replace("objectVersion = 100;", "objectVersion = 77;")
    project.write_text(content.replace("preferredProjectObjectVersion = 100;", "preferredProjectObjectVersion = 77;"))
    log_path = output / "build.log"
    with log_path.open("w") as log:
        result = subprocess.run([
            "xcodebuild", "-project", str(stage / "CodexBar.xcodeproj"), "-scheme", "CodexBar",
            "-configuration", configuration, "-destination", "generic/platform=macOS",
            "-derivedDataPath", str(output / "DerivedData"), "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGN_ENTITLEMENTS=", "ENABLE_DEBUG_DYLIB=NO", "SWIFT_OPTIMIZATION_LEVEL=-O", "build"
        ], stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join(log_path.read_text().splitlines()[-80:]))
        sys.exit(result.returncode)

    # 本地签名不申请 iCloud 权限, 正式构建仍使用工程原有的授权配置
    app = stage / app_name
    subprocess.run(["ditto", "--noextattr", str(output / "DerivedData/Build/Products" / configuration / app.name), str(app)], check=True)
    subprocess.run(["xattr", "-cr", str(app)], check=True)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
    # ditto 会保留目标目录的旧文件, 先移除旧产物避免残留资源破坏签名
    if (output / app.name).exists():
        shutil.rmtree(output / app.name)
    subprocess.run(["ditto", "--noextattr", str(app), str(output / app.name)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(output / app.name)], check=True)
    print(output / app.name)
PYTHON
