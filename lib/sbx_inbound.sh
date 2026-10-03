#!/usr/bin/env bash
# singbox-manager v0.6 multi-inbound routing integration.
# Sourced after the node/proxy/bootstrap/image layers.

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

  if running; then
    restart || { warn "入口配置已写入磁盘，但 sing-box 重启失败；请执行 sbx logs 检查。"; return 1; }
  fi
  info "入口配置已生效。"
}

inbound_test(){
  local ref="${1:-}" json listen port host proxy
  if [[ -z "$ref" ]]; then
    python3 "$HELPER" inbound-list
    read -r -p '入口 ID/名称: ' ref
  fi
  [[ -n "$ref" ]] || die "入口不能为空。"

  json="$(python3 "$HELPER" inbound-show "$ref")" || return 1
  listen="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("listen",""))' 2>/dev/null)" || true
  port="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("port",""))' 2>/dev/null)" || true
  [[ -n "$listen" && -n "$port" ]] || die "入口条目缺少 listen/port 字段，请先重新编辑该入口: $ref"

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
sbx inbound list                  查看全部入口及唯一 ID
sbx inbound add                   添加 mixed 入口
sbx inbound edit [ID|名称]        编辑入口
sbx inbound delete [ID|名称]      删除入口
sbx inbound show [ID|名称]        查看入口及解析后的出口
sbx inbound test [ID|名称]        测试该入口的真实代理

高级非交互参数：
sbx inbound add --name NAME --listen 127.0.0.1 --port 7891 --target proxy
sbx inbound add --name HK --listen 127.0.0.1 --port 7892 --target node:2

target 支持：direct / proxy / auto / node:<节点序号|名称>
（节点序号来自 sbx node list，按节点库顺序从 1 开始）
EOF
      ;;
    *) die "未知 inbound 命令: $op" ;;
  esac
}

inbound_menu(){
  local x ref
  while true; do
    clear
    menu_title '入口路由'
    menu_note 'Docker 托管建议按入口 ID 绑定。'
    printf '\n'
    python3 "$HELPER" inbound-list || true
    menu_block '入口操作' <<'EOF'
   1  添加        新增一个代理入口
   2  编辑        修改端口 / 出口绑定
   3  删除        删除某个入口
   4  详情        查看入口配置
   5  测试        测试入口能否连通
EOF
    menu_footer '0  返回'
    menu_end
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
