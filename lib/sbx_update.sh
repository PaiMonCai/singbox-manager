#!/usr/bin/env bash
# singbox-manager v0.7 self-update integration.

VERSION="0.11.16"

UPDATE_REPO="${SBX_UPDATE_REPO:-PaiMonCai/singbox-manager}"
UPDATE_BRANCH="${SBX_UPDATE_BRANCH:-main}"
UPDATE_BASE="${SBX_UPDATE_BASE_URL:-https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}}"
UPDATE_SERVICE_FILE="${SBX_UPDATE_SERVICE_FILE:-/etc/systemd/system/singbox-manager-update.service}"
UPDATE_TIMER_FILE="${SBX_UPDATE_TIMER_FILE:-/etc/systemd/system/singbox-manager-update.timer}"
UPDATE_BIN_LINK="${SBX_BIN_LINK:-/usr/local/bin/sbx}"
UPDATE_INSTALLER_LINK="${SBX_INSTALLER_LINK:-/usr/local/bin/sbx-install}"
UPDATE_SOURCE_MIRRORS="${SBX_SOURCE_MIRRORS:-}"
UPDATE_MIRROR_PRESET="${SBX_MIRROR_PRESET:-0}"
UPDATE_RACE_TIMEOUT="${SBX_UPDATE_RACE_TIMEOUT:-25}"
# 显式指定过 SBX_UPDATE_BASE_URL（自建镜像 / 固定 tag / file:// 测试源）时，
# 只在该地址内抢速，不混入由 UPDATE_REPO 推导出来的官方额外候选。
UPDATE_BASE_EXPLICIT=0
[[ -n "${SBX_UPDATE_BASE_URL:-}" ]] && UPDATE_BASE_EXPLICIT=1

manager_proxy_url(){
  local port="7890" host="127.0.0.1"
  if [[ -f "${ENV:-$HOME_DIR/.env}" ]]; then
    port="$(grep -E '^SING_BOX_MIXED_PORT=' "${ENV:-$HOME_DIR/.env}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    [[ -n "$port" ]] || port="7890"
  fi
  # bin/sbx 里定义了 proxy_host()（会读 SING_BOX_BIND_ADDR）；
  # 单独 source 本文件（例如 CI）时退回回环地址。
  declare -F proxy_host >/dev/null 2>&1 && host="$(proxy_host)"
  printf 'http://%s:%s' "$host" "$port"
}


manager_local_version(){
  if [[ -f "$HOME_DIR/VERSION" ]]; then
    tr -d '[:space:]' < "$HOME_DIR/VERSION"
  else
    printf '%s' "$VERSION"
  fi
}

# 候选 raw 根地址（不含文件名）：默认官方 raw + jsDelivr，
# 第三方公共加速站只在 SBX_MIRROR_PRESET=1 时加入（它们能改写安装内容）。
manager_candidate_bases(){
  local -a extras=() preset=()
  local m raw_base="https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}"
  printf '%s\n' "${UPDATE_BASE%/}"
  IFS=' ,' read -r -a extras <<<"$UPDATE_SOURCE_MIRRORS"
  for m in ${extras[@]+"${extras[@]}"}; do
    [[ -n "$m" ]] || continue
    printf '%s\n' "${m%/}"
  done
  if (( UPDATE_BASE_EXPLICIT == 0 )); then
    printf '%s\n' "https://cdn.jsdelivr.net/gh/${UPDATE_REPO}@${UPDATE_BRANCH}"
  fi
  if [[ "$UPDATE_MIRROR_PRESET" == "1" ]]; then
    preset=(
      "https://gh-proxy.com/${raw_base}"
      "https://ghproxy.net/${raw_base}"
      "https://ghfast.top/${raw_base}"
      "https://raw.githubusercontent.com/${UPDATE_REPO}/${UPDATE_BRANCH}"
      "https://raw.gitmirror.com/${UPDATE_REPO}/${UPDATE_BRANCH}"
    )
    for m in "${preset[@]}"; do
      printf '%s\n' "$m"
    done
  fi
  return 0
}

# 给 HTTP(S) 地址加缓存破坏参数；file:// 等其它协议原样返回
# （raw CDN 对单个文件有几分钟缓存，发版后立刻更新时可能拿到旧内容）
manager_bust_url(){
  case "$1" in
    http://*|https://*) printf '%s?sbx=%s\n' "$1" "$(date +%s)" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# 并发取每个候选源的 VERSION，输出 "base<TAB>version"。
# 失败/为空的候选不输出。可选参数原样传给 curl（例如 --proxy）。
manager_collect_versions(){
  local -a bases=() pids=() outs=()
  local i n dir line base v
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    bases+=("$line")
  done < <(manager_candidate_bases)
  n=${#bases[@]}
  (( n )) || return 1
  dir="$(mktemp -d "${TMPDIR:-/tmp}/sbx-manager-ver.XXXXXX")"
  for ((i=0;i<n;i++)); do
    outs[i]="$dir/$i"
    (
      curl "$@" -fsSL --connect-timeout 8 --max-time 20 \
        "$(manager_bust_url "${bases[$i]%/}/VERSION")" -o "${outs[$i]}"
    ) >/dev/null 2>&1 &
    pids[i]=$!
  done
  for ((i=0;i<n;i++)); do wait "${pids[$i]}" 2>/dev/null || true; done
  for ((i=0;i<n;i++)); do
    [[ -s "${outs[$i]}" ]] || continue
    v="$(tr -d '[:space:]' < "${outs[$i]}")"
    [[ -n "$v" ]] || continue
    printf '%s\t%s\n' "${bases[$i]}" "$v"
  done
  rm -rf "$dir"
  return 0
}

# 远端版本 = 所有候选源里“最大的那个版本号”，并记下报告该版本的来源。
# 不能取“最快返回者”：CDN 对分支路径有缓存（jsDelivr 可长达 12 小时），
# 快但过期的源会让“有更新”被误判成“已是最新 / 远端更旧”，把更新永久挡住。
# 结果写入 REMOTE_VERSION 与 REMOTE_FRESH_BASES（逗号分隔的可用来源）。
manager_resolve_remote_version(){
  local line base v best="" best_list="" cmp lines proxy=""
  REMOTE_VERSION=""
  REMOTE_FRESH_BASES=""

  lines="$(manager_collect_versions 2>/dev/null)" || true
  if [[ -z "$lines" ]]; then
    proxy="$(manager_proxy_url)"
    warn "直连更新源失败，尝试通过本机 sing-box: $proxy"
    lines="$(manager_collect_versions --proxy "$proxy" 2>/dev/null)" || true
  fi
  [[ -n "$lines" ]] || return 1

  while IFS=$'\t' read -r base v; do
    [[ -n "$v" ]] || continue
    if [[ -z "$best" ]]; then
      best="$v"; best_list="$base"; continue
    fi
    # 注意：成功时也要显式赋值，不能写 `manager_version_cmp .. || cmp=$?`
    # （成功不进入 || 分支，cmp 会保留上一轮的旧值）
    if manager_version_cmp "$best" "$v"; then
      cmp=0
    else
      cmp=$?
    fi
    case "$cmp" in
      0) best="$v"; best_list="$base" ;;          # v 更新 → 换成它
      1) best_list="$best_list,$base" ;;          # 相同 → 并列最新
    esac
  done <<<"$lines"

  REMOTE_VERSION="$best"
  REMOTE_FRESH_BASES="$best_list"
  [[ -n "$best" ]]
}

# 并发抢速：向所有候选地址同时请求同一个文件，最先完整落地者胜出。
# RACE_PREFER_BASES（逗号分隔）里的来源优先，其余按原顺序垫后 ——
# 用来把“版本过期（命中 CDN 缓存）的来源”排到后面，避免装上旧安装器。
# mode=file   → 内容写入 dest，并在 stdout 打印胜出的基础地址
# mode=stdout → 内容打印到 stdout
manager_race_fetch_once(){
  local mode="$1" dest="$2" rel="$3"; shift 3
  local -a bases=() urls=() outs=() pids=()
  local -a prefer=() keep=()
  local i n=0 won=-1 alive=0 deadline dir line="" b p hit=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    bases+=("$line")
  done < <(manager_candidate_bases)
  n=${#bases[@]}
  (( n )) || return 1

  if [[ -n "${RACE_PREFER_BASES:-}" ]]; then
    # 只在这些来源里抢速：命中 CDN 缓存的旧源再快也不能让它先落地。
    # 它们全都取不到时返回失败，由调用方退回“全量候选”再试一次。
    IFS=',' read -r -a prefer <<<"$RACE_PREFER_BASES"
    for b in ${bases[@]+"${bases[@]}"}; do
      hit=0
      for p in ${prefer[@]+"${prefer[@]}"}; do
        if [[ "$b" == "$p" ]]; then hit=1; break; fi
      done
      (( hit )) && keep+=("$b")
    done
    bases=()
    for b in ${keep[@]+"${keep[@]}"}; do bases+=("$b"); done
    n=${#bases[@]}
    (( n )) || { rm -rf "$dir" 2>/dev/null || true; return 1; }
  fi

  for ((i=0;i<n;i++)); do urls[i]="$(manager_bust_url "${bases[$i]%/}/$rel")"; done

  dir="$(mktemp -d "${TMPDIR:-/tmp}/sbx-manager-race.XXXXXX")"
  for ((i=0;i<n;i++)); do
    outs[i]="$dir/$i"
    (
      curl "$@" -fsSL --connect-timeout 8 --max-time "$UPDATE_RACE_TIMEOUT" \
        "${urls[$i]}" -o "${outs[$i]}.part" && mv -f "${outs[$i]}.part" "${outs[$i]}"
    ) >/dev/null 2>&1 &
    pids[i]=$!
  done
  deadline=$(( SECONDS + UPDATE_RACE_TIMEOUT + 10 ))
  while (( SECONDS < deadline )); do
    for ((i=0;i<n;i++)); do
      if [[ -s "${outs[$i]}" ]]; then won=$i; break 2; fi
    done
    alive=0
    for ((i=0;i<n;i++)); do
      if kill -0 "${pids[i]}" 2>/dev/null; then alive=1; break; fi
    done
    if (( alive == 0 )); then break; fi
    sleep 0.2
  done
  for ((i=0;i<n;i++)); do kill "${pids[i]}" 2>/dev/null || true; done
  wait >/dev/null 2>&1 || true

  if (( won < 0 )); then
    rm -rf "$dir"
    return 1
  fi
  if [[ "$mode" == "file" ]]; then
    cp -f "${outs[$won]}" "$dest"
    printf '%s\n' "${bases[$won]}"
  else
    cat "${outs[$won]}"
  fi
  rm -rf "$dir"
  return 0
}

# 直连抢速失败后，再走本机 sing-box 代理抢一次；
# 还不行就 -q 忽略 ~/.curlrc（用户按 sbx proxy curl on 配了代理但 sing-box 没运行时，
# 不忽略配置会让更新完全走不动）。
manager_race_fetch(){
  local mode="$1" dest="$2" rel="$3" out="" proxy=""
  if out="$(manager_race_fetch_once "$mode" "$dest" "$rel")"; then
    printf '%s\n' "$out"
    return 0
  fi
  proxy="$(manager_proxy_url)"
  warn "直连更新源失败，尝试通过本机 sing-box: $proxy"
  if out="$(manager_race_fetch_once "$mode" "$dest" "$rel" --proxy "$proxy")"; then
    printf '%s\n' "$out"
    return 0
  fi
  warn "仍失败，忽略 curl 配置（-q）再试一轮..."
  if out="$(manager_race_fetch_once "$mode" "$dest" "$rel" -q)"; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

manager_remote_version(){
  manager_resolve_remote_version || return 1
  printf '%s\n' "$REMOTE_VERSION"
}

# 版本号比较（纯 bash，不依赖 GNU sort -V；busybox 环境也不会静默失效）：
#   远端更新 → 0；相同 → 1；远端更旧 → 2；无法解析 → 3
manager_version_cmp(){
  local local_v="$1" remote_v="$2" lc rci n i ln rn
  local -a lparts=() rparts=()
  lc="${local_v#v}"; lc="${lc#V}"
  rci="${remote_v#v}"; rci="${rci#V}"
  lc="${lc%%[^0-9.]*}"      # 去掉 "-rc1" 之类后缀与尾部空白
  rci="${rci%%[^0-9.]*}"
  [[ "$lc" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 3
  [[ "$rci" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 3
  IFS='.' read -r -a lparts <<< "$lc"
  IFS='.' read -r -a rparts <<< "$rci"
  n=${#lparts[@]}
  (( ${#rparts[@]} > n )) && n=${#rparts[@]}
  for (( i = 0; i < n; i++ )); do
    ln="${lparts[i]:-0}"; rn="${rparts[i]:-0}"
    if (( 10#$rn > 10#$ln )); then return 0; fi
    if (( 10#$rn < 10#$ln )); then return 2; fi
  done
  # 数字部分相同：字符串也相同才是"已是最新"，否则（0.11.1 与 0.11.1-rc1、0.11 与 0.11.0）按有更新处理
  [[ "$local_v" == "$remote_v" ]] && return 1
  return 0
}

manager_check(){
  command -v curl >/dev/null 2>&1 || die "检查更新需要 curl。"
  local local_v remote_v
  local_v="$(manager_local_version)"
  remote_v="$(manager_remote_version)" || die "无法获取远端版本。"
  printf '当前版本: %s\n远端版本: %s\n' "$local_v" "$remote_v"
  local state=0
  manager_version_cmp "$local_v" "$remote_v" || state=$?
  case "$state" in
    0) printf '状态: 有可用更新\n' ;;
    1) printf '状态: 已是最新版本\n' ;;
    2) printf '状态: 本地版本更新，远端较旧（不会自动降级；确实要降级: sbx manager update --force）\n' ;;
    *) printf '状态: 版本号无法比较（按“有可用更新”处理）\n' ;;
  esac
}

manager_update(){
  command -v curl >/dev/null 2>&1 || die "更新需要 curl。"
  local quiet=0 force=0 arg local_v remote_v tmp
  for arg in "$@"; do
    case "$arg" in
      --quiet) quiet=1 ;;
      --force) force=1 ;;
      *) die "用法: sbx manager update [--quiet] [--force]" ;;
    esac
  done

  local_v="$(manager_local_version)"
  if ! remote_v="$(manager_remote_version)"; then
    ((quiet)) || warn "无法获取远端版本（已尝试全部候选更新源）。"
    return 1
  fi

  # 只有"远端严格更新"才自动执行；远端更旧时不降级（--force 是唯一降级路径）。
  # 版本号无法解析时按"有可用更新"处理，避免解析失败把更新永久挡住。
  local state=0
  manager_version_cmp "$local_v" "$remote_v" || state=$?
  if [[ "$force" != "1" ]]; then
    if (( state == 1 )); then
      ((quiet)) || info "singbox-manager 已是最新版本: $local_v"
      return 0
    fi
    if (( state == 2 )); then
      ((quiet)) || warn "远端版本 $remote_v 比本地 $local_v 更旧，已跳过（确实要降级请加 --force）。"
      return 0
    fi
  fi

  ((quiet)) || info "更新 singbox-manager: $local_v -> $remote_v"
  tmp="$(mktemp /tmp/sbx-manager-update.XXXXXX.sh)"
  trap 'rm -f "$tmp"' RETURN

  # 只从“报告了最新版本的那些来源”里优先取 install.sh：
  # 否则命中 CDN 缓存的旧源可能最快返回，结果装回一个旧安装器
  # （后续 VERSION 校验会失败并报错，但没必要白跑一趟）。
  local src="" preferred="${REMOTE_FRESH_BASES:-}" race_rc=0
  RACE_PREFER_BASES="$preferred"
  src="$(manager_race_fetch file "$tmp" install.sh)" || race_rc=$?
  RACE_PREFER_BASES=""
  if (( race_rc )) && [[ -n "$preferred" ]]; then
    # 报告最新版本的来源全取不到 → 退回全量候选（拿到的可能是旧安装器，
    # 但后面的 VERSION 校验会拦住，不会静默降级）
    ((quiet)) || warn "报告最新版本的来源都取不到 install.sh，退回全部候选源重试..."
    src="$(manager_race_fetch file "$tmp" install.sh)" || race_rc=$?
  fi
  if (( race_rc )); then
    rm -f "$tmp"
    trap - RETURN
    warn "下载 install.sh 失败（已并发尝试全部候选更新源），未做任何改动。"
    return 1
  fi
  if [[ -n "$preferred" ]] && [[ ",$preferred," != *",$src,"* ]]; then
    ((quiet)) || warn "注意: 本次 install.sh 来自 $src，它报告的版本不是最新的（可能命中 CDN 缓存）。"
  fi
  ((quiet)) || info "安装器来源: ${src:-$UPDATE_BASE}"

  # 可选：用固定校验和钉住更新内容。设置了就必须匹配，否则拒绝执行。
  local want_sha="${SBX_UPDATE_SHA256:-}"
  if [[ -n "$want_sha" ]]; then
    if ! command -v sha256sum >/dev/null 2>&1; then
      rm -f "$tmp"; trap - RETURN
      warn "设置了 SBX_UPDATE_SHA256 但系统没有 sha256sum，已中止。"
      return 1
    fi
    local got_sha
    got_sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
    if [[ "$got_sha" != "$want_sha" ]]; then
      rm -f "$tmp"; trap - RETURN
      warn "install.sh 校验和不匹配（期望 $want_sha，实际 ${got_sha:-空}），已中止更新。"
      return 1
    fi
    ((quiet)) || info "install.sh 校验和匹配。"
  fi

  # 调用方可能是 `manager_update || true`（交互菜单），那个上下文会抑制 errexit，
  # 所以必须显式检查退出码，不能依赖 set -e。
  local rc=0
  local -a envs=(
    SBX_MANAGER_ONLY=1
    SBX_NONINTERACTIVE=1
    "SBX_INSTALL_DIR=$HOME_DIR"
    "SBX_BIN_LINK=$UPDATE_BIN_LINK"
    "SBX_INSTALLER_LINK=$UPDATE_INSTALLER_LINK"
    "SBX_REPO=$UPDATE_REPO"
    "SBX_INSTALL_BRANCH=$UPDATE_BRANCH"
  )
  # 显式指定的更新源（自建镜像 / 固定 tag / file://）必须透传；
  # 默认源则让安装器自己做并发测速去抢最快的源（SBX_SOURCE_MIRRORS 等随环境继承）。
  if (( UPDATE_BASE_EXPLICIT )); then
    envs+=("SBX_SOURCE_BASE_URL=$UPDATE_BASE")
  fi
  env "${envs[@]}" bash "$tmp" || rc=$?

  rm -f "$tmp"
  trap - RETURN

  if ((rc)); then
    warn "管理器安装器执行失败（退出码 $rc）；当前安装目录可能处于半更新状态，请重试或改用 sbx-install。"
    return 1
  fi

  # 只比对 VERSION 不足以说明安装完整，必须同时确认代码文件到位
  # （install.sh 已把 VERSION 放在最后安装，两者互为印证）。
  local missing="" f
  for f in bin/sbx lib/sbx_nodes.py lib/sbx_update.sh lib/sbx_verify.py lib/sbx_docker_network.sh VERSION; do
    [[ -s "$HOME_DIR/$f" ]] || missing+="$f "
  done
  if [[ -n "$missing" ]]; then
    warn "管理器更新不完整，缺少或为空: $missing"
    return 1
  fi

  local installed
  installed="$(tr -d '[:space:]' < "$HOME_DIR/VERSION" 2>/dev/null || true)"
  if [[ "$installed" != "$remote_v" ]]; then
    die "更新完成后版本校验失败：期望 $remote_v，实际 ${installed:-unknown}"
  fi

  ((quiet)) || info "管理器已更新到 $installed。"
}

manager_auto_on(){
  command -v systemctl >/dev/null 2>&1 || die "自动更新目前要求 systemd。"
  warn "自动更新会定期从 $UPDATE_REPO/$UPDATE_BRANCH 拉取并执行 manager 更新。"
  warn "只有在你信任该仓库与分支时才应开启。"

  if [[ "${SBX_UPDATE_NO_APPLY:-0}" != "1" ]]; then
    read -r -p '输入 AUTO 确认开启自动更新: ' answer || { warn "未收到确认输入（EOF），已取消。"; return 1; }
    [[ "$answer" == "AUTO" ]] || { warn "已取消。"; return 1; }
  fi

  mkdir -p "$(dirname "$UPDATE_SERVICE_FILE")" "$(dirname "$UPDATE_TIMER_FILE")"

  # 同上：systemd 单元没有 HOME，显式补上，避免脚本里任何 $HOME 在 set -u 下炸掉
  local unit_home
  unit_home="$(getent passwd 0 2>/dev/null | cut -d: -f6 || true)"
  unit_home="${unit_home:-/root}"
  cat > "$UPDATE_SERVICE_FILE" <<EOF
[Unit]
Description=singbox-manager self update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="SBX_UPDATE_REPO=$UPDATE_REPO"
Environment="SBX_UPDATE_BRANCH=$UPDATE_BRANCH"
Environment="SBX_UPDATE_BASE_URL=$UPDATE_BASE"
Environment="HOME=$unit_home"
ExecStart=$UPDATE_BIN_LINK manager update --quiet
EOF

  cat > "$UPDATE_TIMER_FILE" <<'EOF'
[Unit]
Description=Daily singbox-manager update check

[Timer]
OnBootSec=15min
OnUnitActiveSec=24h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  chmod 644 "$UPDATE_SERVICE_FILE" "$UPDATE_TIMER_FILE"

  if [[ "${SBX_UPDATE_NO_APPLY:-0}" == "1" ]]; then
    info "自动更新 systemd 文件已生成；测试模式未启用 timer。"
    return 0
  fi

  systemctl daemon-reload
  systemctl enable --now singbox-manager-update.timer
  info "自动更新已开启。"
}

manager_auto_off(){
  if command -v systemctl >/dev/null 2>&1 && [[ "${SBX_UPDATE_NO_APPLY:-0}" != "1" ]]; then
    systemctl disable --now singbox-manager-update.timer >/dev/null 2>&1 || true
  fi
  rm -f "$UPDATE_SERVICE_FILE" "$UPDATE_TIMER_FILE"
  if command -v systemctl >/dev/null 2>&1 && [[ "${SBX_UPDATE_NO_APPLY:-0}" != "1" ]]; then
    systemctl daemon-reload
  fi
  info "自动更新已关闭。"
}

manager_auto_status(){
  printf '当前版本: %s\n' "$(manager_local_version)"
  printf '更新源:   %s\n' "$UPDATE_BASE"
  if [[ -f "$UPDATE_TIMER_FILE" ]]; then
    printf '自动更新: CONFIGURED\n'
    if command -v systemctl >/dev/null 2>&1; then
      systemctl is-enabled singbox-manager-update.timer 2>/dev/null | sed 's/^/systemd:   /' || true
      systemctl list-timers singbox-manager-update.timer --no-pager 2>/dev/null || true
    fi
  else
    printf '自动更新: OFF\n'
  fi
}

manager_menu(){
  local x action
  while true; do
    clear
    menu_title '管理器更新'
    menu_note "当前版本: $(manager_local_version)"
    menu_block '手动更新' <<'EOF'
   1  检查更新    查询远端是否有新版本
   2  立即更新    更新管理器自身
   3  强制重装    重装/降级到远端版本
EOF
    menu_block '自动更新' <<'EOF'
   4  自动更新    开启 / 关闭 / 状态
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) manager_check || true ;;
      2) manager_update || true ;;
      3) manager_update --force || true ;;
      4)
        read -r -p '自动更新: 1 开启 / 2 关闭 / 3 状态: ' action
        case "$action" in
          1) manager_auto_on || true ;;
          2) manager_auto_off || true ;;
          3) manager_auto_status || true ;;
          *) warn "无效选项" ;;
        esac
        ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

manager_cmd(){
  local op="${1:-menu}"
  shift || true
  case "$op" in
    menu) manager_menu ;;
    check) manager_check ;;
    update) manager_update "$@" ;;
    version) manager_local_version; printf '\n' ;;
    auto)
      case "${1:-status}" in
        on) manager_auto_on ;;
        off) manager_auto_off ;;
        status) manager_auto_status ;;
        *) die "用法: sbx manager auto on|off|status" ;;
      esac
      ;;
    help|-h|--help)
      cat <<'EOF'
sbx manager check               检查 manager 更新
sbx manager update              立即更新 manager，不动 sing-box 镜像/节点
sbx manager update --force      强制重装/降级到远端版本（唯一会降级的路径）
sbx manager auto on             开启每日自动更新
sbx manager auto off            关闭自动更新
sbx manager auto status         查看自动更新状态
sbx self-update                 sbx manager update 的快捷别名
sbx-install                     获取最新 install.sh 并执行完整安装/升级

更新与安装都会先并发测速多个来源（官方 raw / jsDelivr / 整包），取最快者。

可用的环境变量（用于固定更新源/校验内容/调整抢速）：
SBX_UPDATE_REPO / SBX_UPDATE_BRANCH / SBX_UPDATE_BASE_URL   替换更新源（可指向自己的镜像或 tag）
SBX_UPDATE_SHA256=<sha256>                                  校验 install.sh 后再执行
SBX_SOURCE_MIRRORS=<base>                                   附加候选源（参与抢速，空格或逗号分隔）
SBX_MIRROR_PRESET=1                                         额外加入公共 GitHub 加速站参与抢速（默认关闭）
SBX_SOURCE_NO_RACE=1                                        关闭抢速，恢复按默认顺序逐个试
EOF
      ;;
    *) die "未知 manager 命令: $op" ;;
  esac
}

version(){
  printf 'singbox-manager: %s\npinned sing-box: %s\nimage: %s\nstrategy: %s\nroute: %s\ncustom inbounds: %s\nproxy: %s\n'     "$(manager_local_version)" "$(image_version)" "$(image_ref)"     "$(python3 "$HELPER" strategy)" "$(python3 "$HELPER" route-mode)"     "$(python3 "$HELPER" inbound-endpoints --json 2>/dev/null | python3 -c 'import json,sys; print(max(0,len(json.load(sys.stdin))-1))' 2>/dev/null || printf '0')"     "$(proxy_url)"
}

# ── 交互子菜单 ──────────────────────────────────────────────────────────────
# 条目版式约定见 lib/sbx_v3.sh 顶部注释：编号 + 名称(补到 10 显示列) + 说明(≤24 显示列)。
# 菜单里的动作一律带 `|| true`：单个操作失败不应该把整个菜单一起带崩。

backup_list(){ # 按时间倒序列出已有备份（最新的排最前）
  local f p
  # shellcheck disable=SC2012  # 备份名固定是 sbx-<时间戳>.tar.gz，ls 足够，也不会遇到特殊文件名
  f=$(ls -1t "$BACKUPS"/sbx-*.tar.gz 2>/dev/null || true)
  if [[ -z "$f" ]]; then info "还没有备份。"; return 0; fi
  info "备份目录: $BACKUPS"
  while IFS= read -r p; do
    printf '  %s  %s\n' "$(basename "$p")" "$(du -h "$p" 2>/dev/null | cut -f1)"
  done <<< "$f"
}

install_info(){
  printf '\n安装目录: %s\n版本:     %s\n' "$HOME_DIR" "$(manager_local_version)"
  printf '配置文件: %s\n节点库:   %s\n环境变量: %s\n备份目录: %s\n' "$CONFIG" "$NODES" "$ENV" "$BACKUPS"
  printf '镜像:     %s\n' "$(image_ref)"
  printf '看日志:   docker compose --project-directory %s logs -f sing-box\n\n' "$HOME_DIR"
}

service_menu(){
  local x
  while true; do
    clear
    menu_title '服务'
    if running 2>/dev/null; then menu_note '当前状态: 运行中'; else menu_note '当前状态: 已停止'; fi
    menu_block '容器' <<'EOF'
   1  状态        容器与服务当前状态
   2  日志        跟踪最近 100 行
   3  启动        启动 sing-box 容器
   4  停止        停止 sing-box 容器
   5  重启        重启容器（不重建配置）
EOF
    menu_block '配置' <<'EOF'
   6  重建配置    按节点库重新生成并重启
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) status || true ;;
      2) logs || true ;;
      3) start || true ;;
      4) stop || true ;;
      5) restart || true ;;
      6) node render || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

diagnose_menu(){
  local x
  while true; do
    clear
    menu_title '检查与诊断'
    menu_block '检查' <<'EOF'
   1  配置检查    sing-box check 校验配置
   2  代理测试    经当前出口请求一次外网
   3  系统诊断    容器/入口/Docker 体检
EOF
    menu_block '信息' <<'EOF'
   4  版本        管理器 / sing-box / 镜像
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) check || true ;;
      2) test_current || true ;;
      3) python3 "$HOME_DIR/lib/sbx_verify.py" doctor || true ;;
      4) version || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

upgrade_menu(){
  local x v
  while true; do
    clear
    menu_title '升级'
    menu_note "管理器 $(manager_local_version)    sing-box $(image_version)"
    menu_block 'sing-box' <<'EOF'
   1  升级        指定目标版本并重建
   2  拉镜像      重新 pull .env 里的镜像
EOF
    menu_block '管理器' <<'EOF'
   3  检查更新    查询远端是否有新版本
   4  立即更新    更新管理器自身
   5  强制重装    重装/降级到远端版本
   6  自动更新    开启 / 关闭 / 状态
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) read -r -p 'sing-box 目标版本: ' v; [[ -n "$v" ]] && { upgrade "$v" || true; } ;;
      2) pull || true ;;
      3) manager_check || true ;;
      4) manager_update || true ;;
      5) manager_update --force || true ;;
      6)
        read -r -p '自动更新: 1 开启 / 2 关闭 / 3 状态: ' v
        case "$v" in
          1) manager_auto_on || true ;;
          2) manager_auto_off || true ;;
          3) manager_auto_status || true ;;
          *) warn "无效选项" ;;
        esac
        ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

backup_menu(){
  local x f
  while true; do
    clear
    menu_title '备份与恢复'
    menu_note "备份目录: $BACKUPS"
    menu_block '操作' <<'EOF'
   1  创建备份    打包配置 / 节点 / .env
   2  从备份恢复  留空 = 最近一个备份
   3  备份列表    列出已有备份与大小
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) backup || true ;;
      2) read -r -p '备份文件名（留空 = 最近一个）: ' f; restore "$f" || true ;;
      3) backup_list || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

advanced_menu(){
  local x
  while true; do
    clear
    menu_title '高级'
    menu_block '工具' <<'EOF'
   1  手工编辑    直接改 config.json
   2  安装信息    目录 / 版本 / 数据文件
   3  命令速查    全部非交互子命令
EOF
    menu_footer '0  返回'
    menu_end
    read -r -p '请选择: ' x || return
    case "$x" in
      1) edit || true ;;
      2) install_info || true ;;
      3) help || true ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
    [[ "$x" != 0 ]] && pause
  done
}

# 主菜单：23 项收敛到 11 项。分组按「你要做什么」而不是内部模块，每项都带一行说明，
# 不必先点进去才知道它是干什么的。两处改名消歧：
#   宿主机代理 = 宿主机的 Docker/Git/APT/npm/curl 走代理
#   容器接入   = 其它容器共享 sing-box 出口
menu(){
  local x
  while true; do
    clear
    menu_title "singbox-manager $(manager_local_version)"
    if running 2>/dev/null; then menu_note 'sing-box: 运行中'; else menu_note 'sing-box: 已停止'; fi
    menu_block '日常' <<'EOF'
   1  节点        列表 / 增删改 / 测试
   2  订阅与导入  订阅 / 分享链接导入
   3  出口与分流  出口策略 / 路由模式
   4  服务        状态 / 日志 / 启停
EOF
    menu_block '接入' <<'EOF'
   5  入口路由    多个入口绑定出口
   6  宿主机代理  让 Docker/Git/APT 走代理
   7  容器接入    其它容器共享出口
EOF
    menu_block '维护' <<'EOF'
   8  检查与诊断  配置检查 / 代理测试
   9  升级        sing-box / 镜像 / 管理器
  10  备份与恢复  备份 / 恢复 / 列表
  11  高级        手工编辑 / 安装信息
EOF
    menu_footer '0  退出'
    menu_end
    read -r -p '请选择: ' x || exit
    case "$x" in
      1) node_menu; continue ;;
      2) subs_import_menu; continue ;;
      3) outlet_menu; continue ;;
      4) service_menu; continue ;;
      5) inbound_menu; continue ;;
      6) proxy_menu; continue ;;
      7) docker_network_menu; continue ;;
      8) diagnose_menu; continue ;;
      9) upgrade_menu; continue ;;
      10) backup_menu; continue ;;
      11) advanced_menu; continue ;;
      0) exit ;;
      *) warn "无效选项" ;;
    esac
    pause
  done
}

help(){
  cat <<'EOF'
sbx                                  交互菜单
sbx node                             节点管理（列表里的序号就是操作时填的值）
sbx node list [--ids]                节点列表；--ids 才显示内部 ID
sbx node edit|delete|default|show|test <序号|名称>
                                     按序号操作节点，例如 sbx node test 2
sbx reapply                          按现有节点库重新生成配置并重启 sing-box
sbx inbound                          多入口 -> 出口路由管理
sbx import uri|file                  分享链接 / 文件导入
sbx subscription                     订阅管理
sbx strategy manual|auto
sbx route global|cn-direct-lite|cn-direct-full
sbx proxy                            Docker/Git/APT/npm 应用代理
sbx image status|bootstrap|pull|load
sbx manager                          管理器更新菜单
sbx manager check|update
sbx manager auto on|off|status
sbx docker-network                    Docker 容器共享代理网络
sbx doctor                            一键诊断 sing-box / 入口 / Docker 代理
sbx self-update                      快速更新 singbox-manager
sbx-install                          获取最新安装器并完整安装/升级
sbx status/start/stop/restart/logs/check/test
sbx backup/restore [file]
sbx version
sbx upgrade <version>                升级 sing-box
sbx pull                             拉取当前 sing-box 镜像
EOF
}

main(){
  root "$@"
  local cmd="${1:-menu}"
  shift || true

  local lightweight=0
  case "$cmd" in
    manager|self-update|doctor) lightweight=1 ;;
    proxy)
      case "${1:-menu}:${2:-}" in
        status:*|env:*|help:*|-h:*|--help:*|*:off) lightweight=1 ;;
      esac
      ;;
  esac

  if ((lightweight)); then
    [[ -d "$HOME_DIR" ]] || die "未找到 $HOME_DIR，请先安装 singbox-manager。"
  else
    ready
  fi

  mkdir -p "$PROXY_STATE_DIR"
  chmod 700 "$PROXY_STATE_DIR" 2>/dev/null || true

  case "$cmd" in
    menu) menu ;;
    node) node "$@" ;;
    apply|reapply|reload) node render ;;
    inbound|in) inbound_cmd "$@" ;;
    import) import_cmd "$@" ;;
    subscription|sub) subscription "$@" ;;
    strategy) strategy "${1:-}" ;;
    route) route_mode "${1:-}" ;;
    urltest) urltest "$@" ;;
    proxy) proxy_cmd "$@" ;;
    image) image_cmd "$@" ;;
    manager) manager_cmd "$@" ;;
    self-update) manager_update "$@" ;;
    docker-network|dnet) docker_network_cmd "$@" ;;
    doctor) python3 "$HOME_DIR/lib/sbx_verify.py" doctor ;;
    status|ps) status ;;
    start|up) start ;;
    stop|down) stop ;;
    restart) restart ;;
    logs|log) logs ;;
    check) check ;;
    test) test_current ;;
    backup) backup ;;
    restore) restore "${1:-}" ;;
    version|-v|--version) version ;;
    upgrade) upgrade "${1:-}" ;;
    pull|update) pull ;;
    edit|config) edit ;;
    help|-h|--help) help ;;
    *) die "未知命令: $cmd" ;;
  esac
}
