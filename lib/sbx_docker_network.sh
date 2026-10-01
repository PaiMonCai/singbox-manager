#!/usr/bin/env bash
# Docker shared proxy network integration for singbox-manager.

DOCKER_NETWORK_COMPOSE="${SBX_DOCKER_NETWORK_COMPOSE:-$HOME_DIR/compose.network.yml}"
DOCKER_NETWORK_DEFAULT="${SBX_DOCKER_NETWORK_DEFAULT:-singbox-proxy}"
DOCKER_NETWORK_ALIAS="${SBX_DOCKER_NETWORK_ALIAS:-sing-box}"
DOCKER_TARGET_HELPER="${SBX_DOCKER_TARGET_HELPER:-$HOME_DIR/lib/sbx_docker_targets.py}"
DOCKER_MANAGED_FILE="${SBX_DOCKER_MANAGED_FILE:-$HOME_DIR/docker-managed.json}"
DOCKER_WATCH_SERVICE="${SBX_DOCKER_WATCH_SERVICE:-/etc/systemd/system/singbox-manager-docker-watch.service}"
DOCKER_WATCH_SBX="${SBX_BIN_LINK:-/usr/local/bin/sbx}"
DOCKER_WATCH_BIN="${SBX_DOCKER_WATCH_BIN:-$HOME_DIR/bin/sbx-docker-watch}"

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
    managed_count="$(SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 "$DOCKER_TARGET_HELPER" list --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || printf '0')"
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
  printf '  HTTP/HTTPS: http://%s:%s\n' "$DOCKER_NETWORK_ALIAS" "$(envval SING_BOX_MIXED_PORT 7890)"
  printf '  SOCKS5:     socks5h://%s:%s\n' "$DOCKER_NETWORK_ALIAS" "$(envval SING_BOX_MIXED_PORT 7890)"
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
  local host="$DOCKER_NETWORK_ALIAS" default_port
  default_port="$(envval SING_BOX_MIXED_PORT 7890)"
  printf '默认入口\n'
  printf '  HTTP/HTTPS: http://%s:%s\n' "$host" "$default_port"
  printf '  SOCKS5:     socks5h://%s:%s\n' "$host" "$default_port"

  if [[ -f "$NODES" ]]; then
    python3 - "$NODES" "$host" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
host = sys.argv[2]
try:
    data = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
for item in data.get("inbounds", []):
    name = item.get("name", item.get("id", "inbound"))
    port = item.get("port")
    target = item.get("target") or {}
    target_type = target.get("type", "?")
    print()
    print(f"{name} -> {target_type}")
    print(f"  HTTP/HTTPS: http://{host}:{port}")
    print(f"  SOCKS5:     socks5h://{host}:{port}")
PY
  fi
}

docker_network_env(){
  local port="${1:-$(envval SING_BOX_MIXED_PORT 7890)}"
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "端口无效: $port"
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
  local port="${1:-$(envval SING_BOX_MIXED_PORT 7890)}" net
  net="$(docker_network_name)"
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "端口无效: $port"
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

docker_network_known_ports(){
  printf '  %s  默认入口 -> proxy\n' "$(envval SING_BOX_MIXED_PORT 7890)"
  if [[ -f "$NODES" ]]; then
    python3 - "$NODES" <<'PY'
import json, sys
from pathlib import Path
try:
    data=json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
for item in data.get("inbounds", []):
    target=(item.get("target") or {}).get("type","?")
    print(f"  {item.get('port')}  {item.get('name', item.get('id','inbound'))} -> {target}")
PY
  fi
}

docker_network_choose_port(){
  local default_port raw
  default_port="$(envval SING_BOX_MIXED_PORT 7890)"
  printf '可用代理入口：\n' >&2
  docker_network_known_ports >&2
  read -r -p "托管目标使用哪个代理入口端口 [$default_port]: " raw
  raw="${raw:-$default_port}"
  [[ "$raw" =~ ^[0-9]+$ ]] && ((raw >= 1 && raw <= 65535)) || die "端口无效: $raw"
  printf '%s\n' "$raw"
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
  systemctl enable --now singbox-manager-docker-watch.service >/dev/null
  info "Docker watcher 已开启。"
}

docker_network_watch_off(){
  if command -v systemctl >/dev/null 2>&1 && [[ "${SBX_DOCKER_WATCH_NO_APPLY:-0}" != "1" ]]; then
    systemctl disable --now singbox-manager-docker-watch.service >/dev/null 2>&1 || true
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
      systemctl is-enabled singbox-manager-docker-watch.service 2>/dev/null | sed 's/^/Enabled: /' || true
      systemctl is-active singbox-manager-docker-watch.service 2>/dev/null | sed 's/^/Active:  /' || true
    fi
  else
    printf 'Watcher: OFF\n'
  fi
}

docker_network_sync(){
  local quiet=0 net
  [[ "${1:-}" == "--quiet" ]] && quiet=1
  net="$(docker_network_name)"
  docker_network_create_if_missing "$net"
  [[ -f "$DOCKER_TARGET_HELPER" ]] || die "缺少 Docker 托管 helper: $DOCKER_TARGET_HELPER"
  if ((quiet)); then
    SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 "$DOCKER_TARGET_HELPER" sync --network "$net" --quiet
  else
    SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 "$DOCKER_TARGET_HELPER" sync --network "$net"
  fi
}

docker_network_managed_list(){
  local net
  net="$(docker_network_name)"
  [[ -f "$DOCKER_TARGET_HELPER" ]] || die "缺少 Docker 托管 helper。"
  SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 "$DOCKER_TARGET_HELPER" list --network "$net"
}

docker_network_manage(){
  local container="${1:-}" port="${2:-}" net
  net="$(docker_network_name)"
  [[ -n "$container" ]] || die "用法: sbx docker-network manage <容器> [入口端口]"
  docker inspect "$container" >/dev/null 2>&1 || die "未找到容器: $container"
  if [[ -z "$port" ]]; then
    port="$(docker_network_choose_port)"
  fi
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "端口无效: $port"

  docker_network_enabled || docker_network_on "$net"
  SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 "$DOCKER_TARGET_HELPER" add "$container" --port "$port"
  docker_network_sync
  if command -v systemctl >/dev/null 2>&1; then
    docker_network_watch_on || true
  fi
  info "已纳入托管。容器重建后 watcher 会按 Compose project/service 或名称重新接入。"
  printf '建议应用代理：http://%s:%s\n' "$DOCKER_NETWORK_ALIAS" "$port"
}

docker_network_unmanage(){
  local ref="${1:-}" remaining
  [[ -n "$ref" ]] || die "用法: sbx docker-network unmanage <容器|KEY>"
  SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 "$DOCKER_TARGET_HELPER" remove "$ref"
  remaining="$(SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 "$DOCKER_TARGET_HELPER" list --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || printf '0')"
  if [[ "$remaining" == "0" ]]; then
    docker_network_watch_off >/dev/null 2>&1 || true
    info "已无托管目标，Docker watcher 已停止。"
  fi
}

docker_network_scan_manage(){
  [[ -f "$DOCKER_TARGET_HELPER" ]] || die "缺少 Docker 托管 helper。"
  local json selection port token idx name
  json="$(SBX_DOCKER_MANAGED_FILE="$DOCKER_MANAGED_FILE" python3 "$DOCKER_TARGET_HELPER" scan --json)"
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
    managed=f"YES:{r.get('port')}" if r.get('managed') else "NO"
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
  port="$(docker_network_choose_port)"

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
    docker_network_manage "$name" "$port"
  done
}

docker_network_menu(){
  local x c
  while true; do
    clear
    printf '%bDocker 容器共享代理网络%b\n\n' "$C" "$N"
    docker_network_status || true
    docker_network_watch_status || true
    printf '\n1 扫描并托管  2 查看托管目标  3 立即同步\n'
    printf '4 取消托管    5 临时接入容器  6 临时移除容器\n'
    printf '7 查看成员    8 查看代理地址  9 Compose 模板\n'
    printf '10 Watcher开启 11 Watcher关闭 12 开启共享网络\n'
    printf '13 关闭共享网络                              0 返回\n'
    read -r -p '请选择: ' x || return
    case "$x" in
      1) docker_network_scan_manage ;;
      2) docker_network_managed_list ;;
      3) docker_network_sync ;;
      4) read -r -p '容器名称或托管 KEY: ' c; docker_network_unmanage "$c" ;;
      5) read -r -p '容器名称/ID: ' c; docker_network_connect "$c" ;;
      6) read -r -p '容器名称/ID: ' c; docker_network_disconnect "$c" ;;
      7) docker_network_members || true ;;
      8) docker_network_urls ;;
      9) docker_network_snippet ;;
      10) docker_network_watch_on ;;
      11) docker_network_watch_off ;;
      12) docker_network_on ;;
      13) docker_network_off ;;
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
sbx docker-network manage <container> [port]
sbx docker-network unmanage <container|KEY>
sbx docker-network managed            查看托管目标
sbx docker-network sync [--quiet]     立即按托管清单补接网络
sbx docker-network watch on|off|status
sbx docker-network connect <container>    临时接入当前容器实例
sbx docker-network disconnect <container> 临时移除当前容器实例
sbx docker-network list               查看网络成员
sbx docker-network urls               查看默认/自定义入口的容器内代理地址
sbx docker-network env [port]         输出容器侧代理环境变量
sbx docker-network snippet [port]     输出其他 Compose 项目的接入模板
EOF
      ;;
    *) die "未知 docker-network 命令: $op" ;;
  esac
}
