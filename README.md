# singbox-manager

面向 Linux 服务器的 sing-box Docker 管理层。sing-box 保持官方镜像运行，宿主机通过 `sbx` 完成安装、节点管理、配置生成、校验、测试、备份恢复与升级。

当前版本：**0.11.6**

## 一键交互式安装

推荐直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/singbox-manager/main/install.sh -o /tmp/sbx-install.sh && sudo bash /tmp/sbx-install.sh
```

安装器会交互询问：

- sing-box 版本
- 本地监听地址（必须是 IPv4/IPv6 地址，例如 `127.0.0.1`）
- mixed HTTP/SOCKS5 端口（1–65535）
- Docker 未安装时是否自动安装
- 是否立即拉取镜像
- 是否立即添加第一个代理节点
- 是否立即启动 sing-box

默认安装目录：

```text
/opt/singbox-manager
```

管理命令：

```text
/usr/local/bin/sbx
```

已有安装再次运行安装器时，会更新管理器文件，同时保留本机 `.env`、节点库和运行配置（包括自定义的 `SING_BOX_CONTAINER_NAME`，不会被重置回 `sing-box`）。

### 重复运行（升级）时不再重新配置

检测到已有安装后，安装器**直接沿用现有 `.env`**，不再逐项询问 sing-box 版本 / 监听地址 / 端口：

- 只在镜像缺失时才询问是否准备镜像；
- 只在节点库为空时才询问是否添加第一个节点；
- **如果 sing-box 正在运行，会自动重新生成配置并重启**，让新脚本与新生成的配置立即生效（不再问“是否立即启动”）。

要修改版本 / 监听地址 / 端口（回到交互式逐项询问）：

```bash
SBX_RECONFIGURE=1 bash install.sh
# 或
SBX_RECONFIGURE=1 sbx-install
```

自动化场景可再加 `SBX_ASSUME_YES=1`，所有确认都取默认值，全程无交互。

只想让改动生效、不重跑安装器时：

```bash
sbx reapply
```

它会按现有节点库重新生成 `config/config.json`、跑 `sing-box check`，通过后重启正在运行的 sing-box；不重装管理器，也不改 `.env`。

### 安装时的输入校验

- 监听地址必须是 IPv4/IPv6 地址字面量（`127.0.0.1`、`::1` 等），端口必须是 1–65535 的整数；非法值会立即报错，而不是写进 `.env`、等到 `sbx start` 时才由 Docker 报错。
- 使用 `0.0.0.0` 或 `::` 会把代理端口暴露到所有网卡，安装器会给出安全警告。
- 非交互模式（`SBX_NONINTERACTIVE=1`；`SBX_MANAGER_ONLY=1` 会自动隐含）下无法重新输入，因此 `.env` 中的非法端口或监听地址会**直接失败并提示修正**，不会停在提示符上等待输入。

### 安装失败时会做什么

- 写入新 `.env` 之前会先备份：若随后的节点库校验失败（例如 `nodes.json` 含当前版本不支持的协议），会**回滚 `.env`**、保留已装好的管理器文件，以非零状态退出并提示先修复 `nodes/nodes.json`。
- `VERSION` 文件在最后一步写入，因此“`VERSION` 已是新值”可以认为管理器文件已经装全。
- 只更新管理器的流程（`sbx manager update`）不再询问、也不再校验 sing-box 版本与端口，因此 `.env` 里即使是 `SING_BOX_VERSION=latest` 也不会阻塞管理器更新。

## 节点管理

进入菜单：

```bash
sbx node
```

也可直接使用：

```bash
sbx node list            # 只看列表（默认不显示内部 ID）
sbx node list --ids      # 需要排障/写脚本时，额外显示内部 ID
sbx node add
sbx node edit <序号>
sbx node delete <序号>
sbx node default <序号>
sbx node show <序号>
sbx node test <序号>
sbx node render
```

列表里的第一列就是操作时要填的序号（节点库顺序，从 1 开始）：

```text
默认  序号   协议          名称                    来源          地址
------------------------------------------------------------------------------------------------
      1      vless         美国【优化|×3】          import-uri    38.47.116.141:32242
*     2      shadowsocks   香港【ix|×4】            import-uri    5434se.viaspeed.shop:27644
```

```bash
sbx node test 2          # 测试第 2 个节点（就是上面标记 * 的默认节点）
             # 直接回车则先打印列表，再输入序号选择
```

交互层用序号，持久层仍然是 8 位节点 ID：序号只是"当前这份节点库里的第几个"，导入/删除节点后序号会跟着变化；节点 ID 只作为内部唯一标识保存（`sbx node list --ids` 或 `sbx node show <序号>` 可见），用于入口绑定、订阅迁移和 `docker-managed.json`。按名称操作仍然可用，脚本里继续传 ID 也不会失效。

当前交互式节点类型：

- Shadowsocks
- VLESS
- Trojan
- Hysteria2
- SOCKS5

VLESS 支持 TLS、Reality，以及 TCP / WebSocket / gRPC / HTTPUpgrade 传输；Trojan 支持 TLS 和上述传输；Hysteria2 支持 TLS 与 Salamander obfs。

节点凭据仅保存在本机：

```text
/opt/singbox-manager/nodes/nodes.json
```

该文件以及实际生成的 `config/config.json` 都被 `.gitignore` 排除。

节点名称在当前节点库内必须唯一：新增/编辑时会拒绝重名，因为重名会让按名称的操作无法确定目标。确实需要同名时，请改用序号操作（`sbx node edit 2`）。

## 配置生成与回滚

节点操作采用事务式流程：

```text
备份当前状态
  ↓
修改 nodes.json
  ↓
重新生成 config.json
  ↓
sing-box check
  ↓
成功 → 生效 / 运行中则自动重启
失败 → 自动恢复旧 nodes.json + config.json
```

默认节点会成为 sing-box 的最终出站；没有节点时默认走 direct。

所有会改写节点库的命令（`add` / `edit` / `delete` / `default` / `render` / 导入 / 订阅 / 入口 / 策略等）在改写期间对节点库加锁，只读命令不受影响。两个终端（或脚本与交互界面）同时操作不会互相覆盖；等待超时会明确提示“节点库正被其它进程占用，请稍后重试”。锁文件是 `nodes/.sbx-nodes.lock`，仅用于加锁，可以随时删除。

落盘顺序是「先渲染 `config.json`，成功后才写入 `nodes.json`」，所以生成失败不会留下“节点库已改、配置没跟上”的不一致状态；删除最后一个节点时，指向 `proxy`/`auto` 的入口会自动回退为 `direct`，保证节点库始终可校验。

## 单节点真实测试

`sbx node test` 会：

1. 为指定节点生成临时 sing-box 配置；
2. 使用当前固定版本镜像执行 `sing-box check`；
3. 启动隔离的临时 sing-box 容器；
4. 将临时 mixed 代理映射到随机本地端口；
5. 通过该节点访问国际 HTTPS 站点；
6. 尝试获取出口 IP；
7. 删除临时容器和配置。

例如：

```bash
sbx node test
sbx node test 12ab34cd
sbx node test Tokyo-01
```


## 分享链接与订阅导入

现在可以直接导入常见节点分享链接：

```bash
sbx import uri
```

也可以把 URI 直接作为参数传入：

```bash
sbx import uri 'vless://...'
```

当前支持导入：

- Shadowsocks `ss://`
- VLESS `vless://`
- Trojan `trojan://`
- Hysteria2 `hysteria2://` / `hy2://`
- SOCKS5 `socks://` / `socks5://`

订阅管理：

```bash
sbx subscription
sbx subscription add
sbx subscription list
sbx subscription update
sbx subscription delete
```

订阅内容支持逐行 URI 列表，也支持整段 Base64 编码的 URI 列表。更新订阅时只替换该订阅上一次导入的节点，不会清空手工节点或其他订阅节点。

订阅 URL 会作为本机敏感配置保存在 `nodes/nodes.json`，不会提交到 Git。下载订阅时会先尝试直连；如果直连失败且当前 sing-box 正在运行，会自动通过本机 sing-box 再尝试一次。

## 自动测速与出口策略

每个真实节点会进入一个 sing-box `urltest` 出站组 `auto`，同时由 `selector` 出站组 `proxy` 统一作为路由出口。

默认仍然保持手动策略：

```bash
sbx strategy manual
```

开启自动测速：

```bash
sbx strategy auto
```

修改 URLTest 参数：

```bash
sbx urltest \
  --url https://www.gstatic.com/generate_204 \
  --interval 3m \
  --tolerance 50
```

切回某个手动节点时，`sbx node default <节点>` 会自动把策略切回 `manual`。

## 路由模板

提供三档模式：

```bash
sbx route global
sbx route cn-direct-lite
sbx route cn-direct-full
```

- `global`：私网地址直连，其余流量走 `proxy`。
- `cn-direct-lite`：在 global 基础上增加 `.cn` 域名直连，不依赖外部规则集。
- `cn-direct-full`：增加中国 GeoIP / Geosite 二进制 rule-set，用于更完整的国内直连；首次使用需要能够下载规则集。

升级到 0.3 后不会自动改变原有流量策略：旧节点库会迁移到新格式，但默认保持 `manual + global`，需要你主动开启 `auto` 或国内直连模式。















## 0.11.6：curl 也接入宿主机应用代理

0.4 起 `sbx proxy` 能一键把 Docker / Git / APT / npm 接到本机 sing-box，但 **curl 一直不在里面**——而本管理器的安装、`sbx-install`、`sbx self-update` 全都是 curl。

现在多一项：

```bash
sbx proxy curl on     # 写 ~/.curlrc
sbx proxy curl off    # 只删本管理器写入的块
sbx proxy all on      # 包含 curl
sbx proxy status      # 多一行 curl 状态与文件路径
```

写入内容（只动自己的块，用户原有的 `~/.curlrc` 配置原样保留）：

```text
# >>> singbox-manager proxy >>>
proxy = http://127.0.0.1:7890
noproxy = localhost,127.0.0.1,::1
# <<< singbox-manager proxy <<<
```

几点说明：

- curl 只读**用户级**配置（没有 `/etc/curlrc` 这种系统级文件），所以写的是 `${CURL_HOME:-$HOME}/.curlrc`；路径可用 `SBX_CURLRC_FILE` 覆盖，`sbx proxy status` 会打印实际使用的文件。
- 生效范围比 Shell 环境变量更广：`cron`、`systemd` 服务、`sudo` 里跑的 curl（只要 `HOME` 对得上）都会走代理。
- `noproxy` 保证访问 `127.0.0.1` 这类本地地址不会绕进代理。
- 关掉 sing-box 后这些 curl 会连不上代理——所以安装器都加了兜底（见下）。

### 代理配了但不可用时的兜底

`install.sh`、`sbx-install`、`sbx self-update` 现在都会在“直连 + 本机 sing-box 代理”都失败后，再用 `curl -q`（**忽略 `~/.curlrc`**）重试一轮：

```text
直连（会用 ~/.curlrc 里的代理）
   ↓ 失败
--proxy http://127.0.0.1:7890
   ↓ 失败
-q 真直连（忽略 curl 配置）
```

因此即使你的 `~/.curlrc` 指向一个已经停掉的代理，也不会出现“连修复用的安装器都下不来”。`install.sh` 在这轮还会用 `-q` 重新测速排序，避免第一轮探测全失败导致候选退化成默认顺序。

## 0.11.5：修复“CDN 缓存让更新看起来不存在”

0.11.3 给更新路径引入并发抢速后带出一个 bug：**取“最快返回者”会输给命中 CDN 缓存的旧内容**。

jsDelivr 对 `@main` 这类分支路径有约 12 小时的缓存，raw 的 CDN 也有几分钟缓存。发版后 `sbx self-update` 会出现：

```text
当前版本: 0.11.4
远端版本: 0.11.2      <- jsDelivr 缓存里的旧 VERSION，它比 raw 快，所以被采信
状态: 本地版本更新，远端较旧（不会自动降级）
```

于是“明明有新版本，却提示没有更新”。现在改成：

```text
远端版本 = 所有候选源里“最大的那个版本号”（不是最快返回的那个）
```

并且所有下载都先问一次各候选源的 `VERSION`：

```text
报告了最新版本的源   → 参与抢速（在这批里取最快）
报告更旧版本的源     → 不参与；只有最新那批全部失败时才退回去用（并发警告）
探测不到版本（整包源）→ 不降级，照常参与
```

覆盖范围：

- `sbx manager check` / `sbx self-update`：远端版本取最大值；install.sh 只在“报告最新版本”的源里抢速
- `sbx-install`：同样只在最新版本那批源里抢 install.sh
- `install.sh`：逐文件源里报告更旧版本的（典型是命中缓存的 jsDelivr）降到候选末尾，只有其余源都取不到时才会用到它
- 所有 per-file / VERSION 请求都带缓存破坏参数（`?sbx=<时间戳>`），raw 的单文件缓存也不会再喂旧内容；`file://` 之类的地址不受影响

补充说明两点：

- 判断“是否更新”仍用严格版本比较（`0.11.1` 与 `0.11.1-rc1` 按有更新处理）；判断“某个源是否过期”只比数字部分，避免同一个版本号的不同后缀被误判。
- 更新完成后依旧校验安装出的 `VERSION` 必须等于远端版本，所以退回旧源也不会静默降级。

## 0.11.4：节点改用序号操作，ID 退到内部

节点操作不再要求你记 8 位 ID，也不需要先复制 ID 再粘贴：

```text
默认  序号   协议          名称                    来源          地址
------------------------------------------------------------------------------------------------
      1      vless         美国【优化|×3】          import-uri    38.47.116.141:32242
*     2      shadowsocks   香港【ix|×4】            import-uri    5434se.viaspeed.shop:27644
```

`sbx node` 菜单里 编辑 / 删除 / 默认 / 详情 / 测试 都只问序号（直接回车会先打印列表再让你输序号）：

```text
序号(留空可列表选择): 2
```

CLI 同样收序号：

```bash
sbx node test 2
sbx node default 1
sbx node delete 3
```

层次划分和 [0.10.1 的入口序号](#0101代理入口改为序号选择)保持一致：

```text
交互层：序号（1..N，节点库顺序）
持久层：节点 ID（8 位，仅内部使用）
```

- `sbx node list` 默认不再显示 ID；需要排障或写脚本时用 `sbx node list --ids`。
- 入口出口选择（`sbx inbound`）、`target node:<...>` 也改成按序号或名称，例如 `--target node:2`。
- 添加/导入的提示从 `（ID）` 改为 `（序号 N）`。
- 按名称/ID 的老用法仍然兼容：`sbx node test 香港【ix|×4】`、脚本里传 ID 都还能用；重名节点改用序号即可。
- 解析顺序是 **完整 ID → 序号 → ID 前缀 → 名称**，所以 8 位全数字的节点 ID（例如 `11111111`）不会被误当成序号；反之 `1`/`2` 这种不会出现在生成的 ID 里的输入按序号解释。
- 序号会随导入/删除变化，跨时间引用请用名称；入口绑定、订阅迁移、`docker-managed.json` 里保存的始终是节点 ID，不受序号变化影响。

## 0.11.3：安装源并发测速，自动选最快

源码获取不再是“先 raw、失败才 archive”的顺序试探，而是**先把所有候选源并发测速，再按实测吞吐排序取最快**：

```text
并发测速（逐文件源取同一个探测文件，整包源取整包，单源最长 6s）
        ↓ 按实测吞吐排名（有响应的按速度降序，其余保持原顺序作为后备）
按排名并发下载源码（默认 3 个文件同时下）—— 某个源取某个文件失败，立刻切到下一名
        ↓ 全部逐文件源都不行
archive 整包兜底
```

文件级切换解决的是最常见的失败形态：raw 源下到一半某个文件超时（例如 `lib/sbx_v3.sh`），旧版本会让整个安装失败或全部重来，现在只有那一个文件换源，其余继续用最快的源。

并发下载解决的是另一个形态：慢链路上 17 个文件逐个串行下载会把 RTT 和限速叠加起来。默认 3 个文件并发（`SBX_SOURCE_CONCURRENCY` 可调，设为 1 即回到顺序下载）。

默认参与测速的候选源都是官方/可信来源：

```text
raw.githubusercontent.com/<repo>/<branch>      官方 raw，逐文件
github.com/<repo>/archive/refs/heads/<br>.tar.gz  官方整包
codeload.github.com/<repo>/tar.gz/refs/heads/<br>  官方整包（省一次跳转）
cdn.jsdelivr.net/gh/<repo>@<branch>            jsDelivr CDN，逐文件
```

实际输出示例（国内慢链路机器）：

```text
[INFO] 正在并发测速 4 个候选源（单源最长 6s）...
[INFO] 测速结果: codeload 118.2KB/s | jsdelivr 76.5KB/s | github-archive 68.9KB/s | raw 15.0KB/s → 首选 codeload
[INFO] 源码已通过整包源 codeload 准备完成。
```

同一机制也用在另外两个入口：

```text
sbx-install      并发请求多个 install.sh 源，最先完整下载完成的胜出
sbx self-update  install.sh 同样抢速；远端版本号也取自最快源
```

### 相关环境变量

```text
SBX_SOURCE_MIRRORS        自建镜像/加速地址（空格或逗号分隔），参与测速
SBX_MIRROR_PRESET=1       额外加入公共 GitHub 加速站参与测速（默认关闭）
SBX_SOURCE_NO_RACE=1      关闭测速，恢复“按默认顺序逐个试”
SBX_SOURCE_PROBE_TIMEOUT  单源测速上限秒数，默认 6
SBX_SOURCE_FILE_TIMEOUT   单个文件下载上限秒数，默认 30
SBX_SOURCE_ARCHIVE_TIMEOUT 整包下载上限秒数，默认 60
SBX_SOURCE_CONCURRENCY    并发下载的文件数，默认 3（设为 1 即顺序下载）
SBX_ARCHIVE_URL=          显式置空表示关闭整包兜底，只从逐文件源取源码
```

例如把自建镜像加入候选：

```bash
sudo SBX_SOURCE_MIRRORS=https://mirror.example.com/singbox-manager/main \
  bash /tmp/sbx-install.sh
```

一旦显式指定 `SBX_SOURCE_BASE_URL`（或 `SBX_ARCHIVE_URL`），就只在指定地址内取源码与兜底，不会再混入由仓库名推导出来的官方额外候选 —— 避免把两个不同来源的文件混装到一起。显式来源只有一个时不做任何额外请求（保持旧行为）。

### 公共加速站默认关闭

设 `SBX_MIRROR_PRESET=1` 会把以下第三方公共加速站加入测速：

```text
gh-proxy.com  ghproxy.net  ghfast.top  raw.gitmirror.com
```

```bash
SBX_MIRROR_PRESET=1 sbx-install
```

默认关闭的原因：这些站点能改写回给你的文件内容，等于把它们纳入供应链。本仓库不把任何第三方公共镜像站硬编码为默认来源；要用请显式开启，并只使用你信任的站点。

### 已知取舍

- **分支缓存**：jsDelivr 对 `@main` 这类分支路径有约 12 小时的缓存。正常情况下整棵树都取自同一个胜出源，内容自洽；只有在“某个文件在所有源里只有次优源能给”的换源场景下，才可能混入一个稍旧的单个文件。0.11.5 起会先探测各源报告的 `VERSION`、把明显更旧的源降到候选末尾，并给所有请求加上 `?sbx=` 缓存破坏参数，所以这种情况基本不会再命中。要完全可复现，请把分支固定到 tag（`SBX_INSTALL_BRANCH=v0.11.5`）或用 `SBX_SOURCE_NO_RACE=1` 回到顺序取源。
- **测速成本**：每个候选源都会产生一次约一个探测文件大小的流量（整包源受 `SBX_SOURCE_PROBE_TIMEOUT` 限制）；候选越多，第一个字节跑得越快，但总量略增。
- **测速只代表当下**：排名按这次测量的吞吐排序，链路抖动时不一定每次都选同一个源。

## 0.11.2：更新判定改为版本比较

`sbx manager update` / `sbx manager check` 之前用**字符串相等**判断是否需要更新，带来两个后果：版本号不变就永远报“已是最新”（0.11.1 已修），以及**本地版本比远端新时会提示有更新、并把你降级**。

现在改成版本号比较：

```text
远端 > 本地   有可用更新，自动更新会执行
远端 = 本地   已是最新版本
远端 < 本地   本地版本更新；不提示、不降级
无法解析      按“有可用更新”处理，避免解析失败把更新永久挡住
```

比较规则：忽略 `v` 前缀与 `-rc1` 之类的后缀，按 `.` 分段逐段比较（所以 `0.10.9 < 0.11.0` 不再被当成字符串比较）；数字相同但拼写不同（如 `0.11` 与 `0.11.0`）仍按有更新处理。

`sbx manager update --force` 是唯一会降级的路径（例如你确实想回到远端版本）。

## 0.11.1：安装器幂等、并发安全与校验加固

这一版集中修掉一批“看起来能跑、边缘情况下会出错”的问题，并让重复安装/更新不再需要重新配置。

**安装与更新**

- 重复运行安装器时**不再重新询问配置**：识别到已有安装就沿用现有 `.env`，只在镜像缺失或节点库为空时才提问；**sing-box 正在运行则自动重新生成配置并重启**。需要改版本/监听/端口用 `SBX_RECONFIGURE=1`，需要全程无交互用 `SBX_ASSUME_YES=1`。
- 新增 `sbx reapply`：按现有节点库重新生成配置、`sing-box check` 通过后重启正在运行的 sing-box，不重跑安装器、不改 `.env`。
- 管理器自更新补上安装器退出码与关键文件校验，“`VERSION` 已更新、代码没装全”不会再被报告为成功。
- 只更新管理器的流程不再被 `.env` 里的 sing-box 版本串（例如 `latest`）阻塞；非交互模式下非法端口/监听地址会立即失败，不再空转等待输入。
- 安装失败时回滚 `.env`；`VERSION` 最后写入，因此它代表“管理器文件已装全”。
- 重装保留已有 `.env`（含自定义的 `SING_BOX_CONTAINER_NAME`，不再被重置回 `sing-box`）。
- 新增可选 `SBX_UPDATE_SHA256`：校验 `install.sh` 通过后才以 root 执行。

**节点库、并发与校验**

- 所有会改写节点库的命令在改写期间加锁，两个终端（或脚本与界面）同时操作不会互相覆盖。
- 落盘顺序改为“先渲染 `config.json`，成功后才写 `nodes.json`”；删除最后一个节点时，指向 `proxy`/`auto` 的入口自动回退 `direct`，节点库始终可校验。
- 新增/编辑拒绝重名节点；入口名 `default` 作为保留名。
- 订阅更新不再静默替换你设定的默认出口（默认节点按名称跟随迁移）。
- 校验更严：空 `password`/`uuid`、非法端口、坏条目、节点库缺失都会失败并给出可读信息，而不是抛 Python 栈。

**Docker 接入与诊断**

- `verify-all` 默认对每个托管容器做真实出口探测（`--quick` 只做结构检查）；托管状态查不到时会失败并说明原因，不再报“没有托管目标”后返回成功。
- 区分**宿主端口**与**容器内端口**：`SING_BOX_MIXED_PORT` 不是 7890 时，给容器输出的代理地址不会再指错端口。
- 容器名会正确传给 Docker 托管 helper，sing-box 自己不会再被列为可托管目标；托管目标引用的入口消失会明确提示。
- watcher 在 Docker 事件流中断后不再退出；systemd 单元名跟随实际写入路径。

**其它**

- 管理菜单里的操作失败会回到菜单，不再直接结束整个 `sbx` 进程。
- 版本号改为以安装目录的 `VERSION` 文件为唯一来源，去掉多处硬编码。
- CI 增加 shellcheck 门禁（错误级）与“执行已安装 CLI”的步骤，并新增“重复运行安装器不重新配置”的行为测试。

## 0.11：可验证性与一键诊断

0.11 不再增加 Web 面板，重点增强现有 CLI 的“可验证性”。

### 一键诊断

```bash
sbx doctor
```

会依次检查：

```text
manager 版本
节点库 / 生成配置结构
sing-box 实际配置 check
sing-box 容器运行状态
所有代理入口的真实 HTTP 代理请求
Docker 共享网络
sing-box 是否加入共享网络
Docker Watcher
托管目标是否已经接入网络
托管容器应用层快速检查
```

每项输出：

```text
PASS  正常
WARN  网络可用但仍有配置风险 / 无法完全判断
FAIL  明确失败
```

### 验证指定 Docker 容器

```bash
sbx docker-network verify new-api-A
```

会检查：

```text
容器是否运行
singbox-proxy 是否存在
目标容器是否在 singbox-proxy
sing-box 是否在 singbox-proxy
Docker 托管目标绑定的是哪个 inbound_id
该 ID 当前对应哪个端口
容器 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 是否指向正确入口
Docker Watcher 是否运行
从目标容器网络命名空间通过该入口发起真实代理请求
代理出口 IP
```

真实出口测试使用宿主机的 `nsenter + curl` 进入目标容器的网络命名空间，因此不要求目标镜像内部安装 curl、wget 或 Python。

### 验证全部托管容器

```bash
sbx docker-network verify-all
```

默认对每个正在运行的托管容器做真实出口探测，与单容器命令一致：

```bash
sbx docker-network verify <container>
```

只想做结构检查、不重复请求外部 IP 服务时，显式使用快速模式：

```bash
sbx docker-network verify-all --quick
```

如果托管状态**无法查询**（例如缺少 `lib/sbx_docker_targets.py`、托管清单损坏），`verify-all` 与 `sbx doctor` 会失败并打印具体原因，而不是报“没有托管目标”后返回成功——不要把这类情况当成健康。

另外，托管目标引用的入口被删除后不会再静默：`sbx docker-network managed` 会把这些行标成 `MISSING` 并汇总提示，`sbx docker-network sync` 在共享网络已关闭时会直接跳过并说明原因。

### 如何理解结果

仅看到：

```text
CONNECTED
```

只能证明 Docker network membership 已经建立。

真正判断代理链路可用，应至少看到：

```text
PASS  目标容器已加入 singbox-proxy
PASS  sing-box 已加入 singbox-proxy
PASS  托管关系: ... -> [入口ID] ... -> :端口
PASS  从目标容器网络命名空间通过代理访问互联网成功
      代理出口 IP: ...
```

如果同时看到：

```text
WARN  未检测到 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 环境变量
```

表示“代理路径已经可用”，但 manager 无法证明应用自身已经配置为使用该代理。应用也可能在自己的配置文件、数据库或启动参数中设置代理。

## 0.10.1：代理入口改为序号选择

底层仍然使用稳定的 `inbound_id` 保存绑定关系，但交互界面不再要求手工输入 ID。

现在“扫描并托管”会显示：

```text
可用代理入口：
  1. [default] 默认入口  7890 -> proxy
  2. [a1b2c3d4] 香港入口  7891 -> node-...
  3. [e5f6a7b8] 日本入口  7892 -> node-...

请选择代理入口 [1]:
```

用户只需要输入 `1/2/3`。manager 会把序号转换为对应的稳定入口 ID，再写入 `docker-managed.json`。

因此：

```text
交互层：序号
持久层：inbound_id
运行层：ID -> 当前端口
```

高级 CLI 仍然保留直接传入口 ID，例如：

```bash
sbx docker-network manage new-api-A a1b2c3d4
```

## 0.10：代理入口唯一 ID 绑定

Docker 托管目标不再绑定入口端口，而是绑定稳定的代理入口 ID。

所有代理入口现在统一显示 ID：

```text
ID        名称       监听                 出口
default   默认入口   127.0.0.1:7890       proxy
a1b2c3d4  香港入口   127.0.0.1:7891       香港节点
e5f6a7b8  日本入口   127.0.0.1:7892       日本节点
```

默认入口的稳定 ID 为：

```text
default
```

自定义入口继续使用创建时生成的 8 位唯一 ID，不会因为改名或修改端口而变化。

Docker 托管现在保存：

```json
{
  "inbound_id": "a1b2c3d4"
}
```

而不是：

```json
{
  "port": 7891
}
```

因此如果把 `a1b2c3d4` 的端口从 7891 改为 7901，Docker 托管关系仍绑定同一个入口，manager 会按 ID 动态解析当前端口。

推荐命令：

```bash
sbx inbound list
sbx docker-network manage new-api-A default
sbx docker-network manage new-api-B a1b2c3d4
sbx docker-network env a1b2c3d4
sbx docker-network snippet a1b2c3d4
```

交互式“扫描并托管”也改为按入口 ID 选择：

```text
代理入口 ID [default]:
```

旧版 `docker-managed.json` 中已经保存的 `port` 会在第一次查看/同步时按当前入口表迁移为 `inbound_id`。为了兼容旧脚本，数字端口仍可作为查询引用使用，但新的托管状态只保存 ID。

## 0.9.1：修复扫描托管端口选择

修复 `sbx docker-network -> 扫描并托管` 中，入口列表文本被命令替换误当成端口值的问题。

旧行为可能出现：

```text
[ERROR] 端口无效: 可用代理入口：
  7890  默认入口 -> proxy
```

现在交互提示与入口列表输出到终端提示流，函数标准输出只返回纯端口数字，因此批量选择容器后可正常选择 `7890/7891/...`。

## 0.9：Docker 扫描、托管与自动重连

0.9 在共享代理网络基础上增加“托管接入”。手工：

```bash
sbx docker-network connect <container>
```

仍然只针对当前容器实例；如果 Compose 更新删除旧容器并创建新容器，这个临时连接不会自动继承。

托管模式会扫描 Docker，并按稳定身份记录目标：

```text
Compose 容器 -> com.docker.compose.project + com.docker.compose.service
普通容器  -> 容器名称
```

因此容器 ID 改变后仍能找到新实例。

交互使用：

```bash
sbx docker-network
```

选择“扫描并托管”，会列出当前 Docker 容器，并显示：

```text
容器名 / 运行状态 / Compose project/service / 是否已托管
```

也可以直接：

```bash
sbx docker-network scan
sbx docker-network manage new-api 7891
sbx docker-network managed
sbx docker-network sync
sbx docker-network unmanage new-api
```

托管清单保存在：

```text
/opt/singbox-manager/docker-managed.json
```

该文件会进入 manager 备份，但不会提交 Git。

### Docker watcher

第一次托管目标时，如果系统使用 systemd，manager 会自动安装并启动：

```text
singbox-manager-docker-watch.service
```

watcher 监听 Docker 容器 `create` 和 `start` 事件。发现容器变化后执行幂等同步，把匹配的托管目标重新接入 `singbox-proxy`。

Docker daemon 重启（例如开启 Docker 代理时会重启 Docker）导致事件流中断时，watcher 不会退出，而是等待重试后重新订阅事件；如果 `SBX_WATCH_SBX` 指向的 `sbx` 不可执行，会在日志里持续报错，而不是静默空转。systemd 单元名取自实际写入的服务文件路径，所以用 `SBX_DOCKER_WATCH_SERVICE` 覆盖路径时 `systemctl` 也会操作对应的单元。

手工管理：

```bash
sbx docker-network watch on
sbx docker-network watch off
sbx docker-network watch status
```

即时补接：

```bash
sbx docker-network sync
```

Compose 服务如果存在多个实例，同一个 `project/service` 会匹配并接入所有运行实例。

### 边界

托管功能只恢复 Docker network membership，不会修改其他项目的 Compose 文件，也不会给运行中的目标容器强行注入 `HTTP_PROXY` 环境变量。

应用仍应自行配置，例如：

```text
HTTP_PROXY=http://sing-box:7891
HTTPS_PROXY=http://sing-box:7891
ALL_PROXY=socks5h://sing-box:7891
```

对于“应用启动第一毫秒就必须能解析代理地址”的严格场景，仍建议使用：

```bash
sbx docker-network snippet 7891
```

把 external network 声明写进目标应用自己的 Compose；watcher 属于自动恢复机制，不替代声明式 Compose 网络配置。

## 0.8.1：安装器入口自动代理回退

`sbx-install` 获取最新 `install.sh` 时，现在采用：

```text
直连 raw.githubusercontent.com
        ↓ 失败
检测/使用本机 sing-box
        ↓
http://127.0.0.1:<mixed端口>
```

也可以手工指定：

```bash
SBX_INSTALL_PROXY=http://127.0.0.1:7890 sbx-install
```

或者直接切换安装器镜像：

```bash
SBX_INSTALL_URL=https://example.com/install.sh sbx-install
```

如果机器还没有升级到带 `sbx-install` 的版本，而本机 sing-box 已经运行，可以使用：

```bash
curl -x http://127.0.0.1:7890 -fsSL \
  https://raw.githubusercontent.com/PaiMonCai/singbox-manager/main/install.sh \
  -o /tmp/sbx-install.sh \
  && sudo bash /tmp/sbx-install.sh
```

## 0.8：Docker 容器共享代理网络

0.8 解决 Docker 场景下的 `127.0.0.1` 隔离问题。

宿主机仍然通过：

```text
http://127.0.0.1:7890
```

访问代理；其他 Docker 容器则通过一个专用 external bridge 网络访问：

```text
http://sing-box:7890
socks5h://sing-box:7890
```

开启：

```bash
sbx docker-network on
```

默认会创建：

```text
singbox-proxy
```

并生成：

```text
/opt/singbox-manager/compose.network.yml
```

该 Compose override 会让 sing-box 同时保留项目默认网络，并持久接入 `singbox-proxy`，网络别名固定为 `sing-box`。因此 sing-box 容器重建后仍会重新接入共享网络。

常用命令：

```bash
sbx docker-network
sbx docker-network status
sbx docker-network on
sbx docker-network connect new-api
sbx docker-network disconnect new-api
sbx docker-network list
sbx docker-network urls
sbx docker-network env 7891
sbx docker-network snippet 7891
sbx docker-network off
```

例如把现有容器接进共享网络：

```bash
sbx docker-network connect new-api
```

然后在该容器/应用配置中使用：

```text
HTTP_PROXY=http://sing-box:7890
HTTPS_PROXY=http://sing-box:7890
ALL_PROXY=socks5h://sing-box:7890
```

如果使用 0.6 的多入口功能，则：

```text
sing-box:7891 -> 香港出口
sing-box:7892 -> 日本出口
sing-box:7893 -> auto
```

因此不同容器可以选择不同代理端口。

### 重要：接入网络不等于自动代理

`docker network connect` 只建立网络连通性，不会修改目标容器的环境变量，也不会透明劫持流量。

如果目标容器由 Docker Compose 管理，建议执行：

```bash
sbx docker-network snippet 7891
```

把输出的 external network 和代理环境变量写进目标项目自己的 Compose 文件。这样目标容器以后被重新创建时仍然会自动接入 `singbox-proxy`。

手动执行：

```bash
sbx docker-network connect <container>
```

适合临时接入，但目标容器如果被其他 Compose 项目删除并重新创建，需要重新接入。

### 安全边界

共享网络本身是一个信任边界。只有加入该网络的容器才能直接访问 `sing-box:789x`。不要把不可信容器加入该网络。

宿主机端口仍然可以继续只绑定 `127.0.0.1`，无需为了 Docker 容器访问而把代理发布到 `0.0.0.0`。

## 0.7：管理器快捷更新与自动更新

0.7 把“更新 singbox-manager”和“升级 sing-box 内核”彻底分开。

快速更新管理器：

```bash
sbx self-update
```

等价于：

```bash
sbx manager update
```

它只更新 manager 自身文件，例如 `bin/sbx`、`lib/*.sh`、Python helper、Compose 模板和版本文件；不会修改：

```text
.env
nodes/nodes.json
config/config.json
```

也不会拉取 sing-box 镜像或重启正在运行的 sing-box。

检查是否有新版本：

```bash
sbx manager check
```

强制重新安装当前远端版本：

```bash
sbx manager update --force
```

更新时会检查安装器退出码，并在更新后确认 `bin/sbx`、`lib/*`、`VERSION` 等关键文件存在且非空，因此“`VERSION` 已更新、代码没装全”不会再被报告成成功。

### 固定更新源与校验更新内容

```text
SBX_UPDATE_REPO        仓库，例如 your-name/singbox-manager
SBX_UPDATE_BRANCH      分支或 tag，默认 main
SBX_UPDATE_BASE_URL    直接指定 raw 根地址（镜像 / CDN）
SBX_UPDATE_SHA256      校验 install.sh 的 sha256，不匹配则拒绝执行
SBX_SOURCE_MIRRORS     附加候选源（0.11.3 起参与并发抢速，见 0.11.3 一节）
SBX_MIRROR_PRESET=1    加入公共加速站参与抢速（默认关闭）
```

例如把更新源固定到自己的 tag 并校验安装器内容：

```bash
SBX_UPDATE_REPO=your-name/singbox-manager \
SBX_UPDATE_BRANCH=v0.11.0 \
SBX_UPDATE_SHA256=<install.sh 的 sha256> \
sbx manager update
```

默认更新源是可变的 `main` 分支，且拉取到的 `install.sh` 会以 root 执行。需要长期无人值守的自动更新时，建议用上面的变量把来源固定到自己的 tag 或镜像，并设置 `SBX_UPDATE_SHA256` 校验内容。

### 最新安装器快捷入口

首次升级到 0.7 后会安装：

```text
/usr/local/bin/sbx-install
```

以后直接执行：

```bash
sbx-install
```

它会先获取最新 `install.sh`，然后进入完整安装/升级流程。因此不需要再手工输入长 `curl` 命令。

0.11.3 起，`sbx-install` 会**并发**向官方 raw、jsDelivr CDN（以及你通过 `SBX_SOURCE_MIRRORS` / `SBX_MIRROR_PRESET` 指定的候选源）请求 `install.sh`，最先完整下载完成的胜出；直连全部失败时再走本机 sing-box 代理重试同一批候选源。

`sbx-install` 是“完整安装器”，可能询问 sing-box 版本、监听端口、镜像准备和启动等问题；而 `sbx self-update` 是“只更新 manager”的安全快捷方式。

### 自动更新

自动更新默认关闭。明确开启：

```bash
sbx manager auto on
```

需要输入 `AUTO` 确认，因为这意味着服务器将定期信任并执行配置仓库分支中的 manager 更新。

关闭：

```bash
sbx manager auto off
```

查看状态：

```bash
sbx manager auto status
```

当前 systemd timer 使用：

```text
OnBootSec=15min
OnUnitActiveSec=24h
RandomizedDelaySec=30min
Persistent=true
```

也就是每天检查一次，并加入最多约 30 分钟随机延迟，避免所有机器同一时刻访问更新源。

自动更新只执行：

```bash
sbx manager update --quiet
```

不会自动升级 sing-box 镜像版本。

## 0.6：多入口 -> 多出口路由

0.6 开始支持多个宿主机代理入口，并把每个入口绑定到不同出口。默认入口仍保留：

```text
127.0.0.1:7890 -> proxy
```

自定义入口通过：

```bash
sbx inbound
```

管理。也可以直接：

```bash
sbx inbound list
sbx inbound add
sbx inbound edit [ID|名称]
sbx inbound delete [ID|名称]
sbx inbound show [ID|名称]
sbx inbound test [ID|名称]
```

入口名称不能重复，也不能是 `default`：内置的默认入口占用了这个名称和 ID，自定义入口再叫 `default` 会让按名称解析产生歧义。

每个入口当前使用 `mixed` 协议，同时提供 HTTP 和 SOCKS 代理能力。出口可以选择：

```text
proxy   跟随全局 selector 策略
auto    固定走 URLTest 自动测速组
direct  直连
node    固定走某个具体节点
```

例如：

```text
127.0.0.1:7891 -> 香港节点
127.0.0.1:7892 -> 日本节点
127.0.0.1:7893 -> auto
127.0.0.1:7894 -> direct
```

应用侧只需要选择不同代理端口：

```bash
curl -x http://127.0.0.1:7891 https://api.ipify.org
curl -x http://127.0.0.1:7892 https://api.ipify.org
```

### Docker 端口发布

自定义入口不是通过 host network 实现。manager 会自动生成：

```text
/opt/singbox-manager/compose.inbounds.yml
```

这里只记录实际创建的入口端口，并与主 `compose.yml` 合并。默认只绑定回环地址，不会一次性暴露一个大端口范围。

### 安全

交互式创建入口时默认监听：

```text
127.0.0.1
```

如果改成 `0.0.0.0` 或其他非回环地址，当前 mixed 入口没有用户名/密码认证，因此管理器会显示安全警告，并要求输入 `PUBLIC` 才允许继续。

非交互 CLI 暂不允许直接创建非回环入口。

### 节点更新与入口绑定

入口绑定保存的是 manager 的节点关系，而不是手写 sing-box outbound tag。订阅更新时，如果原节点名称仍存在，会把入口迁移到新节点 ID；如果节点已经消失，则自动回退到 `proxy`，没有任何节点时回退到 `direct`。

入口专属路由规则位于普通的 private/CN 规则之前，因此：

```text
7891 -> 香港节点
```

表示该入口的流量强制交给香港节点，不会再被全局 `.cn -> direct` 规则覆盖。

## 0.5.3：安装器优先走 raw 源

修复一种国内服务器常见情况：入口 `install.sh` 可以从 `raw.githubusercontent.com` 下载，但安装器随后访问 `github.com/<repo>/archive/...tar.gz` 超时。

现在源码获取顺序改为：

```text
本地完整源码目录
        ↓
raw.githubusercontent.com 分文件下载
        ↓
GitHub archive 兜底
```

因此只要最开始这条命令能成功：

```bash
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/singbox-manager/main/install.sh \
  -o /tmp/sbx-install.sh
```

安装器后续会优先沿用同类 raw 源，不再先依赖 GitHub archive。

> 0.11.3 起这条顺序被“并发测速后取最快”取代（见 [0.11.3：安装源并发测速，自动选最快](#0113安装源并发测速自动选最快)），本节描述的 raw 优先语义只适用于 `SBX_SOURCE_NO_RACE=1`。

如果你有自己的国内 CDN、对象存储或仓库镜像，可以通过环境变量切换源码根地址：

```bash
sudo SBX_SOURCE_BASE_URL=https://example.com/singbox-manager/main \
  bash /tmp/sbx-install.sh
```

该地址下需要保持与仓库一致的相对路径，例如：

```text
compose.yml
.env.example
config/config.example.json
bin/sbx
lib/sbx_nodes.py
lib/sbx_v3.sh
lib/sbx_proxy.sh
lib/sbx_bootstrap.sh
lib/sbx_image.sh
```

## 0.5.2：修复重复 inbound tag

修复运行容器使用 `-C /etc/sing-box/` 加载整个配置目录的问题。旧行为会同时读取：

```text
config.json
config.example.json
```

两个文件都包含 `mixed-in`，因此会出现：

```text
FATAL unmarshal merged config: duplicate inbound tag: mixed-in
```

现在 Compose 明确只加载：

```text
-c /etc/sing-box/config.json
```

因此示例配置即使保留在目录中，也不会参与运行。

## 0.5.1：禁止运行期隐式拉镜像

0.5.1 修复了一个实际安装流程问题：节点导入完成后执行 `sing-box check` 时，如果本地缺少镜像，Docker Compose 以前会按默认策略自动拉取 GHCR，导致国内服务器卡在 `Pulling fs layer`。

现在运行期统一增加了镜像守卫：

```text
import / node / subscription / check / start
                    ↓
             检查本地目标镜像
                    ↓
        ┌───────────┴───────────┐
        │                       │
      已存在                   缺失
        │                       │
        ↓                       ↓
  --pull=never 执行      立即进入 Bootstrap
                                │
                        用户明确选择后才拉取
```

`check` 和节点测试使用 Docker 的 `--pull=never`；`start/restart/upgrade` 使用 Compose 的 `--pull never`，因此这些运行期命令不会再偷偷触发镜像下载。

新增镜像管理命令：

```bash
sbx image status
sbx image bootstrap
sbx image pull
sbx image load /path/to/sing-box.tar
sbx image ref
```

其中 `sbx image bootstrap` 如果镜像缺失，会直接进入 Bootstrap 菜单，不会先自动尝试 GHCR。只有 `sbx image pull` 或 Bootstrap 菜单中明确选择拉取方式后才会发生网络拉取。

如果你刚才在节点导入时按 `Ctrl+C` 中断了 GHCR 拉取，可以升级到 0.5.1 后先执行：

```bash
sbx image status
sbx image bootstrap
```

镜像准备好后，再重新执行节点导入或 `sbx check`。

## Bootstrap：解决国内服务器首次拉镜像问题

0.5 专门处理第一次安装时的“鸡生蛋”问题：sing-box 还没有启动，Docker 又可能无法直接从 GHCR 拉取 sing-box 镜像。

安装器会先对当前镜像源做一次短时拉取尝试。默认目标仍是官方镜像：

```text
ghcr.io/sagernet/sing-box:<version>
```

如果失败，会自动进入 Bootstrap 菜单：

```text
1. 使用临时 HTTP/HTTPS 代理拉取官方镜像
2. 使用自定义/可信镜像仓库拉取并重新 tag
3. docker load 本地 .tar 镜像包
4. 再次尝试官方源
0. 暂时跳过
```

### 临时 HTTP 代理

如果服务器已经能访问某个外部 HTTP 代理，可输入例如：

```text
http://1.2.3.4:7890
```

安装器会临时写入 Docker daemon 的 systemd drop-in、重启 Docker、拉取官方镜像，然后立刻删除临时代理配置并再次重启 Docker。

### 自定义镜像仓库

安装器不会硬编码任何第三方公共镜像站。你可以输入自己信任的镜像仓库，例如：

```text
mirror.example.com/sagernet/sing-box
```

成功拉取后，安装器会把该镜像重新 tag 成当前正式目标镜像名，因此 compose 后续仍可以使用标准镜像引用。

### 本地镜像包

也可以在其他网络正常的机器上提前：

```bash
docker pull ghcr.io/sagernet/sing-box:v1.14.2
docker save ghcr.io/sagernet/sing-box:v1.14.2 -o sing-box-v1.14.2.tar
```

把 tar 文件传到国内服务器后，在 Bootstrap 菜单选择本地导入。

### 自定义正式镜像源

`.env` 现在支持：

```text
SING_BOX_IMAGE=ghcr.io/sagernet/sing-box
SING_BOX_VERSION=v1.14.2
```

如果你有长期可信的私有镜像仓库，也可以修改 `SING_BOX_IMAGE`。

## 宿主机应用代理

0.4 增加了 Docker、Git、APT、npm 的一键代理接入。所有集成都指向 sing-box 的本地 mixed 端口，默认是：

```text
http://127.0.0.1:7890
```

进入交互菜单：

```bash
sbx proxy
```

直接命令：

```bash
sbx proxy status

sbx proxy docker on
sbx proxy docker off

sbx proxy git on
sbx proxy git off

sbx proxy apt on
sbx proxy apt off

sbx proxy npm on
sbx proxy npm off

sbx proxy curl on
sbx proxy curl off

sbx proxy all on
sbx proxy all off
```

临时给当前 Shell 设置代理环境变量：

```bash
eval "$(sbx proxy env)"
```

取消：

```bash
eval "$(sbx proxy env off)"
```

### Docker

Docker 使用独立 systemd drop-in：

```text
/etc/systemd/system/docker.service.d/99-singbox-manager-proxy.conf
```

开启/关闭 Docker daemon 代理需要重启 Docker 服务，因此运行中的容器可能短暂中断。管理器会等待 Docker daemon 恢复，并重新确保 sing-box 容器处于启动状态。

当前自动配置针对普通 rootful + systemd Docker。检测到 rootless Docker 时不会擅自修改用户级 systemd 配置。

如果 `/etc/docker/daemon.json` 已显式配置 `proxies`，管理器会给出警告，因为 Docker daemon 配置文件的代理设置优先于 systemd 环境变量。

### Git

Git 使用一个独立的系统级 include 文件：

```text
/etc/singbox-manager/git-proxy.conf
```

只向系统 Git 配置增加该 include；关闭时删除自己的 include，不直接覆盖已有 Git 用户配置。

### APT

APT 使用：

```text
/etc/apt/apt.conf.d/99singbox-manager-proxy
```

关闭时仅删除这个文件。

### npm

npm 在其 `globalconfig` 中维护一段带 singbox-manager 标记的配置块，只删除和重写自己的区块。已有 npm 配置文件的权限不会被主动放宽。

### 推荐用法

国内服务器配置好节点并确认：

```bash
sbx test
```

之后可以：

```bash
sbx strategy auto
sbx route cn-direct-lite
sbx proxy all on
sbx proxy status
```

这样 Docker 拉镜像、Git、APT 与 npm 都会统一经过本机 sing-box。

## 常用命令

```bash
sbx
sbx status
sbx start
sbx stop
sbx restart
sbx logs
sbx check
sbx test
sbx reapply
sbx backup
sbx restore
sbx version
sbx self-update
sbx manager check
sbx manager auto status
sbx docker-network status
sbx docker-network scan
sbx docker-network managed
sbx docker-network sync
sbx docker-network urls
sbx-install
sbx upgrade v1.14.2
sbx pull
```

本地代理默认监听：

```text
HTTP:   http://127.0.0.1:7890
SOCKS5: socks5://127.0.0.1:7890
```

例如：

```bash
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
```

## 项目结构

```text
/opt/singbox-manager
├── compose.yml
├── compose.inbounds.yml      # 有自定义入口时自动生成
├── compose.network.yml       # 启用 Docker 共享代理网络时生成
├── .env
├── docker-managed.json       # 有托管 Docker 目标时生成
├── VERSION
├── bin/
│   ├── sbx
│   └── sbx-install
├── lib/
│   └── sbx_nodes.py
├── nodes/
│   ├── nodes.json
│   └── .sbx-nodes.lock       # 节点库写锁（flock，仅加锁用，可删除）
├── config/
│   └── config.json
├── data/
└── backup/
```

## 安全说明

- mixed 代理默认只绑定 `127.0.0.1`，不会直接暴露到公网。
- 不要把生产节点密码、UUID、Reality Key 或完整 `nodes.json` 提交到 Git。
- `sbx node show` 默认对敏感字段做脱敏显示。
- 升级 sing-box 前会先备份并用目标版本检查现有配置，失败时回滚版本设置。
- 管理器自更新默认从可变的 `main` 分支拉取并以 root 执行；无人值守场景请用 `SBX_UPDATE_BRANCH` 固定到 tag，并设置 `SBX_UPDATE_SHA256` 校验。
- Docker daemon 代理、Git/APT/npm 系统代理以及 curl 的 `~/.curlrc` 都会写入宿主机配置；关闭时请使用对应的 `sbx proxy ... off`，不要只手工删文件（会留下引用已删除配置的残留，以及指向已停代理的 curl 配置）。

## Roadmap

下一层计划：

- 订阅定时更新与节点健康检查
- Docker build 阶段代理模板
- 更丰富的路由规则管理
- TUN / 透明代理
