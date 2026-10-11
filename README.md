# bitsrun · 原生 macOS 校园网自动登录

插上网线，剩下的交给系统事件。

专用于北京理工大学 `10.0.0.55` 深澜认证的 macOS 小工具。一个 Swift 可执行程序，零第三方依赖。使用系统框架监听网络、绑定有线接口、完成认证、保存凭据和发送通知；平时没有定时任务或轮询请求。

认证协议与编码算法来自 [BITNP/bitsrun](https://github.com/BITNP/bitsrun)，沿用 WTFPL 许可证。

## 使用

需要 macOS 13+、Swift 6+ 工具链（Xcode 或 Command Line Tools）。

```sh
git clone https://github.com/windlandneko/bitsrun.git
cd bitsrun
./bitsrun install
```

首次运行会编译。先在本地 `.env` 中填写 `USERNAME`、`PASSWORD`，再安装；也可以指定其他凭据文件：

```sh
./bitsrun install --env .env
```

文件使用 `USERNAME=...`、`PASSWORD=...`，可选 `INTERFACE=en7`。值可包裹单引号或双引号；不执行文件内容，不进行变量展开。密码不会进入命令参数或日志。`.env` 已被 Git 忽略；导入后后台服务只读取钥匙串，不再依赖该文件。

安装程序创建仅用于后台运行的 `Bitsrun.app`，进行本机 ad-hoc 签名并注册用户级 LaunchAgent，无需 sudo 或 Apple 开发者证书。服务位于 `~/Library/Application Support/bitsrun/Bitsrun.app`，用户登录后启动。安装完成后可以删除仓库目录。

程序使用传统登录钥匙串，后台读取不弹授权窗口。同一版本重复安装不替换应用，相同凭据不重写钥匙串。临时签名的身份随代码变化；更新版本时可能需要一次 Mac 登录密码授权，日常插线和重连无需输入密码。如果钥匙串锁定、拒绝访问，或更新程序后系统要求重新授权，请解锁钥匙串或重新运行安装命令。通知是否显示取决于系统通知和勿扰设置。

## 行为

- **等待事件。** 原生订阅网卡 Link、IPv4、全局 IPv4 变化和系统唤醒；启动时由网络路径监视器提供初始状态。
- **等待网络稳定。** 合并短时间内的事件，防抖 2 秒；相邻事件检查批次至少间隔 15 秒。新事件取消旧任务及其 TCP 连接。
- **限定有线。** 使用系统网卡类型识别 Ethernet，取得对应 IPv4；每条 TCP 连接同时限定这张网卡与源地址。认证流量不使用环境代理，不因默认路由变化切换到 Wi-Fi。
- **确认校园网。** 访问 `http://10.0.0.55/srun_portal_pc?ac_id=43&theme=bit` 并检查北理工、srun 特征。拒绝 HTTP 重定向。其他网络或不可达的认证页面保持静默。
- **只在需要时认证。** 已有任何账号在线都跳过；未登录时校验设备 IP，完成 challenge、SRBX1、HMAC-MD5 和 SHA-1 流程，最后重新查询在线账号确认结果。
- **有限恢复。** 每个事件批次最多尝试 3 次，网络错误在 5 秒、15 秒后重试；每个 HTTP 请求最多 5 秒。认证拒绝不重试。
- **安静反馈。** 成功写入系统日志；识别校园网后仍最终失败时通知一次，恢复成功后才再次允许失败通知。非校园网页面的探测失败不会通知。

服务端会话静默过期、而本机没有任何网络或唤醒事件时，程序不会主动发现。这是事件驱动方案的边界。页面特征用于识别网络，并不提供 HTTP 服务器身份的密码学验证。

## 检测与维护

```sh
# 真实访问有线认证服务，查询状态；不读取密码，也不提交登录
./bitsrun check

# 重新导入 .env 或更新已安装程序
./bitsrun install

# 卸载服务，保留钥匙串凭据
./bitsrun uninstall

# 查看最近的系统日志
log show --last 10m --style compact --predicate 'subsystem == "local.bitsrun.auto"'
```

凭据可在“钥匙串访问”中搜索 `bitsrun` 后手动删除。

安装先构建并签名临时应用，再切换服务。配置或加载失败会尝试恢复原应用、LaunchAgent 配置和运行状态；新录入的钥匙串凭据会保留。

## 代码

只有四个职责明确的源文件：

| 文件 | 职责 |
| --- | --- |
| `Authentication.swift` | 深澜编码、认证流程、JSONP 解码；不依赖系统网络状态 |
| `Transport.swift` | 原生有线接口绑定、可取消 TCP 请求、有界 HTTP 解析 |
| `Service.swift` | 钥匙串、事件合并、有限重试、通知与系统日志 |
| `Command.swift` | 命令入口、安装回滚、卸载与真实状态检测 |

`bitsrun` 只是一个极小的 zsh 启动器：用系统 Swift 编译，然后执行程序。已安装的服务直接运行编译好的二进制，不执行 shell、Python、curl 或其他子进程。

```sh
swift test
swift format format --in-place --recursive Sources tests Package.swift
swift format lint --strict --recursive Sources tests Package.swift
swift build --configuration release
```

使用 Swift 6 并发检查、系统格式化器和两空格缩进。单元测试仅保留上游认证编码基准（普通字符、转义字符、中文和 emoji）及 HTTP 分片、异常响应解析；不保留模拟认证服务器。登录与事件触发使用下面的真实校园网实测验证。

已在真实校园网上，将默认联网切至 Wi-Fi，并独立绑定 `en7` 完成以下实测：

- 有线会话登出后，用真实凭据重新认证；服务器确认账号与有线 IP 一致。
- 重复登录正确跳过现有会话；取消实际网络请求能够中止任务。
- Wi-Fi 在有线会话登出、网络服务关闭期间仍保持在线。
- 安装后的后台进程从钥匙串取凭据，并在启动时完成自动登录。
- 停止后台服务时有线保持离线，重新启动后恢复认证。
- 关闭、启用有线网络服务触发真实系统事件；原进程自动恢复认证。
- 进程正常退出后，launchd 自动重新拉起。

实测完成后恢复原网络优先级。尚未执行整机睡眠/唤醒实测，也没有故意提交错误密码。
