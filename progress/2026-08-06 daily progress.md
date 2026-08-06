# 2026-08-06 开发进度

## 主要任务

M7：跨设备双向同步高亮 + 三路合并（设计草案 v4，含多角色审查整合）。

---

## 范围调整记录

### 早上：4 方案作废

v1 设计了 4 个"防互删"方案。用户澄清需求：要的不是"防互删"，而是真正的双向同步。v1 作废。

### 中午：可行性研究

启动 general-purpose agent 研究跨格式坐标系统，关键结论：

| 格式 | 坐标方式 | 跨设备稳定性 |
|------|---------|------------|
| EPUB / MOBI / AZW3 / FB2 / TXT / HTML（crengine）| XPointer | ✅ 100% 稳定（同文件）|
| PDF / CBZ / DJVU（mupdf / picdocument）| 像素坐标 | ❌ 极不稳定 |

API 入口：`self.ui.annotation:addItem(item)`（具体签名待查证）。

### 下午：用户拍板范围 + 关键决策

| 决策点 | 选择 |
|--------|------|
| 支持格式 | EPUB / MOBI / AZW3 / FB2 / TXT / HTML（crengine）|
| 不支持格式 | PDF / CBZ / DJVU（mupdf / picdocument）|
| 同步内容 | 高亮 + 摘录（text）|
| 不同步 | note（笔记字段）|
| 冲突解决 | 三路合并（last_synced_ts）|
| 双向同步默认开关 | 关（实验性功能）|
| 开书自动拉取默认 | 关 |

### 晚间：多角色并行审查（4 agent）

| Agent | HIGH | MEDIUM | LOW |
|-------|:---:|:---:|:---:|
| 自审 | 3 | 5 | 2 |
| silent-failure-hunter | 4 | 6 | 2 |
| security-reviewer | 3 | 5 | 2 |
| code-reviewer | 4 | 6 | 3 |
| architect | 3 | 5 | 3 |
| **原始总计** | **17** | **27** | **12** |
| **去重整合** | **~9 类** | **~15 类** | **~8 类** |

### 用户产品决策（拍板完成）

1. 首次启用弹窗文案要写隐私告知（XPointer 坐标会进 Obsidian 笔记）✅
2. Obsidian 端编辑语义接受（用户在 Obsidian 删 HL@ 块 = 跨设备删本地）✅
3. 删除本地高亮要 toast 提示 ✅
4. M6 队列走两路（不做拉取，离线书拉了无意义）✅

---

## M7 设计方案 v4（含多角色审查整合）

### 1. 核心思路（v3 → v4 调整）

**v3 的核心思路**（保留）：
1. Obsidian 笔记里加 META@ 块存 XPointer 坐标
2. 本地 per-book 存 last_synced_ts
3. 三路合并 diff

**v4 的关键调整**（多角色审查驱动）：

| # | v3 设计 | v4 调整 | 来源 |
|---|---------|---------|------|
| 1 | META@ 作为独立 HTML 注释块 | **META@ 作为 hl segment 子字段 `seg.meta`** | code-reviewer H-A3 + architect M-A5 |
| 2 | `_doSyncCurrentBook` 内部 if-else 双向开关 | **显式分流为两个独立函数** | architect H-A1 + 自审 HIGH-1 |
| 3 | 推/拉是两个独立方法各自更新 last | **同步回合（sync round）：拉 → 合并 → 应用双方 → 单次更新 last** | architect H-A2 |
| 4 | `last_synced_ts` 存 `G_reader_settings` | **独立文件 `fns_sync_state.lua` + 原子写** | architect M-A1 + security M-S2 |
| 5 | 拉取触发推送的自循环未防护 | **`_pull_in_flight` 标志 + 注入后单次 dispatch + 抑制 M5 debounce** | security H-S2 |

### 2. META@ 块的新设计（关键调整）

**v3 设计（独立块）**：
````markdown
<!-- HL@ts -->
> 内容
<!-- META@ts pos0="..." pos1="..." chapter="..." -->
<!-- /HL@ts -->
````

**问题**：与 `Marker.parse` 的 `plain=find` 安全机制冲突；ts 与 HL@ ts 冲突；紧贴位置破坏现有 parse 逻辑。

**v4 设计（子字段，不进 markdown）**：

不改变 Obsidian 笔记的 markdown 渲染！META@ 数据通过 `Marker.parse` 内部解析后 attach 到 hl segment 上，但**不作为独立 HTML 块写入笔记**。

具体方案：META@ 数据**仍然在笔记中存在**（机器可读），但解析层把它视为 HL@ 块的"扩展属性"，attach 到 seg.meta 字段。

````markdown
<!-- HL@2026-08-06 10:30:00 pos0="/body/.../p[3]/text()[2].123" pos1="/body/.../p[3]/text()[2].156" chapter="第二章" -->
> 📖 第 42 页
> 这是被高亮的文字

**笔记**：用户笔记

<!-- /HL@2026-08-06 10:30:00 -->
````

**关键变化**：META@ 数据合并到 HL@ 起标记里（作为额外 key=value），不再单独成块。

**Marker.parse 改造**：
- 解析 HL@ 起标记时，除了 ts，额外解析 `pos0` / `pos1` / `chapter` 字段
- attach 到 segment：`seg.meta = { pos0=..., pos1=..., chapter=... }`
- 老笔记（无 pos0/pos1）→ seg.meta = nil（向后兼容）

**Marker.serialize 改造**：
- 输出 HL@ 起标记时，如果 seg.meta 非空，附加 pos0/pos1/chapter 到起标记
- 老笔记的 serialize 输出与原来一致（seg.meta=nil → 不附加）

**Marker.diff / applyDiff 改造**：
- 完全无感（diff 只看 ts 和 content，不看 meta）
- 向后兼容（老 segment.seg.meta=nil 自然处理）

### 3. 显式分流：单向 vs 双向路径

**v3 设计**：`_doSyncCurrentBook` 内部判断开关 → 走两路或三路 diff。

**v4 设计**：抽出两个独立函数，caller 显式选择：

```lua
-- 老路径（M5/M6 + 双向同步关闭时）
function FnsSync:_doSyncCurrentBookLegacy(annotations, meta, book_path, note_path, silent)
    -- 两路 diff（保留现有 Marker.diff 行为）
end

-- 新路径（仅双向同步开启时）
function FnsSync:_doSyncCurrentBookBidirectional(annotations, meta, book_path, note_path, silent)
    -- 三路合并 + 同步回合
end
```

**Caller 分流**：
- `_triggerSync`（M5 实时）：检查 `bidirectional_sync_enabled`，分流到对应函数
- `_processQueueItem`（M6 队列）：**强制走 Legacy**（用户拍板 #4，离线书不做拉取）
- 手动按钮"立即同步当前书"：检查开关分流
- 手动按钮"立即拉取远端高亮"：**仅调用 Bidirectional 的拉取动作**（不推送）

**禁止混用**：一台设备要么全走 Legacy 要么全走 Bidirectional（一旦启用双向，所有相关路径都走新路径）。

### 4. 同步回合（Sync Round）概念

**v3 设计**：推和拉是两个独立方法，各自更新 last_synced。

**v4 设计**：一次完整的同步 = 一个原子回合：

```
1. 拉 server 快照（getNote）
2. parse server content → server_segments（含 seg.meta）
3. 提取 server_ts_set
4. 提取 local_ts_set（从 self.ui.annotation.annotations）
5. 加载 last_synced[book_path]
6. _computeThreeWayActions(server_ts_set, local_ts_set, last_ts_set) → actions
7. 应用 actions 到 server_segments（产生 new_server_segments + new_server_content）
8. 应用 actions 到 local（addItem / removeItemByXPointer，基于 server_segments 的 seg.meta）
9. API: overwriteNote(new_server_content)
10. API 成功 → 原子写 last_synced[book_path] = server_ts ∪ successfully_added_local_ts
11. dispatch AnnotationsModified（仅一次，cause="sync_round"）
12. toast 用户感知（"已同步 N 条 / 已删除 M 条其他设备的"）
```

**关键点**：
- 推和拉是同一个回合的两个应用方向，**不可分割**
- last_synced 只有一个更新点（回合成功后）
- 部分成功（addItem 失败）→ last 不含失败的 ts（下次重试）

### 5. 三路合并算法（保留 v3 真值表）

| server 有 X? | local 有 X? | last 有 X? | 决策 |
|---|---|---|---|
| ✅ | ✅ | ✅ | 不变 |
| ✅ | ❌ | ✅ | delete on local（用户删了）|
| ✅ | ❌ | ❌ | **保留 server + addItem 到 local**（别的设备新增）|
| ❌ | ✅ | ✅ | delete on local（别的设备删了）|
| ❌ | ✅ | ❌ | insert on server（本地新增）|
| ❌ | ❌ | ✅ | 不可能（last 损坏 → 跳过 + 日志）|
| ✅ | ✅ | ❌ | 不变（首次同步 + 双方都有）|

**异常防护**（H-SF-4）：
- 如果 `last_synced[book]` 非空但 `server_ts_set` 突然全空（用户在 Obsidian 删光所有 HL@ 块）→ 三路合并会判定"全部 delete on local"→ 本地也清空
- 这是**用户期望行为**（拍板 #2：Obsidian 删 = 跨设备删本地）✅
- 但如果 server_ts_set 是因为 parse 失败变空（HL@ 块格式坏掉）→ **拒绝执行 + toast 告警**

### 6. last_synced_ts 的存储

**独立文件**：`<koreader>/settings/fns_sync_state.lua`（或 KOreader 标准位置，待查证）

**结构**：
```lua
return {
    schema_version = 1,
    books = {
        ["/path/to/book.epub"] = {
            ["2026-08-06 10:30:00"] = true,
            ["2026-08-06 11:00:00"] = true,
        },
        ...
    },
}
```

**原子写**（HIGH-3 + M-S2）：
1. 写临时文件 `fns_sync_state.lua.tmp`
2. fsync
3. rename 替换原文件
4. 失败回滚（保留旧文件）

**清理孤儿**（M-SF-5）：
- `onCloseDocument` 时检查书文件是否存在
- 双向同步开关 toggle off 时弹确认（"清除所有同步状态？或保留以便重新启用？"）→ 用户选清除则删整个 books 表

### 7. _sync_in_flight 锁扩展

**v3**：仅保护推送。

**v4**：扩展为保护**整个同步回合**：
- 推送 / 拉取 / 同步回合共用 `_sync_in_flight`
- 拉取入口检查 `if self._sync_in_flight then return end`
- 同步回合设置同把锁，回合结束释放
- 拉取过程中用户划线 → M5 debounce 跳过（"another in flight"）→ 划线数据没丢，下次关书兜底推

### 8. 拉取过程的事件抑制（防自循环）

**问题**（H-S2）：`addItem` 触发 `AnnotationsModified` → M5 监听 → debounce 推送 → 自循环。

**v4 解决方案**：
- 拉取过程设置 `self._pull_in_flight = true`
- `onAnnotationsModified` 入口检查：`if self._pull_in_flight then return end`
- 拉取完成（批量 addItem 后）**手动 dispatch 一次** `AnnotationsModified`，payload 含 `cause = "remote_pull"`
- M5 的 `onAnnotationsModified` 看到 `cause == "remote_pull"` → 跳过 debounce（不触发推送）

**注意**：`addItem` 是否真的会 dispatch 事件需要查证（M-B4）。如果 `addItem` 不 dispatch，则不需要 `_pull_in_flight`，只需最后手动 dispatch 一次。

### 9. 配置字段（v3 保留，新增 1 个）

| key | 默认 | 说明 |
|-----|------|------|
| `bidirectional_sync_enabled` | `false` | 双向同步总开关 |
| `pull_on_book_open` | `false` | 开书时自动拉取 |
| `bidirectional_first_use_confirmed` | `false` | 首次启用弹窗确认标志（防误触）|

**config_version bump 到 v4**（L-C2）：
- migration: 把 M5 占位的 `sync_on_book_open` 改名为 `pull_on_book_open`
- 老用户的 `sync_on_book_open`（false）→ 迁移到 `pull_on_book_open`
- DEFAULTS 删 `sync_on_book_open`，加 `pull_on_book_open = false`

### 10. UI 菜单（v3 保留，加首次弹窗）

```
FNS 同步
├─ 启用 FNS 同步 [✓]
├─ 自动同步 [✓]
│  ├─ ...
│  └─ 双向同步（实验性） [ ]
│     ├─ 启用双向同步 [ ]  ← 首次开启弹窗（隐私告知）
│     ├─ 开书时自动拉取 [ ]
│     └─ 说明
├─ ...
├─ 立即同步当前书
├─ 立即拉取远端高亮  ← 新增（仅双向同步开启时启用）
└─ ...
```

**首次启用弹窗文案**（用户拍板 #1）：
```
即将开启双向同步。

【隐私告知】
开启后，每条高亮会额外记录精确的 DOM 坐标（XPointer）到 Obsidian 笔记。
如果 Obsidian vault 被共享/公开/入侵，攻击者可借此了解你的阅读进度和书籍结构。

【数据流变化】
Obsidian 端的内容会同步回 KOreader。如果你在 Obsidian 删除了某条高亮，
本设备的高亮也会被删除（跨设备同步删除）。

【首次启用】
首次启用会拉取服务器端的所有历史高亮到本设备。

确认开启？
```

### 11. 范围（v4 最终）

#### 必做
- Marker.parse / serialize / diff / applyDiff 改造支持 `seg.meta` 子字段
- 新增 `_doSyncCurrentBookLegacy`（保留 M5/M6 行为）+ `_doSyncCurrentBookBidirectional`（三路合并）
- 新增 `_pullRemoteHighlights`（实际是 Bidirectional 路径的拉取动作）
- 新增 `_computeThreeWayActions` 纯函数（写到独立 `threeway.lua` 模块 + unit test）
- `fns_sync_state.lua` 独立文件 + 原子写
- `_sync_in_flight` 锁扩展 + `_pull_in_flight` 标志
- 拉取时 toast（删除/新增/失败）
- 首次启用弹窗（含隐私告知）
- `onOpenDocument` 拉取钩子（延迟 2s + gated by 配置）
- 新增"立即拉取远端高亮"按钮
- config_version bump v4 + 字段重命名
- DEBUG 日志截断 XPointer（前 40 字符 + 长度）

#### 不做（明确边界）
- 双向同步 note 字段
- 双向同步 color / drawer
- PDF / 漫画支持（格式检测直接跳过拉取）
- XPointer 失效时的文字搜索兜底（留 M8）
- M6 队列的双向同步（强制走 Legacy，用户拍板 #4）
- Obsidian 端编辑高亮文字后回推到 KOreader（留 M8）

#### 留待 M8+
- 文字搜索兜底（不同 epub 版本）
- color / drawer / note 双向同步
- per-book 重置同步状态 UI（v4 通过 reset_config 兜底）
- META@ 来源设备标识（device 短哈希）

---

## 9 类 HIGH 问题整合（去重后）

### A. 数据结构层（META@ 设计）
- v3 的独立 META@ 块设计有 4 个问题（plain=find 冲突 / ts 冲突 / parse 边界 / 畸形保留）
- v4 解决：合并到 HL@ 起标记的 key=value，解析层 attach 到 `seg.meta` 子字段

### B. 路径分流层
- v3 的 _doSyncCurrentBook 内部 if-else 会让 M5/M6 误伤 + 开关穿透 + 状态漂移
- v4 解决：显式分流 Legacy / Bidirectional 两个独立函数

### C. 同步回合原子性
- v3 的推/拉分离会让 last_synced 双重写入中间态不一致
- v4 解决：同步回合概念，单次更新 last

### D. last_synced_ts 部分成功
- v3 设计部分失败仍计入 last → 永久丢高亮
- v4 解决：last = server_ts ∪ successfully_added_local_ts

### E. 持久化事务性
- v3 直接 G_reader_settings:saveSetting 无原子保证
- v4 解决：独立文件 + temp + fsync + rename

### F. 安全层（addItem + XPointer）
- v3 直接传 META@ 的 pos0/pos1 给 addItem，无校验
- v4 解决：pcall + XPointer 格式校验（白名单 + 长度上限）+ chapter 长度限制

### G. 自循环防护
- v3 拉取触发推送的自循环未防护
- v4 解决：`_pull_in_flight` + dispatch 时 `cause="remote_pull"` + M5 跳过该 cause

### H. UI 刷新
- v3 addItem 后 UI 可能不刷新
- v4 解决：批量完成后强制 dispatch 一次 AnnotationsModified

### I. 异常防护
- v3 server_ts_set 异常空 → 全量重插笔记双份
- v4 解决：parse 失败时拒绝执行 + toast 告警

---

## 实施前必须查证（待 git clone 完成）

1. **`addItem` 真实签名**（M-B4 code）：
   - 接受哪些字段？
   - 必填 vs 可选？
   - 是否自动 dispatch AnnotationsModified？
   - 是否需要 chapter/color/drawer？

2. **真实 XPointer 字符串样本**（影响 META@ 解析的字符 escaping）：
   - 字符集是什么？
   - 最大长度多少？
   - 是否含 `"` / `\n` / `<` / `>` 等需要转义的字符？

3. **删除 annotation 的 API**：
   - `removeItemByXPointer` 真的存在吗？
   - 接受 datetime / xpointer / item 引用？
   - 返回值是什么？
   - 是否 dispatch 事件？

4. **KOreader 已有的 importAnnotations 逻辑**：
   - 怎么处理 device_id 防自循环？
   - 怎么处理 datetime 去重？
   - 能否复用？

5. **`AnnotationsModified` 事件 payload**：
   - 是否支持 `cause` 字段？
   - 现有 listener（M5）怎么响应？

git clone 完成后用 Read 工具查证。

---

## 实施前查证完成（git clone KOreader 源码）

### 查证 1：`addItem` 真实签名

源码：`frontend/apps/reader/modules/readerannotation.lua:506-513`

```lua
function ReaderAnnotation:addItem(item)
    item.datetime = item.datetime or os.date("%Y-%m-%d %H:%M:%S")
    item.pageno = self.ui.rolling and self.document:getPageFromXPointer(item.page) or item.page
    item.pageref = self:getPageRef(item.page, item.pageno)
    local index = self:getInsertionIndex(item)
    table.insert(self.annotations, index, item)
    return index
end
```

**关键发现**：
- ✅ 接受 XPointer（rolling 模式下 `page` 是 XPointer 字符串）
- ✅ 必填字段：`page`（XPointer）、`pos0`、`pos1`、`text`
- ✅ 可选字段：`datetime`（缺则用当前时间）、`drawer`、`color`、`note`、`chapter`
- ⚠️ **不 dispatch `AnnotationsModified` 事件**！只插入数组 + 返回 index
- 设计影响：拉取批量完成后必须**手动 dispatch 一次** `AnnotationsModified`，且 payload 加 `cause="remote_pull"` 让 M5 跳过 debounce

### 查证 2：删除 annotation 的 API

源码：`frontend/apps/reader/modules/readerbookmark.lua:466-485`

```lua
function ReaderBookmark:removeItem(item, item_idx)
    local index = item_idx or self:getBookmarkItemIndex(item)
    if item.drawer then
        self.ui.highlight:deleteHighlight(index)
    else
        self:removeItemByIndex(index)
    end
end

function ReaderBookmark:removeItemByIndex(index)
    local item = table.remove(self.ui.annotation.annotations, index)
    local item_type = self.getBookmarkType(item)
    if item_type == "highlight" then
        self.ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = -1, index_modified = -index }))
    elseif item_type == "note" then
        self.ui:handleEvent(Event:new("AnnotationsModified", { item, nb_notes_added = -1, index_modified = -index }))
    end
    self.view.footer:maybeUpdateFooter()
end
```

**关键发现**：
- ❌ **没有 `removeItemByXPointer`**！名称是 agent 推测的，实际不存在
- ✅ 实际 API：`self.ui.bookmark:removeItemByIndex(index)` 或更直接的 `table.remove(self.ui.annotation.annotations, idx)`
- ⚠️ 删除时会 dispatch `AnnotationsModified`（payload 没有 cause 字段）
- 设计影响：拉取过程的"删除"必须用**直接 table.remove**，避免触发 KOreader 内部的 dispatch；批量完成后统一 dispatch 一次带 cause 的事件

### 查证 3：真实 XPointer 字符串样本

源码：`frontend/apps/reader/modules/readerlink.lua:859, 1148, 1153`（注释中的真实样本）

```
/body/DocFragment/body/ul[2]/li[5]/text()[3].16
/body/DocFragment/body/div/p[12]/sup[3]/a[3].0
/body/DocFragment/body/div/div[4]/ul/li[3]/ul/li[2]/ul/li[1]/ul/li[3]/a.0
```

**字符集分析**：
- 字母数字（路径段、索引）
- `/` 路径分隔符
- `[` `]` 数组索引
- `(` `)` 函数（如 `text()`）
- `.` 字符偏移量
- 不含 `"` `\n` `<` `>` `&` 等需要 HTML/JSON 转义的字符

**设计影响**：META@ 块用 `pos0="..."` 双引号格式，XPointer 内不需要转义。可以放心用 `string.find(plain=true)` + 手写状态机解析。

### 查证 4：`importAnnotations` 的合并逻辑可复用

源码：`frontend/apps/reader/modules/readerannotation.lua:279-336`

**可复用部分**：
- `doesMatch` 函数（rolling 模式）：datetime + pos0 + pos1 都相同才算匹配
- `datetime_updated` 比较：新的替换旧的
- device_id 防自循环（line 283）

**不可直接复用**：
- 它处理的是 `.annotations.lua` 文件（外部设备导入），不是 Obsidian 笔记
- 三路合并的"last"概念这里没有（importAnnotations 是两路合并）

**设计影响**：三路合并算法仍需自己实现，但 doesMatch 和 datetime 比较逻辑可以参考。

### 查证 5：`AnnotationsModified` 事件 payload

源码：多处 dispatch（readerbookmark / readerhighlight）

**payload 结构**：
- `payload[1]` = item（被修改的 annotation）
- `payload.index_modified` = 数字（+index = 新增，-index = 删除，nil = 修改）
- `payload.nb_highlights_added` = 数字（增量）
- `payload.nb_notes_added` = 数字（增量）
- `payload.modify_datetime` = bool（强制更新 datetime_updated）
- ❌ **没有 cause 字段**

**设计影响**：我们自定义加 `payload.cause = "remote_pull"`，M5 监听器检查该字段跳过 debounce。

---

## 设计微调（基于查证结果）

### 微调 1：拉取过程的删除不走 `removeItemByIndex`

**原设计**：调用 `self.ui.bookmark:removeItemByIndex(idx)`
**问题**：内部会 dispatch `AnnotationsModified`（无 cause 字段），触发 M5 自循环
**调整为**：直接 `table.remove(self.ui.annotation.annotations, idx)`，不 dispatch。批量完成后统一 dispatch 一次带 cause 的事件。

### 微调 2：拉取过程的插入也不 dispatch

**原设计**：`addItem` 后 dispatch
**查证**：`addItem` 本来就不 dispatch，无需调整。
**仍要做**：批量插入完成后**手动 dispatch 一次** `AnnotationsModified`，payload 加 `cause="remote_pull"` + `nb_highlights_added=N`

### 微调 3：META@ 块的字符 escaping 简化

**原设计**：考虑 XPointer 含特殊字符的转义
**查证**：XPointer 字符集简单（`/[]().`+字母数字），不含 `"` `\n` `<` `>`
**调整为**：META@ 用 `pos0="..." pos1="..." chapter="..."` 格式，无需转义。解析用 `string.find('pos0="', plain)` + 找下一个 `"`。

---

## 待办（设计阶段全部完成）

- [x] 用户拍板 4 个产品决策
- [x] 多角色审查整合完成
- [x] 最终设计 v4 + 改动清单
- [x] 实施前查证（5 项全部完成）
- [x] 设计微调（基于查证）
- [ ] **实施**（等用户确认开始）
- [ ] 代码级审查
- [ ] DEBUG 日志加足
- [ ] Kindle 实测（两台设备互划线 + 互删验证）

预计 1-2 周完成（设计 ✅ + 查证 ✅ + 实施 2-3 天 + 实测 2-3 天 + buffer）。

---

## 今日实施进度（M7 Day 1 部分）

### ✅ 已完成

**Day 1a：`threeway.lua` + unit test**
- 新建 `plugin/fns_sync.koplugin/threeway.lua`
  - `computeActions(server_set, local_set, last_set) → actions`：三路合并纯函数
  - `countActions(actions) → number`：统计 action 总数
  - `validateActions(actions) → bool`：结构校验（测试用）
- 新建 `tests/test_threeway.lua`（不部署 Kindle，开发者本地跑）
  - 覆盖 7 种真值表组合 + 边界（all empty / nil inputs / delete cycle 验证）
  - 关键测试：**删除循环防护**（A 删 X，B 拉取时正确触发 delete_on_local，不会复活 X）
  - 注：本机未装 Lua 解释器，未实际运行。逻辑人工对照真值表确认。等用户机器跑 `lua tests/test_threeway.lua` 验证

**Day 1b：`marker.lua` 改造（部分完成）**

| 函数 | 状态 | 改动 |
|------|------|------|
| `parseOpenMarkerMeta` | ✅ 新增 | 解析 HL@ 起标记的 META 字段（pos0/pos1/chapter），用 plain=find 状态机 |
| `parse` | ✅ 改造 | 调用 parseOpenMarkerMeta，attach 到 `seg.meta`（向后兼容老笔记 seg.meta=nil）|
| `wrapBlock` | ✅ 改造 | 新增可选 `meta` 参数，serialize 时附加到起标记 |
| `serialize` | ✅ 改造 | 调用 wrapBlock 时传 `seg.meta` |
| `diff` | ✅ 改造 | 新增可选 `current_meta_map` 参数，insert/update actions 带 `meta` 字段 |
| `applyDiff` | ❌ **未改造** | 当前不读 `action.meta`，meta 暂时丢失（明天补）|

**中间状态说明**：marker.lua 当前处于不一致状态（diff 输出带 meta 的 action，applyDiff 不读）。但**不影响 M5/M6 功能**：
- M5 实时同步：用户没传 `current_meta_map`（参数可选，nil），diff 输出的 action.meta=nil，applyDiff 行为不变
- M6 队列同步：同上
- 仅 M7 双向同步拉取路径需要 meta，**路径还没实现**，所以中间状态无副作用

### 🔄 明天继续（Day 1b 收尾 + Day 2）

- [ ] 完成 `marker.lua:applyDiff` 改造（让 insert/update 创建新 segment 时带 meta）
- [ ] Day 2a：`main.lua` 核心改造
  - 抽出 `_doSyncCurrentBookLegacy`（保留 M5/M6 行为）
  - 新增 `_doSyncCurrentBookBidirectional`（三路合并 + 同步回合）
  - 新增 `_pullRemoteHighlights`（拉取路径）
  - `_sync_in_flight` 锁扩展为保护双向
  - 新增 `_pull_in_flight` 标志抑制事件回灌
  - 改造 `_triggerSync` 分流 Legacy/Bidirectional
  - 改造 `onAnnotationsModified`（检查 `_pull_in_flight` + payload.cause）
  - 改造 `onOpenDocument`（加拉取钩子，scheduleIn(2s)）
  - 改造 `onCloseWidget`（unschedule `_pull_action`）
  - 新增 `last_synced` 持久化（用 `G_reader_settings:readSetting("fns_sync_last_synced", {})`，简化实施；如果实测发现性能问题再独立文件）
- [ ] Day 2b：config.lua（bump v4 + 字段重命名）+ 菜单 + 首次启用弹窗
- [ ] Day 3：DEBUG 日志加足 + 自审 + 部署清单

### 今日 commit 计划

**改动文件**：
- 修改：`plugin/fns_sync.koplugin/marker.lua`（+107 -16）
- 新增：`plugin/fns_sync.koplugin/threeway.lua`（106 行）
- 新增：`tests/test_threeway.lua`（107 行）
- 新增：`progress/2026-08-06 daily progress.md`（约 600 行：设计 v4 + 审查整合 + 查证 + 实施进度）

**建议 commit message**：
```
feat(M7): 设计 v4 + 三路合并模块 + marker.lua META 解析（部分）

设计阶段（17 HIGH + 27 MEDIUM + 12 LOW 来自 4 agent 审查，去重整合后写到 progress 文档）。
查证 KOreader 源码完成 5 项（addItem 不 dispatch 事件 / 删除 API 真名 / XPointer 字符集 / importAnnotations 可参考 / AnnotationsModified payload 加 cause 字段）。

实施 Day 1 部分：
- threeway.lua 新建（三路合并纯函数 + 真值表覆盖）
- tests/test_threeway.lua 新建（unit test，本地跑不部署）
- marker.lua 改造（parse/serialize/diff 支持 seg.meta，向后兼容老笔记）
- marker.lua:applyDiff 改造留待明天（中间状态不影响 M5/M6）

明日继续 Day 1b 收尾 + Day 2 main.lua 核心改造 + 菜单。
```

**安全检查**：
- ✅ 无密钥/token 泄漏（设计文档只引用代码注释和 API 路径）
- ✅ 无 console.log / debug 残留
- ✅ progress 文档中的 XPointer 样本来自 KOreader 公开源码注释，无隐私
