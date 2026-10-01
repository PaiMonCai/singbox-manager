#!/usr/bin/env bash
# singbox-manager v0.6 multi-inbound routing integration.
# Sourced after the node/proxy/bootstrap/image layers.

VERSION="0.6.0"

inbound_tx(){
  local op="$1" ref="${2:-}" rollback rc=0
  shift 2 || true
  backup
  rollback="$BACKUP_RESULT"

  case "$op" in
    add) python3 "$HELPER" inbound-add "$@" || rc=$? ;;
    edit) python3 "$HELPER" inbound-edit ${ref:+"$ref"} "$@" || rc=$? ;;
    delete) python3 "$HELPER" inbound-delete ${ref:+"$ref"} "$@" || rc=$? ;;
    *) die "未知入口操作: $op" ;;
  esac

  if ((rc)); then
    restore_raw "$rollback" no
    return "$rc"
  fi

  if ! python3 "$HELPER" validate >/dev/null || ! check; then
    warn "入口配置未通过 sing-box 校验，正在自动回滚。"
    restore_raw "$rollback" no
    return 1
  fi

  info "入口配置已生效。"
  running && restart || true
}

inbound_test(){
  local ref="${1:-}" json listen port host proxy
  if [[ -z "$ref" ]]; then
    python3 "$HELPER" inbound-list
    read -r -p '入口 ID/名称: ' ref
  fi
  [[ -n "$ref" ]] || die "入口不能为空。"

  json="$(python3 "$HELPER" inbound-show "$ref")" || return 1
  listen="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["listen"])')"
  port="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["port"])')"

  case "$listen" in
    0.0.0.0) host="127.0.0.1" ;;
    "::") host="[::1]" ;;
    *:*) host="[$listen]" ;;
    *) host="$listen" ;;
  esac
  proxy="http://$host:$port"

  running || die "sing-box 未运行。请先执行 sbx start。"
  http_test "$proxy" && info "入口测试通过: $proxy" || die "入口测试失败: $proxy"
}

inbound_cmd(){
  local op="${1:-menu}" ref=""
  shift || true

  case "$op" in
    menu) inbound_menu ;;
    list|ls) python3 "$HELPER" inbound-list ;;
    add) inbound_tx add "" "$@" ;;
    edit)
      if [[ "$#" -gt 0 && "${1:-}" != --* ]]; then ref="$1"; shift; fi
      inbound_tx edit "$ref" "$@"
      ;;
    delete|del|rm)
      if [[ "$#" -gt 0 && "${1:-}" != --* ]]; then ref="$1"; shift; fi
      inbound_tx delete "$ref" "$@"
      ;;
    show)
      ref="${1:-}"
      python3 "$HELPER" inbound-show ${ref:+"$ref"}
      ;;
    test)
      ref="${1:-}"
      inbound_test "$ref"
      ;;
    help|-h|--help)
      cat <<'EOF'
sbx inbound                       入口管理菜单
sbx inbound list                  查看自定义入口
sbx inbound add                   添加 mixed 入口
sbx inbound edit [ID|名称]        编辑入口
sbx inbound delete [ID|名称]      删除入口
sbx inbound show [ID|名称]        查看入口及解析后的出口
sbx inbound test [ID|名称]        测试该入口的真实代理

高级非交互参数：
sbx inbound add --name NAME --listen 127.0.0.1 --port 7891 --target proxy
sbx inbound add --name HK --listen 127.0.0.1 --port 7892 --target node:<节点ID>

target 支持：direct / proxy / auto / node:<节点ID或名称>
EOF
      ;;
    *) die "未知 inbound 命令: $op" ;;
  esac
}

inbound_menu(){
  local x ref
  while true; do
    clear
    printf '%b入口路由管理%b\n' "$C" "$N"
    printf '默认入口: %s:%s -> proxy（受全局 strategy / route 控制）\n\n'       "$(envval SING_BOX_BIND_ADDR 127.0.0.1)" "$(envval SING_BOX_MIXED_PORT 7890)"
    python3 "$HELPER" inbound-list || true
    printf '\n1 添加  2 编辑  3 删除  4 详情  5 测试  0 返回\n'
    read -r -p '请选择: ' x || return
    case "$x" in
      1) inbound_tx add "" || true ;;
      2) read -r -p '入口 ID/名称(留空后选择): ' ref; inbound_tx edit "$ref" || true ;;
      3) read -r -p '入口 ID/名称(留空后选择): ' ref; inbound_tx delete "$ref" || true ;;
      4) read -r -p '入口 ID/名称(留空后选择): ' ref; python3 "$HELPER" inbound-show ${ref:+"$ref"} || true ;;
      5) read -r -p '入口 ID/名称(留空后选择): ' ref; inbound_test "$ref" || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

version(){
  printf 'singbox-manager: %s\npinned sing-box: %s\nimage: %s\nstrategy: %s\nroute: %s\ncustom inbounds: %s\nproxy: %s\n'     "$VERSION" "$(image_version)" "$(image_ref)"     "$(python3 "$HELPER" strategy)" "$(python3 "$HELPER" route-mode)"     "$(python3 "$HELPER" inbound-list 2>/dev/null | awk 'NR>2{n++} END{print n+0}')"     "$(proxy_url)"
}

menu(){
  local x v f
  while true; do
    clear
    printf '%b' "$C"
    cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        singbox-manager 0.6
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 1 状态      2 启动      3 停止      4 重启
 5 日志      6 节点管理  7 导入      8 订阅管理
 9 出口策略 10 路由模式 11 应用代理 12 入口管理
13 检查     14 测试代理 15 备份     16 恢复
17 版本     18 升级     19 拉取当前版本
20 高级编辑
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
      18) read -r -p '目标版本: ' v; [[ -n "$v" ]] && upgrade "$v" || true ;;
      19) pull ;;
      20) edit || true ;;
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
sbx inbound add/list/edit/delete/show/test
sbx import uri|file                  分享链接 / 文件导入
sbx subscription                     订阅管理
sbx strategy manual|auto             手动 / URLTest 自动测速
sbx route global|cn-direct-lite|cn-direct-full
sbx proxy                            Docker/Git/APT/npm 应用代理
sbx image status|bootstrap|pull|load
sbx status/start/stop/restart/logs/check/test
sbx backup/restore [file]
sbx version/upgrade <version>/pull
EOF
}

main(){
  root "$@"
  local cmd="${1:-menu}"
  shift || true

  local lightweight=0
  if [[ "$cmd" == "proxy" ]]; then
    case "${1:-menu}:${2:-}" in
      status:*|env:*|help:*|-h:*|--help:*|*:off|all:off) lightweight=1 ;;
    esac
  fi

  if ((lightweight)); then
    [[ -f "$ENV" ]] || die "未找到 $ENV，请先安装 singbox-manager。"
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
