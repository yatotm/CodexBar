#!/usr/bin/env python3
"""仅发布已经构建并验签的当前 fork 产物, 不覆盖已有标签"""

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import xml.etree.ElementTree as ET

REPOSITORY = "yatotm/CodexBar"


def api(path, payload=None, method=None, optional=False):
    command = ["gh", "api", "repos/" + REPOSITORY + "/" + path]
    if payload is not None:
        command += ["--method", method or "POST", "--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True)
    if result.returncode:
        if optional and "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def publish(directory, tag, commit):
    if os.environ.get("GITHUB_REPOSITORY", REPOSITORY) != REPOSITORY:
        raise ValueError("发布仓库不匹配")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("标签或提交格式无效")
    version = tag[1:]
    files = [directory / f"CodexBar-{tag}.zip", directory / f"CodexBar-{tag}.dmg", directory / "appcast.xml", directory / "SHA256SUMS.txt"]
    if not all(path.is_file() and path.stat().st_size > 0 for path in files):
        raise ValueError("发布附件不完整")
    config = pathlib.Path("Config/Version.xcconfig").read_text()
    if re.search(r"^MARKETING_VERSION\s*=\s*" + re.escape(version) + r"\s*$", config, re.M) is None:
        raise ValueError("标签与版本配置不一致")
    notes = pathlib.Path("ReleaseNotes", tag + ".md").read_text()
    feed = ET.parse(directory / "appcast.xml")
    namespace = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    item = feed.find("./channel/item")
    build = re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*(\d+)\s*$", config, re.M)
    if (item is None or build is None
            or item.findtext("sparkle:shortVersionString", namespaces=namespace) != version
            or item.findtext("sparkle:version", namespaces=namespace) != build.group(1)):
        raise ValueError("更新源与版本配置不一致")
    enclosure = item.find("enclosure")
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{files[0].name}"
    if (enclosure is None or enclosure.get("url") != expected_url
            or enclosure.get("length") != str(files[0].stat().st_size)):
        raise ValueError("更新源与安装包不一致")
    expected_checksums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in files[:3])
    if files[3].read_text() != expected_checksums:
        raise ValueError("发布附件校验失败")
    latest = api("releases/latest", optional=True)
    if latest and re.fullmatch(r"v\d+\.\d+\.\d+", latest["tag_name"]):
        current = tuple(map(int, version.split(".")))
        previous = tuple(map(int, latest["tag_name"][1:].split(".")))
        if current < previous:
            raise ValueError("不能把较旧版本发布为最新更新")
    existing = api("git/ref/tags/" + tag, optional=True)
    if existing:
        obj = existing["object"]
        while obj["type"] == "tag":
            obj = api("git/tags/" + obj["sha"])["object"]
        if obj["sha"] != commit:
            raise ValueError("已有标签指向其他提交, 不允许覆盖")
    else:
        annotated = api("git/tags", {"tag": tag, "message": "Release " + tag, "object": commit, "type": "commit"})
        api("git/refs", {"ref": "refs/tags/" + tag, "sha": annotated["sha"]})
    release = api("releases/tags/" + tag, optional=True)
    if release and not release["draft"]:
        names = {asset["name"] for asset in release["assets"]}
        if {path.name for path in files} <= names:
            print("Release already published; immutable assets retained")
            return
        raise ValueError("已有公开 Release 附件不完整, 请人工核对后处理")
    if release is None:
        release = api("releases", {"tag_name": tag, "name": "CodexBar " + version, "body": notes, "draft": True, "prerelease": False})
    subprocess.run(["gh", "release", "upload", tag, "--repo", REPOSITORY, "--clobber", *map(str, files)], check=True)
    api("releases/" + str(release["id"]), {"draft": False, "make_latest": "true", "body": notes}, method="PATCH")
    print("Published https://github.com/" + REPOSITORY + "/releases/tag/" + tag)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=pathlib.Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    publish(args.directory.resolve(), args.tag, args.commit)
