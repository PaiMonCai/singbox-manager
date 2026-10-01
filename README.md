# singbox-manager

面向 Linux 服务器的 sing-box Docker 管理层。sing-box 保持官方镜像运行，宿主机通过 `sbx` 完成安装、节点管理、配置生成、校验、测试、备份恢复与升级。

当前版本：**0.8.1**

## 一键交互式安装

推荐直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/singbox-manager/main/install.sh -o /tmp/sbx-install.sh && sudo bash /tmp/sbx-install.sh
```

安装器会交互询问：

- sing-box 版本
- 本地监听地址
- mixed HTTP/SOCKS5 端口
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

已有安装再次运行安装器时，会更新管理器文件，同时保留本机 `.env`、节点库和运行配置。

## 节点管理

进入菜单：

```bash
sbx node
```

也可直接使用：

```bash
sbx node list
sbx node add
sbx node edit [ID|名称]
sbx node delete [ID|名称]
sbx node default [ID|名称]
sbx node show [ID|名称]
sbx node test [ID|名称]
sbx node render
```

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

### 最新安装器快捷入口

首次升级到 0.7 后会安装：

```text
/usr/local/bin/sbx-install
```

以后直接执行：

```bash
sbx-install
```

它会先从当前仓库的 raw 地址获取最新 `install.sh`，然后进入完整安装/升级流程。因此不需要再手工输入长 `curl` 命令。

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
sbx backup
sbx restore
sbx version
sbx self-update
sbx manager check
sbx manager auto status
sbx docker-network status
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
├── VERSION
├── bin/
│   ├── sbx
│   └── sbx-install
├── lib/
│   └── sbx_nodes.py
├── nodes/
│   └── nodes.json
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

## Roadmap

下一层计划：

- 订阅定时更新与节点健康检查
- Docker build 阶段代理模板
- 更丰富的路由规则管理
- TUN / 透明代理
