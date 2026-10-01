#!/usr/bin/env bash
# singbox-manager v0.3 extension. Sourced by bin/sbx after core functions load.
VERSION="0.3.0"

transaction_v3(){
  local rollback rc=0
  backup
  rollback="$BACKUP_RESULT"
  "$@" || rc=$?
  if ((rc)); then
    restore_raw "$rollback" no
    return "$rc"
  fi
  if ! python3 "$HELPER" validate >/dev/null || ! check; then
    warn "新配置未通过校验，自动回滚"
    restore_raw "$rollback" no
    return 1
  fi
  info "配置已生效。"
  running && restart || true
}

fetch_url(){
  local url="$1" out="$2" port
  command -v curl >/dev/null 2>&1 || die "订阅功能需要 curl。"
  if curl -fL --retry 2 --connect-timeout 8 --max-time 30 -A "singbox-manager/$VERSION" "$url" -o "$out"; then
    return 0
  fi
  if running; then
    port=$(envval SING_BOX_MIXED_PORT 7890)
    warn "直接下载失败，尝试通过当前 sing-box 代理下载..."
    curl -fL --retry 2 --connect-timeout 8 --max-time 30 -A "singbox-manager/$VERSION" \
      --proxy "http://127.0.0.1:$port" "$url" -o "$out"
  else
    return 1
  fi
}

import_uri(){
  local uri="${1:-}"
  if [[ -z "$uri" ]]; then
    read -r -s -p '粘贴分享链接（输入不会回显）: ' uri
    printf '\n'
  fi
  [[ -n "$uri" ]] || die "分享链接不能为空。"
  transaction_v3 python3 "$HELPER" import-uri "$uri"
}

import_file(){
  local file="${1:-}"
  [[ -n "$file" && -f "$file" ]] || die "用法: sbx import file <path>"
  transaction_v3 python3 "$HELPER" import-file "$file"
}

sub_add(){
  local url="${1:-}" name="${2:-}" tmp rollback id rc=0
  if [[ -z "$url" ]]; then
    read -r -s -p '订阅 URL（输入不会回显）: ' url
    printf '\n'
  fi
  [[ -n "$url" ]] || die "订阅 URL 不能为空。"
  [[ -n "$name" ]] || read -r -p '订阅名称（可留空）: ' name

  backup
  rollback="$BACKUP_RESULT"
  if [[ -n "$name" ]]; then
    id=$(python3 "$HELPER" sub-register "$url" --name "$name") || { restore_raw "$rollback" no; return 1; }
  else
    id=$(python3 "$HELPER" sub-register "$url") || { restore_raw "$rollback" no; return 1; }
  fi

  tmp=$(mktemp)
  fetch_url "$url" "$tmp" || rc=$?
  if ((rc==0)); then
    python3 "$HELPER" sub-apply "$id" "$tmp" || rc=$?
  fi
  rm -f "$tmp"

  if ((rc)) || ! python3 "$HELPER" validate >/dev/null || ! check; then
    warn "订阅导入失败，自动回滚"
    restore_raw "$rollback" no
    return 1
  fi
  info "订阅已添加并生效。"
  running && restart || true
}

sub_update(){
  local ref="${1:-}" url id tmp rollback rc=0
  if [[ -z "$ref" ]]; then
    python3 "$HELPER" sub-list
    read -r -p '订阅 ID/名称: ' ref
  fi
  [[ -n "$ref" ]] || return 1
  url=$(python3 "$HELPER" sub-get "$ref" --field url) || return 1
  id=$(python3 "$HELPER" sub-get "$ref" --field id) || return 1

  backup
  rollback="$BACKUP_RESULT"
  tmp=$(mktemp)
  fetch_url "$url" "$tmp" || rc=$?
  if ((rc==0)); then
    python3 "$HELPER" sub-apply "$id" "$tmp" || rc=$?
  fi
  rm -f "$tmp"

  if ((rc)) || ! python3 "$HELPER" validate >/dev/null || ! check; then
    warn "订阅更新失败，自动回滚"
    restore_raw "$rollback" no
    return 1
  fi
  info "订阅更新完成。"
  running && restart || true
}

sub_delete(){
  local ref="${1:-}"
  transaction_v3 python3 "$HELPER" sub-delete ${ref:+"$ref"}
}

subscription(){
  local op="${1:-menu}"
  shift || true
  case "$op" in
    list|ls) python3 "$HELPER" sub-list ;;
    add) sub_add "${1:-}" "${2:-}" ;;
    update|refresh) sub_update "${1:-}" ;;
    delete|del|rm) sub_delete "${1:-}" ;;
    show) python3 "$HELPER" sub-get "${1:-}" ;;
    menu) subscription_menu ;;
    *) die "未知 subscription 命令: $op" ;;
  esac
}

strategy(){
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    python3 "$HELPER" strategy
    return
  fi
  case "$value" in
    manual|auto) ;;
    *) die "用法: sbx strategy manual|auto" ;;
  esac
  transaction_v3 python3 "$HELPER" strategy "$value"
}

route_mode(){
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    python3 "$HELPER" route-mode
    return
  fi
  case "$value" in
    global|cn-direct-lite|cn-direct-full) ;;
    *) die "用法: sbx route global|cn-direct-lite|cn-direct-full" ;;
  esac
  if [[ "$value" == "cn-direct-full" ]]; then
    info "完整国内直连模式会加载 CN GeoIP/Geosite rule-set；首次运行需要能够下载规则集。"
  fi
  transaction_v3 python3 "$HELPER" route-mode "$value"
}

urltest(){
  local args=()
  while (($#)); do
    case "$1" in
      --url|--interval|--tolerance)
        [[ $# -ge 2 ]] || die "$1 缺少参数"
        args+=("$1" "$2")
        shift 2
        ;;
      *) die "未知参数: $1" ;;
    esac
  done
  transaction_v3 python3 "$HELPER" urltest "${args[@]}"
}

node(){
  local op="${1:-menu}" ref="${2:-}"
  case "$op" in
    list|ls) python3 "$HELPER" list ;;
    add|edit|delete|del|rm|default|use)
      case "$op" in del|rm) op=delete;; use) op=default;; esac
      node_tx "$op" "$ref"
      ;;
    show) python3 "$HELPER" show ${ref:+"$ref"} ;;
    test) test_node "$ref" ;;
    render) transaction_v3 python3 "$HELPER" render >/dev/null ;;
    menu) node_menu ;;
    *) die "未知 node 命令: $op" ;;
  esac
}

version(){
  printf 'singbox-manager: %s\npinned sing-box: %s\nstrategy: %s\nroute: %s\n' \
    "$VERSION" "$(envval SING_BOX_VERSION v1.14.2)" \
    "$(python3 "$HELPER" strategy)" "$(python3 "$HELPER" route-mode)"
}

subscription_menu(){
  local x r
  while true; do
    clear
    printf '%b订阅管理%b\n1 查看  2 添加  3 更新  4 删除  5 详情  0 返回\n' "$C" "$N"
    read -r -p '请选择: ' x || return
    case "$x" in
      1) subscription list ;;
      2) sub_add || true ;;
      3) sub_update || true ;;
      4) read -r -p 'ID/名称: ' r; sub_delete "$r" || true ;;
      5) read -r -p 'ID/名称: ' r; python3 "$HELPER" sub-get "$r" || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

import_menu(){
  local x f
  while true; do
    clear
    printf '%b导入%b\n1 分享链接  2 订阅  3 本地订阅/URI 文件  0 返回\n' "$C" "$N"
    read -r -p '请选择: ' x || return
    case "$x" in
      1) import_uri || true ;;
      2) sub_add || true ;;
      3) read -r -p '文件路径: ' f; import_file "$f" || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

strategy_menu(){
  local x
  while true; do
    clear
    printf '%b出口策略%b\n当前: %s\n1 manual 手动默认节点\n2 auto URLTest 自动测速\n3 查看 URLTest 参数\n0 返回\n' \
      "$C" "$N" "$(python3 "$HELPER" strategy)"
    read -r -p '请选择: ' x || return
    case "$x" in
      1) strategy manual || true ;;
      2) strategy auto || true ;;
      3) python3 "$HELPER" urltest; warn "修改可用: sbx urltest --url URL --interval 3m --tolerance 50" ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

route_menu(){
  local x
  while true; do
    clear
    printf '%b路由模式%b\n当前: %s\n1 global           私网直连，其余代理\n2 cn-direct-lite   私网 + .cn 直连\n3 cn-direct-full   私网 + .cn + CN rule-set 直连\n0 返回\n' \
      "$C" "$N" "$(python3 "$HELPER" route-mode)"
    read -r -p '请选择: ' x || return
    case "$x" in
      1) route_mode global || true ;;
      2) route_mode cn-direct-lite || true ;;
      3) route_mode cn-direct-full || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

menu(){
  local x v f
  while true; do
    clear
    printf '%b' "$C"
    cat <<'__MENU__'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        singbox-manager 0.3
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 1 状态      2 启动      3 停止      4 重启
 5 日志      6 节点管理  7 导入      8 订阅管理
 9 出口策略 10 路由模式 11 检查     12 测试代理
13 备份     14 恢复     15 版本     16 升级
17 拉取当前版本       18 高级编辑配置
 0 退出
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
__MENU__
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
      11) check || true ;;
      12) test_current || true ;;
      13) backup ;;
      14) read -r -p '备份文件(留空最新): ' f; restore "$f" || true ;;
      15) version ;;
      16) read -r -p '目标版本: ' v; [[ -n "$v" ]] && upgrade "$v" || true ;;
      17) pull ;;
      18) edit || true ;;
      0) exit ;;
      *) warn "无效选项" ;;
    esac
    pause
  done
}

help(){
  cat <<'__HELP__'
sbx                                  交互菜单
sbx node                             节点管理菜单
sbx import uri [URI]                 导入分享链接
sbx import file <path>               导入本地订阅/URI 列表
sbx subscription                    订阅管理菜单
sbx subscription add [URL] [name]
sbx subscription update [ID|name]
sbx subscription list/delete/show
sbx strategy manual|auto             手动节点 / URLTest 自动测速
sbx route global|cn-direct-lite|cn-direct-full
sbx urltest --url URL --interval 3m --tolerance 50
sbx status/start/stop/restart/logs/check/test
sbx backup/restore [file]
sbx version/upgrade <version>/pull
__HELP__
}

import_cmd(){
  local op="${1:-menu}"
  shift || true
  case "$op" in
    uri) import_uri "${1:-}" ;;
    file) import_file "${1:-}" ;;
    subscription|sub) sub_add "${1:-}" "${2:-}" ;;
    menu) import_menu ;;
    *) die "未知 import 命令: $op" ;;
  esac
}

main(){
  root "$@"
  ready
  local cmd="${1:-menu}"
  shift || true
  case "$cmd" in
    menu) menu ;;
    node) node "$@" ;;
    import) import_cmd "$@" ;;
    subscription|sub) subscription "$@" ;;
    strategy) strategy "${1:-}" ;;
    route) route_mode "${1:-}" ;;
    urltest) urltest "$@" ;;
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
