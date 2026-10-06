# 版本历史

singbox-manager 的逐版本变更记录，按时间倒序（最新在上）。
当前功能与用法请见 [README.md](README.md)。

## 版本索引

- [0.11.16：托管同步的竞态不再误报“接入失败”](#01116托管同步的竞态不再误报接入失败)
- [0.11.15：给 systemd 单元加固（崩溃快速失败 + 显式补 HOME）](#01115给-systemd-单元加固崩溃快速失败--显式补-home)
- [0.11.14：修掉“没有 HOME 时 sbx 完全起不来”（连同自动更新一起中招）](#01114修掉没有-home-时-sbx-完全起不来连同自动更新一起中招)
- [0.11.13：修掉 Docker watcher 静默失效（docker events 模板字段）](#01113修掉-docker-watcher-静默失效docker-events-模板字段)
- [0.11.12：默认入口也能编辑了（监听/端口/出口）](#01112默认入口也能编辑了监听端口出口)
- [0.11.11：入口也改用序号，并修掉默认入口的报错与编辑崩溃](#01111入口也改用序号并修掉默认入口的报错与编辑崩溃)
- [0.11.10：修掉 Docker 托管里“宿主端口当成容器内端口”的错误](#01110修掉-docker-托管里宿主端口当成容器内端口的错误)
- [0.11.9：菜单收敛（23 项 → 11 项，每项带说明）](#0119菜单收敛23-项--11-项每项带说明)
- [0.11.8：菜单版式放大（行距 / 缩进 / 列宽 / 标题块）](#0118菜单版式放大行距--缩进--列宽--标题块)
- [0.11.7：黑底可读的终端配色（主色改明绿）](#0117黑底可读的终端配色主色改明绿)
- [0.11.6：curl 也接入宿主机应用代理](#0116curl-也接入宿主机应用代理)
- [0.11.5：修复“CDN 缓存让更新看起来不存在”](#0115修复cdn-缓存让更新看起来不存在)
- [0.11.4：节点改用序号操作，ID 退到内部](#0114节点改用序号操作id-退到内部)
- [0.11.3：安装源并发测速，自动选最快](#0113安装源并发测速自动选最快)
- [0.11.2：更新判定改为版本比较](#0112更新判定改为版本比较)
- [0.11.1：安装器幂等、并发安全与校验加固](#0111安装器幂等并发安全与校验加固)
- [0.11：可验证性与一键诊断](#011可验证性与一键诊断)
- [0.10.1：代理入口改为序号选择](#0101代理入口改为序号选择)
- [0.10：代理入口唯一 ID 绑定](#010代理入口唯一-id-绑定)
- [0.9.1：修复扫描托管端口选择](#091修复扫描托管端口选择)
- [0.9：Docker 扫描、托管与自动重连](#09docker-扫描托管与自动重连)
- [0.8.1：安装器入口自动代理回退](#081安装器入口自动代理回退)
- [0.8：Docker 容器共享代理网络](#08docker-容器共享代理网络)
- [0.7：管理器快捷更新与自动更新](#07管理器快捷更新与自动更新)
- [0.6：多入口 -> 多出口路由](#06多入口---多出口路由)
- [0.5.3：安装器优先走 raw 源](#053安装器优先走-raw-源)
- [0.5.2：修复重复 inbound tag](#052修复重复-inbound-tag)
- [0.5.1：禁止运行期隐式拉镜像](#051禁止运行期隐式拉镜像)

---

## 0.11.16：托管同步的竞态不再误报“接入失败”

0.11.13 之后 watcher 会真的干活了，于是下面这行在新日志里出现：

```text
[sbx-docker-watch] 接入失败: sbx-watch-probe: Error response from daemon: endpoint with name sbx-watch-probe already exists in network singbox-proxy
```

它其实**不是失败**。时序是这样：

```text
01:27:05  watcher 被探针容器的 create/start 事件唤醒 → 取了 docker 快照（此时还没托管、也没接入）
01:27:06  你的 `sbx docker-network manage` 把它登记托管并接进网络；同一瞬间 watcher 又跑了一轮 sync，
          它按旧快照以为“没接上”就去 connect → daemon 回 “already exists”（因为 manage 已经接好了）
01:27:19  真正的测试（disconnect + restart）→ `已自动接入` ✓
```

`sync()` 原来只看 `docker network connect` 的退出码，失败就直接打成“接入失败”。
现在失败后会**重新 inspect 这一个容器**再决定：

- 它其实已经在共享网络里 → 计为 `already`，打印 `已在共享网络中: <容器> -> <网络>`
- 确实没接上 → 照旧报 `接入失败`（真实故障不会被掩盖）

这样日志里就不会再出现误导性的“失败”，同时真失败仍然可见 —— 对靠日志判断 watcher 是否健康的人来说这点很重要。

CI 在“假 docker”测试台里加了确定性用例：`FAKE_DOCKER_STATE=race` 模拟“批量快照看不到网络、按名称重新 inspect 却在网络里、此时 connect 被 daemon 以 already exists 拒绝”，断言必须打印 `已在共享网络中` 且**不得**出现 `接入失败`；对着旧代码反向验证过（去掉自检必红）。

## 0.11.15：给 systemd 单元加固（崩溃快速失败 + 显式补 HOME）

两个独立问题都是这次 watcher 事故暴露出来的：

**1. 崩溃循环能烧掉 40 分钟 CPU 而没人知道**

`Restart=always` + `RestartSec=3` 的慢速崩溃（每 3 秒一次）不会触发 systemd 默认的
`StartLimitBurst=5/10s`（3 秒一次刚好卡在门槛下），于是 unit 一直 active、重启计数
涨到 5276、白烧 40 分钟 CPU。现在 watcher 单元里显式加上：

```ini
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=5
```

以后再崩就会**停止重启并把 unit 标成 failed** —— `systemctl status` 和
`sbx docker-network` 的 Watcher 那几行一眼能看出问题。
（这两个键是 systemd ≥ 229 的 `[Unit]` 写法；更老的 systemd 会忽略，不影响启动。）

**2. systemd 单元里没有 HOME**

0.11.14 修的是脚本里没兜底的 `$HOME`；这一版再加一层保险，生成单元时显式补上：

```ini
Environment="HOME=/root"        # 自动更新 service 同样补上
```

家目录取自 `getent passwd 0`，取不到才退回 `/root`。这样即使以后新代码又踩到
`$HOME`，这两个单元也不会再静默失败。

自动更新的 service 是 `Type=oneshot` 且没有 `Restart=`，不存在崩溃循环，所以只补了 HOME。

CI：unit 生成步骤新增断言（`StartLimitIntervalSec=60`、`StartLimitBurst=5`、
`Environment="HOME=`），watcher 与自动更新两个单元都校验。

## 0.11.14：修掉“没有 HOME 时 sbx 完全起不来”（连同自动更新一起中招）

0.11.13 修好 watcher 之后，容器重建仍然没有被接回共享网络，日志里换成了新错误：

```text
[sbx-docker-watch] /opt/singbox-manager/lib/sbx_proxy.sh: line 12: HOME: unbound variable
```

根因：`lib/sbx_proxy.sh` 在**被 source 的阶段**用 `$HOME` 拼 `~/.curlrc` 的路径：

```bash
CURLRC_FILE="${SBX_CURLRC_FILE:-${CURL_HOME:-$HOME}/.curlrc}"
```

而 systemd 单元和 cron 里**没有 `HOME`**，`bin/sbx` 又是 `set -Eeuo pipefail` —— 于是 `set -u` 让整个 CLI 在加载阶段就退出。所有子命令全废，不只是 `docker-network sync`：

| 谁在无 HOME 的环境里跑 | 命令 | 结果 |
| --- | --- | --- |
| Docker watcher（systemd） | `sbx docker-network sync` | 失败 → 容器重建后接不回网络 |
| 每日自动更新（systemd timer） | `sbx manager update --quiet` | 失败 → **自动更新一直是坏的** |
| cron 里的任何 sbx 调用 | 任意子命令 | 失败 |

自查（`0.11.14` 之前必现，之后正常）：

```bash
env -i PATH=/usr/local/bin:/usr/bin:/bin SBX_HOME=/opt/singbox-manager sbx version
# 以前：lib/sbx_proxy.sh: line 12: HOME: unbound variable
# 现在：singbox-manager: 0.11.14
```

修复：加 `proxy_user_home()` —— 先用 `$HOME`，没有就用 `getent passwd $(id -u)` 查该用户真实家目录，再兜底 root 的 `/root`；`CURL_HOME` / `SBX_CURLRC_FILE` 优先级不变。顺便审计了全仓顶层赋值：只有这一处引用了外部环境变量，其余都是 `${SBX_*:-默认值}` 形式。

**如果你的自动更新开着，请顺手确认它现在真的会跑**（升级到 0.11.14 之后）：

```bash
journalctl -u singbox-manager-update.service -n 30 --no-pager   # 旧记录里应该都是这条 unbound variable
systemctl start singbox-manager-update.service                   # 手动触发一次，应报“已是最新版本”
systemctl list-timers singbox-manager-update.timer               # 看下次触发时间
```

CI 新增“空环境”断言：用 `env -i`（没有 HOME）跑 `sbx version` / `manager auto status` / `proxy status`，必须正常输出且不得出现 `unbound variable`。对着旧代码反向验证过（把 `$HOME` 改回去，断言必红）。

## 0.11.13：修掉 Docker watcher 静默失效（docker events 模板字段）

症状：`sbx docker-network` 里 Watcher 显示 `CONFIGURED` / systemd 显示 active，但重建（或重启）容器后容器并没有被自动接回共享网络。

根因在 watcher 里这条命令上：

```bash
docker events --filter type=container --filter event=create --filter event=start --format '{{.ID}}' 2>/dev/null
```

Docker 26 起，`docker events` 的事件类型不再带废弃的 `ID` 字段（要用 `Actor.ID`），于是这条命令**一启动就以 `Error parsing format` 退出**：

```text
Error parsing format: template: :1:2: executing "" at <.ID>: can't evaluate field ID in type *events.Message
```

而脚本把它的 stderr 丢进了 `/dev/null`，`while true` 里每 3 秒静默重试一次 —— 所以 systemd 看到进程一直活着，判定 active；实际一次 `sync` 都没跑过。用户侧的表现就是“开了没用”。

修复：

- 去掉 `--format`：事件行本身不需要解析（循环体只需要“有事件发生”这个信号），不写模板就没有跨版本字段问题
- 不再隐藏 `docker events` 的 stderr：参数/模板/daemon 出错都要能在 `journalctl` 里看到
- 每次同步的输出加 `[sbx-docker-watch]` 前缀写进 journal（原来 `--quiet` 且重定向到 /dev/null），**接入成功与失败都看得见**
- `sbx docker-network` 的 Watcher 状态里直接打印排查入口：`journalctl -u singbox-manager-docker-watch -n 20 --no-pager`

自查：

```bash
journalctl -u singbox-manager-docker-watch -n 20 --no-pager   # 有没有 [sbx-docker-watch] 记录
SBX_WATCH_SBX=/usr/local/bin/sbx bash /opt/singbox-manager/bin/sbx-docker-watch   # 前台跑，重建一个容器看输出
```

注意「共享网络」关掉时 `sync` 会跳过（`共享代理网络当前未启用，已跳过 sync`），这句话现在也会进 journal，不会再无声无息。

CI 新增回归断言：watcher 跑 3 秒不得出现 `Error parsing format` / `sbx 不可执行`；`docker events` 必须能持续运行 2 秒以上（参数或模板错会立刻退出）。这两条断言对着旧代码验证过：把 `--format '{{.ID}}'` 加回去就必红。

## 0.11.12：默认入口也能编辑了（监听/端口/出口）

0.11.11 把默认入口的编辑直接拒了，理由写的是“它由 .env 决定”。这不对：默认入口本来就有能改的东西，只是要改对地方。现在放开：

**默认入口 = 容器里的 `mixed-in`**

| 属性 | 在哪 | 现在能不能改 |
| --- | --- | --- |
| 容器内监听端口 | 固定 7890（`compose.yml` 发布 `<bind>:<port>:7890`） | 不能改（改了等于换容器接口） |
| 宿主机监听地址 | `.env` 的 `SING_BOX_BIND_ADDR` | ✅ 可改（编辑时写入 .env） |
| 宿主机端口 | `.env` 的 `SING_BOX_MIXED_PORT` | ✅ 可改（会检查与自定义入口端口冲突） |
| 出口 | 注册表 `settings.default_inbound_target` | ✅ 可改：`proxy`（默认）/ `auto` / `direct` / 指定节点 |
| 名称 | 固定「默认入口」（配置里的 tag 是 `mixed-in`） | ❌ 不能改 |
| 删除 | —— | ❌ 不能删（容器里始终有这么一个入口） |

```bash
sbx inbound edit 1 --port 7897 --target node:2     # 序号 1 就是默认入口
sbx inbound edit default --listen 127.0.0.1        # 按 ID 也一样
sbx inbound edit 1                                 # 交互式：逐个问监听地址/端口/出口
```

改端口/监听地址后需要**重建容器**才生效（端口映射变了，`restart` 不是重载）：菜单返回时会自动 `sbx restart`（内部是 `compose up -d --force-recreate`），命令行下自己执行一次即可。值没变时不会重写 `.env`，也不会提示重启。

**出口标签先说明白**，菜单里那一列到底是什么意思：

| 标签 | 含义 |
| --- | --- |
| `proxy` | 一个 selector，候选是 `[auto] + 所有节点`；默认选谁由【出口与分流】决定 —— `manual` 选你指定的默认节点，`auto` 选 `auto` 组。**默认入口出厂就是这个，等于「跟随全局策略」** |
| `auto` | URLTest 测速组，自己在所有节点里挑最快的 |
| `direct` | 直连，不走代理 |
| 节点名 | 写死走这一个节点（绕过策略） |

默认入口的出口保持 `proxy` 时，生成的配置与以前完全一致（不加额外规则，靠 `route.final = proxy` 兜底）；只有被改成别的才会为 `mixed-in` 加一条路由规则。

**顺带修掉一个事务性 bug**：编辑失败回滚时，bash 侧只还原 `nodes.json`/`config.json` 而不还原 `.env`。默认入口的监听/端口就写在 `.env` 里，于是会出现「端口改了、出口没改」的半套状态（在缺少镜像、`sing-box check` 失败时必现）。两处都修了：helper 内部先校验/渲染、最后才写 `.env`；`inbound_tx` 的回滚改为连 `.env` 一起还原。

CI 新增断言：默认入口可改端口（写入 .env、容器内端口仍是 7890）、可改出口（配置里为 `mixed-in` 生成规则）、端口与自定义入口冲突要报错、改名要报错、改回 `proxy` 后规则消失、删除仍被拒。

## 0.11.11：入口也改用序号，并修掉默认入口的报错与编辑崩溃

节点从 0.11.4 起就是“交互层用序号、持久层用 ID”，但入口管理还是让你手打 ID，而且列表里根本看不到序号。三个问题一起修：

**1. 入口列表显示序号**

```text
序号  名称                  监听                      出口
--------------------------------------------------------------------------------------
1     默认入口              127.0.0.1:7890            proxy
2     香港                  127.0.0.1:4512            香港【ix|×4】
3     华南                  127.0.0.1:7891            华南
```

默认不再显示 `ID`，需要排障或写脚本时用 `sbx inbound list --ids`。序号顺序就是入口表的顺序：内置默认入口恒为 1，之后按自定义入口的添加顺序。顺带修掉列宽按字符数补齐导致中文名把后面列顶歪的问题（改成按显示宽度算，CJK 记 2 列）。

**2. 序号/名称/ID/端口都能用，默认入口不再报“未找到入口”**

解析顺序是：完整 ID → 端口 → 序号 → ID 前缀 → 名称。

```bash
sbx inbound show 2            # 序号
sbx inbound show 香港         # 名称
sbx inbound show 7891         # 端口（0.10 起的行为；端口匹配优先于序号）
sbx inbound edit 3 --port 7899
```

- 之前 `sbx inbound edit default` / `delete default` 会报 `未找到入口: default` —— 列表里明明有这个入口。原因是编辑/删除走的是“只认自定义入口”的解析器，而列表和 `--endpoint` 走的是另一套（含内置默认入口）。现在统一成一套。
- 0.11.11 及以前：默认入口**不能编辑也不能删除**（它的监听地址/端口来自 `.env` 的 `SING_BOX_BIND_ADDR` / `SING_BOX_MIXED_PORT`，出口恒为 proxy），所以当时给的是明确说明而不是“未找到”：

  ```text
  默认入口不能编辑或删除：它的监听地址/端口来自 .env（SING_BOX_BIND_ADDR / SING_BOX_MIXED_PORT），
  出口恒为 proxy。改 .env 后执行 sbx restart，或重跑安装器（SBX_RECONFIGURE=1）重新配置；
  需要别的端口/出口请用「添加」新建自定义入口。
  ```

  > 0.11.12 起这条限制已放开：默认入口可以编辑宿主机监听地址/端口（写入 `.env`）和出口（`proxy` / `auto` / `direct` / 指定节点），只有改名与删除仍然被拒。上面这段提示语只属于 0.11.11 及以前，现状见 [0.11.12：默认入口也能编辑了](#01112默认入口也能编辑了监听端口出口)。

- 序号越界现在是 `入口序号超出范围: 9（当前 1-3）`，而不是莫名其妙命中某个 ID 前缀（`9` 以前会解析成 `9d52daa0`）。完整 ID 仍然优先，所以全数字的 ID（例如 `22222222`）不会被当成序号。

**3. 修掉编辑入口直接崩掉的问题**

`sbx inbound edit 2` 以前会抛 `{'id': ...} is not in list`：编辑用的解析器返回的是 `inbound_endpoints()` 拼出来的**合成副本**（带 `builtin` / `container_port` 等额外字段），却被拿去 `data["inbounds"].index(...)` 找位置，自然找不到。现在改为按 ID 回注册表定位真实那一条；改名/改端口/改出口后入口 ID 保持稳定。

菜单同步改口：入口路由里的操作从「入口 ID/名称(留空后选择)」改成「序号(留空可列表选择)」，与节点菜单一致。命令行依旧兼容：`sbx inbound edit <ID>`、`sbx inbound show 7891` 都能用。

CI 新增断言：列表默认不显示 ID、`--ids` 才显示、按序号/端口解析、越界报错、默认入口详情可用但编辑/删除必须被拒、全数字 ID 仍按 ID 解析，以及“按序号编辑后 ID 不变且配置与 compose 跟着更新”。

## 0.11.10：修掉 Docker 托管里“宿主端口当成容器内端口”的错误

默认入口在 sing-box 容器内**固定监听 7890**，宿主机侧发布端口是 `.env` 里的 `SING_BOX_MIXED_PORT`（两者可以不一样）；自定义入口才是 `host:port == container:port` 一一对应。

代码里大多数地方都清楚这一点（`docker-network urls`、`docker-network env`、`snippet`、`verify` 的真实探测都特意用 `container_port`），但有三处漏了，会把宿主机端口当成“容器里该连的端口”告诉用户：

| 位置 | 之前 | 现在 |
| --- | --- | --- |
| `sbx docker-network manage` / 扫描并托管 完成后的回显 | `当前代理：http://sing-box:<宿主端口>` | `容器内代理：http://sing-box:<容器内端口>`；两者不同时补一行说明宿主机侧端口是多少 |
| 扫描并托管时的入口选择列表 | 显示入口的宿主端口 | 显示容器内端口（并说明这就是容器里要用的端口） |
| `sbx docker-network managed` 的 `PORT` 列 | 只有一列 `PORT`，实际是宿主端口 | 拆成 `HOST_PORT` 与 `CONTAINER_PORT` 两列，列宽按显示宽度对齐（中文不再顶歪后面的列） |

复现（0.11.10 之前）：把 `.env` 的 `SING_BOX_MIXED_PORT` 改成 `7895`，托管一个容器后提示 `http://sing-box:7895` —— 容器里连不上，正确值是 `7890`。

顺带把 `sbx docker-network verify` 的“托管关系”那行改清楚：端口一致时保持 `-> :7890` 不变，不一致时写成 `-> 宿主 :7895 / 容器内 :7890`；未纳入托管时的提示也改成按“容器内端口”检测。

遗留的 `port` 语义没有动：`docker-managed.json` 里旧版存的裸端口仍然是**宿主机端口**（迁移时按宿主端口匹配入口 ID），`verify docker <容器> <数字端口>` 的数字引用也仍按宿主端口匹配。

CI 增加了回归断言：把 `SING_BOX_MIXED_PORT` 改成 7895 后，`docker_network_inbound_ports` 必须返回 `7895 7890`、托管提示必须出现 `http://sing-box:7890` 且不得出现 `7895`、入口选择列表与 `managed` 列表都必须给出容器内端口。

## 0.11.9：菜单收敛（23 项 → 11 项，每项带说明）

0.11.8 把版式放大之后，主菜单反而更看不清了：一级 23 项（其中 12 项是进子菜单），二级再加 56 项，一共 79 个可选动作。问题不在“多”，而在三件事：

- **编号断档**：同一组里 `8 导入` 后面直接跳 `12 入口管理`。编号是按历史追加顺序长的，不是按逻辑排的。
- **概念撞名**：`应用代理` 和 `Docker 容器网络` 都带 Docker + 代理，光看名字分不出谁是宿主机、谁是容器；`7 订阅管理` 和 `8 导入` 能互相点到同一件事；四个“检查”（检查 / 测试代理 / 系统诊断 / Docker 验证）和四个“升级”（版本 / sing-box 升级 / 拉取当前镜像 / 管理器更新）散在四处。
- **二级菜单自己也在乱**：应用代理是 `1 2 3 4 5 6` 然后 `9`，再跳回 `7 8`；Docker 容器网络一家 15 项。

这一版按「你要做什么」重排（而不是按内部模块），一级收敛到 11 项，每项都带一行说明：

```text

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                         singbox-manager 0.11.9
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    sing-box: 运行中

  【日常】

     1  节点        列表 / 增删改 / 测试
     2  订阅与导入  订阅 / 分享链接导入
     3  出口与分流  出口策略 / 路由模式
     4  服务        状态 / 日志 / 启停

  【接入】

     5  入口路由    多个入口绑定出口
     6  宿主机代理  让 Docker/Git/APT 走代理
     7  容器接入    其它容器共享出口

  【维护】

     8  检查与诊断  配置检查 / 代理测试
     9  升级        sing-box / 镜像 / 管理器
    10  备份与恢复  备份 / 恢复 / 列表
    11  高级        手工编辑 / 安装信息

    0  退出

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

原来的 23 项这样归类：

| 原来的入口 | 现在的位置 |
| --- | --- |
| 1 状态 / 2 启动 / 3 停止 / 4 重启 / 5 日志 | 【服务】(4) |
| 6 节点管理 | 【节点】(1) |
| 7 订阅管理 + 8 导入 | 【订阅与导入】(2)，两处入口合成一处 |
| 9 出口策略 + 10 路由模式 | 【出口与分流】(3) |
| 12 入口管理 | 【入口路由】(5) |
| 11 应用代理 | 【宿主机代理】(6)，改名以免和容器侧混淆 |
| 21 Docker 容器网络 | 【容器接入】(7)，改名；15 项 → 11 项 |
| 13 检查 / 14 测试代理 / 17 版本 / 22 系统诊断 | 【检查与诊断】(8) |
| 18 sing-box 升级 / 19 拉取当前镜像 / 20 管理器更新 | 【升级】(9) |
| 15 备份 / 16 恢复 | 【备份与恢复】(10)，多一个「备份列表」 |
| 23 高级编辑 | 【高级】(11)，多「安装信息」和「命令速查」 |

配套变化：

- 条目一律「编号 + 名称 + 说明」单列排布，说明列按显示宽度对齐（中文按 2 列）。最长的说明也留有余量，紧凑版式（42 列）与宽松版式（60 列以上）都不会折行。
- 主菜单标题下多一行状态（`sing-box: 运行中 / 已停止`）；子菜单显示当前值（出口策略、路由模式、备份目录、管理器与 sing-box 版本）。
- 开关类动作合成一项、进去再选：`Watcher`、`共享网络`、`自动更新` 都是「1 开启 / 2 关闭」。
- 菜单里的动作失败不再把菜单一起带崩，一律回到菜单（原来 `restart` 之类的失败在 `set -e` 下会直接退出菜单）。
- 「重建配置」从节点菜单挪到【服务】，节点增删改本来就会自动重建；【节点】因此从 8 项变成 7 项。
- 命令行用法完全不变：`sbx status`、`sbx node test 2`、`sbx docker-network sync` 等照旧，这一版只动交互菜单。
- 顺手修掉 `sbx proxy help` 的一处文本损坏（`\n` 没展开、`sbx image` 那行串进了 `sbx proxy env` 的说明里）。

CI 新增菜单结构断言：主菜单必须 11 项、编号连续 `1..11`、每个条目都带说明且说明列对齐、11 个入口都能进到对应子菜单、旧分组名（服务控制 / 节点与入口 / 出口与分流 / 维护与诊断）不得残留。

## 0.11.8：菜单版式放大（行距 / 缩进 / 列宽 / 标题块）

先说清楚：终端里的**字号由终端自己决定**，脚本改不了。脚本能调的是版式，这一版把所有菜单重排了一遍：

```text

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                         singbox-manager 0.11.8
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  【服务控制】

     1  状态                 2  启动
     3  停止                 4  重启
     5  日志

  【节点与入口】

     6  节点管理             7  订阅管理
     8  导入                12  入口管理
```

具体变化：

- **标题块**：上下分隔线 + 居中加粗标题，并显示真实版本号（原来看起来是写死的 “0.11”）
- **行距**：区块之间留空行、标题后留空行、末尾留空行；条目比区块再缩进 2 格
- **列宽**：两列间距从 10 扩到 18，标题分隔线跟随终端宽度（40–72，取 `tput cols`）
- **窄终端自动降级**：少于 60 列时回到紧凑版式，不会折行
- 10 个菜单（主菜单、节点、订阅、导入、出口策略、路由模式、应用代理、入口路由、Docker 容器网络、管理器更新）统一改成同一套版式

开关：

```bash
SBX_MENU_DENSITY=compact sbx        # 回到 0.11.7 之前的紧凑版式
SBX_MENU_DENSITY=comfortable sbx    # 默认：宽松版式
```

想真正把字调大，只能在终端侧改字号（每种终端一次设置，长期生效）：

```text
Windows Terminal / Tabby     Ctrl + 加号 / Ctrl + 滚轮
GNOME Terminal / iTerm2      Ctrl + 加号 / Cmd + 加号
macOS Terminal               Cmd + 加号
PuTTY (Windows)              Window → Appearance → Font settings → 调大字号
```

## 0.11.7：黑底可读的终端配色（主色改明绿）

菜单标题/区块标题原来是暗青 `36`，在黑色背景的终端上偏暗（尤其深色主题 + 低亮度屏幕）。现在整体按“黑底也看得清”重新取色：

```text
主色（菜单/区块标题）  明绿 92      <- 原来是暗青 36
[INFO]                 明绿 92      <- 原来是 32 暗绿
[WARN]                 明黄 93      <- 原来是 33
[ERROR]                明红 91      <- 原来是 31
次要文字               浅灰 37      <- 原来是纯 dim(2)，黑底上几乎看不见
```

换色与关闭：

```bash
SBX_COLOR_ACCENT=96 sbx         # 换主色（96 明青、94 明蓝、1;36 加粗青…）
NO_COLOR=1 sbx                  # 关闭全部颜色（写日志/CI 时有用）
SBX_NO_COLOR=1 sbx              # 同上，管理器自己的开关
```

`install.sh` 与 `lib/sbx_bootstrap.sh`（首次装镜像时的 bootstrap 菜单）用同一套配色，`NO_COLOR=1` 一样生效。

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

节点操作不再要求你记 8 位 ID，也不需要先复制 ID 再粘贴。列表输出与 [节点管理](README.md#节点管理) 小节一致（六列：默认 / 序号 / 协议 / 名称 / 来源 / 地址），这里不再重复示例。

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

交互式“扫描并托管”的入口选择（0.10.1 起改为输入序号，提示语也不再带 `[default]`）：

```text
请选择代理入口 [1]:
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

该地址下需要保持与仓库一致的相对路径（共 17 项，与 `install.sh` 的 `SOURCE_REQUIRED` 一一对应）：

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
lib/sbx_inbound.sh
lib/sbx_docker_network.sh
lib/sbx_docker_targets.py
bin/sbx-docker-watch
lib/sbx_verify.py
lib/sbx_update.sh
bin/sbx-install
VERSION
```

> 此清单必须与 `install.sh` 的 `SOURCE_REQUIRED` 保持同步：镜像里缺任何一项，安装器都会判定该来源不完整并跳过它（或直接失败），别只同步前几个文件。

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

