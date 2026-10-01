#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${SBX_REPO:-PaiMonCai/singbox-manager}"
BRANCH="${SBX_INSTALL_BRANCH:-main}"
INSTALL_DIR="${SBX_INSTALL_DIR:-/opt/singbox-manager}"
BIN_LINK="${SBX_BIN_LINK:-/usr/local/bin/sbx}"
DEFAULT_VERSION="${SBX_DEFAULT_VERSION:-v1.14.2}"
NONINTERACTIVE="${SBX_NONINTERACTIVE:-0}"
MANAGER_ONLY="${SBX_MANAGER_ONLY:-0}"
RECONFIGURE="${SBX_RECONFIGURE:-0}"
INSTALLER_LINK="${SBX_INSTALLER_LINK:-/usr/local/bin/sbx-install}"
[[ "$MANAGER_ONLY" == "1" ]] && NONINTERACTIVE=1
[[ "${SBX_ASSUME_YES:-0}" == "1" ]] && NONINTERACTIVE=1
SOURCE_BASE_URL="${SBX_SOURCE_BASE_URL:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
# 显式指定过来源地址时（自己的 CDN / 私有镜像 / 固定 tag），只在该地址内竞速，
# 不再自动混入由 REPO/BRANCH 推导出来的官方额外候选，避免把不同来源的内容混装。
SOURCE_BASE_URL_EXPLICIT=0
[[ -n "${SBX_SOURCE_BASE_URL:-}" ]] && SOURCE_BASE_URL_EXPLICIT=1
# SBX_ARCHIVE_URL 用"是否设置"而非"是否非空"判断：
# 显式置空（SBX_ARCHIVE_URL= ）表示关闭整包兜底，只从逐文件源取源码。
ARCHIVE_URL=""
ARCHIVE_URL_EXPLICIT=0
if [[ -n "${SBX_ARCHIVE_URL+x}" ]]; then
  ARCHIVE_URL="$SBX_ARCHIVE_URL"
  ARCHIVE_URL_EXPLICIT=1
else
  ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
fi
SOURCE_EXTRAS=0
if (( SOURCE_BASE_URL_EXPLICIT == 0 && ARCHIVE_URL_EXPLICIT == 0 )); then
  SOURCE_EXTRAS=1
fi

TMP_DIR=""
SOURCE_DIR=""
env_backup=""

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  if [[ -n "${env_backup:-}" ]]; then
    rm -f "$env_backup"
  fi
  return 0
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

validate_bind() {
  [[ -n "$1" ]] || return 1
  python3 -c 'import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1].strip())
except ValueError:
    raise SystemExit(1)' "$1" 2>/dev/null
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

  local installer rc=0
  installer="$(mktemp /tmp/get-docker-XXXXXX.sh)"
  if ! curl -fsSL --retry 3 https://get.docker.com -o "$installer"; then
    rm -f "$installer"
    die "下载 Docker 安装脚本失败。请手动安装 Docker Engine + Compose v2 后重试。"
  fi
  sh "$installer" || rc=$?
  rm -f "$installer"
  if ((rc)); then
    die "Docker 安装脚本执行失败（退出码 $rc）。"
  fi
  return 0

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 || die "Docker 已安装，但未检测到 Compose v2。"
}

# ── 源码获取：候选源枚举 + 并发测速 + 按排名抓取 ──────────────────────────────
# 候选源分两类：
#   files   <base>/<相对路径> 可逐文件下载（官方 raw、jsDelivr、第三方加速站或自建镜像）
#   archive 整包 tar.gz（github.com archive、codeload）
# 流程：对全部候选源并发测速（同一探测文件、短超时）→ 按实测吞吐排名 →
#       按排名逐文件抓取，某个源取某个文件失败就立刻切到下一名（避免"某个文件超时"
#       让整个安装失败）→ 全部逐文件源都不行才回退 archive 整包。
SOURCE_MIRRORS="${SBX_SOURCE_MIRRORS:-}"
SOURCE_MIRROR_PRESET="${SBX_MIRROR_PRESET:-0}"
SOURCE_NO_RACE="${SBX_SOURCE_NO_RACE:-0}"
SOURCE_PROBE_TIMEOUT="${SBX_SOURCE_PROBE_TIMEOUT:-6}"
SOURCE_PROBE_FILE="${SBX_SOURCE_PROBE_FILE:-bin/sbx}"
SOURCE_FILE_TIMEOUT="${SBX_SOURCE_FILE_TIMEOUT:-30}"
SOURCE_ARCHIVE_TIMEOUT="${SBX_SOURCE_ARCHIVE_TIMEOUT:-60}"
SOURCE_CONCURRENCY="${SBX_SOURCE_CONCURRENCY:-3}"
SOURCE_UA="singbox-manager-installer"

SOURCE_REQUIRED=(
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
  "lib/sbx_docker_network.sh"
  "lib/sbx_docker_targets.py"
  "bin/sbx-docker-watch"
  "lib/sbx_verify.py"
  "lib/sbx_update.sh"
  "bin/sbx-install"
  "VERSION"
)

RANKED_SPECS=()
RANKED_LABELS=()
RANKED_SPEEDS=()
RANKED_VERS=()
FILES_RANKED=()
FILES_STICKY=0
ARCHIVE_DIR=""
FIRST_LABEL=""

source_host_label() {
  local host="${1#*://}"
  host="${host%%/*}"
  case "$host" in
    raw.githubusercontent.com) printf 'raw' ;;
    cdn.jsdelivr.net) printf 'jsdelivr' ;;
    github.com) printf 'github-archive' ;;
    codeload.github.com) printf 'codeload' ;;
    "") printf '本地' ;;
    *) printf '%s' "$host" ;;
  esac
}

source_speed_text() {
  local s="${1:-0}" kb
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  if (( s <= 0 )); then
    printf '失败'
    return 0
  fi
  kb=$(( s / 1024 ))
  if (( kb >= 1024 )); then
    printf '%d.%dMB/s' $(( kb / 1024 )) $(( (kb % 1024) * 10 / 1024 ))
  else
    printf '%d.%dKB/s' "$kb" $(( (s % 1024) * 10 / 1024 ))
  fi
}

# 输出 kind|url|label 形式的候选源（kind=files|archive）
source_candidates() {
  local -a extras=() preset=()
  local base raw_base m
  if [[ -n "$SOURCE_BASE_URL" ]]; then
    printf 'files|%s|%s\n' "${SOURCE_BASE_URL%/}" "$(source_host_label "$SOURCE_BASE_URL")"
  fi
  IFS=' ,' read -r -a extras <<<"$SOURCE_MIRRORS"
  for m in ${extras[@]+"${extras[@]}"}; do
    [[ -n "$m" ]] || continue
    printf 'files|%s|%s\n' "${m%/}" "$(source_host_label "$m")"
  done
  if (( SOURCE_EXTRAS )); then
    printf 'files|https://cdn.jsdelivr.net/gh/%s@%s|jsdelivr\n' "$REPO" "$BRANCH"
  fi
  # 第三方公共加速站默认关闭：它们能改写安装内容，只在 SBX_MIRROR_PRESET=1 时参与竞速。
  if [[ "$SOURCE_MIRROR_PRESET" == "1" ]]; then
    raw_base="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
    preset=(
      "https://gh-proxy.com/${raw_base}"
      "https://ghproxy.net/${raw_base}"
      "https://ghfast.top/${raw_base}"
      "https://raw.gitmirror.com/${REPO}/${BRANCH}"
    )
    for m in "${preset[@]}"; do
      printf 'files|%s|%s\n' "$m" "$(source_host_label "$m")"
    done
  fi
  if [[ -n "$ARCHIVE_URL" ]]; then
    printf 'archive|%s|%s\n' "$ARCHIVE_URL" "$(source_host_label "$ARCHIVE_URL")"
  fi
  if (( SOURCE_EXTRAS )); then
    printf 'archive|https://codeload.github.com/%s/tar.gz/refs/heads/%s|codeload\n' "$REPO" "$BRANCH"
  fi
  return 0
}

# 给 HTTP(S) 地址加缓存破坏参数（raw CDN 对单文件有几分钟缓存，发版后立刻跑安装器
# 可能拿到旧内容）；file:// 等其它协议原样返回。
source_bust_url() {
  case "$1" in
    http://*|https://*) printf '%s?sbx=%s\n' "$1" "$(date +%s)" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# 版本号比较，只比较数字部分（install.sh 必须自包含）：
#   第一个更旧 → 0；数字部分相同 → 1；第一个更新 → 2；无法解析 → 3
# 这里刻意忽略 -rc1 / 后缀差异：它只用来判断“某个源报告的版本是不是明显更旧
# （命中了 CDN 的分支缓存）”，不是用来决定要不要更新的。
source_version_cmp() {
  local left_v="$1" right_v="$2" l r n i ln rn
  local -a lparts=() rparts=()
  l="${left_v#v}"; l="${l#V}"; l="${l%%[^0-9.]*}"
  r="${right_v#v}"; r="${r#V}"; r="${r%%[^0-9.]*}"
  [[ "$l" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 3
  [[ "$r" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 3
  IFS='.' read -r -a lparts <<<"$l"
  IFS='.' read -r -a rparts <<<"$r"
  n=${#lparts[@]}
  (( ${#rparts[@]} > n )) && n=${#rparts[@]}
  for ((i=0;i<n;i++)); do
    ln="${lparts[i]:-0}"; rn="${rparts[i]:-0}"
    if (( 10#$ln < 10#$rn )); then return 0; fi
    if (( 10#$ln > 10#$rn )); then return 2; fi
  done
  return 1
}

# 单个候选源的探测：探测文件（测吞吐）+ 该源的 VERSION（判断内容是否过期，仅 files 源）。
# 只测量吞吐，不负责内容完整性——完整性由正式抓取阶段保证。
source_probe_one() {
  local spec="$1" payload="$2" result="$3" kind url label rc=0 metrics code speed size
  local version="" vtmp=""
  IFS='|' read -r kind url label <<<"$spec"
  if [[ "$kind" != "files" ]]; then
    metrics="$(curl -sSL -A "$SOURCE_UA" --connect-timeout 5 --max-time "$SOURCE_PROBE_TIMEOUT" \
      -w '%{http_code} %{speed_download} %{size_download}' -o "$payload" "$url" 2>/dev/null)" || rc=$?
  else
    vtmp="${payload}.version"
    # 探测文件与 VERSION 并发取，避免把单源探测耗时翻倍
    (
      curl -fsSL -A "$SOURCE_UA" --connect-timeout 5 --max-time "$SOURCE_PROBE_TIMEOUT" \
        "$(source_bust_url "${url%/}/VERSION")" -o "$vtmp" 2>/dev/null
    ) >/dev/null 2>&1 &
    local vpid=$!
    metrics="$(curl -sSL -A "$SOURCE_UA" --connect-timeout 5 --max-time "$SOURCE_PROBE_TIMEOUT" \
      -w '%{http_code} %{speed_download} %{size_download}' -o "$payload" \
      "$(source_bust_url "${url%/}/${SOURCE_PROBE_FILE}")" 2>/dev/null)" || rc=$?
    wait "$vpid" 2>/dev/null || true
    if [[ -s "$vtmp" ]]; then version="$(tr -d '[:space:]' < "$vtmp")"; fi
    rm -f "$vtmp"
  fi
  read -r code speed size <<<"${metrics:-0 0 0}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$rc" "${code:-0}" "${speed:-0}" "${size:-0}" "$version" >"$result"
  return 0
}

source_tree_complete() {
  local dir="$1" path
  for path in "${SOURCE_REQUIRED[@]}"; do
    [[ -f "$dir/$path" ]] || return 1
  done
  return 0
}

# 并发测速 → 填充 RANKED_SPECS / RANKED_LABELS / RANKED_SPEEDS / FILES_RANKED
race_sources() {
  local spec i n=0 idx kind url label rc=0 code=0 speed=0 size=0 size_int=0 speed_int=0 a b best tmp order_str=""
  local raced=0 max_version="" stale_str=""
  local dir="$TMP_DIR/race"
  local -a pids=() spd_of=() ver_of=()
  local -a r_specs=() r_labels=() r_spds=() r_vers=() r_files=()
  local uniq=""

  RANKED_SPECS=(); RANKED_LABELS=(); RANKED_SPEEDS=(); RANKED_VERS=(); FILES_RANKED=(); FILES_STICKY=0

  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    case $'\n'"$uniq" in *$'\n'"$spec"$'\n'*) continue ;; esac
    uniq+="$spec"$'\n'
    RANKED_SPECS+=("$spec")
  done < <(source_candidates)
  n=${#RANKED_SPECS[@]}
  (( n )) || return 1

  for ((i=0;i<n;i++)); do spd_of[i]=0; done

  if [[ "$SOURCE_NO_RACE" == "1" ]]; then
    info "已禁用并发测速（SBX_SOURCE_NO_RACE=1），按默认顺序取源。"
    for ((i=0;i<n;i++)); do order_str+=" $i"; done
  elif (( n == 1 )); then
    # 只有一个来源（例如显式指定了自己的镜像）时不做任何额外请求，保持旧行为。
    order_str=" 0"
  else
    raced=1
    info "正在并发测速 ${n} 个候选源（单源最长 ${SOURCE_PROBE_TIMEOUT}s）..."
    mkdir -p "$dir"
    for ((i=0;i<n;i++)); do
      ( source_probe_one "${RANKED_SPECS[$i]}" "$dir/payload.$i" "$dir/result.$i" ) &
      pids[i]=$!
    done
    wait ${pids[@]+"${pids[@]}"} >/dev/null 2>&1 || true

    # 有响应的按实测吞吐降序排在最前，其余保持默认顺序作为后备
    local -a ok_idx=() ok_spd=()
    for ((i=0;i<n;i++)); do
      rc=1; code=0; speed=0; size=0; ver_of[i]=""
      local ver_field=""
      if [[ -f "$dir/result.$i" ]]; then
        IFS=$'\t' read -r rc code speed size ver_field <"$dir/result.$i" || true
        ver_of[i]="$ver_field"
      fi
      size_int="${size%%.*}"; speed_int="${speed%%.*}"
      [[ "$size_int" =~ ^[0-9]+$ ]] || size_int=0
      [[ "$speed_int" =~ ^[0-9]+$ ]] || speed_int=0
      spd_of[i]="$speed_int"
      if (( size_int > 0 )); then
        ok_idx+=("$i"); ok_spd+=("$speed_int")
      fi
    done
    # 选择排序（候选通常只有几个，避免依赖 sort 的实现差异）
    for ((a=0;a<${#ok_idx[@]};a++)); do
      best=$a
      for ((b=a+1;b<${#ok_idx[@]};b++)); do
        if (( ok_spd[b] > ok_spd[best] )); then best=$b; fi
      done
      if (( best != a )); then
        tmp="${ok_spd[a]}"; ok_spd[a]="${ok_spd[best]}"; ok_spd[best]="$tmp"
        tmp="${ok_idx[a]}"; ok_idx[a]="${ok_idx[best]}"; ok_idx[best]="$tmp"
      fi
    done

    # 过期源降级：CDN 对分支路径有缓存（jsDelivr 可长达 12 小时），它往往又快又旧。
    # 取探测到的最大版本作为“当前版本”，报告更旧版本的源排到最后，
    # 避免“装了快但过期的源码/旧版本”。只在默认派生候选集合上启用，
    # 显式指定 SBX_SOURCE_BASE_URL 时保持原语义（用户自己钉的来源优先）。
    if (( SOURCE_EXTRAS )); then
      local cmp_rc=0
      for ((i=0;i<n;i++)); do
        [[ -n "${ver_of[$i]}" ]] || continue
        if [[ -z "$max_version" ]]; then
          max_version="${ver_of[$i]}"
          continue
        fi
        if source_version_cmp "$max_version" "${ver_of[$i]}"; then
          cmp_rc=0
        else
          cmp_rc=$?
        fi
        if (( cmp_rc == 0 )); then
          max_version="${ver_of[$i]}"
        fi
      done
      if [[ -n "$max_version" ]]; then
        for ((a=0;a<${#ok_idx[@]};a++)); do
          i="${ok_idx[a]}"
          cmp_rc=1
          if [[ -n "${ver_of[$i]}" ]]; then
            if source_version_cmp "$max_version" "${ver_of[$i]}"; then
              cmp_rc=0
            else
              cmp_rc=$?
            fi
          fi
          # 只有“明确比最新版本更旧”才降级；未知版本、相同版本、无法解析都保持原序
          if (( cmp_rc == 2 )); then
            stale_str+=" $i"
          else
            order_str+=" $i"
          fi
        done
      fi
    fi
    if [[ -z "$order_str" ]]; then
      for ((a=0;a<${#ok_idx[@]};a++)); do order_str+=" ${ok_idx[a]}"; done
    fi
    order_str+="$stale_str"
    for ((i=0;i<n;i++)); do
      case " $order_str " in *" $i "*) continue ;; esac
      order_str+=" $i"
    done
  fi

  idx=0
  for i in $order_str; do
    spec="${RANKED_SPECS[$i]}"
    IFS='|' read -r kind url label <<<"$spec"
    r_specs+=("$spec")
    r_labels+=("$label")
    r_spds+=("$(source_speed_text "${spd_of[$i]:-0}")")
    r_vers+=("${ver_of[$i]:-}")
    if [[ "$kind" == "files" ]]; then r_files+=("$spec"); fi
    if (( idx == 0 )); then FIRST_LABEL="$label"; fi
    idx=$((idx+1))
  done

  RANKED_SPECS=("${r_specs[@]}")
  RANKED_LABELS=("${r_labels[@]}")
  RANKED_SPEEDS=("${r_spds[@]}")
  RANKED_VERS=("${r_vers[@]}")
  if (( ${#r_files[@]} )); then FILES_RANKED=("${r_files[@]}"); fi

  if (( raced )); then
    local summary="" sep="" mark=""
    for ((a=0;a<${#RANKED_LABELS[@]};a++)); do
      mark=""
      if [[ -n "${RANKED_VERS[$a]:-}" ]]; then
        if [[ "${RANKED_VERS[$a]}" == "$max_version" ]]; then
          mark="v${RANKED_VERS[$a]}"
        else
          mark="v${RANKED_VERS[$a]}(过期)"
        fi
      fi
      summary+="${sep}${RANKED_LABELS[$a]} ${mark:+$mark }${RANKED_SPEEDS[$a]}"
      sep=" | "
    done
    info "测速结果: $summary → 首选 ${FIRST_LABEL}"
  fi
  return 0
}

fetch_source_file() { # base path dest
  local base="$1" path="$2" dest="$3" part="$3.part"
  mkdir -p "$(dirname "$dest")"
  if curl -fL -A "$SOURCE_UA" --retry 1 --retry-delay 1 --connect-timeout 8 \
    --max-time "$SOURCE_FILE_TIMEOUT" "$(source_bust_url "${base%/}/$path")" -o "$part"; then
    if [[ -s "$part" ]]; then
      mv -f "$part" "$dest"
      return 0
    fi
  fi
  rm -f "$part"
  return 1
}

# 单个文件：按排名逐个候选源试，成功时把用到的候选序号写进结果目录
# （子进程不能改父 shell 的 FILES_STICKY，所以由父进程汇总后再更新）
fetch_one_file_ranked() { # raw_dir path results_dir
  local raw_dir="$1" path="$2" results="$3" spec base label i n idx
  n=${#FILES_RANKED[@]}
  for ((i=0;i<n;i++)); do
    idx=$(( (FILES_STICKY + i) % n ))
    spec="${FILES_RANKED[$idx]}"
    IFS='|' read -r _ base label <<<"$spec"
    if fetch_source_file "$base" "$path" "$raw_dir/$path"; then
      printf '%s\n' "$idx" > "$results/${path//\//_}.idx"
      return 0
    fi
    warn "源 $label 下载 $path 失败，切换到下一个候选源..."
  done
  return 1
}

# 逐文件抓取；某个源失败立刻切到排名下一名，并记住可用的源（FILES_STICKY）。
# 多个文件在有界并发下同时下载（慢链路上收益明显；SBX_SOURCE_CONCURRENCY=1 可回到顺序下载）。
fetch_files_missing() { # raw_dir
  local raw_dir="$1" results="$TMP_DIR/fetch-results" path i n conc launched=0
  local best=-1 bestcount=0 count
  local -a queue=() pids=()
  n=${#FILES_RANKED[@]}
  (( n )) || return 1
  for path in "${SOURCE_REQUIRED[@]}"; do
    [[ -s "$raw_dir/$path" ]] && continue
    queue+=("$path")
  done
  (( ${#queue[@]} )) || return 0

  conc="$SOURCE_CONCURRENCY"
  [[ "$conc" =~ ^[0-9]+$ ]] || conc=3
  (( conc >= 1 )) || conc=1
  (( conc > ${#queue[@]} )) && conc=${#queue[@]}
  info "并发下载源码：${#queue[@]} 个文件，并发 $conc，单文件失败自动换源..."

  rm -rf "$results"
  mkdir -p "$results"
  for path in "${queue[@]}"; do
    ( fetch_one_file_ranked "$raw_dir" "$path" "$results" ) &
    pids+=("$!")
    launched=$((launched+1))
    # 滑动窗口：跑满 conc 个就先等最老的那个收工
    if (( launched >= conc )); then
      wait "${pids[$((launched-conc))]}" 2>/dev/null || true
    fi
  done
  wait || true

  for path in "${queue[@]}"; do
    if [[ ! -s "$raw_dir/$path" ]]; then
      warn "所有逐文件候选源都取不到 $path。"
      rm -rf "$results"
      return 1
    fi
  done

  # 把这一轮最常成功的候选源记成 sticky，下次从它开始试
  for ((i=0;i<n;i++)); do
    count=0
    for path in "${queue[@]}"; do
      if [[ -f "$results/${path//\//_}.idx" ]] && [[ "$(cat "$results/${path//\//_}.idx")" == "$i" ]]; then
        count=$((count+1))
      fi
    done
    if (( count > bestcount )); then bestcount=$count; best=$i; fi
  done
  (( best >= 0 )) && FILES_STICKY=$best

  rm -rf "$results"
  return 0
}

fetch_archive_source() { # url → 成功时设置 ARCHIVE_DIR
  local url="$1" archive="$TMP_DIR/archive.tar.gz" dir
  rm -rf "$TMP_DIR/archive"
  mkdir -p "$TMP_DIR/archive"
  if ! curl -fL -A "$SOURCE_UA" --retry 2 --connect-timeout 10 \
    --max-time "$SOURCE_ARCHIVE_TIMEOUT" "$url" -o "$archive"; then
    rm -f "$archive"
    return 1
  fi
  if ! tar -xzf "$archive" -C "$TMP_DIR/archive"; then
    rm -f "$archive"
    return 1
  fi
  for dir in "$TMP_DIR/archive"/*/; do
    [[ -d "$dir" ]] || continue
    if source_tree_complete "${dir%/}"; then
      ARCHIVE_DIR="${dir%/}"
      return 0
    fi
  done
  return 1
}

get_source() {
  local script_dir="" raw_dir="" spec kind url label
  local fetched=0

  # 1) 已经在本仓库里运行（源码完整）→ 直接用本地源码，不联网
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || true)"
  fi
  if [[ -n "$script_dir" ]] && source_tree_complete "$script_dir"; then
    SOURCE_DIR="$script_dir"
    return 0
  fi

  # 2) 并发测速候选源（SOURCE_BASE_URL / ARCHIVE_URL + SBX_SOURCE_MIRRORS / SBX_MIRROR_PRESET）
  TMP_DIR="$(mktemp -d)"
  raw_dir="$TMP_DIR/raw"
  mkdir -p "$raw_dir/config" "$raw_dir/bin" "$raw_dir/lib"
  race_sources || die "没有可用的源码候选地址。"

  # 3) 按测速排名抓取：逐文件源失败自动换源，最后才用整包源
  for spec in "${RANKED_SPECS[@]}"; do
    IFS='|' read -r kind url label <<<"$spec"
    if [[ "$kind" == "files" ]]; then
      if fetch_files_missing "$raw_dir" && source_tree_complete "$raw_dir"; then
        SOURCE_DIR="$raw_dir"
        fetched=1
        info "源码已通过 $label 准备完成。"
        break
      fi
      warn "源 $label 未能取齐全部文件，尝试下一个候选源..."
    else
      if fetch_archive_source "$url"; then
        SOURCE_DIR="$ARCHIVE_DIR"
        fetched=1
        info "源码已通过整包源 $label 准备完成。"
        break
      fi
      warn "整包源 $label 下载失败，尝试下一个候选源..."
    fi
  done

  if (( fetched )); then
    return 0
  fi

  # 4) 全部候选源失败：保留 archive 兜底语义与提示
  warn "raw 源不可用，回退 GitHub archive..."
  if [[ -n "$ARCHIVE_URL" ]] && fetch_archive_source "$ARCHIVE_URL"; then
    SOURCE_DIR="$ARCHIVE_DIR"
    return 0
  fi

  die "无法下载 singbox-manager 源码（候选源均失败）。可设置 SBX_SOURCE_BASE_URL 指向你自己的 raw/CDN 镜像，或设置 SBX_ARCHIVE_URL 指向整包地址。"
}

read_env_value() {
  local file="$1" key="$2" fallback="$3" value
  value="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  printf '%s\n' "${value:-$fallback}"
}

write_env() {
  local version="$1" bind="$2" port="$3" image="${4:-ghcr.io/sagernet/sing-box}" docker_network="${5:-singbox-proxy}" container_name="${6:-sing-box}"
  cat > "$INSTALL_DIR/.env" <<EOF
SING_BOX_IMAGE=$image
SING_BOX_VERSION=$version
SING_BOX_CONTAINER_NAME=$container_name
SING_BOX_BIND_ADDR=$bind
SING_BOX_MIXED_PORT=$port
SING_BOX_DOCKER_NETWORK=$docker_network
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
old_container_name="sing-box"
old_bind="127.0.0.1"
old_port="7890"
old_docker_network="singbox-proxy"
if (( UPGRADE )); then
  old_version="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_VERSION "$DEFAULT_VERSION")"
  old_image="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_IMAGE "ghcr.io/sagernet/sing-box")"
  old_container_name="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_CONTAINER_NAME "sing-box")"
  old_bind="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_BIND_ADDR "127.0.0.1")"
  old_port="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_MIXED_PORT "7890")"
  old_docker_network="$(read_env_value "$INSTALL_DIR/.env" SING_BOX_DOCKER_NETWORK "singbox-proxy")"
  info "检测到已有安装，将执行就地升级并保留节点数据。"
fi

version=""
bind=""
port=""
# manager-only 更新不使用这三个值（它在 write_env 之前就退出），
# 因此 sing-box 的版本/端口不能用来挡住管理器自身的更新路径。
if [[ "$MANAGER_ONLY" != "1" ]]; then
  if (( UPGRADE )) && [[ "$RECONFIGURE" != "1" ]]; then
    # 已有安装：直接沿用现有 .env，不再逐项询问（要改这些值请用 SBX_RECONFIGURE=1 重跑）
    version="$old_version"; bind="$old_bind"; port="$old_port"
    info "检测到已有安装，沿用现有配置：sing-box $version，监听 $bind:$port"
  else
    version="$(ask 'sing-box 版本' "$old_version")"
    [[ "$version" == v* ]] || version="v$version"
    bind="$(ask '本地代理监听地址' "$old_bind")"
    port="$(ask '本地 mixed HTTP/SOCKS5 端口' "$old_port")"
  fi

  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "版本格式无效: $version（可修正 $INSTALL_DIR/.env 的 SING_BOX_VERSION，或用 SBX_RECONFIGURE=1 重新输入）"

  bind_attempts=0
  while ! validate_bind "$bind"; do
    bind_attempts=$((bind_attempts+1))
    if [[ "$NONINTERACTIVE" == "1" || $bind_attempts -ge 5 ]]; then
      die "监听地址无效: ${bind:-（空）}。请修正 $INSTALL_DIR/.env 中的 SING_BOX_BIND_ADDR 后重试。"
    fi
    warn "监听地址必须是 IPv4/IPv6 地址，例如 127.0.0.1。"
    bind="$(ask '本地代理监听地址' "$old_bind")"
  done
  case "$bind" in
    0.0.0.0|"::") warn "监听地址 $bind 会把代理端口暴露到所有网卡（可能含公网），请确认这是你的意图。" ;;
  esac

  # 非交互模式下 ask 永远回显同一个默认值，重试不可能成功，必须直接失败而不是空转。
  port_attempts=0
  while ! validate_port "$port"; do
    port_attempts=$((port_attempts+1))
    if [[ "$NONINTERACTIVE" == "1" || $port_attempts -ge 5 ]]; then
      die "端口无效: ${port:-（空）}。请修正 $INSTALL_DIR/.env 中的 SING_BOX_MIXED_PORT 后重试。"
    fi
    warn "端口必须是 1-65535 的整数。"
    port="$(ask '本地 mixed HTTP/SOCKS5 端口' "$old_port")"
  done
fi

info "安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/config" "$INSTALL_DIR/nodes" "$INSTALL_DIR/data" "$INSTALL_DIR/backup"

install -m 0644 "$SOURCE_DIR/compose.yml" "$INSTALL_DIR/compose.yml"
install -m 0644 "$SOURCE_DIR/.env.example" "$INSTALL_DIR/.env.example"
install -m 0644 "$SOURCE_DIR/config/config.example.json" "$INSTALL_DIR/config/config.example.json"
install -m 0755 "$SOURCE_DIR/bin/sbx" "$INSTALL_DIR/bin/sbx"
install -m 0755 "$SOURCE_DIR/lib/sbx_nodes.py" "$INSTALL_DIR/lib/sbx_nodes.py"
install -m 0755 "$SOURCE_DIR/lib/sbx_v3.sh" "$INSTALL_DIR/lib/sbx_v3.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_proxy.sh" "$INSTALL_DIR/lib/sbx_proxy.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_bootstrap.sh" "$INSTALL_DIR/lib/sbx_bootstrap.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_image.sh" "$INSTALL_DIR/lib/sbx_image.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_inbound.sh" "$INSTALL_DIR/lib/sbx_inbound.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_docker_network.sh" "$INSTALL_DIR/lib/sbx_docker_network.sh"
install -m 0755 "$SOURCE_DIR/lib/sbx_docker_targets.py" "$INSTALL_DIR/lib/sbx_docker_targets.py"
install -m 0755 "$SOURCE_DIR/bin/sbx-docker-watch" "$INSTALL_DIR/bin/sbx-docker-watch"
install -m 0755 "$SOURCE_DIR/lib/sbx_verify.py" "$INSTALL_DIR/lib/sbx_verify.py"
install -m 0755 "$SOURCE_DIR/lib/sbx_update.sh" "$INSTALL_DIR/lib/sbx_update.sh"
install -m 0755 "$SOURCE_DIR/bin/sbx-install" "$INSTALLER_LINK"

chmod 700 "$INSTALL_DIR/config" "$INSTALL_DIR/nodes" "$INSTALL_DIR/data" "$INSTALL_DIR/backup"
ln -sfn "$INSTALL_DIR/bin/sbx" "$BIN_LINK"
chmod 0755 "$INSTALLER_LINK"
# VERSION 最后安装：管理器自更新以它作为“这次安装是否整体成功”的判据，
# 先写 VERSION 会让“代码没装全”被误判成更新成功。
install -m 0644 "$SOURCE_DIR/VERSION" "$INSTALL_DIR/VERSION"

if [[ "$MANAGER_ONLY" == "1" ]]; then
  manager_version="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION" 2>/dev/null || true)"
  printf '\n'
  printf '\033[32m管理器更新完成：%s\033[0m\n' "${manager_version:-unknown}"
  printf '  未修改 .env / nodes.json / config.json，也未重启 sing-box。\n'
  printf '  快速更新: sbx self-update\n'
  printf '  完整安装器: sbx-install\n'
  exit 0
fi

# 后面还有可能失败（节点库校验）。先把现有 .env 留一份，避免失败时已经改掉用户配置。
if [[ -f "$INSTALL_DIR/.env" ]]; then
  env_backup="$(mktemp /tmp/sbx-env-XXXXXX)"
  cp -a "$INSTALL_DIR/.env" "$env_backup"
fi

write_env "$version" "$bind" "$port" "$old_image" "$old_docker_network" "$old_container_name"

export SBX_HOME="$INSTALL_DIR"
if [[ ! -f "$INSTALL_DIR/nodes/nodes.json" ]]; then
  python3 "$INSTALL_DIR/lib/sbx_nodes.py" init
  chmod 600 "$INSTALL_DIR/nodes/nodes.json" "$INSTALL_DIR/config/config.json"
else
  if ! python3 "$INSTALL_DIR/lib/sbx_nodes.py" validate >/dev/null; then
    if [[ -n "$env_backup" ]]; then
      install -m600 "$env_backup" "$INSTALL_DIR/.env"
      rm -f "$env_backup"; env_backup=""
    fi
    die "现有节点库校验失败，已回滚 .env。请先修复 $INSTALL_DIR/nodes/nodes.json 后重试。"
  fi
  python3 "$INSTALL_DIR/lib/sbx_nodes.py" render >/dev/null
fi
if [[ -n "$env_backup" ]]; then rm -f "$env_backup"; env_backup=""; fi

source "$INSTALL_DIR/lib/sbx_bootstrap.sh"
image_ready=0
if docker image inspect "$old_image:$version" >/dev/null 2>&1; then
  info "本地已有镜像: $old_image:$version"
  image_ready=1
elif confirm "本地缺少 sing-box $version 镜像，是否现在准备？" yes; then
  if bootstrap_ensure_image "$version" "$INSTALL_DIR/.env"; then
    image_ready=1
  else
    warn "sing-box 镜像尚未准备好。你可以稍后重新运行安装器。"
  fi
fi

node_count="$(python3 - "$INSTALL_DIR/nodes/nodes.json" <<'PY'
import json
import sys
from pathlib import Path
try:
    print(len(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8')).get('nodes', [])))
except Exception:
    print(0)
PY
)"

if [[ "$node_count" == "0" ]] && confirm "当前没有代理节点，是否现在交互式添加第一个节点？" yes; then
  "$BIN_LINK" node add || warn "节点添加未完成，你之后可以运行: sbx node add"
  node_count="$(python3 - "$INSTALL_DIR/nodes/nodes.json" <<'PY'
import json
import sys
from pathlib import Path
try: print(len(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8')).get('nodes', [])))
except Exception: print(0)
PY
)"
fi

# sing-box 已在运行（本次多半只是更新脚本/配置）：直接重启让新配置生效，不再询问
container_running=0
if docker ps --filter "name=^${old_container_name}$" --format '{{.Names}}' 2>/dev/null | grep -qx "$old_container_name"; then
  container_running=1
fi

if (( image_ready )); then
  if (( container_running )); then
    info "sing-box 正在运行，重新生成配置后自动重启以生效..."
    "$BIN_LINK" restart || warn "重启失败，请运行 sbx logs 查看详情。"
  else
    start_default="no"
    [[ "$node_count" != "0" ]] && start_default="yes"
    if confirm "是否立即启动 sing-box？" "$start_default"; then
      "$BIN_LINK" start || warn "启动失败，请运行 sbx check 和 sbx logs 查看详情。"
    fi
  fi
fi

printf '\n'
printf '\033[32m安装完成。\033[0m\n'
if (( UPGRADE )); then
  printf '  就地更新：沿用现有 .env 的版本/监听/端口，未做任何重新询问（需要改这些值: SBX_RECONFIGURE=1 bash install.sh）\n'
fi
printf '  管理菜单: sbx\n'
printf '  节点管理: sbx node\n'
printf '  添加节点: sbx node add\n'
printf '  测试节点: sbx node test\n'
printf '  快速更新: sbx self-update\n'
printf '  最新安装器: sbx-install\n'
printf '  当前代理: http://%s:%s 或 socks5://%s:%s\n' "$bind" "$port" "$bind" "$port"
printf '\n'
