#!/usr/bin/env python3
"""构建发布附件, 用应用内公钥验证更新签名"""

import argparse
import datetime as dt
import hashlib
import os
import pathlib
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPOSITORY = "yatotm/CodexBar"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def package(app, output, signer):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not str(build).isdigit():
        raise ValueError("发布版本格式无效")
    if info["CFBundleIdentifier"] != "io.github.yatotm.codexbar":
        raise ValueError("只能发布本 fork 的正式应用")
    if info.get("SUFeedURL") != f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml":
        raise ValueError("更新地址没有指向当前 fork")
    private_key = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()
    if not private_key:
        raise ValueError("未配置 SPARKLE_PRIVATE_KEY")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"CodexBar-fork-v{version}.zip"
    dmg = output / f"CodexBar-fork-v{version}.dmg"
    if archive.exists() or dmg.exists():
        raise ValueError("发布附件已存在, 请使用空输出目录")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    with tempfile.TemporaryDirectory(prefix="codexbar-dmg-") as directory:
        stage = pathlib.Path(directory)
        subprocess.run(["ditto", str(app), str(stage / app.name)], check=True)
        (stage / "Applications").symlink_to("/Applications")
        (stage / "安装说明.txt").write_text(
            "将 CodexBar Fork.app 拖入 Applications, 然后从应用程序打开\n"
            "本版未经过 Apple 公证, 首次打开若被阻止, 在系统设置 > 隐私与安全性中选择仍要打开\n"
            "统计与 SSH/HTTPS 可用; Helper, 防睡眠, 自动重置及 iCloud 不可用\n"
            "安装帮助: https://support.apple.com/zh-cn/102445\n"
        )
        subprocess.run(["hdiutil", "create", "-volname", "CodexBar", "-srcfolder", str(stage), "-format", "UDZO", str(dmg)], check=True)
    result = subprocess.run([str(signer), "--ed-key-file", "-", "-p", str(archive)],
                            input=private_key, capture_output=True, text=True, check=True)
    signature = result.stdout.strip()
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature):
        raise ValueError("Sparkle 返回了无效签名")
    verifier = pathlib.Path(__file__).with_name("verify-update.swift")
    subprocess.run(["xcrun", "swift", str(verifier), str(archive), signature, info["SUPublicEDKey"]], check=True)
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "CodexBar · yatotm"
    ET.SubElement(channel, "link").text = info["SUFeedURL"]
    ET.SubElement(channel, "language").text = "zh-CN"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"CodexBar {version}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(build)
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = f"https://github.com/{REPOSITORY}/releases/tag/fork-v{version}"
    ET.SubElement(item, "pubDate").text = dt.datetime.now(dt.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{REPOSITORY}/releases/download/fork-v{version}/{archive.name}",
        f"{{{SPARKLE}}}edSignature": signature,
        "length": str(archive.stat().st_size), "type": "application/octet-stream"
    })
    ET.indent(root)
    feed = output / "appcast.xml"
    ET.ElementTree(root).write(feed, encoding="utf-8", xml_declaration=True)
    checksums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in [archive, dmg, feed])
    (output / "SHA256SUMS.txt").write_text(checksums)
    print(f"Prepared CodexBar {version} ({build}) with verified update signature")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--signer", type=pathlib.Path, required=True)
    args = parser.parse_args()
    package(args.app.resolve(), args.output.resolve(), args.signer.resolve())
