# AI 对话功能设计（M8 AI 助手）

> 2026-08-11 brainstorming 完成。本规格进入 writing-plans 流程前的最终版本。

---

## 1. 概述

为 FNS Sync 插件增加 **AI 对话功能**：用户在 KOreader 阅读时，可针对高亮（或选中文字）向 AI 提问、多轮对话、让 AI 总结，最后把 AI 内容精简后加入 Obsidian 笔记。

**核心价值**：把"阅读 → 提问 → 整理笔记"三步合一，无需切换 App。

**主要场景**：
- 解释/答疑（古文翻译、专业术语、背景知识）
- 评论/扩展（评论观点、补充论据、起标题）
- 翻译（外文书高亮翻译）
- 讨论/追问（多轮对话探讨书里观点）

---

## 2. 用户故事

```
1. 用户读到一段话，想问 AI
2. 选中文字 → 弹出小菜单 → 点「问 AI」
3. 弹出 InputDialog，已自动填入「📖 原文摘录」
4. 用户输入问题（或点「翻译/解释/评论」快捷模板按钮）
5. 点「发送」→ 显示 loading → 调 AI API
6. 弹 TextViewer 显示：原文 + Q1 + A1
7. 用户可选：
   a) 点「继续问」→ 回到 InputDialog（带累积上下文）
   b) 点「让 AI 总结」→ 自动以"请总结以上对话"作为新 prompt 调 API
   c) 点「加到笔记」→ 把最后一条 AI 回复写入 FNS 笔记
   d) 点「关闭」→ 弃用
8. 点「加到笔记」后：
   - AI 内容作为独立 AI@ 块插入到笔记（紧跟关联的 HL@ 块之后）
   - 通过现有 FNS 同步推送到 Obsidian
   - toast「AI 内容已加入笔记」
```

---

## 3. 架构方案

### 选定：方案 A（Kindle 直连 AI API）

```
KOreader 插件 ──HTTP──▶ DeepSeek / OpenAI / Ollama
                          │
                          └─ 用户自配 base URL + API key + model
```

### 为什么选 A

| 维度 | 方案 A（直连） | 方案 B（FNS server 中转） | 方案 C（直连+代理） |
|------|--------------|----------------------|----------------|
| 实现复杂度 | 低 | 中（server 要扩） | 中 |
| API key 安全 | 中（Kindle 文件） | 高（server 集中） | 中 |
| OpenAI/Claude 支持 | ❌（Kindle 配代理难） | ✅ | ✅ |
| DeepSeek/国内服务 | ✅ | ✅ | ✅ |
| 单点故障 | 无 | FNS server | 无 |
| FNS server 跑题 | 否 | **是** | 否 |

**结论**：MVP 选 A。DeepSeek 兼容 OpenAI API 格式，覆盖国内主流场景。如果以后真需要 OpenAI/Claude，再升级到 B 或 C。

### 多 AI 服务的统一支持

所有目标服务都兼容 OpenAI Chat Completions API 格式：

| 服务 | base_url | 兼容性 |
|------|---------|--------|
| DeepSeek | `https://api.deepseek.com/v1` | ✅ 原生 |
| OpenAI | `https://api.openai.com/v1` | ✅ 本尊 |
| 通义/智谱 | （各自的 OpenAI 兼容端点） | ⚠️ 通过兼容模式或聚合层 |
| Ollama | `http://localhost:11434/v1` | ✅ 原生 |
| LM Studio | `http://localhost:1234/v1` | ✅ 原生 |

**插件不做适配层**——用户自己配 base_url + model_name + api_key，调统一的 `/chat/completions` 端点。

---

## 4. UI 流程设计

### 4.1 链式对话框

KOreader 没有原生聊天窗口组件，用现有 `InputDialog` + `TextViewer` 链式拼接实现多轮对话。

```
[1] 选中文字 / 长按高亮 → 菜单选「问 AI」
        ↓
[2] InputDialog：输入问题
    ┌────────────────────────────────┐
    │ 📖 原文摘录（自动填入，可编辑）  │
    ├────────────────────────────────┤
    │ [翻译] [解释] [评论]（快捷模板）│
    ├────────────────────────────────┤
    │ 输入你的问题：                  │
    │ ___________________________    │
    ├────────────────────────────────┤
    │            [发送] [取消]        │
    └────────────────────────────────┘
        ↓
[3] 调 /chat/completions（messages 带 system + user 摘录 + user 问题）
        ↓
[4] TextViewer 显示：
    ┌────────────────────────────────┐
    │ 📖 原文摘录                      │
    │ ──────                          │
    │ 🧑 Q1: ...                       │
    │ 🤖 A1: [AI 回复]                 │
    │ ──────                          │
    │ [继续问] [让 AI 总结]            │
    │ [加到笔记] [关闭]                │
    └────────────────────────────────┘
        ↓
   点「继续问」→ 回到 [2]，对话框带累积上下文
   点「让 AI 总结」→ 调 API（自动构造"请总结以上对话"作为新 user message）→ 回到 [4]
   点「加到笔记」→ 见 §5
   点「关闭」→ 弃用
```

### 4.2 上下文累积策略

每次调 API，messages 数组包含：

```lua
{
  {role = "system", content = system_prompt},
  {role = "user",   content = "【原文摘录】\n" .. excerpt},
  {role = "user",   content = Q1},
  {role = "assistant", content = A1},
  {role = "user",   content = Q2},
  {role = "assistant", content = A2},
  ...
  {role = "user",   content = 最新问题 or "请总结以上对话"},
}
```

原文摘录始终作为第一条 user message（system 之外），AI 每轮都看得见。

### 4.3 「让 AI 总结」按钮 vs 自然语言总结

**功能等价**：用户直接打字"请帮我总结以上对话"跟点按钮效果完全一样（因为完整历史都在上下文里）。

按钮只是**便利快捷方式**，省 Kindle 键盘打字。保留按钮，但用户可以选择不用。

---

## 5. 笔记格式设计（AI@ 块）

### 5.1 选定：格式 B（独立 AI@ 块）

```markdown
<!-- HL@2026-08-11 19:45:00 pos0="..." pos1="..." chapter="..." -->
> 📖 第 123 页
> 原文摘录内容...
<!-- /HL@2026-08-11 19:45:00 -->

<!-- AI@2026-08-11 19:48:00 hl="2026-08-11 19:45:00" model="deepseek-chat" -->
💬 AI 助手
> 这是 AI 总结的内容...
<!-- /AI@2026-08-11 19:48:00 -->
```

### 5.2 AI@ 块字段

| 字段 | 必需 | 含义 |
|------|------|------|
| `datetime`（在 `AI@` 后） | ✅ | AI 回复生成时间（格式 `YYYY-MM-DD HH:MM:SS`，跟 HL@ 一致），唯一 key |
| `hl` | ✅ | 关联的 HL@ 块 ts（多条 AI 可关联同一高亮） |
| `model` | ✅ | 用的模型名（deepseek-chat / gpt-4o / 等），便于追溯 |

### 5.3 "原文摘录"的精确定义

「原文摘录」= **高亮的纯文字内容**（`document:getTextFromXPointers(pos0, pos1)` 的返回值），**不是** excerpt.lua 渲染后的 markdown block。

→ 直接传纯文本给 AI，不带 markdown 引用块 `> ` 或页码前缀。

### 5.4 "加到笔记"的精确路径

走现有 FNS 同步路径，**不直接写本地 Obsidian 文件**：

```
点「加到笔记」
  ↓
ai.lua 构造 AI@ 块字符串
  ↓
main.lua 调用 _triggerSync（高亮本身的同步路径）
  ↓
FNS sync 把 AI@ 块作为 USER 内容一起同步到 server
  ↓
Obsidian 端拉取，AI@ 块出现在笔记里
```

→ AI@ 块**复用现有 M5 实时同步**，零额外网络逻辑。

### 5.5 为什么选 B

- **HL@ 块零修改** → M5/M6/M7 同步逻辑完全不动
- **可追溯**：AI@ 带 model + hl 关联
- **可演进**：未来加"重新生成 AI 总结"、"删除 AI 评论"等功能，独立单元好操作
- **跟 marker.lua 现有架构同构**——只要扩展支持 AI@ 的 parse/serialize/diff

---

## 6. 配置管理

### 6.1 配置文件：`plugin/fns_sync.koplugin/ai_config.lua`

```lua
return {
    enabled = true,
    base_url = "https://api.deepseek.com/v1",
    api_key = "sk-xxx",            -- 用户填写
    model = "deepseek-chat",
    system_prompt = "你是一个阅读助手，根据用户的高亮和问题给出简洁有用的回答。",
    max_tokens = 1024,
    temperature = 0.7,
    timeout_sec = 30,
    quick_prompts = {
        translate = "请把这段话翻译成中文",
        explain   = "请解释这段话的背景和含义",
        comment   = "请简要评论这段话的观点",
    },
}
```

**独立文件**，不混进 KOreader 全局 settings.reader.lua。

### 6.2 API key 输入方式（两种都支持）

- **方式 1（推荐）**：USB 连 Kindle → PC 编辑 `ai_config.lua` → 粘贴 key → 保存
- **方式 2**：菜单 → FNS 同步 → AI 助手 → 配置 → 输入 API key → InputDialog

### 6.3 安全性 trade-off

- API key 明文存在 Kindle 文件系统（跟 FNS token 同安全级别）
- 不做加密（YAGNI）：加密的 key 早晚要解密给 HTTP 用，加密只防"USB 翻文件"的小偷
- Kindle 丢失应对：登出 DeepSeek 后台撤销 key

### 6.4 快捷模板

InputDialog 顶部三个按钮 `[翻译] [解释] [评论]`，点一下自动填入对应 prompt。模板可在 `ai_config.lua` 自定义。用户也可不用快捷按钮，直接打字。

---

## 7. 实现细节

### 7.1 菜单入口

- **入口 A**：原文选中文字 → KOreader 选中菜单加「问 AI」选项
- **入口 B**：长按高亮列表里的某条 → 菜单加「问 AI」

两个入口都做，覆盖"边读边问"和"事后问"两种场景。

入口 B 通过 `config.ai_enabled` 控制显隐（默认 false，用户配置 ai_config.lua 后变 true）。

### 7.2 错误处理

| 场景 | 行为 | crash.log 标签 |
|------|------|--------------|
| 网络不通 | toast「无网络连接」 | `[FNS-AI] network unreachable` |
| API key 没配 | 弹「请先配置 AI 服务」→ 跳配置页 | `[FNS-AI] no api_key` |
| API 401（key 错）| toast「API key 无效」 | `[FNS-AI] 401 unauthorized` |
| API 429（限流）| toast「请求太频繁，30 秒后再试」 | `[FNS-AI] 429 rate limited` |
| API 5xx | toast「AI 服务异常」 | `[FNS-AI] 5xx` |
| 超时（>30s）| toast「请求超时」 | `[FNS-AI] timeout` |
| 响应格式异常 | toast「AI 回复解析失败」+ 显示原始返回 | `[FNS-AI] parse error` |

错误后**不退出对话框**，用户可改问题重试或主动关闭。所有错误打 `[FNS-AI]` 日志，便于诊断。

### 7.3 模块结构

```
plugin/fns_sync.koplugin/
├── main.lua               # 现有，注册「问 AI」菜单
├── marker.lua             # 现有，扩展支持 AI@ 块（parse/serialize/diff）
├── excerpt.lua            # 现有，不动
├── threeway.lua           # 现有，不动
├── config.lua             # 现有，加 ai_enabled 字段
├── ai_config.lua          # 🆕 独立 AI 配置文件
└── ai.lua                 # 🆕 AI 模块（HTTP 调用 + 对话框 UI + 错误处理）
```

**单一 `ai.lua` 集中所有 AI 逻辑**。`marker.lua` 扩展支持 AI@ 块（跟现有 HL@ 同构）。

### 7.4 跟 M5/M6/M7 兼容性（零回归）

- `marker.lua` parse 时识别 `type = "ai"` segment（跟 `type = "hl"` / `type = "user"` 并列）
- `marker.lua` diff 时 **AI segment 不参与**（跟 USER segment 一样原样保留）
- `marker.lua` serialize 时 AI@ 块原样输出

→ M5/M6/M7 同步逻辑**完全不动**。AI@ 块对现有同步透明，只是笔记里多了一些 `<!-- AI@... -->...<!-- /AI@... -->` 块。

---

## 8. 不做的事（YAGNI）

明确**不做**的功能，避免范围蔓延：

- ❌ **不存对话历史**：关掉窗口就清空，下次新对话从零开始
- ❌ **不做流式输出（streaming）**：KOreader HTTP 客户端不好处理 SSE，一次性返回就行
- ❌ **不多 API 并行调用**：一次只调一家
- ❌ **不重新生成 AI 总结**：MVP 不做"重新生成"按钮，用户不满意可手动新开对话
- ❌ **不做 token 计数 / 成本统计**：用户自己看 AI 服务后台
- ❌ **不加密 API key**：见 §6.3
- ❌ **不支持图片输入**（GPT-4V 等）：纯文本对话
- ❌ **不做对话导出**（导出为 markdown / json）：用户可用「加到笔记」一条条加

---

## 9. 后续演进（M9+ 候选）

记下来等 MVP 验证后再考虑：

- **多 API 路由**：用户配多个 AI 服务，按场景自动选（翻译用 DeepSeek，评论用 GPT-4）
- **本地 RAG**：把同本书的所有高亮做向量检索，AI 回答时自动带"相关上下文"
- **流式输出**：如果 KOreader HTTP 支持 SSE，做实时打字效果
- **AI 内容跨设备同步**：AI@ 块当前作为 USER 内容跨设备保留；M9 可加"AI@ 块识别"，B 设备拉取时知道这是 AI 内容
- **"重新生成"按钮**：基于关联 HL@ 的原文 + 历史 prompt，重新调 AI
- **快捷模板自定义 UI**：用户在 KOreader 里增删改 quick_prompts，不用 USB 编辑文件
- **Token 用量统计**：显示本次对话消耗多少 token，估算成本
- **OpenAI/Claude 支持（方案 B/C）**：如果用户真的需要，做 FNS server 中转

---

## 10. 验收标准

MVP 完成需要：

1. ✅ `ai.lua` 模块实现：API 调用 + 错误处理 + 链式对话框 UI
2. ✅ `ai_config.lua` 配置加载 + 校验
3. ✅ `marker.lua` 扩展支持 AI@ 块（parse/serialize/diff 不参与）
4. ✅ `main.lua` 注册「问 AI」菜单入口
5. ✅ `config.lua` 加 `ai_enabled` 字段
6. ✅ Kindle 实测：高亮 → 问 AI → 加到笔记 全流程跑通
7. ✅ Kindle 实测：DeepSeek API 调用成功，多轮对话有上下文
8. ✅ Kindle 实测：错误场景（无网络 / key 错 / 超时）toast 提示正确
9. ✅ Kindle 实测：AI@ 块通过 FNS 同步到 Obsidian 正确显示
10. ✅ M5/M6/M7 已有功能零回归

---

## 11. 风险与未知

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| KOreader 选中菜单 hook 困难 | 中 | 入口 A 受影响 | 退路：先做入口 B（高亮列表长按） |
| Kindle 网络不稳，AI 调用容易超时 | 高 | 用户体验差 | timeout 30s + 重试提示；用户可缩短问题 |
| DeepSeek API 偶发限流 | 中 | 短暂不可用 | 429 toast + 30 秒冷却 |
| `marker.lua` 扩展引入回归 bug | 低 | M5/M6/M7 同步坏 | 单元测试 + Kindle 回归实测 |
| API key 泄漏（Kindle 丢） | 低 | 财务损失（DeepSeek 额度被刷）| 文档告知用户：登出撤销 key |
| 多轮对话 token 累积成本 | 中 | 用户花冤枉钱 | max_tokens=1024；system_prompt 写"简洁" |

---

## 12. 参考资料

- DeepSeek API 文档：https://platform.deepseek.com/api-docs/
- OpenAI Chat Completions：https://platform.openai.com/docs/api-reference/chat
- KOreader InputDialog：`frontend/ui/widget/inputdialog.lua`
- KOreader TextViewer：`frontend/ui/widget/textviewer.lua`
- 现有项目 marker.lua：HL@ 块的 parse/serialize/diff/applyDiff（AI@ 块同构参考）
