# 状态与记忆管理

[English](state_and_memory.md) | [简体中文](state_and_memory.zh-CN.md)

## `AgentState`

`AgentState` 是 Agent 生命周期内发生的一切的可序列化快照。它挂在 `StatefulAgent` 上，并在每回合后更新。

关键字段：

| 字段 | 类型 | 说明 |
|-------|------|-------------|
| `sessionId` | `String` | 本会话的唯一标识 |
| `history` | `AgentMessageHistory` | 对话消息 + 情节记忆 |
| `usages` | `List<ModelUsage>` | 所有 LLM 调用的 Token 用量记录 |
| `metadata` | `Map<String, dynamic>` | 用户自定义数据（例如 user ID、偏好） |
| `plan` | `PlanState?` | 规划器当前的 todo 列表 |
| `activeSkills` | `List<String>?` | 当前激活技能的名称 |
| `isRunning` | `bool` | Agent 是否在运行中（用于 resume） |
| `totalLoopCount` | `int` | 跨所有 run 的 LLM 调用总数 |
| `currentLoopCount` | `int` | 当前 run 的 LLM 调用次数 |
| `currentLoopUsages` | `List<ModelUsage>` | 仅当前 run 的 Token 用量记录 |
| `lastError` | `String?` | 上次失败 run 的错误信息 |
| `systemReminders` | `Map<String, String>` | 动态 per-request 备注，会插入到最后一条用户消息之前 |
| `systemPromptHistory` | `List<SystemPromptHistoryItem>` | 按消息索引保存的系统提示词快照 |
| `toolsHistory` | `List<ToolsHistoryItem>` | 按消息索引保存的工具列表快照 |

> 注意：`Tool` 与 `Skill` 的*定义*由 `StatefulAgent` 持有，不在 `AgentState` 中。`AgentState.activeSkills` 只以字符串存储当前激活技能的名称。

---

## `AgentCallToolContext`

Agent 执行工具时，会把调用包在携带 `AgentCallToolContext` 的 Dart `Zone` 中。工具函数因此可以访问会话状态，无需显式参数：

```dart
String checkBalance(String currency) {
  final context = AgentCallToolContext.current;
  final userId = context?.state.metadata['user_id'] as String?;
  return fetchBalance(userId, currency);
}
```

通过 `AgentCallToolContext.current` 可访问：
- `state`：实时 `AgentState`
- `agent`：正在运行该工具的 `StatefulAgent`
- `batchCallId`：同一并行批次中所有工具共享的 UUID
- `cancelToken`：当前 run 的 `CancelToken`

---

## `FileStateStorage`

`FileStateStorage` 把 `AgentState` 以 JSON 文件持久化到磁盘。每个会话对应给定目录下的一个 `$sessionId.json` 文件。

```dart
final storage = FileStateStorage('.state_dir');

// 加载已有状态，或使用初始 metadata 创建新状态
final state = await storage.loadOrCreate('session_123', {
  'user_id': 'u_001',
  'premium_status': 'gold',
});

final agent = StatefulAgent(
  name: 'my_agent',
  client: client,
  modelConfig: modelConfig,
  state: state,
  // 每个工具批次完成后以及 finally 中调用
  autoSaveStateFunc: (s) async => await storage.save(s),
);
```

`FileStateStorage` 的其他方法：

```dart
await storage.save(state);             // 显式保存
await storage.delete('session_123');   // 删除会话
final exists = await storage.exist('session_123');
```

### Metadata 合并

用 `loadOrCreate` 加载已有会话时，传入的 `initialMetadata` 默认会**合并进**已有 metadata（已有 key 会被覆盖）。若会话已存在且不想合并，传入 `overwrite: false`。

---

## `LLMBasedContextCompressor`

长会话最终会超出模型 Token 上限。挂载 `LLMBasedContextCompressor` 可自动处理。

当 Token 数量（以最近一次 `ModelUsage.promptTokens` 衡量）超过 `totalTokenThreshold` 时，压缩器会：
1. 取出除最近 `keepRecentMessageSize` 条以外的全部消息
2. 用总结提示词发给 LLM
3. 把结果存为 `EpisodicMemory`（压缩后的 XML 快照 + 原始消息）
4. 在活动上下文中用简短摘要占位符替换旧消息

```dart
final compressor = LLMBasedContextCompressor(
  client: client,
  modelConfig: ModelConfig(model: 'gpt-4o-mini'),
  totalTokenThreshold: 64000, // 默认
  keepRecentMessageSize: 10,  // 默认
);

final agent = StatefulAgent(..., compressor: compressor);
```

压缩器始终保持 `FunctionCall` / `FunctionExecutionResult` 成对完整 —— 决定压缩范围时不会把工具调用与其结果拆开。

---

## 情节记忆（Episodic Memory）

压缩后的历史保存在 `AgentState.history.episodicMemories` 的 `EpisodicMemory` 条目中。每条包含：
- `id`：短随机 ID（例如 `episode_aB3xYz`）
- `summary`：压缩器生成的 XML 状态快照
- `messages`：压缩前的原始消息

摘要会作为 `UserMessage` 注入活动上下文，因此模型始终能看到过去事件的结构化概览。模型还会看到 episode ID，并被告知可调用 `retrieve_memory` 获取完整原始消息。

### `retrieve_memory` 工具

存在情节记忆时，Agent 会自动获得 `retrieve_memory` 工具：

```dart
// Agent 在需要精确历史细节时内部调用
// 工具参数：
// - snapshot_id（必填）：例如 'episode_aB3xYz'
// - limit（可选）：最多返回多少条消息（默认 20）
// - offset（可选）：分页偏移（默认 0）
```

这样 Agent 可以在摘要不够详细时取回原文，而不必把全部历史重新加载进活动上下文。

---

## `systemReminders`

`AgentState.systemReminders` 是 `Map<String, String>`，保存每次 LLM 调用前注入请求的短备注。备注会包在 `<system-reminders>` XML 标签中，并作为 `UserMessage` 插入到请求消息列表中最后一条 `UserMessage` 之前。

```dart
agent.state.systemReminders['current_time'] = DateTime.now().toIso8601String();
agent.state.systemReminders['rate_limit'] = 'User has 3 requests remaining today.';
```

备注会持久化在状态中，并包含在之后的每次 LLM 调用里，直到被移除。删除 map 中对应 key 即可移除。
