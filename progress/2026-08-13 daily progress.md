# 2026-08-13 开发进度

## 主要任务

**M8 Task D：链式对话框 UI（一次性 Kindle 实测通过 ✅）**

延续 8月12日 Task A/B/C 完成的基础，今天实施 Task D（最大任务）——完整的 AI 对话交互链路，从高亮选区到多轮对话到 AI 总结。沿用 subagent-driven-development 流程（实现者 → 规格审查 → 代码质量审查 → 修复 → commit）。

## 阶段总览

| 阶段 | 内容 | 结果 |
|------|------|------|
| 一 | Task D 决策点讨论（5 个产品/交互决策）| 用户拍板 |
| 二 | 分派实现者子代理（D1-D11 完整步骤 + 5 决策）| DONE，2 测试 PASS |
| 三 | 规格合规审查（独立验证）| APPROVED（5 决策全 ✓，字段名 MATCH ai.lua）|
| 四 | 代码质量审查 | NEEDS_CHANGES（1 C + 3 H + 3 M + 1 L）|
| 五 | 4 条必修问题修复 + 测试 + commit | ✅ commit `70a0fa2` |
| 六 | Kindle 实测（10 步流程 + 错误场景 A）| ✅ 全通过 |

---

## 阶段一：5 个产品决策（用户拍板）

| # | 决策点 | 最终方案 | 落地位置 |
|---|--------|----------|---------|
| 1 | 对话标记 emoji vs 文字 | 纯文字 `【原文摘录】`/`【问】`/`【答】`/`【原文】`（Kindle e-ink 黑白屏 emoji 看不清）| D4 描述区 + D6 TextViewer 渲染 |
| 2 | 快捷模板数量 | 3 个固定（翻译/解释/评论），菜单可改文字 | D4 InputDialog 按钮 |
| 3 | 总结按钮文案 | 新增 `ai_quick_prompts.summarize` 字段（默认"请总结以上对话"），用户在菜单改 | config.lua + D6 + D8 |
| 4 | InputDialog 原文摘录长度 | 截 60 字 + "…"（避免撑爆 6 寸屏）| D4 描述区 |
| 5 | AI 助手菜单显隐 | 与 FNS 主开关解耦，`enabled_func` 只看 `ai_enabled` | D8 菜单子树 |

---

## 阶段二：实现者子代理

完整任务文本（D1-D11 步骤代码 + 5 决策覆盖）粘贴给 general-purpose 子代理，不让子代理读计划文件（昨天成功经验）。

### 改动清单

- `config.lua:221` — `ai_quick_prompts` 末尾加 `summarize = "请总结以上对话"`
- `main.lua:49` — D1 require 追加 `TextViewer`
- `main.lua:59` — D1 require 追加 `Ai`
- `main.lua:73-79` — D2 `FnsSync:extend` 块加 `_ai_session = nil`（含注释）
- `main.lua:284-286` — D3 `_resetAiSession` 方法
- `main.lua:292-368` — D4 `_openAiInputDialog` 方法
- `main.lua:374-413` — D5 `_callAiAndShow` 方法（nextTick + pcall）
- `main.lua:418-485` — D6 `_openAiResponseViewer` 方法
- `main.lua:244-275` — D7 替换 Task C 占位 callback
- `main.lua:2348-2487` — D8 AI 助手菜单子树
- `main.lua:533-572` — D9 `_editString` 嵌套 key 支持

### 报告

状态 DONE，13 项自审清单全 ✓，两个测试 PASS（19/19 + 16/16），3 concerns（最有价值的 concern 3：`Ai:chat` 返回值字段名需对照 ai.lua 源码验证）。

---

## 阶段三：规格合规审查（独立 general-purpose 子代理）

不信任实现者报告，独立 grep/read 验证。

### 核对结果

- D1-D9 全部 ✓
- 5 个产品决策全部 ✓
- Concern 3 验证：ai.lua 的 `Ai:chat` 实际返回 `{ ok, content, message }`，D5 引用 MATCH，无 CRITICAL
- 工作区改动 surgical（只 main.lua + config.lua + tests 共 3 文件）

### 测试独立运行

- `test_threeway.lua` PASS（19/19）
- `test_config_ai.lua` PASS（16/16）

### 唯一 finding

- LOW-1：`test_config_ai.lua` 未断言 `summarize` 字段（已在阶段五顺手补）

---

## 阶段四：代码质量审查（code-reviewer agent）

### 发现问题（按级别）

| 级别 | 数量 | 状态 |
|------|------|------|
| CRITICAL | 1 | C-1 必修 |
| HIGH | 3 | H-1/H-2/H-3 必修 |
| MEDIUM | 3 | 跳过（实测再评估）|
| LOW | 1 | L-1 顺手补 |

### 必修问题详情

#### C-1：失败重试时"挂起 user 消息"堆积

- **位置**：main.lua:345（发送 callback append user）+ main.lua:400-406（失败 return 不回滚）
- **现象**：用户问"翻译这段" → 断网失败 → 再问"解释那段" → AI 收到 `[翻译这段] [解释那段]` 两条 user 连发，中间无 assistant，AI 困惑
- **根因**：点发送时已 append user 消息，失败后没 pop 回来

#### H-1：DEFAULTS by-reference 污染

- **位置**：main.lua:97-101（init backfill）+ main.lua:533-572（setNested in-place mutation）
- **现象**：用户改"翻译模板"为自定义 → 点"重置"应该恢复默认 → 实际拿到的是改后的值，**重置失效**
- **根因**：init backfill 用 `self.settings[k] = v`（引用复制），`_editString` 的 setNested 是 in-place 修改 → 同步污染 `Config.DEFAULTS.ai_quick_prompts.translate`
- **注意**：根因在 Task A 留下的债，Task D 让它首次实际触发

#### H-2：onCloseDocument 不 reset session

- **位置**：main.lua:1633（onCloseDocument）vs main.lua:73 注释承诺"Reset on: book close, ReaderUI teardown"
- **现象**：用户问完关书（不点"关闭"按钮）→ 开新书点"问 AI" → session.original_text 还是旧书的 → AI 收到混合两本书上下文
- **根因**：注释承诺会 reset，但实际只在 TextViewer 关闭路径调 `_resetAiSession()`

#### H-3：widget 字段不清理

- **位置**：5 处 `UIManager:close(self._ai_xxx)` 后字段未设 nil
- **现象**：理论上用户触发不到（按钮 callback 触发时 widget 在屏），但违反防御性原则。未来加异步路径会出 stale 引用 bug

### 跳过问题（M/L）

- M-1 缺 in-flight 锁（loading InfoMessage 应已拦截事件，需实测验证）
- M-2 `_openAiResponseViewer` 函数偏长 68 行（临界值，可拆可不拆）
- M-3 TextViewer `add_default_buttons=true` 可能挤掉"关闭"按钮（需实测看渲染）
- L-1 "未获取到选区文本"toast 在菜单上方（UX 略 awkward 但功能正常）

---

## 阶段五：4 条必修修复 + 测试 + commit

用户授权直接改（"我看不懂代码，你直接修改吧"）。

### 修复详情

| # | 修复 | 改动 |
|---|------|------|
| C-1 | `_callAiAndShow` 失败路径 pop 末尾 user 消息 | 两个 return 前各加 3 行（defensive 检查 role=="user"）|
| H-1 | init backfill 对 table 字段一层深拷贝 | main.lua:88-101 重写循环 + 更新 NOTE 注释 |
| H-2 | `onCloseDocument` 开头加 `self:_resetAiSession()` | 1 行 |
| H-3 | 5 处 `UIManager:close(self._ai_xxx)` 后加 `= nil` | 5 行 |
| LOW-1 | test_config_ai.lua 补 summarize 字段断言 | 1 行 |

### 测试

- `lua tests/test_threeway.lua` PASS（19/19）
- `lua tests/test_config_ai.lua` PASS（17/17，多了 summarize 断言）

### Commit

`70a0fa2` feat(M8 Task D): 链式对话框 UI（InputDialog + TextViewer + AI 菜单树）

分支 `feat/m8-ai-chat` 现 ahead **7 个 commit**（未 push，按惯例等 M8 全部完成 + 实测全通过）。

---

## 阶段六：Kindle 实测（用户操作）

### 实测清单（10 步流程 + 错误场景 A）

| # | 操作 | 结果 |
|---|------|------|
| 1 | 菜单 → FNS 同步 → AI 助手 → 启用 AI 对话 | ✓ |
| 2 | API 设置 → 填真实 DeepSeek key（USB 编辑 settings.reader.lua）| ✓ |
| 3 | 长按选中正文 → 菜单 → 问 AI | ✓ |
| 4 | InputDialog 顶部显示【原文】xxx… + [翻译][解释][评论] | ✓（无 emoji，符合决策 1）|
| 5 | 点【翻译】→ 输入框自动填模板 | ✓ |
| 6 | 点【发送】→ 正在思考… → TextViewer 显示【原文摘录】【问】【答】| ✓ |
| 7 | 点【继续问】→ 输入新问题 → 显示 2 轮对话 | ✓ |
| 8 | 点【让 AI 总结】→ 显示总结 | ✓ |
| 9 | 点【关闭】→ 对话框消失 | ✓ |
| 10 | 长按已有高亮 → 编辑菜单 → "…" → 问 AI（入口 B 验证）| ✓ |
| 错 A | 关 WiFi → 点发送 → 看到错误 toast（网络错误）| ✓（C-1 修复生效，下次再问不会双问）|

### 关键验收点

- 长按选中文字**不闪退** ✅（8月12日早上回滚的根因彻底不复现）
- 长按已有高亮**不闪退** ✅
- InputDialog 描述区不撑爆屏幕（60 字截断）✅
- 错误场景失败后不污染下次会话（C-1 修复生效）✅
- M5/M6/M7 现有功能零回归 ✅

---

## 关键 API key 配置方法（用户问 + 解决）

用户提出："填写真实 API 想 USB 连电脑时填，Kindle 里太难填。"

### 推荐方案：USB 直接编辑 settings.reader.lua

- 文件路径：`<盘符>:\koreader\settings.reader.lua`
- 搜 `ai_api_key` → 改双引号内容
- 顺便改 `ai_enabled = true`
- 重启 KOReader

### 为什么不用独立 ai_config.lua

8月12日早上回滚的直接根因之一：Lua `require` 有 `package.loaded` 缓存，用户改文件后必须重启 KOReader 才生效，且首次 require 后即使重启也可能 stale。调研报告 §5 修正了这点，配置塞进 `G_reader_settings` 是正确架构，不能倒退。

---

## 当前分支状态

- 分支：`feat/m8-ai-chat`
- ahead：7 commits（7f41169 调研+计划 + a55ac37 Task A + 3629f51 Task A 修复 + a33fbb3 Task B + 688144e Task B 修复 + 740cf57 Task C + 70a0fa2 Task D）
- behind：0
- push 状态：**未 push**（按惯例等 M8 全部完成 + 实测全通过）

---

## 明日计划

### Task E：AI@ 块 + marker.lua 扩展（TDD）

按 plan `docs/superpowers/plans/2026-08-12-m8-ai-chat.md` 任务 E 章节：

1. E1：编写失败测试 `tests/test_marker_ai.lua`（16 项断言，包括 parse / round-trip / mixed HL@+AI@）
2. E2-E4：扩展 marker.lua 支持 `type="ai"` segment（parse / serialize）
3. E5-E6：marker.lua diff 不识别 AI segment（M5/M6/M7 零回归保证）
4. E7：main.lua TextViewer 加"加到笔记"按钮 + onCloseDocument 已在 H-2 修复中加 `_resetAiSession`
5. E8：本地测试 + commit
6. E9：Kindle 实测

### Task E 实施前提醒

- 用户决策（Task D 后期可能影响）：
  - "加到笔记"按钮位置：TextViewer buttons_table 第二行，与"关闭"并列（或单独一行）
  - AI@ 块的标记格式：`<!-- AI@YYYY-MM-DD HH:MM:SS hl="原始高亮ts" model="deepseek-chat" -->` + `<!-- /AI@YYYY-MM-DD HH:MM:SS -->`（与 HL@ 同构）
  - AI 内容写入笔记时的格式（markdown 引用块？代码块？纯文本？）
- TDD 流程必须严格执行（marker.lua 有完整单测传统）

---

## 子代理工作流经验（Task D 复盘）

### 成功点

1. **不让子代理读计划文件**：完整任务文本粘贴，避免上下文污染（昨天经验延续）
2. **三阶段审查有效拦住问题**：实现者 → 规格审查 → 代码质量审查。规格审查者独立验证了 ai.lua 返回值字段名（concern 3）MATCH，避免潜在 CRITICAL bug
3. **修复成本低**：4 条必修修复都是 surgical 改动（C-1: 6 行 / H-1: 13 行 / H-2: 1 行 / H-3: 5 行）

### 教训

1. **Task A 的债 Task D 来还**：H-1（DEFAULTS by-reference 污染）是 Task A 留下的 backfill 实现细节问题，Task D 是首个暴露路径。审查者正确判断这是 Task D 的责任（"虽然根因在 Task A，但 Task D 让它首次影响用户，应在 Task D 里一并修"）
2. **用户授权流程要明确**：用户说"我看不懂代码，你直接修改吧"是一次性授权本次修复，不是永久授权。未来仍需先问"现在是否可以开始进行改动？"

---

## 文档产出

- `progress/2026-08-13 daily progress.md` — 本文档
- `plugin/fns_sync.koplugin/main.lua` — Task D 4 条修复落地
- `plugin/fns_sync.koplugin/config.lua` — summarize 字段
- `tests/test_config_ai.lua` — summarize 字段断言
