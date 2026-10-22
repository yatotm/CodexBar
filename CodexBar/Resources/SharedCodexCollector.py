#!/usr/bin/env python3
"""只观察本机 Codex 共享服务, 向现有实时协议输出去正文的任务元数据"""

import argparse
import base64
import ctypes
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import select
import shlex
import signal
import socket
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
MINIMUM_VERSION = (0, 162, 0)
MAX_MESSAGE = 8 * 1024 * 1024
MAX_FRAME = 512 * 1024
MAX_THREADS = 1000
MAX_TURNS = 4000
RETENTION = 86400
HISTORY_RETENTION = 210 * 86400
DATABASE = "shared-activity-v1.sqlite"
NOTIFY = "shared-activity.notify"
LABEL = "io.github.yatotm.codexbar.shared-codex"
SERVICE = "codexbar-shared-codex.service"
MARKER = "# Managed by CodexBar shared Codex collector\n"
TERMINAL = {"completed", "failed", "interrupted"}
TOOLS = {"commandExecution", "fileChange", "webSearch", "imageView", "imageGeneration",
         "sleep", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall"}
PROGRESS = {"item/agentMessage/delta": "replying", "item/reasoning/textDelta": "thinking",
            "item/reasoning/summaryTextDelta": "thinking", "item/commandExecution/outputDelta": "tool"}
APPROVALS = {"item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "item/permissions/requestApproval"}
TOKEN_NAMES = (("inputTokens", "input_tokens"), ("cachedInputTokens", "cached_input_tokens"),
               ("cacheWriteInputTokens", "cache_write_input_tokens"), ("outputTokens", "output_tokens"),
               ("reasoningOutputTokens", "reasoning_output_tokens"), ("totalTokens", "total_tokens"))


class CollectorError(Exception):
    """错误码只包含固定文本, 不把服务端正文传给日志"""


class RPCError(CollectorError):
    pass


def text(value, limit=512):
    return value if isinstance(value, str) and 0 < len(value) <= limit and all(c.isprintable() for c in value) else None


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None


def timestamp(value, fallback):
    value = number(value)
    return value if value is not None and 0 < value < 253402300800 else fallback


def digest(*values):
    return hashlib.sha256("\0".join(values).encode()).hexdigest()


def usage_digest(*values):
    return hashlib.sha256(json.dumps(values, separators=(",", ":")).encode()).hexdigest()


def encode(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def atomic_write(path, data):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".codexbar-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class WebSocket:
    """仅使用 Unix socket, 不支持 TCP 或控制共享服务进程"""

    def __init__(self, path, maximum=MAX_MESSAGE):
        self.maximum = maximum
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.buffer = bytearray()
        try:
            info = Path(path).stat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.geteuid():
                raise CollectorError("socket-owner-mismatch")
            self.socket.settimeout(3)
            self.socket.connect(str(path))
            key = base64.b64encode(os.urandom(16)).decode()
            request = ("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                       f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
            self.socket.sendall(request.encode())
            deadline = time.monotonic() + 5
            header = bytearray()
            while not header.endswith(b"\r\n\r\n"):
                if len(header) >= 16384:
                    raise CollectorError("invalid-handshake")
                header.extend(self.read(1, deadline))
            lines = header.decode("ascii").split("\r\n")
            fields = {}
            for line in lines[1:]:
                if ":" in line:
                    name, value = line.split(":", 1)
                    fields[name.lower()] = value.strip()
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            if (not lines[0].startswith("HTTP/1.1 101 ") or fields.get("sec-websocket-accept") != expected
                    or fields.get("upgrade", "").lower() != "websocket"
                    or "upgrade" not in [part.strip() for part in fields.get("connection", "").lower().split(",")]):
                raise CollectorError("invalid-handshake")
        except Exception:
            self.close()
            raise

    def close(self):
        self.socket.close()

    def read(self, count, deadline):
        while len(self.buffer) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CollectorError("socket-timeout")
            self.socket.settimeout(remaining)
            data = self.socket.recv(min(65536, max(1, count - len(self.buffer))))
            if not data:
                raise CollectorError("connection-closed")
            self.buffer.extend(data)
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def send(self, data, opcode=1):
        if len(data) > self.maximum:
            raise CollectorError("message-too-large")
        header = bytes([0x80 | opcode])
        size = len(data)
        if size < 126:
            header += bytes([0x80 | size])
        elif size <= 65535:
            header += b"\xfe" + struct.pack("!H", size)
        else:
            header += b"\xff" + struct.pack("!Q", size)
        mask = os.urandom(4)
        self.socket.settimeout(5)
        self.socket.sendall(header + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

    def receive(self, timeout=5):
        deadline = time.monotonic() + timeout
        if not self.buffer and not select.select([self.socket], [], [], max(0, timeout))[0]:
            return None
        # 一条帧和其控制帧共用截止时间, 防止分片无限拖住采集器
        frame_deadline = min(deadline + 10, time.monotonic() + 10)
        message = bytearray()
        fragmented = False
        while True:
            first, second = self.read(2, frame_deadline)
            opcode = first & 15
            final = bool(first & 128)
            length = second & 127
            if length in (126, 127):
                length = int.from_bytes(self.read(2 if length == 126 else 8, frame_deadline), "big")
            if first & 0x70 or second & 128 or length > (1 << 63) - 1:
                raise CollectorError("invalid-frame")
            if opcode >= 8:
                if opcode not in (8, 9, 10) or not final or length > 125:
                    raise CollectorError("invalid-control-frame")
            elif opcode != (0 if fragmented else 1):
                raise CollectorError("invalid-fragment")
            if opcode < 8 and len(message) + length > self.maximum:
                self.close()
                raise CollectorError("message-too-large")
            payload = self.read(length, frame_deadline)
            if opcode == 8:
                raise CollectorError("connection-closed")
            if opcode in (9, 10):
                if opcode == 9:
                    self.send(payload, 10)
                if not fragmented and not self.buffer:
                    if not select.select([self.socket], [], [], max(0, deadline - time.monotonic()))[0]:
                        return None
                continue
            message.extend(payload)
            if final:
                try:
                    result = json.loads(message)
                except (ValueError, UnicodeError, RecursionError) as error:
                    raise CollectorError("invalid-json") from error
                if not isinstance(result, dict):
                    raise CollectorError("invalid-envelope")
                return result
            fragmented = True


class RPC:
    def __init__(self, path, consume):
        self.transport = WebSocket(path)
        self.consume = consume
        self.sequence = 0

    def close(self):
        self.transport.close()

    def request(self, method, params=None):
        self.sequence += 1
        sequence = self.sequence
        self.transport.send(encode(dict(id=sequence, method=method, params=params or {})))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = self.transport.receive(max(0, deadline - time.monotonic()))
            if result is None:
                break
            if result.get("id") == sequence and ("result" in result or "error" in result):
                if "error" in result:
                    raise RPCError("rpc-rejected")
                if not isinstance(result.get("result"), dict):
                    raise CollectorError("invalid-result")
                return result["result"]
            # 服务端请求仅观察, 不发送批准或拒绝响应
            self.consume(result)
        raise CollectorError("rpc-timeout")

    def initialize(self):
        result = self.request("initialize", {"clientInfo": {"name": "codexbar_shared_collector", "version": "1.0"},
                                             "capabilities": {"experimentalApi": False}})
        agent = text(result.get("userAgent"), 1024) or ""
        match = re.match(r"[^ /]+/(\d+)\.(\d+)\.(\d+)(?:[ +.-]|$)", agent)
        if not match:
            raise CollectorError("unverified-server-version")
        version = tuple(int(part) for part in match.groups())
        if version < MINIMUM_VERSION:
            raise CollectorError("unsupported-server-version")
        self.transport.send(encode(dict(method="initialized")))
        return ".".join(map(str, version))


def usage(value):
    if not isinstance(value, dict):
        return None
    result = {}
    for wire, key in TOKEN_NAMES:
        number_value = value.get(wire, 0 if wire in ("cacheWriteInputTokens", "reasoningOutputTokens") else None)
        if type(number_value) is not int or not 0 <= number_value <= (1 << 63) - 1:
            return None
        result[key] = number_value
    if (result["input_tokens"] + result["output_tokens"] != result["total_tokens"]
            or result["cached_input_tokens"] + result["cache_write_input_tokens"] > result["input_tokens"]
            or result["reasoning_output_tokens"] > result["output_tokens"]):
        return None
    return result


def question_replies(item):
    opening, closing = "<send_user_message_question_reply>", "</send_user_message_question_reply>"
    contents = item.get("content")
    if not isinstance(contents, list) or len(contents) > 1000:
        return None
    result = None
    for content in contents:
        if not isinstance(content, dict) or content.get("type") != "text" or not isinstance(content.get("text"), str):
            continue
        value = content["text"].strip()
        if not value.startswith(opening) or not value.endswith(closing) or len(value) < len(opening) + len(closing):
            continue
        try:
            replies = json.loads(value[len(opening):-len(closing)])
            if not isinstance(replies, list) or len(replies) > 1000:
                continue
            parsed = []
            for reply in replies:
                if not isinstance(reply, dict) or not text(reply.get("questionItemId"), 4096):
                    break
                identity = json.loads(reply["questionItemId"])
                if not isinstance(identity, list) or len(identity) != 3 or identity[0] != "request_user_input_async" or not text(identity[1]):
                    break
                index = number(identity[2])
                if index is None or index < 0 or index != int(index):
                    break
                parsed.append((identity[1], int(index)))
            if len(parsed) == len(replies):
                result = (result or []) + parsed
        except (ValueError, TypeError, RecursionError):
            continue
    return result


class TaskGraph:
    def __init__(self):
        self.threads = {}
        self.turns = {}
        self.sequence = 0
        self.available = False
        self.loaded = set()
        self.tokens = {}
        self.positions = {}
        self.children = {}
        self.thread_revisions = {}
        self.events = {}
        self.last_prune = 0

    def metadata(self, value):
        if not isinstance(value, dict) or not text(value.get("id")):
            raise CollectorError("invalid-thread")
        key = value["id"]
        if key not in self.threads and len(self.threads) >= MAX_THREADS:
            raise CollectorError("thread-limit")
        old = self.threads.get(key, {})
        source = value.get("source")
        parent = text(value.get("parentThreadId"))
        origin = "main" if source in ("cli", "vscode", "exec", "appServer") else "unknown"
        if isinstance(source, dict):
            subagent = source.get("subAgent", source.get("subagent"))
            if isinstance(subagent, dict):
                spawned = subagent.get("thread_spawn", subagent.get("threadSpawn", {}))
                parent = parent or (text(spawned.get("parent_thread_id")) if isinstance(spawned, dict) else None)
                origin = "review" if subagent.get("other") == "guardian" else "child"
            elif "custom" in source:
                origin = "main"
        cwd = value.get("cwd")
        project = text(Path(cwd).name, 100) if isinstance(cwd, str) and len(cwd) < 16384 else None
        current = {"project": project or old.get("project", ""), "model": text(value.get("model"), 100) or old.get("model"),
                   "effort": text(value.get("reasoningEffort"), 40) or old.get("effort"),
                   "parent": parent or old.get("parent"), "origin": origin if source is not None else old.get("origin", origin),
                   "status": self.status(value.get("status")) if "status" in value else old.get("status", {})}
        if current != old:
            self.sequence += 1
            self.thread_revisions[key] = self.sequence
        self.threads[key] = current

    @staticmethod
    def status(value):
        if not isinstance(value, dict):
            return {}
        flags = value.get("activeFlags")
        return {"type": value.get("type") if value.get("type") in ("active", "idle", "notLoaded") else "unknown",
                "flags": [flag for flag in (flags if isinstance(flags, list) else []) if flag in ("waitingOnApproval", "waitingOnUserInput")]}

    def turn(self, thread, value, now, historical=False, checkpoint=None):
        if not isinstance(value, dict) or not text(value.get("id")):
            raise CollectorError("invalid-turn")
        if self.threads.get(thread, {}).get("origin") == "review":
            return None
        key = (thread, value["id"])
        previous = self.turns.get(key)
        was_terminal = previous is not None and previous["terminal"]
        if previous and checkpoint is not None and previous["revision"] > checkpoint:
            return previous
        state = value.get("status")
        if state not in TERMINAL | {"inProgress"}:
            return previous
        if historical and state in TERMINAL and previous is None and timestamp(value.get("completedAt"), None) is None:
            return None
        if previous and previous["terminal"] and state == "inProgress":
            return previous
        if not previous and len(self.turns) >= MAX_TURNS:
            self.prune(now, force=True)
            if len(self.turns) >= MAX_TURNS:
                raise CollectorError("turn-limit")
        started = timestamp(value.get("startedAt"), previous["started"] if previous else now)
        ended = timestamp(value.get("completedAt"), now) if state in TERMINAL else None
        self.sequence += 1
        node = previous or {"started": started, "updated": started, "stage": "processing", "items": {}, "requests": {},
                            "questions": {}, "planCompleted": None, "planTotal": None, "recentEvent": None,
                            "recentEventAt": None, "tool": None, "liveStart": not historical}
        node.update(status=state, terminal=state in TERMINAL, root=text(value.get("rootTurnId")) or node.get("root"),
                    revision=self.sequence, started=started, verified=True)
        if node["root"] is None and self.threads.get(thread, {}).get("origin") == "main" and not self.threads.get(thread, {}).get("parent"):
            node["root"] = value["id"]
        if ended is not None:
            node["updated"] = max(started, ended)
            node["historical"] = previous.get("historical", historical) if was_terminal else historical
            node["items"].clear()
            node["requests"].clear()
            node["questions"].clear()
        self.turns[key] = node
        return node

    def reconcile(self, thread, turns, now, checkpoint):
        for value in turns:
            node = self.turn(thread, value, now, historical=True, checkpoint=checkpoint)
            if node and not node["terminal"]:
                status = self.threads.get(thread, {}).get("status", {})
                node["verified"] = status.get("type") == "active" and value.get("status") == "inProgress"

    def current(self, thread):
        values = [(key, value) for key, value in self.turns.items() if key[0] == thread and not value["terminal"]]
        return max(values, key=lambda item: item[1]["started"])[0] if values else None

    def consume(self, envelope, now=None):
        now = time.time() if now is None else now
        if not isinstance(envelope, dict) or not isinstance(envelope.get("params"), dict):
            return
        method, params = envelope.get("method"), envelope["params"]
        if not isinstance(method, str):
            return
        if method == "serverRequest/resolved":
            request = text(str(params.get("requestId")))
            if request:
                for node in self.turns.values():
                    if node["requests"].pop(request, None) is not None:
                        self.progress(node, now, "request-ended")
            return
        raw_thread = params.get("thread")
        thread = text(params.get("threadId")) or (text(raw_thread.get("id")) if isinstance(raw_thread, dict) else None)
        if not thread:
            return
        if isinstance(raw_thread, dict):
            self.metadata(raw_thread)
        if thread not in self.threads:
            self.metadata(dict(id=thread))
        if self.threads[thread].get("origin") == "review":
            return
        if method == "thread/status/changed":
            status = self.status(params.get("status"))
            self.threads[thread]["status"] = status
            self.sequence += 1
            self.thread_revisions[thread] = self.sequence
            current = self.current(thread)
            if current:
                node = self.turns[current]
                node["revision"] = self.sequence
                if status.get("type") == "notLoaded":
                    node["verified"] = False
                if not status.get("flags"):
                    node["requests"] = {key: value for key, value in node["requests"].items() if value["blocking"] is False}
                if status.get("type") == "idle":
                    node["questions"].clear()
            return
        if method in ("turn/started", "turn/completed"):
            value = params.get("turn")
            self.turn(thread, value, now)
            if method == "turn/completed" and isinstance(value, dict) and value.get("status") == "interrupted":
                at = timestamp(value.get("completedAt"), now)
                self.record_event(thread, "sharedInterrupt", [value["id"]], at, now)
            return
        turn = text(params.get("turnId"))
        key = (thread, turn) if turn else self.current(thread)
        node = self.turns.get(key)
        if node is None:
            return
        if method == "thread/tokenUsage/updated":
            self.token_usage(key, params.get("tokenUsage"), now)
            return
        if node["terminal"]:
            return
        if method in PROGRESS:
            # 高速输出仅更新阶段和秒级进展, 不保存 delta 正文或逐 Token 写盘
            stage = PROGRESS[method]
            if node["stage"] != stage or now - node["updated"] >= 1:
                node["stage"] = stage
                self.progress(node, now)
        elif method in ("item/started", "item/completed"):
            self.item(key, params.get("item"), method == "item/started", now)
        elif method in APPROVALS or method in ("item/tool/requestUserInput", "mcpServer/elicitation/request"):
            if params.get("mode") == "openai/userVerification":
                return
            request = text(str(envelope.get("id"))) if "id" in envelope else None
            if not request:
                return
            blocking = True if method in APPROVALS else params.get("isBlocking") if type(params.get("isBlocking")) is bool else None
            if method == "mcpServer/elicitation/request":
                blocking = params.get("isBlocking") is not False
            node["requests"][request] = {"blocking": blocking, "approval": method in APPROVALS, "at": now}
            self.bound(node["requests"])
            self.progress(node, now)
            if method in APPROVALS:
                item_id = text(params.get("itemId"))
                approval_id = text(params.get("approvalId"))
                started = number(params.get("startedAtMs"))
                if item_id and (approval_id or (started is not None and started > 0)):
                    at = timestamp(started / 1000 if started is not None else None, now)
                    self.record_event(thread, "sharedPermission", [key[1], method, item_id, approval_id or format(float(started), ".6f")], at, now)
        elif method == "turn/plan/updated":
            plan = params.get("plan")
            if isinstance(plan, list) and len(plan) <= 1000 and all(isinstance(step, dict) for step in plan):
                node["planTotal"] = len(plan)
                node["planCompleted"] = sum(step.get("status") == "completed" for step in plan)
                self.progress(node, now, "plan-updated")
        elif method == "model/rerouted":
            self.threads[thread]["model"] = text(params.get("toModel"), 100) or self.threads[thread].get("model")
            self.progress(node, now, "model-changed")
        elif method == "error":
            if params.get("willRetry") is True:
                node["stage"] = "retrying"
            self.progress(node, now, "retrying" if params.get("willRetry") is True else "error")
        elif method in ("modelProvider/authRecoveryStarted", "modelProvider/authRecoveryCompleted", "model/safetyBuffering/updated"):
            node["stage"] = {"modelProvider/authRecoveryStarted": "recovering-auth",
                             "modelProvider/authRecoveryCompleted": "processing"}.get(method, "buffering" if params.get("showBufferingUi") is True else "processing")
            self.progress(node, now)
        self.prune(now)

    def record_event(self, thread, kind, identity, at, now):
        if not now - HISTORY_RETENTION <= at <= now + 60:
            return
        key = usage_digest("codex", kind, thread, identity)
        if key not in self.events and len(self.events) >= 4096:
            raise CollectorError("event-buffer-full")
        meta = self.threads.get(thread, {})
        record = {field: 0 for field in ("input", "output", "cacheRead", "cacheWrite", "reasoning", "turns",
                                       "tools", "permissions", "compactions", "subagents", "durationMs")}
        record.update(id=key, provider="codex", auth="unknown", kind=kind,
                      session=usage_digest("codex-session", thread), observedAt=at,
                      day=datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y-%m-%d"),
                      model=meta.get("model") or "未知", project=meta.get("project") or "未知",
                      state="interrupted" if kind == "sharedInterrupt" else "",
                      permissions=1 if kind == "sharedPermission" else 0)
        self.events[key] = record

    def progress(self, node, now, recent=None):
        self.sequence += 1
        node["revision"] = self.sequence
        node["updated"] = max(node["updated"], now)
        if recent:
            node["recentEvent"], node["recentEventAt"] = recent, now

    @staticmethod
    def bound(values):
        while len(values) > 128:
            del values[next(iter(values))]

    def item(self, key, item, starting, now):
        if not isinstance(item, dict) or not text(item.get("id")):
            return
        node = self.turns[key]
        kind, identifier = item.get("type"), item["id"]
        if kind == "subAgentActivity":
            child = text(item.get("agentThreadId"))
            if child and item.get("kind") == "started":
                self.metadata(dict(id=child, parentThreadId=key[0], model=item.get("model"), reasoningEffort=item.get("reasoningEffort")))
                self.children.setdefault(key, {})[child] = True
            elif child and item.get("kind") in ("completed", "interrupted"):
                self.children.setdefault(key, {})[child] = False
            if not starting and item.get("kind") in ("started", "completed", "interrupted"):
                self.progress(node, now, "agent-" + item["kind"])
        if kind == "agentMessage" and item.get("delivery") == "async":
            questions = item.get("questions")
            if isinstance(questions, list) and 0 < len(questions) <= 1000:
                node["questions"].setdefault(identifier, {"count": len(questions), "answered": set()})
                self.bound(node["questions"])
        if kind == "userMessage":
            # 正文仅在这里瞬时提取问题标识, 专用答复不能收起其他未回答的问题
            replies = question_replies(item)
            if replies is None:
                node["questions"].clear()
                node["requests"] = {key: value for key, value in node["requests"].items() if value["blocking"]}
            else:
                for question, index in replies:
                    pending = node["questions"].get(question)
                    if pending is not None and index < pending["count"]:
                        pending["answered"].add(index)
                        if len(pending["answered"]) == pending["count"]:
                            del node["questions"][question]
        if kind not in TOOLS | {"contextCompaction", "reasoning", "agentMessage"}:
            return
        stage = "tool" if kind in TOOLS else "compacting" if kind == "contextCompaction" else "thinking" if kind == "reasoning" else "answering" if item.get("phase") == "final_answer" else "replying"
        if starting:
            node["items"][identifier] = {"stage": stage, "tool": text(item.get("tool"), 120) or (kind if kind in TOOLS else None), "at": now}
            self.bound(node["items"])
            node["stage"], node["tool"] = stage, node["items"][identifier]["tool"]
        else:
            removed = node["items"].pop(identifier, None)
            if removed and node["stage"] == removed["stage"]:
                latest = max(node["items"].values(), key=lambda value: value["at"], default={"stage": "processing", "tool": None})
                node["stage"], node["tool"] = latest["stage"], latest["tool"]
            if kind in TOOLS:
                outcome = "tool-failed" if item.get("status") in ("failed", "declined") or item.get("success") is False else "tool-completed"
                agents = item.get("agentsStates")
                if kind == "collabAgentToolCall" and isinstance(agents, dict) and any(isinstance(value, dict) and value.get("status") == "errored" for value in agents.values()):
                    outcome = "agent-failed"
                self.progress(node, now, outcome)
        self.progress(node, now)

    def token_usage(self, key, payload, now):
        if not isinstance(payload, dict):
            return
        total, last = usage(payload.get("total")), usage(payload.get("last"))
        if total is None or last is None:
            return
        thread_key = digest("codex", key[0])
        turn_key = digest("codex", *key)
        position = self.positions.get(thread_key)
        previous = position.get("value") if position else None
        if previous and total["total_tokens"] <= previous["total_tokens"]:
            return
        covered = previous is not None and (position.get("turn") == turn_key or self.turns[key]["liveStart"])
        delta = {field: total[field] - previous[field] for field in total} if covered else last
        if any(value < 0 for value in delta.values()):
            return
        saved = self.tokens.get(turn_key, {"value": {field: 0 for field in total}, "complete": self.turns[key]["liveStart"]})
        result = {field: saved["value"][field] + delta[field] for field in total}
        if any(value > (1 << 63) - 1 for value in result.values()):
            return
        saved.update(value=result, at=now)
        self.tokens[turn_key] = saved
        self.positions[thread_key] = dict(value=total, turn=turn_key)
        self.progress(self.turns[key], now)

    def disconnected(self):
        self.available = False
        self.loaded.clear()
        for node in self.turns.values():
            if not node["terminal"]:
                node["verified"] = False
                node["requests"].clear()
                node["questions"].clear()
                node["items"].clear()
                node["stage"] = "unknown"

    def root_for(self, key):
        if self.threads.get(key[0], {}).get("origin") == "review":
            return None
        node = self.turns[key]
        root = node.get("root")
        if not root:
            return None
        current, ancestors = key[0], set()
        while current and current not in ancestors and len(ancestors) < 128:
            ancestors.add(current)
            current = self.threads.get(current, {}).get("parent")
        matches = [candidate for candidate in self.turns if candidate[1] == root and candidate[0] in ancestors]
        if len(matches) != 1:
            return None
        candidate = matches[0]
        metadata = self.threads.get(candidate[0], {})
        return candidate if metadata.get("origin") == "main" and not metadata.get("parent") else None

    def tasks(self, now=None):
        now = time.time() if now is None else now
        self.prune(now)
        groups = {}
        for key in self.turns:
            root = self.root_for(key)
            if root:
                groups.setdefault(root, []).append(key)
        result = []
        for root, members in groups.items():
            node, meta = self.turns[root], self.threads[root[0]]
            active = [self.turns[key] for key in members if not self.turns[key]["terminal"]]
            observed_children = {key[0] for key in members if key != root}
            pending_children = {child for child, running in self.children.get(root, {}).items()
                                if running and child not in observed_children and self.threads.get(child, {}).get("origin") != "review"}
            unknown = not self.available or any(not value["verified"] for value in active)
            waits = [value for value in active if any(request["blocking"] for request in value["requests"].values())]
            flags = [flag for key in members if not self.turns[key]["terminal"] for flag in self.threads[key[0]].get("status", {}).get("flags", [])]
            nonblocking = any(value["questions"] or any(request["blocking"] is False for request in value["requests"].values()) for value in active)
            waiting = bool(waits or "waitingOnApproval" in flags or ("waitingOnUserInput" in flags and not nonblocking))
            if active or pending_children:
                state = "unknown" if unknown else "waiting" if waiting else "running"
            else:
                state = "completed" if node["status"] == "completed" else "ended"
            current = max(active or [node], key=lambda value: value["updated"])
            child_count = len({key[0] for key in members if key != root and not self.turns[key]["terminal"]} | pending_children)
            pending = sum(len(value["requests"]) + sum(item["count"] - len(item["answered"]) for item in value["questions"].values()) for value in active)
            updated = max(self.turns[key]["updated"] for key in members)
            task = dict(id=digest("codex", *root), provider="codex", state=state, project=meta["project"],
                        startedAt=node["started"], updatedAt=max(node["started"], updated), modelName=meta.get("model"),
                        effort=meta.get("effort"), stage="unknown" if state == "unknown" else "waiting-approval" if "waitingOnApproval" in flags or any(request["approval"] for value in waits for request in value["requests"].values()) else "waiting-input" if waiting else "agent-waiting" if pending_children and not active else current["stage"],
                        toolName=current["tool"], activeSubagentCount=child_count,
                        eventName="PermissionRequest" if state == "waiting" else "SubagentStart" if child_count else "Stop" if state in ("completed", "ended") else "SharedProgress",
                        activeToolCount=sum(sum(item["stage"] == "tool" for item in value["items"].values()) for value in active),
                        pendingInputCount=pending, hasBlockingInputRequest=waiting,
                        planCompleted=node["planCompleted"], planTotal=node["planTotal"],
                        recentEvent=current["recentEvent"], recentEventAt=current["recentEventAt"],
                        isHistoricalTerminal=node.get("historical", False) if not active else False,
                        lifecycleComplete=not unknown and not pending_children and all(value["verified"] for value in active),
                        lastProgressAt=max(node["started"], updated),
                        protectionIdentifier=digest("CodexBar.ActivityProtection.v1", "turn", *root))
            token_values = [self.tokens.get(digest("codex", *key)) for key in members]
            complete = not pending_children and all(value and value["complete"] for value in token_values)
            if any(token_values):
                total = {field: sum(value["value"][field] for value in token_values if value) for _, field in TOKEN_NAMES}
                if all(value < (1 << 63) for value in total.values()):
                    task["tokenUsage"], task["tokenUsageComplete"] = total, complete
            result.append({key: value for key, value in task.items() if value is not None})
        return sorted(result, key=lambda task: (task["state"] in ("running", "waiting", "unknown"), task["updatedAt"]), reverse=True)[:500]

    def prune(self, now, force=False):
        if not self.available and not self.threads:
            return
        if not force and now - self.last_prune < 60:
            return
        self.last_prune = now
        keep = {key for key, node in self.turns.items() if node["updated"] >= now - RETENTION or (not node["terminal"] and key[0] in self.loaded)}
        keep.update(root for key in list(keep) if (root := self.root_for(key)) is not None)
        self.turns = {key: node for key, node in self.turns.items() if key in keep}
        retained = {key[0] for key in self.turns} | self.loaded
        self.threads = {key: value for key, value in self.threads.items() if key in retained}
        self.thread_revisions = {key: value for key, value in self.thread_revisions.items() if key in retained}
        self.tokens = {key: value for key, value in self.tokens.items() if value.get("at", 0) >= now - RETENTION}
        self.positions = {key: value for key, value in self.positions.items() if key in {digest("codex", thread) for thread in retained}}
        self.children = {key: value for key, value in self.children.items() if key in self.turns}


class StateStore:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, mode=0o700, exist_ok=True)
        if self.root.stat().st_uid != os.geteuid() or self.root.is_symlink():
            raise CollectorError("state-owner-mismatch")
        for name in (DATABASE, NOTIFY, "writer.lock"):
            if (self.root / name).is_symlink():
                raise CollectorError("state-symlink")
        self.lock = None
        self.db = sqlite3.connect(self.root / DATABASE, timeout=2)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA journal_size_limit=1048576")
        self.db.execute("CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL, saved REAL NOT NULL)")
        self.db.execute("CREATE TABLE IF NOT EXISTS counters(id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)")
        self.db.execute("CREATE TABLE IF NOT EXISTS history_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        self.db.execute("INSERT OR IGNORE INTO history_meta VALUES('epoch',?)", (uuid.uuid4().hex,))
        self.db.execute("CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, observed REAL NOT NULL, payload TEXT NOT NULL)")
        self.db.execute("CREATE INDEX IF NOT EXISTS events_observed ON events(observed)")
        self.db.commit()
        os.chmod(self.root / DATABASE, 0o600)
        descriptor = os.open(self.root / NOTIFY, os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(descriptor)

    def acquire(self):
        self.lock = os.open(self.root / "writer.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            os.close(self.lock)
            self.lock = None
            raise CollectorError("collector-already-running") from error

    def saved(self):
        row = self.db.execute("SELECT payload,saved FROM state WHERE id=1").fetchone()
        return (json.loads(row[0]), row[1]) if row else (None, 0)

    def restore(self, graph):
        row = self.db.execute("SELECT payload FROM counters WHERE id=1").fetchone()
        if row:
            value = json.loads(row[0])
            graph.tokens = value.get("tokens", {})
            graph.positions = value.get("positions", {})

    def history_home(self, codex_home):
        value = usage_digest("codex-home", str(Path(codex_home).expanduser().resolve()))
        previous = self.db.execute("SELECT value FROM history_meta WHERE key='codexHomeKey'").fetchone()
        if previous is not None and previous[0] != value:
            raise CollectorError("history-home-mismatch")
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO history_meta VALUES('codexHomeKey',?)", (value,))

    def save(self, graph, reason="", version=None, now=None):
        now = time.time() if now is None else now
        previous, saved_at = self.saved()
        tasks = graph.tasks(now)
        old_tasks = {task["id"]: task for task in (previous or {}).get("tasks", [])}
        for task in tasks:
            old = old_tasks.get(task["id"])
            task["stateChangedAt"] = old.get("stateChangedAt", old["updatedAt"]) if old and old["state"] == task["state"] else task["updatedAt"]
        identities = {task["id"] for task in tasks}
        for old in (previous or {}).get("tasks", []):
            if old["id"] not in identities and old["updatedAt"] >= now - RETENTION:
                old = dict(old)
                if old["state"] in ("running", "waiting"):
                    old.update(state="unknown", stage="unknown", hasBlockingInputRequest=False, lifecycleComplete=False)
                if old["state"] in ("completed", "ended"):
                    old["isHistoricalTerminal"] = True
                tasks.append(old)
        tasks.sort(key=lambda task: (task["state"] in ("running", "waiting", "unknown"), task["updatedAt"]), reverse=True)
        payload = dict(schema=1, epoch=previous["epoch"] if previous else uuid.uuid4().hex,
                       revision=previous["revision"] if previous else 0, sentAt=now, tasks=tasks[:500],
                       backend="sharedCodex", sourceAvailable=graph.available, sourceReason=reason, serverVersion=version)
        while len(encode(payload)) > MAX_FRAME - 128 and payload["tasks"]:
            payload["tasks"].pop()
            payload["tasksTruncated"] = True
        comparable = lambda value: {key: item for key, item in value.items() if key not in ("sentAt", "revision")}
        changed = previous is None or comparable(payload) != comparable(previous)
        if changed:
            payload["revision"] += 1
        if changed or now - saved_at >= 30 or graph.events:
            encoded = encode(payload)
            with self.db:
                self.db.execute("INSERT OR REPLACE INTO state VALUES(1,?,?)", (encoded.decode(), now))
                self.db.execute("INSERT OR REPLACE INTO counters VALUES(1,?)", (encode(dict(tokens=graph.tokens, positions=graph.positions)).decode(),))
                self.db.executemany("INSERT OR IGNORE INTO events(id,observed,payload) VALUES(?,?,?)",
                                    ((record["id"], record["observedAt"], encode(record).decode()) for record in graph.events.values()))
                self.db.execute("DELETE FROM events WHERE observed<?", (now - HISTORY_RETENTION,))
            graph.events.clear()
            if changed:
                with open(self.root / NOTIFY, "wb") as signal_file:
                    signal_file.write(str(payload["revision"]).encode())
        return payload

    def snapshot(self, now=None):
        now = time.time() if now is None else now
        value, saved = self.saved()
        if value is None:
            return dict(schema=1, epoch=digest(str(self.root))[:32], revision=0, sentAt=now, tasks=[],
                        backend="sharedCodex", sourceAvailable=False, sourceReason="collector-not-running")
        if now - saved > 75:
            value["sourceAvailable"], value["sourceReason"] = False, "collector-stale"
            for task in value["tasks"]:
                if task["state"] in ("running", "waiting"):
                    task.update(state="unknown", stage="unknown", hasBlockingInputRequest=False, lifecycleComplete=False)
        value["sentAt"] = now
        return value

    def close(self):
        self.db.close()
        if self.lock is not None:
            os.close(self.lock)


class Observer:
    def __init__(self, rpc, graph):
        self.rpc, self.graph = rpc, graph
        self.subscribed = set()
        self.checked = {}
        self.scans = {}

    def loaded_threads(self):
        loaded, cursors = set(), set()
        cursor = None
        for _ in range(10):
            params = dict(limit=100)
            if cursor:
                params["cursor"] = cursor
            result = self.rpc.request("thread/loaded/list", params)
            values = result.get("data")
            if not isinstance(values, list) or any(not text(value) for value in values):
                raise CollectorError("invalid-loaded-list")
            loaded.update(values)
            if len(loaded) > MAX_THREADS:
                raise CollectorError("thread-limit")
            cursor = result.get("nextCursor")
            if cursor is None:
                return loaded
            if not text(cursor, 4096) or cursor in cursors:
                raise CollectorError("invalid-cursor")
            cursors.add(cursor)
        raise CollectorError("loaded-list-truncated")

    def reconcile(self, force=False, now=None):
        now = time.time() if now is None else now
        loaded = self.loaded_threads()
        self.graph.loaded = loaded
        self.subscribed.intersection_update(loaded)
        active = {key[0] for key, node in self.graph.turns.items() if not node["terminal"]}
        parents = {meta["parent"] for meta in self.graph.threads.values() if meta.get("parent")}
        candidates = sorted(loaded | active | parents, key=lambda key: (self.checked.get(key, 0), key))
        deadline = time.monotonic() + (20 if force else 1)
        for identifier in candidates:
            if not force and now - self.checked.get(identifier, 0) < (5 if identifier in active else 60):
                continue
            checkpoint = self.graph.sequence
            try:
                read = self.rpc.request("thread/read", dict(threadId=identifier, includeTurns=False)).get("thread")
                if not isinstance(read, dict) or read.get("id") != identifier:
                    raise CollectorError("invalid-thread")
                if self.graph.thread_revisions.get(identifier, 0) <= checkpoint:
                    self.graph.metadata(read)
                if identifier in loaded and identifier not in self.subscribed and self.graph.threads[identifier]["status"].get("type") != "notLoaded":
                    # 只订阅刚确认已加载的会话, 绝不恢复历史会话或设置模型/审批策略
                    subscribed_revision = self.graph.thread_revisions.get(identifier, 0)
                    joined = self.rpc.request("thread/resume", dict(threadId=identifier, excludeTurns=True)).get("thread")
                    if not isinstance(joined, dict) or joined.get("id") != identifier:
                        raise CollectorError("invalid-thread")
                    if self.graph.thread_revisions.get(identifier, 0) == subscribed_revision:
                        self.graph.metadata(joined)
                    self.subscribed.add(identifier)
                page = self.rpc.request("thread/turns/list", dict(threadId=identifier, limit=10, itemsView="notLoaded"))
                turns = page.get("data")
                if not isinstance(turns, list) or len(turns) > 100:
                    raise CollectorError("invalid-turn-list")
                self.graph.reconcile(identifier, turns, now, checkpoint)
                targets = {key[1] for key, node in self.graph.turns.items() if key[0] == identifier and not node["terminal"]}
                targets.update(node["root"] for key, node in self.graph.turns.items()
                               if node.get("root") and self.graph.threads.get(key[0], {}).get("parent") == identifier)
                covered = {value.get("id") for value in turns if isinstance(value, dict)}
                missing = targets - covered
                cursor = self.scans.get(identifier, page.get("nextCursor")) if missing else None
                visited = set()
                for _ in range(4 if force else 1):
                    if not missing or cursor is None:
                        break
                    if not text(cursor, 4096) or cursor in visited:
                        raise CollectorError("invalid-turn-cursor")
                    visited.add(cursor)
                    checkpoint = self.graph.sequence
                    older = self.rpc.request("thread/turns/list", dict(threadId=identifier, limit=100, itemsView="notLoaded", cursor=cursor))
                    values = older.get("data")
                    if not isinstance(values, list) or len(values) > 100:
                        raise CollectorError("invalid-turn-list")
                    self.graph.reconcile(identifier, values, now, checkpoint)
                    missing.difference_update(value.get("id") for value in values if isinstance(value, dict))
                    next_cursor = older.get("nextCursor")
                    if next_cursor == cursor:
                        raise CollectorError("invalid-turn-cursor")
                    cursor = next_cursor
                if missing and cursor:
                    self.scans[identifier] = cursor
                else:
                    self.scans.pop(identifier, None)
            except RPCError:
                for key, node in self.graph.turns.items():
                    if key[0] == identifier and not node["terminal"]:
                        node["verified"] = False
                self.subscribed.discard(identifier)
            self.checked[identifier] = now
            if time.monotonic() >= deadline:
                break
        self.checked = {key: value for key, value in self.checked.items() if key in loaded | active | parents}
        self.scans = {key: value for key, value in self.scans.items() if key in self.checked}
        self.graph.available = True
        self.graph.prune(now)


class ChangeWatcher:
    def __init__(self, root):
        self.queue = None
        self.file = None
        if sys.platform == "darwin":
            self.queue = select.kqueue()
            self.file = os.open(Path(root) / NOTIFY, os.O_RDONLY)
            self.queue.control([select.kevent(self.file, filter=select.KQ_FILTER_VNODE,
                                              flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)], 0)
            self.descriptor = self.queue.fileno()
        elif sys.platform == "linux":
            libc = ctypes.CDLL(None, use_errno=True)
            self.descriptor = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
            if self.descriptor < 0:
                raise CollectorError("watcher-unavailable")
            if libc.inotify_add_watch(self.descriptor, os.fsencode(Path(root) / NOTIFY), 0x2 | 0x8) < 0:
                os.close(self.descriptor)
                raise CollectorError("watcher-unavailable")
        else:
            raise CollectorError("unsupported-platform")

    def drain(self):
        if self.queue:
            self.queue.control(None, 16, 0)
        else:
            os.read(self.descriptor, 65536)

    def close(self):
        if self.queue:
            self.queue.close()
            os.close(self.file)
        else:
            os.close(self.descriptor)


def stream(store):
    watcher = ChangeWatcher(store.root)
    pending = b""
    revision = None
    heartbeat = 0
    try:
        while True:
            value = store.snapshot()
            stamp = (value["epoch"], value["revision"], value["sourceAvailable"])
            if stamp != revision or time.monotonic() >= heartbeat:
                sys.stdout.buffer.write(encode(value) + b"\n")
                sys.stdout.buffer.flush()
                revision, heartbeat = stamp, time.monotonic() + 60
            _, saved_at = store.saved()
            lease_remaining = max(0, saved_at + 75 - time.time()) if value["sourceAvailable"] else 60
            delay = max(0, min(heartbeat - time.monotonic(), lease_remaining))
            ready, _, _ = select.select([watcher.descriptor, sys.stdin.fileno()], [], [], delay)
            if watcher.descriptor in ready:
                watcher.drain()
            if sys.stdin.fileno() in ready:
                received = os.read(sys.stdin.fileno(), 4096)
                if not received:
                    return
                pending += received
                if len(pending) > 8192:
                    raise CollectorError("invalid-ack")
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    ack = json.loads(line)
                    if (not isinstance(ack, dict) or ack.get("epoch") != value["epoch"]
                            or type(ack.get("ack")) is not int or not 0 <= ack["ack"] <= value["revision"]):
                        raise CollectorError("invalid-ack")
    finally:
        watcher.close()


def daemon(store, socket_path):
    store.acquire()
    store.history_home(Path(socket_path).parent.parent)
    graph = TaskGraph()
    store.restore(graph)
    store.save(graph, reason="collector-starting")
    stopped = False

    def stop(_signal, _frame):
        nonlocal stopped
        stopped = True

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, stop)
    retry = 3
    while not stopped:
        rpc = None
        try:
            rpc = RPC(socket_path, graph.consume)
            version = rpc.initialize()
            observer = Observer(rpc, graph)
            observer.reconcile(force=True)
            store.save(graph, version=version)
            retry = 3
            reconcile_at, heartbeat_at, save_at = time.monotonic() + 5, time.monotonic() + 30, float("inf")
            while not stopped:
                now = time.monotonic()
                event = rpc.transport.receive(max(0, min(reconcile_at, heartbeat_at, save_at) - now))
                if event:
                    before = graph.sequence
                    graph.consume(event)
                    if graph.sequence != before:
                        save_at = min(save_at, time.monotonic() + 0.5)
                now = time.monotonic()
                if now >= reconcile_at:
                    before = graph.sequence
                    observer.reconcile()
                    reconcile_at = time.monotonic() + 5
                    if graph.sequence != before:
                        save_at = min(save_at, time.monotonic() + 0.5)
                if now >= min(save_at, heartbeat_at):
                    store.save(graph, version=version)
                    save_at, heartbeat_at = float("inf"), time.monotonic() + 30
        except (OSError, CollectorError, ValueError, sqlite3.Error):
            graph.disconnected()
            error = sys.exc_info()[1]
            reason = str(error) if isinstance(error, CollectorError) else "socket-unavailable" if isinstance(error, OSError) else "collector-error"
            store.save(graph, reason=reason)
        finally:
            if rpc:
                rpc.close()
        deadline = time.monotonic() + retry
        while not stopped and time.monotonic() < deadline:
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        retry = min(60, retry * 2)
    graph.disconnected()
    store.save(graph, reason="collector-stopped")


def service_definition(script, state, codex_home, python, platform=None, uid=None):
    platform = sys.platform if platform is None else platform
    uid = os.getuid() if uid is None else uid
    arguments = [python, str(script), "daemon", "--state-dir", str(state), "--codex-home", str(codex_home)]
    if platform == "darwin":
        return plistlib.dumps({"Label": LABEL, "ProgramArguments": arguments, "RunAtLoad": True, "KeepAlive": True,
                              "ProcessType": "Background", "ThrottleInterval": 30, "LowPriorityIO": True,
                              "Umask": 0o077, "EnvironmentVariables": {"PYTHONDONTWRITEBYTECODE": "1"},
                              "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"})
    if platform != "linux":
        raise CollectorError("unsupported-platform")
    def quote(value):
        if any(ord(char) < 32 for char in value):
            raise CollectorError("invalid-install-path")
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$") + '"'
    return (MARKER + "\n".join(["[Unit]", "Description=CodexBar shared Codex observer", "", "[Service]", "Type=simple",
                               "ExecStart=" + " ".join(quote(str(arg)) for arg in arguments), "Restart=on-failure", "RestartSec=30",
                               "UMask=0077", "Nice=10", "IOSchedulingClass=idle", "Environment=PYTHONDONTWRITEBYTECODE=1",
                               "NoNewPrivileges=yes", "RestrictAddressFamilies=AF_UNIX", "TimeoutStopSec=15",
                               "StandardOutput=null", "StandardError=null", "", "[Install]",
                               "WantedBy=" + ("multi-user.target" if uid == 0 else "default.target"), ""])).encode()


def retire_legacy_hooks(codex_home, home=None):
    home = Path.home() if home is None else Path(home)
    path = Path(codex_home) / "hooks.json"
    if not path.exists():
        return False
    if path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
        raise CollectorError("legacy-hooks-unreadable")
    original = path.read_bytes()
    document = json.loads(original)
    if not isinstance(document, dict) or not isinstance(document.get("hooks", {}), dict):
        raise CollectorError("legacy-hooks-invalid")
    expected = [str(home / ".local/share/codexbar-usage/ActivityCollector.py"), "record", "--provider", "codex"]
    changed = False
    hooks = document.get("hooks", {})
    for event_name, groups in list(hooks.items()):
        if not isinstance(groups, list):
            raise CollectorError("legacy-hooks-invalid")
        retained_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise CollectorError("legacy-hooks-invalid")
            retained = []
            for handler in group["hooks"]:
                if not isinstance(handler, dict):
                    raise CollectorError("legacy-hooks-invalid")
                try:
                    command = shlex.split(handler.get("command", ""))
                except (TypeError, ValueError):
                    command = []
                owned = handler.get("type") == "command" and len(command) == 5 and command[1:] == expected
                changed = changed or owned
                if not owned:
                    retained.append(handler)
            if retained or not group["hooks"]:
                retained_groups.append({**group, "hooks": retained})
        if retained_groups:
            hooks[event_name] = retained_groups
        else:
            hooks.pop(event_name, None)
    if not changed:
        return False
    if path.read_bytes() != original:
        raise CollectorError("legacy-hooks-changed")
    backup = path.with_name(path.name + ".codexbar-shared-backup")
    if not backup.exists():
        atomic_write(backup, original)
    atomic_write(path, json.dumps(document, ensure_ascii=False, indent=2).encode() + b"\n")
    return True


def bootstrap_launch_agent(run, unit, uid):
    # bootout 返回时旧任务仍可能在退出, 不把短暂的同名注册冲突当作永久故障
    for delay in (0, 0.25, 0.5, 1, 2, 4, 8):
        if delay:
            time.sleep(delay)
        result = run(["launchctl", "bootstrap", f"gui/{uid}", str(unit)], check=False)
        if result.returncode == 0:
            return
    raise CollectorError("launch-agent-start-failed")


def install(args, remove=False):
    root = Path.home() / ".local/share/codexbar-shared-codex"
    if root.is_symlink():
        raise CollectorError("unmanaged-installation")
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    descriptor = os.open(root / "installation.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return install_locked(args, remove)
    finally:
        os.close(descriptor)


def install_locked(args, remove=False):
    home = Path.home()
    code_root = home / ".local/share/codexbar-shared-codex"
    script = code_root / "collector.py"
    manifest = code_root / "installation.json"
    state = Path(args.state_dir).expanduser().absolute()
    codex_home = Path(args.codex_home).expanduser().absolute()
    python = str(Path(sys.executable).resolve())
    config = dict(schema=1, stateDirectory=str(state), codexHome=str(codex_home), script=str(script), python=python)
    if not args.codex_home or not args.state_dir:
        raise CollectorError("invalid-install-path")
    if sys.platform == "darwin":
        unit = home / "Library/LaunchAgents" / (LABEL + ".plist")
    elif sys.platform == "linux":
        unit = Path("/etc/systemd/system") / SERVICE if os.getuid() == 0 else home / ".config/systemd/user" / SERVICE
    else:
        raise CollectorError("unsupported-platform")
    for path in (code_root, script, manifest, unit):
        if path.is_symlink():
            raise CollectorError("unmanaged-installation")
    previous = json.loads(manifest.read_text()) if manifest.exists() else None
    if previous and any(previous.get(key) != config[key] for key in ("schema", "stateDirectory", "codexHome", "script")):
        raise CollectorError("installation-path-changed")
    if (script.exists() or unit.exists()) and not previous:
        raise CollectorError("unmanaged-installation")
    if unit.exists():
        if sys.platform == "darwin":
            existing_unit = plistlib.loads(unit.read_bytes())
            if existing_unit.get("Label") != LABEL or existing_unit.get("ProgramArguments", [None, None])[1:2] != [str(script)]:
                raise CollectorError("unmanaged-installation")
        elif not unit.read_bytes().startswith(MARKER.encode()):
            raise CollectorError("unmanaged-installation")
    def run(command, check=True):
        return subprocess.run(command, check=check, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    systemctl = ["systemctl"] + ([] if os.getuid() == 0 else ["--user"])
    if remove:
        if not previous:
            return dict(schema=1, ok=True, dataPreserved=True)
        if sys.platform == "darwin":
            run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], check=False)
        else:
            run(systemctl + ["disable", "--now", SERVICE])
        unit.unlink(missing_ok=True)
        if sys.platform == "linux":
            run(systemctl + ["daemon-reload"])
        return dict(schema=1, ok=True, dataPreserved=True)
    source = globals().get("CODEXBAR_SCRIPT_SOURCE")
    if not isinstance(source, bytes):
        source = Path(__file__).read_bytes()
    config["scriptSHA256"] = hashlib.sha256(source).hexdigest()
    rendered = service_definition(script, state, codex_home, python)
    unchanged = previous == config and script.exists() and script.read_bytes() == source and unit.exists() and unit.read_bytes() == rendered
    code_root.mkdir(parents=True, mode=0o700, exist_ok=True)
    StateStore(state).close()
    if not unchanged:
        atomic_write(script, source)
        atomic_write(manifest, encode(config))
        atomic_write(unit, rendered)
        os.chmod(unit, 0o644)
    activation_started = time.time()
    needs_fresh_health = not unchanged
    if sys.platform == "darwin":
        running = run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], check=False).returncode == 0
        needs_fresh_health = needs_fresh_health or not running
        if not unchanged or not running:
            if running:
                run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], check=False)
            bootstrap_launch_agent(run, unit, os.getuid())
    else:
        running = run(systemctl + ["is-active", "--quiet", SERVICE], check=False).returncode == 0
        needs_fresh_health = needs_fresh_health or not running
        if not unchanged:
            run(systemctl + ["daemon-reload"])
        run(systemctl + ["enable", "--now", SERVICE])
        if previous and not unchanged:
            run(systemctl + ["restart", SERVICE])
    store = StateStore(state)
    try:
        deadline = time.monotonic() + 12
        value = store.snapshot()
        def healthy():
            return value["sourceAvailable"] and (not needs_fresh_health or store.saved()[1] >= activation_started)
        while not healthy() and time.monotonic() < deadline:
            time.sleep(0.25)
            value = store.snapshot()
        if not healthy():
            value["sourceAvailable"] = False
            value["sourceReason"] = value.get("sourceReason") or "collector-starting"
        retired = retire_legacy_hooks(codex_home) if getattr(args, "retire_legacy_hooks", False) and value["sourceAvailable"] else False
    finally:
        store.close()
    return dict(schema=1, ok=True, stateDirectory=str(state), service=LABEL if sys.platform == "darwin" else SERVICE,
                sourceAvailable=value["sourceAvailable"], sourceReason=value.get("sourceReason", ""), legacyHooksRetired=retired)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("daemon", "snapshot", "stream", "install", "uninstall"))
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME") or str(Path.home() / ".codex"))
    parser.add_argument("--state-dir", default=str(Path.home() / ".local/state/codexbar-shared-codex"))
    parser.add_argument("--retire-legacy-hooks", action="store_true")
    args = parser.parse_args()
    args.codex_home = args.codex_home or os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")
    args.state_dir = args.state_dir or str(Path.home() / ".local/state/codexbar-shared-codex")
    if args.action in ("install", "uninstall"):
        print(json.dumps(install(args, remove=args.action == "uninstall")))
        return
    store = StateStore(Path(args.state_dir).expanduser())
    try:
        if args.action == "daemon":
            daemon(store, Path(args.codex_home).expanduser() / "app-server-control/app-server-control.sock")
        elif args.action == "stream":
            stream(store)
        else:
            print(json.dumps(store.snapshot(), separators=(",", ":")))
    finally:
        store.close()


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        if isinstance(error, CollectorError) and str(error) == "collector-already-running":
            sys.exit(0)
        print("CodexBar: " + (str(error) if isinstance(error, CollectorError) else "shared-collector-failed"), file=sys.stderr)
        sys.exit(1)
