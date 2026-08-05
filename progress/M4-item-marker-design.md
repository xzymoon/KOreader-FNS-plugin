# M4 — Item-level Marker Design

## 背景

当前 M3 实现（区域 marker）的局限：marker `<!-- HIGHLIGHTS_START -->...<!-- HIGHLIGHTS_END -->` 之间的所有内容会在每次同步时被整片覆盖。如果用户在两条摘录之间手动写感想，下次同步会丢失。

升级到 **条目级 marker**：每条摘录各自带 marker，按 datetime 作为唯一 key。用户可以在任意两条摘录之间、或摘录块外部穿插编辑，全部保留。

---

## 决策表

| 决策 | 选择 | 理由 |
|---|---|---|
| 1. HL@ marker 形式 | HTML 注释 `<!-- HL@xxx -->` | 与现有 HIGHLIGHTS 区域 marker 风格统一，灰色淡显不打扰阅读 |
| 2. 删除高亮处理 | 直接删（带配置项） | 最直觉，未来可改 B（标记）/ C（保留） |
| 3. 章节标题位置 | HL@ 块内 | 重渲染时随摘录一起更新，避免章节切换时的孤儿标题 |
| 4. 旧笔记迁移 | 不做 | 用户处于测试阶段，会删除重来 |
| 5. 新增高亮插入 | 按 datetime 全局排序 | 保持时间顺序，便于追读 |

---

## 数据结构

### 单条 HL@ 块的渲染形式

```markdown
<!-- HL@2026-07-29T13:39:56 -->
## 出版說明                              ← 章节标题（仅当 chapter 与前一条不同）

> 📖 第 421 页 · 摘录原文...

*笔记：你在 KOreader 里给这条高亮写的备注*
*H: 2026-07-29 13:39:56*
<!-- /HL@2026-07-29T13:39:56 -->
```

### datetime 作为唯一 key

- KOreader 每条 annotation 有 `datetime` 字段（创建时刻，毫秒精度字符串）
- 同一本书内不会重复
- 跨设备同步保留
- 风险：用户改系统时间可能导致 datetime 重复或乱序 — 实际场景罕见，可接受

### 完整笔记结构（升级后，去掉外层 HIGHLIGHTS marker）

```markdown
# 《国史大纲》读书笔记
... 模板头部（书籍信息、评分、etc.）...

[任意用户内容，永久保留]

<!-- HL@ts1 -->
摘录 1
<!-- /HL@ts1 -->

[任意用户内容，永久保留]

<!-- HL@ts2 -->
摘录 2
<!-- /HL@ts2 -->

[任意用户内容，永久保留]
```

---

## marker.lua 模块设计

### 模块职责

`marker.lua` 负责笔记内容的解析、diff、合并。**不负责** HTTP、不负责摘录渲染（那是 excerpt.lua）。

### 函数签名（4 个公开函数）

```lua
local Marker = {}

-- 解析笔记内容，返回 segment 列表
-- 每个 segment 是 { type = "user"|"hl", ts = "...", content = "..." }
-- user 段：ts 为 nil；hl 段：ts 为 datetime 字符串
function Marker.parse(content)
    -- 实现见下文「解析算法」
end

-- 把 segment 列表重新拼回笔记内容字符串
function Marker.serialize(segments)
    -- 与 parse 互逆
end

-- 计算 diff：哪些 HL@ 块要新增、删除、修改
-- @param existing_segments  parse(现有笔记) 的结果
-- @param current_highlights  KOreader 当前高亮，{ ts -> rendered_content } 表
-- @return actions = { {op="insert"|"delete"|"update", ts=..., content=...}, ... }
function Marker.diff(existing_segments, current_highlights)
end

-- 应用 diff 到 segment 列表，返回新 segment 列表
function Marker.applyDiff(existing_segments, actions)
end
```

---

## 算法

### 1. parse（解析笔记内容为 segment 列表）

伪码：
```
segments = []
i = 1
while i <= #content:
    find next "<!-- HL@" starting at i
    if not found:
        append remaining as user segment, break
    
    if there's text before HL@:
        append as user segment
    
    parse ts from "<!-- HL@<ts> -->"
    find matching "<!-- /HL@<ts> -->"
    if not found:  -- 损坏的块，当作用户内容处理
        append the HL@ line as user segment
        i = position after HL@ line
        continue
    
    block_content = text between HL@ line and /HL@ line (exclusive)
    append as hl segment with ts and block_content
    i = position after /HL@ line
return segments
```

**鲁棒性**：
- 损坏的 HL@ 块（缺闭合）当作用户内容，原样保留
- 用户手动写 `<!-- HL@xxx -->` 也不会破坏（视为 hl 段，下次同步会按 ts 匹配；匹配不到 → 视为已有，diff 时 current_highlights 没有这个 ts → 标记 delete → 删除）

### 2. diff（计算需要执行的操作）

伪码：
```
existing_ts_set = { ts from hl segments }
current_ts_set  = { ts from current_highlights }

actions = []

-- 新增：current 有，existing 没
for ts, content in pairs(current_highlights):
    if not existing_ts_set[ts]:
        actions.append({ op="insert", ts=ts, content=content })

-- 删除：existing 有，current 没
for seg in existing_segments:
    if seg.type == "hl" and not current_ts_set[seg.ts]:
        actions.append({ op="delete", ts=seg.ts })

-- 更新：两边都有，但内容不同（罕见，因为 ts 是创建时刻；
-- 但用户在 KOreader 改了高亮备注时，ts 不变内容变 → 触发 update）
for seg in existing_segments:
    if seg.type == "hl" and current_ts_set[seg.ts]:
        if seg.content != current_highlights[seg.ts]:
            actions.append({ op="update", ts=seg.ts, content=current_highlights[seg.ts] })

return actions
```

### 3. applyDiff（应用操作到 segment 列表）

伪码：
```
-- 第 1 步：执行 delete 和 update（in-place）
new_segments = deep_copy(existing_segments)
for i, seg in new_segments:
    if seg.type != "hl": continue
    action = find_action_for_ts(seg.ts)
    if action.op == "delete":
        mark seg for removal
    elif action.op == "update":
        seg.content = action.content

-- 第 2 步：执行 insert（按 datetime 排序后逐个插入）
inserts = [a for a in actions if a.op == "insert"]
sort inserts by ts ascending

for ins in inserts:
    -- 找到插入位置：new_segments 中第一个 ts > ins.ts 的 hl 段之前
    -- 如果没有，追加到末尾（但末尾可能有 user 段，应该插在最后一个 hl 段之后）
    insert_pos = find_insertion_point(new_segments, ins.ts)
    new_segments.insert(insert_pos, { type="hl", ts=ins.ts, content=ins.content })

-- 第 3 步：清理被标记删除的段
new_segments = [s for s in new_segments if not s.marked_for_removal]

return new_segments
```

### 4. find_insertion_point（按时间排序找插入位置）

策略：
- 找到 new_segments 中第一个 ts > ins.ts 的 hl 段的索引
- 插入到该索引**之前**
- 如果没有这样的 hl 段（即所有 hl 段的 ts 都 < ins.ts）：
  - 如果存在 hl 段 → 插入到最后一个 hl 段**之后**
  - 如果不存在 hl 段（首次同步）→ 插入到末尾（即所有 user 段之后）

**边界**：
- 首次同步：existing 为空 → 所有 current_highlights 都是 insert → 按 ts 排序追加到末尾（在所有 user 段之后，即模板正文之后）

---

## 集成点

### excerpt.lua 改动

```lua
-- renderExcerpt: 在末尾加 HL@ marker 包围
function Markdown:renderExcerpt(ann, settings)
    -- 原渲染逻辑保留，但返回值改为不包含 HL@ marker 的纯摘录
    -- HL@ marker 由 renderExcerptBlock 或调用方添加
end

-- renderExcerptBlock: 输出每个 HL@ 块的字典 { ts -> rendered_block }
-- 而不是字符串（让调用方决定怎么用）
function Markdown:renderExcerptBlock(annotations, settings)
    -- 返回 { ts1 = "block1 content", ts2 = "block2 content", ... }
    -- 每个 block content 已经包含章节标题（如有）、摘录、笔记、时间戳
end

-- renderFullNote: 首次同步时，把所有 HL@ 块串接到模板的占位符位置
-- 不再用 HIGHLIGHTS_START/END，改用 {{HIGHLIGHTS}} 占位符
function Markdown:renderFullNote(annotations, settings, meta)
    -- 渲染模板
    -- 渲染所有 HL@ 块
    -- 替换 {{HIGHLIGHTS}} 为串联的 HL@ 块
    -- 模板没有 {{HIGHLIGHTS}} 占位符时追加到末尾
end

-- replaceMarkerZone: 删除（被 marker.lua 的 diff/applyDiff 取代）
```

### main.lua 改动

```lua
function FnsSync:_doSyncCurrentBook(annotations, meta, path)
    local current_highlights = Excerpt:renderExcerptBlock(annotations, self.settings)
    -- current_highlights 是 { ts -> block_content } 表
    
    local get_result = Api:getNote(self.settings, path)
    if not get_result.ok then ... end
    
    local new_content
    if get_result.exists then
        -- 用 marker.lua 增量合并
        local segments = Marker.parse(get_result.content)
        local actions = Marker.diff(segments, current_highlights)
        local new_segments = Marker.applyDiff(segments, actions)
        new_content = Marker.serialize(new_segments)
    else
        -- 首次创建
        new_content = Excerpt:renderFullNote(annotations, self.settings, meta)
    end
    
    -- POST 写回
end
```

### config.lua 改动

```lua
Config.DEFAULT_NOTE_TEMPLATE = [[# 📖 《 {{VALUE:书名}} 》读书笔记
... 头部 ...
# 摘录 ：

{{HIGHLIGHTS}}
]]

-- Config.HIGHLIGHTS_START_MARKER 和 END_MARKER 可以删除（不再使用）
-- 但保留作为兼容性常量，标记为 deprecated
```

---

## 验证标准

实施完成后，以下场景必须工作（按用户测试顺序）：

| # | 场景 | 期望结果 |
|---|---|---|
| 1 | 首次同步：笔记不存在 | 生成带 N 个 HL@ 块的笔记，块之间无内容 |
| 2 | 二次同步：笔记存在，无高亮变化 | 笔记内容字节级一致（idempotent） |
| 3 | 在两条 HL@ 之间加文字，再同步 | 用户加的文字保留 |
| 4 | 在 HL@ 块外（顶部/底部）加文字，再同步 | 用户加的文字保留 |
| 5 | KOreader 删一条高亮，再同步 | 对应 HL@ 块消失，其他内容保留 |
| 6 | KOreader 加一条新高亮，再同步 | 新 HL@ 块按 datetime 排序插入 |
| 7 | KOreader 改一条高亮的备注，再同步 | 对应 HL@ 块内容更新 |
| 8 | 章节切换（新高亮在新章节） | 新 HL@ 块内含 `## 新章节` 标题 |
| 9 | 损坏笔记（手动删了一个 `<!-- /HL@xxx -->`） | 不崩溃，损坏的块当作用户内容保留 |

---

## 配置项变更

新增配置项（加入 `Config.DEFAULTS`）：

```lua
-- 删除高亮的处理策略
delete_strategy = "remove",  -- "remove" | "mark" | "keep"
```

其他决策（HL@ marker 形式、章节标题位置、插入排序）**不暴露为配置项**，作为代码常量（避免配置爆炸）。

---

## 实施顺序（4 commit）

1. `[docs]` 写本设计文档 → `progress/M4-item-marker-design.md`
2. `[feat]` 新建 `marker.lua`（4 个公开函数 + 单元逻辑）
3. `[refactor]` 改 `excerpt.lua` / `main.lua` / `config.lua` 集成
4. `[docs]` 更新 `progress/2026-08-03 daily progress.md`

---

## 已知限制

- **datetime 冲突**：理论上同本书可能出现两条 datetime 相同的高亮（毫秒级精度），实际罕见。如果发生，第二条会覆盖第一条（dict 行为）
- **没有"已删除"标记**：当前实现是直接删除。如果用户误删高亮，Obsidian 笔记里的对应块立即消失，不可恢复（除非走 Obsidian 文件历史）
- **没有并发保护**：如果用户在 Obsidian 编辑笔记的同时，KOreader 触发同步，可能基于过时内容做 diff。这是边缘情况，先不处理（M6/M7 再考虑加锁/版本号）
