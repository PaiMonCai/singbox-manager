#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${SBX_REPO:-PaiMonCai/singbox-manager}"
BRANCH="${SBX_INSTALL_BRANCH:-main}"
INSTALL_DIR="${SBX_INSTALL_DIR:-/opt/singbox-manager}"
BIN_LINK="${SBX_BIN_LINK:-/usr/local/bin/sbx}"
DEFAULT_VERSION="${SBX_DEFAULT_VERSION:-v1.14.2}"
NONINTERACTIVE="${SBX_NONINTERACTIVE:-0}"

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
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || true)"
  fi

  if [[ -n "$script_dir" && -f "$script_dir/compose.yml" && -f "$script_dir/bin/sbx" && -f "$script_dir/lib/sbx_nodes.py" && -f "$script_dir/lib/sbx_v3.sh" ]]; then
    SOURCE_DIR="$script_dir"
    return
  fi

  TMP_DIR="$(mktemp -d)"
  local archive="$TMP_DIR/source.tar.gz"
  info "正在下载 singbox-manager ($BRANCH)..."
  curl -fL --retry 3 --connect-timeout 10 \
    "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" \
    -o "$archive"
  tar -xzf "$archive" -C "$TMP_DIR"
  for candidate in "$TMP_DIR"/*/; do
    if [[ -f "${candidate}compose.yml" && -f "${candidate}bin/sbx" && -f "${candidate}lib/sbx_nodes.py" && -f "${candidate}lib/sbx_v3.sh" ]]; then
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
  local version="$1" bind="$2" port="$3"
  cat > "$INSTALL_DIR/.env" <<EOF
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
ensure_docker
get_source

UPGRADE=0
[[ -f "$INSTALL_DIR/.env" ]] && UPGRADE=1

old_version="$DEFAULT_VERSION"
old_bind="127.0.0.1"
old_port="7890"
if (( UPGRADE )); then
  old_version="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_VERSION "$DEFAULT_VERSION")"
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
install -m 0644 "$SOURCE_DIR/config/config.example.json" "$INSTALL_DIR/config/config.example.json"
install -m 0755 "$SOURCE_DIR/bin/sbx" "$INSTALL_DIR/bin/sbx"
install -m 0755 "$SOURCE_DIR/lib/sbx_nodes.py" "$INSTALL_DIR/lib/sbx_nodes.py"
install -m 0755 "$SOURCE_DIR/lib/sbx_v3.sh" "$INSTALL_DIR/lib/sbx_v3.sh"
write_env "$version" "$bind" "$port"

chmod 700 "$INSTALL_DIR/config" "$INSTALL_DIR/nodes" "$INSTALL_DIR/data" "$INSTALL_DIR/backup"
ln -sfn "$INSTALL_DIR/bin/sbx" "$BIN_LINK"

export SBX_HOME="$INSTALL_DIR"
if [[ ! -f "$INSTALL_DIR/nodes/nodes.json" ]]; then
  python3 "$INSTALL_DIR/lib/sbx_nodes.py" init
  chmod 600 "$INSTALL_DIR/nodes/nodes.json" "$INSTALL_DIR/config/config.json"
else
  python3 "$INSTALL_DIR/lib/sbx_nodes.py" validate >/dev/null || die "现有节点库校验失败。"
  python3 "$INSTALL_DIR/lib/sbx_nodes.py" render >/dev/null
fi

if confirm "现在拉取 sing-box $version 镜像？" yes; then
  docker compose --project-directory "$INSTALL_DIR" --env-file "$INSTALL_DIR/.env" -f "$INSTALL_DIR/compose.yml" pull sing-box
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
if confirm "是否立即启动 sing-box？" "$start_default"; then
  "$BIN_LINK" start || warn "启动失败，请运行 sbx check 和 sbx logs 查看详情。"
fi

printf '\n'
printf '\033[32m安装完成。\033[0m\n'
printf '  管理菜单: sbx\n'
printf '  节点管理: sbx node\n'
printf '  添加节点: sbx node add\n'
printf '  测试节点: sbx node test\n'
printf '  当前代理: http://%s:%s 或 socks5://%s:%s\n' "$bind" "$port" "$bind" "$port"
printf '\n'
