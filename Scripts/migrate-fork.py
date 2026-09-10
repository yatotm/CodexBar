#!/usr/bin/env python3
"""在首次启动 fork 前复制旧数据, 默认仅预览, 不修改旧安装"""

import argparse
from contextlib import closing
import fcntl
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile

OLD_ID = "app.zabrian.codexbar"
NEW_ID = "io.github.yatotm.codexbar"
DIRECTORIES = ("HookEvents", "ActivityProtection", "UsageCenter", "UsageAnalytics", "UsageQuotaHistory")


def read_preferences(domain):
    result = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
    if result.returncode:
        raise RuntimeError(f"无法读取设置域 {domain}, 请确认旧版类型")
    values = plistlib.loads(result.stdout)
    if not values:
        raise RuntimeError(f"设置域 {domain} 为空, 请确认旧版类型")
    return values


def migrated_preferences(values):
    # 新 Helper 和 CloudKit 需要重新启用, 不继承旧安装的授权与运行状态
    result = {key: value for key, value in values.items()
              if not key.startswith(("SU", "NSWindow", "NSStatusItem", "Helper", "AppProcessDiagnostics", "WorkflowSync.", "KeepAlive.helper"))}
    for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate"):
        if key in values:
            result[key] = values[key]
    for key in ("AutoReset.enabled", "KeepAlive.isEnabled", "WorkflowSync.isEnabled"):
        result[key] = False
    return result


def copy_data(source, target):
    if source.is_symlink():
        return
    if source.is_dir():
        target.mkdir(mode=0o700, parents=True, exist_ok=True)
        for child in source.iterdir():
            if child.name == "Sync" or child.name.endswith((".lock", "-wal", "-shm")):
                continue
            copy_data(child, target / child.name)
    elif source.suffix == ".sqlite":
        with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as old:
            with closing(sqlite3.connect(target)) as new:
                old.backup(new)
        target.chmod(0o600)
    elif source.is_file():
        shutil.copyfile(source, target)
        target.chmod(0o600)


def migrate(home, source_kind, target_kind, apply=False):
    source_id = OLD_ID + (".debug" if source_kind == "debug" else "")
    target_id = NEW_ID + (".debug" if target_kind == "debug" else "")
    source = home / "Library/Application Support/CodexBar"
    target = source.with_name("CodexBar-yatotm")
    values = migrated_preferences(read_preferences(source_id))
    existing = subprocess.run(["defaults", "export", target_id, "-"], capture_output=True)
    if (existing.returncode == 0 and plistlib.loads(existing.stdout)) or target.exists():
        raise RuntimeError("fork 已有设置或数据, 为避免覆盖, 本工具仅支持首次迁移")
    print(f"设置: {source_id} -> {target_id}")
    print("数据: CodexBar -> CodexBar-yatotm, 旧文件保留")
    print("不复制旧云端游标或钥匙串令牌, Helper 与 iCloud 需重新启用")
    if not apply:
        print("仅预览, 使用 --apply 执行")
        return
    if subprocess.run(["pgrep", "-x", "CodexBar"], stdout=subprocess.DEVNULL).returncode == 0:
        raise RuntimeError("请先退出旧版和 fork, 再执行迁移")
    os.umask(0o077)
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".codexbar-migration-", dir=target.parent) as directory:
        stage = Path(directory) / target.name
        stage.mkdir(mode=0o700)
        for name in DIRECTORIES:
            if (source / name).exists():
                copy_data(source / name, stage / name)
        report = {"sourceDomain": source_id, "targetDomain": target_id,
                  "migratedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        (stage / "migration.json").write_text(json.dumps(report, indent=2) + "\n")
        subprocess.run(["defaults", "import", target_id, "-"], input=plistlib.dumps(values), check=True, stdout=subprocess.DEVNULL)
        try:
            stage.rename(target)
        except OSError:
            subprocess.run(["defaults", "delete", target_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            raise
    print("迁移完成, 可以启动 fork")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="source_kind", choices=("debug", "release"), required=True)
    parser.add_argument("--to", dest="target_kind", choices=("debug", "release"), default="release")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        if args.apply:
            os.umask(0o077)
            lock_path = Path.home() / "Library/Application Support/.codexbar-yatotm-migration.lock"
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            with lock_path.open("a+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                migrate(Path.home(), args.source_kind, args.target_kind, True)
        else:
            migrate(Path.home(), args.source_kind, args.target_kind)
    except (RuntimeError, OSError, sqlite3.Error, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")
