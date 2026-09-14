# macOS 27 Campo UI 调研记录

验证环境：macOS 27.0 `26A428`。信息来自本机系统 dyld export、系统 plist 与 unified log。以下均为苹果未公开的实现细节，不属于稳定 API。

## Assistant Island 状态模型

`CampoUIInternal.MacAssistantIslandSessionModel.IslandState` 包含：

- `hidden`
- `prompt`
- `siri(SiriState)`

其中 `SiriState` 包含：

- `listening`
- `thinking`
- `response`
- `transient`

当前 GMS 缓存实验能够安全选择的是 `prompt` UI。`siri(...)` 不是几套可以独立展示的皮肤，而是实际 Siri chat session 的运行状态。

## 语音按钮为何失败

实测日志顺序：

```text
AssistantIsland: prompt -> siri(listening)
AgentCanvasKit.ChatService: submit error: siriUnavailable
AssistantIsland: Failed to start voice recording
assistant_cdmd: Assets are missing
QueryUnderstanding: EmbeddingService / QU model load failed
```

失败前没有麦克风或 TCC 拒绝。`activateVoiceMode(for:)` 在切换到 listening 后会向真实 Siri ChatService 提交会话，因此仅开放 UI availability 不足以让语音工作。

框架本身还定义了：

```text
MacAssistantIslandSessionModel.SessionError.chatServiceUnavailable
```

这与本机的 `siriUnavailable` 错误边界一致。

当前用户偏好虽然报告基础 Siri 已启用、语言为 `en-US`、期望编排模式为 FullUOD，但这不等于 CDM、Query Understanding、Linwood 资产或受限服务端已经可用。继续伪造布尔值只会让界面宣称一个后端并不具备的能力。

## 其他原生 Scene

`CampoServices.CampoUIService.PresentationRequest.SceneType` 暴露了以下场景：

| Scene | 结论 |
| --- | --- |
| `assistantField` | 原生 prompt-field 窗口；直接调用默认只得到紧凑小输入条，与当前 availability 选中的 Assistant Island 重复。 |
| `assistantMenu` | 可能是纯 UI 候选，但需要正确的来源窗口和 frame。适合作为下一步隔离实验。 |
| `lightweightToolsMenu` | 与写作工具/文本选择上下文绑定，需要有效来源 App 和选择范围。 |
| `activitySearch` | 原生 Spotlight 搜索场景，不是目标 Assistant Island。 |
| `transientCanvas` | 需要 chat/request configuration，会进入真实 Canvas 会话，不是纯 UI。 |
| `activityThinking` | 需要有效请求；强制显示会产生虚假或卡死的 thinking 状态。 |
| `activityVoice` | 会调用同一个当前不可用的 Siri 语音/聊天后端，不应自动启用。 |
| `app` | 打开完整 Siri AI 主窗口，本项目明确排除。 |
| `standby` | 内部待机/预热场景，没有独立的用户价值。 |

`CampoUIInternal` 还导出了 `AssistantMenuWindowState`、`CampoCanvasWindowState`、`InlineThinkingWindowState`、`FullAppWindowState` 和 Spotlight continuation。Canvas 与 Inline Thinking 的构造器都需要 `AgentCanvasKit.ChatRequestConfiguration`，这就是“显示原生 UI”和“启动真实 AI 会话”之间的重要边界。

## 后续可安全实验的方向

1. 在提供有效 source-window descriptor 的情况下检查 `assistantMenu`；
2. 在真实可编辑文本选择中检查 `lightweightToolsMenu`；
3. 每次实验只观察窗口和状态转换，失败时立即关闭；
4. 在资产和服务可用性能够独立证明之前，不调用 `startVoice`、`startListening`、`submitIslandPrompt`、Canvas 或 Thinking 测试接口。

正式安装的 LaunchAgent 不会执行上述实验。它只维护已经验证过的 Enhanced Siri UI 可用性缓存。
