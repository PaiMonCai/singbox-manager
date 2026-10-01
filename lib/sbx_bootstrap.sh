#!/usr/bin/env bash
# Bootstrap image acquisition for singbox-manager.
# Sourced by install.sh after helper functions (info/warn/die/ask/confirm) exist.

BOOTSTRAP_DOCKER_DROPIN_DIR="${SBX_BOOTSTRAP_DOCKER_DROPIN_DIR:-/etc/systemd/system/docker.service.d}"
BOOTSTRAP_DOCKER_PROXY_FILE="${SBX_BOOTSTRAP_DOCKER_PROXY_FILE:-$BOOTSTRAP_DOCKER_DROPIN_DIR/98-singbox-manager-bootstrap-proxy.conf}"
BOOTSTRAP_PULL_TIMEOUT="${SBX_BOOTSTRAP_PULL_TIMEOUT:-45}"

bootstrap_image_repo() {
  local env_file="${1:-}"
  local repo="ghcr.io/sagernet/sing-box"
  if [[ -n "$env_file" && -f "$env_file" ]]; then
    local v
    v="$(grep -E '^SING_BOX_IMAGE=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    [[ -n "$v" ]] && repo="$v"
  fi
  printf '%s\n' "$repo"
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
    warn "检测到 rootless Docker，安装器不会修改用户级 systemd。"
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

  info "正在临时为 Docker daemon 配置启动代理..."
  systemctl daemon-reload
  systemctl restart docker
  sleep 1

  local rc=0
  bootstrap_pull "$image" || rc=$?
  bootstrap_cleanup_temp_proxy
  return "$rc"
}

bootstrap_custom_repo_pull() {
  local repo="$1" version="$2" target="$3"
  repo="${repo%/}"
  local source="$repo:$version"
  warn "你选择了自定义镜像仓库。请仅使用你信任的仓库。"
  info "尝试拉取: $source"
  bootstrap_pull "$source" || return 1
  docker tag "$source" "$target"
  info "已将镜像标记为官方目标名: $target"
}

bootstrap_load_tar() {
  local file="$1" target="$2" source=""
  [[ -f "$file" ]] || { warn "镜像包不存在: $file"; return 1; }

  info "导入本地 Docker 镜像包: $file"
  docker load -i "$file"

  if docker image inspect "$target" >/dev/null 2>&1; then
    return 0
  fi

  source="$(ask '导入后的镜像名（例如 ghcr.io/sagernet/sing-box:v1.14.2）' '')"
  [[ -n "$source" ]] || { warn "未提供导入后的镜像名。"; return 1; }
  docker image inspect "$source" >/dev/null 2>&1 || { warn "未找到镜像: $source"; return 1; }
  docker tag "$source" "$target"
}

bootstrap_ensure_image() {
  local version="$1" env_file="$2"
  local repo target choice proxy mirror tarfile

  repo="$(bootstrap_image_repo "$env_file")"
  target="$repo:$version"

  if docker image inspect "$target" >/dev/null 2>&1; then
    info "本地已存在 sing-box 镜像: $target"
    return 0
  fi

  info "首次启动需要 sing-box 镜像。先尝试官方/当前配置源（最长约 ${BOOTSTRAP_PULL_TIMEOUT}s）..."
  if bootstrap_pull "$target"; then
    return 0
  fi

  warn "直接拉取失败，进入 Bootstrap 启动菜单。"

  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    return 1
  fi

  while true; do
    cat <<'EOF'

Bootstrap 镜像获取方式：
  1. 使用临时 HTTP/HTTPS 代理拉取官方镜像
  2. 使用自定义/可信镜像仓库拉取并重新 tag
  3. docker load 本地 .tar 镜像包
  4. 再次尝试官方源
  0. 暂时跳过
EOF
    read -r -p '请选择: ' choice || return 1
    case "$choice" in
      1)
        proxy="$(ask '临时 HTTP 代理地址（例如 http://1.2.3.4:7890）' '')"
        [[ -n "$proxy" ]] || { warn "代理地址不能为空。"; continue; }
        if bootstrap_temp_proxy_pull "$proxy" "$target"; then return 0; fi
        warn "通过临时代理拉取失败。"
        ;;
      2)
        mirror="$(ask '镜像仓库（不含版本，例如 mirror.example.com/sagernet/sing-box）' '')"
        [[ -n "$mirror" ]] || { warn "镜像仓库不能为空。"; continue; }
        if bootstrap_custom_repo_pull "$mirror" "$version" "$target"; then return 0; fi
        warn "自定义镜像仓库拉取失败。"
        ;;
      3)
        tarfile="$(ask 'Docker 镜像 tar 文件路径' '')"
        if bootstrap_load_tar "$tarfile" "$target"; then return 0; fi
        ;;
      4)
        bootstrap_pull "$target" && return 0 || warn "官方源仍然失败。"
        ;;
      0)
        return 1
        ;;
      *)
        warn "无效选项。"
        ;;
    esac
  done
}
