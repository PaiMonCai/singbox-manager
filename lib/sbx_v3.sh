#!/usr/bin/env bash
# singbox-manager v0.3 extension. Sourced by bin/sbx after core functions load.

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
  if running; then
    restart || { warn "配置已写入磁盘，但 sing-box 重启失败，配置尚未生效。"; return 1; }
  fi
  info "配置已生效。"
}

fetch_url(){
  local url="$1" out="$2" port phost="127.0.0.1"
  command -v curl >/dev/null 2>&1 || die "订阅功能需要 curl。"
  if curl -fL --retry 2 --connect-timeout 8 --max-time 30 -A "singbox-manager/$VERSION" "$url" -o "$out"; then
    return 0
  fi
  if running; then
    port=$(envval SING_BOX_MIXED_PORT 7890)
    # proxy_host() 定义在 bin/sbx（会读 SING_BOX_BIND_ADDR）；单独 source 时退回回环地址
    declare -F proxy_host >/dev/null 2>&1 && phost="$(proxy_host)"
    warn "直接下载失败，尝试通过当前 sing-box 代理下载..."
    curl -fL --retry 2 --connect-timeout 8 --max-time 30 -A "singbox-manager/$VERSION" \
      --proxy "http://$phost:$port" "$url" -o "$out"
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
  if running; then
    restart || { warn "订阅已导入，但 sing-box 重启失败；请执行 sbx logs 检查。"; return 1; }
  fi
  info "订阅已添加并生效。"
}

sub_update(){
  local ref="${1:-}" url id tmp rollback rc=0
  if [[ -z "$ref" ]]; then
    python3 "$HELPER" sub-list
    read -r -p '订阅 ID/名称: ' ref || { warn "未收到输入（EOF）。"; return 1; }
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
  if running; then
    restart || { warn "订阅已更新，但 sing-box 重启失败；请执行 sbx logs 检查。"; return 1; }
  fi
  info "订阅更新完成。"
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
    menu) subs_import_menu ;;
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
    # 序号是交互层主入口；--ids 等额外参数原样透传给 helper
    list|ls) shift || true; python3 "$HELPER" list "$@" ;;
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

# 订阅与一次性导入合成一个菜单：旧版「导入」的第二项又是「订阅」，同一件事两个入口。
# 条目版式约定（所有菜单一致，便于扫读）：
#   <3 空格><编号 1-2 位><2 空格><名称补齐到 10 显示列><2 空格><说明 ≤ 24 显示列>
# 名称不含空格，说明也刻意压短，因此紧凑版式（宽度 42）与宽松版式（≥60 列）都不会折行。
subs_import_menu(){
  local x r
  while true; do
    clear
    menu_title '订阅与导入'
    menu_note '订阅自动同步节点；导入是一次性的。'
    menu_block '订阅' <<'EOF'
   1  订阅列表    查看已添加的订阅
   2  添加订阅    从 URL 添加并同步节点
   3  更新订阅    立即重新拉取节点
   4  删除订阅    只删订阅，不动已有节点
   5  订阅详情    查看某个订阅的内容
EOF
    menu_block '一次性导入' <<'EOF'
   6  分享链接    粘贴 vmess / vless 链接
   7  本地文件    从 URI / 订阅文件导入
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) subscription list ;;
      2) sub_add || true ;;
      3) sub_update || true ;;
      4) read -r -p '订阅 ID/名称: ' r; sub_delete "$r" || true ;;
      5) read -r -p '订阅 ID/名称: ' r; python3 "$HELPER" sub-get "$r" || true ;;
      6) import_uri || true ;;
      7) read -r -p '文件路径: ' r; import_file "$r" || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

# 出口策略与路由模式合成一个菜单：二者都是「流量从哪出去」，分开放容易记混。
outlet_menu(){
  local x
  while true; do
    clear
    menu_title '出口与分流'
    menu_note "出口策略: $(python3 "$HELPER" strategy 2>/dev/null || printf '?')    路由模式: $(python3 "$HELPER" route-mode 2>/dev/null || printf '?')"
    menu_block '出口策略' <<'EOF'
   1  手动出口    manual：手动指定默认节点
   2  自动测速    auto：URLTest 自动选最快
   3  测速参数    修改测速 URL / 间隔
EOF
    menu_block '路由模式' <<'EOF'
   4  全局模式    global：私网直连其余代理
   5  轻量直连    cn-direct-lite + .cn
   6  完整直连    cn-direct-full 规则集
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) strategy manual || true ;;
      2) strategy auto || true ;;
      3) python3 "$HELPER" urltest; warn "修改可用: sbx urltest --url URL --interval 3m --tolerance 50" ;;
      4) route_mode global || true ;;
      5) route_mode cn-direct-lite || true ;;
      6) route_mode cn-direct-full || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

import_cmd(){
  local op="${1:-menu}"
  shift || true
  case "$op" in
    uri) import_uri "${1:-}" ;;
    file) import_file "${1:-}" ;;
    subscription|sub) sub_add "${1:-}" "${2:-}" ;;
    # 与 `sbx subscription` 共用同一张菜单，避免两个入口指向同一件事
    menu) subs_import_menu ;;
    *) die "未知 import 命令: $op" ;;
  esac
}
