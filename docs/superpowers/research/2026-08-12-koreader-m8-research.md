# KOReader M8 实施前的机制调研报告

> **调研日期**：2026-08-12
> **调研目的**：M8（AI 对话功能）首次实施失败回滚后，复盘并查清 4 个关键机制的真相，避免再次踩坑。
> **调研方法**：3 个并行 general-purpose agent 通读 KOReader 源码（`E:\koreader-src`）+ qrclipboard 等参考插件 + 本项目 `E:\KOreader-FNS-plugin` 现有代码，整理结论。
> **使用方式**：本报告作为 `docs/superpowers/specs/2026-08-11-ai-chat-design.md` 的**实施前置输入**——动手写 M8 代码前必读，进入 `writing-plans` 阶段时直接引用本报告的"实施路线图"章节。

---

## 执行摘要（30 秒看完）

| # | 主题 | 一句话结论 |
|---|------|----------|
| 1 | 高亮菜单加按钮 | 用 `self.ui.highlight:addToHighlightDialog(idx, fn_button)` 注册，**不要** override `onShowHighlightMenu` |
| 2 | HTTP 客户端 | 完全沿用 FNS api.lua 现有同步模式（luasocket + rapidjson + `UIManager:nextTick`），**不要** 引入 Trapper/Spore/httpclient |
| 3 | 对话框组件 | InputDialog + TextViewer 链式调用是 KOReader 标准模式（close A → show B 同步即可），跨 nextTick 调 API 时注意闭包 capture |
| 4 | 配置加载 | **取消独立 `ai_config.lua`**，把 AI 配置全部塞进 `G_reader_settings["fns_sync"]`，复用现有 `Config.DEFAULTS` + `_editString` + `config_version` 迁移机制 |

**对 M8 设计文档（`2026-08-11-ai-chat-design.md`）的影响**：原设计的 3 处假设被推翻——`onShowHighlightMenu` 事件、独立 `ai_config.lua` 文件、`require` 加载配置。详见 §5。

---

## 1. KOReader 高亮菜单扩展机制调研

### 1.1 菜单是怎么弹出来的

KOReader 把"长按选中文字后弹出的菜单"叫做 **highlight dialog**，渲染入口是 `ReaderHighlight:onShowHighlightMenu(index)`，见 `E:\koreader-src\frontend\apps\reader\modules\readerhighlight.lua:1492-1525`。流程：

1. 校验 `self.selected_text` 存在（1493-1495）
2. 遍历 `self._highlight_buttons`（这个表是核心注册点）——用 `ffiUtil.orderedPairs` 按键名字典序排序，逐个调用注册的工厂函数 `fn_button(self, index)` 拿到按钮定义（1500-1509）
3. 每个按钮可带可选的 `show_in_highlight_dialog_func`，用于条件显示（如"Follow Link"只在选中链接时出现，1502 行）
4. 按钮按每行 2 列（`columns = 2`，1499）排版进 `highlight_buttons`
5. 用 `ButtonDialog:new{ buttons = ... }` 构造对话框，`UIManager:show(self.highlight_dialog)` 显示（1511-1524）

`self._highlight_buttons` 这个表在 `init()` 里硬编码了 7 个内建按钮（键名 `01_select` … `12_search`），见 `readerhighlight.lua:107-207`；并在 init 末尾用 `self:addToHighlightDialog(...)` 追加了 4 个条件按钮（`08_share_text`/`09_view_html`/`10_user_dict`/`11_follow_link`），见 `readerhighlight.lua:212-265`。第三方插件就是追加到同一张表里。

### 1.2 第三方插件加按钮的正确钩子：`addToHighlightDialog()`

钩子定义在 `readerhighlight.lua:1480-1484`：

```lua
function ReaderHighlight:addToHighlightDialog(idx, fn_button)
    -- fn_button is a function that takes the ReaderHighlight instance
    -- as argument, and returns a table describing the button to be added.
    self._highlight_buttons[idx] = fn_button
end
```

**精确签名**：`addToHighlightDialog(idx, fn_button)`

- `idx`：字符串 key，决定排序位置（按字典序）和去重 id。约定用 `"数字_名字"` 形式，如 `"12_generate_qr_code"`、`"12_0_make_handmade_toc_item"`
- `fn_button`：一个**工厂闭包**，签名 `function(this)`，其中 `this` 就是 `ReaderHighlight` 实例（即 `self.ui.highlight`）。返回一张 button table（结构同 `ButtonDialog` 的按钮：`text`/`callback`/可选 `enabled`/`show_in_highlight_dialog_func`/`text_func` 等）

**调用时机**：每次 `onShowHighlightMenu(index)` 被触发时实时遍历（1500-1509），不是注册时就执行。所以 `show_in_highlight_dialog_func` 在菜单弹出瞬间判断条件。

**self 上下文**：注意区分两个 self。注册时调用方是插件实例（如 `QRClipboard`），`self.ui.highlight:addToHighlightDialog(...)` 把闭包交给 ReaderHighlight 保存。运行时 fn_button 被调用时，传入的 `this` 是 **ReaderHighlight 实例**（不是插件自己），插件在闭包里通过 `this.selected_text`、`this:clear()`、`this.ui.rolling` 等拿到选区数据和操作能力。

### 1.3 入口 A vs 入口 B

KOReader 里其实有**两个不同的高亮对话框**，但 `addToHighlightDialog` 注册的按钮**两条路径都会触发**（前提是都走到 `onShowHighlightMenu`）：

- **入口 A（正文选一段新文字）**：`onHold` → `onHoldRelease`（`readerhighlight.lua:2079`，default action = "ask"）→ 直接调 `self:onShowHighlightMenu()`（无 index 参数）。此时 `self.selected_text` 来自当前手势选区，`index` 为 nil
- **入口 B（长按已有高亮）**：`onTap` 命中已存在的高亮 box（`readerhighlight.lua:1011-1013`）→ `showChooseHighlightDialog`（1260）→ `showHighlightNoteOrDialog`（1287）：
  - 如果该高亮**没有笔记**：直接 `self:showHighlightDialog(index)`（1361）——这是**另一个对话框**（"编辑高亮"菜单：删除/Style/Color/Note/Details/…/边界箭头，见 1376-1468），**不走 `addToHighlightDialog` 注册的按钮**
  - 如果有**笔记**：先弹 TextViewer，用户点"Highlight menu"按钮（1350-1355）→ `self:showHighlightDialog(index)`
  - 用户在 `showHighlightDialog` 里点"…"按钮（1414-1421）→ 设置 `self.selected_text = util.tableDeepCopy(item)`，然后调 `self:onShowHighlightMenu(index)`——**这才进入和入口 A 同一个菜单**，并带上 `index`

**关键结论**：入口 B 多了一层"编辑高亮"对话框（`showHighlightDialog`，1365-1478）作为前置，必须点"…"才会进 `onShowHighlightMenu`。`addToHighlightDialog` 注册的按钮**只在 `onShowHighlightMenu` 弹出时出现**。如果想让按钮直接出现在入口 B 的第一层菜单，需要别的机制——但 FNS Sync 的"问 AI"按钮放在 `onShowHighlightMenu` 这一层是合理且符合用户习惯的（和 qrclipboard/readerhandmade 一致）。

`fn_button` 的第二个参数 `index` 可用于判断路径：入口 A 时为 nil，入口 B 时为高亮的 annotation index（`readerhighlight.lua:1501` `local button = fn_button(self, index)`；qrclipboard 闭包没用 index 参数，两个入口都能跑）。

### 1.4 参考实现：qrclipboard.koplugin

完整注册流程（`E:\koreader-src\plugins\qrclipboard.koplugin\main.lua`）：

1. 插件继承 `WidgetContainer`，`name = "qrclipboard"`（`main.lua:14-16`）
2. `init()` 里检查 `if self.document then` 确保只在阅读器（非文件管理器）里注册，调用 `self:addToHighlightDialog()`（`main.lua:18-21`）
3. 包装方法 `QRClipboard:addToHighlightDialog()` 调用宿主钩子：`self.ui.highlight:addToHighlightDialog("12_generate_qr_code", function(this) ... end)`（`main.lua:27-63`，关键行 30）
4. `idx` 选 `"12_generate_qr_code"` 是为了让按钮排在 `12_search` 之前、做次末按钮（注释见 `main.lua:28-29`）
5. 闭包内通过 `this:highlightFromHoldPos()` 拿到 `this.selected_text`（`main.lua:35-36`），构造文本后 `UIManager:show(QRMessage:new{...})` 显示，最后 `this:onClose(true)` + 延迟 `this:clear()` 清理（`main.lua:47-59`）
6. `_meta.lua`（`E:\koreader-src\plugins\qrclipboard.koplugin\_meta.lua`）只声明 `fullname` + `description`，没有钩子相关逻辑

旁证 `readerhandmade.lua:378-396` 也用同一接口 `self.ui.highlight:addToHighlightDialog("12_0_make_handmade_toc_item", function(this) ...)`，且展示了 `text_func` 动态按钮文本、按 `this.ui.rolling`/`this.ui.paging` 分支处理——可直接参考。

### 1.5 我们项目之前的错误用法

之前在 main.lua 写 `function ReaderHighlight:onShowHighlightMenu(...)` 想拦截事件——错在：

1. **KOReader 不广播 `ShowHighlightMenu` 事件**。`onShowHighlightMenu` 是 `ReaderHighlight` 自己的**普通方法**（不是事件回调），由 `onHoldRelease`（2079 行）和 `showHighlightDialog` 的"…"按钮（1418 行）**直接以方法调用**形式 `self:onShowHighlightMenu(...)` 触发。它走的是 Lua 方法调用，**不经过 `WidgetContainer:handleEvent` 事件分发链**
2. 即便它走事件链，在 FNS Sync 插件里定义 `function ReaderHighlight:onShowHighlightMenu(...)` 也只是给 FNS Sync 自己的表加方法，**不会修改 ReaderHighlight 模块**（Lua 不重定义已加载模块）。所以宿主调用 `self:onShowHighlightMenu` 时永远命中 ReaderHighlight 自己的版本，插件函数根本不会被触发
3. 退一步，即使事件广播存在，`InputContainer:handleEvent` 默认按注册顺序逐个 widget 询问，但插件 `WidgetContainer` 没声明 `event_handlers`，也不会自动响应

正确做法是用**注册接口** `self.ui.highlight:addToHighlightDialog(...)`（见 1.2），让 ReaderHighlight 自己在 `onShowHighlightMenu` 里调你的闭包——和 qrclipboard 完全一致。

### 1.6 M8 推荐实现路线

基于以上调研，FNS Sync 的"问 AI"按钮应按 qrclipboard 模板做（**伪代码，非真实 Lua**）：

1. 在 `main.lua` 的 `ReaderUI` 子模块/`init()` 里：判断 `if self.document then`（仅在阅读器里注册），拿到 `self.ui.highlight`（即 ReaderHighlight 实例）
2. 调用 `self.ui.highlight:addToHighlightDialog(KEY_STR, fn_button)`：
   - `KEY_STR` 选 `"12_fns_ask_ai"`（字典序让按钮排在 `12_search` 附近，位置可微调；想靠前可用 `"07_5_..."`）
   - `fn_button = function(this)` 返回 button table：
     - `text = _("Ask AI")`
     - 可选 `enabled_func` 或 `show_in_highlight_dialog_func`（如检查 API token 配置就绪、selected_text 非空）
     - `callback = function()` 里：通过 `this.selected_text.text` 取选区文本；先 `this:onClose(true)` 关菜单（保留 highlight）；调用 FNS Sync 的 AI 模块发请求；用 `UIManager:show(...)` 显示结果；最后延迟 `this:clear()`（参考 qrclipboard `main.lua:54-56`）
3. **不要** override `onShowHighlightMenu`，**不要** 用事件，**不要** 碰 `_meta.lua`（它只放 fullname/description）
4. 入口 A 和入口 B 都会自动出现这个按钮（B 路径需用户先点"…"）

**不确定项**：入口 B 第一层菜单（`showHighlightDialog`，1365-1478）目前没有发现可扩展的注册接口，全是硬编码 buttons。若产品要求"长按已有高亮第一层就看到问 AI"，需要再调研是否要 patch 这个函数或找其它 hook；本次调研没找到现成钩子。

---

## 2. KOReader HTTP 客户端调研

### 2.1 KOReader 用的 HTTP 库

**luasocket + LuaSec**（不是 lua-http / lua-requests）。所有 HTTP 调用统一走这两个底层库，KOReader 没有自封装高层客户端（kosync 用的 Spore 框架只是个老 RFC-ful 的封装，底层仍然是 luasocket）。

- HTTP：`require("socket.http")`（`E:\koreader-src\frontend\socketutil.lua:7`）
- HTTPS：`require("ssl.https")`（`E:\koreader-src\frontend\socketutil.lua:8`）
- 流式 sink/source：`require("ltn12")`（`E:\koreader-src\frontend\socketutil.lua:9`）
- 工具层封装：`require("socketutil")`（KOReader 自带，所有超时/错误码常量都在这里）

`luarocks` 依赖在 `Makefile` / `platform/debian/control` 一类位置，插件层不直接管，KOReader 启动时已把这些库塞进 `package.path`。

### 2.2 插件发 HTTP 请求的标准模式

KOReader 是**单线程 Lua + 主循环（UIManager）**。`socket.http.request` 是**纯同步阻塞**调用，会卡住 UI 直到返回。社区里"显示 loading → 后台跑 → 回调"的标准模式是 `Trapper:wrap` + `Trapper:info`，本质是 **coroutine + UIManager 调度**，不是真异步（参见 `E:\koreader-src\frontend\ui\trapper.lua:42-61`，注释里明说"Mostly done with coroutines, but hides their usage"）。

但实际上，绝大多数 KOReader 插件（wallabag、opds、newsdownloader、exporter、我们 FNS Sync）**根本不用 Trapper**，而是用更简单的两段式：

1. `UIManager:show(InfoMessage{ text="...", timeout=1 })` 先把"正在…"刷到屏幕
2. `UIManager:nextTick(function() ... 阻塞调用 ... end)`，让 UIManager 先把 loading 渲染出来一帧，下一帧再执行阻塞 HTTP 调用

我们 FNS Sync 就是这个套路，`E:\KOreader-FNS-plugin\plugin\fns_sync.koplugin\main.lua:552-586`：

```lua
UIManager:show(InfoMessage{ text = _("正在同步…"), timeout = 1 })
UIManager:nextTick(function()
   local ok, err = pcall(function() self:_doSyncCurrentBook(...) end)
   ...
end)
```

注意：**在 nextTick 的回调里仍然是阻塞调用**，UI 在请求期间不刷新——但因为已经先渲染过一帧"正在同步…"，用户知道在等。Wikipedia/Translator 等用到 `Trapper:info` 是因为它能持续刷新进度文字、并支持用户中断（`Trapper:dismissable` 系列）。

还有一个**真异步**通道：kosync 用的 `httpclient` + Turbo looper（`E:\koreader-src\plugins\kosync.koplugin\KOSyncClient.lua:38-62`），仅当 `UIManager.looper` 存在时启用（一般是带 Turbo 编译的设备才走这条路）。**不建议 M8 用**，依赖条件复杂，文档少。

### 2.3 Timeout 和错误处理

KOReader 的 timeout 实现在 `E:\koreader-src\frontend\socketutil.lua:52-70`，分两个维度：

- `block_timeout`：单次 socket 读/写等待（默认 5s）
- `total_timeout`：整个响应累计上限（自定义 sink 用 `os.time()` 计时强制执行，`socketutil.lua:97-115`）

推荐调用序列（来自 `socketutil.lua:29-33`、`wallabag/main.lua:906-919`）：

```lua
socketutil:set_timeout(block, total)   -- 设置
local code, headers, status = socket.skip(1, http.request(req))
socketutil:reset_timeout()             -- 务必复位
```

预置常量：`LARGE_BLOCK_TIMEOUT=10 / LARGE_TOTAL_TIMEOUT=30`，`FILE_BLOCK_TIMEOUT=15 / FILE_TOTAL_TIMEOUT=60`（`socketutil.lua:29-33`）。

错误处理要分三类（`socketutil.lua:91-93`、`wikipedia.lua:204-219`、我们 `api.lua:118-122`）：

1. **网络层**（DNS、连接拒绝、TCP 超时）：`http.request` 返回 `nil, err_string`。`socket.skip(1, ...)` 之后 `code` 会变成 string 而非 number——必须用 `type(code) == "string"` 判断，否则会把 `"timeout"` 当成 HTTP code（FNS api.lua:118 就是踩过这个坑补的补丁）
2. **socket 级 timeout**：`code == "timeout"` / `"closed"` / `"wantread"`（SSL）
3. **sink 级 total_timeout**：`code == "sink timeout"`
4. **HTTP 层**：`code` 是 200/4xx/5xx 数字，正常判断

### 2.4 JSON 库

**`rapidjson`**（不是 dkjson/cjson）。`cjson` 全代码库零引用；`dkjson` 只在 exporter/calibre/japanese 这几个老插件里有（`E:\koreader-src\plugins\exporter.koplugin\base.lua` 等）。新代码全用 rapidjson：

- 编码：`rapidjson.encode(table) -> string`（`E:\KOreader-FNS-plugin\plugin\fns_sync.koplugin\api.lua:87`）
- 解码：`rapidjson.decode(string) -> table`（`api.lua:159`）
- **已知坑**（我们项目踩过，`api.lua:92-99`）：rapidjson 把整数编码成 `1785730809000.0`（带 `.0`），Go/DeepSeek 服务的强类型 int64 字段会拒收。FNS 的解决方法是对 JSON 字符串做 `gsub("(%d)%.0([,}])", "%1%2")`。**M8 调 DeepSeek 时要确认 `messages` 里的 `timestamp`/数字字段会不会被影响**——OpenAI 规范里基本只有 string 和 number，`max_tokens`/`temperature`/`top_p` 都是 number，理论上不受影响，但要在 brainstorming 里验证一下

### 2.5 我们项目现有的 HTTP 调用模式

**纯同步 luasocket + rapidjson + socketutil**（不用 Spore、不用 Trapper、不用 httpclient/Turbo）。集中在 `plugin/fns_sync.koplugin/api.lua`，骨架（`api.lua:72-123`）：

1. `buildUrl()` 拼 URL + query
2. 构造 `request = { url, method, sink = ltn12.sink.table(sink), headers = { Authorization = "Bearer " .. token, ... } }`
3. body 用 `rapidjson.encode` + `gsub` 去 `.0` + `ltn12.source.string(body_json)` + 设置 `Content-Length` / `Content-Type`
4. `socketutil:set_timeout(LARGE_BLOCK_TIMEOUT, LARGE_TOTAL_TIMEOUT)` → `socket.skip(1, http.request(request))` → `reset_timeout`
5. 用 `type(code) == "string"` 区分网络错误 vs HTTP code
6. 高层 `makeRequest`（`api.lua:135-182`）统一返回 `{ ok, network_error, http_code, biz_code, message, data }` 结构

调用方不直接 `require("socket.http")`，全部通过 `Api:makeRequest` 或 `Api:xxxNote`。**UI 层调用 HTTP 的入口固定在 main.lua 的 `_triggerSync`，用 `UIManager:nextTick + pcall + InfoMessage(timeout=1)` 包装**（`main.lua:552-586`）。这是 M8 应该完全照搬的模式。

### 2.6 参考插件：kosync.koplugin 的关键代码

kosync 给我们两点参考。一点是**它走了另一条路（Spore + httpclient 异步）**——这条路我们不用走。另一点是它的 **timeout 分级策略**很值得借鉴（`KOSyncClient.lua:6-8`）：

```lua
local PROGRESS_TIMEOUTS = { 2,  5 }   -- 上传进度：2s block / 5s total（很快）
local AUTH_TIMEOUTS     = { 5, 10 }   -- 登录认证：5s block / 10s total
```

即"业务场景 → timeout 等级"映射。M8 调 DeepSeek 应该单独定义一套 `{ 10, 60 }` 之类的"AI 调用专用 timeout"。

### 2.7 M8 调 DeepSeek API 的推荐实现路线

**结论：完全沿用 FNS api.lua 的同步模式 + main.lua 的 nextTick 包装，不要引入 Trapper/httpclient/Spore。**

伪代码骨架（**步骤说明，非真实代码**）：

1. **新建 `ai.lua` 模块**，结构对齐 `api.lua`：
   - `require("socket.http")` / `ltn12` / `rapidjson` / `socketutil` / `logger`
   - 定义 `AI_TIMEOUTS = { 10, 60 }`（block 10s、total 60s，给 DeepSeek 30s 思考留余量）
   - 提供 `Ai:chat(settings, messages, callback)` 一类高层方法，内部 `set_timeout → socket.skip(1, http.request) → reset_timeout`，URL 用 `settings.ai_base_url .. "/chat/completions"`，headers 带 `Authorization: Bearer <api_key>` + `Content-Type: application/json`，body 是 `{ model, messages, max_tokens, temperature, stream=false }`

2. **JSON 处理**：`rapidjson.encode` 编请求体；`rapidjson.decode(resp_body)` 解响应。rapidjson 的 `.0` 坑对 DeepSeek 影响有限（OpenAI 规范里数字字段大多被严格类型化为 number，不会因 `18000.0` 拒收），但**保险起见在 brainstorming 里加一条验证项**：发请求前 dump 一下 body 字符串，确认 `max_tokens`/`temperature` 编码形态

3. **UI 调用入口**（在 main.lua 或新建 `ai_dialog.lua` 里）：
   - 用户点"AI 对话"按钮 → `UIManager:show(InfoMessage{ text = _("正在思考…"), timeout = 1 })`
   - `UIManager:nextTick(function() ... pcall(Ai:chat) ... end)`
   - 成功：把 `choices[1].message.content` 塞进 TextViewer 弹出
   - 失败：根据 `r.network_error` / `r.http_code`（429 限流常见）/ JSON 解析失败，分别给用户可读提示

4. **30s timeout 怎么处理**：
   - 用 `socketutil:set_timeout(10, 60)` —— block 10s（建连慢就快速失败）、total 60s（覆盖 DeepSeek 30s 推理 + 网络）
   - timeout 触发时 `code == "timeout"` 或 `"sink timeout"`，统一走 `network_error = true` 分支，提示"AI 响应超时，请重试"，**不要自动重试**（DeepSeek 计费）

5. **不要做的事**：
   - 不要用 `Trapper:wrap`（FNS 全项目没用过，引入会破坏一致性）
   - 不要用 Spore / httpclient / Turbo looper（依赖条件复杂，且 FNS 没用过）
   - 不要尝试 streaming（`stream: true`）——luasocket 同步模式下处理 SSE 麻烦，M8 一次性返回即可
   - 不要在主循环里直接 `http.request`（必须 `nextTick` 或 `scheduleIn` 包装，否则连 loading 文字都画不出来）

**不确定点**：rapidjson 编码 OpenAI 请求体是否触发 `.0` 坑——需要在 brainstorming 阶段用真实 payload 验证一次（构造 `{max_tokens=2048, temperature=0.7}`，dump 出来看是 `2048` 还是 `2048.0`，DeepSeek 是否拒收）。如果踩坑，可以复用 FNS 的 `gsub` 修复，或者用 `rapidjson.encode` 之前把整数 `math.tointeger` 一下。

---

## 3. InputDialog / TextViewer 调研

### 3.1 InputDialog API

源码：`E:\koreader-src\frontend\ui\widget\inputdialog.lua`

**类定义**：`InputDialog:extend{...}`（`inputdialog.lua:123`），是一个 FocusManager 子类。

**核心构造参数**（`inputdialog.lua:123-201`）：

- `title`（标题）、`input`（默认值）、`input_hint`（占位符）、`description`（标题下方说明文字）
- `buttons`：二维表（行→列），每行一组按钮，每个按钮是 `{text=..., callback=..., id=..., is_enter_default=...}`（典型用法见 `inputdialog.lua:21-42`）
- `save_callback` / `reset_callback`：传入这两个任一个，KOReader 自动追加 `|Reset|Save|Close|` 三按钮（`inputdialog.lua:803-929`），其中 Close 按钮点击未保存改动会弹 MultiConfirmBox 二次确认
- `close_callback`：对话框关闭后回调（`inputdialog.lua:161`），传 `true/false/nil` 分别表示"已保存"/"已丢弃改动"/"未改动关闭"
- `fullscreen=true` + `condensed=true` + `allow_newline=true` + `add_nav_bar=true`：多行编辑模式（inputdialog.lua:46-54）
- `text_type="password"`：密码框
- `input_type="number"`：数字输入，`getInputValue()` 自动 tonumber

**获取输入**：`inputdialog:getInputText()`（inputdialog.lua:581）/ `getInputValue()`（:585）。

**显示与键盘**：

```lua
UIManager:show(input_dialog)
input_dialog:onShowKeyboard()
```

（`inputdialog.lua:43-44`）

**项目内现有用法**：`E:\KOreader-FNS-plugin\plugin\fns_sync.koplugin\main.lua:250-267` 的 `_editString` 函数用了 `save_callback` 模式（这是 KOReader 推荐的简化写法，自带 Reset/Save/Close 三按钮）。

### 3.2 TextViewer API

源码：`E:\koreader-src\frontend\ui\widget\textviewer.lua`

**类定义**：`TextViewer = InputContainer:extend{...}`（`textviewer.lua:40`）。

**核心构造参数**（`textviewer.lua:40-96`）：

- `title`、`text`（要显示的多行文本，由 ScrollTextWidget/ScrollHtmlWidget 渲染）
- `buttons_table`：二维表，结构同 InputDialog.buttons；不传则只显示默认按钮（Find/⇱/⇲/Close，见 `textviewer.lua:343-390`）
- `add_default_buttons=true`：保留默认按钮并把用户的 buttons_table 追加在前（`textviewer.lua:391-397`）—— **M8 必须设这个为 true**，否则丢失 Close 按钮
- `text_type`：预设的字体/字号组合，可选 `"general" / "file_content" / "book_info" / "bookmark" / "lookup" / "code"`（`textviewer.lua:81-89`）；M8 显示对话历史建议 `"general"`
- `close_callback`：关闭后回调（`textviewer.lua:549`）
- `text_selection_callback`：用户长按选择文字时回调（`textviewer.lua:792`）
- `file = <path>`：会触发 Pin 按钮显示（与 M8 无关）
- `title_multilines=true`：标题超长自动换行

**显示**：`UIManager:show(textviewer)`（无需 onShowKeyboard）。

**运行时改文本**：`textviewer:reinit()`（textviewer.lua:805）—— 会重新读取 `self.text` 并重画；M8 链式对话框累积上下文时可用。

### 3.3 链式对话框实现

**核心模式**：KOReader 的 `UIManager:close(A)` 之后立刻 `UIManager:show(B)` 是**同步**的，A 的 onCloseWidget 先执行清理，B 紧接着 init + onShow。无需 nextTick。例子：

- `E:\koreader-src\plugins\newsdownloader.koplugin\main.lua:1094-1095`：InputDialog 里点 Cancel → `UIManager:close(input_dialog)` → `UIManager:show(kv)`（KV 页面）
- `E:\koreader-src\frontend\apps\filemanager\filemanagershortcuts.lua:425-426`：ButtonDialog 点 Folder → close 自身 → show PathChooser
- `E:\koreader-src\frontend\ui\viewhtml.lua:135-136`：TextViewer 关闭后 show 另一个 TextViewer（这正是 M8" TextViewer → TextViewer"模式）

**关闭后回调机制**：InputDialog / TextViewer 都支持 `close_callback`（inputdialog.lua:161 / textviewer.lua:549），由 onClose 触发。当需要"A 关闭 → 异步做事 → 弹 B"时（比如 A 关后调 API、API 返回后弹 B），用：

- `UIManager:nextTick(fn)`（inputdialog.lua:59-62 示例）
- `UIManager:scheduleIn(seconds, fn)`（项目 main.lua:1255 已大量使用）

**链式方向**（M8 的两种链）：

- **A→B 同步**（如点"翻译"模板按钮直接打开 TextViewer）：close A + show B 写在同一个 callback
- **A→B 异步**（如点"发送"→调 API→API 回来后 show TextViewer）：close A + scheduleIn/nextTick + 在异步回调里 show B；API 调用期间可 show 一个临时 InfoMessage（项目 main.lua:387-397 已用此模式）

### 3.4 快捷模板按钮（翻译/解释/评论）的实现方式

两种可选方案：

**方案 A：buttons 第一行就是模板按钮**（推荐）

InputDialog 的 buttons 是二维表，第一行可放 `[翻译][解释][评论]` 三个按钮，第二行放 `[取消][发送]`。每个模板按钮的 callback 做：

1. `self._input_widget:setText(template_prompt)`（用 InputDialog:setInputText，inputdialog.lua:594）
2. 不关闭对话框，让用户在模板基础上继续输入

**方案 B：通过 `addWidget` 插入额外控件**

InputDialog 提供 `:addWidget(widget, re_init, skip_focus_layout)`（inputdialog.lua:525-551），可插入 CheckButton 等。TextViewer 自身的 findDialog 就用此机制插入了 "Case sensitive" 复选框（textviewer.lua:703-712）。如果模板按钮需要带"启用/禁用"勾选框，这条路更合适。M8 的纯按钮场景用方案 A 即可。

**buttons 结构示例（伪代码）**：

```lua
buttons = {
  -- 第一行：模板按钮
  {
    { text = "翻译", callback = function() dialog:setInputText("请翻译：\n" .. selected_text) end },
    { text = "解释", callback = function() ... end },
    { text = "评论", callback = function() ... end },
  },
  -- 第二行：主操作按钮
  {
    { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
    { text = "发送", is_enter_default = true, callback = function() ... end },
  },
}
```

### 3.5 参考实现（KOReader 内部或 plugins 的例子）

1. **TextViewer.findDialog**（`textviewer.lua:670-716`）：在 TextViewer 内部点 Find 弹 InputDialog，InputDialog 关闭后回到 TextViewer 继续 findCallback。极典型，M8 链式对话框直接照抄模式
2. **InputDialog 内部的 Find / Go to line**（`inputdialog.lua:962-1056`）：一个 InputDialog 里点 Find 按钮 → toggleKeyboard(false) 隐藏键盘 → 弹第二个 InputDialog → 第二个关闭后 toggleKeyboard() 恢复。是"InputDialog 套 InputDialog"的标准模式，对 M8 的"InputDialog 套 TextViewer"有直接参考价值（注意 `stop_events_propagation=true` 防止事件穿透到下层 dialog，inputdialog.lua:966）
3. **filemanagershortcuts.lua:425-426**：close A → show B 的最干净小例子

### 3.6 M8 链式对话框推荐实现路线

**伪代码步骤**（不写真实代码）：

1. 在 main.lua 或新建 ai.lua 维护 `self._ai_session = { original_text, messages = {{role, content}...} }`
2. **打开 InputDialog（首轮）**：
   - title="AI 对话"，input=空，input_hint="输入你的问题…"
   - buttons 第一行三个模板按钮，第二行 [取消][发送]
   - 模板按钮 callback：调 `dialog:setInputText(template_prompt_for(original_text))`，不关 dialog
   - "发送" callback：取 `dialog:getInputText()` 加入 messages → `UIManager:close(dialog)` → show InfoMessage "思考中…" → `UIManager:nextTick(function() 调用 API end)`
3. **API 返回后**：`UIManager:close(loading_infomsg)`（如果还显示）→ `UIManager:show(textviewer)`，textviewer.text 由 messages 渲染成"原文 + Q1 + A1 + Q2 + A2…"。`add_default_buttons=true`，`buttons_table` 追加一行 `[继续问][让 AI 总结][加到笔记]`
4. **"继续问"按钮**：`UIManager:close(textviewer)` → 立刻 `UIManager:show(input_dialog_round2)`；round2 与首轮同一个 InputDialog 实例（或重新 new），input=空，messages 已包含上一轮 QA → 用户输入 → 发送 → API 调用（带累积上下文）→ 关 InputDialog → show TextViewer（带累积历史）
5. **"加到笔记"**：复用项目已有的 `Annotation:addNote` 之类 API（M8 调研任务 1 范围）
6. **状态管理**：每次关闭 TextViewer 时不要清空 messages；只有用户点"关闭"或切书才 reset session
7. **错误处理**：API 失败用 `UIManager:show(InfoMessage)`（项目 main.lua:_showSyncError 已有同款）

**关键陷阱提醒**：

- InputDialog 套 TextViewer 时，InputDialog 的虚拟键盘需要先 `onCloseKeyboard()` 或 `toggleKeyboard(false)` 再 show TextViewer，否则键盘残留在屏幕底部（参考 inputdialog.lua:962）
- 跨 nextTick 的闭包**不能**引用 `self.ui`（项目 main.lua:_triggerSync 已踩过坑：close-document 路径 ReaderUI 可能在 nextTick 前被拆毁）。M8 API 调用闭包里需要 self 时，提前 capture 到 local

---

## 4. Lua require 缓存 + package.path 调研

### 4.1 KOReader 的 package.path 配置

**插件目录是动态加进 package.path 的**，不是启动时静态配置：

- `E:\koreader-src\frontend\pluginloader.lua:242`：加载每个插件时临时把 `plugin_root/?.lua` 加到 package.path 前面（`package.path = string.format("%s/?.lua;%s", plugin_root, package_path)`）
- `pluginloader.lua:269`：load 完一个插件就**恢复原 package.path**，下一个插件再临时改
- `pluginloader.lua:284-287`：所有插件加载完毕后，把**所有 enabled 插件路径**永久追加到 package.path（`package.path = string.format("%s;%s/?.lua", package.path, plugin.path)`）。这是 KOReader 运行时的最终 package.path，所以插件代码里能 `require("config")` 找到同目录下的 config.lua

**启动时的基础 package.path**：`E:\koreader-src\setupkoenv.lua:2-4` 配置（包括 frontend/、base/ 等基础路径），与 M8 无关。

### 4.2 KOReader 怎么加载插件

`E:\koreader-src\frontend\pluginloader.lua`：

1. `_discover`（:201-228）：扫描 `plugins/` 等目录，凡以 `.koplugin` 结尾的子目录都识别为插件，记录 `main.lua / _meta.lua` 路径
2. `_load`（:231-271）：
   - 临时改 package.path 加进插件目录
   - **`pcall(dofile, mainfile)`** 加载 main.lua（:244）—— **用的是 `dofile`，不是 `require`！** 所以每次 PluginLoader 启动都重新执行 main.lua，且 main.lua 返回的 module table 由 PluginLoader 自己保管，不进 `package.loaded`
   - 同样 `pcall(dofile, metafile)` 加载 _meta.lua（:253）
3. `loadPlugins`（:273-292）：把每个 enabled 插件的路径**永久**加进 package.path

**关键结论**：插件 main.lua 是 `dofile` 加载，**不在 package.loaded 缓存**。但插件内部代码用 `require("config")` 时，require 会查 package.path（包含插件目录）→ 找到 `config.lua` → **第一次执行后存入 `package.loaded["config"]`**。这就是 require 缓存坑的来源。

### 4.3 require 加载用户可编辑配置的问题

Lua 的 `require` 机制：

- 第一次 `require("ai_config")` → 沿 package.path 找到 `ai_config.lua` → **执行它，把返回值存入 `package.loaded["ai_config"]`**
- 后续 `require("ai_config")` → **直接返回 `package.loaded["ai_config"]`，不再读文件**

**问题场景**：用户 USB 连 Kindle → 编辑 `fns_sync.koplugin/ai_config.lua`（改 API key、改模型）→ 断开 USB → 回到 KOReader 打开 AI 菜单 → **看到的是旧配置**，因为 `package.loaded["ai_config"]` 还是上次的值。

**`package.loaded` 什么时候清**：

- KOReader 重启（最暴力）
- 手动 `package.loaded["ai_config"] = nil`（标准 Lua 用法）
- 没有其他自动失效机制

### 4.4 几种加载方案的对比

| 方案 | 缓存行为 | 失效时机 | KOReader 内部用例 | M8 适配度 |
|---|---|---|---|---|
| `require("ai_config")` | 进 package.loaded | 仅重启或手动 nil | 业务模块（widget/util）都用此 | ❌ 用户改文件不生效 |
| `require + package.loaded[mod]=nil` | 强制每次重读 | 每次调用前 nil | 不常见 | ⚠️ 可用但啰嗦 |
| **`dofile(path)`** | **不缓存，每次读盘+解析** | 每次调用即最新 | **KOReader 加载插件、LuaSettings 读 settings 文件都用此**（pluginloader.lua:244, luasettings.lua:31, docsettings.lua:276, luadata.lua, readhistory.lua:110） | ✅ **首选**（如果一定要独立文件） |
| `loadfile(path)()` | 同 dofile，但分两步 | 每次调用即最新 | luadata.lua:72 用 `loadfile` + 空 env（沙箱） | ✅ 同 dofile |
| `require` + 让用户重启 | 进缓存 | 重启 KOReader | — | ❌ 用户体验差 |

**KOReader 内部一贯做法**：所有"用户可编辑、需运行时读取"的文件（settings.lua、metadata.lua sidecar、history.lua、_meta.lua、main.lua）**全部用 `dofile`**，从不用 `require`。理由正是避开 package.loaded 缓存。

### 4.5 我们项目现有 config.lua 的加载方式

**关键发现：项目里的 `config.lua` 不是"用户可编辑配置文件"，而是"代码常量模块"**。

- `E:\KOreader-FNS-plugin\plugin\fns_sync.koplugin\config.lua`：定义 `Config.DEFAULTS`、`Config.CURRENT_CONFIG_VERSION`、`Config.MAX_NOTE_BYTES` 等编译期常量
- `main.lua:56`：`local Config = require("config")` —— 用 require 加载
- 用户**不直接编辑** config.lua；用户可调的设置都通过菜单写进 `G_reader_settings["fns_sync"]`（main.lua:79）

**这个 require 是安全的**，因为：

1. config.lua 是代码，不是用户配置
2. 一旦加载后值永远不变，缓存反而是好事（避免每次 require 重新读盘）

**用户配置实际存哪里**：`G_reader_settings:readSetting("fns_sync", {})` 读、`:saveSetting("fns_sync", self.settings)` 写（main.lua:79, 137）。这是 KOReader 标准做法，存全局 `settings.reader.lua`。

### 4.6 KOReader 全局 settings.reader.lua 的读写 API

源码：`E:\koreader-src\frontend\luasettings.lua`

`G_reader_settings` 是一个 LuaSettings 实例（全局对象），表示 KOReader 的 `settings.reader.lua`。

**读**：`G_reader_settings:readSetting(key, default)`（luasettings.lua 注释 :75-81）

- 若 key 不存在且给了 default，则**初始化**为 default 并返回引用
- 若 key 不存在且没 default，返回 nil

**写**：`G_reader_settings:saveSetting(key, value)`（项目 main.lua:137, 205）

**删**：`G_reader_settings:delSetting(key)`（textviewer.lua:269 有用法）

**是否持久化**：LuaSettings 实例的 flush 时机由 KOReader 全局管理（通常关闭 ReaderUI / 退出 app 时写盘），不是 saveSetting 立刻落盘。项目 main.lua:209-213 的注释也说明了这一点。

**项目内已有的同款用法**（全部用 G_reader_settings，不是独立文件）：

- `main.lua:79` 读 fns_sync
- `main.lua:152` 读 fns_sync_queue
- `main.lua:233` 读 fns_sync_last_synced
- `main.lua:137/205/215/240` 写

### 4.7 M8 ai_config.lua 的推荐加载方式

**核心结论**：**不要让用户编辑独立的 `ai_config.lua` 文件，而是把 AI 相关设置（API key、模型名、base URL、模板提示词等）作为子项写进 `G_reader_settings["fns_sync"]`**，复用项目现有的菜单 + `_editString` + `save_callback` 模式（main.lua:250-267）。

**为什么这样选**：

1. KOReader 一贯把"用户可调"配置存进 G_reader_settings，从不让用户 USB 编辑独立 lua 文件（对比 settings.reader.lua、metadata.lua sidecar 全是 dofile 读，但都是 KOReader 自己写、用户不直接编辑）
2. 复用现有的 `_editString` / `_toggleBool` / `Config.DEFAULTS` backfill + `config_version` 迁移机制（main.lua:84-135），AI 配置改动可平滑迁移
3. 避免 dofile + 每次读盘的性能/损坏风险（用户手抖写错 Lua 语法 → dofile 抛错 → AI 功能直接挂）
4. 第一次实现失败正是因为"require 加载 ai_config.lua" + 用户改文件不生效 —— 走 G_reader_settings 路线天然没有这个问题

**M8 实施步骤（伪代码）**：

1. **`Config.DEFAULTS` 增加 AI 子节**（在 `config.lua:107` 的 DEFAULTS 表里）：
   - `ai_enabled = false`
   - `ai_api_base = ""`（用户填 API 服务商 base URL）
   - `ai_api_key = ""`
   - `ai_model = "gpt-4o-mini"` 之类默认值
   - `ai_max_tokens = 2048`
   - `ai_temperature = 0.7`
   - `ai_template_translate = "请把下面这段文字翻译成中文：\n\n{text}"`
   - `ai_template_explain / ai_template_comment` 类似
2. **`Config.CURRENT_CONFIG_VERSION` 从 4 升到 5**，main.lua:init 增加一段 `if prev_version < 5 then ... end` 迁移块（M4→M7 都是这个套路）
3. **菜单新增"AI 对话"子树**，结构类似现有"自动同步"子树（main.lua:1811-1895），包含：
   - "启用 AI 对话"（toggle）
   - "API 设置" 子菜单（base URL / API key / model，全部 `self:_editString(...)`）
   - "提示词模板" 子菜单（translate/explain/comment，全部 `_editString` 带 multiline=true）
   - "开始 AI 对话"（按下打开 3.6 节描述的 InputDialog）
4. **运行时读取配置**：直接 `self.settings.ai_api_key` 等（settings 已经在 init 时通过 DEFAULTS backfill 好了），无需 require/dofile 任何文件
5. **绝对不要**新建 `ai_config.lua`；**绝对不要**用 `require("ai_config")`

**例外情况**（如果将来真的需要"模板文件"放在 vault 里给用户用 Obsidian 编辑）：用 `dofile(absolute_path)` 读，且包 `pcall(dofile, path)`（参考 luasettings.lua:31 的安全写法），文件读失败回退到 `Config.DEFAULTS` 里的默认模板。

---

## 5. M8 设计文档需要修正的错误假设清单

下表对照 `docs/superpowers/specs/2026-08-11-ai-chat-design.md` 原设计与本次调研发现，列出**必须修正**的条目。`writing-plans` 阶段直接以此为准。

| # | 设计文档原假设 | 调研真相 | 影响章节 | 修正方向 |
|---|---|---|---|---|
| 1 | "KOReader 调用 `onShowHighlightMenu` 事件，插件可拦截" | KOReader 不广播此事件；它是 ReaderHighlight 自己的普通方法，**插件无法通过事件机制拦截** | §7.1 菜单入口 | 改用 `self.ui.highlight:addToHighlightDialog(idx, fn_button)` 注册按钮（qrclipboard 同款） |
| 2 | "入口 A 和入口 B 都做，覆盖边读边问和事后问" | `addToHighlightDialog` 注册的按钮**两条路径都自动出现**（B 路径多一层"编辑高亮"前置菜单，需点"…"才看到） | §7.1 菜单入口 | 不需要分两个入口写代码，一套注册搞定；若要 B 第一层就出现，需进一步调研（目前没找到现成钩子） |
| 3 | "独立 `plugin/fns_sync.koplugin/ai_config.lua` 文件，用户 USB 编辑" | `require` 加载 + `package.loaded` 缓存导致用户改文件不生效；dofile 虽可，但 KOReader 内部一贯把"用户可调配置"塞进 `G_reader_settings`，从不让用户编辑独立 lua | §6.1 配置文件 §6.2 API key 输入方式 | **取消独立文件**，AI 配置全部塞进 `G_reader_settings["fns_sync"]`，复用 `Config.DEFAULTS` + `config_version` 迁移 + `_editString` 菜单 |
| 4 | "用 require 加载 ai_config.lua" | require 的 package.loaded 缓存机制不适合"用户可编辑配置" | §6.1 | 同上 |
| 5 | "Plugin 的 init() 中注册高亮按钮" | 部分正确：注册时机确实是 init()，但**必须是 `self.ui.highlight:addToHighlightDialog()`，不是定义 `onShowHighlightMenu` 方法** | §7.3 模块结构 | 调整 main.lua init() 注册逻辑，照搬 qrclipboard main.lua:18-21 + 27-63 |
| 6 | "ai.lua 模块（HTTP 调用 + 对话框 UI + 错误处理）" | 方向正确，但 HTTP 调用应**完全复用 FNS api.lua 现有模式**（同步 luasocket + rapidjson + nextTick），不要引入 Trapper/Spore/httpclient | §7.3 模块结构 | ai.lua 拆为 `ai.lua`（HTTP 调用层，结构对齐 api.lua）+ UI 层（链式对话框逻辑可放 main.lua 或 ai_dialog.lua） |
| 7 | "InputDialog 顶部三个按钮 `[翻译][解释][评论]`" | 实现可行，buttons 第一行放三个 callback，调 `dialog:setInputText(template)` | §6.4 快捷模板 | 设计正确，无需修改 |
| 8 | "链式对话框：InputDialog → API → TextViewer → 继续问回到 InputDialog" | 实现可行，KOReader 标准 `close A + show B` 同步模式 | §4.1 链式对话框 | 设计正确，注意 InputDialog 套 TextViewer 时要先 `onCloseKeyboard()` |
| 9 | "AI@ 块作为 USER 内容走现有 M5 路径" | 设计合理，marker.lua 扩展支持 `type = "ai"` segment 跟现有 `type = "hl"/"user"` 同构 | §5 笔记格式 | 设计正确，本次调研未覆盖 marker.lua 内部扩展细节，实施时需单列一项调研 |
| 10 | "timeout 30s" | 建议升级到 `block=10s, total=60s`，给 DeepSeek 30s 推理 + 网络往返留余量 | §7.2 错误处理 | 用 `socketutil:set_timeout(10, 60)`，参考 kosync 的 `PROGRESS_TIMEOUTS / AUTH_TIMEOUTS` 分级策略 |
| 11 | 隐含假设：rapidjson 编码 OpenAI body 无坑 | 未验证。FNS 项目踩过 rapidjson `.0` 坑（int → float） | §7.3 / §7.2 | brainstorming 阶段加一项验证：用真实 payload dump 看 max_tokens/temperature 编码形态 |
| 12 | "USB 连 Kindle → PC 编辑 ai_config.lua" 入口 | 整个入口不需要了（配置走菜单） | §6.2 API key 输入方式 | 删除"方式 1（USB 编辑）"，只保留"方式 2（菜单输入）" |

---

## 6. M8 实施路线图（writing-plans 阶段直接引用）

基于以上调研，M8 的实施应拆分为以下 5 个相对独立的任务，每个任务都可独立测试 + commit。

### Task A：配置基础设施（无 UI，纯数据层）

**目标**：把 AI 配置塞进 `G_reader_settings["fns_sync"]`，为后续 UI 和 HTTP 提供数据基础。

**改动范围**：

- `plugin/fns_sync.koplugin/config.lua`：`Config.DEFAULTS` 加 AI 字段；`Config.CURRENT_CONFIG_VERSION` 4 → 5；新增 `Config.AI_TIMEOUTS = { 10, 60 }`、`Config.AI_DEFAULT_BASE_URL = "https://api.deepseek.com/v1"`、`Config.AI_DEFAULT_MODEL = "deepseek-chat"` 等常量
- `plugin/fns_sync.koplugin/main.lua`：init() 增加 `if prev_version < 5 then ... end` 迁移块（空操作即可，因为 DEFAULTS backfill 会自动补字段）

**验收**：

- KOReader 启动后，`G_reader_settings:readSetting("fns_sync")` 返回的表里能看到 `ai_enabled / ai_api_key / ai_model` 等字段（默认值）
- M5/M6/M7 现有功能零回归（Kindle 实测）

### Task B：HTTP 调用层（ai.lua 的 API 部分）

**目标**：实现一个 `Ai:chat(settings, messages)` 函数，调 DeepSeek `/chat/completions` 端点，返回 `{ ok, network_error, http_code, content, error_msg }` 结构。

**改动范围**：

- 新建 `plugin/fns_sync.koplugin/ai.lua`，结构对齐 `api.lua`（require socket.http / ltn12 / rapidjson / socketutil / logger；定义 `Ai:chat`；定义内部 `_buildRequest` / `_parseResponse`）
- **不写 UI 代码**，纯数据层

**验收**：

- Kindle 上用 Lua console 手动调 `Ai:chat({ai_api_base=..., ai_api_key=..., ai_model=...}, {{role="user", content="hello"}})` 能拿到 DeepSeek 的响应
- 错误场景（无网络 / key 错 / 429 / timeout）返回结构正确（Kindle 实测 + crash.log 检查）
- rapidjson `.0` 坑验证（dump body 看编码形态）

### Task C：高亮菜单按钮注册

**目标**：长按高亮 → 弹出"问 AI"按钮（按钮 callback 暂时只 toast "功能开发中"，UI 完整逻辑在 Task D 加）。

**改动范围**：

- `main.lua` 的 `ReaderUI` init() 里加 `self.ui.highlight:addToHighlightDialog("12_fns_ask_ai", function(this) ... end)`
- 闭包返回的 button：text="问 AI"，callback 暂时只 `UIManager:show(InfoMessage{ text="功能开发中" })`
- 加 `show_in_highlight_dialog_func`：仅当 `self.settings.ai_enabled == true` 且 `this.selected_text` 非空时显示

**验收**：

- Kindle 实测：长按选中文字 → 弹菜单 → 看到"问 AI"按钮（位置合理）
- Kindle 实测：长按已有高亮 → "…" → 看到"问 AI"按钮
- Kindle 实测：ai_enabled=false 时按钮不出现
- 长按不再闪退（这是 2026-08-12 回滚的直接原因）

### Task D：链式对话框 UI

**目标**：完整实现 §3.6 的链式对话框——InputDialog 输入问题 → API 调用 → TextViewer 显示对话 → 继续问 / 让 AI 总结 / 关闭。

**改动范围**：

- main.lua 的"问 AI"按钮 callback 完整化：close 高亮菜单 → show InputDialog（首轮）
- InputDialog 按钮：第一行 [翻译][解释][评论] 模板，第二行 [取消][发送]
- 发送 callback：取输入 → close InputDialog → show InfoMessage "思考中…" → nextTick 调 `Ai:chat` → close InfoMessage → show TextViewer
- TextViewer 按钮：[继续问][让 AI 总结][关闭]（"加到笔记"在 Task E 加）
- "继续问" callback：close TextViewer → show InputDialog（带累积上下文）
- "让 AI 总结" callback：close TextViewer → 在 messages 末尾追加"请总结以上对话"作为 user → nextTick 调 Ai:chat → show TextViewer
- session 管理：切书 / 关 ReaderUI 时 reset

**验收**：

- Kindle 实测：高亮 → 问 AI → 输入"翻译这段" → 看到 AI 回复
- Kindle 实测：多轮对话（≥3 轮）有上下文累积
- Kindle 实测：错误场景（无网络 / timeout / 429）toast 提示正确，不闪退
- Kindle 实测：InputDialog 虚拟键盘开关正确（套 TextViewer 时键盘关闭）

### Task E：AI@ 块写入 + marker.lua 扩展

**目标**：用户点"加到笔记" → AI 内容作为 AI@ 块写入笔记，通过 FNS 同步推送到 Obsidian。

**改动范围**：

- `marker.lua` 扩展支持 `type = "ai"` segment（parse / serialize / diff 不参与）
- TextViewer 加"加到笔记"按钮：构造 AI@ 块字符串（datetime + hl 关联 + model）→ 走现有 `_triggerSync` 路径 → toast "AI 内容已加入笔记"
- M8 设计文档 §5.5 的"AI@ 块零修改 HL@ 块"承诺验证

**改动前必做的额外调研**（本次报告未覆盖）：

- marker.lua 现有 HL@ / USER segment 的 parse/serialize/diff 代码完整阅读
- AI@ 块的 diff 不参与（跟 USER 一样原样保留）的具体实现位置

**验收**：

- Kindle 实测：高亮 → 问 AI → 加到笔记 → Obsidian 端看到 AI@ 块（紧跟 HL@ 块之后）
- Kindle 实测：双向同步（B 设备拉取）AI@ 块原样保留
- M5/M6/M7 已有功能零回归（Kindle 实测 + 单元测试）

### 实施顺序与依赖

```
Task A (配置基础设施)
   ↓
Task B (HTTP 调用层) ──── 可与 Task C 并行
   ↓                        ↓
Task C (高亮菜单按钮)    Task D (链式对话框 UI) ── 依赖 B 的 Ai:chat
   ↓                        ↓
   └──────────────┬─────────┘
                  ↓
          Task E (AI@ 块 + marker.lua 扩展)
```

**推荐顺序**：A → B → C → D → E（每一步独立 commit + Kindle 实测通过再进下一步），避免再次发生"今天这样堆叠修复 + 回滚"的浪费。

---

## 7. 附录：参考源码清单（全部绝对路径）

### KOReader 源码（`E:\koreader-src\`）

**高亮菜单相关**：

- `frontend/apps/reader/modules/readerhighlight.lua`（全文 ~2100 行；重点 107-265 init + _highlight_buttons 注册、1011-1013 onTap 命中已有高亮、1260-1468 showChooseHighlightDialog/showHighlightDialog、1480-1525 addToHighlightDialog + onShowHighlightMenu、2079 onHoldRelease）
- `plugins/qrclipboard.koplugin/main.lua`（14-63：WidgetContainer 继承 + addToHighlightDialog 注册 + 闭包实现，**M8 高亮按钮直接照抄**）
- `plugins/qrclipboard.koplugin/_meta.lua`（仅 fullname + description）
- `frontend/apps/reader/modules/readerhandmade.lua:378-396`（旁证：另一个用 addToHighlightDialog 的 KOReader 内置模块）

**HTTP 客户端相关**：

- `frontend/socketutil.lua`（7-9：require 三件套；29-33：timeout 常量；52-70：set_timeout；91-93：错误码）
- `plugins/kosync.koplugin/KOSyncClient.lua:6-8, 38-62`（kosync 的 timeout 分级 + httpclient 异步，**异步方案我们不用，但 timeout 分级可借鉴**）
- `plugins/wallabag.koplugin/main.lua:906-919`（同步 HTTP 调用 + set_timeout/reset_timeout 标准用法）
- `frontend/ui/network/wikipedia.lua:204-219`（错误处理模式）
- `frontend/ui/trapper.lua:42-61`（异步 trap 机制文档，**M8 不用**）

**对话框组件相关**：

- `frontend/ui/widget/inputdialog.lua`（123 类定义；21-42 buttons 示例；123-201 构造参数；525-551 addWidget；581/585 getInputText/Value；594 setInputText；803-929 save_callback 自动追加三按钮；962-1056 嵌套 InputDialog 例子）
- `frontend/ui/widget/textviewer.lua`（40 类定义；40-96 构造参数；343-397 默认按钮 + add_default_buttons；549 close_callback；670-716 findDialog 链式对话框例子；703-712 addWidget 插入 CheckButton；792 text_selection_callback；805 reinit）
- `plugins/newsdownloader.koplugin/main.lua:1083-1118, 1094-1095`（buttons 完整结构 + close A → show B）
- `frontend/apps/filemanager/filemanagershortcuts.lua:425-426`（close A → show B 最干净的例子）
- `frontend/ui/viewhtml.lua:135-136, 428-429`（TextViewer → TextViewer 链式例子）

**插件加载 + package.path 相关**：

- `frontend/pluginloader.lua:201-292`（_discover / _load / loadPlugins；244 dofile 加载 main.lua；284-287 永久加进 package.path）
- `frontend/luasettings.lua:21-48, 75-81`（dofile 读 settings；readSetting 含 default 的初始化语义）
- `frontend/luadata.lua:72`（loadfile + 空 env 沙箱，可选参考）
- `frontend/docsettings.lua:276, 305`（dofile 读 metadata sidecar，旁证 KOReader 一贯做法）
- `setupkoenv.lua:2-4`（启动时基础 package.path）

### 我们项目现有代码（`E:\KOreader-FNS-plugin\plugin\fns_sync.koplugin\`）

- `main.lua:56`（require config）
- `main.lua:79`（readSetting fns_sync）
- `main.lua:84-135`（Config.DEFAULTS backfill + config_version 迁移逻辑，**M8 Task A 直接照搬**）
- `main.lua:137/205/215/240`（saveSetting / delSetting 用法）
- `main.lua:152/233`（readSetting fns_sync_queue / fns_sync_last_synced）
- `main.lua:250-267`（_editString 函数，**M8 AI 配置菜单直接照搬**）
- `main.lua:387-397`（异步 InfoMessage + nextTick 模式）
- `main.lua:552-586`（_triggerSync 同步 HTTP 调用包装，**M8 Ai:chat 入口直接照搬**）
- `main.lua:1255`（scheduleIn 用法）
- `main.lua:1811-1895`（"自动同步"子菜单树结构，**M8"AI 对话"子菜单直接照搬**）
- `config.lua:107-189`（DEFAULTS 结构，**M8 Task A 在此追加 AI 字段**）
- `api.lua:72-123`（HTTP 调用骨架，**M8 ai.lua 直接照搬**）
- `api.lua:87, 92-99, 118-122, 135-182, 159`（rapidjson encode/decode + `.0` 坑修复 + makeRequest 高层封装）
- `marker.lua`（HL@/USER segment 的 parse/serialize/diff/applyDiff，**Task E 必须先完整阅读**）

---

## 8. 待解决的开放问题（writing-plans 阶段需要回答）

1. **入口 B 第一层菜单**：长按已有高亮的第一层（`showHighlightDialog`）目前没找到可扩展的注册口，全是硬编码 buttons。若产品要求"第一层就看到问 AI"，需要进一步调研（可能要 monkey-patch 或加 hook）。**MVP 建议**：先不做，用户在第一层点"…"进 `onShowHighlightMenu` 再看到"问 AI"按钮是可接受的（跟 qrclipboard 一致）

2. **rapidjson `.0` 坑验证**：在 Task B 实施前，用真实 payload 验证 `rapidjson.encode({max_tokens=2048, temperature=0.7})` 的输出形态。如果踩坑，复用 FNS api.lua 的 `gsub` 修复

3. **AI@ 块在 marker.lua 里的扩展细节**：本次调研未覆盖 marker.lua 内部 parse/serialize/diff/applyDiff 的完整代码。Task E 实施前需补一份针对性的源码阅读报告

4. **"让 AI 总结"的上下文窗口**：多轮对话 token 累积成本（M8 设计文档 §11 风险表已列出）。建议 Task D 实施时加一个"超过 N 轮自动提示用户"或"max_tokens 调小"的保护机制

5. **API key 在 Kindle 文件系统的安全级别**：跟 FNS token 同安全级别（明文存储 + 不加密），用户登出 DeepSeek 后台撤销即可。本次调研确认这是 KOReader 一贯做法（settings.reader.lua 也是明文），YAGNI 不加密

---

**报告结束。下一步：用 `writing-plans` 技能创建基于本报告的实施计划。**
