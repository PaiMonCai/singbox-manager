#!/usr/bin/env bash
# singbox-manager v0.4 host application proxy integration.
# Sourced after v0.3; overrides VERSION/menu/help/main and adds `sbx proxy`.

PROXY_STATE_DIR="${SBX_PROXY_STATE_DIR:-$HOME_DIR/proxy-state}"
DOCKER_DROPIN_DIR="${SBX_DOCKER_DROPIN_DIR:-/etc/systemd/system/docker.service.d}"
DOCKER_PROXY_FILE="${SBX_DOCKER_PROXY_FILE:-$DOCKER_DROPIN_DIR/99-singbox-manager-proxy.conf}"
APT_PROXY_FILE="${SBX_APT_PROXY_FILE:-/etc/apt/apt.conf.d/99singbox-manager-proxy}"
GIT_PROXY_FILE="${SBX_GIT_PROXY_FILE:-/etc/singbox-manager/git-proxy.conf}"
# curl 只读用户级配置（没有 /etc/curlrc 这种系统级文件），
# 默认写当前 HOME 下的 ~/.curlrc；CURL_HOME 与 SBX_CURLRC_FILE 都可覆盖。
CURLRC_FILE="${SBX_CURLRC_FILE:-${CURL_HOME:-$HOME}/.curlrc}"
PROXY_BLOCK_BEGIN="# >>> singbox-manager proxy >>>"
PROXY_BLOCK_END="# <<< singbox-manager proxy <<<"
NPM_BLOCK_BEGIN="$PROXY_BLOCK_BEGIN"
NPM_BLOCK_END="$PROXY_BLOCK_END"

# 定义留在本文件：sbx_proxy.sh 会被单独 source（CI 与手工调试都是这样），
# 依赖 bin/sbx 里先定义会让本文件单独加载时不可用。
proxy_host(){
  local bind
  bind=$(envval SING_BOX_BIND_ADDR 127.0.0.1)
  case "$bind" in
    0.0.0.0|"") printf '127.0.0.1' ;;
    "::"|"[::]") printf '[::1]' ;;
    *:*)
      bind="${bind#[}"
      bind="${bind%]}"
      printf '[%s]' "$bind"
      ;;
    *) printf '%s' "$bind" ;;
  esac
}
proxy_port(){ envval SING_BOX_MIXED_PORT 7890; }
proxy_url(){ printf 'http://%s:%s' "$(proxy_host)" "$(proxy_port)"; }
proxy_socks_url(){ printf 'socks5h://%s:%s' "$(proxy_host)" "$(proxy_port)"; }
proxy_no_proxy(){ printf 'localhost,127.0.0.1,::1'; }

proxy_require_running(){
  running || die "sing-box 当前未运行。请先执行 sbx start，再开启宿主机应用代理。"
}

proxy_is_rootless_docker(){
  docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -qi rootless
}

proxy_wait_docker(){
  for _ in $(seq 1 20); do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

proxy_docker_on(){
  local url no_proxy
  proxy_require_running
  proxy_is_rootless_docker && die "当前检测到 rootless Docker；0.4 暂不自动修改用户级 Docker systemd 服务。"
  command -v systemctl >/dev/null 2>&1 || die "Docker 一键代理目前要求 systemd。"
  url=$(proxy_url); no_proxy=$(proxy_no_proxy)
  mkdir -p "$DOCKER_DROPIN_DIR"
  cat > "$DOCKER_PROXY_FILE" <<EOF
[Service]
Environment="HTTP_PROXY=$url"
Environment="HTTPS_PROXY=$url"
Environment="NO_PROXY=$no_proxy"
EOF
  chmod 644 "$DOCKER_PROXY_FILE"
  info "已写入 Docker daemon 代理: $DOCKER_PROXY_FILE"
  if [[ -f /etc/docker/daemon.json ]] && python3 - <<'PY' >/dev/null 2>&1
import json
try:
    d=json.load(open('/etc/docker/daemon.json', encoding='utf-8'))
    raise SystemExit(0 if isinstance(d, dict) and d.get('proxies') else 1)
except Exception:
    raise SystemExit(1)
PY
  then
    warn "/etc/docker/daemon.json 已存在 proxies 配置；Docker 配置文件优先级高于 systemd 环境变量，可能覆盖本管理器设置。"
  fi
  warn "应用 Docker daemon 代理会重启 Docker 服务，运行中的容器可能短暂中断。"
  if [[ "${SBX_PROXY_NO_APPLY:-0}" == "1" ]]; then
    warn "SBX_PROXY_NO_APPLY=1：跳过 Docker daemon-reload/restart。"
    return 0
  fi
  systemctl daemon-reload
  if ! systemctl restart docker; then
    warn "Docker 重启失败，撤销本次代理配置..."
    rm -f "$DOCKER_PROXY_FILE"
    systemctl daemon-reload || true
    systemctl restart docker || true
    return 1
  fi
  proxy_wait_docker || die "Docker daemon 重启后未恢复。"
  dc up -d --pull never sing-box >/dev/null 2>&1 || true
  info "Docker daemon 代理已开启。"
}

proxy_docker_off(){
  if [[ ! -f "$DOCKER_PROXY_FILE" ]]; then
    info "Docker daemon 未发现 singbox-manager 代理配置。"
    return 0
  fi
  proxy_is_rootless_docker && die "当前检测到 rootless Docker；0.4 暂不自动修改用户级 Docker systemd 服务。"
  command -v systemctl >/dev/null 2>&1 || die "Docker 一键代理目前要求 systemd。"
  rm -f "$DOCKER_PROXY_FILE"
  if [[ "${SBX_PROXY_NO_APPLY:-0}" == "1" ]]; then
    warn "SBX_PROXY_NO_APPLY=1：已删除配置，但跳过 Docker restart。"
    return 0
  fi
  systemctl daemon-reload
  systemctl restart docker
  proxy_wait_docker || die "Docker daemon 重启后未恢复。"
  dc up -d --pull never sing-box >/dev/null 2>&1 || true
  info "Docker daemon 代理已关闭。"
}

proxy_git_on(){
  local url regex
  proxy_require_running
  command -v git >/dev/null 2>&1 || die "未安装 Git。"
  url=$(proxy_url)
  mkdir -p "$(dirname "$GIT_PROXY_FILE")"
  cat > "$GIT_PROXY_FILE" <<EOF
[http]
    proxy = $url
[https]
    proxy = $url
EOF
  chmod 644 "$GIT_PROXY_FILE"
  regex='^'"$(printf '%s' "$GIT_PROXY_FILE" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"'$'
  if ! git config --system --get-all include.path 2>/dev/null | grep -Fxq "$GIT_PROXY_FILE"; then
    git config --system --add include.path "$GIT_PROXY_FILE"
  fi
  info "Git 系统代理已开启。"
}

proxy_git_off(){
  local regex
  command -v git >/dev/null 2>&1 || { warn "未安装 Git，跳过。"; return 0; }
  regex='^'"$(printf '%s' "$GIT_PROXY_FILE" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"'$'
  git config --system --unset-all include.path "$regex" >/dev/null 2>&1 || true
  rm -f "$GIT_PROXY_FILE"
  info "Git 系统代理已关闭。"
}

proxy_apt_on(){
  local url
  proxy_require_running
  command -v apt-get >/dev/null 2>&1 || die "当前系统未检测到 APT。"
  url=$(proxy_url)
  mkdir -p "$(dirname "$APT_PROXY_FILE")"
  cat > "$APT_PROXY_FILE" <<EOF
Acquire::http::Proxy "$url";
Acquire::https::Proxy "$url";
EOF
  chmod 644 "$APT_PROXY_FILE"
  info "APT 代理已开启: $APT_PROXY_FILE"
}

proxy_apt_off(){
  rm -f "$APT_PROXY_FILE"
  info "APT 代理已关闭。"
}

# 只删掉本管理器写入的块，保留用户在同一个文件里的其它配置
proxy_strip_block(){ # file begin end
  local file="$1" begin="$2" end="$3" tmp
  [[ -f "$file" ]] || return 0
  tmp=$(mktemp)
  awk -v begin="$begin" -v end="$end" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# curl 走 ~/.curlrc（对所有使用该 HOME 的 curl 调用生效，包括本管理器自己的
# sbx-install / 更新流程，以及不继承 shell 环境变量的 cron/systemd 任务）。
proxy_curl_on(){
  local url no_proxy file="$CURLRC_FILE" existed=0
  proxy_require_running
  command -v curl >/dev/null 2>&1 || die "未安装 curl。"
  url=$(proxy_url); no_proxy=$(proxy_no_proxy)
  mkdir -p "$(dirname "$file")"
  [[ -e "$file" ]] && existed=1
  touch "$file"
  proxy_strip_block "$file" "$PROXY_BLOCK_BEGIN" "$PROXY_BLOCK_END"
  cat >> "$file" <<EOF
$PROXY_BLOCK_BEGIN
proxy = $url
noproxy = $no_proxy
$PROXY_BLOCK_END
EOF
  chmod 644 "$file"
  printf '%s\n' "$file" > "$PROXY_STATE_DIR/curlrc"
  if (( existed == 0 )); then printf '1\n' > "$PROXY_STATE_DIR/curlrc-created"; fi
  info "curl 代理已开启: $file"
}

proxy_curl_off(){
  local file="" rest=""
  if [[ -f "$PROXY_STATE_DIR/curlrc" ]]; then
    file=$(cat "$PROXY_STATE_DIR/curlrc")
  else
    file="$CURLRC_FILE"
  fi
  if [[ -n "$file" && -f "$file" ]]; then
    proxy_strip_block "$file" "$PROXY_BLOCK_BEGIN" "$PROXY_BLOCK_END"
    # 这个文件是本管理器为了让 curl 走代理而创建的，且去掉块后已经空了 → 一并删掉
    if [[ -f "$PROXY_STATE_DIR/curlrc-created" ]]; then
      rest=$(tr -d '[:space:]' < "$file" || true)
      [[ -n "$rest" ]] || rm -f "$file"
    fi
  fi
  rm -f "$PROXY_STATE_DIR/curlrc" "$PROXY_STATE_DIR/curlrc-created"
  info "curl 代理已关闭。"
}

npm_global_file(){
  local f
  command -v npm >/dev/null 2>&1 || return 1
  f=$(npm config get globalconfig 2>/dev/null | tail -n1)
  [[ -n "$f" && "$f" != "undefined" && "$f" != "null" ]] || return 1
  printf '%s' "$f"
}

npm_strip_block(){
  proxy_strip_block "$1" "$NPM_BLOCK_BEGIN" "$NPM_BLOCK_END"
}

proxy_npm_on(){
  local file url
  proxy_require_running
  command -v npm >/dev/null 2>&1 || die "未安装 npm。"
  file=$(npm_global_file) || die "无法确定 npm globalconfig。"
  url=$(proxy_url)
  mkdir -p "$(dirname "$file")"
  local existed=0
  [[ -e "$file" ]] && existed=1
  touch "$file"
  npm_strip_block "$file"
  cat >> "$file" <<EOF
$NPM_BLOCK_BEGIN
proxy=$url
https-proxy=$url
$NPM_BLOCK_END
EOF
  ((existed)) || chmod 644 "$file"
  printf '%s\n' "$file" > "$PROXY_STATE_DIR/npm-globalconfig"
  info "npm 全局代理已开启: $file"
}

proxy_npm_off(){
  local file=""
  if [[ -f "$PROXY_STATE_DIR/npm-globalconfig" ]]; then
    file=$(cat "$PROXY_STATE_DIR/npm-globalconfig")
  elif command -v npm >/dev/null 2>&1; then
    file=$(npm_global_file || true)
  fi
  if [[ -n "$file" && -f "$file" ]]; then
    npm_strip_block "$file"
  fi
  rm -f "$PROXY_STATE_DIR/npm-globalconfig"
  info "npm 全局代理已关闭。"
}

proxy_state_word(){
  [[ "$1" == "1" ]] && printf 'ON' || printf 'OFF'
}
proxy_status(){
  local url docker_on=0 git_on=0 apt_on=0 npm_on=0 curl_on=0 npmfile="" curlfile=""
  url=$(proxy_url)
  [[ -f "$DOCKER_PROXY_FILE" ]] && grep -Fq "HTTP_PROXY=$url" "$DOCKER_PROXY_FILE" && docker_on=1
  [[ -f "$GIT_PROXY_FILE" ]] && grep -Fq "proxy = $url" "$GIT_PROXY_FILE" && git_on=1
  [[ -f "$APT_PROXY_FILE" ]] && grep -Fq "$url" "$APT_PROXY_FILE" && apt_on=1
  if [[ -f "$PROXY_STATE_DIR/npm-globalconfig" ]]; then npmfile=$(cat "$PROXY_STATE_DIR/npm-globalconfig"); fi
  [[ -n "$npmfile" && -f "$npmfile" ]] && grep -Fq "$NPM_BLOCK_BEGIN" "$npmfile" && npm_on=1
  curlfile="$CURLRC_FILE"
  if [[ -f "$PROXY_STATE_DIR/curlrc" ]]; then curlfile=$(cat "$PROXY_STATE_DIR/curlrc"); fi
  [[ -n "$curlfile" && -f "$curlfile" ]] && grep -Fq "$PROXY_BLOCK_BEGIN" "$curlfile" && grep -Fq "proxy = $url" "$curlfile" && curl_on=1
  printf 'sing-box proxy: %s\n' "$url"
  printf '%-8s %s\n' "Docker" "$(proxy_state_word "$docker_on")"
  printf '%-8s %s\n' "Git" "$(proxy_state_word "$git_on")"
  printf '%-8s %s\n' "APT" "$(proxy_state_word "$apt_on")"
  printf '%-8s %s\n' "npm" "$(proxy_state_word "$npm_on")"
  printf '%-8s %s\n' "curl" "$(proxy_state_word "$curl_on")$([[ -n "$curlfile" ]] && printf '  (%s)' "$curlfile")"
}

proxy_env(){
  local mode="${1:-on}" http socks no
  http=$(proxy_url); socks=$(proxy_socks_url); no=$(proxy_no_proxy)
  if [[ "$mode" == "off" || "$mode" == "unset" ]]; then
    cat <<'EOF'
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy
EOF
    return
  fi
  cat <<EOF
export HTTP_PROXY='$http'
export HTTPS_PROXY='$http'
export ALL_PROXY='$socks'
export NO_PROXY='$no'
export http_proxy='$http'
export https_proxy='$http'
export all_proxy='$socks'
export no_proxy='$no'
EOF
}

proxy_one(){
  local target="$1" action="$2"
  case "$target:$action" in
    docker:on) proxy_docker_on ;;
    docker:off) proxy_docker_off ;;
    git:on) proxy_git_on ;;
    git:off) proxy_git_off ;;
    apt:on) proxy_apt_on ;;
    apt:off) proxy_apt_off ;;
    npm:on) proxy_npm_on ;;
    npm:off) proxy_npm_off ;;
    curl:on) proxy_curl_on ;;
    curl:off) proxy_curl_off ;;
    *) die "用法: sbx proxy docker|git|apt|npm|curl on|off" ;;
  esac
}

proxy_all(){
  local action="$1" failed=0
  case "$action" in
    on)
      proxy_require_running
      command -v git >/dev/null 2>&1 && proxy_git_on || warn "Git 未安装，跳过。"
      command -v apt-get >/dev/null 2>&1 && proxy_apt_on || warn "APT 不可用，跳过。"
      command -v npm >/dev/null 2>&1 && proxy_npm_on || warn "npm 未安装，跳过。"
      command -v curl >/dev/null 2>&1 && proxy_curl_on || warn "curl 未安装，跳过。"
      proxy_docker_on || failed=1
      ;;
    off)
      proxy_docker_off || failed=1
      command -v npm >/dev/null 2>&1 && proxy_npm_off || true
      command -v curl >/dev/null 2>&1 && proxy_curl_off || true
      command -v apt-get >/dev/null 2>&1 && proxy_apt_off || true
      command -v git >/dev/null 2>&1 && proxy_git_off || true
      ;;
    *) die "用法: sbx proxy all on|off" ;;
  esac
  return "$failed"
}

proxy_menu(){
  local x target action
  while true; do
    clear
    printf '%b宿主机应用代理%b\n' "$C" "$N"
    proxy_status
    printf '\n1 Docker          2 Git\n3 APT             4 npm\n5 全部开启        6 全部关闭\n7 Shell 环境变量  8 测试 sing-box\n9 curl (~/.curlrc)\n\n0 返回\n'
    read -r -p '请选择: ' x || return
    case "$x" in
      1|2|3|4|9)
        case "$x" in 1) target=docker;;2) target=git;;3) target=apt;;4) target=npm;;9) target=curl;; esac
        read -r -p "$target: 1 开启 / 2 关闭: " action
        case "$action" in 1) proxy_one "$target" on || true;;2) proxy_one "$target" off || true;;*) warn "无效选项";; esac
        ;;
      5) proxy_all on || true ;;
      6) proxy_all off || true ;;
      7)
        printf '\n在当前 Shell 临时启用：\n  eval "$(sbx proxy env)"\n\n取消：\n  eval "$(sbx proxy env off)"\n\n'
        proxy_env
        ;;
      8) test_current || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

proxy_cmd(){
  local target="${1:-menu}" action="${2:-}"
  case "$target" in
    menu) proxy_menu ;;
    status) proxy_status ;;
    env) proxy_env "${action:-on}" ;;
    all) proxy_all "$action" ;;
    docker|git|apt|npm|curl) proxy_one "$target" "$action" ;;
    help|-h|--help)
      cat <<'EOF'
sbx proxy                         交互式应用代理菜单
sbx proxy status                  查看 Docker/Git/APT/npm/curl 接入状态
sbx proxy docker on|off           Docker daemon 拉取镜像走 sing-box
sbx proxy git on|off              Git 系统 HTTP/HTTPS 代理
sbx proxy apt on|off              APT 系统代理
sbx proxy npm on|off              npm 全局代理
sbx proxy curl on|off             curl 走 ~/.curlrc（对 cron/systemd 等不继承环境变量的 curl 也生效）
sbx proxy all on|off              一键开启/关闭全部可用集成
sbx proxy env [off]\nsbx image status|bootstrap|pull|load               输出当前 Shell 的 export/unset 命令
EOF
      ;;
    *) die "未知 proxy 命令: $target" ;;
  esac
}
