# singbox-manager

面向 Linux 服务器的 sing-box Docker 管理层。sing-box 保持官方镜像运行，宿主机通过 `sbx` 完成安装、节点管理、配置生成、校验、测试、备份恢复与升级。

当前版本：**0.5.0**

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
├── .env
├── bin/
│   └── sbx
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

- 订阅定时更新与健康检查
- Docker build / 容器级代理模板
- 更丰富的路由规则管理
- TUN / 透明代理
