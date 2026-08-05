# 2026-08-05 开发进度

## 主要任务

M5：自动同步（高亮修改 + 关书事件触发 + debounce）。

代码层面已完成，待用户部署到 Kindle 实测。

---

## 仓库命名讨论（未实施，留待后续）

用户提出想把根目录 `KOreader` 改名为 `KOreader FNS plugin` 并推送到 GitHub。经讨论确定：

- 仓库名 / 本地根目录：`KOreader-FNS-plugin`（连字符，避免空格在 bash / Windows 路径 / GitHub URL 的诸多坑）
- KOreader 插件包名：保持 `fns_sync`（snake_case 是 KOreader 约定，仓库名不影响）
- 插件显示名：保持 `FNS Sync`
- 老用户配置迁移：无（包名和 settings key 都没变，无痛升级）

→ 结论：**代码一行不改**，只是后续重命名目录 + 推 GitHub。本次会话未执行，因为 Windows 不允许重命名当前进程占用的目录（本会话 cwd 就是 `E:\KOreader`），需要用户退出 Claude Code 后手动操作。

---

## M5 设计方案

### 功能行为

| 触发场景 | 行为 |
|---------|------|
| 划线 / 改笔记 / 加书签等操作 | debounce N 秒后自动同步（成功静默，失败弹 toast） |
| 合书 | 立即同步（在线时；离线静默跳过） |
| 离线 | 静默跳过，不弹 WiFi 对话框；高亮数据由 KOreader 本地存（`metadata.lua`），下次开书/合书/手动按钮补上 |
| 同步进行中又触发新的 | 共用 `_sync_in_flight` 锁，新触发跳过（手动按钮强制清锁，信任用户意图） |

### 设置默认值（4 个字段）

| key | 默认 | 说明 |
|-----|------|------|
| `auto_sync_enabled` | `true` | 自动同步总开关（在 `enabled` 主开关之下） |
| `sync_on_highlight` | `true`（沿用 M1 占位） | 高亮修改触发 |
| `sync_on_book_close` | `true`（M1 占位是 false，本次改为 true） | 关书触发 |
| `debounce_seconds` | `5`（M1 占位是 3，本次改为 5） | debounce 秒数 |
| `sync_on_book_open` | `false`（保留占位，M5 不实施） | 留给未来"拉同步"里程碑 |

### 不实现（明确边界）

- 离线队列 / 自动重试 → M6
- 双向同步（拉 Obsidian 改动到 KOreader）→ 不在路线图
- 跨书批量自动同步 → M6/M7
- 网络恢复监听（联网后自动补推）→ 用户选择方案 A，不做（M6 离线队列完整方案）

---

## 自审发现 + 修复（核心环节）

### 设计阶段自审：5 个问题

1. **关书时如果离线，会弹"是否启用 WiFi"对话框打断关书** —— 默认走 `NetworkMgr:runWhenOnline` 会弹。修复：`_autoSyncCurrentBook` 入口加 `isOnline` 检查，离线静默跳过。
2. **debounce 计时器在关书时残留 → 关书后异步触发，self.ui 已销毁** —— 修复：`onCloseDocument` 入口**无脑**取消 debounce 计时器（即使关书同步开关关）。
3. **silent 模式不应显示 "正在同步…" toast** —— 修复：把这一行包进 `if not silent then ... end`。
4. **silent 模式 `_doSyncCurrentBook` 也不应显示成功/失败 toast** —— 修复：`_doSyncCurrentBook` 加 `silent` 参数，所有 `UIManager:show` 用 `if not silent` 包裹，失败始终 `logger.warn`。
5. **子菜单 `enabled_func` 应反映综合状态** —— 修复：`enabled && auto_sync_enabled && isConfigured()`，让用户看到当前是否实际生效。

### Code review 抓出的 2 个 HIGH

独立审查（code-reviewer agent）发现：

**[HIGH-1] TOCTOU 窗口**：`_autoSyncCurrentBook` 检查 `isOnline=true` 后，`_triggerSync` 走 `runWhenOnline`，两步之间网络可能掉线 → `runWhenOnline` 弹 WiFi 对话框 → 关书时弹在 FileManager 上，灾难性。

**[HIGH-2] 锁挂起**：`runWhenOnline` 离线挂起时 callback 永不执行 → `_sync_in_flight` 锁不释放 → 同一本书内后续所有自动同步被锁挡住。

**统一修复**：`_triggerSync` 加 `opts.skip_run_when_online` 参数。自动同步路径（高亮 + 关书）传 `true`，跳过 `runWhenOnline` 包装，只靠 `_autoSyncCurrentBook` 入口的 `isOnline` 检查；手动按钮保留 `runWhenOnline`（用户主动按，弹 WiFi 提示合理）。

→ HIGH-1 消失（不走 runWhenOnline，没有 TOCTOU）；HIGH-2 消失（不被 runWhenOnline 离线挂起，锁不会卡死）。

### 其他审查发现（不修，可接受）

- **MEDIUM-1**：建议在 `_triggerSync` 注释加"禁止再读 self.ui"强约束 → 已加。
- **MEDIUM-2**：close 时 offline 的 pending 高亮延迟日志 → 已有 `logger.info("[FNS] auto-sync skipped: offline (will catch up on next trigger)")`。
- **LOW-1**：`onAnnotationsModified(payload)` 形参未用，建议改 `_` → 保持现状（KOreader 其他模块也用 `payload` 命名）。
- **LOW-2**：`debounce_seconds` 用户编辑后变 string，与 DEFAULTS 的 number 不一致 → `_rescheduleAutoSync` 已 `tonumber() or 5` 兜底。

---

## 改动清单

### `config.lua`

`Config.DEFAULTS` 表里"Trigger mode"一节重写：

- 新增 `auto_sync_enabled = true`（M5 总开关）
- `sync_on_book_close` 默认 `false` → `true`
- `debounce_seconds` 默认 `3` → `5`
- `sync_on_book_open` 保留 `false`，加注释"reserved, not implemented in M5"
- `sync_on_highlight` 沿用 `true`

不 bump `config_version`：所有新字段都是 nil→default 的 backfill，老用户首次启动行为=开箱即用，无副作用。

### `main.lua`

**1. init 函数末尾新增运行时状态**（不持久化）：
- `self._auto_sync_action` —— 稳定闭包，作为 `UIManager:scheduleIn / unschedule` 的 action key。必须用同一引用，因为 `unschedule` 按 action 引用比较；新建闭包会让 unschedule 找不到旧任务，导致关书后残留触发。
- `self._sync_in_flight` —— 并发锁，手动按钮和自动触发共用，防止同一本书同时跑两个同步。

**2. 重构 `onSyncCurrentBook` 为共用入口 `_triggerSync{silent=...}`**：
- 4 道短路：`_sync_in_flight` 锁、`enabled`、`isConfigured`、annotations 非空
- eager 抓取 `annotations / meta / path` 为局部变量（关键：关书异步路径不依赖 self.ui）
- 锁设置在入口，释放在 `nextTick` 的 `pcall` finally（无论成功/失败/异常都释放）
- 新增 `opts.skip_run_when_online`（修 HIGH-1/2）
- `onSyncCurrentBook` 入口强制清锁（兜底上一次 runWhenOnline 离线挂起的场景）

**3. `_doSyncCurrentBook` 加 `silent` 参数**：
- 所有成功/失败 `UIManager:show(InfoMessage:new{...})` 用 `if not silent then ... end` 包裹
- `_showSyncError` 调用同样受 silent 控制
- 失败始终 `logger.warn`，确保日志可追溯

**4. 新增 4 个辅助方法**：
- `_gateAutoSync()` —— 4 道短路：`enabled && auto_sync_enabled && isConfigured && self.ui.annotation` 存在
- `_rescheduleAutoSync()` —— `unschedule(self._auto_sync_action)` + `scheduleIn(delay, self._auto_sync_action)`，`delay = tonumber(...) or 5; math.max(0, delay)`
- `_cancelAutoSyncTimer()` —— 仅 `unschedule`
- `_autoSyncCurrentBook()` —— 入口 `NetworkMgr:isOnline()` 检查（离线静默跳过）+ `_triggerSync{silent=true, skip_run_when_online=true}`

**5. 新增 2 个事件回调**：
- `onAnnotationsModified(payload)` —— `gateAutoSync → sync_on_highlight → rescheduleAutoSync`。忽略 payload（KOreader dispatch 点 payload 结构不固定，只用事件作为触发信号）。
- `onCloseDocument()` —— 第一行**无脑**`_cancelAutoSyncTimer()`（即使关书同步开关关，也要取消残留计时器），然后 `gateAutoSync → sync_on_book_close → _autoSyncCurrentBook`。

**6. 菜单**：在"启用 FNS 同步"和"立即同步当前书"之间插入"自动同步"子菜单：
- 启用自动同步（总开关，`checked_func`）
- 高亮修改时同步（`enabled_func = enabled && auto_sync_enabled && isConfigured`）
- 关闭书籍时同步（同上 `enabled_func`）
- 同步延迟（秒）（`_editString` 输入数字）

---

## 关键设计决策（备忘）

### 为什么 `_auto_sync_action` 必须是稳定闭包

`UIManager:unschedule(action)` 按 action 引用比较（`uimanager.lua:443 self._task_queue[i].action == action`）。如果每次 reschedule 都新建闭包，unschedule 找不到旧任务 → 关书后旧任务仍会触发 → 此时 self.ui 已销毁 → 抓 `self.ui.annotation.annotations` 拿不到。

init 里创建一次，永不重新赋值。所有调用点（`_rescheduleAutoSync` / `_cancelAutoSyncTimer`）都用 `self._auto_sync_action`。

### 为什么自动同步路径跳过 `runWhenOnline`

`NetworkMgr:runWhenOnline(callback)`（`manager.lua:698-708`）：
- 在线 → 立即执行 callback
- 离线 → `beforeWifiAction` → 默认 `promptWifiOn` 弹对话框

自动同步（特别是关书路径）绝不能弹对话框：
- 关书时弹"是否启用 WiFi" → 对话框落在 FileManager 上 → 用户困惑
- 离线挂起 → 锁挂起 → 同书后续自动同步全跳过

修复：`_triggerSync` 加 `opts.skip_run_when_online`，自动同步路径传 `true`。手动按钮保留 `runWhenOnline`（用户主动按，弹 WiFi 提示是合理的，且锁挂起的场景下用户可以再按一次按钮强制清锁）。

### 为什么 `_autoSyncCurrentBook` 仍要 `isOnline` 检查

跳过 `runWhenOnline` 后，没有"等网络"的兜底。如果 isOnline=false 时仍调 `_triggerSync{skip=true}`，会直接 nextTick → `_doSyncCurrentBook` → HTTP 失败 → 浪费一次请求（虽然 silent=true 不打扰用户）。所以入口先 isOnline 检查，离线静默跳过更高效。

### 为什么手动按钮强制清锁

`onSyncCurrentBook` 入口 `self._sync_in_flight = false`。原因：用户上次按按钮时如果离线，`runWhenOnline` 会弹对话框，用户取消 → callback 永不执行 → 锁挂起。下次按按钮如果不强制清锁，会被 `_triggerSync` 入口的锁检查挡住。手动按钮是显式用户意图，应该总是触发；潜在并发（手动 + 自动）的代价由 API 的幂等性（基于 path 的 overwrite）兜底。

### 为什么 `onCloseDocument` 无脑取消计时器

场景：用户启用了"高亮修改时同步"但关掉了"关闭书籍时同步"。划线后立刻合书（< 5 秒）：
- 如果不无脑取消 → debounce 计时器残留 → 关书后 5 秒触发 → self.ui 已销毁 → 闭包内 `_autoSyncCurrentBook` 仍能跑（不依赖 self.ui），但 `_triggerSync` 入口抓 annotations 时拿不到 → 触发"当前书没有高亮/笔记"分支（但 silent=true 不显示）→ 浪费一次 schedule
- 无脑取消 → 计时器干净，不会有任何残留触发

代价：如果用户关掉了关书同步，pending 的高亮修改要等下次开书/手动按钮补推。但这是用户选择（关掉了关书同步），可接受。

### 为什么"开书同步"留给未来里程碑

开书同步 = 拉取 Obsidian 端的修改到 KOreader。这跟当前插件"只推不拉"的语义冲突，需要：
- KOreader 端 annotations 表与 Obsidian 端笔记内容的双向 merge 算法
- 冲突解决策略（同一条高亮两边都改了怎么办）
- 这是"双向同步"的工作，远超 M5 范围

`sync_on_book_open` 字段保留 false 占位，未来实施时复用。

---

## 部署清单（累积，截至本次）

Kindle 上需要更新的文件（覆盖全部 M5 改动）：
- `config.lua`（DEFAULTS 4 字段）
- `main.lua`（_triggerSync 重构 + 4 辅助方法 + 2 事件回调 + 菜单）

其他文件（api.lua / marker.lua / excerpt.lua）M5 未动。

## 待用户操作

部署 2 个文件到 Kindle，测试步骤：

1. 重启 KOreader（让 init 创建 `_auto_sync_action` 闭包）
2. 打开一本有高亮的书
3. 验证菜单结构：工具 → FNS 同步 → 自动同步子菜单（4 项）
4. **场景 A：在线 + 划新高亮** → 等 5 秒 → 应静默同步（无 toast），日志可见 `[FNS] sync start (auto)`
5. **场景 B：在线 + 合书** → 应立即静默同步
6. **场景 C：连续划多段** → 5 秒内只触发一次（debounce 合并）
7. **场景 D：手动按钮** → 应显示"正在同步..." + 成功 toast
8. **场景 E：离线 + 划线** → 静默跳过，日志可见 `auto-sync skipped: offline`
9. **场景 F：关掉"高亮修改时同步"，划线后合书** → 不应有任何同步触发（计时器被取消，关书同步也关）

预期全部通过则 M5 完成。

---

## M5 实测结果（用户反馈，2026-08-05）

部署 2 个文件到 Kindle（覆盖 config.lua + main.lua），重启 KOreader 后跑 6 场景：

| # | 场景 | 结果 | 备注 |
|---|------|------|------|
| A | 在线 + 划新高亮 → 等 5 秒 | ✅ 通过 | 静默同步，无 toast |
| B | 在线 + 合书 | ✅ 通过 | 立即静默同步 |
| C | 连续划多段（debounce 合并） | ⏭️ 跳过 | Kindle 反应慢，5 秒内连划 3 段难稳定复现；用户决定不验证，留待未来有人提出再排查。代码逻辑（稳定闭包 + unschedule 按引用匹配）理论上正确。 |
| D | 手动按钮 | ✅ 通过 | "正在同步…" + 成功 toast |
| E | 离线 + 划线 | ✅ 通过 | 静默跳过，**无 WiFi 弹窗** → HIGH-1 修复（`skip_run_when_online`）验证有效 |
| F | 关掉"高亮修改时同步"后合书 | ✅ 通过 | 无任何同步触发（`_cancelAutoSyncTimer` + 关书同步开关都关）|

**额外验证**：KOreader 端删除高亮 → Obsidian 端反应正常 → `_doSyncCurrentBook` 的 delete 分支（`n_del > 0`）路径有效。

**结论**：M5 核心路径全部通过，5/6 场景验证 + 删除路径额外验证。C 跳过属可接受风险（不影响数据正确性，最坏情况是同书多触发一次同步，API 幂等性兜底）。

**M5 里程碑：完成 ✅**

---

## M6 设计方案（设计 + 自审完成，待实施）

### 范围

| 必须 | 不做（避免膨胀） |
|------|------------------|
| 离线时入队（按书去重） | 跨设备队列同步 |
| 联网后自动补推（核心增量） | 队列优先级 |
| 跨书批量串行处理 | 同步进度 toast |
| 重启后队列保留 + 启动补推 | 失败通知 push |
| 失败重试上限 + 冻结 + 手动重试 | 队列条目过期 |

### 与 M5 的关系

M5 已实现"事件驱动补推"——离线跳过，等下次开书/合书/手动按钮时补推。
M6 加的是"**联网后即时补推**"——不等用户操作，联网就推。这是 M5 设计时埋的伏笔（用户当时选了"方案 A — M5 不做网络监听，留给 M6 完整方案"）。

### 功能行为

| 触发场景 | 行为 |
|---------|------|
| 在线划线 | M5 路径，实时同步（不变） |
| **离线划线 / 离线关书** | 入队（按书 path 去重），写盘 |
| **网络恢复**（`onNetworkConnected` 事件） | 触发 `_processQueue()` 串行处理所有条目 |
| **开书 / 关书 / 手动按钮** | 兜底触发 `_processQueue()`（防事件未注册） |
| 单条同步失败 | `attempts++`，保留在队列 |
| `attempts >= 5` | 该条**冻结**，不再被自动处理；UI 显示"已失败 5 次" |
| 用户点"重试冻结条目" | 重置 `attempts = 0`，立即触发处理 |
| 用户点"清空队列" | 确认对话框 → 清空 |
| KOreader 启动 | `scheduleIn(10s)` 检查队列，如果联网则处理 |

### 配置字段（极简，只 1 个新增）

| key | 默认 | 说明 |
|-----|------|------|
| `offline_queue_enabled` | `true` | 队列总开关（在 `enabled` 主开关 + `auto_sync_enabled` 之下） |

`max_retry_attempts = 5` 写死在代码常量 `Config.MAX_RETRY_ATTEMPTS`，**不暴露给用户**（避免菜单膨胀；5 是合理默认）。

### 数据结构

```lua
-- G_reader_settings["fns_sync_queue"]
{
  ["/path/to/book.epub"] = {
     ts       = 1234567890,   -- 最后一次入队时间戳（用于排序和 UI 显示）
     attempts = 0,             -- 连续失败次数；>= MAX_RETRY_ATTEMPTS(5) 则冻结
     title    = "书名",         -- 仅 UI 显示用，同步时实时从 metadata.lua 读最新 annotations
  },
  ...
}
```

### 处理流程

```
[入队] _autoSyncCurrentBook 离线分支
  → 检查 offline_queue_enabled
  → queue[book_path] 已存在? 仅更新 ts (不写盘)
                          : 新建条目 (写盘 saveSettings)
  → 日志: "queued — will auto-retry when network reconnects"

[触发] onNetworkConnected / onOpenDocument / onCloseDocument / onSyncCurrentBook
  → _processQueue()

[处理] _processQueue()
  → 检查 _queue_processing 标志 (重入保护, 修 HIGH-2)
  → 检查 _sync_in_flight (与 M5 实时同步互斥)
  → 取队列里 ts 最早且 attempts < 5 的条目
  → _triggerSync{ silent=true, book_path=path, source="queue" }
       → 成功: queue[path] = nil → saveSettings → 继续下一条 (链式)
       → 失败: entry.attempts++ → saveSettings → 继续下一条 (链式)
            ↑ 这里是关键修复: 串行链式而不是 for 循环并发, 修 HIGH-1

[启动] init 末尾
  → scheduleIn(10s, function() if isOnline() then _processQueue() end end)
```

---

## M6 自审发现 + 修复

### 🔴 HIGH-1：批量补推会被 `_sync_in_flight` 锁挡住

**问题**：队列里 N 本书要补推，遍历时调 `_triggerSync`。但 M5 的锁是"同一时刻只能跑一次同步"。第一条异步跑（HTTP 飞着）→ 锁占用 → 第二条入口被锁挡住跳过 → 后续全跳过。

**结果**：每次联网事件只补推第一本，后面的书永远补不上。

**修复**：队列处理改为**串行链式**——前一条完成（成功/失败的回调里）才递归处理下一条。具体实现：`_processQueue` 每次只处理一条，完成后调用自身处理下一条，直到队列空。

### 🔴 HIGH-2：多个触发源重入

**问题**：联网事件、开书、关书、手动按钮可能同时（同一 tick 内多次）触发 `_processQueue()`。第二次调用会与正在进行的处理冲突 → 重复 HTTP + attempts 双倍消耗。

**修复**：`_processQueue` 入口加 `self._queue_processing` 标志，处理中则跳过。标志在所有出口（成功/失败/异常）释放。

### 🟡 MEDIUM-1：网络事件名不一定存在

**问题**：设计假设 KOreader 有 `onNetworkConnected` 事件，**未确认**。如果没有，纯靠三道兜底（开书/关书/手动按钮）不够——用户联网后不开书不操作 → 队列永远不处理。

**修复**：
- 实施前 grep KOreader 源码（`frontend/apps/network/networkmanager.lua`、`frontend/dispatcher.lua`）确认事件名
- 找到则按 `on<EventName>` 注册
- 找不到则降级：`UIManager:scheduleIn(60, _checkNetworkAndProcess)` 轮询（每 60 秒检查一次 isOnline，联网则处理队列，处理完停止轮询直到下次离线→联网切换）

### 🟡 MEDIUM-2：离线狂划线频繁写盘

**问题**：用户离线狂划线 → debounce 触发多次 → 每次入队都 saveSettings → IO 频繁，对 Kindle 闪存不友好。

**修复**：入队时按书 path 去重——
- queue[path] 已存在 → 只更新内存中的 `ts`，**不写盘**
- queue[path] 不存在 → 创建条目，**写盘一次**
- 关书事件 / KOreader 退出时统一 flush 一次（保证不丢）

### 🟢 LOW 级（接受，不修）

| 问题 | 影响 | 为什么接受 |
|------|------|----------|
| UI 显示的"N 本"略滞后 | 用户重开菜单即刷新 | 非关键数据 |
| 队列永久保留 | 占用极小磁盘（每条 ~100 字节） | 用户离线旅行场景需要 |
| 跨设备同书冲突 | 后同步的覆盖先同步的 | 不在 M6 范围（API 基于 path overwrite 语义） |

---

## 关键设计决策（备忘）

### 为什么按"书"粒度而不是按"修改事件"粒度

KOreader 自己把每本书的 annotations 存在该书的 `metadata.lua` 里不会丢。队列只需"提醒哪些书 pending"，同步时实时读 metadata.lua 拿最新版即可。如果队列存 annotations 快照：
- 占用空间大
- 同步时可能拿旧快照覆盖用户后续的修改（用户离线时先划 A，又删除 A，队列里如果存了"A 存在"的快照，同步时会把 A 加回去 → 数据错乱）

### 为什么 attempts 上限是 5

覆盖典型故障场景：
- 临时网络抖动（1-2 次）→ 应该重试到成功
- 路由器短时断外网（3-5 分钟，多次联网事件触发）→ 5 次能扛过去
- 持久故障（外网封了 Obsidian 服务、token 失效）→ 5 次后停止浪费请求

低于 5（如 2 次）容易把临时问题判死刑；高于 5（如 20 次）浪费请求。5 是经验值。

### 为什么不暴露 `max_retry_attempts` 给用户

菜单项越多用户越困惑。5 是合理默认，需要调整的用户极少（极少数会改）。如果未来有用户提需求，再加菜单项。

### 为什么选事件驱动 + 三道兜底，而不是纯轮询

- **事件优先**：零开销，联网即时触发
- **三道兜底**：事件未注册 / 没触发时，开书/关书/手动按钮仍能补推
- **降级轮询**：MEDIUM-1 修复——如果事件名确认不存在，降级到 60 秒轮询 + 兜底

### 为什么入队时按 path 去重不写盘

M5 实测发现 Kindle 反应慢、闪存写频繁不友好。按 path 去重后：
- 用户离线连续划 10 条 → debounce 触发 2-3 次 → 第一次入队写盘，后续只更新内存 ts
- 关书或退出时 flush 一次 → 写盘次数从 N 降到 1-2

### 为什么有"重启后启动延迟 10s"

避免 KOreader 启动时的 race（启动时大量模块初始化、UI 还没稳定）。10s 后再处理队列，给系统时间稳定。如果 10s 后还没联网 → 不处理，等用户操作或联网事件。

---

## 改动清单（实施时）

### `config.lua`

- `Config.DEFAULTS` 新增 `offline_queue_enabled = true`
- 新增常量 `Config.MAX_RETRY_ATTEMPTS = 5`
- 不 bump `config_version`（新字段 nil→default backfill，老用户无痛）

### `main.lua`

- `init` 末尾：新增 `self._queue_processing = false`、加载 `self.queue = G_reader_settings:readSetting("fns_sync_queue", {})`、`scheduleIn(10s, _startupQueueCheck)`
- `_autoSyncCurrentBook`：离线分支从"静默跳过"改为"调用 `_enqueueCurrentBook`"
- 新增 `_enqueueCurrentBook`：按 path 去重 + 写盘逻辑（修 MEDIUM-2）
- 新增 `_processQueue`：重入保护（修 HIGH-2）+ 串行链式处理（修 HIGH-1）+ 锁互斥
- 新增 `onNetworkConnected`（待 MEDIUM-1 确认事件名后注册）
- 修改 `onOpenDocument` / `onCloseDocument` / `onSyncCurrentBook`：调用 `_processQueue()` 兜底
- 新增菜单：「自动同步」子菜单下加"待同步队列（N 本）"+ "重试冻结条目" + "清空队列"
- 修改 M5 的离线日志文案：`auto-sync skipped: offline (will catch up on next trigger)` → `auto-sync skipped: offline (queued — will auto-retry when network reconnects)`

### `_doSyncCurrentBook` 的改造

当前签名 `_doSyncCurrentBook(annotations, meta, path, silent)` 假设有 self.ui 上下文。队列处理时**没有 self.ui**（书可能已关），需要：
- 新增一个变体 `_doSyncBookByPath(book_path, silent, on_complete)` —— 从指定 path 读 metadata.lua 拿 annotations 和 meta
- 或者把现有 `_doSyncCurrentBook` 重构为接受外部传入的 annotations/meta（已经是这样了，只需补一个"从 path 加载 annotations"的辅助方法）

倾向后者——复用现有逻辑，加一个 `_loadBookFromPath(book_path) -> annotations, meta, nil|err` 辅助。

---

## 待办（实施前）

- [x] 在 KOreader 源码确认 `onNetworkConnected` 事件名（MEDIUM-1 修复前提）
  - 已确认：`onNetworkConnected` / `onNetworkDisconnected` 事件存在
  - 触发点：`manager.lua:154`（启动时如已联网 broadcast 一次）、`manager.lua:872`（重连）、`manager.lua:109`（连接成功）
  - 参考实现：`plugins/kosync.koplugin/main.lua:1012` 的 `_onNetworkConnected`（用 `scheduleIn(0.5, ...)` 延迟 0.5s 避开启动 race）
  - 设计简化：删掉 `scheduleIn(10s)` 启动延迟（KOreader 自动广播），删掉 60s 轮询降级方案

---

## M6 多角色独立审查（4 agent 并行）

参考 CLAUDE.md `agents.md` 多角色并行模式。4 个 agent 独立审查 M6 设计文档，找新问题（不重复自审的 HIGH-1/2 + MEDIUM-1/2）。

### 数字结果

| 来源 | HIGH | MEDIUM |
|------|------|--------|
| 自审（已记录在上方）| 2 | 2 |
| architect | +2 | +3 |
| code-reviewer | +3 | +4 |
| security-reviewer | +3 | +4 |
| silent-failure-hunter | +3 | +3 |
| **去重整合** | **+9** | **+9** |

### HIGH 级修复方案

**HIGH-A：插件双实例化导致状态分裂**
- 问题：插件无 `is_doc_only`，FileManager 和 ReaderUI 各实例化一次 → `_queue_processing` 是实例级标志，互斥失效 → 同书并发推两次
- 来源：architect
- 影响：HIGH-1 串行链式修复被绕过，整个 M6 设计前提失效
- 修复：**待拍板 1**（见下方）

**HIGH-B：`_triggerSync` 不能复用**
- 问题：M5 的 `_triggerSync` 强依赖 `self.ui.annotation`（main.lua:335），队列处理时书可能已关 → 崩溃或读错数据
- 来源：architect + silent + code-reviewer（三 agent 都指出）
- 影响：启动补推、联网补推、跨书批量全部撞雷
- 修复：M6 队列走独立入口 `_processQueueItem(path)` → 直接调 `_doSyncBookByPath`，**完全不经 `_triggerSync`**。两把锁解耦：`_sync_in_flight` 给 M5 实时路径，`_queue_processing` 给 M6 队列路径

**HIGH-C：队列持久化泄漏 PII**
- 问题：path + title 明文存到 `G_reader_settings`，任何 KOreader 插件可读，备份 settings 时也被带走
- 来源：security
- 影响：隐私泄漏（阅读书单 + 敏感目录路径）
- 修复：**待拍板 2**

**HIGH-D：pcall 失败回调链断裂**
- 问题：M5 的 pcall 失败只 `logger.warn`（main.lua:356-362），M6 串行链式依赖回调推进 → 异常时 `_queue_processing` 锁不释放 → 队列永久卡死
- 来源：silent + code-reviewer
- 修复：pcall 失败分支必须释放 `_queue_processing` 锁 + 触发链式下一条（视为失败计入 attempts）

**HIGH-E：saveSettings 失败被吞**
- 问题：`G_reader_settings:saveSetting` 不抛错也不回滚，磁盘失败时内存与磁盘不一致 → 重启后丢条目或重复处理
- 来源：silent + code-reviewer
- 修复：写盘后校验返回值（如返回 bool/nil），失败 `logger.error` + 在 UI 标记条目"未保存"

**HIGH-F：path 失效导致永久冻结**
- 问题：用户重命名/移动/删除书文件 → `_loadBookFromPath` 失败 → 一路 attempts 到冻结 → 永远修不好，UI 无法提示根因
- 来源：code-reviewer + silent
- 修复：`_loadBookFromPath` 返回 `nil, "file_missing"` 时立即从队列移除该条目 + `logger.warn`，不消耗 attempts 配额

**HIGH-G：重试冻结与并发处理无锁**
- 问题：用户点"重试冻结"重置 `attempts=0` 的瞬间，链式 `_processQueue` 正在迭代同一 entry → 重复同步 + attempts 双倍消耗
- 来源：code-reviewer
- 修复：reset 入口也走 `_queue_processing` 重入保护；或改为"置 ts=now + attempts=0 后仅触发一次 `_processQueue`"，由串行链式拾取

**HIGH-H：`_showSyncError` 泄漏 token**
- 问题：服务端 message 原样透传到 UI / 日志，某些网关在 4xx body 里回显 `Authorization` 前缀或 token 片段
- 来源：security
- 修复：`_showSyncError` / `logger.warn` 前对 `result.message` 截断（≤200 字符）+ 过滤 `Bearer`/`token`/`api_token` 子串

**HIGH-I：token 失效不快速失败**
- 问题：FNS code 307/308（token 失效）仍重试 5 次才冻结 → 期间 5 次无效请求 + 服务端可能风控
- 来源：security
- 修复：**待拍板 3**

### MEDIUM 级修复方向（简列）

| # | 问题 | 修复 |
|---|------|------|
| M-1 | 队列与 `_sync_in_flight` 共锁死锁窗口 | HIGH-B 解耦后消失 |
| M-2 | 内存 ts 未 flush（用户 kill 进程丢失）| `onCloseDocument` + `onSuspend` 统一 flush；首次入队立即同步写盘 |
| M-3 | 冻结条目累积全表扫描 | 维护 `active` / `frozen` 子表，事件触发时 short-circuit |
| M-4 | 串行链式 N 次 saveSettings 与 MEDIUM-2 冲突 | 内存 dirty 标记 + 节流写盘（成功可延迟，失败立即）|
| M-5 | `scheduleIn(10s)` vs `onOpenDocument` 兜底撞车 | `_processQueue` 跳过 path == 当前打开书的条目（让实时路径处理）|
| M-6 | `_loadBookFromPath` 路径穿越 / 资源耗尽 | 校验 path 后缀 ∈ {.epub,.pdf,.cbz,...}；metadata.lua 用受控解析 |
| M-7 | `onNetworkConnected` 无去抖，网络抖动短时多次触发 | 加 100ms 去抖（最近一次触发时间戳）|
| M-8 | 跨设备并发同步"后覆盖前"静默丢失 | **待拍板 4** |
| M-9 | 降级方案（60s 轮询）落地为代码 | 检测 `onNetworkConnected` 未触发时启用周期性 `isOnline()` 检查 |

### LOW 级（接受，不修）

- `title` 字段可能过期 → UI 显示时实时读 metadata（M-1 修复时一并处理）
- `ts` 排序：去重时若 `attempts>0` 保留首次入队 ts 保证 FIFO
- 启动 `scheduleIn(10s)` 在离线时仍排程 → init 检查 `isOnline()` 后再排程（已删，简化）

---

## 4 个决策已确认 + 最终改动清单（整合 9 HIGH + 9 MEDIUM 修复）

### 决策记录

| # | 问题 | 选择 | 影响 |
|---|------|------|------|
| 1 | HIGH-A 双实例化 | ✅ `is_doc_only = true` | FileManager 下不处理队列（用户开书才补推，可接受）|
| 2 | HIGH-C 队列隐私 | ✅ 仅文档警告（降级）| KOreader 不支持 backup 排除 key（grep 确认），降级为仅文档警告；互信模型下实质威胁小 |
| 3 | HIGH-I token 失效 | ✅ toast 提示 | 307/308 立即冻结所有 + 弹一次性 toast |
| 4 | M-8 跨设备冲突 | ✅ M6 不做，留 M7 | 仅 `logger.warn`，"后覆盖前"语义 |

### 最终改动清单（替代 v1 改动清单）

#### `main.lua` — 模块定义顶部
- 在 `WidgetContainer:extend{ name = "fns_sync", ... }` 表里加 `is_doc_only = true`（修 HIGH-A；查证确认位置：参考 KOSync `main.lua:24`、coverimage / perceptionexpander / autoturn 同写法）
- `_meta.lua` **不改**（只放 fullname + description，KOSync 的 `_meta.lua` 也只有这两项）

#### `config.lua`
- 新增 `Config.DEFAULTS.offline_queue_enabled = true`
- 新增常量 `Config.MAX_RETRY_ATTEMPTS = 5`
- 新增常量 `Config.TOKEN_INVALID_CODES = { [307] = true, [308] = true }`
- 注释警告 `fns_sync_queue` 含 PII（path + title），不随 settings backup 导出（修 HIGH-C）
- 不 bump `config_version`

#### `main.lua` — init 改造
- 加载 `self.queue = G_reader_settings:readSetting("fns_sync_queue", {}) or {}`
- 维护两个子表：`self._active_keys` / `self._frozen_keys`（修 M-3，避免每次事件全表扫描）
- 加 `self._queue_processing = false`（M6 队列锁，**与 M5 的 `_sync_in_flight` 解耦**，修 HIGH-B）
- 加 `self._last_network_event_ts = 0`（修 M-7 去抖）
- **删除**原设计的 `scheduleIn(10s)` 启动检查（事件已确认，由 `onNetworkConnected` 触发）
- 加 `onSuspend` flush 队列到磁盘（修 M-2）

#### `main.lua` — 离线分支改造
- `_autoSyncCurrentBook` 离线：从"静默跳过"改为调 `_enqueueCurrentBook`
- 日志文案改：`auto-sync skipped: offline (queued — will auto-retry when network reconnects)`

#### `main.lua` — 新增方法
- `_enqueueCurrentBook()`：按 path 去重，首次创建即同步写盘，后续只更新内存 ts（修 M-2 + M-4）
- `_loadBookFromPath(path) → annotations, meta, nil|err`：
  - path 失效返回 `nil, "file_missing"`（修 HIGH-F）
  - path 后缀校验 ∈ {.epub, .pdf, .cbz, ...}（修 M-6）
- `_processQueueItem(path, on_complete)`：**独立入口，不经 `_triggerSync`**（修 HIGH-B）
  - `_loadBookFromPath` 返回 `file_missing` → 立即移除条目 + 不计 attempts（修 HIGH-F）
  - biz_code 307/308 → 冻结所有条目 + 弹 toast（修 HIGH-I）
  - 失败其他 → attempts++；到 5 迁到 frozen
  - 调 `on_complete` 触发链式下一条
- `_processQueue()`：
  - 入口 `_queue_processing` 重入保护（修 HIGH-2）
  - 100ms 去抖（修 M-7）
  - 跳过 path == 当前打开书的条目（修 M-5，让实时路径处理）
  - **pcall 包裹整个流程，失败也释放锁**（修 HIGH-D）
  - 串行链式（修 HIGH-1）
- `onNetworkConnected()`：`scheduleIn(0.5, _processQueue)`（借鉴 KOSync）

#### `main.lua` — 兜底改造
- `onOpenDocument` / `onCloseDocument` / `onSyncCurrentBook` 调 `_processQueue()` 兜底
- `_cancelAutoSyncTimer` 在 `onCloseDocument` 入口仍调用（保留 M5 行为）

#### `main.lua` — UI
- "重试冻结条目"：reset 入口走 `_queue_processing` 保护（修 HIGH-G），重置后迁回 active
- "清空队列"：确认对话框 + 文案"将放弃 N 本书的待同步状态（高亮仍保留在 metadata.lua，但不会自动同步到 Obsidian）"

#### `main.lua` — 错误处理加固
- `_showSyncError`：对 `result.message` 截断 ≤200 字符 + 过滤 `Bearer`/`token`/`api_token` 子串（修 HIGH-H）
- `saveSettings` 调用后校验返回值，失败 `logger.error` + UI 提示（修 HIGH-E）

#### 不动
- `api.lua`（除非 307/308 处理时发现需要补充）
- `marker.lua` / `excerpt.lua`

### 实施前查证结果

- [x] `_meta.lua` 的 `is_doc_only` 字段位置 → 确认在 **`main.lua` 顶部的 `WidgetContainer:extend{...}` 表里**（不在 `_meta.lua`）
- [x] KOreader settings backup 是否支持排除 key → **不支持**，降级为"仅文档警告"

---

## M6 实施 + 代码审查修复（2026-08-05）

### 实施 commit
- `76b096d` feat(M6): 离线队列实施（main.lua +500 / config.lua +22）

### 实施 vs 设计的合理简化
- `_active_keys` / `_frozen_keys` 子表未实现 → 改为全表扫描（队列条目数实际 < 100，性能可接受；M-3 简化）
- `onSuspend` flush 未实现 → 信任 KOreader shutdown 时统一 flush（与 M5 一致）
- `saveSettings` 校验返回值降级 → `LuaSettings:saveSetting` 不返回状态（best-effort，HIGH-E 部分降级）

### 多角色代码审查（3 agent 并行，代码级）
- code-reviewer / silent-failure-hunter / security-reviewer
- 找出 HIGH 4 + MEDIUM 6 + 安全 2

### 修复 commit
- `ce07450` fix(M6): 多角色代码审查修复（main.lua +89 / -23）

| # | 问题 | 来源 | 修复 |
|---|------|------|------|
| H-1 | `onOpenDocument` 兜底漏改造 | silent | 加 `function FnsSync:onOpenDocument()` 调 `_processQueue` |
| H-2 | race 分支被误判为失败 → attempts++ | code-reviewer | race 视为成功移除条目，不计 attempts |
| H-3 | widget 销毁后 scheduleIn 闭包仍触发 | silent | stable closure `_queue_drain_action` + 替换 4 处匿名闭包 + `onCloseWidget` unschedule |
| H-4 | token 失效只 toast 一次，用户错过无再提示 | silent | 菜单 `text_func` 检查冻结条目数，显示 `[!]` 前缀 |
| M-1 | `if not doc_settings` 死分支 + readSetting 未保护 | silent | 删死分支，readSetting 包 pcall |
| M-3 | 菜单 `path:match("[^/]+$")` Windows 路径失败 | code-reviewer | 改 `[^/\\]+$` |
| S-1 | `_sanitizeServerMessage` 正则可绕过 | security | 6 patterns 大小写无关 + 关键词扩展（password/secret） |

### 接受不修（已记录）
- queue path 全量进日志（MEDIUM，可接受）
- 跨设备冲突无日志（M6 决策，M7 处理）
- saveSettings 无法校验返回值（LuaSettings 限制）
- os.time 秒级去抖精度（互斥锁保护兜底）

### 部署清单（实测前）
更新这 2 个文件到 Kindle：
- `plugin/fns_sync.koplugin/config.lua`
- `plugin/fns_sync.koplugin/main.lua`

其他文件（api.lua / marker.lua / excerpt.lua / _meta.lua）M6 未动。

### 实测场景（建议覆盖）
1. 离线划线 → 联网恢复 → 静默补推成功
2. 离线多书 → 联网 → 串行补推（按 ts 顺序）
3. 重启 KOreader → 队列保留 → 启动后自动补推
4. 模拟 token 失效（改个错的 token）→ toast + 菜单 `[!]` 前缀
5. 重试冻结条目 → 重置 attempts + 触发处理
6. 清空队列 → 确认对话框 → 队列清空
7. 关书后立即切到另一本书 → 不会重复同步
8. 同一本书离线连续划线 → 队列只占一条（去重）

---

## 下次工作的候选优先级

## M6 实测 + 终极 bug 修复（2026-08-05）

### 实测过程

部署后用户跑了 2 轮大场景测试：

**第 1 轮**：A/B/C/E 失败 → 4 个修复 commit（`639898f`）：
- H-1 跳过当前书条件改为 `path == current_path and _sync_in_flight`
- H-2 API 调用前判 isOnline
- H-3 区分 sidecar 损坏 vs 字段缺失
- 加调试日志覆盖事件触发 + _processQueue 决策

**第 2 轮**：发现尼罗河"diff +0 ~0 -0 但用户实际改了"：
- API + Python 模拟确认：服务器端笔记有旧 ts=11:57:27，客户端 metadata.lua 有新 ts=13:58:54
- Python 模拟 Marker.parse + diff 返回正确 2 actions（insert + delete）
- 但 Lua 运行时返回 0 actions
- 加 DEBUG parse/client/diff 日志重测，发现客户端读到 3 条（少了用户新加的 1 条）

### 终极根因

`_loadBookFromPath` 用 `DocSettings:open(book_path)` 创建**新实例**，新实例从 sidecar **文件**读 annotations。但：

- KOreader 的 `ReaderUI`（readerui.lua:131）持有自己的 `DocSettings` 实例（`self.doc_settings`）
- 用户每次划线时，`readerannotation.lua:251` 把最新数据 `saveSetting` 到**内存**
- 只在 `onCloseDocument` 时才 `flush` 到**文件**

所以只要书还开着，新实例读文件 = 读到旧状态，**错过用户最新操作**。M5 实时路径用 `self.ui.annotation.annotations`（直接访问运行时数组）没这个问题。

### 修复

`_loadBookFromPath` 入口加判断：当前书匹配时用 `self.ui.doc_settings`（运行时），否则才用 `DocSettings:open`（处理已关书的补推）。

**第 3 轮实测（最终）**：用户大场景反复测试，全部通过 ✅

### 关键 commit 链（M6 完整路径）

```
ccbae29 fix(M6): 队列路径读到旧 annotations — 用运行时 doc_settings  ← 终极修复
37f90ff debug(M6): 加 parse/diff 调试日志 — 诊断尼罗河 bug
01181de fix(M6): 多角色代码审查修复 — 3 HIGH + 1 MEDIUM + 2 LOW
542b08f chore(M6): 增强调试日志 — 覆盖事件触发 + _processQueue 决策
639898f fix(M6): 实测发现的 4 个 bug — A/B/C/E 失败根因修复
0d30747 docs: M6 实施完成 + 3 agent 代码审查修复整合
ce07450 fix(M6): 多角色代码审查修复 — 4 HIGH + 3 MEDIUM + 1 安全加固
76b096d feat(M6): 离线队列 — 入队 + onNetworkConnected + 串行补推 + 冻结/重试
4d6e4ad docs: M6 4 决策已拍板 + 最终改动清单 v2
d1b8d06 docs: M6 多角色独立审查 — 4 agent 抓出 9 HIGH + 9 MEDIUM
c1379c6 docs: M6 设计方案 + 自审完成
```

### 教训

**M5 测试通过 ≠ M5 实时路径覆盖所有边界**。M6 队列路径用 `_loadBookFromPath`（独立加载），与 M5 实时路径用 `self.ui.annotation` 的数据源不同，引入了缓存一致性问题。如果 M6 也复用 `self.ui.annotation` 就不会有这个 bug——但 M6 要支持"已关书的补推"，必须从文件读。

**多角色审查有效但不全能**。3 agent 找出 9 HIGH + 9 MEDIUM（设计 + 实现层），但**这个 bug 是数据源选择错误**——只有跑实际场景 + 看具体数据才能发现。

**DEBUG 日志挽救了诊断**。没有 parse/client/diff 三行 DEBUG，无法定位"Lua 运行时与 Python 模拟为何结果不同"。事后改为 logger.dbg，开 verbose 时仍可见。

**M6 里程碑：完成 ✅**

---

## 下次工作的候选优先级

| 编号 | 任务 | 启动条件 |
|------|------|---------|
| ~~🧪 M5 部署 + 6 场景实测~~ | ~~已完成~~ | ✅ |
| ~~M6 设计 + 自审 + 多角色审查 + 实施 + 实测~~ | ~~全部完成~~ | ✅ |
| 🐙 **接 GitHub** | M6 完成后可推 | 用户决定 |
| 📖 **写 README / 使用说明** | 推 GitHub 后让仓库可被发现 | 用户决定 |
| M7 | 跨设备冲突 / 双向同步 / onSyncAllHistory 实施 | 用户决定优先级 |

---

## 晚间追加：英文 README + PayPal 修复

### 背景

v1.0.0 发布后，用户提出两个改进：
1. 加英文版 README（中文为主 + 英文版切换）
2. 修 PayPal 捐赠按钮（之前用户在网页编辑过两次，第一次用 `<form>` 被 GitHub 过滤不渲染，第二次用 Markdown 图片但 URL 写错了）

### 调查

| 项 | 现状 |
|---|---|
| 远程 README 改动 | 用户在 GitHub 网页直接编辑了 2 个 commit（8c31eed 加 form, f37e818 改 markdown），本地落后 |
| README 中 PayPal 链接 | `[![PayPal 捐赠](https://paypalobjects.com)](...)` — `paypalobjects.com` 不是图片 URL，渲染为 broken image |
| .github/FUNDING.yml | 不存在，所以仓库 About 没显示 Sponsor 按钮 |

### 决策

| 问题 | 用户拍板 |
|---|---|
| 英文 README 方案 | 中文为主（README.md 保持中文）+ 新建 README.en.md + 顶部加语言切换链接 |
| PayPal 修法 | 修法 2（shields.io 徽章）+ 修法 3（.github/FUNDING.yml） |
| 徽章文字 | `Donate`（PayPal 国际惯例英文） |

### 改动清单

1. `git pull origin master --ff-only`：同步远程 2 个 commit（1 file +2 -1）
2. `README.md`：
   - 第 3 行插入语言切换：`[English](./README.en.md) | 中文`
   - PayPal 链接改为 shields.io 徽章：`[![Donate](https://img.shields.io/badge/PayPal-Donate-blue.svg?logo=paypal)](https://www.paypal.com/...)`
3. 新建 `README.en.md`：完整翻译中文 README 9 个章节，顶部 `English | [中文](./README.md)`
4. 新建 `.github/FUNDING.yml`：`custom: ["https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=WTV8HNRMMMGEC"]`
5. 更新本 progress 文档
6. `git add` + `commit` + `push`

### PayPal 渲染对比

**修复前（broken image）：**
```
[![PayPal 捐赠](https://paypalobjects.com)](https://www.paypal.com/...)
```
`https://paypalobjects.com` 无文件扩展名，GitHub Markdown 渲染为 broken image icon。

**修复后（蓝色徽章）：**
```
[![Donate](https://img.shields.io/badge/PayPal-Donate-blue.svg?logo=paypal)](https://www.paypal.com/...)
```
shields.io 实时生成 SVG 徽章，与 GitHub README 其他 badge 风格统一。

### FUNDING.yml 的副作用

加了这个文件后，仓库 About 区域会自动出现 **Sponsor** 按钮，点击展开看到 PayPal 链接。这是 GitHub 标准赞助入口，很多开源项目都用这个。

---

## 晚间追加：License 切换 MIT → PolyForm Noncommercial 1.0.0

### 用户诉求

"我希望我的项目不能被其他人用于商业，用于商业需要我授权。"

MIT 是反方向的（允许任何用途包括商业），必须换 license。

### 候选方案与决策

| 方案 | 评估 |
|---|---|
| PolyForm Noncommercial 1.0.0 | 专门为软件设计的非商业许可证，现成模板，条款清晰，**采纳** |
| PolyForm Small Business License | 折中方案，小公司免费大公司付费，未采纳 |
| CC BY-NC 4.0 | 为文章/图片设计，不适合软件，否决 |
| 自定义条款 | 法律风险高，否决 |

### 关键法律现实（已向用户说明）

1. **License 不能追溯**：v1.0.0 已用 MIT 发布，git tag `v1.0.0` 指向的 commit 里 LICENSE 是 MIT，这是历史事实改不了。
2. **0 下载意味着实质风险为零**：v1.0.0 发布才几小时，没有任何人下载使用过，所以即便有人理论上能拿 v1.0.0 当 MIT 商业依据，实际无影响。
3. **正确做法**：master 分支 LICENSE 切换为 PolyForm Noncommercial，v1.0.0 release 不动，下次有功能更新再发 v1.1.0 标记新 license。

### PolyForm Noncommercial 关键条款（通俗版）

| 用途 | 是否允许 |
|---|---|
| 个人读书划线自用 | ✅ 允许 |
| 学者研究 / 教学 | ✅ 允许 |
| 慈善 / 宗教 / 教育机构 | ✅ 允许 |
| 政府机构使用 | ✅ 允许 |
| 卖软件 / 商业分发 | ❌ 禁止（需授权） |
| 公司内部使用 | ❌ 禁止（需授权） |
| 商业 SaaS 服务用到它 | ❌ 禁止（需授权） |

### 改动清单

1. `LICENSE` 文件全文替换：MIT 22 行 → PolyForm Noncommercial 1.0.0 完整 13 个条款
2. `README.md`：加"商业授权"章节（GitHub Issue 联系）+ License 链接 `MIT` → `PolyForm Noncommercial 1.0.0`
3. `README.en.md`：加 "Commercial Licensing" 章节 + License 链接同步切换
4. `plugin/fns_sync.koplugin/README.md`：License 章节从"参考根目录"改为指向具体 PolyForm 协议 + 商业授权提示
5. 代码文件 `*.lua`：grep 检查无显式 license header，不需要改
6. 更新本 progress 文档
7. `git add` + `commit` + `push`，**不发新 release**（等下次功能更新再发 v1.1.0）

### 商业授权联系入口

用户拍板：用 GitHub Issue 联系（不开个人邮箱，避免骚扰）。

README 里链接 `https://github.com/xzymoon/KOreader-FNS-plugin/issues/new`，用户开 issue 时可选用 "Commercial licensing inquiry" 标题模板（暂未配置 issue templates，留作未来改进）。

### 不是法律建议

本文档作者不是律师，license 选择是基于常见开源实践。正式商业决策建议咨询律师。

---

## 晚间追加：v1.0.0 历史遗留决策 + 今日总结

### v1.0.0 是否要"消除 MIT 历史"

用户提出："v1.0.0 release / tag 不动 (里面 LICENSE 是 MIT, 这是历史) 那别人下载这个，会产生实质性影响吗？"

**法律层面（冷酷事实）**：

- MIT 协议条款原文是"任何获得副本的人"自动获得使用 / 修改 / 销售的权利
- 一旦发出，**法律上永久不可撤销**
- v1.0.0 release / git tag / 所有 MIT 时期的 commit，每一个都是 MIT 授权的快照
- 即便删除 v1.0.0 release / tag / 强制重写 git history，**已经 clone 走的副本无法回收**
- 所以"彻底消除"做不到

**实际层面（为什么不用焦虑）**：

- 项目当前 0 watch / 0 download / 0 star
- v1.0.0 发布才几小时
- 项目体量小（个人项目）
- 商业用的人通常基于最新版本而非旧版本

**三个候选**：

| 选项 | 含义 | 推荐 |
|---|---|---|
| A. 什么都不做 | v1.0.0 release 保留，git history 不动 | ⭐⭐⭐⭐ |
| B. 删除 v1.0.0 release + tag | 让直接下载入口消失（但 git history 还在 MIT） | ⭐⭐ |
| C. v1.0.0 release notes 加透明声明 | 法律诚实 + 沟通清晰 | ⭐⭐⭐ |

**用户拍板：选 A**

理由：法律事实无法改变，删除 v1.0.0 反而显得刻意隐藏，且实际风险为零。GitHub 仓库主页显示的 license 标签是 master 当前版本（= PolyForm Noncommercial），搜索者第一时间看到的依然是新 license。v1.0.0 release 单独点进去会显示 MIT，但这是历史诚实记录。

### 今日整体总结

| 阶段 | 任务 | 状态 |
|---|---|---|
| 下午 | M5 自动同步 6 场景实测（A/B/C/E 修复 + D/F 验证） | ✅ 完成 |
| 下午 | M6 离线队列设计（自审 + 多角色审查 + 整合） | ✅ 完成 |
| 下午 | M6 实施 + 4 个实测 bug 修复（A/B/C/E） | ✅ 完成 |
| 傍晚 | M6 终极 bug 修复（DocSettings 内存 vs 文件双数据源） | ✅ 完成 |
| 傍晚 | 写根目录 README + plugin README + LICENSE（MIT） + 赞助二维码 | ✅ 完成 |
| 傍晚 | GitHub 首次推送 + 发布 v1.0.0 release（首次填错 tag 名，已修） | ✅ 完成 |
| 晚间 | 加英文 README + 修复 PayPal 徽章（broken image → shields.io） + .github/FUNDING.yml（触发 Sponsor 按钮） | ✅ 完成 |
| 晚间 | License 切换 MIT → PolyForm Noncommercial 1.0.0（用户要求禁止商业） | ✅ 完成 |
| 晚间 | v1.0.0 历史遗留决策（用户拍板选 A：保留不动） | ✅ 完成 |

**今日 commit 总览**（按时间顺序，从早到晚）：

| Commit | 类型 | 内容 |
|---|---|---|
| `47a8fe4` | feat(M5) | 自动同步 — 高亮修改 debounce + 关书事件触发 |
| `b1aa474` | docs | 追加 M5 实测结果 — 5/6 通过 + 删除路径验证 |
| `c1379c6` | docs | M6 设计方案 + 自审完成 |
| `d1b8d06` | docs | M6 多角色独立审查 — 4 agent 抓出 9 HIGH + 9 MEDIUM |
| `4d6e4ad` | docs | M6 4 决策已拍板 + 最终改动清单 v2 |
| `76b096d` | feat(M6) | 离线队列 — 入队 + onNetworkConnected + 串行补推 + 冻结/重试 |
| `ce07450` | fix(M6) | 多角色代码审查修复 — 4 HIGH + 3 MEDIUM + 1 安全加固 |
| `0d30747` | docs | M6 实施完成 + 3 agent 代码审查修复整合 |
| `639898f` | fix(M6) | 实测发现的 4 个 bug — A/B/C/E 失败根因修复 |
| `542b08f` | chore(M6) | 增强调试日志 — 覆盖事件触发 + _processQueue 决策路径 |
| `01181de` | fix(M6) | 多角色代码审查修复 — 3 HIGH + 1 MEDIUM + 2 LOW |
| `37f90ff` | debug(M6) | 加 parse/diff 调试日志 — 诊断尼罗河"diff +0 ~0 -0"问题 |
| `ccbae29` | fix(M6) | 队列路径读到旧 annotations — 用运行时 doc_settings |
| `40bb414` | chore(M6) | 实测通过 — DEBUG 日志降级为 dbg |
| `8ad9722` | docs | 加项目根目录 README + 更新插件内 README 加 M5/M6 章节 |
| `f9f2df6` | docs | 加 MIT LICENSE + 赞助章节 (微信收款码) |
| `b02985f` | docs | README 配置说明调整 — 端口改 9000, Token 描述简化 |
| `8c31eed` | (网页) | Enhance sponsorship information in README（PayPal form）|
| `f37e818` | (网页) | Update README.md（PayPal markdown 简化，但 URL 写错）|
| `37c9992` | docs | 加英文 README + 修复 PayPal 徽章 + 加 FUNDING.yml |
| `ff08509` | license | 切换 MIT → PolyForm Noncommercial 1.0.0 |

共 21 个 commit（含 4 docs + 1 license + 多轮 fix + 多次自审 + 多角色审查 + 实测迭代）。

**关键经验（已记入 memory）**：

- M5/M6 验证了"设计草案 → 自审 → 多角色审查 → 实施 → DEBUG 日志 → 实测看 crash.log"的循环 [[feedback-multistage-review]]
- 多角色审查有效但不全能，**数据源类 bug 只有实测能发现**（M6 终极 bug：DocSettings 内存 vs 文件双数据源）
- DEBUG 日志挽救了诊断（parse/diff/client 三行 dbg）

**M6 里程碑：完成 ✅**
**v1.0.0 发布：完成 ✅**
**License 法律层面：完成 ✅（PolyForm Noncommercial）**

### 明日候选

| 编号 | 任务 | 启动条件 |
|------|------|---------|
| M7 | 跨设备冲突 + 双向同步 + onSyncAllHistory 实施 | 用户决定优先级 |
| 截图 | 给 README 加 KOreader 菜单截图 + Obsidian HL@ 块截图 | 15 分钟，提升项目观感 |
| 推广 | 写文章发 KOreader 社区 / Obsidian 论坛 / 小红书 | 用户决定是否做 |
| GitHub Issue Templates | 配置 "Commercial licensing inquiry" 等模板 | 可选改进 |

---

## 夜间追加：删除 + 重建 GitHub 仓库（清除 MIT 历史）

### 决策背景

用户进一步追问："那我是否可以删除库，然后重新发？"

前面 "License 切换" 章节已经说明：法律上 MIT 授权一旦发出**永久不可撤销**，删除仓库也改变不了"已发出 MIT"这个事实。但用户经过完整 trade-off 评估后，决定还是重建，目的是：

- **心理层面**：新仓库从第一天就是 PolyForm，没有 MIT 时期痕迹
- **git history 干净**：squash 成单个 commit，没有 MIT 时期的 LICENSE commit
- **外部索引干净**：搜索引擎 / Sourcegraph / GitHub 镜像从新仓库开始抓
- **0 star / 0 fork / 0 issue**：实质无损失

### 决策：方案 Y（Squash + 保留 progress）

| 维度 | 选择 |
|---|---|
| 重建策略 | Y (squash 21 commit → 1 commit) + 保留 progress 文档 |
| 新仓库第一个 release | v1.0.0 (从零开始，license 是 PolyForm) |

为什么不选 X (保留 21 commit history)：21 个 commit 里有 MIT LICENSE 那个 commit (`f9f2df6`)，git history 看到那个 commit 显得不"干净"。
为什么不选 Z (删除 progress)：progress 文档是宝贵的开发记录，删了可惜。

### 7 阶段执行流程

| 阶段 | 操作 | 执行者 |
|---|---|---|
| 1. 本地 squash | 创建 `backup-pre-squash` 分支保留原 21 commit；`git checkout --orphan new-master`；commit；替换 master；打 v1.0.0 tag | Claude |
| 2. 删除旧 GitHub 仓库 | Settings → Danger Zone → Delete repository | 用户 |
| 3. 重建同名仓库 | github.com/new，不勾选 README/.gitignore/LICENSE 避免冲突 | 用户 |
| 4. 推送新仓库 | `git push -u origin master` + `git push origin v1.0.0` | Claude |
| 5. 配置 About | description + topics (koreader/obsidian/plugin/sync/highlights/notes) + 勾选 Releases | 用户 |
| 6. 发布 v1.0.0 Release | tag v1.0.0 + 完整 release notes（功能介绍 + 安装 + License）| 用户 |
| 7. 更新 progress | 追加本节决策记录 + commit | Claude |

### 阶段 1 squash 具体步骤

```bash
git branch backup-pre-squash       # 安全网：保留原 21 commit
git checkout --orphan new-master   # 创建孤儿分支（无历史）
# orphan 自动 staged 所有文件
git commit -m "KOreader FNS Sync Plugin v1.0.0 — initial commit ..."
git branch -D master                # 删除旧 master
git branch -m new-master master     # 把 new-master 重命名为 master
git tag -d v1.0.0                   # 旧 tag 指向 MIT 时期 commit
git tag v1.0.0                      # 在新 squashed commit 上打同名 tag
```

squashed commit hash: `24fdba3`
backup branch hash: 保留原 `94350c3` HEAD（含 21 commit）

### squash 后的 commit message

```
KOreader FNS Sync Plugin v1.0.0 — initial commit

Features (M1-M6):
- 基础同步: 高亮 + 笔记 → Obsidian via FNS REST API
- HL@ marker 条目级 diff (Obsidian 端穿插编辑的内容会被保留)
- 模板定制: 摘录 / 笔记 / 文件名 / 颜色 emoji
- per-book title/author override (适合合集场景)
- 自动同步: debounce + 关书触发
- 离线队列: 持久化 + 联网自动补推 + 失败重试/冻结

License: PolyForm Noncommercial 1.0.0
商业使用需通过 GitHub Issue 联系

See progress/ for development history.
```

### 阶段 4 验证（远程 API 查询）

| 项 | 状态 |
|---|---|
| 远程 commit 数 | 1 个（`24fdba3`）✅ |
| default_branch | master ✅ |
| License | NOASSERTION（PolyForm 不在 SPDX 标准列表，GitHub 显示 "Other"，正常） |
| Release | 1 个 v1.0.0，draft=false ✅ |

### 法律现实再次确认（写给未来翻看此文档的自己）

**重建仓库 ≠ 撤销 MIT**：

- 旧仓库 v1.0.0 在 MIT 协议下公开过几小时，理论上 GitHub 公开仓库可能已被搜索引擎 / 镜像 / 爬虫抓取过副本
- 这些副本即使原仓库删除，它们手上的副本**法律上仍受 MIT 保护**
- **但实际风险几乎为零**：0 star / 0 watcher / 0 download，几乎没有备份服务真的抓这个小仓库

**重建的实际收益**（不是法律层面，而是项目展示层面）：

- 新仓库访客看到的第一个 commit 就是 PolyForm（不是 MIT）
- git history 没有 MIT LICENSE 那个 commit
- 搜索引擎从零开始索引 PolyForm 版本
- 心理上"干净开始"

### backup-pre-squash 分支的处理

本地保留 backup 分支作为安全网，**不推到 GitHub**（否则 squash 就没意义了）。如果未来确认新仓库稳定 + 不需要回溯，可以本地删除：

```bash
git branch -D backup-pre-squash   # 仅当完全确认不需要回滚时
```

短期保留（至少几天），确保新仓库运行正常后再清理。

### 今日最终 commit 总览

新仓库只有 1 个 commit（squashed initial commit `24fdba3`）+ 阶段 7 的 progress 追加 commit（待提交）。

旧仓库的 21 个 commit 历史保留在本地 `backup-pre-squash` 分支，**不推 GitHub**。

---

## 夜间追加：README 加 ASCII 菜单树状图

### 用户提议

"KOreader 的菜单能否直接做成 ASCII 的树状图，因为在 KOreader 里面截图，一个是比较麻烦，还有就是无法展现它的树状。"

### Trade-off 分析

| 维度 | 截图 | ASCII 树状图 |
|---|---|---|
| 展示树状层级 | ❌ 一次只能看一层 | ✅ 一目了然 |
| 跨语言（中英 README）| ❌ 需要截两套 | ✅ 一份代码两种语言都能渲染 |
| 维护成本 | ❌ 改菜单要重新截 | ✅ 改文本即可 |
| diff 友好 | ❌ 二进制无法 diff | ✅ 文本 diff 清晰 |
| 加载速度 | ❌ 图片体积 | ✅ 几 KB 文本 |
| 真实感 | ✅ 直观 | ❌ 抽象 |

**结论**：菜单结构展示用 ASCII 树状图**比截图更合适**。截图留给"HL@ 块在 Obsidian 里的实际渲染效果"这种需要真实感的场景。

### 决策

- 风格 1（树状，类 Linux `tree` 命令）—— 紧凑、开发者熟悉、跟 GitHub README 整体风格搭
- 方案 A（中英两份独立图，菜单文字本地化）

### 翻译决策

| 中文 | 英文 |
|---|---|
| 立即同步当前书 | Sync Current Book Now |
| 立即同步全部历史 | Sync All History |
| 当前书信息 | Current Book Info |
| 章节二级标题 | Chapter Subtitle |
| 防抖延迟 | Debounce Delay |

### 改动清单

1. **README.md**：在"## 配置"前加新章节"## 菜单结构"，包含中文 ASCII 树状图
2. **README.en.md**：在"## Configuration"前加新章节"## Menu Structure"，包含英文 ASCII 树状图
3. 更新本 progress 文档
4. `git add` + `commit` + `push`

### 图的结构覆盖

- 顶层 1 项（FNS 同步入口）
- 第一级 8 项（启用 / 自动同步 / 离线队列 / 立即同步当前书 / 立即同步全部历史 / 测试连接 / 当前书信息 / 设置）
- 4 层嵌套（FNS 同步 → 设置 → 服务连接 → FNS 服务 URL）
- toggle 项用 `[✓]` / `[ ]` 表示开/关
- 子菜单用 `├─` / `└─` 树状字符
- 分组用 `─────` 分隔线（KOreader 菜单里 `separator = true` 的视觉）

### 后续可选改进

- 给 README 加 Obsidian HL@ 块的截图（这个 ASCII 不合适，需要真实渲染效果）
- 给 plugin/fns_sync.koplugin/README.md 也加同样的菜单图（详细文档目前没图）


