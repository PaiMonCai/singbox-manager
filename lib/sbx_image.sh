#!/usr/bin/env bash
# Runtime image guard for singbox-manager.
# Prevents Docker/Compose from implicitly pulling sing-box during check/start/import flows.

VERSION="0.5.3"

image_repo() {
  envval SING_BOX_IMAGE ghcr.io/sagernet/sing-box
}

image_version() {
  envval SING_BOX_VERSION v1.14.2
}

image_ref() {
  printf '%s:%s\n' "$(image_repo)" "$(image_version)"
}

image_present() {
  docker image inspect "$(image_ref)" >/dev/null 2>&1
}

image_require() {
  local image
  image="$(image_ref)"
  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi

  warn "本地不存在 sing-box 镜像: $image"
  warn "本次操作不会让 Docker Compose 隐式拉取镜像。"

  bootstrap_ensure_image "$(image_version)" "$ENV" runtime || {
    warn "镜像尚未准备好，操作已取消。"
    return 1
  }

  docker image inspect "$image" >/dev/null 2>&1 || {
    warn "Bootstrap 结束后仍未找到目标镜像: $image"
    return 1
  }
}

check() {
  local image
  image_require || return 1
  image="$(image_ref)"
  info "检查 sing-box 配置..."
  docker run --rm --pull=never     -v "$HOME_DIR/config:/etc/sing-box:ro"     -v "$HOME_DIR/data:/var/lib/sing-box"     "$image"     check -c /etc/sing-box/config.json -D /var/lib/sing-box
}

start() {
  image_require || die "sing-box 镜像未准备好。"
  check || die "配置检查失败。"
  dc up -d --pull never sing-box
  status
}

restart() {
  image_require || die "sing-box 镜像未准备好。"
  check || die "配置检查失败，未替换运行容器。"
  dc up -d --force-recreate --pull never sing-box
  status
}

test_node() {
  local ref="${1:-}" t c image port rc=0
  image_require || return 1
  image="$(image_ref)"
  t="$(mktemp -d)"
  c="sbx-node-test-$$"

  python3 "$HELPER" test-config ${ref:+"$ref"} --output "$t/config.json" --port 7891 || {
    rm -rf "$t"
    return 1
  }

  docker run --rm --pull=never     -v "$t:/etc/sing-box:ro"     "$image"     check -c /etc/sing-box/config.json -D /tmp/sing-box || {
      rm -rf "$t"
      return 1
    }

  docker run -d --rm --pull=never     --name "$c"     -p '127.0.0.1::7891/tcp'     -v "$t:/etc/sing-box:ro"     "$image"     -D /tmp/sing-box -c /etc/sing-box/config.json run >/dev/null || {
      rm -rf "$t"
      return 1
    }

  sleep 1
  port="$(docker port "$c" 7891/tcp 2>/dev/null | head -n1 | awk -F: '{print $NF}')"
  [[ -n "$port" ]] && http_test "http://127.0.0.1:$port" || rc=1

  if ((rc)); then
    warn "节点测试失败，临时日志："
    docker logs "$c" 2>&1 | tail -n40 || true
  else
    info "节点完整代理测试通过。"
  fi

  docker rm -f "$c" >/dev/null 2>&1 || true
  rm -rf "$t"
  return "$rc"
}

image_status() {
  local image
  image="$(image_ref)"
  printf '目标镜像: %s\n' "$image"
  if docker image inspect "$image" >/dev/null 2>&1; then
    local id created
    id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
    created="$(docker image inspect --format '{{.Created}}' "$image" 2>/dev/null || true)"
    printf '状态:     READY\n'
    [[ -n "$id" ]] && printf 'Image ID: %s\n' "$id"
    [[ -n "$created" ]] && printf 'Created:  %s\n' "$created"
  else
    printf '状态:     MISSING\n'
    return 1
  fi
}

image_bootstrap() {
  bootstrap_ensure_image "$(image_version)" "$ENV" runtime
}

image_pull() {
  local image
  image="$(image_ref)"
  info "明确拉取镜像: $image"
  if bootstrap_pull "$image"; then
    info "镜像拉取完成。"
    return 0
  fi
  warn "直接拉取失败，可继续选择其他 Bootstrap 方式。"
  bootstrap_menu "$(image_version)" "$ENV"
}

image_load() {
  local file="${1:-}"
  [[ -n "$file" ]] || read -r -p 'Docker 镜像 tar 文件路径: ' file
  [[ -n "$file" ]] || die "镜像包路径不能为空。"
  bootstrap_load_tar "$file" "$(image_ref)"
}

image_cmd() {
  local op="${1:-status}"
  shift || true
  case "$op" in
    status) image_status ;;
    bootstrap|prepare) image_bootstrap ;;
    pull) image_pull ;;
    load) image_load "${1:-}" ;;
    ref)
      image_ref
      ;;
    help|-h|--help)
      cat <<'EOF'
sbx image status              查看当前目标镜像是否已存在
sbx image bootstrap           缺镜像时进入 Bootstrap 菜单（不隐式拉取）
sbx image pull                明确尝试拉取当前目标镜像
sbx image load [file.tar]     导入本地 Docker 镜像包
sbx image ref                 输出当前目标镜像引用
EOF
      ;;
    *) die "未知 image 命令: $op" ;;
  esac
}

upgrade() {
  local new="${1:-}" old old_image
  [[ -n "$new" ]] || die "用法: sbx upgrade v1.14.2"
  [[ "$new" == v* ]] || new="v$new"
  [[ "$new" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "版本格式无效"

  old="$(image_version)"
  old_image="$(image_ref)"
  backup
  setenv SING_BOX_VERSION "$new"

  if ! bootstrap_ensure_image "$new" "$ENV" runtime; then
    setenv SING_BOX_VERSION "$old"
    die "目标版本镜像未准备好，已恢复版本设置。"
  fi

  if ! check || ! dc up -d --force-recreate --pull never sing-box; then
    setenv SING_BOX_VERSION "$old"
    if docker image inspect "$old_image" >/dev/null 2>&1; then
      dc up -d --force-recreate --pull never sing-box >/dev/null 2>&1 || true
    fi
    die "升级失败，已尝试回滚到 $old"
  fi

  version
}

pull() {
  backup
  image_pull
  check
  dc up -d --force-recreate --pull never sing-box
}

version() {
  printf 'singbox-manager: %s\npinned sing-box: %s\nimage: %s\nstrategy: %s\nroute: %s\n'     "$VERSION" "$(image_version)" "$(image_ref)"     "$(python3 "$HELPER" strategy)" "$(python3 "$HELPER" route-mode)"
}
