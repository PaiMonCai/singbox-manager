#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${SBX_REPO:-PaiMonCai/singbox-manager}"
BRANCH="${SBX_INSTALL_BRANCH:-main}"
INSTALL_DIR="${SBX_INSTALL_DIR:-/opt/singbox-manager}"
BIN_LINK="${SBX_BIN_LINK:-/usr/local/bin/sbx}"
DEFAULT_VERSION="${SBX_DEFAULT_VERSION:-v1.14.2}"
NONINTERACTIVE="${SBX_NONINTERACTIVE:-0}"
MANAGER_ONLY="${SBX_MANAGER_ONLY:-0}"
INSTALLER_LINK="${SBX_INSTALLER_LINK:-/usr/local/bin/sbx-install}"
[[ "$MANAGER_ONLY" == "1" ]] && NONINTERACTIVE=1
SOURCE_BASE_URL="${SBX_SOURCE_BASE_URL:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
ARCHIVE_URL="${SBX_ARCHIVE_URL:-https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz}"

TMP_DIR=""
SOURCE_DIR=""

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ask() {
  local text="$1" default="${2:-}" answer
  if [[ "$NONINTERACTIVE" == "1" ]]; then
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

confirm() {
  local text="$1" default="${2:-yes}" answer mark
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$default" == "yes" ]]
    return
  fi
  [[ "$default" == "yes" ]] && mark="Y/n" || mark="y/N"
  while true; do
    read -r -p "$text [$mark] " answer || true
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes|1|true|是) return 0 ;;
      n|no|0|false|否) return 1 ;;
      *) printf '请输入 y 或 n。\n' ;;
    esac
  done
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

pkg_install() {
  local packages=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${packages[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${packages[@]}"
  else
    return 1
  fi
}

ensure_basic_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  if ((${#missing[@]})); then
    info "安装基础依赖: ${missing[*]}"
    pkg_install "${missing[@]}" || die "无法自动安装依赖: ${missing[*]}"
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi

  warn "未检测到 Docker Engine + Compose v2。"
  if ! confirm "是否使用 Docker 官方安装脚本安装 Docker？" yes; then
    die "singbox-manager 需要 Docker Engine 和 Docker Compose v2。"
  fi
  command -v curl >/dev/null 2>&1 || die "安装 Docker 需要 curl。"

  local installer="/tmp/get-docker-$$.sh"
  curl -fsSL --retry 3 https://get.docker.com -o "$installer"
  sh "$installer"
  rm -f "$installer"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 || die "Docker 已安装，但未检测到 Compose v2。"
}

get_source() {
  local script_dir="" raw_dir="" archive="" candidate="" path=""
  local required=(
    "compose.yml"
    ".env.example"
    "config/config.example.json"
    "bin/sbx"
    "lib/sbx_nodes.py"
    "lib/sbx_v3.sh"
    "lib/sbx_proxy.sh"
    "lib/sbx_bootstrap.sh"
    "lib/sbx_image.sh"
    "lib/sbx_inbound.sh"
    "lib/sbx_update.sh"
    "bin/sbx-install"
    "VERSION"
  )

  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || true)"
  fi

  if [[ -n "$script_dir" ]]; then
    local complete=1
    for path in "${required[@]}"; do
      [[ -f "$script_dir/$path" ]] || { complete=0; break; }
    done
    if (( complete )); then
      SOURCE_DIR="$script_dir"
      return
    fi
  fi

  TMP_DIR="$(mktemp -d)"
  raw_dir="$TMP_DIR/raw"
  mkdir -p "$raw_dir/config" "$raw_dir/bin" "$raw_dir/lib"

  info "正在通过 raw 源下载 singbox-manager ($BRANCH)..."
  local raw_ok=1
  for path in "${required[@]}"; do
    mkdir -p "$raw_dir/$(dirname "$path")"
    if ! curl -fL --retry 2 --connect-timeout 8 --max-time 30 \
      "${SOURCE_BASE_URL%/}/$path" \
      -o "$raw_dir/$path"; then
      warn "raw 源下载失败: $path"
      raw_ok=0
      break
    fi
  done

  if (( raw_ok )); then
    SOURCE_DIR="$raw_dir"
    info "源码已通过 raw 源准备完成。"
    return
  fi

  warn "raw 源不可用，回退 GitHub archive..."
  archive="$TMP_DIR/source.tar.gz"
  if ! curl -fL --retry 2 --connect-timeout 10 --max-time 60 "$ARCHIVE_URL" -o "$archive"; then
    die "无法下载 singbox-manager 源码。可设置 SBX_SOURCE_BASE_URL 指向你自己的 raw/CDN 镜像。"
  fi

  tar -xzf "$archive" -C "$TMP_DIR"
  for candidate in "$TMP_DIR"/*/; do
    [[ "$candidate" == "$raw_dir/" ]] && continue
    local complete=1
    for path in "${required[@]}"; do
      [[ -f "${candidate}$path" ]] || { complete=0; break; }
    done
    if (( complete )); then
      SOURCE_DIR="${candidate%/}"
      break
    fi
  done

  [[ -n "$SOURCE_DIR" ]] || die "无法识别下载的源码目录。"
}

read_env_value() {
  local file="$1" key="$2" fallback="$3" value
  value="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  printf '%s\n' "${value:-$fallback}"
}

write_env() {
  local version="$1" bind="$2" port="$3" image="${4:-ghcr.io/sagernet/sing-box}"
  cat > "$INSTALL_DIR/.env" <<EOF
SING_BOX_IMAGE=$image
SING_BOX_VERSION=$version
SING_BOX_CONTAINER_NAME=sing-box
SING_BOX_BIND_ADDR=$bind
SING_BOX_MIXED_PORT=$port
EOF
  chmod 600 "$INSTALL_DIR/.env"
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "请使用 root 运行，例如: sudo bash install.sh"
fi
[[ "$(uname -s)" == "Linux" ]] || die "当前安装脚本只支持 Linux。"

printf '\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '      singbox-manager 安装器\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

ensure_basic_dependencies
if [[ "$MANAGER_ONLY" != "1" ]]; then
  ensure_docker
fi
get_source

UPGRADE=0
[[ -f "$INSTALL_DIR/.env" ]] && UPGRADE=1
if [[ "$MANAGER_ONLY" == "1" && "$UPGRADE" != "1" ]]; then
  die "manager-only 更新要求已有安装。"
fi

old_version="$DEFAULT_VERSION"
old_image="ghcr.io/sagernet/sing-box"
old_bind="127.0.0.1"
old_port="7890"
if (( UPGRADE )); then
  old_version="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_VERSION "$DEFAULT_VERSION")"
  old_image="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_IMAGE "ghcr.io/sagernet/sing-box")"
  old_bind="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_BIND_ADDR "127.0.0.1")"
  old_port="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_MIXED_PORT "7890")"
  info "检测到已有安装，将执行就地升级并保留节点数据。"
fi

version="$(ask 'sing-box 版本' "$old_version")"
[[ "$version" == v* ]] || version="v$version"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "版本格式无效: $version"

bind="$(ask '本地代理监听地址' "$old_bind")"
while true; do
  port="$(ask '本地 mixed HTTP/SOCKS5 端口' "$old_port")"
  validate_port "$port" && break
  warn "端口必须是 1-65535 的整数。"
done

info "安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/config" "$INSTALL_DIR/nodes" "$INSTALL_DIR/data" "$INSTALL_DIR/backup"

install -m 0644 "$SOURCE_DIR/compose.yml" "$INSTALL_DIR/compose.yml"
install -m 0644 "$SOURCE_DIR/.env.example" "$INSTALL_DIR/.env.example"
install -m 0644 "$SOURCE_DIR/VERSION" "$INSTALL_DIR/VERSION"
install -m 0644 "$SOURCE_DIR/config/config.example.json" "$INSTALL_DIR/config/config.example.json"
install -m 0755 "$SOURCE_DIR/bin/sbx" "$INSTALL_DIR/bin/sbx"
install -m 0755 "$SOURCE_DIR/lib/sbx_nodes.py" "$INSTALL_DIR/lib/sbx_nodes.py"
install -m 0755 "$SOURCE_DIR/lib/sbx_v3.sh" "$INSTALL_DIR/lib/sbx_v3.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_proxy.sh" "$INSTALL_DIR/lib/sbx_proxy.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_bootstrap.sh" "$INSTALL_DIR/lib/sbx_bootstrap.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_image.sh" "$INSTALL_DIR/lib/sbx_image.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_inbound.sh" "$INSTALL_DIR/lib/sbx_inbound.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_update.sh" "$INSTALL_DIR/lib/sbx_update.sh"
install -m 0755 "$SOURCE_DIR/bin/sbx-install" "$INSTALLER_LINK"

chmod 700 "$INSTALL_DIR/config" "$INSTALL_DIR/nodes" "$INSTALL_DIR/data" "$INSTALL_DIR/backup"
ln -sfn "$INSTALL_DIR/bin/sbx" "$BIN_LINK"
chmod 0755 "$INSTALLER_LINK"

if [[ "$MANAGER_ONLY" == "1" ]]; then
  manager_version="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION" 2>/dev/null || true)"
  printf '\n'
  printf '\033[32m管理器更新完成：%s\033[0m\n' "${manager_version:-unknown}"
  printf '  未修改 .env / nodes.json / config.json，也未重启 sing-box。\n'
  printf '  快速更新: sbx self-update\n'
  printf '  完整安装器: sbx-install\n'
  exit 0
fi

write_env "$version" "$bind" "$port" "$old_image"

export SBX_HOME="$INSTALL_DIR"
if [[ ! -f "$INSTALL_DIR/nodes/nodes.json" ]]; then
  python3 "$INSTALL_DIR/lib/sbx_nodes.py" init
  chmod 600 "$INSTALL_DIR/nodes/nodes.json" "$INSTALL_DIR/config/config.json"
else
  python3 "$INSTALL_DIR/lib/sbx_nodes.py" validate >/dev/null || die "现有节点库校验失败。"
  python3 "$INSTALL_DIR/lib/sbx_nodes.py" render >/dev/null
fi

source "$INSTALL_DIR/lib/sbx_bootstrap.sh"
image_ready=0
if confirm "现在准备 sing-box $version 镜像？" yes; then
  if bootstrap_ensure_image "$version" "$INSTALL_DIR/.env"; then
    image_ready=1
  else
    warn "sing-box 镜像尚未准备好。你可以稍后重新运行安装器。"
  fi
elif docker image inspect "$old_image:$version" >/dev/null 2>&1; then
  image_ready=1
fi

node_count="$(python3 - <<PY
import json
from pathlib import Path
p=Path('$INSTALL_DIR/nodes/nodes.json')
try:
    print(len(json.loads(p.read_text(encoding='utf-8')).get('nodes', [])))
except Exception:
    print(0)
PY
)"

if [[ "$node_count" == "0" ]] && confirm "当前没有代理节点，是否现在交互式添加第一个节点？" yes; then
  "$BIN_LINK" node add || warn "节点添加未完成，你之后可以运行: sbx node add"
  node_count="$(python3 - <<PY
import json
from pathlib import Path
p=Path('$INSTALL_DIR/nodes/nodes.json')
try: print(len(json.loads(p.read_text(encoding='utf-8')).get('nodes', [])))
except Exception: print(0)
PY
)"
fi

start_default="no"
[[ "$node_count" != "0" ]] && start_default="yes"
if (( image_ready )) && confirm "是否立即启动 sing-box？" "$start_default"; then
  "$BIN_LINK" start || warn "启动失败，请运行 sbx check 和 sbx logs 查看详情。"
fi

printf '\n'
printf '\033[32m安装完成。\033[0m\n'
printf '  管理菜单: sbx\n'
printf '  节点管理: sbx node\n'
printf '  添加节点: sbx node add\n'
printf '  测试节点: sbx node test\n'
printf '  快速更新: sbx self-update\n'
printf '  最新安装器: sbx-install\n'
printf '  当前代理: http://%s:%s 或 socks5://%s:%s\n' "$bind" "$port" "$bind" "$port"
printf '\n'
