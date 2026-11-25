# SpotlightPlus

SpotlightPlus 让 macOS 27 使用苹果原生的新版 Spotlight（Assistant Island）。界面由系统的 `com.apple.campo` 进程显示。这个项目能让新版搜索框出现；Siri AI、千问和模型下载仍由 macOS 管理。

## 实测结果

| 功能 | macOS 27.3 beta（`26C5047e`），国行配置 |
| --- | --- |
| 新版 Spotlight | 能打开。手动退出后台的 Siri AI 进程后，快捷键可能失效。 |
| 写作工具、照片「消除」 | 在实验配置中验证过原生校对和「消除」模型加载。写作工具的「创作」也成功用千问回答了测试问题。 |
| Spotlight 的 `Ask Qwen` | 菜单项能显示，点选后没有收到千问回复。 |
| 经典 Siri 转交千问 | 本次英文测试返回了百度搜索结果。 |
| Siri AI 会话 | 系统显示不可用。仅安装 SpotlightPlus 无法恢复会话或更换模型。 |

新版搜索框最初在 macOS 27.0 `26A428` 上验证。上表是同一台测试 Mac 的结果，其中写作工具和照片测试使用了本地实验配置，当前安装脚本未包含该配置。[调研记录](RESEARCH.md#macos-273-beta-复测)里列了复测细节。

## 安装

需要 macOS 27 或更新版本、系统的 `/usr/bin/python3`，以及能正常启动的基础 Siri。

在仓库目录运行：

```bash
./install.sh
```

安装脚本会备份原有偏好，安装当前用户的 LaunchAgent。它还会请求管理员权限，在 `/Library/Preferences/FeatureFlags/Domain/WritingTools.plist` 关闭实验性的文本选区 Ask Siri 输入框，避免这个浮层卡住 App 菜单。Spotlight 搜索框仍可使用。脚本不需要关闭 SIP，也不会修改 `/System`。

登录后通常等约一分钟，再按系统原有的 Spotlight 快捷键（默认 `⌘Space`）。启动较慢时，可以等到三分钟。可以关闭 Siri AI 的主窗口，请保留后台进程；退出进程后如果快捷键失效，用下面这条命令重新启动系统任务：

```bash
launchctl kickstart "gui/$(id -u)/com.apple.campo"
```

## 排查问题

- **按快捷键没弹窗，或总是旧版。** 等登录满三分钟，运行 `./diagnose.sh`。如果刚退出过 Siri AI，先用上面的命令启动后台进程。
- **新版能打开，`Ask Qwen` 或 `Ask Siri` 没答复。** 提交 Issue 时写清是哪一项、能否输入、点下去后是卡住还是出现提示。「创作」是否能用千问也一起注明。
- **选中文字后，右键菜单或 App 界面卡住。** 更新到最新版本，重新登录或重启，让安装脚本的写作工具设置生效。

诊断报告只记录系统版本、进程和安装状态、少量布尔设置，并留出位置让你填写实际表现。脚本不会上传报告。贴到 [Issues](https://github.com/alanmacX/SpotlightPlus/issues) 前请先检查内容。

如需在本机看维护状态和完整日志：

```bash
/usr/bin/python3 "$HOME/Library/Application Support/SpotlightPlus/state_tool.py" status
tail -f "$HOME/Library/Application Support/SpotlightPlus/repair.log"
```

LaunchAgent 平时可以显示 `not running`；它会在登录、相关文件变化或五分钟定时检查时运行。

## 卸载

```bash
./uninstall.sh
```

卸载脚本会先检查安装备份，再停止 LaunchAgent，恢复用户偏好和安装前的 `WritingTools.plist`，最后移除安装目录。备份缺失时会停止。`/Library/Preferences/FeatureFlags/Domain/SpotlightUI.plist` 由其他工具管理时，SpotlightPlus 不会动它。

## 许可证

[MIT](LICENSE)。Apple、Siri、Spotlight 与 Apple Intelligence 是苹果的产品或组件。本仓库不分发苹果系统二进制或模型。
