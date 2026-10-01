#!/usr/bin/env bash
# Bootstrap image acquisition for singbox-manager.
# Used by both install.sh and the runtime image guard.

BOOTSTRAP_DOCKER_DROPIN_DIR="${SBX_BOOTSTRAP_DOCKER_DROPIN_DIR:-/etc/systemd/system/docker.service.d}"
BOOTSTRAP_DOCKER_PROXY_FILE="${SBX_BOOTSTRAP_DOCKER_PROXY_FILE:-$BOOTSTRAP_DOCKER_DROPIN_DIR/98-singbox-manager-bootstrap-proxy.conf}"
BOOTSTRAP_PULL_TIMEOUT="${SBX_BOOTSTRAP_PULL_TIMEOUT:-45}"

bootstrap_ask() {
  local text="$1" default="${2:-}" answer
  if declare -F ask >/dev/null 2>&1; then
    ask "$text" "$default"
    return
  fi
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    printf '%s\n' "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$text [$default]: " answer || true
    printf '%s\n' "${answer:-$default}"
  else
    read -r -p "$text: " answer || true
    printf '%s\n' "$answer"
  fi
}

bootstrap_image_repo() {
  local env_file="${1:-}" repo="ghcr.io/sagernet/sing-box" v
  if [[ -n "$env_file" && -f "$env_file" ]]; then
    v="$(grep -E '^SING_BOX_IMAGE=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    [[ -n "$v" ]] && repo="$v"
  fi
  printf '%s\n' "$repo"
}

bootstrap_image_version() {
  local env_file="${1:-}" fallback="${2:-v1.14.2}" v
  v="$(grep -E '^SING_BOX_VERSION=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  printf '%s\n' "${v:-$fallback}"
}

bootstrap_target_image() {
  local version="$1" env_file="$2"
  printf '%s:%s\n' "$(bootstrap_image_repo "$env_file")" "$version"
}

bootstrap_image_present() {
  docker image inspect "$1" >/dev/null 2>&1
}

bootstrap_pull() {
  local image="$1"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${BOOTSTRAP_PULL_TIMEOUT}s" docker pull "$image"
  else
    docker pull "$image"
  fi
}

bootstrap_cleanup_temp_proxy() {
  [[ -f "$BOOTSTRAP_DOCKER_PROXY_FILE" ]] || return 0
  rm -f "$BOOTSTRAP_DOCKER_PROXY_FILE"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl restart docker || true
  fi
}

bootstrap_temp_proxy_pull() {
  local proxy="$1" image="$2"
  command -v systemctl >/dev/null 2>&1 || { warn "临时 Docker daemon 代理需要 systemd。"; return 1; }
  docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -qi rootless && {
    warn "检测到 rootless Docker，暂不自动修改用户级 systemd。"
    return 1
  }

  mkdir -p "$BOOTSTRAP_DOCKER_DROPIN_DIR"
  cat > "$BOOTSTRAP_DOCKER_PROXY_FILE" <<EOF
[Service]
Environment="HTTP_PROXY=$proxy"
Environment="HTTPS_PROXY=$proxy"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
EOF
  chmod 600 "$BOOTSTRAP_DOCKER_PROXY_FILE"

  # 从这里起，任何退出路径（Ctrl-C / errexit / systemctl 失败）都必须撤掉 drop-in，
  # 否则宿主机 Docker daemon 会永久指向一个临时或已失效的代理。
  # 需保存并还原上层已有的 EXIT trap（install.sh 用它清理临时目录，不能被顶掉）。
  local prev_trap rc=0
  prev_trap="$(trap -p EXIT || true)"
  trap 'bootstrap_cleanup_temp_proxy' EXIT INT TERM HUP

  info "正在临时为 Docker daemon 配置启动代理..."
  systemctl daemon-reload || true
  if systemctl restart docker; then
    sleep 1
    bootstrap_pull "$image" || rc=$?
  else
    warn "Docker 重启失败，正在撤销临时代理配置。"
    rc=1
  fi

  bootstrap_cleanup_temp_proxy
  trap - EXIT INT TERM HUP
  [[ -n "$prev_trap" ]] && eval "$prev_trap"
  return "$rc"
}

bootstrap_custom_repo_pull() {
  local repo="$1" version="$2" target="$3" source
  repo="${repo%/}"
  source="$repo:$version"
  warn "你选择了自定义镜像仓库。请仅使用你信任的仓库。"
  info "尝试拉取: $source"
  bootstrap_pull "$source" || return 1
  docker tag "$source" "$target"
  info "已将镜像标记为运行目标: $target"
}

bootstrap_load_tar() {
  local file="$1" target="$2" source=""
  [[ -f "$file" ]] || { warn "镜像包不存在: $file"; return 1; }
  info "导入本地 Docker 镜像包: $file"
  docker load -i "$file"

  bootstrap_image_present "$target" && return 0

  source="$(bootstrap_ask '导入后的镜像名（含版本）' '')"
  [[ -n "$source" ]] || { warn "未提供导入后的镜像名。"; return 1; }
  bootstrap_image_present "$source" || { warn "未找到镜像: $source"; return 1; }
  docker tag "$source" "$target"
}

bootstrap_menu() {
  # 颜色变量来自 bin/sbx；install.sh 直接 source 本文件时需要兜底。
  # 兜底色与 bin/sbx 的主题一致：明绿主色 + 浅灰次要文字（黑底可读）
  local Y="${Y:-\033[93m}" C="${C:-\033[92m}" D="${D:-\033[37m}" N="${N:-\033[0m}"
  local version="$1" env_file="$2" target choice proxy mirror tarfile
  target="$(bootstrap_target_image "$version" "$env_file")"

  bootstrap_image_present "$target" && {
    info "本地已存在 sing-box 镜像: $target"
    return 0
  }

  [[ "${NONINTERACTIVE:-0}" == "1" ]] && return 1

  while true; do
    printf '\n%b本地缺少 sing-box 镜像%b\n  %b%s%b\n\n' "$Y" "$N" "$D" "$target" "$N"
    printf '%bBootstrap 镜像获取方式%b\n' "$C" "$N"
    cat <<EOF
  1  使用临时 HTTP/HTTPS 代理拉取目标镜像
  2  使用自定义 / 可信镜像仓库拉取并重新 tag
  3  docker load 本地 .tar 镜像包
  4  明确尝试当前镜像源（最长约 ${BOOTSTRAP_PULL_TIMEOUT}s）

  0  取消
EOF
    read -r -p '请选择: ' choice || return 1
    case "$choice" in
      1)
        proxy="$(bootstrap_ask '临时 HTTP 代理地址（例如 http://1.2.3.4:7890）' '')"
        [[ -n "$proxy" ]] || { warn "代理地址不能为空。"; continue; }
        bootstrap_temp_proxy_pull "$proxy" "$target" && return 0
        warn "通过临时代理拉取失败。"
        ;;
      2)
        mirror="$(bootstrap_ask '镜像仓库（不含版本）' '')"
        [[ -n "$mirror" ]] || { warn "镜像仓库不能为空。"; continue; }
        bootstrap_custom_repo_pull "$mirror" "$version" "$target" && return 0
        warn "自定义镜像仓库拉取失败。"
        ;;
      3)
        tarfile="$(bootstrap_ask 'Docker 镜像 tar 文件路径' '')"
        bootstrap_load_tar "$tarfile" "$target" && return 0
        ;;
      4)
        bootstrap_pull "$target" && return 0
        warn "当前镜像源拉取失败。"
        ;;
      0) return 1 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

bootstrap_ensure_image() {
  local version="$1" env_file="$2" mode="${3:-install}" target
  target="$(bootstrap_target_image "$version" "$env_file")"

  if bootstrap_image_present "$target"; then
    info "本地已存在 sing-box 镜像: $target"
    return 0
  fi

  if [[ "$mode" == "runtime" ]]; then
    warn "本地缺少 sing-box 镜像；不会隐式执行 docker pull。"
    bootstrap_menu "$version" "$env_file"
    return
  fi

  info "首次安装先短时尝试当前镜像源（最长约 ${BOOTSTRAP_PULL_TIMEOUT}s）..."
  bootstrap_pull "$target" && return 0
  warn "直接拉取失败，进入 Bootstrap 启动菜单。"
  bootstrap_menu "$version" "$env_file"
}
