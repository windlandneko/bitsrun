# bitsrun

北京理工大学有线校园网自动登录。纯 Swift，零第三方依赖，无定时轮询。

需要 macOS 13+ 和 Swift 6+（Xcode 或 Command Line Tools）。

```sh
./bitsrun install     # 首次输入校园网账号密码，保存到钥匙串
./bitsrun check       # 查询有线网认证状态
./bitsrun uninstall   # 卸载服务，保留钥匙串凭据
```

用户登录后自动运行；插线、网络变化或唤醒时检查 `10.0.0.55`，确认北理工页面后认证。请求绑定有线网卡，已有会话跳过；网络故障有限重试，最终失败通知一次。没有本机事件时，不主动检测服务端会话过期。

首次安装或代码更新可能需要钥匙串授权；日常联网不需要输密码。同一版本重复安装不替换应用。修改凭据可在“钥匙串访问”中删除 `bitsrun` 条目后重新安装。

认证算法来自 [BITNP/bitsrun](https://github.com/BITNP/bitsrun)，沿用 WTFPL 许可证。
