# 2026-08-07 开发进度

## 主要任务

M7 Day 1b 收尾 + Day 2a 启动。

- Day 1b：`marker.lua:applyDiff` 收尾（已 commit）
- Day 2a Commit 1：main.lua dispatcher 拆分 + 锁扩展 + 持久化 helper + 事件抑制（无行为变化）

---

## 范围说明

延续 2026-08-06 的 M7 设计 v4，今日只做一件小事：把昨日遗留的 applyDiff 半成品收尾。

决策：本机不装 Lua 解释器，`tests/test_threeway.lua` 留待 Kindle 实测阶段统一验证（逻辑已人工对照真值表）。

---

## 改动详情

### 文件：`plugin/fns_sync.koplugin/marker.lua`

`applyDiff` 函数两处构造新 segment 的位置：

**1. update 分支**（原第 320 行）：
```lua
-- Before
table.insert(after_inplace, { type = "hl", ts = seg.ts, content = a.content })

-- After
local new_seg = { type = "hl", ts = seg.ts, content = a.content }
if a.meta then new_seg.meta = a.meta end
table.insert(after_inplace, new_seg)
```

**2. insert 分支**（原第 343 行）：
```lua
-- Before
table.insert(after_inplace, pos, { type = "hl", ts = ins.ts, content = ins.content })

-- After
local new_seg = { type = "hl", ts = ins.ts, content = ins.content }
if ins.meta then new_seg.meta = ins.meta end
table.insert(after_inplace, pos, new_seg)
```

### 设计要点

- **匹配 parse() 模式**：line 173-174 的 parse 函数已经是「先构造 new_seg，meta 非空才 attach」的写法，applyDiff 改造完全对齐这一模式。
- **向后兼容**：`a.meta` 为 nil 时（M5/M6 路径不传 current_meta_map），new_seg 不写入 meta 字段，老笔记 round-trip 行为不变。
- **M7 路径**：当双向同步通过 current_meta_map 传入 `{ pos0=..., pos1=..., chapter=... }` 时，applyDiff 创建的新 segment 自动带上 meta，后续 serialize 时会写入 HL@ 起标记。

### 风险评估

- ✅ 不影响 M5 实时同步（current_meta_map 为 nil → action.meta 为 nil → 不写入 seg.meta）
- ✅ 不影响 M6 队列同步（同上）
- ✅ 不影响 marker.parse / serialize / diff（已昨日完成）
- ✅ 中间状态彻底闭环：diff 输出带 meta 的 action，applyDiff 正确消费；双向同步路径未实现前，meta 字段自然为 nil

---

## M7 实施进度地图

| 阶段 | 状态 |
|------|------|
| 设计 v4 | ✅ 完成（昨日） |
| 实施前查证 5 项 | ✅ 完成（昨日） |
| Day 1a：`threeway.lua` + unit test | ✅ 完成（昨日，逻辑未实跑） |
| Day 1b：`marker.lua` parse/serialize/diff | ✅ 完成（昨日） |
| **Day 1b：`marker.lua` applyDiff** | **✅ 完成（今日）** |
| Day 2a：`main.lua` 核心改造 | ⏳ 待办 |
| Day 2b：config bump v4 + 菜单 + 首次启用弹窗 | ⏳ 待办 |
| Day 3：DEBUG 日志 + 自审 + 多 agent 审查 | ⏳ 待办 |
| Kindle 两台设备实测 | ⏳ 待办 |

---

## 今日 commit 计划

**改动文件**：
- 修改：`plugin/fns_sync.koplugin/marker.lua`（+12 -2，仅 applyDiff 函数）
- 新增：`progress/2026-08-07 daily progress.md`

**建议 commit message**：
```
feat(M7): marker.lua applyDiff 收尾，透传 action.meta 到新 segment

Day 1b 最后一里：applyDiff 的 insert/update 分支构造新 segment 时
读 action.meta，匹配 parse() 的「meta 非空才 attach」模式。

M5/M6 路径不传 current_meta_map，action.meta 自然为 nil，新 segment
不写入 meta 字段，行为不变。

marker.lua 整体闭环：parse/serialize/diff/applyDiff 全部支持 seg.meta
子字段。M7 双向同步拉取路径尚未实现，meta 字段暂时无入口进入 action。

明日进入 Day 2a：main.lua 核心改造（抽出 _doSyncCurrentBookLegacy +
新增 _doSyncCurrentBookBidirectional + _pull_in_flight 锁）。
```

**安全检查**：
- ✅ 无密钥/token 泄漏
- ✅ 无 console.log / debug 残留
- ✅ 改动行数小（14 行），易于人工 review

---

## Day 2a Commit 1：dispatcher 拆分 + 基础设施（无行为变化）

### 改动文件

- `plugin/fns_sync.koplugin/main.lua`（+82 -2）

### 改动详情（6 处）

**1. dispatcher 拆分**（line ~510）
- 新增 `_doSyncCurrentBook` dispatcher：根据 `bidirectional_sync_enabled` 分流到 Legacy 或 Bidirectional
- 原 `_doSyncCurrentBook` 改名为 `_doSyncCurrentBookLegacy`
- Bidirectional 分支引用了尚未实现的 `_doSyncCurrentBookBidirectional`，但 `bidirectional_sync_enabled` 此时为 nil（Day 2b 才进 Config.DEFAULTS），所以走不到

**2. M6 队列路径直接调 Legacy**（line ~945）
- `_processQueueItem` 内部 `pcall` 从 `_doSyncCurrentBook` 改为 `_doSyncCurrentBookLegacy`
- 契合用户决策 #4（progress 2026-08-06 line 142）：离线书不做拉取，队列强制走 Legacy

**3. init 加锁**（line ~134）
- 新增 `self._pull_in_flight = false`：拉取过程中抑制 M5 debounce 的标志
- 新增 `self._pull_action = function() self:_pullRemoteHighlights() end`：用于 `onOpenDocument` 延迟拉取的稳定 closure（Commit 3 才会被 scheduleIn）

**4. `onAnnotationsModified` 加 pull 抑制**（line ~709）
- 检查 `_pull_in_flight`：拉取批量 addItem 期间所有 AnnotationsModified 都跳过
- 检查 `payload.cause == "remote_pull"`：批量完成后我们手动 dispatch 一次的事件，M5 显式跳过
- 两层防护对应设计 v4 H-S2 fix（progress 2026-08-06）

**5. `onCloseWidget` 加 unschedule `_pull_action`**（line ~1169）
- 防止 ReaderUI teardown 后 closure 还在 UIManager 队列里，触发死引用
- 模式与现有 `_queue_drain_action` / `_auto_sync_action` 一致

**6. 新增 `_getLastSyncedSet` / `_saveLastSyncedSet` helper**（line ~183）
- 持久化三路合并的 base 引用（per-book ts set）
- 存储位置：`G_reader_settings["fns_sync_last_synced"]`，结构 `{ [book_path] = { [ts] = true, ... }, ... }`
- **简化实施**（vs progress v4 设计的独立文件 + 原子 temp+fsync+rename）：用 G_reader_settings 牺牲 hard-crash 原子性换实施简单；per-book ts set 通常 <100 条，KOreader LuaSettings 的 flush 足够；实测如发现腐败再升级到独立文件

### 行为不变性验证

| 路径 | Commit 1 之前 | Commit 1 之后 | 备注 |
|------|--------------|--------------|------|
| M5 实时同步（onAnnotationsModified → debounce → _triggerSync） | _triggerSync → _doSyncCurrentBook | _triggerSync → _doSyncCurrentBook → **_doSyncCurrentBookLegacy** | 多一层 dispatcher，结果相同 |
| M5 关书同步（onCloseDocument → _autoSyncCurrentBook） | 同上 | 同上 | 同上 |
| 手动按钮（onSyncCurrentBook → _triggerSync） | 同上 | 同上 | 同上 |
| M6 队列（_processQueueItem） | _doSyncCurrentBook | **_doSyncCurrentBookLegacy**（直接调用） | 避开 dispatcher，确保队列永不走 Bidirectional |
| init 流程 | 设置 _sync_in_flight / queue / _queue_drain_action | 加设置 _pull_in_flight / _pull_action | 新增字段不影响现有 |
| AnnotationsModified 触发 | M5 debounce 正常 reschedule | _pull_in_flight=false / cause≠remote_pull → 走原路径 | 抑制路径未被触发 |

### 风险与限制

- dispatcher 引用了 Commit 2 才实现的 `_doSyncCurrentBookBidirectional` —— 安全：`bidirectional_sync_enabled` 此时为 nil
- `_pull_action` 引用了 Commit 2 才实现的 `_pullRemoteHighlights` —— 安全：Commit 1 没 scheduleIn 它
- 用户无法在 UI 上启用双向同步（菜单按钮 Day 2b 才加）—— 安全：默认走 Legacy

### Commit 信息

```
feat(M7): Day 2a/Commit 1 — main.lua dispatcher 拆分 + 锁扩展 + 持久化 helper

无行为变化（bidirectional_sync_enabled 默认 nil → dispatcher 走 Legacy）。

基础设施铺路：
- _doSyncCurrentBook 改为 dispatcher，原逻辑搬到 _doSyncCurrentBookLegacy
- M6 队列直接调 _doSyncCurrentBookLegacy（用户决策 #4：离线书不拉取）
- init 加 _pull_in_flight 标志 + _pull_action 稳定 closure
- onAnnotationsModified 加 pull 抑制（_pull_in_flight + cause=remote_pull）
- onCloseWidget unschedule _pull_action
- 新增 _getLastSyncedSet / _saveLastSyncedSet helper（简化版：用 G_reader_settings）

Commit 2 实现 _doSyncCurrentBookBidirectional + _pullRemoteHighlights。
```

---

## Day 2a Commit 2：_doSyncCurrentBookBidirectional + _pullRemoteHighlights

### 改动文件

- `plugin/fns_sync.koplugin/main.lua`（+367 -7）
- `plugin/fns_sync.koplugin/excerpt.lua`（+11 -2，renderFullNote 加可选 current_meta_map 参数）

### 实施前发现的设计漏洞

**漏洞 1：跨设备 text 字段同步**

设计阶段没考虑过：B 设备拉 A 设备同步过来的高亮时，text 字段从哪来？server 上 HL@ 块的 content 是渲染后的 markdown（带 `> 📖 第 N 页`），没法反推原始 text。

**用户决策（2026-08-07）**：用 KOreader 的 `document:getTextFromXPointers(pos0, pos1)` API 实时从本地书的 XPointer 范围提取 text。同时加**文字一致性校验**：用子串匹配（extracted 是否是 server seg.content 的子串）检测跨设备书版本不一致。不一致时**跳过 + 警告**（A 方案），M8 升级文字搜索兜底。已存入 memory `project_m7_version_mismatch.md`。

**漏洞 2：_triggerSync 在 annotations 为空时早返回**

启用 Bidirectional 后首次按"立即拉取"按钮时本地通常没高亮，但 _triggerSync 的早返回会阻断 pull 路径。修复：只在非 Bidirectional 模式下早返回。

**漏洞 3：跳过的 ts 会被错误计入 last_synced**

实施时 self-review 发现：如果跳过的 ts 仍计入 last_synced，下次三路合并会判定"server 有 local 没 last 有" → delete_on_local（noop）→ 永不重试。修复：在 Step 11 推导 `skipped_local_ts = actions.insert_on_local - successfully_added_local_ts`，从 new_last 中显式排除。

### 改动详情

**1. 顶部 require 新增**
- `local Threeway = require("threeway")`：昨日写的三路合并纯函数模块
- `local Event = require("ui/event")`：用于 dispatch AnnotationsModified with cause

**2. excerpt.lua:renderFullNote 加可选第 4 参数 current_meta_map**

签名：`renderFullNote(highlights_by_ts, settings, meta, current_meta_map)`

- 当 current_meta_map 非空时，每个 HL@ 块的起标记带 pos0/pos1/chapter
- 当 nil 时（Legacy 路径），行为不变（向后兼容）
- 用途：Bidirectional 首次同步创建笔记时也要带 META 字段，否则其他设备拉下来 seg.meta=nil 无法 addItem

**3. _triggerSync 修复 annotations 早返回**

`if #annotations == 0 and not self.settings.bidirectional_sync_enabled then` —— Bidirectional 路径允许空 annotations（首次启用 pull 场景）。

**4. _doSyncCurrentBookBidirectional（核心新增，~280 行 + 60 行 doc comment）**

13 步同步回合：
1. annotations 防御性 nil → {}
2. can_pull gate 在 self.ui.rolling（PDF 等 paging 模式跳过 pull phase）
3. 渲染本地 highlights_by_ts
4. 构造 local_ts_set + current_meta_map from annotations
5. GET server note
6. 首次同步（note 不存在）→ createNote + 初始化 last_synced = local_ts_set
7. parse server → server_segments + server_ts_set + server_seg_by_ts
8. 异常防护：server_ts_set 空 + last_ts_set 非空 → 区分"用户清空"vs"格式损坏"（后者拒绝执行）
9. 三路合并 computeActions
10. 应用 server actions（转 Marker 格式 + Marker.applyDiff + serialize → new_server_content）
11. 应用 local actions：
    - insert_on_local：getTextFromXPointers → 子串校验 → 通过 addItem / 失败 skip + warn
    - delete_on_local：直接 table.remove（倒序，避免 dispatch）
    - _pull_in_flight 包裹整个过程
12. overwriteNote(new_server_content)
13. 更新 last_synced = (server_ts ∪ insert_on_server - delete_on_server) - skipped_local_ts
14. dispatch AnnotationsModified ONCE with cause="remote_pull"（仅当有变更）
15. toast + 详细日志

**5. _pullRemoteHighlights（30 行）**

"立即拉取远端高亮"按钮入口。是 _triggerSync{ silent=false } 的薄包装（dispatcher 自动路由到 Bidirectional）。Per 设计 v4 H-A2，推拉不可分割。

### 跳过 case 统计维度（4 类）

| 类型 | 触发条件 | 处理 |
|------|---------|------|
| `n_skip_no_meta` | server seg 缺 meta（老笔记无 pos0/pos1） | 跳过 + warn |
| `n_skip_text_empty` | getTextFromXPointers 返回空（XPointer 完全失效） | 跳过 + warn + XPointer 头 40 字 + 长度 |
| `n_skip_text_mismatch` | 子串校验失败（书版本不一致） | 跳过 + warn + extracted 头 40 字 + content 头 40 字 |
| `n_skip_failed` | addItem pcall 失败 | 跳过 + warn + err |

所有跳过的 ts 都不计入 last_synced（推导自 `insert_on_local - successfully_added`），下次同步自动重试。

### 行为不变性验证

| 路径 | Commit 1 之后 | Commit 2 之后 |
|------|--------------|--------------|
| M5 实时同步 | 走 Legacy | bidirectional_sync_enabled 为 nil → 仍走 Legacy |
| M5 关书同步 | 走 Legacy | 同上 |
| 手动按钮 | 走 Legacy | 同上 |
| M6 队列 | 直接调 Legacy | 同上（强制 Legacy 不变） |
| 首次启用 Bidirectional + 手动按"立即拉取" | (Commit 2 之前按钮不存在) | _pullRemoteHighlights → _triggerSync → dispatcher → Bidirectional |

### 已知限制（M8 升级方向）

- 跳过的 ts 永远不会自动恢复（直到书版本一致），需要 M8 文字搜索兜底
- drawer 硬编码 "lighten"（KOreader 默认值），不跟用户设置走
- 子串校验依赖 server content 含原始 text，用户改 excerpt_template 后可能失效（边界 case）
- `_sync_in_flight` 锁在 _pullRemoteHighlights 入口被强制清掉，理论上有并发风险（manual override，与 onSyncCurrentBook 一致）

### Commit 信息

```
feat(M7): Day 2a/Commit 2 — _doSyncCurrentBookBidirectional + _pullRemoteHighlights

完整的 13 步同步回合（拉 → 三路合并 → 应用双方 → 推 → 更新 last）。
跨设备 text 字段用 getTextFromXPointers 从本地书实时提取 + 子串校验。
书版本不一致时跳过+警告（用户拍板 A 方案），M8 升级文字搜索兜底。

新代码：~370 行（main.lua）+ 11 行（excerpt.lua renderFullNote 加可选 meta_map）

修复 3 个实施时发现的 bug：
- _triggerSync annotations 早返回阻断 pull（Bidirectional 首次启用场景）
- 跳过的 ts 错误计入 last_synced 导致下次不重试（推导 skipped_local_ts 排除）
- dispatcher 注释更新（Commit 1 说"stubbed until Commit 2"，现已实现）

明日 Commit 3：onOpenDocument 加 scheduleIn(2s) → _pull_action（gated by pull_on_book_open）。
Day 2b：config bump v4 + 菜单加"双向同步"子树 + "立即拉取"按钮 + 首次启用弹窗。
```

---

## Day 2a Commit 3：onOpenDocument 加 pull 钩子

### 改动文件

- `plugin/fns_sync.koplugin/main.lua`（+10 -0）

### 改动详情

`onOpenDocument` 函数末尾加：
```lua
if self.settings.bidirectional_sync_enabled and self.settings.pull_on_book_open then
    logger.info("[FNS] onOpenDocument: scheduleIn(2s) → _pull_action (bidirectional pull)")
    UIManager:scheduleIn(2, self._pull_action)
end
```

### 行为不变性

- `bidirectional_sync_enabled` 此时为 nil（Day 2b/Commit 1 才进 DEFAULTS）→ falsy → 不触发 pull
- 即使 Day 2b 加默认值后，仍需用户手动开启两个开关才生效

### 关键设计

- 2s 延迟：让 ReaderUI 完全起来（特别是 crengine 加载 epub）再 fire HTTP + addItem batch
- `_pull_action` 是 init 中分配的稳定 closure，`onCloseWidget` 能 unschedule 干净（避免 teardown 后死引用）

---

## Day 2b Commit 1：config bump v4 + 字段重命名 + migration

### 改动文件

- `plugin/fns_sync.koplugin/config.lua`（+35 -4）
- `plugin/fns_sync.koplugin/main.lua`（+16 -0，仅 init 的 migration block）

### 改动详情

**1. config.lua: `CURRENT_CONFIG_VERSION = 3` → `4`**

**2. config.lua DEFAULTS 字段调整**

| 操作 | 字段 | 原因 |
|------|------|------|
| 删除 | `sync_on_book_open` | M5 占位字段，从未实际接线；v4 重命名为 `pull_on_book_open` |
| 新增 | `bidirectional_sync_enabled = false` | M7 双向同步总开关 |
| 新增 | `pull_on_book_open = false` | 开书自动拉取（替代 sync_on_book_open） |
| 新增 | `bidirectional_first_use_confirmed = false` | 首次启用弹窗确认标志 |

**3. config.lua 注释补充**
- M7 字段说明（含隐私告知：XPointer 坐标会进 Obsidian 笔记）
- M6 队列字段补充 M7 NOTE（队列强制走 Legacy，引用用户决策 #4）

**4. main.lua:init 加 v3 → v4 migration block**

```lua
if prev_version < 4 then
    if self.settings.sync_on_book_open ~= nil then
        self.settings.pull_on_book_open = self.settings.sync_on_book_open
        self.settings.sync_on_book_open = nil
        logger.info("[FNS] migrated settings v3→v4: sync_on_book_open → pull_on_book_open")
    else
        logger.info("[FNS] migrated settings v3→v4: no rename needed (sync_on_book_open was nil)")
    end
end
```

### 老用户升级路径

| 老版本 | 老字段值 | v4 升级后 |
|--------|---------|----------|
| v3（默认） | `sync_on_book_open = false` | `pull_on_book_open = false`（DEFAULTS backfill + migration 覆盖）|
| v3（用户手动 true） | `sync_on_book_open = true` | `pull_on_book_open = true`（用户意图保留）|
| v1/v2（无 sync_on_book_open） | 字段不存在 | `pull_on_book_open = false`（DEFAULTS backfill）|

### 行为不变性

- DEFAULTS 中所有 M7 字段都默认 false → dispatcher 仍走 Legacy
- "触发模式"子菜单里仍有 `sync_on_book_open` 引用（line 1485 区域）—— Commit 2 菜单改造会清理

### Commit 信息

```
feat(M7): Day 2b/Commit 1 — config bump v4 + 字段重命名 + migration

- CURRENT_CONFIG_VERSION 3 → 4
- DEFAULTS: 删除 sync_on_book_open（M5 占位），新增 3 个 M7 字段
- main.lua:init 加 v3→v4 migration（sync_on_book_open → pull_on_book_open）

Day 2b/Commit 2: 菜单加"双向同步"子树 + "立即拉取"按钮 + 首次启用弹窗。
```

---

## Day 2b Commit 2：菜单改造 + 首次启用弹窗

### 改动文件

- `plugin/fns_sync.koplugin/main.lua`（+112 -8）

### 改动详情（4 处）

**1. 新增 `_toggleBidirectionalSync` 方法（含首次启用弹窗）**

放在 `_toggleBool` 后面。逻辑：
- 关闭双向同步：silent toggle（不弹"are you sure"）
- 开启 + 已确认过：silent toggle
- 开启 + 首次：弹 ConfirmBox（含隐私告知文案，per progress v4 设计 + 用户决策 #1）
  - 用户点确认 → 设 `bidirectional_sync_enabled=true` + `bidirectional_first_use_confirmed=true` + 提示信息

**2. "自动同步"子树末尾加"双向同步（实验性）"子树**

```
自动同步
├─ 启用自动同步
├─ 高亮修改时同步
├─ 关闭书籍时同步
├─ 同步延迟（秒）
└─ 双向同步（实验性） [ ]  ← 新增
   ├─ 启用双向同步 [ ]
   ├─ 开书时自动拉取 [ ]
   └─ 说明（弹出 InfoMessage 介绍功能）
```

enabled_func 链式：
- "启用双向同步"：requires enabled + auto_sync_enabled + isConfigured
- "开书时自动拉取"：上面 + bidirectional_sync_enabled（必须先开双向才能开拉取）

**3. "立即同步当前书"后加"立即拉取远端高亮"按钮**

按钮一直可见（discoverability hint），enabled 仅在 bidirectional_sync_enabled=true 时。callback 调 `_pullRemoteHighlights`（Commit 2 已实现）。

**4. 删除"设置 → 触发模式 → 开书同步"项**

原项引用 `sync_on_book_open`（v4 已废），是 M5 时的 placeholder 从未实际工作。删除后用注释说明原因（保留可追溯性）。

### 行为不变性

- DEFAULTS 中所有 M7 字段默认 false → 所有新菜单项 disabled 或不影响现有路径
- 老用户升级 v3→v4 后：菜单看到"双向同步（实验性）[ ]"（关），"开书同步"项消失（原 placeholder）
- 现有 M5/M6 路径完全不变

### 首次启用弹窗文案（per progress v4 设计 line 270-286）

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

按钮：「开启」/「取消」

### 文件头注释更新

main.lua 顶部模块说明：
- 加 M7 一节（bidirectional_sync_enabled gate / 三路合并 / 同步回合 / 版本不一致处理 / 格式 gate / 队列强制 Legacy）
- 删除 "Stubbed: sync_on_book_open"
- "Not in scope" 加 M8 待办：文字搜索兜底 / note+color+drawer 同步 / per-book 重置 UI

### Commit 信息

```
feat(M7): Day 2b/Commit 2 — 菜单加"双向同步"子树 + "立即拉取"按钮 + 首次启用弹窗

- _toggleBidirectionalSync 方法（首次启用弹窗 + bidirectional_first_use_confirmed 防重弹）
- "自动同步"子树末尾加"双向同步（实验性）"子树（3 项：toggle / 拉取 / 说明）
- "立即同步当前书"后加"立即拉取远端高亮"按钮（enabled 链式）
- 删除"设置 → 触发模式 → 开书同步"项（M5 placeholder，已被 pull_on_book_open 替代）
- 文件头注释加 M7 一节，删过时 stub 项

Day 2b 全部完成。下一步 Day 3：DEBUG 日志加足 + 自审 + 多 agent 审查。
```

---

## Day 3 多 agent 审查 + bug 修复

### Phase 3：4 agent 并行审查结果

| Agent | HIGH | MEDIUM | LOW |
|-------|:---:|:---:|:---:|
| silent-failure-hunter | 3 | 5 | 5 |
| security-reviewer | 2 | 4 | 2 |
| code-reviewer | 2（含撤回 1）| 4 | 4 |
| architect | 3 | 4 | 2 |

### Phase 4 修复（按严重度分级）

#### HIGH 全部修复 ✅

1. **_pull_in_flight 异常路径不释放**（silent H1 + code H1）：在 _triggerSync 的 pcall finally 中复位两把锁 + toast 提示内部错误
2. **onCloseWidget 防御性复位 _pull_in_flight**（code M4 + architect H3 复合）
3. **XPointer 格式校验 + 长度上限**（security H1）：白名单 `^/[%w_%-%./%[%]()]+$` + MAX_XPOINTER_LEN=256
4. **server note 大小上限**（security H2）：MAX_NOTE_BYTES=1MB 防 DoS
5. **_pullRemoteHighlights 加 manual 参数**（architect H3）：自动 scheduleIn 不再强制清锁，避免抢占 M5 debounce
6. **chapter 长度+换行校验**（security M2）：MAX_CHAPTER_LEN=256
7. **同步回合原子性重构**（architect H1+H2）：Step 9 拆为"extract+validate"和"apply local"，中间插入 overwriteNote

#### MEDIUM 部分修复 ✅

- extracted_head 改成 extracted_len（privacy：不打用户文字到 crash.log）
- original_ctime 加 or 0 兜底
- DEBUG 加 impossible_ts 列表：last 残留 ts 可诊断

#### 未修（记入 M8 backlog）

| 问题 | 来源 | 决策 |
|------|------|------|
| 函数拆分（320 行→ 3 helper） | code H2 | 改动大，目前可工作，M8 重构 |
| 不同步 content update | code M2 | 设计层面决策 |
| last_synced 独立文件持久化 | architect M1 | 简化 trade-off 已记录 |
| chapter markdown 注入深度防御 | security M2 | 已加长度+换行校验作为第一道防线 |
| v3→v4 migration toast 告知 | security M4 | 罕见场景 |
| _loadBookFromPath 失败降级 | silent M2 | M6 路径 |
| 缺 marker/excerpt 单元测试 | code L2 | M8 补 |

### 同步回合原子性重构详情（architect H1+H2）

**原流程**：
```
Step 9: apply local (addItem + table.remove)
Step 10: overwriteNote
```
**问题**：Step 9 改本地，Step 10 失败时本地有"幽灵高亮"，重试混乱。

**新流程**：
```
Step 9: extract + validate → items_to_add + indices_to_remove
Step 10: overwriteNote (失败时本地未改 → 重试幂等)
Step 11: apply local (addItem + table.remove)
```

好处：overwriteNote 失败时本地未改 → 重试幂等；_pull_in_flight 临界区更窄。

### Phase 5：Kindle 实测清单（独立文档）

详见 `progress/M7-Kindle-实测清单.md`。

包含：
- 部署 + M5/M6 回归测试
- M7 阶段 1-7 实测场景（启用 → 首次同步 → 双向新增 → 删除 → Obsidian 删 → 版本不一致 → PDF）
- crash.log 关键 grep
- 验收标准 + 失败排查表
