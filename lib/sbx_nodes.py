#!/usr/bin/env python3
import argparse
import getpass
import ipaddress
import json
import os
import re
import secrets
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

HOME = Path(os.environ.get("SBX_HOME", "/opt/singbox-manager"))
REGISTRY = HOME / "nodes" / "nodes.json"
CONFIG = HOME / "config" / "config.json"

SUPPORTED = ("shadowsocks", "vless", "trojan", "hysteria2", "socks")


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


def load_registry() -> Dict[str, Any]:
    if not REGISTRY.exists():
        return {"version": 1, "default": None, "nodes": []}
    with REGISTRY.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("nodes"), list):
        raise ValueError("节点库格式无效")
    data.setdefault("version", 1)
    data.setdefault("default", None)
    return data


def save_registry(data: Dict[str, Any]) -> None:
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
    hint = " [直接回车保持不变]" if current is not None else ""
    while True:
        try:
            value = getpass.getpass(f"{text}{hint}: ").strip()
        except (EOFError, KeyboardInterrupt):
            raise SystemExit("输入已终止")
        if not value and current is not None:
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


def is_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def new_id(existing: List[Dict[str, Any]]) -> str:
    used = {n.get("id") for n in existing}
    while True:
        candidate = secrets.token_hex(4)
        if candidate not in used:
            return candidate


def node_tag(node: Dict[str, Any]) -> str:
    return f"node-{node['id']}"


def resolve_node(data: Dict[str, Any], ref: Optional[str]) -> Dict[str, Any]:
    nodes = data["nodes"]
    if not nodes:
        raise ValueError("当前没有节点")
    if not ref:
        list_nodes(data)
        ref = prompt("请输入节点 ID 或名称", required=True)
    exact_id = [n for n in nodes if n.get("id") == ref]
    if len(exact_id) == 1:
        return exact_id[0]
    prefix = [n for n in nodes if str(n.get("id", "")).startswith(ref)]
    if len(prefix) == 1:
        return prefix[0]
    by_name = [n for n in nodes if n.get("name") == ref]
    if len(by_name) == 1:
        return by_name[0]
    if len(prefix) > 1 or len(by_name) > 1:
        raise ValueError("匹配到多个节点，请使用完整 ID")
    raise ValueError(f"未找到节点: {ref}")


def choose_protocol(current: Optional[str] = None) -> str:
    items = [
        ("1", "shadowsocks", "Shadowsocks"),
        ("2", "vless", "VLESS"),
        ("3", "trojan", "Trojan"),
        ("4", "hysteria2", "Hysteria2"),
        ("5", "socks", "SOCKS5"),
    ]
    print("\n支持的节点协议：")
    for num, key, label in items:
        suffix = "  <- 当前" if current == key else ""
        print(f"  {num}. {label}{suffix}")
    default_num = next((num for num, key, _ in items if key == current), None)
    while True:
        raw = prompt("请选择协议", default_num, required=True)
        for num, key, _ in items:
            if raw == num or raw.lower() == key:
                return key
        print("无效协议。")


def tls_fields(existing: Optional[Dict[str, Any]], server: str, required: bool = False, allow_reality: bool = False) -> Optional[Dict[str, Any]]:
    existing = existing or {}
    enabled_default = bool(existing.get("enabled", required))
    enabled = True if required else prompt_bool("启用 TLS", enabled_default)
    if not enabled:
        return None
    default_sni = str(existing.get("server_name") or ("" if is_ip(server) else server))
    sni = prompt("TLS Server Name / SNI", default_sni)
    insecure = prompt_bool("跳过证书校验（不推荐）", bool(existing.get("insecure", False)))
    tls: Dict[str, Any] = {"enabled": True, "insecure": insecure}
    if sni:
        tls["server_name"] = sni

    if allow_reality:
        old_reality = existing.get("reality") if isinstance(existing.get("reality"), dict) else {}
        use_reality = prompt_bool("使用 Reality", bool(old_reality and old_reality.get("enabled")))
        if use_reality:
            public_key = prompt_secret("Reality Public Key", old_reality.get("public_key"), required=True)
            short_id = prompt("Reality Short ID", old_reality.get("short_id", ""), required=True)
            if not re.fullmatch(r"[0-9a-fA-F]{0,16}", short_id):
                raise ValueError("Reality Short ID 必须是 0-16 位十六进制字符串")
            tls["reality"] = {
                "enabled": True,
                "public_key": public_key,
                "short_id": short_id,
            }
    return tls


def transport_fields(existing: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    existing = existing or {}
    old_type = existing.get("type", "")
    choices = {"1": "", "2": "ws", "3": "grpc", "4": "httpupgrade"}
    reverse = {v: k for k, v in choices.items()}
    print("\n传输方式：")
    print("  1. TCP / 默认")
    print("  2. WebSocket")
    print("  3. gRPC")
    print("  4. HTTPUpgrade")
    raw = prompt("请选择传输方式", reverse.get(old_type, "1"), required=True)
    kind = choices.get(raw)
    if kind is None:
        raise ValueError("无效传输方式")
    if not kind:
        return None
    if kind == "ws":
        path = prompt("WebSocket Path", existing.get("path", "/"))
        host = prompt("WebSocket Host（可留空）", (existing.get("headers") or {}).get("Host", ""))
        result: Dict[str, Any] = {"type": "ws", "path": path or "/"}
        if host:
            result["headers"] = {"Host": host}
        return result
    if kind == "grpc":
        service = prompt("gRPC Service Name", existing.get("service_name", ""))
        result = {"type": "grpc"}
        if service:
            result["service_name"] = service
        return result
    host = prompt("HTTPUpgrade Host（可留空）", existing.get("host", ""))
    path = prompt("HTTPUpgrade Path", existing.get("path", "/"))
    result = {"type": "httpupgrade", "path": path or "/"}
    if host:
        result["host"] = host
    return result


def build_node(existing: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    existing = existing or {}
    protocol = choose_protocol(existing.get("type"))
    name = prompt("节点名称", existing.get("name"), required=True)
    server = prompt("服务器地址", existing.get("server"), required=True)
    port = prompt_port("服务器端口", existing.get("server_port"))

    node: Dict[str, Any] = {
        "id": existing.get("id"),
        "name": name,
        "type": protocol,
        "server": server,
        "server_port": port,
    }

    if protocol == "shadowsocks":
        method = prompt("加密方式", existing.get("method", "aes-256-gcm"), required=True)
        password = prompt_secret("密码", existing.get("password"), required=True)
        node.update(method=method, password=password)

    elif protocol == "socks":
        username = prompt("用户名（可留空）", existing.get("username", ""))
        password = prompt_secret("密码（可留空）", existing.get("password")) if username else ""
        node["version"] = "5"
        if username:
            node["username"] = username
            node["password"] = password

    elif protocol == "trojan":
        password = prompt_secret("Trojan 密码", existing.get("password"), required=True)
        node["password"] = password
        node["tls"] = tls_fields(existing.get("tls"), server, required=True)
        transport = transport_fields(existing.get("transport"))
        if transport:
            node["transport"] = transport

    elif protocol == "vless":
        uuid = prompt_secret("VLESS UUID", existing.get("uuid"), required=True)
        if not re.fullmatch(r"[0-9a-fA-F-]{32,36}", uuid):
            print("提示：UUID 格式看起来不标准，仍将保存并交给 sing-box check 验证。")
        flow = prompt("Flow（通常留空；Reality Vision 可填 xtls-rprx-vision）", existing.get("flow", ""))
        node["uuid"] = uuid
        if flow:
            node["flow"] = flow
        tls = tls_fields(existing.get("tls"), server, required=False, allow_reality=True)
        if tls:
            node["tls"] = tls
        transport = transport_fields(existing.get("transport"))
        if transport:
            node["transport"] = transport

    elif protocol == "hysteria2":
        password = prompt_secret("Hysteria2 密码", existing.get("password"), required=True)
        node["password"] = password
        node["tls"] = tls_fields(existing.get("tls"), server, required=True)
        old_obfs = existing.get("obfs") if isinstance(existing.get("obfs"), dict) else {}
        use_obfs = prompt_bool("启用 Salamander 混淆", bool(old_obfs))
        if use_obfs:
            obfs_password = prompt_secret("Obfs 密码", old_obfs.get("password"), required=True)
            node["obfs"] = {"type": "salamander", "password": obfs_password}

    return node


def outbound_from_node(node: Dict[str, Any]) -> Dict[str, Any]:
    typ = node["type"]
    out: Dict[str, Any] = {
        "type": typ,
        "tag": node_tag(node),
        "server": node["server"],
        "server_port": int(node["server_port"]),
    }
    if typ == "shadowsocks":
        out.update(method=node["method"], password=node["password"])
    elif typ == "socks":
        out["version"] = node.get("version", "5")
        if node.get("username"):
            out["username"] = node["username"]
            out["password"] = node.get("password", "")
    elif typ == "trojan":
        out["password"] = node["password"]
        out["tls"] = node["tls"]
        if node.get("transport"):
            out["transport"] = node["transport"]
    elif typ == "vless":
        out["uuid"] = node["uuid"]
        if node.get("flow"):
            out["flow"] = node["flow"]
        if node.get("tls"):
            out["tls"] = node["tls"]
        if node.get("transport"):
            out["transport"] = node["transport"]
    elif typ == "hysteria2":
        out["password"] = node["password"]
        out["tls"] = node["tls"]
        if node.get("obfs"):
            out["obfs"] = node["obfs"]
    else:
        raise ValueError(f"暂不支持协议: {typ}")
    return out


def make_config(data: Dict[str, Any], listen_port: int = 7890, only_node: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    nodes = [only_node] if only_node else data["nodes"]
    outbounds = [outbound_from_node(n) for n in nodes]
    outbounds.append({"type": "direct", "tag": "direct"})

    if only_node:
        final = node_tag(only_node)
    else:
        default_id = data.get("default")
        default_node = next((n for n in data["nodes"] if n.get("id") == default_id), None)
        final = node_tag(default_node) if default_node else "direct"

    return {
        "$schema": "https://sing-box.sagernet.org/schema.json",
        "log": {"level": "info", "timestamp": True},
        "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "0.0.0.0",
                "listen_port": int(listen_port),
            }
        ],
        "outbounds": outbounds,
        "route": {"final": final},
    }


def render(data: Optional[Dict[str, Any]] = None, target: Optional[Path] = None, port: int = 7890) -> None:
    data = data or load_registry()
    atomic_json(target or CONFIG, make_config(data, port))


def list_nodes(data: Optional[Dict[str, Any]] = None) -> None:
    data = data or load_registry()
    nodes = data["nodes"]
    if not nodes:
        print("暂无节点。")
        return
    print(f"{'默认':<4} {'ID':<10} {'协议':<12} {'名称':<20} 地址")
    print("-" * 78)
    for n in nodes:
        mark = "*" if n.get("id") == data.get("default") else ""
        addr = f"{n.get('server')}:{n.get('server_port')}"
        print(f"{mark:<4} {n.get('id',''):<10} {n.get('type',''):<12} {n.get('name','')[:18]:<20} {addr}")


def redact(value: Any, key: str = "") -> Any:
    secret_keys = {"password", "uuid", "public_key"}
    if isinstance(value, dict):
        return {k: redact(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v, key) for v in value]
    if key in secret_keys and isinstance(value, str) and value:
        if len(value) <= 8:
            return "***"
        return value[:4] + "..." + value[-4:]
    return value


def cmd_init(_: argparse.Namespace) -> int:
    data = load_registry()
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    save_registry(data)
    if not CONFIG.exists():
        render(data)
    return 0


def cmd_list(_: argparse.Namespace) -> int:
    list_nodes()
    return 0


def cmd_add(_: argparse.Namespace) -> int:
    data = load_registry()
    print("\n=== 添加节点 ===")
    node = build_node()
    node["id"] = new_id(data["nodes"])
    data["nodes"].append(node)
    if not data.get("default"):
        data["default"] = node["id"]
    save_registry(data)
    render(data)
    print(f"\n已添加节点：{node['name']} ({node['id']})")
    if data.get("default") == node["id"]:
        print("该节点已设为默认出口。")
    return 0


def cmd_edit(args: argparse.Namespace) -> int:
    data = load_registry()
    node = resolve_node(data, args.ref)
    print(f"\n=== 编辑节点：{node['name']} ({node['id']}) ===")
    updated = build_node(node)
    updated["id"] = node["id"]
    idx = data["nodes"].index(node)
    data["nodes"][idx] = updated
    save_registry(data)
    render(data)
    print("节点已更新。")
    return 0


def cmd_delete(args: argparse.Namespace) -> int:
    data = load_registry()
    node = resolve_node(data, args.ref)
    if not args.yes:
        answer = prompt(f"确认删除节点 {node['name']} ({node['id']})？输入 DELETE")
        if answer != "DELETE":
            print("已取消。")
            return 1
    data["nodes"] = [n for n in data["nodes"] if n.get("id") != node.get("id")]
    if data.get("default") == node.get("id"):
        data["default"] = data["nodes"][0]["id"] if data["nodes"] else None
    save_registry(data)
    render(data)
    print("节点已删除。")
    return 0


def cmd_default(args: argparse.Namespace) -> int:
    data = load_registry()
    node = resolve_node(data, args.ref)
    data["default"] = node["id"]
    save_registry(data)
    render(data)
    print(f"默认出口已切换为：{node['name']} ({node['id']})")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    data = load_registry()
    node = resolve_node(data, args.ref)
    print(json.dumps(redact(node), ensure_ascii=False, indent=2))
    return 0


def cmd_render(args: argparse.Namespace) -> int:
    render(port=args.port)
    print(str(CONFIG))
    return 0


def cmd_test_config(args: argparse.Namespace) -> int:
    data = load_registry()
    node = resolve_node(data, args.ref)
    target = Path(args.output)
    atomic_json(target, make_config(data, args.port, only_node=node), 0o600)
    return 0


def cmd_validate(_: argparse.Namespace) -> int:
    data = load_registry()
    ids = [n.get("id") for n in data["nodes"]]
    if len(ids) != len(set(ids)):
        raise ValueError("节点 ID 重复")
    for n in data["nodes"]:
        if n.get("type") not in SUPPORTED:
            raise ValueError(f"不支持的节点协议: {n.get('type')}")
        if not n.get("id") or not n.get("name") or not n.get("server"):
            raise ValueError("节点缺少必要字段")
        port = int(n.get("server_port", 0))
        if not 1 <= port <= 65535:
            raise ValueError(f"节点端口无效: {n.get('name')}")
        outbound_from_node(n)
    if data.get("default") is not None and data.get("default") not in ids:
        raise ValueError("默认节点不存在")
    make_config(data)
    print("OK")
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="singbox-manager node helper")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init").set_defaults(func=cmd_init)
    sub.add_parser("list").set_defaults(func=cmd_list)
    a = sub.add_parser("add"); a.set_defaults(func=cmd_add)
    e = sub.add_parser("edit"); e.add_argument("ref", nargs="?"); e.set_defaults(func=cmd_edit)
    d = sub.add_parser("delete"); d.add_argument("ref", nargs="?"); d.add_argument("--yes", action="store_true"); d.set_defaults(func=cmd_delete)
    df = sub.add_parser("default"); df.add_argument("ref", nargs="?"); df.set_defaults(func=cmd_default)
    s = sub.add_parser("show"); s.add_argument("ref", nargs="?"); s.set_defaults(func=cmd_show)
    r = sub.add_parser("render"); r.add_argument("--port", type=int, default=7890); r.set_defaults(func=cmd_render)
    t = sub.add_parser("test-config"); t.add_argument("ref", nargs="?"); t.add_argument("--output", required=True); t.add_argument("--port", type=int, default=7891); t.set_defaults(func=cmd_test_config)
    sub.add_parser("validate").set_defaults(func=cmd_validate)
    return p


def main() -> int:
    try:
        args = parser().parse_args()
        return int(args.func(args) or 0)
    except (ValueError, KeyError, json.JSONDecodeError) as exc:
        eprint(f"错误: {exc}")
        return 2
    except KeyboardInterrupt:
        eprint("\n已取消。")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
