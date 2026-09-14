# 2026-09-14 daily progress

## 遗留项盘点与路线决策（无代码改动）

### 背景

v1.2.1 发布后休整期，全面梳理项目文档中「计划过但未实现」的内容，逐项对照当前代码核实（排除已被后续里程碑悄悄补上的"假遗留"），并做去留决策。

盘点来源：

- `docs/superpowers/specs/2026-08-11-ai-chat-design.md` §9「后续演进（M9+ 候选）」
- `progress/2026-08-06 daily progress.md`「留待 M8+」清单（M7 双向同步遗留）
- `progress/2026-08-05 daily progress.md` 零散遗留（国际化 / 文档图 / HTTP bug 等）

---

## 决策 1：M8 spec「后续演进（M9+ 候选）」全部放弃

用户拍板：**不做**。该清单 8 项候选中 1 项已在 M8 后期顺手实现，其余 7 项全部放弃：

| 候选项 | 处置 |
|--------|------|
| 多 API 路由（按场景自动选服务） | ❌ 放弃 |
| 本地 RAG（同书高亮向量检索带上下文） | ❌ 放弃 |
| 流式输出（SSE 打字机效果） | ❌ 放弃 |
| AI 内容跨设备识别（B 设备知道是 AI 生成） | ❌ 放弃 |
| "重新生成"按钮 | ❌ 放弃 |
| Token 用量统计 | ❌ 放弃 |
| OpenAI/Claude 原生 API（FNS server 中转） | ❌ 放弃（用户自配 base_url 已天然兼容 OpenAI 风格端点） |
| 快捷模板自定义 UI | ✅ 已实现（`main.lua` `_editString` 菜单编辑 `ai_quick_prompts`） |

spec 原文档保持不动（历史记录，放弃决策以本文档为准）。

## 决策 2：M7「留待 M8+」清单列为待做

以下 5 项（源自 `progress/2026-08-06`「留待 M8+」及边界清单）确认**打算做**，作为后续里程碑候选：

1. **文字搜索兜底**——XPointer 失效时（不同 epub 版本）用文字搜索定位高亮；当前行为是失效即跳过
2. **color / drawer / note 字段双向同步**——M7 拉取路径只同步 text
3. **per-book 重置同步状态 UI**——当前靠全局 reset_config 兜底
4. **META@ 来源设备标识**——device 短哈希，标记高亮来源设备
5. **Obsidian 端编辑高亮文字后回推到 KOReader**

---

## 三项状态核实（用户提问）

### 1. 完整国际化——半成

- ✅ 字符串标记层完成：全部 UI 字符串用 KOReader 惯例 `_("...")` gettext 包裹（main.lua 185 / api.lua 13 / ai.lua 11 / _meta.lua 2，共 **211 处**；grep 无遗漏的裸中文 UI 字符串）
- ❌ 缺英译：**全仓库没有任何 `.po` 翻译文件**——gettext 无翻译时回退显示原文，英文用户看到的仍是中文界面
- 结论：要完成国际化，剩余工作就是产出英译 `.po` 文件

### 2. plugin 目录 README 加菜单图——未做，且内容已过时

- `plugin/fns_sync.koplugin/README.md` 无任何图，也无 ASCII 菜单树（2026-08-05 记录的"后续可选改进"未执行；根目录主 README 有图，易混淆）
- **新发现**：该 README 内容停留在 M5-M7 时代——菜单路径仍写"工具 → FNS 同步"单入口，M10 后已是双模块结构（FNS 同步 → 设置▸network；AI 读书助手 → tools 首位）；且缺 M8 AI 对话 / M9 本地模式 / M10 conf 导入章节。下次文档更新时应整体刷新

### 3. T4 连续划多段 debounce 合并——已实现、未验证

- 代码在：`main.lua` 稳定闭包 `_auto_sync_action` 作为 `UIManager:scheduleIn / unschedule` 的 action key（按引用匹配，正是 2026-08-05 设计），逻辑上 debounce 窗口内连续划线只发一次同步请求
- 2026-08-05 真机验证时因"5 秒内连划 3 段难稳定复现"，用户拍板跳过，留待有人报告再排查——至今无真机验证记录

---

## 已排除的"假遗留"（早期标记未实现、后被悄悄补上）

| 项 | 早期记录 | 实际状态 |
|----|----------|----------|
| M5 自动同步三开关 | 8-03 标记未实现 | ✅ M5 落地（onAnnotationsModified / onCloseDocument 已接线） |
| 开书自动同步 | 8-03 标记未实现 | ✅ M7 改名 `pull_on_book_open` 实现 |
| HTTP CLOSE NIL bug | 8-03 标记"下次修复" | ✅ `api.lua` type check 已修 |
| color_emoji_map 深拷贝 TODO | 8-02 记录 | ✅ `main.lua` 浅拷贝守卫已处理 |

## 国际化（i18n）实施

### 方案拍板（用户确认）

- **方案 A**：`locale/en_US.lua` Lua 表 + init 时 merge 进全局 `gettext.translation`（KOReader 的 gettext 只加载本体 mo 且 en_US 被短路，插件翻译只能自行注入；插件中文 msgid 与本体英文 msgid 的 key 空间不重叠，互不干扰）
- **术语**：模式名「离线本地笔记」→ `Local Notes (Offline)`；快捷模板 → `Translate Prompt` 风格
- **范围**：只做 UI 字符串，笔记内容仍由用户模板渲染（默认模板的「📖 第 N 页」等中文标签不随 UI 语言切换）

### 改动内容

| 文件 | 内容 |
|------|------|
| `plugin/fns_sync.koplugin/i18n.lua`（新） | 纯逻辑模块：`needsEnglish(lang)`（`en` 前缀判定）+ `merge(target, translations)`（幂等），无 KOReader 依赖、可单测 |
| `plugin/fns_sync.koplugin/locale/en_US.lua`（新） | 186 条英文翻译表，按功能分组，头部写维护说明（key 须与 msgid 逐字一致、英文原文条目不收） |
| `plugin/fns_sync.koplugin/main.lua` | init 最前加注入块：读 `G_reader_settings` 的 `language`，英文则 `pcall require("locale/en_US")` merge 进 `_.translation`；`reader.lua` 先应用语言再加载插件，注入不会被 changeLang 清掉 |
| `tests/test_i18n.lua`（新） | 14 项测试（见下） |
| `README.md` / `README.en.md` | 「配置」章节末补「界面语言 / UI Language」小节 |

### 测试设计（test_i18n.lua，14 项全过）

1. needsEnglish 边界（en_US/en_GB/en ✓；zh_CN/C/nil/空串/非字符串 ✗）
2. merge 覆盖/新增/幂等
3. en_US.lua 数据完整性（186 条 key/value 均为非空 string）
4. **源码覆盖对比**：plain-find 扫描 main/api/ai/_meta 源码提取全部 `_("...")` msgid（189 条唯一），白名单 7 条英文原文（FNS Sync/max_tokens/temperature 等）外必须全部有翻译——未来新增 UI 字符串漏翻译会被测试直接暴露
5. **占位符保真**：每条翻译的 `%d/%s/%1/%2/{word}` 集合与 msgid 严格一致

回归：现有 7 个单测（gate/conf_import/localstore/marker_ai/threeway/config_ai/ai_chat）共 230 项全过。

### 实施中抓到的问题

- **真 bug（占位符校验抓到）**：「同步成功（+%d 更新%d 删除%d）」3 个 `%d`，英文初稿丢了 1 个 → 修正为 `Sync OK (+%d added, %d updated, %d deleted)`
- **翻译遗漏 6 条**：带缩进的队列状态变体（`  [失败 %d 次]` 等 3 条）、`AI 读书助手`、`AI 块级联删除数量异常`、`说明`——源码覆盖测试抓出后补齐
- **Lua pattern 踩坑**（记录备用）：提取 `_("...")` 无法用 pattern 捕获表达——捕获组内**全部**模式都算捕获内容，`")` 两字符结束序列会把尾引号吞进捕获或截断跨行；含 `\"` 的 msgid 还会中途误停。最终用 `string.find(plain)` 手工切片
- **源码级转义**：源码文本里的 `\n` 是两个字符，模块加载后才是真换行——测试提取需反转义（`\\(.)` 逐字符处理）才能与 en_US.lua 解析后的 key 对齐

### 待真机验证（Kindle）

1. 界面语言设为 English → 插件菜单/提示显示英文
2. 切回中文 → 恢复中文
3. 笔记内容渲染不受 UI 语言影响

## 每日总结

无代码改动，纯盘点 + 路线决策落盘。

| 事项 | 状态 |
|------|------|
| 遗留项全量盘点（文档 × 代码交叉验证） | ✅ |
| M8 spec 后续演进 7 项放弃 | ✅ 决策落盘 |
| M7「留待 M8+」5 项列为待做 | ✅ 决策落盘 |
| 国际化 / plugin README 图 / T4 三项状态核实 | ✅ 结论见上 |
| **国际化实施**（i18n.lua + en_US.lua 186 条 + init 注入 + 14 项新单测 + README） | ✅ 单测全绿（14 + 230 回归），待 Kindle 真机验证 |

### 今日 commit

| commit | 类型 | 内容 |
|--------|------|------|
| （本次） | docs | progress: 遗留项盘点与路线决策——M8 演进放弃、M7 清单待做 |
