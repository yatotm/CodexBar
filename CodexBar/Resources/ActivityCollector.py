#!/usr/bin/env python3
"""本地 Hook 状态与 SSH 实时快照, 不读取对话内容或访问模型服务"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

SCHEMA = 1
EVENTS = ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
          "PostToolUse", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact")
LIMIT = 512 * 1024


def events_for(provider):
    return EVENTS + (("PostToolUseFailure",) if provider == "claude" else ())


def directory():
    return Path.home() / ".local/state/codexbar-activity"


def connect(root):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(root / "activity.notify", os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(descriptor)
    db = sqlite3.connect(root / "activity-v1.sqlite", timeout=0.3)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS meta(epoch TEXT, revision INTEGER)")
    db.execute("INSERT INTO meta(epoch,revision) SELECT ?,0 WHERE NOT EXISTS(SELECT 1 FROM meta)", (uuid.uuid4().hex,))
    db.execute("CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, provider TEXT, state TEXT, "
               "project TEXT, updated REAL, started REAL, pid INTEGER, birth TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS models(id TEXT PRIMARY KEY, model TEXT, updated REAL)")
    db.execute("CREATE TABLE IF NOT EXISTS details(id TEXT PRIMARY KEY, payload TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS agents(parent TEXT, agent TEXT, PRIMARY KEY(parent,agent))")
    db.commit()
    return db


def process_identity(pid):
    if sys.platform == "darwin":
        try:
            result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid=", "-o", "lstart="],
                                    capture_output=True, text=True, timeout=0.5, check=True)
            parent, birth = result.stdout.strip().split(None, 1)
            return int(parent), birth
        except (OSError, ValueError, subprocess.SubprocessError):
            return None
    try:
        # comm 允许空格和括号, 从最后一个右括号切开
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return int(fields[1]), fields[19]
    except (OSError, ValueError, IndexError):
        return None


def parent_identity(provider):
    pid = os.getppid()
    for _ in range(12):
        identity = process_identity(pid)
        if not identity:
            break
        try:
            if sys.platform == "darwin":
                result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                                        capture_output=True, timeout=0.5, check=True)
                args = [result.stdout.strip()]
            else:
                args = Path(f"/proc/{pid}/cmdline").read_bytes()[:4096].split(b"\0")
            names = [Path(os.fsdecode(arg)).name for arg in args[:3]]
            paths = [os.fsdecode(arg) for arg in args[:3]]
            native_claude = provider == "claude" and any("/claude/versions/" in path or "/@anthropic-ai/claude-code/" in path for path in paths)
            if provider in names or native_claude:
                return pid, identity[1]
        except (OSError, subprocess.SubprocessError):
            pass
        pid = identity[0]
        if pid <= 1:
            break
    return 0, ""


def record(db, payload, provider, now=None):
    event = payload.get("hook_event_name")
    session = payload.get("session_id")
    if event not in events_for(provider) or not isinstance(session, str) or not 0 < len(session) <= 512:
        return
    task_id = hashlib.sha256((provider + "\0" + session).encode()).hexdigest()
    now = time.time() if now is None else now
    model = model_name(payload, provider)
    if model:
        with db:
            db.execute("INSERT OR REPLACE INTO models VALUES(?,?,?)", (task_id, model, now))
            db.execute("DELETE FROM models WHERE updated<?", (now - 86400,))
    # 会话启动只记录模型, 不代表已有任务运行
    if event == "SessionStart":
        return
    state = {"PermissionRequest": "waiting", "Stop": "completed", "SessionEnd": "ended"}.get(event, "running")
    cwd = payload.get("cwd", "")
    project = Path(cwd).name[:100] if isinstance(cwd, str) else ""
    project = "".join(char for char in project if char.isprintable())
    pid, birth = parent_identity(provider)
    with db:
        previous = db.execute("SELECT state,started,pid,birth FROM tasks WHERE id=?", (task_id,)).fetchone()
        if event in ("SubagentStart", "SubagentStop"):
            if not previous or previous[0] not in ("running", "waiting", "unknown"):
                return
            state = previous[0]
        started = previous[1] if previous and previous[0] in ("running", "waiting") and event != "UserPromptSubmit" else now
        if previous and not pid:
            pid, birth = previous[2:]
        db.execute("INSERT OR REPLACE INTO tasks VALUES(?,?,?,?,?,?,?,?)",
                   (task_id, provider, state, project, now, started, pid, birth))
        record_details(db, task_id, payload, event, now)
        db.execute("UPDATE meta SET revision=revision+1")
        db.execute("DELETE FROM tasks WHERE updated<?", (now - 86400,))
        db.execute("DELETE FROM tasks WHERE id NOT IN (SELECT id FROM tasks ORDER BY updated DESC LIMIT 500)")
        db.execute("DELETE FROM details WHERE id NOT IN (SELECT id FROM tasks)")
        db.execute("DELETE FROM agents WHERE parent NOT IN (SELECT id FROM tasks)")
    # WAL 写事件可能早于事务提交, 提交后单独发信号才不会读到旧快照后永久漏更
    root = Path(db.execute("PRAGMA database_list").fetchone()[2]).parent
    descriptor = os.open(root / "activity.notify", os.O_WRONLY)
    try:
        os.write(descriptor, b"1")
    finally:
        os.close(descriptor)


def record_details(db, task_id, payload, event, now):
    previous = db.execute("SELECT payload FROM details WHERE id=?", (task_id,)).fetchone()
    details = json.loads(previous[0]) if previous else {}
    tool = payload.get("tool_name")
    if not (event in ("SubagentStart", "SubagentStop") and details.get("eventName") == "PermissionRequest"):
        details["eventName"] = event
        details["toolName"] = tool if isinstance(tool, str) and 0 < len(tool) <= 120 and tool.isprintable() else None
    details["observedAt"] = now
    if event == "UserPromptSubmit":
        db.execute("DELETE FROM agents WHERE parent=?", (task_id,))
        details["activeSubagentCount"] = 0
    agent = payload.get("agent_id")
    if isinstance(agent, str) and 0 < len(agent) <= 512:
        agent_key = hashlib.sha256(agent.encode()).hexdigest()
        if event == "SubagentStart":
            count = db.execute("SELECT COUNT(*) FROM agents WHERE parent=?", (task_id,)).fetchone()[0]
            if count < 1000:
                db.execute("INSERT OR IGNORE INTO agents VALUES(?,?)", (task_id, agent_key))
        elif event == "SubagentStop":
            db.execute("DELETE FROM agents WHERE parent=? AND agent=?", (task_id, agent_key))
    if event in ("Stop", "SessionEnd"):
        db.execute("DELETE FROM agents WHERE parent=?", (task_id,))
    if details.get("activeSubagentCount") is not None:
        details["activeSubagentCount"] = db.execute("SELECT COUNT(*) FROM agents WHERE parent=?", (task_id,)).fetchone()[0]
    db.execute("INSERT OR REPLACE INTO details VALUES(?,?)", (task_id, json.dumps(details)))


def reconcile(db):
    now = time.time()
    with db:
        for task_id, pid, birth, updated in db.execute(
                "SELECT id,pid,birth,updated FROM tasks WHERE state IN ('running','waiting')").fetchall():
            identity = process_identity(pid) if pid else None
            # 消失的进程只标记失联, 不伪造任务完成
            if (pid and (not identity or identity[1] != birth)) or (not pid and now - updated > 600):
                db.execute("UPDATE tasks SET state='unknown' WHERE id=?", (task_id,))
                db.execute("UPDATE meta SET revision=revision+1")


def snapshot(db):
    with db:
        db.execute("BEGIN")
        epoch, revision = db.execute("SELECT epoch,revision FROM meta").fetchone()
        rows = db.execute("SELECT t.id,t.provider,t.state,t.project,t.updated,t.started,m.model,d.payload "
                          "FROM tasks t LEFT JOIN models m ON m.id=t.id LEFT JOIN details d ON d.id=t.id ORDER BY t.updated DESC LIMIT 500").fetchall()
    return dict(schema=SCHEMA, epoch=epoch, revision=revision, sentAt=time.time(),
                tasks=[{**dict(zip(("id", "provider", "state", "project", "updatedAt", "startedAt", "modelName"), row[:7])),
                        **current_details(row[7], row[4])} for row in rows])


def current_details(payload, updated):
    if not payload:
        return {}
    details = json.loads(payload)
    # 旧采集器仍能写原任务表, 附加字段只在同一笔更新时有效
    if details.get("observedAt") != updated:
        return {}
    return {key: details[key] for key in ("eventName", "toolName", "activeSubagentCount") if key in details}


def model_name(payload, provider):
    def valid(value):
        return value if isinstance(value, str) and 0 < len(value) <= 100 and value.isprintable() else None
    model = valid(payload.get("model"))
    if model:
        return model
    transcript = payload.get("transcript_path")
    if not isinstance(transcript, str):
        return None
    home = Path(os.environ.get("CODEX_HOME" if provider == "codex" else "CLAUDE_CONFIG_DIR", str(Path.home() / ("." + provider)))).expanduser().resolve()
    path = Path(transcript).expanduser().resolve()
    folders = ("sessions", "archived_sessions") if provider == "codex" else ("projects",)
    if not any(path.is_relative_to(home / folder) for folder in folders):
        return None
    try:
        # 只从有界尾部提取模型标识, 对话与工具内容不保存也不传输
        with path.open("rb") as source:
            size = source.seek(0, os.SEEK_END)
            source.seek(max(0, size - 131072))
            if size > 131072:
                source.readline(131072)
            lines = source.read(131072).splitlines()
        for line in reversed(lines[-100:]):
            try:
                value = json.loads(line)
                detail = value.get("payload") if value.get("type") == "turn_context" else value.get("message") if value.get("type") == "assistant" else None
                if isinstance(detail, dict) and valid(detail.get("model")):
                    return detail["model"]
            except (ValueError, AttributeError):
                continue
    except OSError:
        pass
    return None


class ChangeWatcher:
    def __init__(self, root):
        self.queue = None
        self.files = []
        if sys.platform == "darwin":
            self.queue = select.kqueue()
            for name in ("activity.notify",):
                descriptor = os.open(root / name, os.O_RDONLY)
                self.files.append(descriptor)
                self.queue.control([select.kevent(descriptor, filter=select.KQ_FILTER_VNODE,
                                                  flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                                  fflags=select.KQ_NOTE_WRITE)], 0)
            self.descriptor = self.queue.fileno()
        else:
            libc = ctypes.CDLL(None, use_errno=True)
            self.descriptor = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
            if self.descriptor < 0:
                raise RuntimeError("实时采集需要 Linux inotify 或 macOS kqueue")
            if libc.inotify_add_watch(self.descriptor, os.fsencode(root / "activity.notify"), 0x00000002 | 0x00000008) < 0:
                os.close(self.descriptor)
                raise RuntimeError("无法监听实时状态目录")

    def drain(self):
        if self.queue:
            self.queue.control(None, 16, 0)
        else:
            os.read(self.descriptor, 65536)

    def close(self):
        if self.queue:
            self.queue.close()
        else:
            os.close(self.descriptor)
        for descriptor in self.files:
            os.close(descriptor)


def stream(root, db):
    watcher = ChangeWatcher(root)
    try:
        revision = None
        heartbeat = 0.0
        pending = b""
        while True:
            now = time.monotonic()
            if now >= heartbeat:
                reconcile(db)
            frame = snapshot(db)
            if frame["revision"] != revision or now >= heartbeat:
                data = json.dumps(frame, separators=(",", ":")).encode() + b"\n"
                if len(data) > LIMIT:
                    raise RuntimeError("实时快照超过大小限制")
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                revision = frame["revision"]
                heartbeat = now + 60
            ready, _, _ = select.select([watcher.descriptor, sys.stdin.fileno()], [], [], max(0, heartbeat - time.monotonic()))
            if watcher.descriptor in ready:
                watcher.drain()
            if sys.stdin.fileno() in ready:
                data = os.read(sys.stdin.fileno(), 4096)
                if not data:
                    return
                pending += data
                if len(pending) > 8192:
                    raise RuntimeError("无效确认帧")
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    ack = json.loads(line)
                    if ack.get("epoch") != frame["epoch"] or not isinstance(ack.get("ack"), int) or not 0 <= ack["ack"] <= revision:
                        raise RuntimeError("无效确认帧")
    finally:
        watcher.close()


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".codexbar-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class CodexRPC:
    def __init__(self, home):
        executable = shutil.which("codex")
        if not executable:
            raise RuntimeError("未找到远端 Codex CLI")
        self.process = subprocess.Popen([executable, "app-server", "--listen", "stdio://"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        env={**os.environ, "CODEX_HOME": str(home)})
        self.sequence = 0
        self.buffer = b""

    def request(self, method, params):
        self.sequence += 1
        self.process.stdin.write(json.dumps(dict(id=self.sequence, method=method, params=params)).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    break
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    break
                self.buffer += data
                if len(self.buffer) > 2 * 1024 * 1024:
                    raise RuntimeError("Codex 响应超过大小限制")
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            try:
                result = json.loads(line)
            except ValueError:
                continue
            if result.get("id") == self.sequence:
                if "error" in result:
                    raise RuntimeError("Codex 拒绝 Hook 配置请求")
                return result["result"]
        raise RuntimeError("Codex Hook 校验超时")

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def rewrite_hooks(document, command, install, provider="codex"):
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise RuntimeError("已有 Hook 配置格式无效, 未修改")
    for event in events_for(provider):
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            raise RuntimeError("已有 Hook 配置格式无效, 未修改")
        retained = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise RuntimeError("已有 Hook 配置格式无效, 未修改")
            if any(not isinstance(handler, dict) for handler in group["hooks"]):
                raise RuntimeError("已有 Hook 配置格式无效, 未修改")
            other = [handler for handler in group["hooks"] if not managed_command(handler.get("command"), command)]
            if other:
                retained.append({**group, "hooks": other})
        if install:
            retained.append({"hooks": [dict(type="command", command=command, timeout=3)]})
        if retained:
            hooks[event] = retained
        else:
            hooks.pop(event, None)


def managed_command(candidate, command):
    if not isinstance(candidate, str):
        return False
    try:
        # Python 小版本升级可能改变解释器路径, 归属按固定脚本路径与参数识别
        actual, expected = shlex.split(candidate), shlex.split(command)
        return actual == expected or (len(expected) > 2 and actual[1:] == expected[1:])
    except ValueError:
        return False


def configure(args):
    script = Path.home() / ".local/share/codexbar-usage/ActivityCollector.py"
    if args.action == "install":
        code = globals().get("CODEXBAR_SCRIPT_SOURCE") or Path(__file__).read_bytes()
        atomic_write(script, code)
    for provider in args.providers.split(","):
        home = Path(os.path.expanduser(getattr(args, provider + "_home") or os.environ.get(
            "CODEX_HOME" if provider == "codex" else "CLAUDE_CONFIG_DIR", str(Path.home() / ("." + provider)))))
        config = home / ("hooks.json" if provider == "codex" else "settings.json")
        command = " ".join(shlex.quote(word) for word in [sys.executable, str(script), "record", "--provider", provider])
        rpc = CodexRPC(home) if provider == "codex" else None
        try:
            if rpc:
                result = rpc.request("initialize", dict(clientInfo=dict(name="codex_bar", title="CodexBar", version="1.0.0")))
                match = re.match(r"[^/]+/(\d+)\.(\d+)\.(\d+)", result.get("userAgent", ""))
                if not match or tuple(map(int, match.groups())) < (0, 145, 0):
                    raise RuntimeError("实时 Hook 需要 Codex 0.145.0 或更新版本")
                rpc.process.stdin.write(b'{"method":"initialized"}\n')
                rpc.process.stdin.flush()
                features = rpc.request("config/read", {})["config"].get("features") or {}
                if args.action == "install" and features.get("hooks", features.get("codex_hooks")) is False:
                    raise RuntimeError("Codex 全局 Hook 已关闭, 请先在 Codex 中开启")
            original = config.read_bytes() if config.exists() else None
            document = json.loads(original) if original is not None else {}
            rewrite_hooks(document, command, args.action == "install", provider)
            updated = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode()
            # 写入前检查并发编辑, 备份仅属于本次配置
            if (config.read_bytes() if config.exists() else None) != original:
                raise RuntimeError("配置已被其他进程修改, 请重试")
            if original is not None:
                atomic_write(config.with_name(config.name + ".codexbar-activity-backup"), original)
            atomic_write(config, updated)
            if rpc and args.action == "install":
                result = rpc.request("hooks/list", dict(cwds=[str(Path.home())]))
                managed = [hook for entry in result["data"] for hook in entry["hooks"]
                           if hook.get("command") == command and hook.get("sourcePath") == str(config)]
                trust = {hook["key"]: {"trusted_hash": hook["currentHash"]} for hook in managed
                         if hook.get("key") and hook.get("currentHash")}
                if len(managed) != len(EVENTS) or len(trust) != len(EVENTS):
                    raise RuntimeError("Codex 未识别全部实时 Hook, 配置已保留供检查")
                rpc.request("config/batchWrite", dict(edits=[dict(keyPath="hooks.state", value=trust, mergeStrategy="upsert")]))
                verified = rpc.request("hooks/list", dict(cwds=[str(Path.home())]))
                installed = [hook for entry in verified["data"] for hook in entry["hooks"]
                             if hook.get("command") == command and hook.get("sourcePath") == str(config)]
                if len(installed) != len(EVENTS) or any(not hook.get("enabled") or hook.get("trustStatus") != "trusted" for hook in installed):
                    raise RuntimeError("Codex 实时 Hook 未通过信任校验")
        finally:
            if rpc:
                rpc.close()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("record", "stream", "install", "uninstall"))
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    parser.add_argument("--providers", default="codex")
    parser.add_argument("--codex-home", default="")
    parser.add_argument("--claude-home", default="")
    args = parser.parse_args()
    if set(args.providers.split(",")) - {"codex", "claude"}:
        parser.error("无效工具类型")
    if args.action in ("install", "uninstall"):
        configure(args)
        print('{"schema":1,"ok":true}')
        return
    db = connect(directory())
    try:
        if args.action == "record":
            data = sys.stdin.buffer.read(LIMIT + 1)
            if len(data) <= LIMIT:
                record(db, json.loads(data), args.provider)
        else:
            stream(directory(), db)
    finally:
        db.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        if len(sys.argv) > 1 and sys.argv[1] == "record":
            sys.exit(0)
        message = str(error) if isinstance(error, RuntimeError) else "实时采集配置或连接失败, 请检查 Codex 版本和 Hook 配置"
        print("CodexBar: " + message, file=sys.stderr)
        sys.exit(1)
