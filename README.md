# bitsrun macOS 自动登录

从 [BITNP/bitsrun](https://github.com/BITNP/bitsrun) 精简而来，只用于 macOS 有线校园网自动登录。保留上游的深澜编码算法与 WTFPL 许可证。

## 安装

需要 macOS、Xcode Command Line Tools、[uv](https://docs.astral.sh/uv/)。首次安装需要能下载 Python 及依赖的网络。

```sh
git clone https://github.com/windlandneko/bitsrun.git
cd bitsrun
uv run --no-project macos/install.py
```

按提示输入账号密码；网卡设备名可以留空自动识别。如果希望限定某个 USB 网卡，用 `networksetup -listallhardwareports` 查出设备名（例如 `en5`）再填写。

程序及独立 Python 环境安装到 `~/Library/Application Support/bitsrun`，由用户级 LaunchAgent 启动。之后可以移动或删除仓库目录。无需 sudo，用户登录后自动运行。

凭据位于 `~/.config/bitsrun/bit-user.json`，权限为 `600`，密码以明文保存在该文件中，不写入日志。重新安装即可修改配置。

## 行为

- `SCDynamicStore` 监听网卡 Link、IPv4 与全局 IPv4 变化，`NSWorkspace` 监听唤醒；启动时也检查一次。
- 平时只等待系统事件，没有定时轮询。合并事件，等待至少 2 秒，并限制事件检查的启动间隔为至少 15 秒。
- 只接受硬件端口名称含 Ethernet 或 LAN 的网卡。必须取得 IPv4，且通往 `10.0.0.55` 的路由经过该网卡。
- HTTP 连接绑定该网卡 IPv4，禁用环境代理，不跟随重定向。页面包含北理工和 srun 特征后才查询状态；已有任何账号在线都跳过。
- 使用截图中的 `http://10.0.0.55/srun_portal_pc?ac_id=43&theme=bit`，只在未登录时认证。发送凭据前再次检查路由，登录后核验账号。
- 每次事件至多尝试 3 次；网络失败在 5 秒、15 秒后有限重试。认证拒绝或配置错误不重试。每次检查最多 60 秒。
- 成功静默记日志；最终失败尝试发送 macOS 通知。通知显示取决于系统通知及勿扰设置。

没有登出、Raycast、状态表格、跨平台支持或定时保活。服务端会话静默过期而本机没有网络变化时，无法自动发现；下一次网络事件或唤醒会再次检查。页面特征用于避免误登录，不构成服务器身份的密码学验证。

## 日志与卸载

```sh
tail -n 30 ~/Library/Logs/bitsrun/auto.log
uv run --no-project macos/install.py --uninstall
```

卸载移除 LaunchAgent 和程序，保留凭据。若要彻底删除凭据，再手动删除 `~/.config/bitsrun/bit-user.json`。

## 验证

```sh
uv sync
uv run --with pytest pytest -q
uv tool run ruff check src macos tests
swiftc -O macos/Watcher.swift -o macos/watcher
```

模拟测试覆盖 Wi-Fi 跳过、非校园页面、已有在线会话、完整认证、认证过程中换网、断网及非法响应。测试不访问校园认证服务器。原生监听器已在 Apple Silicon macOS 编译；真实插线、唤醒和校园网认证需要在目标网络上验证。
