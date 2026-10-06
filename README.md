# singbox-manager

面向 Linux 服务器的 sing-box Docker 管理层。sing-box 保持官方镜像运行，宿主机通过 `sbx` 完成安装、节点管理、配置生成、校验、测试、备份恢复与升级。

当前版本：**0.11.16**

## 目录

- [一键交互式安装](#一键交互式安装)
- [节点管理](#节点管理)
- [配置生成与回滚](#配置生成与回滚)
- [单节点真实测试](#单节点真实测试)
- [分享链接与订阅导入](#分享链接与订阅导入)
- [自动测速与出口策略](#自动测速与出口策略)
- [路由模板](#路由模板)
- [Bootstrap：解决国内服务器首次拉镜像问题](#bootstrap解决国内服务器首次拉镜像问题)
- [宿主机应用代理](#宿主机应用代理)
- [常用命令](#常用命令)
- [项目结构](#项目结构)
- [安全说明](#安全说明)
- [Roadmap](#roadmap)
- [版本历史](#版本历史)

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

### 源码完整性校验（SHA256SUMS）

安装器（`install.sh` / `sbx-install`）与管理器自更新都支持用 `sha256sum` 清单校验下载到的源码文件，用来发现 CDN、对象存储或第三方镜像站返回的内容被改写：

| 变量 | 默认 / 作用 |
| --- | --- |
| `SBX_SOURCE_SHA256SUMS` | 校验清单的 URL 或本地路径；留空时默认取 `<候选源 base>/SHA256SUMS` |
| `SBX_REQUIRE_CHECKSUM=1` | 安装器严格模式：清单不可得即中止安装 |
| `SBX_UPDATE_SHA256SUMS` | 自更新用的校验清单；默认 `<更新源 base>/SHA256SUMS` |
| `SBX_UPDATE_REQUIRE_CHECKSUM=1` | 自更新严格模式：清单不可得即中止更新 |
| `SBX_UPDATE_SHA256` | 原有的单文件校验，保留；仍可单独校验 `install.sh` |

语义（安装器与自更新都适用）：

- 清单可得且可解析 → 下载的每个源码文件都必须匹配：**不匹配或清单里缺条目即中止**（自更新时绝不继续执行）。
- 清单不可得（安装器侧还包括清单不可解析）→ 打印一次警告后按原行为继续；严格模式下（`..._REQUIRE_CHECKSUM=1`）清单不可得即中止。
- 自更新多一层保险：清单取到了但不含任何可解析条目时，视为清单损坏并**直接中止**，不静默放行。
- 清单格式是标准 `sha256sum` 输出：`<64 位十六进制哈希><空格><相对路径>`（标准 `sha256sum` 是两个空格，单空格 / TAB 也接受，`*` 二进制前缀可有可无），允许 `#` 注释与空行；路径写法与 `install.sh` 的 `SOURCE_REQUIRED` 一致（例如 `lib/sbx_nodes.py`）。

**防护边界**：清单和源码来自同一个分支 / 同一个镜像地址，所以它挡得住“CDN / 镜像站改写内容”，**挡不住仓库本身被改写** —— 攻击者改了源码，也会顺带改掉同一分支里的 `SHA256SUMS`。要真正锁定内容，请把来源固定到不可变的 tag（`SBX_INSTALL_BRANCH` / `SBX_UPDATE_BRANCH`）并使用自建源（`SBX_SOURCE_BASE_URL` / `SBX_UPDATE_BASE_URL`），这样清单才具备独立可信度。

### 校验清单的发布与维护

仓库根已发布 `SHA256SUMS`，所以安装器与 `sbx-install` 从官方源（或任何镜像该目录的源）安装时，**默认就会走清单校验**：不匹配或缺条目直接中止。若你的源没有该文件，只会打印一次“未找到校验清单”的警告然后按老行为继续；要禁止这种降级，用 `SBX_REQUIRE_CHECKSUM=1` / `SBX_UPDATE_REQUIRE_CHECKSUM=1`。

维护这份清单（**改任何一个受校验的文件后都必须重新生成**）：

```bash
# 在仓库根执行。清单必须恰好 18 项：17 项源码（= install.sh 的 SOURCE_REQUIRED）+ install.sh
# 自身 —— install.sh 不由 install.sh 下载，但 bin/sbx-install 要用清单校验它。
sha256sum install.sh compose.yml .env.example config/config.example.json \
  bin/sbx bin/sbx-docker-watch bin/sbx-install \
  lib/*.py lib/*.sh VERSION > SHA256SUMS

sha256sum -c SHA256SUMS   # 自校验
```

三条硬性约束：

- **`SHA256SUMS` 自身不写进清单**（也不列入 `SOURCE_REQUIRED`），否则会形成自我引用的死循环。
- **清单必须包含 `install.sh`**：`bin/sbx-install` 下载安装器后要用它校验；缺条目会被当成校验失败而否决该候选源。
- **过期清单会让所有安装与自更新直接失败**（fail-closed）。CI 已把这条变成门禁：`Verify SHA256SUMS is up to date` 步骤会跑 `sha256sum -c` 并断言清单条目与 `SOURCE_REQUIRED + install.sh` 完全一致，不一致即红。

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

## Bootstrap：解决国内服务器首次拉镜像问题

0.5 专门处理第一次安装时的“鸡生蛋”问题：sing-box 还没有启动，Docker 又可能无法直接从 GHCR 拉取 sing-box 镜像。

安装器会先对当前镜像源做一次短时拉取尝试。默认目标仍是官方镜像：

```text
ghcr.io/sagernet/sing-box:<version>
```

如果失败，会自动进入 Bootstrap 菜单：

```text
1. 使用临时 HTTP/HTTPS 代理拉取目标镜像
2. 使用自定义 / 可信镜像仓库拉取并重新 tag
3. docker load 本地 .tar 镜像包
4. 明确尝试当前镜像源
0. 取消
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

本节说的是**宿主机上**的工具走 sing-box（菜单里的【宿主机代理】，0.11.9 之前叫「应用代理」）。
让**其它容器**共享 sing-box 出口是另一件事，见【容器接入】（0.11.9 之前叫「Docker 容器网络」）。

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
├── .env.example
├── docker-managed.json       # 有托管 Docker 目标时生成
├── VERSION
├── bin/
│   ├── sbx
│   └── sbx-docker-watch      # Docker 事件 watcher（托管容器自动重连）
├── lib/                      # 10 个文件，由 SOURCE_REQUIRED 全量安装
│   ├── sbx_update.sh
│   ├── sbx_nodes.py
│   ├── sbx_docker_targets.py
│   ├── sbx_verify.py
│   ├── sbx_docker_network.sh
│   ├── sbx_inbound.sh
│   ├── sbx_proxy.sh
│   ├── sbx_bootstrap.sh
│   ├── sbx_image.sh
│   └── sbx_v3.sh
├── nodes/
│   ├── nodes.json
│   └── .sbx-nodes.lock       # 节点库写锁（flock，仅加锁用，可删除）
├── config/
│   ├── config.example.json
│   └── config.json
├── data/
├── backup/
└── proxy-state/              # 代理状态记录（curlrc / npm 等，权限 700）
```

`bin/sbx-install` 不在安装目录里：安装时它被复制到 `/usr/local/bin/sbx-install`，`/usr/local/bin/sbx` 则软链到 `<安装目录>/bin/sbx`。

## 安全说明

- mixed 代理默认只绑定 `127.0.0.1`，不会直接暴露到公网。
- 不要把生产节点密码、UUID、Reality Key 或完整 `nodes.json` 提交到 Git。
- `sbx node show` 默认对敏感字段做脱敏显示。
- 升级 sing-box 前会先备份并用目标版本检查现有配置，失败时回滚版本设置。
- 管理器自更新默认从可变的 `main` 分支拉取并以 root 执行；无人值守场景请用 `SBX_UPDATE_BRANCH` 固定到 tag，并用 `SBX_UPDATE_SHA256SUMS`（配合 `SBX_UPDATE_REQUIRE_CHECKSUM=1` 严格模式）校验整套更新文件；只想单独校验 `install.sh` 时仍可用 `SBX_UPDATE_SHA256`。安装器侧对应 `SBX_SOURCE_SHA256SUMS` / `SBX_REQUIRE_CHECKSUM=1`。注意清单与源码同源：它挡得住 CDN / 镜像站改写内容，但挡不住仓库本身被改写，详见 [源码完整性校验（SHA256SUMS）](#源码完整性校验sha256sums)。
- Docker daemon 代理、Git/APT/npm 系统代理以及 curl 的 `~/.curlrc` 都会写入宿主机配置；关闭时请使用对应的 `sbx proxy ... off`，不要只手工删文件（会留下引用已删除配置的残留，以及指向已停代理的 curl 配置）。

## Roadmap

下一层计划：

- 订阅定时更新与节点健康检查
- Docker build 阶段代理模板
- 更丰富的路由规则管理
- TUN / 透明代理

## 版本历史

逐版本变更记录（含各历史版本引入功能时的背景与取舍）已移到 [CHANGELOG.md](CHANGELOG.md)。

其中一些**至今仍然适用**的详细说明当初是随版本一起写的，现在也留在 CHANGELOG 里，按主题索引：

| 主题 | 位置 |
| --- | --- |
| 一键诊断与 Docker 容器验证（`sbx doctor` / `verify-all` 输出怎么读） | [0.11：可验证性与一键诊断](CHANGELOG.md#011可验证性与一键诊断) |
| Docker watcher：容器重建后自动重连 | [0.9：Docker 扫描、托管与自动重连](CHANGELOG.md#09docker-扫描托管与自动重连) |
| 自动更新、固定更新源与更新内容校验 | [0.7：管理器快捷更新与自动更新](CHANGELOG.md#07管理器快捷更新与自动更新) |
| 安装源并发测速与环境变量（`SBX_SOURCE_*`） | [0.11.3：安装源并发测速，自动选最快](CHANGELOG.md#0113安装源并发测速自动选最快) |
| 多入口 → 多出口路由与节点更新绑定 | [0.6：多入口 -> 多出口路由](CHANGELOG.md#06多入口---多出口路由) |
| “接入网络不等于自动代理”与安全边界 | [0.8：Docker 容器共享代理网络](CHANGELOG.md#08docker-容器共享代理网络) |

> 版本号的唯一来源是仓库根的 [`VERSION`](VERSION)；管理器在运行时从安装目录的 `VERSION` 读取。
