# 2026-08-14 开发进度

## 主要任务

**M8 Task E-step1 实测问题诊断 + 修复（5 个问题）**

用户昨晚（8-13 下午 14:22-15:50）做了 Task E-step1 Kindle 实测，今天反馈 11 个点，其中 5 个是问题。本日完成：抓 crash.log → 多 agent 诊断 → 多 agent 审查方案 → 修订方案 → TDD 实现 → 代码审查 → 修复。

---

## 阶段一：用户反馈的 5 个问题

| # | 问题 | 用户原话摘要 |
|---|------|------------|
| 1 | 问 AI 卡住 | "点击了问 AI 后，长时间点击无任何反应，我感觉应该是点击问 AI，自动产生高亮，这一步在等待 FNS 服务器" |
| 5 | 立即同步卡顿 + 笔记未出现 | "页面显示正在同步，会卡住一下，然后正在同步显示完成后，笔记也没出现" |
| 6 | 加入笔记后 AI 内容未同步 | "点击之后，没有将 AI 内容进行同步。我看 FNS 服务器端，也没有看到同步记录" |
| 10 | AI@ orphaned + 空行多 + 对话未重置 | 给出 markdown 例子：AI@ ts=14:47:51 hl_ts=14:27:20 orphaned="true" |
| 11 | AI 块如何删除 | （功能缺失，M9 范围）|

---

## 阶段二：crash.log 抓取 + 诊断

### 抓取流程

- Kindle H 盘 → `E:/KOreader-FNS-plugin/.ua/kindle-crash-2026-08-14.log`（330KB）
- 用 FNS API 拉取 server 端 .md → `E:/KOreader-FNS-plugin/.ua/server-note-extracted.md`（36KB，含 47 条 HL@，**0 条 AI@**）

### 日志关键证据（昨晚 14:22-15:50 段）

```
14:24:28 ask-ai clicked → saveHighlight → annotations=48
14:24:37 M5 debounce 同步 → server +1（写入 HL@14:24:28）
14:25:11 神秘第二次 onAnnotationsModified  ← 本地变 47！
14:25:14 同步 → server -1（删掉刚加的）
14:25:15 用户又点问 AI → saveHighlight → annotations=48
... 循环 4 次

14:39:42 queued AI@ (chars=961) → drain 把块从 pending 移到 segments
14:39:44 drained 1 AI@ blocks, 0 remaining  ← pending 已清空！
14:40:14 POST /api/note network error: wantwrite  ← 30秒后 POST 失败
14:42:45 用户点立即同步 → sync success +0~0-0  ← pending 已空，AI 块永久丢失

14:45:54 ask-ai clicked hl_ts=2026-08-12 21:18:58  ← 入口 B 反查成功
14:47:51 queued AI@ block hl_ts=2026-08-13 14:27:20  ← hl_ts 没更新（旧值）！
14:47:52 WARN no matching HL@, appending at end (orphaned)
```

### 5 个问题的初步根因（送审前）

1. **卡顿**：推测 saveHighlight 同步阻塞
2. **数据丢失**：drain 在 POST 前清空 pending
3. **orphaned**：session.hl_ts 不更新
4. **空行多**：marker.lua separator 设计
5. **AI 块删除**：功能缺失

---

## 阶段三：多 agent 诊断审查（4 个 agent）

按 CLAUDE.md "Multi-Perspective Analysis"原则，spawn 4 个 agent 独立审查：

### Architect agent

发现 2 CRITICAL + 3 HIGH：
- 修复 A（去 saveHighlight）副作用：A1 入口 A 永远 orphaned；A2 os.date 时序漂移无解
- 修复 B（drain 回滚）实现风险：B1 首次创建路径破坏、B2 Bidirectional 回滚层级、B3 多块原子性
- 修复 C（session 重置）漏洞：C1 "继续问"按钮不传 hl_ts 会被误判
- D1-D4 边界：神秘第二次事件根因未明、race、orphaned 无限循环、并发未保护

### Factual Reviewer agent（事实核查）

- ❌ **诊断 1 卡顿根因判错**：真凶是 `unwrapped dismissablePopen(), falling back to blocking io.popen()`——KOreader 字典查询（readerdictionary.lua）回退到阻塞 io.popen，**不是 saveHighlight**
- ✅ 诊断 2/3/4 准确
- ⚠️ 新发现：14:47:51 POST **成功**但 server .md 无 AI@，需另查（可能 Obsidian sync 覆盖）

### Senior Engineer agent

3 个必修代码细节：
- Bidirectional POST 失败回滚漏掉
- first-create `if drained > 0` API 不兼容
- H-4 排序逻辑必须保留

### Consistency Reviewer agent

- CRITICAL-1: 修复 B 必须改三处调用点 + POST 失败分支保留 pending
- CRITICAL-2: 修复 A 与决策 6 冲突，需更新文档 + ts 唯一性注释
- HIGH-1: marker.lua separator 一致，但缺 orphaned 测试
- HIGH-2: 修复 C 不冲突，但 _callAiAndShow 缺 session==nil 防御
- MEDIUM: D1 payload 日志不要 dump 整个 table

---

## 阶段四：用户产品决策

- 入口 A 方案 Y：允许 orphaned 追加（接受方案 A 副作用）
- 切换高亮方案 P：重置对话（每个高亮 = 新对话）

---

## 阶段五：修订后的最终方案

| 修复 | 改动 |
|------|------|
| **B** | drain helper 抽到 `Marker.drainAiBlocks(pending, segments, book_path)` 纯函数（不修改 pending）；新增 `_commitDrainedAi(drained)` helper（用 ts\|hl_ts 作 key）；3 处调用点 POST 成功才 commit |
| **C** | `_openAiInputDialog` 加 `if hl_ts ~= nil and session.hl_ts ~= hl_ts then reset end` + 防御日志；`_callAiAndShow` 入口加 `if not session then return end` 防御 |
| **A** | 入口 A 不调 saveHighlight，不反查 annotations，直接 `hl_ts = os.date()` fallback；progress 文档记录决策 6 修订 |
| **D1** | `onAnnotationsModified` 加 payload 限定字段日志（cause/nb_highlights_added 等，不 dump table） |
| **测试** | test_marker_ai.lua 补 9 项测试（orphaned round-trip + drain 各种场景） |

---

## 阶段六：TDD 实现

### 红：写测试

9 项新测试加到 `tests/test_marker_ai.lua`：
- #10: orphaned AI@ meta round-trip 幂等
- #11-#14: drain 基本场景（空 / book 不匹配 / 匹配 HL@ / orphaned fallback）
- #15: H-4 同 hl_ts 多块排序
- #16: drain 不修改 pending（CRITICAL fix 直接验证）
- #17: drain 后 serialize 幂等
- #18: 混合 book_path（2 匹配 + 1 不匹配）

跑红：`drainAiBlocks` 是 nil（不存在）。

### 绿：实现修复

- `marker.lua` 新增 `Marker.drainAiBlocks`（纯函数，保留 H-4/H-5/LOW-4 逻辑）
- `main.lua` `_drainPendingAiBlocks` 改为 thin wrapper（不再修改 pending）
- `main.lua` 新增 `_commitDrainedAi` helper（key 用 ts|hl_ts + 碰撞 warn）
- 3 处调用点统一：Legacy / first-create / Bidirectional
- 入口 A 去 saveHighlight + os.date fallback
- `_openAiInputDialog` 加切换重置 + 防御日志
- `_callAiAndShow` 入口加 session==nil 防御 + closure 内 session 一致性检查
- `onAnnotationsModified` 加 payload 限定字段日志 + KOreader cause 值注释

跑绿：50/50 → 56/56（多了 6 项 drain 测试）。

---

## 阶段七：Code Reviewer agent 审查

**Verdict: APPROVED**

| 级别 | 数量 | 状态 |
|------|------|------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 1 | info（drained key 碰撞理论风险，实际不触发）|
| LOW | 2 | note（closure stale session / payload cause 列举）|

3 项 M/L 全部顺手修：
- MEDIUM：drain key 碰撞 warn 日志（drained_keys 改为计数 map）
- LOW-1：closure 入口加 `if self._ai_session ~= session then return end`
- LOW-2：payload 日志加 KOreader cause 值列举注释

补 1 条混合场景测试（#18）。

最终测试：**marker_ai 56/56 + threeway 19/19 + config_ai 17/17 = 92 项全过**。

---

## 改动文件清单

| 文件 | 改动 |
|------|------|
| `plugin/fns_sync.koplugin/marker.lua` | 新增 `Marker.drainAiBlocks` 纯函数（约 55 行）|
| `plugin/fns_sync.koplugin/main.lua` | 8 处改动（drain helper 重构 + 新 commit helper + 3 调用点 + callback 重写 + session 切换 + _callAiAndShow 防御 + payload 日志）|
| `tests/test_marker_ai.lua` | 新增 9 项测试 |

预计总规模：约 150 行代码改动 + 60 行测试。

---

## 决策记录修订

### 决策 6（Task E-step1）二次修订

#### 原决策（方案 A，已废弃）

- 自动 saveHighlight + 反查 hl_ts

#### 一次修订（方案 Y，已废弃）

- 不 saveHighlight + os.date fallback + 接受 orphaned 追加到笔记末尾
- 原因（误判）：
  1. ~~saveHighlight 同步阻塞在 Kindle e-ink 上慢~~（code-explorer 调研证伪）
  2. 触发 AnnotationsModified → M5 debounce → 高亮反复创建删除（日志显示 48↔47 抖动循环 4 次）
  3. 无法解决用户感受到的"卡顿"（真凶是 KOreader 自身 dismissablePopen，FNS 不能修）

#### 二次修订（方案 Z，最终方案）

- **恢复 saveHighlight（异步）+ 反查 hl_ts**
- 触发原因：实测发现方案 Y 的副作用——AI@ 块 orphaned 追加到笔记末尾，**没有 HL@ 上下文**，用户读笔记时困惑（"AI 在回答什么原文？"）
- 用户原话："摘录和AI块分开，并且都保留"——方案 Z 完美满足

#### 方案 Z 可行性调研（code-explorer agent）

| 困难 | 评估 |
|------|------|
| 1. saveHighlight 卡顿？| ❌ 不存在。code-explorer 调研：saveHighlight 只做 addItem（纯内存），不写盘 |
| 2. 抖动 bug？| ⚠️ 当前代码不会重现。M7 双重防护（_pull_in_flight + cause=remote_pull）+ Legacy 路径不改本地 |
| 3. 异步 saveHighlight？| ✅ 简单。UIManager:scheduleIn(0, ...) |
| 4. clear() 副作用？| ✅ 无。clear 只清屏幕选区，不删 annotation |
| 5. 改动量？| ✅ 10-15 行（仅 main.lua:248-309 入口 A callback）|

#### 方案 Z 实施

入口 A callback 重写为：
```lua
UIManager:scheduleIn(0, function()
    -- 1. capture selected_text
    -- 2. 入口 A: saveHighlight + 反查；入口 B: 直接用 selected_text.datetime
    -- 3. 关闭 highlight menu（保留高亮）
    -- 4. 立即 clear 选区（不再延迟 0.1 秒）
    -- 5. 弹 InputDialog
end)
```

#### 方案 Z 代价

- 问 AI 后高亮**强制保留**（即使不想要也要手动删）
- 用户已接受

---

## 阶段八：Kindle 实测（下午进行）

### 实测前的基础设施问题

#### 服务器证书更换 + 重启不稳定

- 用户今早更换服务器证书（DigiCert → Encryption Everywhere DV TLS CA - G2）
- 未重启服务 → 部分请求走新证书、部分走旧证书 → 表现极不稳定
- 我这边 curl 测试：5 次中 2 次超时，POST 全部超时
- 用户重启服务后仍不稳定（重启后预热期）
- 约 10 分钟后服务器稳定：10 次 GET 全部 < 0.15s

#### 排除的可能

- ❌ 证书问题（浏览器 Security 显示"证书有效且可信"）
- ❌ Kindle 网络问题（testConnection 走 HTTPS 成功）
- ❌ Token / Vault 问题（testConnection 成功）
- ❌ 我的代码 bug（crash.log 证明 drain helper / payload 日志 / M5 路径全正常）

#### 关键证据（crash.log line 11:07 段）

```
11:07:21 onAnnotationsModified payload={ hl_added=1 idx_mod=48 }  ← 修复 D1 日志工作
11:07:24 sync start (auto) annotations=48                          ← M5 触发
11:07:27 GET /api/note biz_code=1 Success                          ← GET 成功
11:07:27 inserting HL@ block ts=...11:07:21 at position 96         ← diff 正确
11:07:27 drained 0 AI@ blocks (commit pending after POST success)  ← 修复 B 日志工作
11:07:37 POST /api/note network error: timeout                     ← POST 服务器超时
```

修复 B/C/D1 在 crash.log 中**全部验证生效**，唯一失败是服务器 POST 端。

### 实测进度

| Phase | 状态 | 备注 |
|-------|------|------|
| Phase 1（M5/M6/M7 回归）| ✅ | 服务器稳定后通过 |
| Phase 2（Task D AI 对话）| ✅ | 2.1-2.5 全过 |
| Phase 3.A（修复 A 入口 A 不加亮）| ✅ | 通过（注：方案 Y 验证，方案 Z 后行为变化）|
| Phase 3.B（修复 B POST 失败回滚）| ⏳ | 验证方法问题（modal 阻挡关 WiFi），下午用"关路由器"方案 |
| Phase 3.C（修复 C 切换重置）| ✅ | 通过 |
| Phase 3.D（同一高亮继续问）| ⏳ | 下午 |
| Phase 3.E（入口 B hl_ts 正确）| ⏳ | 下午 |
| Phase 4（边界场景）| ⏳ | 下午 |
| Phase 5（抓 crash.log）| ⏳ | 下午 |

### Phase 3 实测发现的新问题（已解决）

用户实测 Phase 3 后反馈："加入笔记会出现没有原文摘录，但是有 AI 块的情况，我认为，如果没有 HL 块但是有 AI 块不合理。"

→ 这是方案 Y 的副作用（入口 A 不 saveHighlight，HL@ 不存在）
→ 用户决策改用方案 Z（恢复 saveHighlight）
→ 本次实施

---

## 子代理工作流经验（本次复盘）

### 成功点

1. **多 agent 诊断有效**：4 个 agent 各自从不同视角找到不同问题（architect 找架构问题、factual 找事实错误、senior 找代码细节、consistency 找一致性问题）
2. **factual reviewer 找到关键错误**：卡顿根因判错（saveHighlight → dismissablePopen），如果不是 factual 独立 read 日志，会按错误根因修复
3. **TDD 流程有效**：先写 drain 测试看到红 → 实现 → 绿，确保新 API 正确

### 教训

1. **初步诊断可能错**：我对卡顿根因的判断来自代码直觉（saveHighlight 同步），但日志 factual 显示真凶是 KOreader 字典查询阻塞。这验证了"不要相信直觉，看日志"
2. **方案需要自审 + 外审**：architect 给的修复 A 反馈（A1/A2 问题）让我重新评估，最终用户拍板方案 Y 简化决策
3. **3 路径调用点同步**：drain 在 Legacy / first-create / Bidirectional 三处都调用，senior engineer 提醒"必须同时改三处"，避免遗漏

---

## 仍然未解的问题

| 问题 | 状态 | 计划 |
|------|------|------|
| 卡顿真凶（dismissablePopen）| FNS 无法修 | 建议用户在 KOreader 设置里关"长按时显示字典" |
| 14:47:51 POST 成功但 server 无 AI@ | 可能 Obsidian sync 覆盖 | 后续观察；如频繁出现，补"POST 后 GET 验证"兜底 |
| AI 块删除 UI | M9 范围 | 短期 USB 编辑 settings.reader.lua 的 `fns_sync_pending_ai` 字段 |
| "神秘第二次 AnnotationsModified" | 等 D1 日志 | 下次 Kindle 实测时 payload 日志会暴露 cause |

---

## 当前分支状态

- 分支：`feat/m8-ai-chat`
- ahead：9 commits（Task A/B/C/D + E-step1）+ 本日修复（待 commit）
- behind：0
- push 状态：**未 push**（按惯例等 M8 全部完成 + 实测全通过）

---

## 明日计划

### 用户 Kindle 实测（最终验收）

完整 10 步流程 + 错误/边界场景 + 关键验收点：
- **问 AI 不卡顿**（注意：dismissablePopen 仍卡，但 saveHighlight 抖动消除）
- **AI@ 块在 POST 失败时不再丢失**（关键修复 B）
- **切换高亮重置对话**（方案 P）
- **payload 日志能看到 cause**（D1 诊断）
- M5/M6/M7 零回归

### 实测后

如全通过 → commit + 考虑 push 到 master。

---

## 文档产出

- `progress/2026-08-14 daily progress.md` — 本文档
- `plugin/fns_sync.koplugin/marker.lua` — `drainAiBlocks` 纯函数
- `plugin/fns_sync.koplugin/main.lua` — 8 处修复 + 决策 6 修订
- `tests/test_marker_ai.lua` — 新增 9 项测试
- `.ua/kindle-crash-2026-08-14.log` — 昨晚 Kindle crash.log 副本（不入 git）
- `.ua/server-note-guoshidagang.md` / `server-note-extracted.md` — server 端 .md 拉取（不入 git）
