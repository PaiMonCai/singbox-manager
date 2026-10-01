#!/usr/bin/env bash
# Docker shared proxy network integration for singbox-manager.

DOCKER_NETWORK_COMPOSE="${SBX_DOCKER_NETWORK_COMPOSE:-$HOME_DIR/compose.network.yml}"
DOCKER_NETWORK_DEFAULT="${SBX_DOCKER_NETWORK_DEFAULT:-singbox-proxy}"
DOCKER_NETWORK_ALIAS="${SBX_DOCKER_NETWORK_ALIAS:-sing-box}"

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

  info "已关闭 sing-box 的共享网络持久接入。"
  warn "Docker 网络 $net 本身以及其他容器连接不会自动删除。"
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

docker_network_menu(){
  local x c
  while true; do
    clear
    printf '%bDocker 容器共享代理网络%b\n\n' "$C" "$N"
    docker_network_status || true
    printf '\n1 开启/创建  2 接入容器  3 移除容器\n'
    printf '4 查看成员    5 查看代理地址  6 Compose 模板\n'
    printf '7 关闭持久接入                0 返回\n'
    read -r -p '请选择: ' x || return
    case "$x" in
      1) docker_network_on ;;
      2) read -r -p '容器名称/ID: ' c; docker_network_connect "$c" ;;
      3) read -r -p '容器名称/ID: ' c; docker_network_disconnect "$c" ;;
      4) docker_network_members || true ;;
      5) docker_network_urls ;;
      6) docker_network_snippet ;;
      7) docker_network_off ;;
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
    disconnect|remove|rm) docker_network_disconnect "${1:-}" ;;
    list|members) docker_network_members ;;
    urls|address|addresses) docker_network_urls ;;
    env) docker_network_env "${1:-}" ;;
    snippet|compose) docker_network_snippet "${1:-}" ;;
    help|-h|--help)
      cat <<'EOF'
sbx docker-network                    交互菜单
sbx docker-network on [network]       创建并启用共享代理网络
sbx docker-network off                关闭 sing-box 的持久共享网络接入
sbx docker-network status             查看状态
sbx docker-network connect <container>
sbx docker-network disconnect <container>
sbx docker-network list               查看网络成员
sbx docker-network urls               查看默认/自定义入口的容器内代理地址
sbx docker-network env [port]         输出容器侧代理环境变量
sbx docker-network snippet [port]     输出其他 Compose 项目的接入模板
EOF
      ;;
    *) die "未知 docker-network 命令: $op" ;;
  esac
}
