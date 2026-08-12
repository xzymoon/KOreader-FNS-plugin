# 2026-08-12 开发进度

## 主要任务

**全天（M8 AI对话功能：失败回滚 → 调研 → 计划 → 重新实施 Task A/B/C）**

- 上午-下午：第一次 M8 实施失败，因多个未解决的技术问题导致长按闪退，回滚到 8月11日版本
- 下午-晚上：基于回滚复盘做 4 方向调研（高亮菜单 / HTTP / 对话框 / require 缓存），产出调研报告 + 实施计划，用 subagent-driven-development 重新实施 Task A/B/C，全部 Kindle 实测通过

## 阶段总览

| 阶段 | 时间 | 内容 | 结果 |
|------|------|------|------|
| 一 | 上午-下午 | M8 第一次实施 + 闪退 + 回滚 | 失败，回到 8月11日晚版本 |
| 二 | 下午 | 4 方向机制调研（3 个 general-purpose agent 并行） | 修正设计 12 处错误假设 |
| 三 | 晚上 | writing-plans 产出实施计划（5 任务 ~50 步骤） | 计划通过自检 |
| 四 | 晚上 | subagent-driven-development 执行 Task A/B/C | 本地 + Kindle 实测全通过 |

---

## 阶段一：M8 第一次实施失败与回滚

### 故障经过（盲目实现 → 缺乏调查 → 越修越坏 → 回滚）

| 时间 | 事件 |
|------|------|
| 上午 | 添加 ai.lua、ai_config.lua 等 M8 核心模块 |
| 上午 | main.lua 添加"问 AI"菜单项和 _askAI() 方法 |
| 下午 | 发现两个问题：API配置无法加载、长按高亮菜单没有按钮 |
| 下午 | 没有调查问题根因，直接写代码修复 |
| 下午 | 修复后发现问题依然存在：API仍显示未配置、高亮菜单仍没有按钮 |
| 晚上 | 用户要求全盘审查 M8 代码，发现多个错误 |
| - | aiConfigOverrideLoader 使用 require，导致缓存问题 |
| - | onShowHighlightMenu 事件根本不会被 KOReader 调用 |
| - | 缺少 init() 中的高亮按钮注册代码 |
| 晚上 | 根据调查结果修复代码，重新提交 |
| 晚上 | 用户测试发现长按直接闪退，比之前更严重 |
| 晚上 | 用户要求回滚到 8月11日晚上的版本 |
| 晚上 | 执行 `git reset --hard b219caf`，删除所有 M8 代码 |

### 根本问题

1. **没有先调查就写代码**：没看 qrclipboard 等参考插件、没看 KOReader 源码、假设了错误的事件名 `onShowHighlightMenu`
2. **配置加载机制理解错误**：没理解 require 的 package.loaded 缓存机制
3. **缺乏防御性编程**：没检查 nil 边界情况

### 回滚详情

**删除**：ai.lua、ai_config.lua、ai_config_override.lua.example、tests/test_ai*.lua、marker.lua 中的 AI@ 块支持代码、main.lua 中的所有 M8 相关代码

**当前状态**：插件恢复到 8月11日晚版本（只有 FNS 同步 M1-M7）

### 经验教训

1. **永远不要基于猜测写代码**：先看参考代码 → 再看源码 → 然后写代码
2. **不要让用户测试未审查的代码**
3. **越修越坏时立即停止**：回滚到最后一个工作版本，重新调查

---

## 阶段二：4 方向机制调研（修正设计假设）

### 调研方法

3 个 general-purpose agent 并行调研，每个 agent 完整读 KOReader 源码（`E:\koreader-src`）+ qrclipboard 参考插件 + 本项目现有代码，独立产出 markdown 章节。

### 调研方向

1. **高亮菜单扩展机制**：读 `readerhighlight.lua` + `qrclipboard.koplugin` 完整源码
2. **HTTP 客户端 + 异步 + JSON**：读 kosync/wallabag 等插件 + 项目现有 api.lua
3. **InputDialog / TextViewer + require 缓存**：读 widget 源码 + pluginloader.lua

### 关键调研结论（修正设计规格 12 处错误假设）

最关键的 3 处：

| # | 设计文档原假设 | 调研真相 | 修正方向 |
|---|---|---|---|
| 1 | "KOReader 调用 `onShowHighlightMenu` 事件，插件可拦截" | KOReader 不广播此事件；它是 ReaderHighlight 自己的普通方法 | 改用 `self.ui.highlight:addToHighlightDialog(idx, fn_button)` 注册（qrclipboard 同款） |
| 2 | "独立 `ai_config.lua` 文件，用户 USB 编辑" | require 的 package.loaded 缓存导致用户改文件不生效 | 配置塞进 `G_reader_settings["fns_sync"]`，复用 Config.DEFAULTS + 迁移机制 |
| 3 | "USB 编辑文件 + 菜单输入 两种 API key 输入方式" | KOReader 一贯用 G_reader_settings，从不让用户编辑独立 lua | 仅保留菜单 `_editString` 输入 |

其他 9 处修正详见 `docs/superpowers/research/2026-08-12-koreader-m8-research.md` §5。

### 产出

- `docs/superpowers/research/2026-08-12-koreader-m8-research.md`（约 1100 行，含 7 章节 + 附录）

---

## 阶段三：实施计划（writing-plans）

### 计划结构

5 个串行任务 + ~50 个步骤：

```
Task A 配置基础设施（TDD）
  → Task B HTTP 调用层 ai.lua（Kindle 实测）
    → Task C 高亮菜单按钮注册（Kindle 实测）
      → Task D 链式对话框 UI（Kindle 实测）
        → Task E AI@ 块 marker.lua 扩展（TDD + Kindle 实测）
```

**强制纪律**：每步独立 commit + Kindle 实测通过再进下一步。**禁止堆叠修复**（这是早上回滚的直接原因）。

### 设计修正块（写在计划头部）

- ❌ 取消独立 ai_config.lua → ✅ 配置塞进 G_reader_settings
- ❌ 取消 USB 编辑入口 → ✅ 仅菜单 _editString
- ❌ override onShowHighlightMenu → ✅ addToHighlightDialog() 钩子
- ❌ 引入 Trapper/Spoke → ✅ 沿用 api.lua 同步模式
- ⚙️ Timeout 升级：30s → `{block=10s, total=60s}`（给 DeepSeek 30s 推理留余量）

### 自检结果

- 规格覆盖度：设计规格 17 个章节全部有对应任务
- 占位符扫描：无 TODO/待定
- 类型一致性：字段名/方法签名/常量名跨任务对齐

### 产出

- `docs/superpowers/plans/2026-08-12-m8-ai-chat.md`（约 1100 行）

---

## 阶段四：subagent-driven-development 执行 Task A/B/C

### 流程

新建 `feat/m8-ai-chat` 分支（master 是技术红线，必须 feature branch）。每个任务：
1. 分派实现者子代理（完整任务文本 + 上下文，不让子代理读计划文件）
2. 实现者完成 + 自审 + 报告状态（DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT）
3. 分派规格合规审查子代理（独立验证，不信任实现者报告）
4. 分派代码质量审查子代理（code-reviewer agent）
5. 修复审查发现的问题（关键/重要必修，次要可选）
6. 标记任务完成 → 进入下一个

### Task A：配置基础设施 ✅

**改动**：
- `config.lua`：`Config.DEFAULTS` 加 9 个 AI 字段（ai_enabled / ai_api_base / ai_api_key / ai_model / ai_system_prompt / ai_max_tokens / ai_temperature / ai_timeout_sec / ai_quick_prompts）
- `config.lua`：`CURRENT_CONFIG_VERSION` 4 → 5
- `config.lua`：新增 `Config.AI_HTTP_TIMEOUTS = { 10, 60 }` 常量
- `main.lua`：init() 加 v4→v5 迁移块（no-op log marker）
- `tests/test_config_ai.lua`：新建，16 项断言（含 `package.preload["gettext"]` mock 解决本地 Lua 测试的 gettext 依赖）

**TDD 流程**：写失败测试 → 跑测试看 FAIL → 改 config → 跑测试看 PASS → commit

**审查**：
- 规格合规 ✅
- 代码质量 WARNING（预防性 1 重要 + 3 次要）→ 修 1 重要（main.lua:80-83 backfill NOTE 扩展，列出 color_emoji_map + ai_quick_prompts 两个 table 字段）+ 1 次要（config.lua:209-216 占位符契约说明）

**Commits**：
- `a55ac37` feat(M8 Task A): AI 配置基础设施（DEFAULTS + 版本迁移 + 测试）
- `3629f51` docs(M8 Task A): code review fixes（table 字段引用 + 占位符契约）

### Task B：HTTP 调用层 ai.lua ✅

**改动**：
- 新建 `plugin/fns_sync.koplugin/ai.lua`（189 行 → 修复后 188 行）
- `Ai:_rawRequest(settings, body)` — 底层 luasocket POST，结构对齐 api.lua（URL 归一化 / rapidjson `.0` 修复 / Bearer auth / 错误归一化）
- `Ai:chat(settings, messages)` — 高层接口，10 个错误分支（base/key 空 / 网络 / 401 / 429 / 5xx / 其他 / JSON / 无 choices / 空 content）+ 1 个成功路径
- 不写 UI（Task D 做），不写单元测试（项目对 HTTP 集成无单测传统，靠 Kindle 实测）

**审查**：
- 规格合规 ✅（11 个分支全覆盖，模式真对齐 api.lua）
- 代码质量 APPROVED（0 关键/重要/中等，3 次要）→ 修 1 次要（删除 unused `util` import）

**Commits**：
- `a33fbb3` feat(M8 Task B): AI HTTP 调用层（ai.lua，无 UI）
- `688144e` refactor(M8 Task B): 删除 ai.lua 的 unused util import

### Task C：高亮菜单按钮注册 ✅

**改动**：
- `main.lua`：init() 末尾追加 56 行 addToHighlightDialog 注册代码
- 钩子用 `self.ui.highlight:addToHighlightDialog("12_fns_ask_ai", fn_button)`（不是事件 override）
- fn_button 闭包返回 `{ text="问 AI", show_in_highlight_dialog_func, callback }`
- callback 提前捕获 selected_text → `this:onClose(true)` → InfoMessage 占位 → `scheduleIn(0.1, clear)`
- 完整 InputDialog/TextViewer 在 Task D 实现

**审查**：
- 规格合规 ✅（钩子机制正确，回滚根因不复现，未"顺手"做 Task D）
- 代码质量 APPROVED（0 关键/重要/中等，3 次要都可选；Task D 会重写 callback 时一并处理）

**Commit**：
- `740cf57` feat(M8 Task C): 注册"问 AI"高亮菜单按钮（callback 占位）

### Kindle 实测（每任务后必做）

**Task A+B 实测**（看 2 个文件验证）：
- `crash.log` 有 `[FNS] migrated settings v4→v5` ✅
- `settings.reader.lua` 含 9 个 ai_* 字段 + config_version=5 ✅
- KOReader 启动 + M5 自动同步正常 ✅

**Task C 实测**（修改 settings.reader.lua 临时开 ai_enabled=true + ai_api_key="sk-test"）：
- 入口 A（选中新文字）：菜单出现"问 AI"按钮 ✅
- 入口 B（长按已有高亮 → "…" → 主菜单）：菜单出现"问 AI"按钮 ✅
- 点按钮：看到 InfoMessage 占位（选区 69 字符 / 190 字符），**不闪退** ✅
- crash.log 有 `[FNS] registered '问 AI' button` + `[FNS-AI] ask-ai button clicked` ✅
- M5/M6/M7 零回归 ✅
- 实测后恢复配置（ai_enabled=false, ai_api_key=""）

**关键里程碑**：2026-08-12 早上回滚的直接原因（长按闪退）已不复现。

---

## 子代理工作流经验

### 成功点

1. **三阶段审查有效拦住问题**：实现者 → 规格审查 → 代码质量审查。规格审查者每次都"独立验证不信任报告"，发现了几个实现者报告与实际不符的地方（如 ai.lua 加载冒烟测试声称通过但实际复现困难）
2. **修复循环成本低**：每个 LOW 级别修复用 haiku 模型，1-2 分钟搞定
3. **不让子代理读计划文件**：完整任务文本直接粘贴到 prompt，避免上下文污染
4. **feature branch 隔离**：feat/m8-ai-chat 比 master ahead 6 个 commits，可整体回滚

### 教训

1. **子代理会遵守"修改前先问"规则**：第一次分派修复任务时，子代理问"现在是否可以开始进行改动？"——必须在 prompt 里**明确告知**"你已经获得授权做这次特定修改，不要再询问"
2. **KOReader 没有内置 Lua console**：之前 plans 假设有 Lua console，调研后发现没有。Kindle 实测改成"看 crash.log + settings.reader.lua 两个文件"的纯肉眼方法
3. **实测清单要给非程序员友好版本**：原清单有"用 Lua console 验证"步骤，用户没看懂。改成"USB 连 Kindle + 用电脑编辑器看两个文件"后顺了

---

## 明日计划

### Task D：链式对话框 UI（最大任务，12 步骤）

预计子代理时间 10-20 分钟。要给 main.lua 加：
- 5 个新方法（`_resetAiSession` / `_openAiInputDialog` / `_callAiAndShow` / `_openAiResponseViewer`，加增强版 `_editString` 支持嵌套 key）
- AI 助手子菜单树（启用开关 / API 设置 / 提示词模板 / 高级参数 / 说明）
- 把 Task C 的占位 callback 替换为真实 InputDialog → Ai:chat → TextViewer 链式对话框
- TextViewer require / `_ai_session` 状态字段

**Kindle 实测要点**（Task D 完成后）：
- 需要真实 DeepSeek API key + 联网
- 测完整流程：长按 → 问 AI → 输入问题 → 发送 → 看到 AI 回复 → 继续问 → 让 AI 总结 → 关闭
- 错误场景：关 WiFi、故意填错 key

### Task E：AI@ 块 + marker.lua 扩展

TDD（先写 test_marker_ai.lua 16 项断言），扩展 marker.lua 支持 `type="ai"` segment，diff 不参与。然后 UI 加"加到笔记"按钮。

### Task D/E 实施前提醒

- **Task D 重写 callback 时**：考虑代码审查 LOW-1（"…"入口路径 selected_text 可能 nil）和 LOW-2（缺 qrclipboard 的 `highlightFromHoldPos()` 防御）
- **Task D 加菜单时**：考虑代码审查 LOW 关于 `ai_timeout_sec` 字段归属（应该让菜单可调，注入到 `Config.AI_HTTP_TIMEOUTS` 或动态覆盖）

---

## 当前分支状态

- 分支：`feat/m8-ai-chat`（从 master 切出）
- ahead：6 commits（7f41169 调研+计划 + a55ac37 Task A + 3629f51 Task A 修复 + a33fbb3 Task B + 688144e Task B 修复 + 740cf57 Task C）
- behind：0
- push 状态：**未 push**（按惯例等 M8 全部完成 + Kindle 实测全通过）

---

## 文档产出

- `docs/superpowers/research/2026-08-12-koreader-m8-research.md` — 4 方向调研报告（约 1100 行）
- `docs/superpowers/plans/2026-08-12-m8-ai-chat.md` — 实施计划（约 1100 行）
- `progress/2026-08-12 daily progress.md` — 本文档（重写，含三阶段回顾）
