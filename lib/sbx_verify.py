#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HOME = Path(os.environ.get("SBX_HOME", "/opt/singbox-manager"))
ENV_FILE = HOME / ".env"
VERSION_FILE = HOME / "VERSION"
NODE_HELPER = HOME / "lib" / "sbx_nodes.py"
TARGET_HELPER = HOME / "lib" / "sbx_docker_targets.py"
MANAGED_FILE = HOME / "docker-managed.json"
SBX_BIN = os.environ.get("SBX_VERIFY_SBX", "/usr/local/bin/sbx")
NETWORK_DEFAULT = "singbox-proxy"


class Result:
    def __init__(self) -> None:
        self.passed = 0
        self.warned = 0
        self.failed = 0

    def ok(self, msg: str) -> None:
        self.passed += 1
        print(f"PASS  {msg}")

    def warn(self, msg: str) -> None:
        self.warned += 1
        print(f"WARN  {msg}")

    def fail(self, msg: str) -> None:
        self.failed += 1
        print(f"FAIL  {msg}")

    def summary(self) -> int:
        print("─" * 48)
        print(f"结果: PASS={self.passed}  WARN={self.warned}  FAIL={self.failed}")
        return 1 if self.failed else 0


def run(cmd: List[str], timeout: int = 20) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(cmd, 124, "", str(exc))


def env_values() -> Dict[str, str]:
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


def docker_json(ref: str) -> Optional[Dict[str, Any]]:
    cp = run(["docker", "inspect", ref], 8)
    if cp.returncode:
        return None
    try:
        data = json.loads(cp.stdout)
        return data[0] if data else None
    except Exception:
        return None


def container_name(obj: Dict[str, Any]) -> str:
    return str(obj.get("Name", "")).lstrip("/")


def network_name() -> str:
    return env_values().get("SING_BOX_DOCKER_NETWORK", NETWORK_DEFAULT)


def endpoints() -> List[Dict[str, Any]]:
    cp = run(["python3", str(NODE_HELPER), "inbound-endpoints", "--json"])
    if cp.returncode:
        return []
    try:
        data = json.loads(cp.stdout)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def resolve_endpoint(ref: str) -> Optional[Dict[str, Any]]:
    items = endpoints()
    raw = (ref or "default").strip()
    exact = [x for x in items if str(x.get("id")) == raw]
    if len(exact) == 1:
        return exact[0]
    prefix = [x for x in items if str(x.get("id", "")).startswith(raw)]
    if len(prefix) == 1:
        return prefix[0]
    named = [x for x in items if str(x.get("name", "")) == raw]
    if len(named) == 1:
        return named[0]
    if raw.isdigit():
        by_port = [x for x in items if int(x.get("port", 0)) == int(raw)]
        if len(by_port) == 1:
            return by_port[0]
    return None


def managed_rows() -> List[Dict[str, Any]]:
    if not TARGET_HELPER.exists():
        return []
    env = os.environ.copy()
    env["SBX_DOCKER_MANAGED_FILE"] = str(MANAGED_FILE)
    try:
        cp = subprocess.run(
            ["python3", str(TARGET_HELPER), "list", "--network", network_name(), "--json"],
            text=True, capture_output=True, timeout=15, env=env
        )
    except Exception:
        return []
    if cp.returncode:
        return []
    try:
        rows = json.loads(cp.stdout)
        return rows if isinstance(rows, list) else []
    except Exception:
        return []


def managed_inbound_for(name: str) -> Optional[str]:
    for row in managed_rows():
        names = set(row.get("matches", [])) | set(row.get("running", []))
        if name in names:
            value = row.get("inbound_id")
            if value:
                return str(value)
            legacy = row.get("port")
            if legacy is not None:
                ep = resolve_endpoint(str(legacy))
                return str(ep.get("id")) if ep else None
    return None


def network_inspect() -> Optional[Dict[str, Any]]:
    cp = run(["docker", "network", "inspect", network_name()], 8)
    if cp.returncode:
        return None
    try:
        data = json.loads(cp.stdout)
        return data[0] if data else None
    except Exception:
        return None


def network_members(net: Optional[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    if not net:
        return {}
    return {
        str(v.get("Name", "")): v
        for v in (net.get("Containers") or {}).values()
        if v.get("Name")
    }


def proxy_env(obj: Dict[str, Any]) -> List[str]:
    values = ((obj.get("Config") or {}).get("Env") or [])
    keys = {"http_proxy", "https_proxy", "all_proxy"}
    out = []
    for entry in values:
        key = str(entry).split("=", 1)[0].lower()
        if key in keys:
            out.append(str(entry))
    return out


def watcher_active() -> bool:
    if not shutil.which("systemctl"):
        return False
    return run(["systemctl", "is-active", "--quiet", "singbox-manager-docker-watch.service"], 5).returncode == 0


def active_proxy_probe(obj: Dict[str, Any], singbox_ip: str, port: int) -> Tuple[bool, str]:
    if not shutil.which("nsenter") or not shutil.which("curl"):
        return False, "宿主机缺少 nsenter 或 curl"
    state = obj.get("State") or {}
    pid = int(state.get("Pid") or 0)
    if pid <= 0:
        return False, "无法取得目标容器 PID"
    cp = run([
        "nsenter", "-t", str(pid), "-n", "--",
        "curl", "-fsS",
        "--proxy", f"http://{singbox_ip}:{port}",
        "--connect-timeout", "5", "--max-time", "15",
        "https://api.ipify.org",
    ], 20)
    ip = cp.stdout.strip()
    if cp.returncode == 0 and ip:
        return True, ip
    msg = (cp.stderr or cp.stdout).strip()
    return False, msg[-300:] or "代理请求失败"


def verify_container(ref: str, inbound_ref: Optional[str] = None, quick: bool = False) -> int:
    result = Result()
    print(f"\n验证 Docker 代理：{ref}")
    print("─" * 48)

    obj = docker_json(ref)
    if not obj:
        result.fail(f"容器不存在: {ref}")
        return result.summary()

    name = container_name(obj)
    state = obj.get("State") or {}
    running = bool(state.get("Running"))
    if running:
        result.ok(f"容器运行中: {name}")
    else:
        result.fail(f"容器未运行: {name}")

    net = network_inspect()
    if net:
        result.ok(f"共享网络存在: {network_name()}")
    else:
        result.fail(f"共享网络不存在: {network_name()}")
    members = network_members(net)

    if name in members:
        result.ok(f"目标容器已加入 {network_name()}")
    else:
        result.fail(f"目标容器未加入 {network_name()}")

    sbx_name = env_values().get("SING_BOX_CONTAINER_NAME", "sing-box")
    sbx_member = members.get(sbx_name)
    if sbx_member:
        result.ok(f"{sbx_name} 已加入 {network_name()}")
    else:
        result.fail(f"{sbx_name} 未加入 {network_name()}")

    managed_id = managed_inbound_for(name)
    chosen = inbound_ref or managed_id or "default"
    ep = resolve_endpoint(chosen)
    if not ep:
        result.fail(f"代理入口不存在或已失效: {chosen}")
        return result.summary()

    iid = str(ep.get("id"))
    iname = str(ep.get("name"))
    port = int(ep.get("port"))
    # 容器内可达端口（默认入口固定 7890），与宿主发布端口可能不同：
    # 环境变量比对与真实探测都必须用它，否则端口≠7890 时会对正常配置误报失败。
    cport = int(ep.get("container_port", port))
    if managed_id:
        result.ok(f"托管关系: {name} -> [{iid}] {iname} -> :{port}")
    else:
        result.warn(f"该容器未纳入托管；本次按 [{iid}] {iname} :{port} 检测")

    envs = proxy_env(obj)
    expected = f"sing-box:{cport}"
    if not envs:
        result.warn("未检测到 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 环境变量")
        print("      网络接通 ≠ 应用一定使用代理；应用也可能在自身配置中设置代理。")
    elif any(expected in line for line in envs):
        result.ok(f"容器代理环境变量指向 {expected}")
    else:
        result.warn(f"检测到代理环境变量，但没有指向当前入口 {expected}")
        for line in envs:
            print(f"      {line}")

    if managed_id:
        if watcher_active():
            result.ok("Watcher 正在运行，容器重建后会自动补接")
        else:
            result.warn("Watcher 未运行；当前连接可用，但容器重建后可能丢失")

    if quick:
        result.warn("快速模式：跳过真实出口 IP 测试")
    elif running and sbx_member:
        addr = str(sbx_member.get("IPv4Address") or "").split("/", 1)[0]
        if not addr:
            result.warn("sing-box 在共享网络上没有 IPv4 地址，跳过真实出口测试")
        else:
            ok, detail = active_proxy_probe(obj, addr, cport)
            if ok:
                result.ok("从目标容器网络命名空间通过代理访问互联网成功")
                print(f"      代理出口 IP: {detail}")
            else:
                result.fail(f"真实代理请求失败: {detail}")

    return result.summary()


def verify_all(quick: bool = True) -> int:
    rows = managed_rows()
    names: List[str] = []
    for row in rows:
        for name in row.get("running", []):
            if name not in names:
                names.append(name)
    if not names:
        print("没有正在运行的托管容器。")
        return 0
    rc = 0
    for name in names:
        if verify_container(name, quick=quick):
            rc = 1
    return rc


def host_proxy_probe(port: int, listen: str = "127.0.0.1") -> Tuple[bool, str]:
    if not shutil.which("curl"):
        return False, "缺少 curl"
    host = str(listen or "127.0.0.1")
    if host == "0.0.0.0":
        host = "127.0.0.1"
    elif host == "::":
        host = "::1"
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    cp = run([
        "curl", "-fsS",
        "--proxy", f"http://{host}:{port}",
        "--connect-timeout", "5", "--max-time", "15",
        "https://api.ipify.org",
    ], 20)
    value = cp.stdout.strip()
    if cp.returncode == 0 and value:
        return True, value
    return False, (cp.stderr or cp.stdout).strip()[-300:] or "请求失败"


def doctor() -> int:
    result = Result()
    print("singbox-manager Doctor")
    print("═" * 48)

    version = VERSION_FILE.read_text(encoding="utf-8").strip() if VERSION_FILE.exists() else "unknown"
    result.ok(f"manager 版本: {version}")

    if NODE_HELPER.exists():
        cp = run(["python3", str(NODE_HELPER), "validate"], 15)
        if cp.returncode == 0:
            result.ok("节点库与生成配置结构校验通过")
        else:
            result.fail("节点库/配置校验失败")
            if cp.stderr:
                print("      " + cp.stderr.strip().replace("\n", "\n      "))
    else:
        result.fail(f"缺少 helper: {NODE_HELPER}")

    if Path(SBX_BIN).exists():
        cp = run([SBX_BIN, "check"], 40)
        if cp.returncode == 0:
            result.ok("sing-box 实际配置检查通过")
        else:
            result.fail("sing-box 实际配置检查失败")
    else:
        result.fail(f"缺少 sbx: {SBX_BIN}")

    sbx_name = env_values().get("SING_BOX_CONTAINER_NAME", "sing-box")
    obj = docker_json(sbx_name)
    if obj and (obj.get("State") or {}).get("Running"):
        result.ok(f"sing-box 容器运行中: {sbx_name}")
    else:
        result.fail(f"sing-box 容器未运行: {sbx_name}")

    eps = endpoints()
    if not eps:
        result.fail("没有可解析的代理入口")
    else:
        for ep in eps:
            iid = str(ep.get("id"))
            name = str(ep.get("name"))
            port = int(ep.get("port"))
            ok, detail = host_proxy_probe(port, str(ep.get("listen") or "127.0.0.1"))
            if ok:
                result.ok(f"入口 [{iid}] {name} :{port} 可用")
                print(f"      出口 IP: {detail}")
            else:
                result.fail(f"入口 [{iid}] {name} :{port} 代理测试失败")

    net = network_inspect()
    if net:
        members = network_members(net)
        result.ok(f"Docker 共享网络存在: {network_name()} ({len(members)} members)")
        if sbx_name in members:
            result.ok("sing-box 已接入共享网络")
        else:
            result.fail("sing-box 未接入共享网络")
    else:
        result.warn(f"Docker 共享网络不存在: {network_name()}")

    rows = managed_rows()
    if rows:
        if watcher_active():
            result.ok("Docker Watcher 正在运行")
        else:
            result.warn("存在托管容器，但 Docker Watcher 未运行")
        missing = []
        for row in rows:
            running = row.get("running", [])
            connected = set(row.get("connected", []))
            for name in running:
                if name not in connected:
                    missing.append(name)
        if missing:
            result.fail("托管容器未接入共享网络: " + ", ".join(missing))
        else:
            result.ok(f"托管容器网络状态正常: {len(rows)} targets")
    else:
        result.warn("当前没有 Docker 托管目标")

    print("\nDocker 应用层快速检查")
    print("─" * 48)
    if rows:
        rc = verify_all(quick=True)
        if rc:
            result.failed += 1
    else:
        print("SKIP  无托管容器")

    return result.summary()


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("docker")
    d.add_argument("container")
    d.add_argument("inbound", nargs="?")
    d.add_argument("--quick", action="store_true")

    da = sub.add_parser("docker-all")
    da.add_argument("--active", action="store_true")

    sub.add_parser("doctor")

    args = p.parse_args()
    if args.cmd == "docker":
        return verify_container(args.container, args.inbound, args.quick)
    if args.cmd == "docker-all":
        return verify_all(quick=not args.active)
    return doctor()


if __name__ == "__main__":
    raise SystemExit(main())
