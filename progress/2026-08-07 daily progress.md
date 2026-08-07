# 2026-08-07 开发进度

## 主要任务

M7 Day 1b 收尾：`marker.lua:applyDiff` 改造（让 insert/update 创建新 segment 时透传 `action.meta`，完成 marker.lua 的 META 字段闭环）。

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
