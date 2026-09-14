# SpotlightPlus

SpotlightPlus 是一个面向 macOS 27 的实验性工具，用于在正常地区可用性缓存会选择旧版界面的设备上，维持苹果原生 Enhanced Siri Assistant Island 界面。

它不会复制或重绘苹果界面，也不会替换 Spotlight。程序只维护 `GenerativeModels.Availability` 使用的当前用户偏好状态，实际界面仍由系统自带的 `com.apple.campo` 和 `CampoUIInternal.MacAssistantIslandCoordinator` 呈现。

> [!WARNING]
> 本项目使用未公开且可能随系统更新改变的内部状态，目前仅在作者本机的 macOS 27.0 `26A428` 上完成实验，尚未在其他 Mac、硬件型号或系统 build 上验证。它只能开放界面门控，不能绕过地区服务限制、下载缺失模型或保证 Siri/Apple Intelligence 的实际请求可用。欢迎在 [Issues](https://github.com/alanmacX/SpotlightPlus/issues) 报告其他设备上的结果和问题。

> [!IMPORTANT]
> 开机登录后，新 UI 不会立即出现。系统需要先完成 GMS 和 Campo 初始化，SpotlightPlus 通常需要约一分钟才能重新 patch 并切回新版 UI；此时无需手动打开 Siri AI.app。不同机器的等待时间可能略有差异。

## 实现效果

- 使用苹果原生新版 Assistant Island 界面；
- 不打开 Siri AI.app 的普通主窗口；
- Siri AI.app 仅作为苹果系统后台 UI 宿主存在；
- 登录到桌面后等待 Campo 就绪，自动修复状态并在后台重启一次，使其重新选择新版 coordinator；
- 登录后的前三分钟每两秒检查文件时间戳，只有发生变化才读取和修复状态，用于捕获 GMS/Campo 延迟初始化造成的二次覆盖；
- 状态文件变化时立即检查，另有每 5 分钟一次的兜底检查；
- 登录后的运行中，只有状态实际回退时才再次重启 Campo；
- 全程保持 SIP 开启；
- 不需要管理员权限。

## 修改范围

SpotlightPlus 只修改当前用户目录下与 Enhanced Siri 可用性有关的偏好：

- 将缓存中的 `ai.enhanced-siri` 标记为可用，有效期滚动维持为 7 天；
- 将对应的 CloudSubscription waitlist 项设为 `active`；
- 清除当前用户 GMS 拒绝原因；
- 从 ByHost 偏好中移除 `com.apple.Siri.EnhancedSiriDisablement`；
- 标记 Enhanced Siri 偏好为启用；
- 发布苹果已有的 availability Darwin notifications。

它不会：

- 关闭或修改 SIP；
- 写入 `/System`；
- 修改 eligibility 数据库；
- 安装 kext、系统扩展或注入代码；
- 执行 `open Siri AI.app`；
- 接管 Command–Space 全局快捷键；
- 自动提交文字、语音或 AI 请求。

## 系统要求

- macOS 27 或更高版本；
- 系统自带 `/usr/bin/python3`；
- 当前用户能够正常使用基础 Siri；
- 建议先退出其他用于强开 Siri/Apple Intelligence 的工具，避免偏好互相覆盖。

## 安装方法

在 Terminal 中进入仓库目录：

```bash
cd SpotlightPlus
chmod +x install.sh uninstall.sh
./install.sh
```

安装器会：

1. 在 `~/Library/Application Support/SpotlightPlus/Original` 保存逐文件原始快照；
2. 安装状态修复程序；
3. 创建当前用户 LaunchAgent；
4. 立即应用一次状态；
5. 通过系统 LaunchAgent 在后台重启 `com.apple.campo`，不会打开 Siri AI 主窗口。

安装完成后不需要手动打开任何 App。LaunchAgent 会在下次登录时自动运行；开机进入桌面后请等待约一分钟，再使用快捷键唤出新版 UI。

## 使用方法

使用系统已经设置的 Siri/键入 Siri 快捷键唤出 Assistant Island。项目不会自行修改你的键盘快捷键。

查看当前维护状态：

```bash
/usr/bin/python3 "$HOME/Library/Application Support/SpotlightPlus/state_tool.py" status
```

查看自动修复日志：

```bash
tail -f "$HOME/Library/Application Support/SpotlightPlus/repair.log"
```

正常稳定状态会显示：

```text
changed=no
cache_canUse=True
user_unifiedReasons=[]
byhost_availability=True
```

开机登录后的前三分钟，LaunchAgent 会短暂显示为运行中，用于消除系统服务初始化顺序造成的竞争。新版 UI 通常会在约一分钟内恢复。预热结束后显示 `state = not running` 是正常现象：它仍会由状态文件变化和五分钟兜底计时触发，并非常驻进程。

## 卸载与恢复

在仓库目录运行：

```bash
./uninstall.sh
```

卸载器会：

1. 停止并移除 LaunchAgent；
2. 恢复安装时存在的全部用户偏好文件；
3. 删除安装时原本不存在、后来才创建的目标文件；
4. 发布可用性变更通知；
5. 让系统后台 Campo 重新读取恢复后的状态；
6. 删除 SpotlightPlus 安装目录和备份。

卸载脚本会先检查备份完整性。如果缺少备份，它会拒绝继续，避免把用户设置恢复成未知状态。

本项目不会创建或管理以下管理员级 Feature Flag：

```text
/Library/Preferences/FeatureFlags/Domain/SpotlightUI.plist
```

如果你曾通过其他方法修改该文件，SpotlightPlus 不会在卸载时擅自删除，因为项目不知道它修改前的原值。

## 已知问题：语音按钮

当前机器上点击语音按钮时，界面能够进入 `siri(listening)`，但真实 Siri 会话随即失败：

```text
ChatService submit error: siriUnavailable
Failed to start voice recording
assistant_cdmd: Assets are missing
Query Understanding / EmbeddingService load failed
```

日志中没有在失败前出现麦克风/TCC 拒绝，因此问题不是简单的麦克风权限，而是 UI 已开放、真实 Siri 编排服务或模型资产仍不可用。当前版本不会尝试伪造 Voice、Thinking 或 Canvas 状态。

更详细的逆向结果见 [RESEARCH.md](RESEARCH.md)。

## 安全与隐私

- 脚本只在本机运行；
- 不包含网络请求；
- 不上传提示词、语音、日志或偏好文件；
- 仓库不包含任何苹果二进制、框架、模型或资源文件；
- 安装备份保存在用户本机，不应提交到 Git。

## 许可证

本项目代码采用 MIT License。Apple、Siri、Spotlight、Apple Intelligence、Campo 等名称和系统组件归 Apple Inc. 所有。
