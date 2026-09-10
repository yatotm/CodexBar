#!/usr/bin/env python3
"""安装独立的 systemd 定时采集任务, 复用原有统计数据库"""

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import pwd
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
MARKER = "# 由 CodexBar 统计定时任务安装器管理\n"
SERVICE = "codexbar-usage.service"
TIMER = "codexbar-usage.timer"


def quote(value, command=False):
    value = str(value)
    if any(ord(char) < 32 for char in value):
        raise ValueError("路径不能包含控制字符")
    value = value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%")
    if command:
        value = value.replace("$", "$$")
    return '"' + value + '"'


def units(config):
    state = config["stateDirectory"]
    command = ["/usr/bin/python3", config["script"], "collect", "--quiet", "--budget", "60",
               "--state-dir", state, "--codex-home", config["codexHome"],
               "--claude-home", config["claudeHome"], "--providers", config["providers"]]
    write_paths = quote(state)
    if "claude" in config["providers"].split(","):
        write_paths += " " + quote("-" + config["claudeHome"] + "/codexbar-usage/signals")
    hidden = [config["home"] + "/.ssh", config["codexHome"] + "/auth.json",
              config["claudeHome"] + "/.credentials.json"]
    service = MARKER + "\n".join([
        "[Unit]", "Description=CodexBar local usage collection", "",
        "[Service]", "Type=oneshot", "User=" + config["user"],
        "Environment=PYTHONDONTWRITEBYTECODE=1", "UMask=0077",
        "ExecStart=" + " ".join(quote(arg, command=True) for arg in command),
        "TimeoutStartSec=75", "Nice=10", "IOSchedulingClass=idle", "MemoryMax=256M",
        "NoNewPrivileges=yes", "PrivateTmp=yes", "PrivateNetwork=yes",
        "RestrictAddressFamilies=AF_UNIX", "ProtectSystem=strict", "ProtectHome=read-only",
        "CapabilityBoundingSet=", "ReadWritePaths=" + write_paths,
        "InaccessiblePaths=" + " ".join(quote("-" + path) for path in hidden),
        "StandardOutput=null", "StandardError=journal", ""
    ])
    timer = MARKER + "\n".join([
        "[Unit]", "Description=Collect CodexBar usage every five minutes", "",
        "[Timer]", "OnCalendar=*:0/5", "AccuracySec=30s", "Persistent=true", "Unit=" + SERVICE,
        "", "[Install]", "WantedBy=timers.target", ""
    ])
    return {SERVICE: service, TIMER: timer}


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def load_collector():
    path = pathlib.Path(__file__).resolve().parents[1] / "CodexBar/Resources/UsageCollector.py"
    spec = importlib.util.spec_from_file_location("UsageCollector", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return path, module


def configured_path(value, home, default):
    path = str(value) if value else str(home / default)
    if path.startswith("~/"):
        path = str(home / path[2:])
    result = pathlib.Path(path)
    if not result.is_absolute():
        raise ValueError("采集目录必须为绝对路径")
    return result.resolve()


def ensure_managed(paths):
    for path in paths:
        if path.is_symlink() or (path.exists() and not path.read_text().startswith(MARKER)):
            raise ValueError("存在非本程序管理的同名单元, 已停止安装")


def main():
    parser = argparse.ArgumentParser(description="安装或移除 CodexBar 五分钟定时任务")
    parser.add_argument("--user", default=os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name)
    parser.add_argument("--providers", choices=("codex", "claude", "codex,claude"), default="codex")
    parser.add_argument("--codex-home")
    parser.add_argument("--claude-home")
    parser.add_argument("--state-dir")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    if sys.platform != "linux" or os.geteuid() != 0:
        raise ValueError("安装系统定时任务需要在 Linux 上以 root 执行, 可用 --user 指定日志拥有者")
    account = pwd.getpwnam(args.user)
    if not account.pw_name.replace("-", "").replace("_", "").isalnum():
        raise ValueError("不支持的用户名")
    root = pathlib.Path("/etc/systemd/system")
    unit_paths = [root / name for name in (SERVICE, TIMER)]
    ensure_managed(unit_paths)
    if args.uninstall:
        run("systemctl", "disable", "--now", TIMER)
        run("systemctl", "stop", SERVICE)
        for path in unit_paths:
            path.unlink(missing_ok=True)
        run("systemctl", "daemon-reload")
        print(json.dumps({"status": "removed", "dataPreserved": True}))
        return
    source, collector = load_collector()
    home = pathlib.Path(account.pw_dir)
    code_dir = home / ".local/share/codexbar-usage"
    manifest_path = code_dir / "timer-installation.json"
    script = code_dir / "collector.py"
    codex = configured_path(args.codex_home, home, ".codex")
    claude = configured_path(args.claude_home, home, ".claude")
    default_state = home / ".local/state/codexbar-usage/sources" / collector.digest(str(codex), str(claude))
    state = configured_path(args.state_dir, home, str(default_state))
    config = {"user": account.pw_name, "home": str(home), "providers": args.providers,
              "codexHome": str(codex), "claudeHome": str(claude), "stateDirectory": str(state), "script": str(script)}
    if script.is_symlink() or (script.exists() and not manifest_path.exists()):
        raise ValueError("已有同名采集器不属于此安装器, 已保留原文件")
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text())
        if any(previous.get(key) != config[key] for key in ("user", "stateDirectory", "codexHome", "claudeHome")):
            raise ValueError("现有安装的数据目录或用户不同, 请先确认兼容方案")
    for directory in (code_dir, state):
        if not directory.exists():
            directory.mkdir(parents=True, mode=0o700)
            os.chown(directory, account.pw_uid, account.pw_gid)
        if directory.stat().st_uid != account.pw_uid:
            raise ValueError("安装目录与日志用户不一致, 已停止安装")
    collector.atomic_write(script, source.read_bytes())
    os.chown(script, account.pw_uid, account.pw_gid)
    config["scriptSHA256"] = hashlib.sha256(source.read_bytes()).hexdigest()
    collector.atomic_write(manifest_path, json.dumps(config, indent=2).encode())
    os.chown(manifest_path, account.pw_uid, account.pw_gid)
    rendered = units(config)
    with tempfile.TemporaryDirectory(prefix="codexbar-unit-check-") as temporary:
        staged = []
        for name, content in rendered.items():
            path = pathlib.Path(temporary) / name
            path.write_text(content)
            staged.append(str(path))
        run("systemd-analyze", "verify", *staged)
    for name, content in rendered.items():
        collector.atomic_write(root / name, content.encode())
        os.chmod(root / name, 0o644)
    run("systemctl", "daemon-reload")
    run("systemctl", "enable", "--now", TIMER)
    try:
        run("systemctl", "start", SERVICE)
    except subprocess.CalledProcessError:
        run("systemctl", "disable", "--now", TIMER)
        raise
    print(json.dumps({"status": "installed", "stateDirectory": str(state), "timer": TIMER}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr.strip() or "systemd 操作失败, 请检查服务状态", file=sys.stderr)
        else:
            print(str(error), file=sys.stderr)
        sys.exit(1)
