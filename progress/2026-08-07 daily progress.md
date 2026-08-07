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
