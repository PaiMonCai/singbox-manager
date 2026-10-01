#!/usr/bin/env python3
import argparse
import base64
import fcntl
import getpass
import ipaddress
import json
import os
import re
import secrets
import sys
import time
import unicodedata
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import parse_qs, unquote, urlsplit

HOME = Path(os.environ.get("SBX_HOME", "/opt/singbox-manager"))
REGISTRY = HOME / "nodes" / "nodes.json"
CONFIG = HOME / "config" / "config.json"
INBOUND_COMPOSE = HOME / "compose.inbounds.yml"
ENV_FILE = HOME / ".env"
SUPPORTED = ("shadowsocks", "vless", "trojan", "hysteria2", "socks")
DEFAULT_SETTINGS = {
    "strategy": "manual",
    "route_mode": "global",
    "urltest": {
        "url": "https://www.gstatic.com/generate_204",
        "interval": "3m",
        "tolerance": 50,
    },
}

# 会改写节点库的子命令：整个「读-改-写」周期必须互斥，否则并发操作会互相覆盖。
MUTATING_COMMANDS = frozenset({
    "init", "add", "edit", "delete", "default", "render",
    "import-uri", "import-file",
    "inbound-add", "inbound-edit", "inbound-delete",
    "strategy", "route-mode", "urltest",
    "sub-register", "sub-apply", "sub-delete",
})

LOCK_FILE = HOME / "nodes" / ".sbx-nodes.lock"
_LOCK_HANDLE: Optional[Any] = None


def acquire_registry_lock(timeout: float = 15.0) -> None:
    """独占节点库的读-改-写周期。进程退出时 flock 自动释放，无需显式解锁。"""
    global _LOCK_HANDLE
    if _LOCK_HANDLE is not None:
        return
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    handle = LOCK_FILE.open("w")
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.monotonic() >= deadline:
                handle.close()
                raise ValueError("节点库正被其它进程占用，请稍后重试")
            time.sleep(0.1)
    _LOCK_HANDLE = handle


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


def atomic_json(path: Path, data: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def merged_settings(value: Any) -> Dict[str, Any]:
    out = json.loads(json.dumps(DEFAULT_SETTINGS))
    if isinstance(value, dict):
        if value.get("strategy") in ("manual", "auto"):
            out["strategy"] = value["strategy"]
        if value.get("route_mode") in ("global", "cn-direct-lite", "cn-direct-full"):
            out["route_mode"] = value["route_mode"]
        if isinstance(value.get("urltest"), dict):
            out["urltest"].update({k: v for k, v in value["urltest"].items() if k in out["urltest"]})
    return out


def load_registry() -> Dict[str, Any]:
    if not REGISTRY.exists():
        return {"version": 3, "default": None, "settings": merged_settings(None), "subscriptions": [], "inbounds": [], "nodes": []}
    with REGISTRY.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("nodes"), list):
        raise ValueError("节点库格式无效")
    data["version"] = max(int(data.get("version", 1)), 3)
    data.setdefault("default", None)
    data["settings"] = merged_settings(data.get("settings"))
    if not isinstance(data.get("subscriptions"), list):
        data["subscriptions"] = []
    if not isinstance(data.get("inbounds"), list):
        data["inbounds"] = []
    return data


def save_registry(data: Dict[str, Any]) -> None:
    data["version"] = 3
    data["settings"] = merged_settings(data.get("settings"))
    if not isinstance(data.get("inbounds"), list):
        data["inbounds"] = []
    atomic_json(REGISTRY, data)


def prompt(text: str, default: Optional[str] = None, required: bool = False) -> str:
    suffix = f" [{default}]" if default not in (None, "") else ""
    while True:
        try:
            value = input(f"{text}{suffix}: ").strip()
        except EOFError:
            raise SystemExit("输入已终止")
        if not value and default is not None:
            value = default
        if value or not required:
            return value
        print("此项不能为空。")


def prompt_secret(text: str, current: Optional[str] = None, required: bool = False) -> str:
    # current 为空串时不能当成“已有值”，否则 required=True 会被直接回车绕过
    keep = current is not None and current != ""
    hint = " [直接回车保持不变]" if keep else ""
    while True:
        try:
            value = getpass.getpass(f"{text}{hint}: ").strip()
        except (EOFError, KeyboardInterrupt):
            raise SystemExit("输入已终止")
        if not value and keep:
            return current
        if value or not required:
            return value
        print("此项不能为空。")


def prompt_bool(text: str, default: bool = False) -> bool:
    mark = "Y/n" if default else "y/N"
    while True:
        value = prompt(f"{text} [{mark}]").lower()
        if not value:
            return default
        if value in ("y", "yes", "1", "true", "是"):
            return True
        if value in ("n", "no", "0", "false", "否"):
            return False
        print("请输入 y 或 n。")


def prompt_port(text: str, default: Optional[int] = None) -> int:
    while True:
        raw = prompt(text, str(default) if default else None, required=True)
        try:
            port = int(raw)
            if 1 <= port <= 65535:
                return port
        except ValueError:
            pass
        print("端口必须是 1-65535 的整数。")


def truthy(value: Optional[str]) -> bool:
    return str(value or "").lower() in ("1", "true", "yes", "on")


def first(qs: Dict[str, List[str]], *keys: str, default: str = "") -> str:
    for key in keys:
        vals = qs.get(key)
        if vals:
            return vals[0]
    return default


def b64decode_loose(value: str) -> str:
    raw = value.strip()
    raw += "=" * (-len(raw) % 4)
    for alt in (None, b"-_"):
        try:
            if alt is None:
                return base64.b64decode(raw).decode("utf-8")
            return base64.b64decode(raw, altchars=alt).decode("utf-8")
        except Exception:
            pass
    raise ValueError("Base64 内容无法解码")


def is_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def new_id(existing: Iterable[Dict[str, Any]]) -> str:
    used = {n.get("id") for n in existing}
    while True:
        candidate = secrets.token_hex(4)
        if candidate not in used:
            return candidate


def node_tag(node: Dict[str, Any]) -> str:
    return f"node-{node['id']}"


def inbound_tag(inbound: Dict[str, Any]) -> str:
    return f"inbound-{inbound['id']}"


def read_env_file() -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not ENV_FILE.exists():
        return out
    for line in ENV_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def default_host_port() -> int:
    raw = read_env_file().get("SING_BOX_MIXED_PORT", "7890")
    try:
        return int(raw)
    except ValueError:
        return 7890


def inbound_endpoints(data: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
    data = data or load_registry()
    # port = 宿主机侧端口（compose 发布端口）；container_port = 容器内/共享网络内可达端口。
    # 默认入口在容器内固定监听 7890（compose.yml 映射 `宿主:7890`），
    # 只有自定义入口才是 host:port == container:port 一一对应。
    items: List[Dict[str, Any]] = [{
        "id": "default",
        "name": "默认入口",
        "type": "mixed",
        "listen": read_env_file().get("SING_BOX_BIND_ADDR", "127.0.0.1"),
        "port": default_host_port(),
        "container_port": 7890,
        "target": {"type": "proxy"},
        "builtin": True,
    }]
    for inbound in data.get("inbounds", []):
        item = dict(inbound)
        item["builtin"] = False
        item["container_port"] = int(inbound.get("port", 0))
        items.append(item)
    return items


def resolve_inbound_endpoint(data: Dict[str, Any], ref: Optional[str]) -> Dict[str, Any]:
    items = inbound_endpoints(data)
    raw = (ref or "default").strip()
    exact = [x for x in items if str(x.get("id")) == raw]
    if len(exact) == 1:
        return exact[0]
    prefix = [x for x in items if str(x.get("id", "")).startswith(raw)]
    if len(prefix) == 1:
        return prefix[0]
    named = [x for x in items if x.get("name") == raw]
    if len(named) == 1:
        return named[0]
    if raw.isdigit():
        by_port = [x for x in items if int(x.get("port", 0)) == int(raw)]
        if len(by_port) == 1:
            return by_port[0]
    if len(prefix) > 1 or len(named) > 1:
        raise ValueError("匹配到多个代理入口，请使用完整 ID")
    raise ValueError(f"未找到代理入口: {raw}")


def resolve_inbound(data: Dict[str, Any], ref: Optional[str]) -> Dict[str, Any]:
    items = data.get("inbounds", [])
    if not items:
        raise ValueError("当前没有自定义入口")
    if not ref:
        list_inbounds(data, include_default=False)
        ref = prompt("请输入自定义入口 ID 或名称", required=True)
    exact = [x for x in items if x.get("id") == ref]
    if len(exact) == 1:
        return exact[0]
    prefix = [x for x in items if str(x.get("id", "")).startswith(ref)]
    if len(prefix) == 1:
        return prefix[0]
    named = [x for x in items if x.get("name") == ref]
    if len(named) == 1:
        return named[0]
    if len(prefix) > 1 or len(named) > 1:
        raise ValueError("匹配到多个入口，请使用完整 ID")
    raise ValueError(f"未找到入口: {ref}")


def target_from_ref(data: Dict[str, Any], value: str) -> Dict[str, Any]:
    raw = (value or "").strip()
    if raw in ("direct", "proxy", "auto"):
        if raw in ("proxy", "auto") and not data.get("nodes"):
            raise ValueError(f"当前没有节点，不能使用 {raw} 出口")
        return {"type": raw}
    if raw.startswith("node:"):
        node = resolve_node(data, raw[5:])
        return {"type": "node", "node_id": node["id"]}
    node = resolve_node(data, raw)
    return {"type": "node", "node_id": node["id"]}


def target_tag(data: Dict[str, Any], target: Any) -> str:
    if not isinstance(target, dict):
        raise ValueError("入口 target 格式无效")
    typ = target.get("type")
    if typ == "direct":
        return "direct"
    if typ in ("proxy", "auto"):
        if not data.get("nodes"):
            raise ValueError(f"入口引用 {typ}，但当前没有节点")
        return str(typ)
    if typ == "node":
        node_id = target.get("node_id")
        node = next((n for n in data.get("nodes", []) if n.get("id") == node_id), None)
        if not node:
            raise ValueError(f"入口引用的节点不存在: {node_id}")
        return node_tag(node)
    raise ValueError(f"未知入口出口类型: {typ}")


def target_label(data: Dict[str, Any], target: Any) -> str:
    if not isinstance(target, dict):
        return "INVALID"
    typ = target.get("type")
    if typ != "node":
        return str(typ or "INVALID")
    node_id = target.get("node_id")
    node = next((n for n in data.get("nodes", []) if n.get("id") == node_id), None)
    # 正常情况下只显示名称（ID 是内部标识）；节点已不存在时才带上 ID 方便排查
    return str(node.get("name")) if node else f"MISSING ({node_id})"


def choose_target(data: Dict[str, Any], current: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    print("\n出口：")
    print("  1. proxy  跟随全局 selector 策略")
    print("  2. auto   固定使用 URLTest 自动测速组")
    print("  3. direct 直连")
    base = 4
    for idx, node in enumerate(data.get("nodes", []), base):
        print(f"  {idx}. {node.get('name')}")
    default = "1"
    if isinstance(current, dict):
        typ = current.get("type")
        if typ == "proxy": default = "1"
        elif typ == "auto": default = "2"
        elif typ == "direct": default = "3"
        elif typ == "node":
            for idx, node in enumerate(data.get("nodes", []), base):
                if node.get("id") == current.get("node_id"):
                    default = str(idx)
                    break
    while True:
        raw = prompt("请选择出口", default, required=True)
        if raw == "1":
            return target_from_ref(data, "proxy")
        if raw == "2":
            return target_from_ref(data, "auto")
        if raw == "3":
            return target_from_ref(data, "direct")
        try:
            idx = int(raw) - base
        except ValueError:
            idx = -1
        nodes = data.get("nodes", [])
        if 0 <= idx < len(nodes):
            return {"type": "node", "node_id": nodes[idx]["id"]}
        print("无效出口。")


def validate_listen_address(value: str, interactive: bool = False) -> str:
    try:
        addr = ipaddress.ip_address(value)
    except ValueError as exc:
        raise ValueError("入口监听地址必须是 IP 地址") from exc
    if not addr.is_loopback:
        if not interactive:
            raise ValueError("非回环监听必须使用交互式入口管理并输入 PUBLIC 确认")
        confirm = prompt("非回环监听会暴露无认证 mixed 代理；输入 PUBLIC 确认")
        if confirm != "PUBLIC":
            raise ValueError("已取消非回环入口")
    return str(addr)


def next_inbound_port(data: Dict[str, Any]) -> int:
    used = {7890, default_host_port()}
    used.update(int(x.get("port", 0)) for x in data.get("inbounds", []))
    port = 7891
    while port in used and port <= 65535:
        port += 1
    if port > 65535:
        raise ValueError("没有可用入口端口")
    return port


def validate_inbound_port(data: Dict[str, Any], port: int, current_id: Optional[str] = None) -> None:
    if not 1 <= int(port) <= 65535:
        raise ValueError("入口端口必须是 1-65535")
    if int(port) == 7890:
        raise ValueError("7890 是容器默认 mixed-in 端口，不能用于自定义入口")
    if int(port) == default_host_port():
        raise ValueError(f"{port} 已被默认 mixed 入口占用")
    for item in data.get("inbounds", []):
        if item.get("id") != current_id and int(item.get("port", 0)) == int(port):
            raise ValueError(f"入口端口已被占用: {port}")


def build_inbound(data: Dict[str, Any], existing: Optional[Dict[str, Any]] = None, *,
                  name: Optional[str] = None, listen: Optional[str] = None,
                  port: Optional[int] = None, target_ref: Optional[str] = None) -> Dict[str, Any]:
    existing = existing or {}
    interactive = name is None and listen is None and port is None and target_ref is None
    inbound_id = existing.get("id")
    if name is None:
        name = prompt("入口名称", existing.get("name"), True)
    if not name:
        raise ValueError("入口名称不能为空")
    name = str(name).strip()
    if name.lower() == "default":
        raise ValueError("入口名称不能是 default（内置默认入口的保留名）")
    if any(x.get("name") == name and x.get("id") != inbound_id for x in data.get("inbounds", [])):
        raise ValueError(f"入口名称重复: {name}")

    if listen is None:
        listen = prompt("宿主机监听地址", existing.get("listen", "127.0.0.1"), True)
    listen = validate_listen_address(listen, interactive=interactive)

    if port is None:
        port = prompt_port("入口端口", int(existing.get("port") or next_inbound_port(data)))
    validate_inbound_port(data, int(port), inbound_id)

    target = target_from_ref(data, target_ref) if target_ref is not None else choose_target(data, existing.get("target"))
    return {
        "id": inbound_id,
        "name": str(name),
        "type": "mixed",
        "listen": listen,
        "port": int(port),
        "target": target,
    }


def repair_inbound_targets(data: Dict[str, Any], removed_ids: Iterable[str],
                           replacements: Optional[Dict[str, str]] = None) -> int:
    removed = set(removed_ids)
    replacements = replacements or {}
    changed = 0
    fallback = {"type": "proxy"} if data.get("nodes") else {"type": "direct"}
    for inbound in data.get("inbounds", []):
        target = inbound.get("target")
        if not isinstance(target, dict):
            continue
        if target.get("type") in ("proxy", "auto") and not data.get("nodes"):
            # 节点被清空后 proxy/auto 无法解析（target_tag 会抛错），
            # 不回退 direct 的话整库会永久通不过校验。
            inbound["target"] = dict(fallback)
            changed += 1
            continue
        if target.get("type") != "node":
            continue
        old_id = target.get("node_id")
        if old_id not in removed:
            continue
        new_id = replacements.get(str(old_id))
        inbound["target"] = {"type": "node", "node_id": new_id} if new_id else dict(fallback)
        changed += 1
    return changed


def is_node_index(ref: str) -> bool:
    # 只认 ASCII 数字：交互层用序号，持久层仍然是 8 位节点 ID
    return bool(ref) and all(ch in "0123456789" for ch in ref)


def resolve_node(data: Dict[str, Any], ref: Optional[str]) -> Dict[str, Any]:
    """按序号 / 名称 / 节点 ID 解析节点。

    顺序很重要：先做完整 ID 匹配，再当序号解释。
    这样 8 位十六进制 ID 恰好全是数字时（例如 11111111）仍可按 ID 使用，
    而 "1"/"2" 这种不会出现在生成的 ID 里的输入自然落到序号分支。
    """
    nodes = data["nodes"]
    if not nodes:
        raise ValueError("当前没有节点")
    if not ref:
        list_nodes(data)
        ref = prompt("请输入节点序号（也可输入名称）", required=True)
    ref = ref.strip()
    exact = [n for n in nodes if n.get("id") == ref]
    if len(exact) == 1:
        return exact[0]
    if is_node_index(ref):
        idx = int(ref)
        if not (1 <= idx <= len(nodes)):
            raise ValueError(f"节点序号超出范围: {ref}（当前 1-{len(nodes)}）")
        return nodes[idx - 1]
    prefix = [n for n in nodes if str(n.get("id", "")).startswith(ref)]
    if len(prefix) == 1:
        return prefix[0]
    named = [n for n in nodes if n.get("name") == ref]
    if len(named) == 1:
        return named[0]
    if len(prefix) > 1 or len(named) > 1:
        raise ValueError("匹配到多个节点，请改用序号（见 sbx node list）")
    raise ValueError(f"未找到节点: {ref}（可用序号 1-{len(nodes)}，或用 sbx node list 查看）")



def resolve_subscription(data: Dict[str, Any], ref: Optional[str]) -> Dict[str, Any]:
    subs = data.get("subscriptions", [])
    if not subs:
        raise ValueError("当前没有订阅")
    if not ref:
        list_subscriptions(data)
        ref = prompt("请输入订阅 ID 或名称", required=True)
    exact = [s for s in subs if s.get("id") == ref]
    if len(exact) == 1:
        return exact[0]
    prefix = [s for s in subs if str(s.get("id", "")).startswith(ref)]
    if len(prefix) == 1:
        return prefix[0]
    named = [s for s in subs if s.get("name") == ref]
    if len(named) == 1:
        return named[0]
    raise ValueError(f"未找到订阅: {ref}")


def choose_protocol(current: Optional[str] = None) -> str:
    items = [("1", "shadowsocks", "Shadowsocks"), ("2", "vless", "VLESS"), ("3", "trojan", "Trojan"), ("4", "hysteria2", "Hysteria2"), ("5", "socks", "SOCKS5")]
    print("\n支持的节点协议：")
    for num, key, label in items:
        print(f"  {num}. {label}" + ("  <- 当前" if current == key else ""))
    default_num = next((num for num, key, _ in items if key == current), None)
    while True:
        raw = prompt("请选择协议", default_num, required=True)
        for num, key, _ in items:
            if raw == num or raw.lower() == key:
                return key
        print("无效协议。")


def tls_fields(existing: Optional[Dict[str, Any]], server: str, required: bool = False, allow_reality: bool = False) -> Optional[Dict[str, Any]]:
    existing = existing or {}
    enabled = True if required else prompt_bool("启用 TLS", bool(existing.get("enabled", required)))
    if not enabled:
        return None
    sni = prompt("TLS Server Name / SNI", str(existing.get("server_name") or ("" if is_ip(server) else server)))
    tls: Dict[str, Any] = {"enabled": True, "insecure": prompt_bool("跳过证书校验（不推荐）", bool(existing.get("insecure", False)))}
    if sni:
        tls["server_name"] = sni
    if allow_reality:
        old = existing.get("reality") if isinstance(existing.get("reality"), dict) else {}
        if prompt_bool("使用 Reality", bool(old and old.get("enabled"))):
            tls["reality"] = {"enabled": True, "public_key": prompt_secret("Reality Public Key", old.get("public_key"), True), "short_id": prompt("Reality Short ID", old.get("short_id", ""), True)}
    return tls


def transport_fields(existing: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    existing = existing or {}
    choices = {"1": "", "2": "ws", "3": "grpc", "4": "httpupgrade"}
    reverse = {v: k for k, v in choices.items()}
    print("\n传输方式：\n  1. TCP / 默认\n  2. WebSocket\n  3. gRPC\n  4. HTTPUpgrade")
    kind = choices.get(prompt("请选择传输方式", reverse.get(existing.get("type", ""), "1"), True))
    if kind is None:
        raise ValueError("无效传输方式")
    if not kind:
        return None
    if kind == "ws":
        result: Dict[str, Any] = {"type": "ws", "path": prompt("WebSocket Path", existing.get("path", "/")) or "/"}
        host = prompt("WebSocket Host（可留空）", (existing.get("headers") or {}).get("Host", ""))
        if host:
            result["headers"] = {"Host": host}
        return result
    if kind == "grpc":
        result = {"type": "grpc"}
        service = prompt("gRPC Service Name", existing.get("service_name", ""))
        if service:
            result["service_name"] = service
        return result
    result = {"type": "httpupgrade", "path": prompt("HTTPUpgrade Path", existing.get("path", "/")) or "/"}
    host = prompt("HTTPUpgrade Host（可留空）", existing.get("host", ""))
    if host:
        result["host"] = host
    return result


def build_node(existing: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    existing = existing or {}
    protocol = choose_protocol(existing.get("type"))
    name = prompt("节点名称", existing.get("name"), True)
    server = prompt("服务器地址", existing.get("server"), True)
    port = prompt_port("服务器端口", existing.get("server_port"))
    node: Dict[str, Any] = {"id": existing.get("id"), "name": name, "type": protocol, "server": server, "server_port": port, "source": existing.get("source", "manual")}
    if protocol == "shadowsocks":
        node.update(method=prompt("加密方式", existing.get("method", "aes-256-gcm"), True), password=prompt_secret("密码", existing.get("password"), True))
    elif protocol == "socks":
        username = prompt("用户名（可留空）", existing.get("username", "")); node["version"] = "5"
        if username:
            node.update(username=username, password=prompt_secret("密码（可留空）", existing.get("password")))
    elif protocol == "trojan":
        node["password"] = prompt_secret("Trojan 密码", existing.get("password"), True); node["tls"] = tls_fields(existing.get("tls"), server, True)
        transport = transport_fields(existing.get("transport"));
        if transport: node["transport"] = transport
    elif protocol == "vless":
        node["uuid"] = prompt_secret("VLESS UUID", existing.get("uuid"), True)
        flow = prompt("Flow（通常留空）", existing.get("flow", ""));
        if flow: node["flow"] = flow
        tls = tls_fields(existing.get("tls"), server, False, True); transport = transport_fields(existing.get("transport"))
        if tls: node["tls"] = tls
        if transport: node["transport"] = transport
    elif protocol == "hysteria2":
        node["password"] = prompt_secret("Hysteria2 密码", existing.get("password"), True); node["tls"] = tls_fields(existing.get("tls"), server, True)
        old = existing.get("obfs") if isinstance(existing.get("obfs"), dict) else {}
        if prompt_bool("启用 Salamander 混淆", bool(old)):
            node["obfs"] = {"type": "salamander", "password": prompt_secret("Obfs 密码", old.get("password"), True)}
    return node


def transport_from_query(qs: Dict[str, List[str]]) -> Optional[Dict[str, Any]]:
    kind = first(qs, "type", "network").lower()
    if kind in ("", "tcp", "none"):
        return None
    if kind == "ws":
        result: Dict[str, Any] = {"type": "ws", "path": unquote(first(qs, "path", default="/")) or "/"}
        host = first(qs, "host")
        if host: result["headers"] = {"Host": host}
        return result
    if kind == "grpc":
        result = {"type": "grpc"}; service = first(qs, "serviceName", "service_name")
        if service: result["service_name"] = service
        return result
    if kind in ("httpupgrade", "http-upgrade"):
        result = {"type": "httpupgrade", "path": unquote(first(qs, "path", default="/")) or "/"}; host = first(qs, "host")
        if host: result["host"] = host
        return result
    raise ValueError(f"暂不支持分享链接传输类型: {kind}")


def tls_from_query(qs: Dict[str, List[str]], server: str, force: bool = False, reality: bool = False) -> Optional[Dict[str, Any]]:
    security = first(qs, "security").lower()
    enabled = force or reality or security in ("tls", "reality")
    if not enabled:
        return None
    tls: Dict[str, Any] = {"enabled": True, "insecure": truthy(first(qs, "insecure", "allowInsecure"))}
    sni = first(qs, "sni", "peer") or ("" if is_ip(server) else server)
    if sni: tls["server_name"] = sni
    fp = first(qs, "fp", "fingerprint")
    if fp and fp.lower() not in ("none", "off"):
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if reality or security == "reality":
        pbk = first(qs, "pbk", "publicKey", "public_key"); sid = first(qs, "sid", "shortId", "short_id")
        if not pbk: raise ValueError("Reality 分享链接缺少 public key (pbk)")
        tls["reality"] = {"enabled": True, "public_key": pbk, "short_id": sid}
    return tls


def parsed_name(parts: Any, fallback: str) -> str:
    return unquote(parts.fragment).strip() or fallback


def parse_ss_uri(uri: str) -> Dict[str, Any]:
    raw = uri[len("ss://"):]
    fragment = ""
    if "#" in raw:
        raw, fragment = raw.split("#", 1)
    if "?" in raw:
        raw, _query = raw.split("?", 1)
    method = password = host = ""; port = 0
    if "@" in raw:
        userinfo, endpoint = raw.rsplit("@", 1)
        # 先做 URL 解码再判断：SIP002 要求 base64 的 "=" 写成 %3D，
        # 若先解码 base64 会把 padding 留成字面量而解析失败。
        userinfo = unquote(userinfo)
        if ":" not in userinfo:
            userinfo = unquote(b64decode_loose(userinfo))
        if ":" not in userinfo:
            raise ValueError("Shadowsocks 分享链接缺少 method:password")
        method, password = userinfo.split(":", 1)
        p = urlsplit("x://" + endpoint)
        host, port = p.hostname or "", int(p.port or 0)
    else:
        decoded = b64decode_loose(raw)
        if "@" not in decoded:
            raise ValueError("Shadowsocks 分享链接不完整")
        creds, endpoint = decoded.rsplit("@", 1)
        if ":" not in creds:
            raise ValueError("Shadowsocks 分享链接缺少 method:password")
        method, password = creds.split(":", 1)
        p = urlsplit("x://" + endpoint)
        host, port = p.hostname or "", int(p.port or 0)
    if not method or not password or not host or not port:
        raise ValueError("Shadowsocks 分享链接不完整")
    return {"name": unquote(fragment) or f"SS-{host}", "type": "shadowsocks", "server": host, "server_port": port, "method": method, "password": password}


def parse_uri(uri: str) -> Dict[str, Any]:
    uri = uri.strip()
    if uri.lower().startswith("ss://"):
        return parse_ss_uri(uri)
    parts = urlsplit(uri)
    scheme = parts.scheme.lower()
    if scheme not in ("vless", "trojan", "hysteria2", "hy2", "socks", "socks5"):
        raise ValueError(f"不支持的分享链接协议: {scheme or 'unknown'}")
    if not parts.hostname or not parts.port:
        raise ValueError("分享链接缺少服务器地址或端口")
    qs = parse_qs(parts.query, keep_blank_values=True)
    server, port = parts.hostname, int(parts.port)
    name = parsed_name(parts, f"{scheme.upper()}-{server}")
    if scheme == "vless":
        node: Dict[str, Any] = {"name": name, "type": "vless", "server": server, "server_port": port, "uuid": unquote(parts.username or "")}
        if not node["uuid"]: raise ValueError("VLESS 分享链接缺少 UUID")
        flow = first(qs, "flow");
        if flow: node["flow"] = flow
        tls = tls_from_query(qs, server, reality=first(qs, "security").lower() == "reality"); transport = transport_from_query(qs)
        if tls: node["tls"] = tls
        if transport: node["transport"] = transport
        return node
    if scheme == "trojan":
        node = {"name": name, "type": "trojan", "server": server, "server_port": port, "password": unquote(parts.username or "")}
        if not node["password"]: raise ValueError("Trojan 分享链接缺少密码")
        node["tls"] = tls_from_query(qs, server, force=True); transport = transport_from_query(qs)
        if transport: node["transport"] = transport
        return node
    if scheme in ("hysteria2", "hy2"):
        password = unquote(parts.username or "")
        if parts.password is not None: password = unquote(f"{parts.username or ''}:{parts.password}")
        node = {"name": name, "type": "hysteria2", "server": server, "server_port": port, "password": password, "tls": tls_from_query(qs, server, force=True)}
        if not password: raise ValueError("Hysteria2 分享链接缺少密码")
        obfs = first(qs, "obfs"); obfs_password = first(qs, "obfs-password", "obfs_password")
        if obfs:
            node["obfs"] = {"type": obfs, "password": obfs_password}
        return node
    username = unquote(parts.username or ""); password = unquote(parts.password or "")
    node = {"name": name, "type": "socks", "server": server, "server_port": port, "version": "5"}
    if username: node.update(username=username, password=password)
    return node


def decode_subscription_text(text: str) -> str:
    stripped = text.strip().lstrip("\ufeff")
    if not stripped:
        return ""
    if "://" in stripped:
        return stripped
    compact = "".join(stripped.split())
    try:
        decoded = b64decode_loose(compact)
        if "://" in decoded:
            return decoded
    except Exception:
        pass
    return stripped


def parse_subscription(text: str) -> Tuple[List[Dict[str, Any]], List[str]]:
    decoded = decode_subscription_text(text)
    nodes: List[Dict[str, Any]] = []; errors: List[str] = []
    for index, line in enumerate(decoded.replace("\r", "\n").split("\n"), 1):
        item = line.strip()
        if not item or item.startswith("#"): continue
        try:
            nodes.append(parse_uri(item))
        except Exception as exc:
            errors.append(f"第 {index} 行: {exc}")
    return nodes, errors


def ensure_unique_name(data: Dict[str, Any], name: str, ignore_ids: Optional[set] = None) -> str:
    ignore_ids = ignore_ids or set()
    existing = {n.get("name") for n in data["nodes"] if n.get("id") not in ignore_ids}
    if name not in existing: return name
    i = 2
    while f"{name}-{i}" in existing: i += 1
    return f"{name}-{i}"


def ensure_unique_node_name(data: Dict[str, Any], node: Dict[str, Any], ignore_id: Optional[str] = None) -> None:
    """交互式新增/编辑时拒绝重名：重名会让所有按名称的操作（edit/delete/show/test）失效。"""
    name = str(node.get("name") or "").strip()
    if not name:
        raise ValueError("节点名称不能为空")
    skip = ignore_id or node.get("id")
    for other in data["nodes"]:
        if other.get("id") == skip:
            continue
        if str(other.get("name") or "").strip() == name:
            raise ValueError(f"节点名称重复: {name}（请换一个名称；确实要同名时用序号操作，例如 sbx node edit 2）")


def add_imported_nodes(data: Dict[str, Any], nodes: List[Dict[str, Any]], source: str = "import", replace_ids: Optional[List[str]] = None) -> List[str]:
    replace_set = set(replace_ids or [])
    if replace_set:
        data["nodes"] = [n for n in data["nodes"] if n.get("id") not in replace_set]
    ids: List[str] = []
    for raw in nodes:
        node = dict(raw); node["id"] = new_id(data["nodes"]); node["name"] = ensure_unique_name(data, node.get("name") or node["type"].upper()); node["source"] = source
        data["nodes"].append(node); ids.append(node["id"])
    if not data.get("default") or data.get("default") in replace_set:
        data["default"] = ids[0] if ids else (data["nodes"][0]["id"] if data["nodes"] else None)
    return ids


def outbound_from_node(node: Dict[str, Any]) -> Dict[str, Any]:
    typ = node["type"]
    out: Dict[str, Any] = {"type": typ, "tag": node_tag(node), "server": node["server"], "server_port": int(node["server_port"])}
    if typ == "shadowsocks": out.update(method=node["method"], password=node["password"])
    elif typ == "socks":
        out["version"] = node.get("version", "5")
        if node.get("username"): out.update(username=node["username"], password=node.get("password", ""))
    elif typ == "trojan":
        out.update(password=node["password"], tls=node["tls"])
        if node.get("transport"): out["transport"] = node["transport"]
    elif typ == "vless":
        out["uuid"] = node["uuid"]
        if node.get("flow"): out["flow"] = node["flow"]
        if node.get("tls"): out["tls"] = node["tls"]
        if node.get("transport"): out["transport"] = node["transport"]
    elif typ == "hysteria2":
        out.update(password=node["password"], tls=node["tls"])
        if node.get("obfs"): out["obfs"] = node["obfs"]
    else: raise ValueError(f"暂不支持协议: {typ}")
    return out


def make_proxy_groups(data: Dict[str, Any], outbounds: List[Dict[str, Any]]) -> str:
    tags = [node_tag(n) for n in data["nodes"]]
    if not tags:
        return "direct"
    settings = data["settings"]; default_node = next((n for n in data["nodes"] if n.get("id") == data.get("default")), None)
    auto_tag = "auto"
    outbounds.append({"type": "urltest", "tag": auto_tag, "outbounds": tags, "url": settings["urltest"].get("url") or "https://www.gstatic.com/generate_204", "interval": settings["urltest"].get("interval") or "3m", "tolerance": int(settings["urltest"].get("tolerance", 50)), "interrupt_exist_connections": True})
    selector_default = auto_tag if settings.get("strategy") == "auto" else (node_tag(default_node) if default_node else tags[0])
    outbounds.append({"type": "selector", "tag": "proxy", "outbounds": [auto_tag] + tags, "default": selector_default, "interrupt_exist_connections": True})
    return "proxy"


def route_config(data: Dict[str, Any], proxy_tag: str) -> Dict[str, Any]:
    mode = data["settings"].get("route_mode", "global")
    inbound_rules = [{"inbound": [inbound_tag(x)], "action": "route", "outbound": target_tag(data, x.get("target"))} for x in data.get("inbounds", [])]
    route: Dict[str, Any] = {"rules": inbound_rules + [{"ip_is_private": True, "action": "route", "outbound": "direct"}], "final": proxy_tag, "auto_detect_interface": True}
    if mode in ("cn-direct-lite", "cn-direct-full"):
        route["rules"].append({"domain_suffix": [".cn"], "action": "route", "outbound": "direct"})
    if mode == "cn-direct-full":
        route["rules"].append({"rule_set": ["geosite-cn", "geoip-cn"], "action": "route", "outbound": "direct"})
        route["rule_set"] = [
            {"type": "remote", "tag": "geosite-cn", "format": "binary", "url": "https://testingcf.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs"},
            {"type": "remote", "tag": "geoip-cn", "format": "binary", "url": "https://testingcf.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs"},
        ]
    return route


def make_config(data: Dict[str, Any], listen_port: int = 7890, only_node: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    if only_node:
        outbounds = [outbound_from_node(only_node), {"type": "direct", "tag": "direct"}]
        route = {"rules": [{"ip_is_private": True, "action": "route", "outbound": "direct"}], "final": node_tag(only_node), "auto_detect_interface": True}
    else:
        outbounds = [outbound_from_node(n) for n in data["nodes"]]
        proxy_tag = make_proxy_groups(data, outbounds)
        outbounds.append({"type": "direct", "tag": "direct"})
        route = route_config(data, proxy_tag)
    inbounds: List[Dict[str, Any]] = [{"type": "mixed", "tag": "mixed-in", "listen": "0.0.0.0", "listen_port": int(listen_port)}]
    if not only_node:
        inbounds.extend({"type": "mixed", "tag": inbound_tag(x), "listen": "0.0.0.0", "listen_port": int(x["port"])} for x in data.get("inbounds", []))
    cfg: Dict[str, Any] = {"$schema": "https://sing-box.sagernet.org/schema.json", "log": {"level": "info", "timestamp": True}, "inbounds": inbounds, "outbounds": outbounds, "route": route}
    if data["settings"].get("route_mode") == "cn-direct-full" and not only_node:
        cfg["experimental"] = {"cache_file": {"enabled": True}}
    return cfg


def render_inbound_compose(data: Dict[str, Any]) -> None:
    items = data.get("inbounds", [])
    if not items:
        try:
            INBOUND_COMPOSE.unlink()
        except FileNotFoundError:
            pass
        return
    lines = ["services:", "  sing-box:", "    ports:"]
    for inbound in items:
        host = str(inbound["listen"])
        host_fmt = f"[{host}]" if ":" in host else host
        port = int(inbound["port"])
        lines.append(f'      - "{host_fmt}:{port}:{port}/tcp"')
        lines.append(f'      - "{host_fmt}:{port}:{port}/udp"')
    INBOUND_COMPOSE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(INBOUND_COMPOSE, 0o600)


def render(data: Optional[Dict[str, Any]] = None, target: Optional[Path] = None, port: int = 7890) -> None:
    data = data or load_registry()
    atomic_json(target or CONFIG, make_config(data, port))
    if target is None:
        render_inbound_compose(data)


def disp_width(text: Any) -> int:
    """终端显示宽度：CJK 全角字符按 2 列计算。"""
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in str(text))


def pad_cell(text: Any, width: int) -> str:
    s = str(text)
    return s + " " * max(0, width - disp_width(s))


def clip_cell(text: Any, width: int) -> str:
    out = ""; used = 0
    for ch in str(text):
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if used + w > width: break
        out += ch; used += w
    return out


def list_nodes(data: Optional[Dict[str, Any]] = None, show_id: bool = False) -> None:
    """节点列表。默认只显示交互用的序号，ID 是内部唯一标识（--ids 才显示）。"""
    data = data or load_registry(); nodes = data["nodes"]
    if not nodes: print("暂无节点。"); return
    id_head = pad_cell("ID", 10) if show_id else ""
    print(f"{pad_cell('默认', 6)}{pad_cell('序号', 6)}{id_head}{pad_cell('协议', 14)}{pad_cell('名称', 22)}{pad_cell('来源', 16)}地址")
    print("-" * (106 if show_id else 96))
    for i, n in enumerate(nodes, 1):
        mark = "*" if n.get("id") == data.get("default") else ""; src = str(n.get("source", "manual"))
        id_cell = pad_cell(n.get("id", ""), 10) if show_id else ""
        name = pad_cell(clip_cell(n.get("name", ""), 20), 22)
        print(f"{pad_cell(mark, 6)}{pad_cell(i, 6)}{id_cell}{pad_cell(n.get('type', ''), 14)}{name}{pad_cell(src[:12], 16)}{n.get('server')}:{n.get('server_port')}")


def list_inbounds(data: Optional[Dict[str, Any]] = None, include_default: bool = True) -> None:
    data = data or load_registry()
    items = inbound_endpoints(data) if include_default else list(data.get("inbounds", []))
    if not items:
        print("暂无自定义入口。")
        return
    print(f"{'ID':<10} {'名称':<22} {'监听':<24} 出口")
    print("-" * 90)
    for item in items:
        addr = f"{item.get('listen')}:{item.get('port')}"
        label = "proxy" if item.get("id") == "default" else target_label(data, item.get("target"))
        print(f"{item.get('id',''):<10} {item.get('name','')[:20]:<22} {addr:<24} {label}")


def list_subscriptions(data: Optional[Dict[str, Any]] = None) -> None:
    data = data or load_registry(); subs = data.get("subscriptions", [])
    if not subs: print("暂无订阅。"); return
    print(f"{'ID':<10} {'名称':<22} {'节点数':<8} URL(脱敏)")
    print("-" * 90)
    for s in subs:
        safe_url = redact(s.get("url", ""), "url")
        print(f"{s.get('id',''):<10} {s.get('name','')[:20]:<22} {len(s.get('node_ids',[])):<8} {safe_url}")


def redact(value: Any, key: str = "") -> Any:
    if isinstance(value, dict): return {k: redact(v, k) for k, v in value.items()}
    if isinstance(value, list): return [redact(v, key) for v in value]
    if key in {"password", "uuid", "public_key", "url"} and isinstance(value, str) and value:
        return "***" if len(value) <= 12 else value[:5] + "..." + value[-5:]
    return value


def validate(data: Optional[Dict[str, Any]] = None) -> None:
    if data is None and not REGISTRY.exists():
        raise ValueError(f"节点库不存在: {REGISTRY}")
    data = data or load_registry()
    if not all(isinstance(n, dict) for n in data["nodes"]):
        raise ValueError("节点库包含格式无效的条目（应为对象）")
    ids = [n.get("id") for n in data["nodes"]]
    if len(ids) != len(set(ids)): raise ValueError("节点 ID 重复")
    for n in data["nodes"]:
        if n.get("type") not in SUPPORTED: raise ValueError(f"不支持的节点协议: {n.get('type')}")
        if not n.get("id") or not n.get("name") or not n.get("server"): raise ValueError("节点缺少必要字段")
        try:
            node_port = int(n.get("server_port", 0))
        except (TypeError, ValueError):
            raise ValueError(f"节点端口无效: {n.get('name')}") from None
        if not 1 <= node_port <= 65535: raise ValueError(f"节点端口无效: {n.get('name')}")
        # 空口令/空 uuid 会生成运行期不可用的 config，必须在这里拦住
        secret_field = {"shadowsocks": "password", "trojan": "password", "hysteria2": "password", "vless": "uuid"}.get(n.get("type"))
        if secret_field and not str(n.get(secret_field) or "").strip():
            raise ValueError(f"节点缺少 {secret_field}: {n.get('name')}")
        if n.get("type") == "socks" and n.get("username") and not str(n.get("password") or "").strip():
            raise ValueError(f"节点缺少 password: {n.get('name')}")
        for key in ("tls", "transport", "obfs"):
            if n.get(key) is not None and not isinstance(n[key], dict):
                raise ValueError(f"节点 {key} 字段格式无效: {n.get('name')}")
        outbound_from_node(n)
    if data.get("default") is not None and data.get("default") not in ids: raise ValueError("默认节点不存在")
    if data["settings"]["strategy"] not in ("manual", "auto"): raise ValueError("strategy 无效")
    if data["settings"]["route_mode"] not in ("global", "cn-direct-lite", "cn-direct-full"): raise ValueError("route_mode 无效")
    inbound_ids = [x.get("id") for x in data.get("inbounds", [])]
    if len(inbound_ids) != len(set(inbound_ids)): raise ValueError("入口 ID 重复")
    inbound_names = [x.get("name") for x in data.get("inbounds", [])]
    if len(inbound_names) != len(set(inbound_names)): raise ValueError("入口名称重复")
    for inbound in data.get("inbounds", []):
        if inbound.get("type") != "mixed": raise ValueError("当前仅支持 mixed 自定义入口")
        if not inbound.get("id") or not inbound.get("name"): raise ValueError("入口缺少必要字段")
        try:
            ipaddress.ip_address(str(inbound.get("listen", "")))
        except ValueError as exc:
            raise ValueError("入口监听地址必须是 IP 地址") from exc
        validate_inbound_port(data, int(inbound.get("port", 0)), inbound.get("id"))
        target_tag(data, inbound.get("target"))
    make_config(data)


def cmd_init(_: argparse.Namespace) -> int:
    data = load_registry(); render(data); save_registry(data); return 0
def cmd_list(args: argparse.Namespace) -> int: list_nodes(show_id=bool(getattr(args, "ids", False))); return 0
def cmd_add(_: argparse.Namespace) -> int:
    data = load_registry(); node = build_node(); ensure_unique_node_name(data, node); node["id"] = new_id(data["nodes"]); data["nodes"].append(node)
    if not data.get("default"): data["default"] = node["id"]
    render(data); save_registry(data); print(f"已添加节点：{node['name']}（序号 {len(data['nodes'])}）"); return 0
def cmd_edit(args: argparse.Namespace) -> int:
    data = load_registry(); old = resolve_node(data, args.ref); node = build_node(old); ensure_unique_node_name(data, node, old.get("id")); node["id"] = old["id"]; data["nodes"][data["nodes"].index(old)] = node; render(data); save_registry(data); print("节点已更新。"); return 0
def cmd_delete(args: argparse.Namespace) -> int:
    data = load_registry(); node = resolve_node(data, args.ref)
    if not args.yes and prompt(f"确认删除 {node['name']}？输入 DELETE") != "DELETE": print("已取消。"); return 1
    data["nodes"] = [n for n in data["nodes"] if n.get("id") != node["id"]]
    for s in data.get("subscriptions", []): s["node_ids"] = [x for x in s.get("node_ids", []) if x != node["id"]]
    if data.get("default") == node["id"]: data["default"] = data["nodes"][0]["id"] if data["nodes"] else None
    repaired = repair_inbound_targets(data, [node["id"]])
    render(data); save_registry(data); print("节点已删除。" + (f" {repaired} 个入口已回退到 proxy/direct。" if repaired else "")); return 0
def cmd_default(args: argparse.Namespace) -> int:
    data = load_registry(); node = resolve_node(data, args.ref); data["default"] = node["id"]; data["settings"]["strategy"] = "manual"; render(data); save_registry(data); print(f"默认出口：{node['name']}；策略已切到 manual。"); return 0
def cmd_show(args: argparse.Namespace) -> int:
    data = load_registry(); print(json.dumps(redact(resolve_node(data, args.ref)), ensure_ascii=False, indent=2)); return 0
def cmd_render(args: argparse.Namespace) -> int: render(port=args.port); print(str(CONFIG)); return 0
def cmd_test_config(args: argparse.Namespace) -> int:
    data = load_registry(); atomic_json(Path(args.output), make_config(data, args.port, resolve_node(data, args.ref)), 0o600); return 0
def cmd_validate(_: argparse.Namespace) -> int: validate(); print("OK"); return 0
def cmd_import_uri(args: argparse.Namespace) -> int:
    uri = args.uri or prompt_secret("粘贴分享链接", required=True); data = load_registry(); node = parse_uri(uri); ids = add_imported_nodes(data, [node], "import-uri"); render(data); save_registry(data); print(f"导入成功: {data['nodes'][-1]['name']}（序号 {len(data['nodes'])}）"); return 0
def cmd_import_file(args: argparse.Namespace) -> int:
    text = Path(args.file).read_text(encoding="utf-8", errors="replace"); nodes, errors = parse_subscription(text)
    if not nodes: raise ValueError("没有解析到支持的节点" + (("；" + errors[0]) if errors else ""))
    data = load_registry(); ids = add_imported_nodes(data, nodes, args.source or "import-file"); render(data); save_registry(data)
    print(f"导入 {len(ids)} 个节点。")
    for err in errors[:10]: eprint("跳过:", err)
    if len(errors) > 10: eprint(f"另有 {len(errors)-10} 条错误未显示。")
    return 0
def cmd_inbound_list(_: argparse.Namespace) -> int:
    list_inbounds(); return 0


def cmd_inbound_endpoints(args: argparse.Namespace) -> int:
    data = load_registry()
    items = inbound_endpoints(data)
    if args.json:
        out = []
        for item in items:
            row = dict(item)
            row["resolved_outbound"] = "proxy" if item.get("id") == "default" else target_tag(data, item.get("target"))
            out.append(row)
        print(json.dumps(out, ensure_ascii=False))
    else:
        list_inbounds(data)
    return 0


def cmd_inbound_endpoint(args: argparse.Namespace) -> int:
    data = load_registry()
    item = resolve_inbound_endpoint(data, args.ref)
    out = dict(item)
    out["resolved_outbound"] = "proxy" if item.get("id") == "default" else target_tag(data, item.get("target"))
    print(json.dumps(out, ensure_ascii=False))
    return 0


def cmd_inbound_add(args: argparse.Namespace) -> int:
    data = load_registry()
    inbound = build_inbound(data, name=args.name, listen=args.listen, port=args.port, target_ref=args.target)
    inbound["id"] = new_id(data.get("inbounds", []))
    data.setdefault("inbounds", []).append(inbound)
    validate(data); render(data); save_registry(data)
    print(f"已添加入口：{inbound['name']} ({inbound['id']}) -> {target_label(data, inbound['target'])}")
    return 0


def cmd_inbound_edit(args: argparse.Namespace) -> int:
    data = load_registry(); old = resolve_inbound(data, args.ref)
    inbound = build_inbound(data, old, name=args.name, listen=args.listen, port=args.port, target_ref=args.target)
    inbound["id"] = old["id"]
    data["inbounds"][data["inbounds"].index(old)] = inbound
    validate(data); render(data); save_registry(data)
    print(f"入口已更新：{inbound['name']} -> {target_label(data, inbound['target'])}")
    return 0


def cmd_inbound_delete(args: argparse.Namespace) -> int:
    data = load_registry(); inbound = resolve_inbound(data, args.ref)
    if not args.yes and prompt(f"确认删除入口 {inbound['name']}？输入 DELETE") != "DELETE":
        print("已取消。"); return 1
    data["inbounds"] = [x for x in data.get("inbounds", []) if x.get("id") != inbound["id"]]
    render(data); save_registry(data); print("入口已删除。"); return 0


def cmd_inbound_show(args: argparse.Namespace) -> int:
    data = load_registry()
    inbound = resolve_inbound_endpoint(data, args.ref)
    out = dict(inbound)
    out["resolved_outbound"] = "proxy" if inbound.get("id") == "default" else target_tag(data, inbound.get("target"))
    print(json.dumps(out, ensure_ascii=False, indent=2)); return 0


def cmd_strategy(args: argparse.Namespace) -> int:
    data = load_registry()
    if not args.value: print(data["settings"]["strategy"]); return 0
    if args.value not in ("manual", "auto"): raise ValueError("策略只能是 manual 或 auto")
    if args.value == "auto" and not data["nodes"]: raise ValueError("没有节点，无法启用自动测速")
    data["settings"]["strategy"] = args.value; render(data); save_registry(data); print(f"strategy={args.value}"); return 0
def cmd_route(args: argparse.Namespace) -> int:
    data = load_registry()
    if not args.value: print(data["settings"]["route_mode"]); return 0
    if args.value not in ("global", "cn-direct-lite", "cn-direct-full"): raise ValueError("路由模式只能是 global / cn-direct-lite / cn-direct-full")
    data["settings"]["route_mode"] = args.value; render(data); save_registry(data); print(f"route_mode={args.value}"); return 0
def cmd_urltest(args: argparse.Namespace) -> int:
    data = load_registry(); ut = data["settings"]["urltest"]
    if args.url: ut["url"] = args.url
    if args.interval: ut["interval"] = args.interval
    if args.tolerance is not None: ut["tolerance"] = args.tolerance
    render(data); save_registry(data); print(json.dumps(ut, ensure_ascii=False, indent=2)); return 0
def cmd_sub_list(_: argparse.Namespace) -> int: list_subscriptions(); return 0
def cmd_sub_register(args: argparse.Namespace) -> int:
    data = load_registry(); sub_id = args.id or new_id(data.get("subscriptions", [])); existing = next((s for s in data.get("subscriptions", []) if s.get("id") == sub_id), None)
    meta = {"id": sub_id, "name": args.name or f"subscription-{sub_id[:4]}", "url": args.url}
    # 只更新元数据：清空 node_ids 会让这些节点变成永远无人管理的孤儿
    if existing:
        existing.update(meta); existing.setdefault("node_ids", [])
    else:
        data["subscriptions"].append({**meta, "node_ids": []})
    save_registry(data); print(sub_id); return 0
def cmd_sub_apply(args: argparse.Namespace) -> int:
    data = load_registry(); sub = resolve_subscription(data, args.ref); text = Path(args.file).read_text(encoding="utf-8", errors="replace"); nodes, errors = parse_subscription(text)
    if not nodes: raise ValueError("订阅未解析到支持的节点" + (("；" + errors[0]) if errors else ""))
    old_ids = list(sub.get("node_ids", []))
    old_default = data.get("default")
    old_names = {n.get("id"): n.get("name") for n in data["nodes"] if n.get("id") in set(old_ids)}
    ids = add_imported_nodes(data, nodes, f"sub:{sub['id']}", old_ids)
    new_by_name = {n.get("name"): n.get("id") for n in data["nodes"] if n.get("id") in set(ids)}
    replacements = {old_id: new_by_name[name] for old_id, name in old_names.items() if name in new_by_name}
    # 默认出口也要按名字跟着迁移，否则订阅里第一个节点会静默顶替用户选的默认节点
    migrated_default = new_by_name.get(old_names.get(old_default))
    if migrated_default:
        data["default"] = migrated_default
    repaired = repair_inbound_targets(data, old_ids, replacements)
    sub["node_ids"] = ids; render(data); save_registry(data); print(f"订阅 {sub['name']} 已导入 {len(ids)} 个节点。" + (f" 已迁移/回退 {repaired} 个入口绑定。" if repaired else ""))
    for err in errors[:10]: eprint("跳过:", err)
    return 0
def cmd_sub_delete(args: argparse.Namespace) -> int:
    data = load_registry(); sub = resolve_subscription(data, args.ref); ids = set(sub.get("node_ids", [])); data["nodes"] = [n for n in data["nodes"] if n.get("id") not in ids]; data["subscriptions"] = [s for s in data["subscriptions"] if s.get("id") != sub["id"]]
    if data.get("default") in ids: data["default"] = data["nodes"][0]["id"] if data["nodes"] else None
    repaired = repair_inbound_targets(data, ids)
    render(data); save_registry(data); print(f"订阅及其 {len(ids)} 个节点已删除。" + (f" {repaired} 个入口已回退到 proxy/direct。" if repaired else "")); return 0
def cmd_sub_get(args: argparse.Namespace) -> int:
    data = load_registry(); sub = resolve_subscription(data, args.ref)
    if args.field:
        value = sub.get(args.field, "")
        if isinstance(value, (dict, list)):
            print(json.dumps(value, ensure_ascii=False))
        else:
            print(value)
        return 0
    print(json.dumps(redact(sub), ensure_ascii=False, indent=2) if not args.raw else json.dumps(sub, ensure_ascii=False)); return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="singbox-manager helper"); sub = p.add_subparsers(dest="cmd", required=True)
    l=sub.add_parser("list"); l.add_argument("--ids", action="store_true", help="额外显示内部节点 ID")
    sub.add_parser("init").set_defaults(func=cmd_init); l.set_defaults(func=cmd_list); sub.add_parser("add").set_defaults(func=cmd_add)
    e=sub.add_parser("edit"); e.add_argument("ref", nargs="?"); e.set_defaults(func=cmd_edit)
    d=sub.add_parser("delete"); d.add_argument("ref", nargs="?"); d.add_argument("--yes", action="store_true"); d.set_defaults(func=cmd_delete)
    df=sub.add_parser("default"); df.add_argument("ref", nargs="?"); df.set_defaults(func=cmd_default)
    s=sub.add_parser("show"); s.add_argument("ref", nargs="?"); s.set_defaults(func=cmd_show)
    r=sub.add_parser("render"); r.add_argument("--port", type=int, default=7890); r.set_defaults(func=cmd_render)
    t=sub.add_parser("test-config"); t.add_argument("ref", nargs="?"); t.add_argument("--output", required=True); t.add_argument("--port", type=int, default=7891); t.set_defaults(func=cmd_test_config)
    sub.add_parser("validate").set_defaults(func=cmd_validate)
    iu=sub.add_parser("import-uri"); iu.add_argument("uri", nargs="?"); iu.set_defaults(func=cmd_import_uri)
    im=sub.add_parser("import-file"); im.add_argument("file"); im.add_argument("--source"); im.set_defaults(func=cmd_import_file)
    il=sub.add_parser("inbound-list"); il.set_defaults(func=cmd_inbound_list)
    ieps=sub.add_parser("inbound-endpoints"); ieps.add_argument("--json", action="store_true"); ieps.set_defaults(func=cmd_inbound_endpoints)
    iep=sub.add_parser("inbound-endpoint"); iep.add_argument("ref", nargs="?", default="default"); iep.set_defaults(func=cmd_inbound_endpoint)
    ia=sub.add_parser("inbound-add"); ia.add_argument("--name"); ia.add_argument("--listen"); ia.add_argument("--port", type=int); ia.add_argument("--target"); ia.set_defaults(func=cmd_inbound_add)
    ie=sub.add_parser("inbound-edit"); ie.add_argument("ref", nargs="?"); ie.add_argument("--name"); ie.add_argument("--listen"); ie.add_argument("--port", type=int); ie.add_argument("--target"); ie.set_defaults(func=cmd_inbound_edit)
    idel=sub.add_parser("inbound-delete"); idel.add_argument("ref", nargs="?"); idel.add_argument("--yes", action="store_true"); idel.set_defaults(func=cmd_inbound_delete)
    ish=sub.add_parser("inbound-show"); ish.add_argument("ref", nargs="?"); ish.set_defaults(func=cmd_inbound_show)
    st=sub.add_parser("strategy"); st.add_argument("value", nargs="?"); st.set_defaults(func=cmd_strategy)
    rt=sub.add_parser("route-mode"); rt.add_argument("value", nargs="?"); rt.set_defaults(func=cmd_route)
    ut=sub.add_parser("urltest"); ut.add_argument("--url"); ut.add_argument("--interval"); ut.add_argument("--tolerance", type=int); ut.set_defaults(func=cmd_urltest)
    sub.add_parser("sub-list").set_defaults(func=cmd_sub_list)
    sr=sub.add_parser("sub-register"); sr.add_argument("url"); sr.add_argument("--name"); sr.add_argument("--id"); sr.set_defaults(func=cmd_sub_register)
    sa=sub.add_parser("sub-apply"); sa.add_argument("ref"); sa.add_argument("file"); sa.set_defaults(func=cmd_sub_apply)
    sd=sub.add_parser("sub-delete"); sd.add_argument("ref", nargs="?"); sd.set_defaults(func=cmd_sub_delete)
    sg=sub.add_parser("sub-get"); sg.add_argument("ref", nargs="?"); sg.add_argument("--raw", action="store_true"); sg.add_argument("--field"); sg.set_defaults(func=cmd_sub_get)
    return p


def main() -> int:
    try:
        args = parser().parse_args()
        if getattr(args, "cmd", None) in MUTATING_COMMANDS:
            acquire_registry_lock()
        return int(args.func(args) or 0)
    except (ValueError, KeyError, TypeError, json.JSONDecodeError, OSError) as exc:
        eprint(f"错误: {exc}"); return 2
    except KeyboardInterrupt:
        eprint("\n已取消。"); return 130

if __name__ == "__main__": raise SystemExit(main())
