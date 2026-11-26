#!/usr/bin/env python3
"""将已确认的探针节点关联到同一账号原已选用的 SSH 历史, 默认仅预览"""

import argparse
from contextlib import closing
import json
from pathlib import Path
import plistlib
import re
import sqlite3
import subprocess


def read_source(database, identifier, transport):
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as connection:
        row = connection.execute("SELECT payload FROM sources WHERE id=?", (identifier,)).fetchone()
    source = json.loads(row[0]) if row else {}
    if source.get("transport") != transport or source.get("id") != identifier or not source.get("includesCodex"):
        raise ValueError(f"找不到已配置 Codex 的 {transport} 设备 {identifier}")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old_id", help="旧 SSH 设备 ID")
    parser.add_argument("node_id", help="已确认对应同一台机器的探针节点 ID")
    parser.add_argument("--account", help="多个账号都选过旧设备时, 指定其中一个账号的本地哈希")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    domain = "io.github.yatotm.codexbar"
    root = Path.home() / "Library/Application Support/CodexBar-yatotm/UsageCenter"
    old = read_source(root / "center-v1.backup.sqlite", args.old_id, "ssh")
    node = read_source(root / "center-v1.sqlite", args.node_id, "probe")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", old.get("address", "")):
        raise ValueError("旧设备没有有效的 SSH 别名")
    prefs = plistlib.loads(subprocess.check_output(["defaults", "export", domain, "-"]))
    prefix = "UsageAnalytics.historySources."
    accounts = [k[len(prefix):] for k, ids in prefs.items() if k.startswith(prefix) and args.old_id in ids
                and re.fullmatch("[0-9a-f]{64}", k[len(prefix):])]
    if args.account:
        accounts = [key for key in accounts if key == args.account]
    if len(accounts) != 1:
        raise ValueError("需有一个明确选过旧设备的账号, 多个账号时请用 --account 指定")
    key = "UsageAnalytics.historyLinks." + accounts[0]
    entries = {node_id: json.loads(value) for node_id, value in prefs.get(key, {}).items()}
    if any(node_id != args.node_id and source["id"] == args.old_id for node_id, source in entries.items()):
        raise ValueError("旧设备已关联其他探针")
    fields = ("id", "name", "transport", "address", "codexHome", "claudeHome", "collectorCacheDirectory")
    source = {field: old[field] for field in fields if field in old}
    if args.node_id in entries and entries[args.node_id] != source:
        raise ValueError("目标节点已有不同的历史关联")
    print(f"{node['name']} ({args.node_id}) ← {old['address']} ({args.old_id})")
    if args.apply:
        value = plistlib.dumps(json.dumps(source, ensure_ascii=False, separators=(",", ":"))).decode()
        subprocess.run(["defaults", "write", domain, key, "-dict-add", args.node_id,
                        value], check=True)
    else:
        print("仅预览, 确认设备身份后使用 --apply")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, sqlite3.Error, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
