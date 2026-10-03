#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

HOME = Path(os.environ.get("SBX_HOME", "/opt/singbox-manager"))
STATE = Path(os.environ.get("SBX_DOCKER_MANAGED_FILE", str(HOME / "docker-managed.json")))
STATE_VERSION = 1


def run(cmd: List[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, check=check)


def docker_json(ref: str) -> Dict[str, Any]:
    cp = run(["docker", "inspect", ref])
    data = json.loads(cp.stdout)
    if not data:
        raise ValueError(f"未找到容器: {ref}")
    return data[0]


def container_name(obj: Dict[str, Any]) -> str:
    return str(obj.get("Name", "")).lstrip("/")


def labels(obj: Dict[str, Any]) -> Dict[str, str]:
    return ((obj.get("Config") or {}).get("Labels") or {})


def identity(obj: Dict[str, Any]) -> Dict[str, Any]:
    lbs = labels(obj)
    project = lbs.get("com.docker.compose.project")
    service = lbs.get("com.docker.compose.service")
    if project and service:
        return {
            "type": "compose",
            "project": project,
            "service": service,
        }
    return {
        "type": "name",
        "name": container_name(obj),
    }


def target_key(target: Dict[str, Any]) -> str:
    if target.get("type") == "compose":
        return f"compose:{target.get('project','')}/{target.get('service','')}"
    return f"name:{target.get('name','')}"


def load_state() -> Dict[str, Any]:
    if not STATE.exists():
        return {"version": STATE_VERSION, "targets": []}
    try:
        data = json.loads(STATE.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ValueError(f"托管文件损坏: {STATE}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("托管文件格式无效")
    if not isinstance(data.get("targets"), list):
        data["targets"] = []
    else:
        # 脏条目（非对象）会让后续 target.get() 抛 AttributeError
        data["targets"] = [x for x in data["targets"] if isinstance(x, dict)]
    data["version"] = STATE_VERSION
    return data


def save_state(data: Dict[str, Any]) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmpname = tempfile.mkstemp(prefix=".docker-managed.", dir=str(STATE.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.chmod(tmpname, 0o600)
        os.replace(tmpname, STATE)
        os.chmod(STATE, 0o600)
    finally:
        if os.path.exists(tmpname):
            os.unlink(tmpname)


def all_containers() -> List[Dict[str, Any]]:
    cp = run(["docker", "ps", "-aq"], check=False)
    ids = [x.strip() for x in cp.stdout.splitlines() if x.strip()]
    if not ids:
        return []
    # ps -aq 与批量 inspect 之间容器可能已经消失（compose 重建、--rm 短命容器），
    # 一个失效 ID 不能让整次 scan/list/sync 失败：批量失败就逐个降级重试。
    cp = run(["docker", "inspect", *ids], check=False)
    if cp.returncode == 0:
        try:
            data = json.loads(cp.stdout)
        except json.JSONDecodeError:
            data = []
        return data if isinstance(data, list) else []
    objects: List[Dict[str, Any]] = []
    for cid in ids:
        one = run(["docker", "inspect", cid], check=False)
        if one.returncode:
            continue
        try:
            data = json.loads(one.stdout)
        except json.JSONDecodeError:
            continue
        if isinstance(data, list):
            objects.extend(x for x in data if isinstance(x, dict))
    return objects


def running(obj: Dict[str, Any]) -> bool:
    return bool((obj.get("State") or {}).get("Running"))


def connected(obj: Dict[str, Any], network: str) -> bool:
    return network in ((obj.get("NetworkSettings") or {}).get("Networks") or {})


def env_file_values() -> Dict[str, str]:
    """读取 $SBX_HOME/.env：容器名等配置只写在那里，不会出现在进程环境变量中。"""
    out: Dict[str, str] = {}
    try:
        text = (HOME / ".env").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for line in text.splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def sing_box_container_name() -> str:
    # 显式环境变量优先（sbx 调用时会传），否则回退读 .env，再否则用 compose 默认值。
    # 只用 os.environ 会让这里恒为 "sing-box"，与 .env 中用户配置不一致。
    name = os.environ.get("SING_BOX_CONTAINER_NAME") or env_file_values().get("SING_BOX_CONTAINER_NAME")
    return (name or "sing-box").strip()


def is_manager_container(obj: Dict[str, Any]) -> bool:
    name = container_name(obj)
    return name == sing_box_container_name() or name.startswith("sbx-node-test-")


def matches(target: Dict[str, Any], obj: Dict[str, Any]) -> bool:
    ident = identity(obj)
    if target.get("type") == "compose":
        return (
            ident.get("type") == "compose"
            and ident.get("project") == target.get("project")
            and ident.get("service") == target.get("service")
        )
    return ident.get("type") == "name" and ident.get("name") == target.get("name")


def scan_rows() -> List[Dict[str, Any]]:
    state = load_state()
    managed = {target_key(x): x for x in state["targets"]}
    rows = []
    for obj in all_containers():
        if is_manager_container(obj):
            continue
        ident = identity(obj)
        key = target_key(ident)
        rows.append({
            "id": str(obj.get("Id", ""))[:12],
            "name": container_name(obj),
            "image": str((obj.get("Config") or {}).get("Image", "")),
            "running": running(obj),
            "type": ident["type"],
            "project": ident.get("project"),
            "service": ident.get("service"),
            "key": key,
            "managed": key in managed,
            "inbound_id": (managed.get(key) or {}).get("inbound_id"),
            "legacy_port": (managed.get(key) or {}).get("port"),
        })
    rows.sort(key=lambda x: (x.get("project") or "", x.get("service") or "", x["name"]))
    return rows


def add_target(ref: str, inbound_id: str) -> Dict[str, Any]:
    inbound_id = str(inbound_id or "").strip()
    if not inbound_id:
        raise ValueError("代理入口 ID 不能为空")
    obj = docker_json(ref)
    if is_manager_container(obj):
        raise ValueError("不能把 sing-box 自己加入托管目标")
    target = identity(obj)
    target["inbound_id"] = inbound_id
    target["last_name"] = container_name(obj)
    state = load_state()
    key = target_key(target)
    state["targets"] = [x for x in state["targets"] if target_key(x) != key]
    state["targets"].append(target)
    save_state(state)
    return target


def remove_target(ref: str) -> Dict[str, Any]:
    state = load_state()
    target: Optional[Dict[str, Any]] = None
    if ref.startswith("compose:") or ref.startswith("name:"):
        target = next((x for x in state["targets"] if target_key(x) == ref), None)
    else:
        try:
            obj = docker_json(ref)
            key = target_key(identity(obj))
            target = next((x for x in state["targets"] if target_key(x) == key), None)
        except Exception:
            target = next(
                (x for x in state["targets"] if x.get("last_name") == ref or x.get("name") == ref),
                None,
            )
    if not target:
        raise ValueError(f"未找到托管目标: {ref}")
    key = target_key(target)
    state["targets"] = [x for x in state["targets"] if target_key(x) != key]
    save_state(state)
    return target


def resolve_target(target: Dict[str, Any], objects: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [obj for obj in objects if matches(target, obj)]


def list_rows(network: Optional[str] = None) -> List[Dict[str, Any]]:
    state = load_state()
    objects = all_containers()
    rows = []
    for target in state["targets"]:
        found = resolve_target(target, objects)
        active = [x for x in found if running(x)]
        rows.append({
            **target,
            "key": target_key(target),
            "matches": [container_name(x) for x in found],
            "running": [container_name(x) for x in active],
            "connected": [
                container_name(x) for x in active if network and connected(x, network)
            ],
        })
    return rows


def network_exists(network: str) -> bool:
    return run(["docker", "network", "inspect", network], check=False).returncode == 0


def sync(network: str, quiet: bool = False) -> Dict[str, int]:
    if not network_exists(network):
        raise ValueError(f"Docker 网络不存在: {network}")
    state = load_state()
    objects = all_containers()
    result = {"targets": len(state["targets"]), "matched": 0, "connected": 0, "already": 0}
    for target in state["targets"]:
        found = [x for x in resolve_target(target, objects) if running(x)]
        result["matched"] += len(found)
        for obj in found:
            name = container_name(obj)
            if connected(obj, network):
                result["already"] += 1
                continue
            cp = run(["docker", "network", "connect", network, name], check=False)
            if cp.returncode == 0:
                result["connected"] += 1
                if not quiet:
                    print(f"已自动接入: {name} -> {network}")
                continue
            # 竞态：从上面取快照到真正 connect 之间，容器可能已经被接进去了
            # （典型场景：用户同时在跑 `sbx docker-network manage`，watcher 又被
            #  同一个 create/start 事件唤醒）。此时 daemon 会回
            #  "endpoint ... already exists in network"，但目标状态其实已经达成。
            # 重新 inspect 一次再决定要不要报错，免得日志里出现假的“接入失败”。
            current = None
            try:
                current = docker_json(name)
            except (ValueError, subprocess.SubprocessError, json.JSONDecodeError):
                current = None
            if current is not None and connected(current, network):
                result["already"] += 1
                if not quiet:
                    print(f"已在共享网络中: {name} -> {network}")
            elif not quiet:
                print(f"接入失败: {name}: {cp.stderr.strip()}", file=sys.stderr)
    return result


def print_scan(rows: List[Dict[str, Any]]) -> None:
    if not rows:
        print("未发现可选择的 Docker 容器。")
        return
    print(f"{'#':<4} {'容器':<26} {'状态':<8} {'类型':<10} {'Compose project/service':<32} 托管")
    print("-" * 100)
    for idx, row in enumerate(rows, 1):
        comp = ""
        if row["type"] == "compose":
            comp = f"{row.get('project')}/{row.get('service')}"
        managed_ref = row.get("inbound_id") or (f"legacy:{row.get('legacy_port')}" if row.get("legacy_port") else "")
        managed = f"YES:{managed_ref}" if row["managed"] else "NO"
        print(f"{idx:<4} {row['name'][:24]:<26} {('RUN' if row['running'] else 'STOP'):<8} {row['type']:<10} {comp[:30]:<32} {managed}")


def print_list(rows: List[Dict[str, Any]]) -> None:
    if not rows:
        print("暂无托管 Docker 目标。")
        return
    print(f"{'KEY':<42} {'INBOUND_ID':<12} {'MATCH':<24} {'RUN':<20} CONNECTED")
    print("-" * 122)
    for row in rows:
        inbound_id = row.get("inbound_id") or (f"legacy:{row.get('port')}" if row.get("port") else "")
        print(
            f"{row['key'][:40]:<42} {str(inbound_id)[:10]:<12} "
            f"{','.join(row['matches'])[:22]:<24} {','.join(row['running'])[:18]:<20} "
            f"{','.join(row['connected'])}"
        )


def cmd_scan(args: argparse.Namespace) -> int:
    rows = scan_rows()
    if args.json:
        print(json.dumps(rows, ensure_ascii=False))
    else:
        print_scan(rows)
    return 0


def cmd_add(args: argparse.Namespace) -> int:
    target = add_target(args.container, args.inbound_id)
    print(json.dumps({**target, "key": target_key(target)}, ensure_ascii=False))
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    target = remove_target(args.ref)
    print(f"已取消托管: {target_key(target)}")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    rows = list_rows(args.network)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False))
    else:
        print_list(rows)
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    result = sync(args.network, args.quiet)
    if not args.quiet:
        print(
            f"同步完成: targets={result['targets']} matched={result['matched']} "
            f"new={result['connected']} existing={result['already']}"
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)

    s = sp.add_parser("scan")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_scan)

    a = sp.add_parser("add")
    a.add_argument("container")
    a.add_argument("--inbound-id", required=True)
    a.set_defaults(func=cmd_add)

    r = sp.add_parser("remove")
    r.add_argument("ref")
    r.set_defaults(func=cmd_remove)

    l = sp.add_parser("list")
    l.add_argument("--network")
    l.add_argument("--json", action="store_true")
    l.set_defaults(func=cmd_list)

    sy = sp.add_parser("sync")
    sy.add_argument("--network", required=True)
    sy.add_argument("--quiet", action="store_true")
    sy.set_defaults(func=cmd_sync)

    return p


def main() -> int:
    try:
        args = build_parser().parse_args()
        return int(args.func(args) or 0)
    except (ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
