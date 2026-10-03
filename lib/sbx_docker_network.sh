#!/usr/bin/env bash
# Docker shared proxy network integration for singbox-manager.

DOCKER_NETWORK_COMPOSE="${SBX_DOCKER_NETWORK_COMPOSE:-$HOME_DIR/compose.network.yml}"
DOCKER_NETWORK_DEFAULT="${SBX_DOCKER_NETWORK_DEFAULT:-singbox-proxy}"
DOCKER_NETWORK_ALIAS="${SBX_DOCKER_NETWORK_ALIAS:-sing-box}"
DOCKER_TARGET_HELPER="${SBX_DOCKER_TARGET_HELPER:-$HOME_DIR/lib/sbx_docker_targets.py}"
DOCKER_MANAGED_FILE="${SBX_DOCKER_MANAGED_FILE:-$HOME_DIR/docker-managed.json}"
DOCKER_WATCH_SERVICE="${SBX_DOCKER_WATCH_SERVICE:-/etc/systemd/system/singbox-manager-docker-watch.service}"
# systemctl 必须操作与写入路径对应的单元名，否则用 SBX_DOCKER_WATCH_SERVICE 覆盖时会各写一边
DOCKER_WATCH_UNIT="$(basename "$DOCKER_WATCH_SERVICE")"
DOCKER_WATCH_SBX="${SBX_BIN_LINK:-/usr/local/bin/sbx}"
DOCKER_WATCH_BIN="${SBX_DOCKER_WATCH_BIN:-$HOME_DIR/bin/sbx-docker-watch}"

# 统一调用入口：helper 读的是进程环境变量，而 SING_BOX_CONTAINER_NAME 只写在 .env，
# 不显式传进去的话 is_manager_container() 会一直用默认值，导致 sing-box 自己被当成可托管容器。
docker_target_helper(){
  SING_BOX_CONTAINER_NAME="$(envval SING_BOX_CONTAINER_NAME sing-box)" \
  SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" \
    python3 "$DOCKER_TARGET_HELPER" "$@"
}

docker_network_name(){
  envval SING_BOX_DOCKER_NETWORK "$DOCKER_NETWORK_DEFAULT"
}

docker_network_validate_name(){
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || die "Docker 网络名称无效: $name"
}

docker_network_enabled(){
  [[ -f "$DOCKER_NETWORK_COMPOSE" ]]
}

docker_network_exists(){
  docker network inspect "$1" >/dev/null 2>&1
}

docker_network_create_if_missing(){
  local net="$1"
  docker_network_validate_name "$net"
  if docker_network_exists "$net"; then
    return 0
  fi
  info "创建 Docker 共享代理网络: $net"
  docker network create --driver bridge "$net" >/dev/null
}

docker_network_render(){
  local net="$1"
  docker_network_validate_name "$net"
  cat > "$DOCKER_NETWORK_COMPOSE" <<EOF
services:
  sing-box:
    networks:
      default: {}
      sbx_proxy:
        aliases:
          - $DOCKER_NETWORK_ALIAS

networks:
  default: {}
  sbx_proxy:
    external: true
    name: $net
EOF
  chmod 600 "$DOCKER_NETWORK_COMPOSE"
}

docker_network_prepare_if_enabled(){
  docker_network_enabled || return 0
  docker_network_create_if_missing "$(docker_network_name)"
}

docker_network_on(){
  local net="${1:-$(docker_network_name)}"
  docker_network_validate_name "$net"
  setenv SING_BOX_DOCKER_NETWORK "$net"
  docker_network_create_if_missing "$net"
  docker_network_render "$net"

  if [[ "${SBX_DOCKER_NETWORK_NO_APPLY:-0}" == "1" ]]; then
    info "共享代理网络配置已生成；测试模式未重建 sing-box。"
    return 0
  fi

  if running; then
    info "重建 sing-box 容器以持久接入共享网络..."
    check
    dc up -d --force-recreate --pull never sing-box
  fi

  if [[ -f "$DOCKER_MANAGED_FILE" && -f "$DOCKER_TARGET_HELPER" ]]; then
    local managed_count
    managed_count="$(docker_target_helper list --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || printf '0')"
    if [[ "$managed_count" =~ ^[0-9]+$ ]] && ((managed_count > 0)); then
      docker_network_sync || true
      command -v systemctl >/dev/null 2>&1 && docker_network_watch_on || true
    fi
  fi
  info "Docker 共享代理网络已开启: $net"
}

docker_network_off(){
  local net
  net="$(docker_network_name)"
  if [[ ! -f "$DOCKER_NETWORK_COMPOSE" ]]; then
    info "Docker 共享代理网络功能未启用。"
    return 0
  fi
  rm -f "$DOCKER_NETWORK_COMPOSE"

  if [[ "${SBX_DOCKER_NETWORK_NO_APPLY:-0}" != "1" ]] && running; then
    info "重建 sing-box 容器并移除持久共享网络连接..."
    check
    dc up -d --force-recreate --pull never sing-box
  fi

  docker_network_watch_off >/dev/null 2>&1 || true
  info "已关闭 sing-box 的共享网络持久接入。"
  warn "Docker 网络 $net 本身以及其他容器连接不会自动删除；托管清单仍保留。"
}

docker_network_members(){
  local net
  net="$(docker_network_name)"
  if ! docker_network_exists "$net"; then
    printf '网络不存在: %s\n' "$net"
    return 1
  fi
  docker network inspect --format '{{range .Containers}}{{println .Name}}{{end}}' "$net" | sed '/^$/d' | sort
}

docker_network_is_connected(){
  local net="$1" container="$2"
  docker network inspect --format '{{range .Containers}}{{println .Name}}{{end}}' "$net" 2>/dev/null |
    grep -Fxq "$container"
}

docker_network_connect(){
  local container="${1:-}" net
  net="$(docker_network_name)"
  [[ -n "$container" ]] || read -r -p '容器名称/ID: ' container
  [[ -n "$container" ]] || die "容器不能为空。"
  docker inspect "$container" >/dev/null 2>&1 || die "未找到容器: $container"
  local container_name
  container_name="$(docker inspect --format '{{.Name}}' "$container" | sed 's#^/##')"

  if ! docker_network_enabled; then
    warn "共享网络尚未启用，将先开启。"
    docker_network_on "$net"
  else
    docker_network_create_if_missing "$net"
  fi

  if docker_network_is_connected "$net" "$container_name"; then
    info "容器已经在网络 $net 中: $container_name"
  else
    docker network connect "$net" "$container"
    info "已接入: $container_name -> $net"
  fi

  printf '\n容器内代理地址：\n'
  local cport; cport="$(docker_network_inbound_port default 2>/dev/null || printf '7890')"
  printf '  HTTP/HTTPS: http://%s:%s\n' "$DOCKER_NETWORK_ALIAS" "$cport"
  printf '  SOCKS5:     socks5h://%s:%s\n' "$DOCKER_NETWORK_ALIAS" "$cport"
  warn "network connect 只建立网络连通性，不会修改该容器已有环境变量。"
  warn "如果该容器由 Compose 管理，建议把 external network 写进它自己的 compose 文件以便重建后仍保留。"
}

docker_network_disconnect(){
  local container="${1:-}" net
  net="$(docker_network_name)"
  [[ -n "$container" ]] || read -r -p '容器名称/ID: ' container
  [[ -n "$container" ]] || die "容器不能为空。"

  docker inspect "$container" >/dev/null 2>&1 || die "未找到容器: $container"
  local sbx_name container_name
  sbx_name="$(envval SING_BOX_CONTAINER_NAME sing-box)"
  container_name="$(docker inspect --format '{{.Name}}' "$container" | sed 's#^/##')"
  if [[ "$container_name" == "$sbx_name" || "$container_name" == "$DOCKER_NETWORK_ALIAS" ]]; then
    die "不要直接移除 sing-box；请使用 sbx docker-network off。"
  fi

  docker_network_exists "$net" || die "网络不存在: $net"
  if docker_network_is_connected "$net" "$container_name"; then
    docker network disconnect "$net" "$container"
    info "已移除: $container_name <- $net"
  else
    info "容器不在网络中: $container_name"
  fi
}

docker_network_urls(){
  local host="$DOCKER_NETWORK_ALIAS" items
  items="$(python3 "$HELPER" inbound-endpoints --json)" || return 1
  python3 - "$host" "$items" <<'PY'
import json,sys
host=sys.argv[1]
items=json.loads(sys.argv[2])
for i,item in enumerate(items):
    if i: print()
    # 容器侧必须用 container_port：默认入口在容器内固定 7890，宿主端口可能被改过
    port=item.get('container_port', item['port'])
    print(f"[{item['id']}] {item['name']} -> {item.get('resolved_outbound','') or (item.get('target') or {}).get('type','?')}")
    print(f"  HTTP/HTTPS: http://{host}:{port}")
    print(f"  SOCKS5:     socks5h://{host}:{port}")
PY
}

docker_network_env(){
  local inbound_ref="${1:-default}" port
  port="$(docker_network_inbound_port "$inbound_ref")" || die "代理入口不存在: $inbound_ref"
  printf "export HTTP_PROXY='http://%s:%s'\n" "$DOCKER_NETWORK_ALIAS" "$port"
  printf "export HTTPS_PROXY='http://%s:%s'\n" "$DOCKER_NETWORK_ALIAS" "$port"
  printf "export ALL_PROXY='socks5h://%s:%s'\n" "$DOCKER_NETWORK_ALIAS" "$port"
  printf "export http_proxy='http://%s:%s'\n" "$DOCKER_NETWORK_ALIAS" "$port"
  printf "export https_proxy='http://%s:%s'\n" "$DOCKER_NETWORK_ALIAS" "$port"
  printf "export all_proxy='socks5h://%s:%s'\n" "$DOCKER_NETWORK_ALIAS" "$port"
  printf "export NO_PROXY='localhost,127.0.0.1,::1'\n"
  printf "export no_proxy='localhost,127.0.0.1,::1'\n"
}

docker_network_snippet(){
  local inbound_ref="${1:-default}" port net
  net="$(docker_network_name)"
  port="$(docker_network_inbound_port "$inbound_ref")" || die "代理入口不存在: $inbound_ref"
  cat <<EOF
services:
  your-app:
    networks:
      - default
      - singbox_proxy
    environment:
      HTTP_PROXY: http://$DOCKER_NETWORK_ALIAS:$port
      HTTPS_PROXY: http://$DOCKER_NETWORK_ALIAS:$port
      ALL_PROXY: socks5h://$DOCKER_NETWORK_ALIAS:$port

networks:
  singbox_proxy:
    external: true
    name: $net
EOF
}

docker_network_status(){
  local net
  net="$(docker_network_name)"
  printf '共享网络: %s\n' "$net"
  printf 'DNS 别名: %s\n' "$DOCKER_NETWORK_ALIAS"
  if docker_network_enabled; then
    printf '持久接入: ON\n'
  else
    printf '持久接入: OFF\n'
  fi
  if docker_network_exists "$net"; then
    printf 'Docker网络: READY\n'
    printf '成员:\n'
    local members
    members="$(docker_network_members || true)"
    if [[ -n "$members" ]]; then
      printf '%s\n' "$members" | sed 's/^/  - /'
    else
      printf '  (无)\n'
    fi
  else
    printf 'Docker网络: MISSING\n'
  fi
}

docker_network_endpoints_json(){
  python3 "$HELPER" inbound-endpoints --json
}

docker_network_known_inbounds(){
  python3 "$HELPER" inbound-endpoints
}

docker_network_resolve_inbound(){
  local ref="${1:-default}"
  python3 "$HELPER" inbound-endpoint "$ref"
}

docker_network_inbound_id(){
  local ref="${1:-default}" json
  json="$(docker_network_resolve_inbound "$ref")" || return 1
  printf '%s\n' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || return 1
}

docker_network_inbound_ports(){
  # 一次打印两个端口：<宿主机侧发布端口> <容器内/共享网络内可达端口>
  # 默认入口在容器内固定 7890，宿主机侧端口是 .env 里的 SING_BOX_MIXED_PORT（可能被改过）；
  # 自定义入口两者一一对应。凡是告诉用户“容器里该连哪个端口”的地方都必须用后者。
  local ref="${1:-default}" json
  json="$(docker_network_resolve_inbound "$ref")" || return 1
  printf '%s\n' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("port",""), d.get("container_port", d.get("port","")))' 2>/dev/null || return 1
}

docker_network_inbound_port(){
  # 容器内/共享网络内可达的端口；入口不存在时返回非零，调用方靠 `|| die` 报错
  local ref="${1:-default}" host_port container_port
  read -r host_port container_port <<<"$(docker_network_inbound_ports "$ref" 2>/dev/null || true)"
  [[ -n "$container_port" ]] || return 1
  printf '%s' "$container_port"
}

docker_network_proxy_hint(){
  # 托管成功后回显“容器里该用的代理地址”。
  # 0.11.10 之前这里打的是宿主机侧端口：默认入口容器内固定 7890，
  # 若 SING_BOX_MIXED_PORT 被改过，提示出来的地址在容器里根本连不上。
  local ref="${1:-default}" host_port container_port id name
  read -r host_port container_port <<<"$(docker_network_inbound_ports "$ref" 2>/dev/null || true)"
  [[ -n "$container_port" ]] || return 1
  id="$(docker_network_inbound_id "$ref" 2>/dev/null || true)"
  name="$(docker_network_inbound_name "$ref" 2>/dev/null || true)"
  printf '代理入口: [%s] %s\n' "${id:-$ref}" "$name"
  printf '容器内代理：http://%s:%s\n' "$DOCKER_NETWORK_ALIAS" "$container_port"
  if [[ "$container_port" != "$host_port" ]]; then
    printf '  （宿主机侧端口是 %s，容器里请用 %s）\n' "$host_port" "$container_port"
  fi
}

docker_network_inbound_name(){
  local ref="${1:-default}" json
  json="$(docker_network_resolve_inbound "$ref")" || return 1
  printf '%s\n' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || return 1
}

docker_network_choose_inbound(){
  local raw endpoints count inbound_id
  endpoints="$(docker_network_endpoints_json)" || return 1

  python3 - "$endpoints" >&2 <<'PY'
import json,sys
items=json.loads(sys.argv[1])
print("可用代理入口：")
print("（端口后面是容器里要用的端口：默认入口容器内固定 7890，与宿主机发布端口无关）")
for idx,item in enumerate(items,1):
    target=item.get("resolved_outbound") or (item.get("target") or {}).get("type","?")
    port=item.get("container_port", item["port"])
    print(f"  {idx}. [{item['id']}] {item['name']}  {port} -> {target}")
PY

  count="$(python3 - "$endpoints" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)"
  read -r -p '请选择代理入口 [1]: ' raw || true
  raw="${raw:-1}"
  [[ "$raw" =~ ^[0-9]+$ ]] || { warn "请输入入口序号。"; return 1; }
  ((raw >= 1 && raw <= count)) || { warn "入口序号不存在: $raw"; return 1; }

  inbound_id="$(python3 - "$endpoints" "$raw" <<'PY'
import json,sys
items=json.loads(sys.argv[1]); idx=int(sys.argv[2])
print(items[idx-1]["id"])
PY
)"
  printf '%s\n' "$inbound_id"
}

docker_network_migrate_legacy_targets(){
  [[ -f "$DOCKER_MANAGED_FILE" ]] || return 0
  local endpoints
  endpoints="$(docker_network_endpoints_json)" || return 1
  SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 - "$DOCKER_MANAGED_FILE" "$endpoints" <<'PY'
import json, os, sys, tempfile
from pathlib import Path
path=Path(sys.argv[1])
endpoints=json.loads(sys.argv[2])
try:
    data=json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
by_port={int(x["port"]): str(x["id"]) for x in endpoints}
changed=False
for target in data.get("targets", []):
    if target.get("inbound_id"):
        continue
    port=target.get("port")
    try:
        port=int(port)
    except (TypeError, ValueError):
        continue
    if port in by_port:
        target["inbound_id"]=by_port[port]
        target.pop("port", None)
        changed=True
if changed:
    fd,tmp=tempfile.mkstemp(prefix=".docker-managed.",dir=str(path.parent))
    try:
        with os.fdopen(fd,"w",encoding="utf-8") as f:
            json.dump(data,f,ensure_ascii=False,indent=2)
            f.write("\n")
        os.chmod(tmp,0o600)
        os.replace(tmp,path)
        os.chmod(path,0o600)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
PY
}


docker_network_watch_on(){
  command -v systemctl >/dev/null 2>&1 || { warn "当前系统没有 systemd，无法启用 Docker watcher；可手工执行 sbx docker-network sync。"; return 1; }
  [[ -x "$DOCKER_WATCH_BIN" ]] || die "缺少 watcher: $DOCKER_WATCH_BIN"
  mkdir -p "$(dirname "$DOCKER_WATCH_SERVICE")"
  cat > "$DOCKER_WATCH_SERVICE" <<EOF
[Unit]
Description=singbox-manager Docker network watcher
After=docker.service
Requires=docker.service

[Service]
Type=simple
Environment="SBX_HOME=$HOME_DIR"
Environment="SBX_WATCH_SBX=$DOCKER_WATCH_SBX"
ExecStart=$DOCKER_WATCH_BIN
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$DOCKER_WATCH_SERVICE"
  if [[ "${SBX_DOCKER_WATCH_NO_APPLY:-0}" == "1" ]]; then
    info "Docker watcher service 已生成；测试模式未启用。"
    return 0
  fi
  systemctl daemon-reload
  systemctl enable --now "$DOCKER_WATCH_UNIT" >/dev/null
  info "Docker watcher 已开启。"
}

docker_network_watch_off(){
  if command -v systemctl >/dev/null 2>&1 && [[ "${SBX_DOCKER_WATCH_NO_APPLY:-0}" != "1" ]]; then
    systemctl disable --now "$DOCKER_WATCH_UNIT" >/dev/null 2>&1 || true
  fi
  rm -f "$DOCKER_WATCH_SERVICE"
  if command -v systemctl >/dev/null 2>&1 && [[ "${SBX_DOCKER_WATCH_NO_APPLY:-0}" != "1" ]]; then
    systemctl daemon-reload
  fi
  info "Docker watcher 已关闭。"
}

docker_network_watch_status(){
  if [[ -f "$DOCKER_WATCH_SERVICE" ]]; then
    printf 'Watcher: CONFIGURED\n'
    if command -v systemctl >/dev/null 2>&1; then
      systemctl is-enabled "$DOCKER_WATCH_UNIT" 2>/dev/null | sed 's/^/Enabled: /' || true
      systemctl is-active "$DOCKER_WATCH_UNIT" 2>/dev/null | sed 's/^/Active:  /' || true
      # Active 只说明进程在跑：docker events 参数/模板出错时它会一直活着但什么都不做，
      # 所以把看日志的入口直接写在这里。
      printf '重建容器后没自动接入就看日志: journalctl -u %s -n 20 --no-pager\n' "$DOCKER_WATCH_UNIT"
    fi
  else
    printf 'Watcher: OFF\n'
  fi
}

docker_network_sync(){
  local quiet=0 net
  [[ "${1:-}" == "--quiet" ]] && quiet=1
  net="$(docker_network_name)"
  if ! docker_network_enabled; then
    # 共享网络已被 off 关闭（compose.network.yml 不存在，sing-box 也不在该网络内），
    # 此时把托管容器接上去只会让它们配置的代理地址失效。
    ((quiet)) || warn "共享代理网络当前未启用，已跳过 sync（先执行 sbx docker-network on）。"
    return 0
  fi
  docker_network_create_if_missing "$net"
  [[ -f "$DOCKER_TARGET_HELPER" ]] || die "缺少 Docker 托管 helper: $DOCKER_TARGET_HELPER"
  docker_network_migrate_legacy_targets || true
  if ((quiet)); then
    docker_target_helper sync --network "$net" --quiet
  else
    docker_target_helper sync --network "$net"
  fi
}

docker_network_managed_list(){
  local net rows endpoints
  net="$(docker_network_name)"
  [[ -f "$DOCKER_TARGET_HELPER" ]] || die "缺少 Docker 托管 helper。"
  docker_network_migrate_legacy_targets || true
  rows="$(docker_target_helper list --network "$net" --json)"
  endpoints="$(docker_network_endpoints_json)"
  python3 - "$rows" "$endpoints" <<'PY'
import json,sys,unicodedata
def dwidth(s):
    return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in str(s))
def fit(s,n):
    # 按显示宽度截断并补空格，CJK 才不会把后面的列顶歪
    out=""
    for ch in str(s):
        if dwidth(out)+dwidth(ch)>n:
            break
        out+=ch
    return out+" "*(n-dwidth(out))
rows=json.loads(sys.argv[1]); eps=json.loads(sys.argv[2])
by_id={str(x["id"]):x for x in eps}
if not rows:
    print("暂无托管 Docker 目标。")
    raise SystemExit(0)
# HOST_PORT 是宿主机上的发布端口，CONTAINER_PORT 才是容器里要用的端口（默认入口固定 7890）
print(f"{'KEY':<42} {'INBOUND_ID':<12} {'NAME':<18} {'HOST_PORT':<10} {'CONTAINER_PORT':<15} {'RUN':<18} CONNECTED")
print("-"*135)
for r in rows:
    iid=str(r.get("inbound_id") or "")
    ep=by_id.get(iid)
    name=(ep or {}).get("name","MISSING")
    host_port=str((ep or {}).get("port","-"))
    container_port=str((ep or {}).get("container_port","-"))
    running=",".join(r.get("running",[]))
    print(f"{r['key'][:40]:<42} {iid[:10]:<12} {fit(name,18)} {host_port:<10} {container_port:<15} {fit(running,18)} {','.join(r.get('connected',[]))}")
missing=sorted(m for m in {str(r.get("inbound_id") or "") for r in rows} if m and m not in by_id)
if missing:
    print()
    print(f"注意: {len(missing)} 个托管目标引用的入口已不存在（上面显示为 MISSING）:")
    print("      " + ", ".join(m[:10] for m in missing))
    print("      这些容器里配置的代理地址已失效；请用 `sbx docker-network unmanage <KEY>` 清理，或重新显式绑定入口。")
PY
}

docker_network_manage(){
  local container="${1:-}" inbound_ref="${2:-default}" net inbound_id
  net="$(docker_network_name)"
  [[ -n "$container" ]] || die "用法: sbx docker-network manage <容器> [入口ID]"
  docker inspect "$container" >/dev/null 2>&1 || die "未找到容器: $container"

  inbound_id="$(docker_network_inbound_id "$inbound_ref")" || die "代理入口不存在: $inbound_ref"

  docker_network_enabled || docker_network_on "$net"
  docker_network_migrate_legacy_targets || true
  docker_target_helper add "$container" --inbound-id "$inbound_id"
  docker_network_sync
  if command -v systemctl >/dev/null 2>&1; then
    docker_network_watch_on || true
  fi
  info "已纳入托管。容器重建后 watcher 会按 Compose project/service 或名称重新接入。"
  docker_network_proxy_hint "$inbound_id"
}

docker_network_unmanage(){
  local ref="${1:-}" remaining
  [[ -n "$ref" ]] || die "用法: sbx docker-network unmanage <容器|KEY>"
  docker_target_helper remove "$ref"
  remaining="$(docker_target_helper list --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || printf '0')"
  if [[ "$remaining" == "0" ]]; then
    docker_network_watch_off >/dev/null 2>&1 || true
    info "已无托管目标，Docker watcher 已停止。"
  fi
}

docker_network_scan_manage(){
  [[ -f "$DOCKER_TARGET_HELPER" ]] || die "缺少 Docker 托管 helper。"
  local json selection inbound_id token idx name choices
  json="$(docker_target_helper scan --json)"
  python3 - "$json" <<'PY'
import json,sys
rows=json.loads(sys.argv[1])
if not rows:
    print("未发现可选择的 Docker 容器。")
    raise SystemExit(0)
print(f"{'#':<4} {'容器':<26} {'状态':<8} {'类型':<10} {'Compose project/service':<34} 托管")
print("-"*105)
for i,r in enumerate(rows,1):
    comp=f"{r.get('project')}/{r.get('service')}" if r.get('type')=="compose" else ""
    managed_ref=r.get("inbound_id") or (f"legacy:{r.get('legacy_port')}" if r.get("legacy_port") else "")
    managed=f"YES:{managed_ref}" if r.get('managed') else "NO"
    print(f"{i:<4} {r.get('name','')[:24]:<26} {('RUN' if r.get('running') else 'STOP'):<8} {r.get('type',''):<10} {comp[:32]:<34} {managed}")
PY
  if [[ "$(python3 - "$json" <<'PY'
import json,sys
print(len(json.loads(sys.argv[1])))
PY
)" == "0" ]]; then
    return 0
  fi

  read -r -p '选择要托管的编号（支持 1,2,5；0 返回）: ' selection
  [[ "$selection" != "0" && -n "$selection" ]] || return 0
  inbound_id="$(docker_network_choose_inbound)" || return 1

  IFS=',' read -ra choices <<< "$selection"
  for token in "${choices[@]}"; do
    token="${token//[[:space:]]/}"
    [[ "$token" =~ ^[0-9]+$ ]] || { warn "忽略无效编号: $token"; continue; }
    idx="$token"
    name="$(python3 - "$json" "$idx" <<'PY'
import json,sys
rows=json.loads(sys.argv[1]); idx=int(sys.argv[2])
if 1 <= idx <= len(rows): print(rows[idx-1]["name"])
PY
)"
    [[ -n "$name" ]] || { warn "编号不存在: $idx"; continue; }
    docker_network_manage "$name" "$inbound_id"
  done
}

# 原名「Docker 容器共享代理网络」与「宿主机应用代理」在菜单里分不清，改名「容器接入」。
# 15 项收敛到 11 项：开关类（共享网络 / Watcher）合成一项、进入后再选开或关；
# 地址与 Compose 模板本来就一起看，合成一项。
docker_network_menu(){
  local x c sub
  while true; do
    clear
    menu_title '容器接入'
    menu_note '让其它 Docker 容器共享 sing-box 出口。'
    printf '\n'
    docker_network_status || true
    docker_network_watch_status || true
    menu_block '托管与同步' <<'EOF'
   1  扫描并托管  扫描容器并选择托管
   2  托管清单    已托管容器与绑定入口
   3  立即同步    按清单补接网络
   4  取消托管    不再跟随某个容器
EOF
    menu_block '临时接入' <<'EOF'
   5  接入容器    临时接上共享网络
   6  移除容器    从共享网络移除
   7  查看成员    当前网络内的容器
EOF
    menu_block '信息' <<'EOF'
   8  地址与模板  容器内地址 + 接入片段
   9  验证        某容器；留空=全部托管
EOF
    menu_block '开关' <<'EOF'
  10  共享网络    开启 / 关闭
  11  Watcher     开启 / 关闭
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) docker_network_scan_manage || true ;;
      2) docker_network_managed_list || true ;;
      3) docker_network_sync || true ;;
      4) read -r -p '容器名称或托管 KEY: ' c || true; docker_network_unmanage "$c" || true ;;
      5) read -r -p '容器名称/ID: ' c || true; docker_network_connect "$c" || true ;;
      6) read -r -p '容器名称/ID: ' c || true; docker_network_disconnect "$c" || true ;;
      7) docker_network_members || true ;;
      8) docker_network_urls || true; docker_network_snippet || true ;;
      9)
        read -r -p '容器名称/ID（留空 = 验证全部托管）: ' c || true
        if [[ -n "$c" ]]; then
          python3 "$HOME_DIR/lib/sbx_verify.py" docker "$c" || true
        else
          python3 "$HOME_DIR/lib/sbx_verify.py" docker-all || true
        fi
        ;;
      10)
        read -r -p '共享网络: 1 开启 / 2 关闭: ' sub
        case "$sub" in
          1) docker_network_on || true ;;
          2) docker_network_off || true ;;
          *) warn "无效选项" ;;
        esac
        ;;
      11)
        read -r -p 'Watcher: 1 开启 / 2 关闭: ' sub
        case "$sub" in
          1) docker_network_watch_on || true ;;
          2) docker_network_watch_off || true ;;
          *) warn "无效选项" ;;
        esac
        ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

docker_network_cmd(){
  local op="${1:-menu}"
  shift || true
  case "$op" in
    menu) docker_network_menu ;;
    on|enable) docker_network_on "${1:-}" ;;
    off|disable) docker_network_off ;;
    status) docker_network_status ;;
    connect|add) docker_network_connect "${1:-}" ;;
    disconnect) docker_network_disconnect "${1:-}" ;;
    scan) docker_network_scan_manage ;;
    manage) docker_network_manage "${1:-}" "${2:-}" ;;
    unmanage) docker_network_unmanage "${1:-}" ;;
    managed) docker_network_managed_list ;;
    sync) docker_network_sync "${1:-}" ;;
    verify) python3 "$HOME_DIR/lib/sbx_verify.py" docker "${1:-}" "${2:-}" ;;
    verify-all) python3 "$HOME_DIR/lib/sbx_verify.py" docker-all ;;
    watch)
      case "${1:-status}" in
        on) docker_network_watch_on ;;
        off) docker_network_watch_off ;;
        status) docker_network_watch_status ;;
        *) die "用法: sbx docker-network watch on|off|status" ;;
      esac
      ;;
    list|members) docker_network_members ;;
    remove|rm) docker_network_disconnect "${1:-}" ;;
    urls|address|addresses) docker_network_urls ;;
    env) docker_network_env "${1:-}" ;;
    snippet|compose) docker_network_snippet "${1:-}" ;;
    help|-h|--help)
      cat <<'EOF'
sbx docker-network                    交互菜单
sbx docker-network on [network]       创建并启用共享代理网络
sbx docker-network off                关闭 sing-box 的持久共享网络接入
sbx docker-network status             查看状态
sbx docker-network scan               扫描 Docker 并按编号选择托管
sbx docker-network manage <container> [入口ID]
sbx docker-network unmanage <container|KEY>
sbx docker-network managed            查看托管目标
sbx docker-network sync [--quiet]     立即按托管清单补接网络
sbx docker-network verify <container> [入口ID]
sbx docker-network verify-all          验证全部托管容器（默认真实出口探测，--quick 只做结构检查）
sbx docker-network watch on|off|status
sbx docker-network connect <container>    临时接入当前容器实例
sbx docker-network disconnect <container> 临时移除当前容器实例
sbx docker-network list               查看网络成员
sbx docker-network urls               查看默认/自定义入口的容器内代理地址
sbx docker-network env [入口ID]       输出容器侧代理环境变量
sbx docker-network snippet [入口ID]   输出其他 Compose 项目的接入模板
EOF
      ;;
    *) die "未知 docker-network 命令: $op" ;;
  esac
}
