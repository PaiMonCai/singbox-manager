#!/usr/bin/env bash
# singbox-manager v0.7 self-update integration.

VERSION="0.10.1"

UPDATE_REPO="${SBX_UPDATE_REPO:-PaiMonCai/singbox-manager}"
UPDATE_BRANCH="${SBX_UPDATE_BRANCH:-main}"
UPDATE_BASE="${SBX_UPDATE_BASE_URL:-https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}}"
UPDATE_SERVICE_FILE="${SBX_UPDATE_SERVICE_FILE:-/etc/systemd/system/singbox-manager-update.service}"
UPDATE_TIMER_FILE="${SBX_UPDATE_TIMER_FILE:-/etc/systemd/system/singbox-manager-update.timer}"
UPDATE_BIN_LINK="${SBX_BIN_LINK:-/usr/local/bin/sbx}"
UPDATE_INSTALLER_LINK="${SBX_INSTALLER_LINK:-/usr/local/bin/sbx-install}"

manager_proxy_url(){
  local port="7890"
  if [[ -f "${ENV:-$HOME_DIR/.env}" ]]; then
    port="$(grep -E '^SING_BOX_MIXED_PORT=' "${ENV:-$HOME_DIR/.env}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    [[ -n "$port" ]] || port="7890"
  fi
  printf 'http://127.0.0.1:%s' "$port"
}

manager_fetch_stdout(){
  local url="$1" proxy
  curl -fsSL --retry 2 --connect-timeout 8 --max-time 20 "$url" && return 0
  proxy="$(manager_proxy_url)"
  warn "直连更新源失败，尝试通过本机 sing-box: $proxy"
  curl -fsSL --proxy "$proxy" --retry 1 --connect-timeout 5 --max-time 25 "$url"
}

manager_fetch_file(){
  local url="$1" output="$2" proxy
  if curl -fL --retry 2 --connect-timeout 8 --max-time 30 "$url" -o "$output"; then
    return 0
  fi
  proxy="$(manager_proxy_url)"
  warn "直连更新源失败，尝试通过本机 sing-box: $proxy"
  curl -fL --proxy "$proxy" --retry 1 --connect-timeout 5 --max-time 30 "$url" -o "$output"
}


manager_local_version(){
  if [[ -f "$HOME_DIR/VERSION" ]]; then
    tr -d '[:space:]' < "$HOME_DIR/VERSION"
  else
    printf '%s' "$VERSION"
  fi
}

manager_remote_version(){
  manager_fetch_stdout "${UPDATE_BASE%/}/VERSION" | tr -d '[:space:]'
}

manager_check(){
  command -v curl >/dev/null 2>&1 || die "检查更新需要 curl。"
  local local_v remote_v
  local_v="$(manager_local_version)"
  remote_v="$(manager_remote_version)" || die "无法获取远端版本。"
  printf '当前版本: %s\n远端版本: %s\n' "$local_v" "$remote_v"
  if [[ "$local_v" == "$remote_v" ]]; then
    printf '状态: 已是最新版本\n'
  else
    printf '状态: 有可用更新\n'
  fi
}

manager_update(){
  command -v curl >/dev/null 2>&1 || die "更新需要 curl。"
  local quiet=0 force=0 arg local_v remote_v tmp
  for arg in "$@"; do
    case "$arg" in
      --quiet) quiet=1 ;;
      --force) force=1 ;;
      *) die "用法: sbx manager update [--quiet] [--force]" ;;
    esac
  done

  local_v="$(manager_local_version)"
  remote_v="$(manager_remote_version)" || {
    ((quiet)) || warn "无法获取远端版本。"
    return 1
  }

  if [[ "$local_v" == "$remote_v" && "$force" != "1" ]]; then
    ((quiet)) || info "singbox-manager 已是最新版本: $local_v"
    return 0
  fi

  ((quiet)) || info "更新 singbox-manager: $local_v -> $remote_v"
  tmp="$(mktemp /tmp/sbx-manager-update.XXXXXX.sh)"
  trap 'rm -f "$tmp"' RETURN

  manager_fetch_file "${UPDATE_BASE%/}/install.sh" "$tmp"

  SBX_MANAGER_ONLY=1 SBX_NONINTERACTIVE=1 SBX_INSTALL_DIR="$HOME_DIR" SBX_BIN_LINK="$UPDATE_BIN_LINK" SBX_INSTALLER_LINK="$UPDATE_INSTALLER_LINK" SBX_REPO="$UPDATE_REPO" SBX_INSTALL_BRANCH="$UPDATE_BRANCH" SBX_SOURCE_BASE_URL="$UPDATE_BASE" bash "$tmp"

  rm -f "$tmp"
  trap - RETURN

  local installed
  installed="$(tr -d '[:space:]' < "$HOME_DIR/VERSION" 2>/dev/null || true)"
  if [[ "$installed" != "$remote_v" ]]; then
    die "更新完成后版本校验失败：期望 $remote_v，实际 ${installed:-unknown}"
  fi

  ((quiet)) || info "管理器已更新到 $installed。"
}

manager_auto_on(){
  command -v systemctl >/dev/null 2>&1 || die "自动更新目前要求 systemd。"
  warn "自动更新会定期从 $UPDATE_REPO/$UPDATE_BRANCH 拉取并执行 manager 更新。"
  warn "只有在你信任该仓库与分支时才应开启。"

  if [[ "${SBX_UPDATE_NO_APPLY:-0}" != "1" ]]; then
    read -r -p '输入 AUTO 确认开启自动更新: ' answer
    [[ "$answer" == "AUTO" ]] || { warn "已取消。"; return 1; }
  fi

  mkdir -p "$(dirname "$UPDATE_SERVICE_FILE")" "$(dirname "$UPDATE_TIMER_FILE")"

  cat > "$UPDATE_SERVICE_FILE" <<EOF
[Unit]
Description=singbox-manager self update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="SBX_UPDATE_REPO=$UPDATE_REPO"
Environment="SBX_UPDATE_BRANCH=$UPDATE_BRANCH"
Environment="SBX_UPDATE_BASE_URL=$UPDATE_BASE"
ExecStart=$UPDATE_BIN_LINK manager update --quiet
EOF

  cat > "$UPDATE_TIMER_FILE" <<'EOF'
[Unit]
Description=Daily singbox-manager update check

[Timer]
OnBootSec=15min
OnUnitActiveSec=24h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  chmod 644 "$UPDATE_SERVICE_FILE" "$UPDATE_TIMER_FILE"

  if [[ "${SBX_UPDATE_NO_APPLY:-0}" == "1" ]]; then
    info "自动更新 systemd 文件已生成；测试模式未启用 timer。"
    return 0
  fi

  systemctl daemon-reload
  systemctl enable --now singbox-manager-update.timer
  info "自动更新已开启。"
}

manager_auto_off(){
  if command -v systemctl >/dev/null 2>&1 && [[ "${SBX_UPDATE_NO_APPLY:-0}" != "1" ]]; then
    systemctl disable --now singbox-manager-update.timer >/dev/null 2>&1 || true
  fi
  rm -f "$UPDATE_SERVICE_FILE" "$UPDATE_TIMER_FILE"
  if command -v systemctl >/dev/null 2>&1 && [[ "${SBX_UPDATE_NO_APPLY:-0}" != "1" ]]; then
    systemctl daemon-reload
  fi
  info "自动更新已关闭。"
}

manager_auto_status(){
  printf '当前版本: %s\n' "$(manager_local_version)"
  printf '更新源:   %s\n' "$UPDATE_BASE"
  if [[ -f "$UPDATE_TIMER_FILE" ]]; then
    printf '自动更新: CONFIGURED\n'
    if command -v systemctl >/dev/null 2>&1; then
      systemctl is-enabled singbox-manager-update.timer 2>/dev/null | sed 's/^/systemd:   /' || true
      systemctl list-timers singbox-manager-update.timer --no-pager 2>/dev/null || true
    fi
  else
    printf '自动更新: OFF\n'
  fi
}

manager_menu(){
  local x
  while true; do
    clear
    printf '%b管理器更新%b\n' "$C" "$N"
    printf '当前版本: %s\n\n' "$(manager_local_version)"
    printf '1 检查更新  2 立即更新  3 强制重装管理器\n'
    printf '4 开启自动更新  5 关闭自动更新  6 自动更新状态  0 返回\n'
    read -r -p '请选择: ' x || return
    case "$x" in
      1) manager_check || true ;;
      2) manager_update || true ;;
      3) manager_update --force || true ;;
      4) manager_auto_on || true ;;
      5) manager_auto_off || true ;;
      6) manager_auto_status ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

manager_cmd(){
  local op="${1:-menu}"
  shift || true
  case "$op" in
    menu) manager_menu ;;
    check) manager_check ;;
    update) manager_update "$@" ;;
    version) manager_local_version; printf '\n' ;;
    auto)
      case "${1:-status}" in
        on) manager_auto_on ;;
        off) manager_auto_off ;;
        status) manager_auto_status ;;
        *) die "用法: sbx manager auto on|off|status" ;;
      esac
      ;;
    help|-h|--help)
      cat <<'EOF'
sbx manager check               检查 manager 更新
sbx manager update              立即更新 manager，不动 sing-box 镜像/节点
sbx manager update --force      强制重装当前远端版本
sbx manager auto on             开启每日自动更新
sbx manager auto off            关闭自动更新
sbx manager auto status         查看自动更新状态
sbx self-update                 sbx manager update 的快捷别名
sbx-install                     获取最新 install.sh 并执行完整安装/升级
EOF
      ;;
    *) die "未知 manager 命令: $op" ;;
  esac
}

version(){
  printf 'singbox-manager: %s\npinned sing-box: %s\nimage: %s\nstrategy: %s\nroute: %s\ncustom inbounds: %s\nproxy: %s\n'     "$(manager_local_version)" "$(image_version)" "$(image_ref)"     "$(python3 "$HELPER" strategy)" "$(python3 "$HELPER" route-mode)"     "$(python3 "$HELPER" inbound-endpoints --json 2>/dev/null | python3 -c 'import json,sys; print(max(0,len(json.load(sys.stdin))-1))' 2>/dev/null || printf '0')"     "$(proxy_url)"
}

menu(){
  local x v f
  while true; do
    clear
    printf '%b' "$C"
    cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        singbox-manager 0.10.1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 1 状态      2 启动      3 停止      4 重启
 5 日志      6 节点管理  7 导入      8 订阅管理
 9 出口策略 10 路由模式 11 应用代理 12 入口管理
13 检查     14 测试代理 15 备份     16 恢复
17 版本     18 sing-box升级          19 拉取当前镜像
20 管理器更新  21 Docker容器网络 22 高级编辑
 0 退出
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
    printf '%b' "$N"
    read -r -p '请选择: ' x || exit
    case "$x" in
      1) status ;;
      2) start ;;
      3) stop ;;
      4) restart ;;
      5) logs || true ;;
      6) node_menu; continue ;;
      7) import_menu; continue ;;
      8) subscription_menu; continue ;;
      9) strategy_menu; continue ;;
      10) route_menu; continue ;;
      11) proxy_menu; continue ;;
      12) inbound_menu; continue ;;
      13) check || true ;;
      14) test_current || true ;;
      15) backup ;;
      16) read -r -p '备份文件(留空最新): ' f; restore "$f" || true ;;
      17) version ;;
      18) read -r -p 'sing-box 目标版本: ' v; [[ -n "$v" ]] && upgrade "$v" || true ;;
      19) pull ;;
      20) manager_menu; continue ;;
      21) docker_network_menu; continue ;;
      22) edit || true ;;
      0) exit ;;
      *) warn "无效选项" ;;
    esac
    pause
  done
}

help(){
  cat <<'EOF'
sbx                                  交互菜单
sbx node                             节点管理
sbx inbound                          多入口 -> 出口路由管理
sbx import uri|file                  分享链接 / 文件导入
sbx subscription                     订阅管理
sbx strategy manual|auto
sbx route global|cn-direct-lite|cn-direct-full
sbx proxy                            Docker/Git/APT/npm 应用代理
sbx image status|bootstrap|pull|load
sbx manager                          管理器更新菜单
sbx manager check|update
sbx manager auto on|off|status
sbx docker-network                    Docker 容器共享代理网络
sbx self-update                      快速更新 singbox-manager
sbx-install                          获取最新安装器并完整安装/升级
sbx status/start/stop/restart/logs/check/test
sbx backup/restore [file]
sbx version
sbx upgrade <version>                升级 sing-box
sbx pull                             拉取当前 sing-box 镜像
EOF
}

main(){
  root "$@"
  local cmd="${1:-menu}"
  shift || true

  local lightweight=0
  case "$cmd" in
    manager|self-update) lightweight=1 ;;
    proxy)
      case "${1:-menu}:${2:-}" in
        status:*|env:*|help:*|-h:*|--help:*|*:off|all:off) lightweight=1 ;;
      esac
      ;;
  esac

  if ((lightweight)); then
    [[ -d "$HOME_DIR" ]] || die "未找到 $HOME_DIR，请先安装 singbox-manager。"
  else
    ready
  fi

  mkdir -p "$PROXY_STATE_DIR"
  chmod 700 "$PROXY_STATE_DIR" 2>/dev/null || true

  case "$cmd" in
    menu) menu ;;
    node) node "$@" ;;
    inbound|in) inbound_cmd "$@" ;;
    import) import_cmd "$@" ;;
    subscription|sub) subscription "$@" ;;
    strategy) strategy "${1:-}" ;;
    route) route_mode "${1:-}" ;;
    urltest) urltest "$@" ;;
    proxy) proxy_cmd "$@" ;;
    image) image_cmd "$@" ;;
    manager) manager_cmd "$@" ;;
    self-update) manager_update "$@" ;;
    docker-network|dnet) docker_network_cmd "$@" ;;
    status|ps) status ;;
    start|up) start ;;
    stop|down) stop ;;
    restart) restart ;;
    logs|log) logs ;;
    check) check ;;
    test) test_current ;;
    backup) backup ;;
    restore) restore "${1:-}" ;;
    version|-v|--version) version ;;
    upgrade) upgrade "${1:-}" ;;
    pull|update) pull ;;
    edit|config) edit ;;
    help|-h|--help) help ;;
    *) die "未知命令: $cmd" ;;
  esac
}
