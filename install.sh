#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${SBX_REPO:-PaiMonCai/singbox-manager}"
BRANCH="${SBX_INSTALL_BRANCH:-main}"
INSTALL_DIR="${SBX_INSTALL_DIR:-/opt/singbox-manager}"
BIN_LINK="${SBX_BIN_LINK:-/usr/local/bin/sbx}"

TMP_DIR=""
SOURCE_DIR=""

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "请使用 root 运行，或执行: sudo bash install.sh"
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  die "当前安装脚本只支持 Linux。"
fi

command -v docker >/dev/null 2>&1 || die "未检测到 Docker Engine，请先安装 Docker。"
docker compose version >/dev/null 2>&1 || die "未检测到 Docker Compose v2，请先安装 docker compose 插件。"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || true)"

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/compose.yml" && -f "$SCRIPT_DIR/bin/sbx" && -f "$SCRIPT_DIR/config/config.example.json" ]]; then
  SOURCE_DIR="$SCRIPT_DIR"
else
  command -v curl >/dev/null 2>&1 || die "通过管道安装时需要 curl。"
  command -v tar >/dev/null 2>&1 || die "通过管道安装时需要 tar。"

  TMP_DIR="$(mktemp -d)"
  ARCHIVE="$TMP_DIR/source.tar.gz"
  info "正在下载 singbox-manager (${BRANCH})..."
  curl -fL --retry 3 --connect-timeout 10     "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"     -o "$ARCHIVE"

  tar -xzf "$ARCHIVE" -C "$TMP_DIR"

  for candidate in "$TMP_DIR"/*/; do
    if [[ -f "${candidate}compose.yml" && -f "${candidate}bin/sbx" ]]; then
      SOURCE_DIR="${candidate%/}"
      break
    fi
  done

  [[ -n "$SOURCE_DIR" ]] || die "无法识别下载的源码目录。"
fi

info "安装目录: $INSTALL_DIR"

mkdir -p   "$INSTALL_DIR/bin"   "$INSTALL_DIR/config"   "$INSTALL_DIR/data"   "$INSTALL_DIR/backup"

install -m 0644 "$SOURCE_DIR/compose.yml" "$INSTALL_DIR/compose.yml"
install -m 0644 "$SOURCE_DIR/.env.example" "$INSTALL_DIR/.env.example"
install -m 0644 "$SOURCE_DIR/config/config.example.json" "$INSTALL_DIR/config/config.example.json"
install -m 0755 "$SOURCE_DIR/bin/sbx" "$INSTALL_DIR/bin/sbx"

if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
  info "已创建默认 .env"
else
  info "保留已有 .env"
fi

if [[ ! -f "$INSTALL_DIR/config/config.json" ]]; then
  cp "$INSTALL_DIR/config/config.example.json" "$INSTALL_DIR/config/config.json"
  chmod 600 "$INSTALL_DIR/config/config.json"
  info "已创建默认 config.json"
else
  info "保留已有 config.json"
fi

chmod 700 "$INSTALL_DIR/config" "$INSTALL_DIR/data" "$INSTALL_DIR/backup"
ln -sfn "$INSTALL_DIR/bin/sbx" "$BIN_LINK"

info "安装完成。"
printf '\n'
printf '常用命令:\n'
printf '  sbx             打开交互菜单\n'
printf '  sbx check       检查配置\n'
printf '  sbx start       启动 sing-box\n'
printf '  sbx logs        查看日志\n'
printf '\n'
printf '当前默认配置仅使用 direct 出站。请先执行 sbx edit 添加你的代理出站，然后执行 sbx check。\n'
