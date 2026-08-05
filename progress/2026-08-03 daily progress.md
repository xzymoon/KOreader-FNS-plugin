# 2026-08-03 开发进度

## 主要任务

调试 KOreader FNS 同步插件，定位"同步失败 305 Invalid Params"错误的根因。

## 重要发现

### 1. FNS Token 作用域系统（3D-RBAC）

克隆 FNS 服务端源码（`haierkeys/fast-note-sync-service`）逐行审计，确认了 3D-RBAC 作用域机制：

- **格式**：`p:<protocol> c:<client> f:<function>`（空格分隔）
- **协议维度**：`rest` / `ws` / `mcp` / `*`
- **客户端维度**：`webgui` / `obsidian` / `mobile` / `koreader` / `*`
- **功能维度**：`note_r` / `note_w` / `note_rw` / `file_r` / `*`

### 2. Obsidian vs KOreader 协议路径差异

| 客户端 | 协议 | 端点 | 校验逻辑 |
|---|---|---|---|
| Obsidian 插件 | WebSocket | `/api/user/sync` | `VerifyPermissions(scope, "ws", client, "")` |
| KOreader 插件 | REST | `GET/POST /api/note(s)` | `VerifyPermissions(scope, "rest", client, "note_r/note_w")` |

Obsidian 一键授权生成的 Token scope 默认是 `p:ws c:obsidian* f:*` — 只允许 WebSocket 协议，REST 请求会被 `code 315 ErrorAuthTokenScopeRestricted` 拦下。

### 3. 用户初始 315 错误的修复

让用户在 WebGUI 手动新建 Token，scope 必须包含 `p:rest`，并指定 `f:note_r,note_w`（或 `f:*`）。Token ID 34 是 Obsidian 一键授权的旧 Token（仅 p:ws），换成新 Token 后 315 消失。

### 4. FNS 不支持"永不过期"Token

- DTO 硬性要求 `ExpiredDays >= 1`（`binding:"min=1"`）
- 计算逻辑直接 `time.Now().Add(days * 24h)`，无"永久"分支
- 推荐填 `3650`（10 年）

### 5. 305 错误的真相 — JSON 解析失败（不是字段校验失败）

服务端日志 `NoteHandler.CreateOrUpdate.BindAndValid err {"error": ""}` — **错误字符串为空**。

源码层面分析（`pkg/app/form.go:BindAndValid`）：

```go
if err := c.ShouldBind(obj); err != nil {
    if validationErrors, ok := err.(validator.ValidationErrors); ok {
        // 只有 validator 类型错误才填进 errs
    }
    return false, errs  // 其他类型错误直接返回，errs 为空
}
```

`errs.ErrorsToString()` 返回空字符串 → 客户端看到 `details=""` 的 305。

→ 这**不是**字段必填校验失败（那样会有具体字段名），而是 `ShouldBind` 在 JSON 解析阶段就抛了非 validator 类型的错误（最可能是 `*json.UnmarshalTypeError` 或 `*strconv.NumError`）。

### 6. PowerShell 模拟测试 — 推翻"ctime 编码"假说

| Test | 内容 | 结果 |
|---|---|---|
| A | 整数 ctime `1722672000000` | ✅ code=1 |
| B | 浮点 ctime `1.722672e12` | ✅ code=1 |
| C | 字符串 ctime `"1722672000000"` | ❌ code=305 |
| D | 超长中文 path（KOreader 实际 path） | ✅ code=1 |
| E | 多行 markdown + HTML 注释 `<!-- -->` | ✅ code=1 |
| F | emoji content（📌🟢🔵🟡）| ✅ code=1 |

**结论**：rapidjson 编码 number 不是问题；path 长度不是问题；content 多行/HTML 注释/emoji 都不是问题。根因在 KOreader 实际生成的 body 里某个我们没复现的细节上（最可能：rapidjson 的 boolean 编码边缘情况、vault 含不可见字符、或 content 里有从 EPUB/PDF 摘录的某种特殊字符）。

## 代码改动

### `plugin/fns_sync.koplugin/api.lua`

在 `_rawRequest` 函数里加了**临时** dump 调试代码（5 行），把每次 POST 请求的实际 JSON body 写到 `/mnt/us/koreader/fns_body.txt`，便于从 Kindle 拉出真实 body 做字节级分析。

- 仅在 `body ~= nil` 分支生效（即只对 POST/PUT 等带 body 的请求）
- body 文件不含 token（token 在 Authorization header）
- 标注 `TEMP DEBUG` 注释，根因定位后立即删除

## 待办（当天剩余）

- [ ] 用户部署改后的 api.lua 到 Kindle，触发一次同步失败
- [ ] 从 Kindle 拉出 `/mnt/us/koreader/fns_body.txt`
- [ ] 分析真实 body，定位 305 根因
- [ ] 修复 api.lua
- [ ] 删除临时 dump 代码
- [ ] 修复 `_rawRequest` 的另一个已知 bug：socket.http 失败时 `socket.skip(1, ...)` 把错误字符串误判为 HTTP code（导致 `HTTP CLOSE NIL` 显示）

## 工具与方法

- 用 `git clone` 拿到 FNS 服务端 Go 源码做静态审计
- 用 PowerShell `Invoke-RestMethod` + `ConvertTo-Json` 做 HTTP 探针（cmd + curl 在 JSON body 转义上是死路）
- 服务端日志（Docker `fast-note-sync-service` container stdout）定位 `BindAndValid err {"error": ""}` 空错误

## 安全注意

用户在调试过程中曾把完整 JWT Token 贴进对话（token_id=35）。已建议用户：
- 在 WebGUI 撤销该 Token
- 新建带 `p:rest` 作用域的 Token
- 今后贴日志/响应时涂掉 Authorization header

## 根因定位与修复（下午）

### 7. dump 文件分析 — 锁定根因

用户从 Kindle 拉出 `/mnt/us/koreader/fns_body.txt`（25.9 KB），核心字段：

```json
{"createOnly":true,"vault":"...","path":"KOReader/《...》.md","ctime":1785730809000.0,"mtime":1785730809000.0,"content":"..."}
```

**`"ctime":1785730809000.0`** 和 **`"mtime":1785730809000.0`** — rapidjson 把 Lua number（double）按浮点字面量输出，带 `.0` 后缀。

### 8. Go json 包对 int64 字段的规则

| JSON 字面量 | 形式 | Go int64 接受？ |
|---|---|---|
| `1785730809000` | 纯整数 | ✅ |
| `1.785730809e12` | 科学计数法（无小数部分） | ✅ |
| `1785730809000.0` | 带小数点的浮点字面量 | ❌ 抛 `*json.UnmarshalTypeError` |

→ `BindAndValid` 拿到非 `validator.ValidationErrors` 类型错误 → 返回空 errs → 客户端看到 `details=""` 的 305。

### 9. 为什么 PowerShell Test A 没复现

PowerShell `ConvertTo-Json` 对 `[long]1722672000000` 输出纯整数 `1722672000000`（无 `.0`），所以成功。KOreader 的 Lua rapidjson 一律按 double 输出 → `.0` 后缀。**两边 number 序列化细微差别就是病根**。

### 10. 修复方案 — gsub 后处理

`api.lua:_rawRequest` 在 `rapidjson.encode` 后加 gsub：

```lua
body_json = body_json:gsub("(%d)%.0([,}])", "%1%2")
```

**安全性论证**：
- 字符串内部的 `.0` 后面总是跟 `"`（不是 `,` 或 `}`），正则不会误伤
- 时间戳永远是整数 → rapidjson 输出永远是 `.0` 结尾
- 没有任何 JSON 数字字段会输出非零小数（`createOnly` 是 bool，所有 number 都是整数时间戳）

同时删除了 dump 调试代码（5 行）。

### 11. 方案选择理由

考虑过方案 B（手动构造 JSON body，~25 行），但 rejected：
- content 字段含繁体中文 + emoji + HTML 注释 + 多行，手写 RFC 8259 转义风险高
- rapidjson 已验证能正确处理这些复杂内容（dump 文件本身就是证据）
- 维护性差，每次新增字段都要改两处
- 不符合 KISS / Surgical Changes 原则

## 当前状态

- ✅ 305 根因已定位（rapidjson 浮点输出 + Go int64 拒绝）
- ✅ 修复已应用（gsub 后处理）
- ✅ dump 调试代码已删除
- ✅ 用户实测同步成功（基础流程通过）
- 📋 已知遗留 bug：`_rawRequest` 中 `socket.skip(1, http.request(...))` 在网络错误时把错误字符串误判为 HTTP code，导致显示 `HTTP CLOSE NIL`。下次修复

## 用户提的新需求（下午讨论）

测试通过后，用户提出 3 个改进 + 1 个能力问询：

### 需求 0：自动同步能力问询（M5，未实施）

**用户问**："如果我在书上做高亮等，是否能够自动同步到 FNS？"

**当前状态**：
- ✅ 手动点"同步当前书"按钮 → 工作（用户已验证）
- ❌ 高亮时自动同步 → **未实现**（M5 规划）
- ❌ 打开书自动同步 → 未实现（菜单开关有，行为没接）
- ❌ 关闭书自动同步 → 未实现（同上）

`config.lua` 里 `sync_on_highlight` / `sync_on_book_open` / `sync_on_book_close` 三个开关当前是装饰性的（开关能开能关，但没有事件监听器响应）。

**实施思路（用户说"先记下"，未启动）**：
1. 订阅 KOreader 事件（具体事件名要查源码确认）：`onAnnotationsModified` / `onReaderReady` / `onCloseDocument`
2. 加 debounce（已有 `debounce_seconds = 3` 配置，未接线）
3. 每个 handler 开头判断对应开关
4. 复用 `_doSyncCurrentBook` 核心逻辑

**主要权衡**：
- 简单版（M5 全量 + debounce）：每次 debounce 后整本同步，代码少；缺点是高亮很多时每次发整本书
- 增量版（M6）：只发送变化的高亮条目，需要离线队列、状态追踪、diff 算法

**推荐**：先做简单版（M5），跑起来看体验再决定要不要 M6。

**触发条件**：等用户明确说"开始实施 M5"再启动。当前先记下。

---

### 需求 1：Obsidian 渲染友好性

观察到的问题：
- `[p.425]` 被 Obsidian 识别为指向 `p.425` 笔记的双链（wiki-link 语法）
- `<!-- HIGHLIGHTS_START -->` 和 `<!-- H:{datetime} -->` 渲染为灰色 HTML 注释（视觉噪音）

子决策：
- **1a 页码格式**：`[p.{page}]` → `📖 第 {page} 页 ·`（避免双链 + 中文友好）
- **1b 摘录时间戳**：`<!-- H:{datetime} -->` → `*H: {datetime}*`（Markdown 斜体，纯文本）
- **1c marker 机制**：从"区域 marker"（HIGHLIGHTS_START/END 整片替换）升级到"条目 marker"（每条摘录各自 HL@ 块，按 datetime 匹配）

1c 升级的动机：用户希望"在两条摘录之间穿插写感想" → 旧机制会丢失（marker 之间整片覆盖）→ 新机制保留任意位置的 user 内容。

### 需求 2：合集自定义当前书标题

合集类书籍（如《钱穆国学作品集》）文件名超长，用户希望 per-book 覆盖 title/author，避免每次同步都用文件名做标题。

### 需求 3：文件名格式

用户的目标格式 `《书名》-作者.md`，当前默认 `《{title}》读书笔记.md`。**纯配置问题**（菜单里改 `note_filename_template` 即可），无需改代码。

---

## M4 条目 marker 实施记录（傍晚）

### 设计文档

`progress/M4-item-marker-design.md` — 5 个决策点 + 算法伪码 + 9 项验证标准。

5 个决策点（用户全部认可推荐项）：

| # | 决策 | 选择 |
|---|---|---|
| 1 | HL@ marker 形式 | HTML 注释 `<!-- HL@xxx -->`（与原 HIGHLIGHTS marker 风格统一）|
| 2 | 删除高亮处理 | 直接删（带配置项预留）|
| 3 | 章节标题位置 | HL@ 块内（重渲染时随摘录一起更新）|
| 4 | 旧笔记迁移 | 不做（用户处于测试阶段，会删除重来）|
| 5 | 新增高亮插入位置 | 按 datetime 全局排序 |

### 实施（3 个 commit）

**Commit 1: `marker.lua` 新建（229 行）**

4 个公开函数：
- `parse(content)` — 字符串 → segments 列表（区分 user / hl 两类）
- `serialize(segments)` — 逆操作，相邻 hl 段自动补 \n\n 分隔
- `diff(existing_segments, current_highlights)` — 计算 insert/delete/update 操作
- `applyDiff(existing_segments, actions)` — in-place delete/update，按 ts 排序后逐个 insert

鲁棒性：
- 损坏的 HL@ 块（缺闭合 marker）当作用户内容保留
- `string.find` 全部用 `plain=true`，避免 Lua 模式干扰

幂等性：parse → serialize 对格式良好的输入严格可逆；hl 段内部空白规范化（前后空白被 trim），user 段原样保留。

**Commit 2: 集成到 `excerpt.lua` / `main.lua` / `config.lua`**

`config.lua`:
- 删除 `HIGHLIGHTS_START_MARKER` / `HIGHLIGHTS_END_MARKER` 常量
- `DEFAULT_EXCERPT_TEMPLATE` 默认值改为 Obsidian 友好格式（1a + 1b）
- `DEFAULT_NOTE_TEMPLATE` 用 `{{HIGHLIGHTS}}` 占位符代替 HIGHLIGHTS_START/END

`excerpt.lua`:
- `renderExcerpt` 不变（按模板替换的逻辑复用）
- `renderExcerptBlock` 返回值从字符串改为 `{ datetime -> block_content }` 字典
- `renderFullNote` 参数从 `annotations` 改为 `highlights_by_ts`；用 `{{HIGHLIGHTS}}` 占位符替换；HL@ 块按 datetime 排序后用 \n\n 串联
- 删除 `replaceMarkerZone`（被 marker.lua 的 parse/diff/applyDiff/serialize 流程取代）

`main.lua`:
- 加 `local Marker = require("marker")`
- `_doSyncCurrentBook` 流程改为：
  - Existing note: `parse → diff → applyDiff → serialize → overwriteNote`
  - New note: `renderFullNote(highlights_by_ts) → createNote`
- 用户提示带 diff 统计：`+N 更新M 删除K`

### 边界情况验证（思维实验）

| # | 场景 | 期望 | 验证 |
|---|---|---|---|
| 1 | 首次同步 | 生成带 N 个 HL@ 块的笔记 | ✅ renderFullNote 输出 `<!-- HL@ts -->...<!-- /HL@ts -->` 串联 |
| 2 | 二次同步无变化 | 字节级一致 | ✅ parse → serialize 严格 idempotent |
| 3 | 在两条 HL@ 之间加文字 | 保留 | ✅ user 段原样保留 |
| 4 | 在 HL@ 块外加文字 | 保留 | ✅ 同上 |
| 5 | 删一条高亮 | 对应 HL@ 块消失 | ✅ applyDiff delete 移除段，user 段保留 |
| 6 | 加一条新高亮 | 按 datetime 排序插入 | ✅ findInsertionPoint 找正确位置 |
| 7 | 改高亮备注 | 对应 HL@ 块内容更新 | ✅ applyDiff update 替换 content |
| 8 | 章节切换 | 新块含 `## 新章节` | ✅ renderExcerptBlock 在 chapter 变化时前置 |
| 9 | 损坏笔记（手动删 close marker）| 不崩溃，损坏块当 user 保留 | ✅ parse 缺 close 时当 user 内容 |

### 已知限制

- **datetime 冲突**：同本书罕见地可能出现两条 datetime 相同的高亮（毫秒级精度），第二条覆盖第一条（dict 行为）
- **没有"已删除"标记**：当前是直接删除。配置项 `delete_strategy` 预留为未来扩展（M5+）
- **没有并发保护**：用户在 Obsidian 编辑笔记的同时触发 KOreader 同步，可能基于过时内容做 diff。M6/M7 再考虑加锁/版本号

### 待用户测试

部署 4 个 lua 文件到 Kindle：
- `api.lua`（含 305 修复）
- `marker.lua`（新建）
- `excerpt.lua`（重写）
- `main.lua`（重写 _doSyncCurrentBook）
- `config.lua`（默认模板更新）

测试场景：
1. 删除 Obsidian 端旧的《钱穆国学作品集》笔记（避免旧 HIGHLIGHTS_START/END marker 干扰）
2. 在 KOreader 触发同步 → 生成新格式笔记
3. 在 Obsidian 笔记里手动加文字 → 再次同步 → 验证保留
4. 在 KOreader 删一条高亮 → 同步 → 验证对应 HL@ 块消失

---

## 需求 2 实施记录（晚上）

### Per-book title/author override

针对合集场景（用户当前读的《钱穆国学作品集》就是合集），让用户为每本书单独覆盖 title / author，同步时优先用 override。

### 实施（1 个 commit）

**Commit: `feat: 需求 2 — per-book title/author override`**

`config.lua`:
- `Config.DEFAULTS` 加 `book_overrides = {}`
- key 用 `self.ui.document.file`（绝对文件路径）
- value 是 `{ title=..., author=... }`，字段独立可选
- 文件移动会让 override 失效（KISS，不做 hash 索引）

`main.lua`:
- `_getCurrentBookPath()` — 取 `self.ui.document.file`，无书返回 nil
- `_getBookMetadata` 改造 — 先取 doc_props，再用 override 字段（非空）覆盖 title/author；language 永远从 doc_props
- `_editBookOverride(field, label)` — InputDialog 编辑单字段；空字符串=清除该字段；两字段都空则删除整个 entry（回退到 doc_props）
- `_clearBookOverride` — 一键清除当前书的所有 override
- 菜单加"当前书信息"子菜单（在「测试连接」和「设置」之间）：
  - 📁 文件名（`text_func` 动态生成，`enabled_func` 返回 false 灰色不可点）
  - 📖 书名: `<当前生效值>` （`text_func` 实时刷新）
  - ✍️ 作者: `<当前生效值>`
  - 🔄 重置为文件元数据（清除 override）

`text_func` 让菜单项显示值动态刷新 — 用户保存编辑后，关闭对话框，菜单立即显示新值，无需重启 KOreader。

### 关键决策（实施时确认）

| 决策点 | 选择 |
|---|---|
| Override key | 绝对文件路径（`document.file`）|
| 覆盖粒度 | title 和 author 独立（可只改一项）|
| 空值语义 | 空字符串 = 清除该字段 override |
| UI 入口 | 主菜单独立子菜单（per-book 操作，比"设置"更外层）|
| 显示值刷新 | 用 `text_func` 而非 `text`，保证编辑后菜单立即更新 |

### 待用户测试（合并到 M4 测试）

部署 5 个 lua 文件（M4 的 4 个 + 这次新增的）+ config.lua 更新（一次部署即可）。

新增测试场景：
5. 打开《钱穆国学作品集》→ 进入 FNS 同步 → 当前书信息 → 自定义书名为「国史大纲」→ 同步 → 验证笔记文件名是 `《国史大纲》读书笔记.md`（不是超长文件名）

---

## 今日总结

### 完成（按时间顺序）

| 阶段 | 内容 | commit |
|---|---|---|
| 上午 | 调研 FNS 服务端源码，定位 Obsidian（ws 协议）与 KOreader（rest 协议）的差异，让用户生成 `p:rest` scope 的 Token | — |
| 上午 | dump POST body 定位 305 根因 | `ad4c880` |
| 上午 | 修复 305 — rapidjson 浮点字面量导致 Go int64 解析失败（gsub 后处理） | `14e5781` |
| 下午 | M4 设计文档（5 决策点 + 算法 + 9 验证标准）| `211f842` |
| 下午 | 新建 `marker.lua`（229 行，4 个公开函数）| `fe0bd00` |
| 下午 | 集成条目级 marker 到 excerpt/main/config | `ed18077` |
| 下午 | 补记早上讨论的 M5 自动同步问询 | `b39259d` |
| 晚上 | 需求 2 — per-book title/author override（合集场景）| `448ce77` |
| 晚上 | daily progress 总结 | `3c0bc09`, `0145b82`, 本次 |

### 待用户操作

- **部署**：把 6 个文件复制到 Kindle 的 `koreader/plugins/fns_sync.koplugin/`（`api.lua` / `marker.lua` / `excerpt.lua` / `main.lua` / `config.lua`，加上前几次没改的其他文件保持不动）
- **测试**：跑测试场景 1（新格式同步 + 305 修复）→ 场景 2（合集 override）→ 场景 3（穿插编辑保留）→ 场景 4（删除高亮）

### 下次工作的候选优先级

| 编号 | 任务 | 启动条件 |
|---|---|---|
| 🧪 | 实测验证 + 修 bug | 用户部署后报告现象 |
| M5 | 自动同步（高亮/开书/关书事件）| 用户说"开始 M5" |
| 遗留 | `_rawRequest` 网络错误显示 `HTTP CLOSE NIL` | 用户说"修这个" |
| 需求 3 | 文件名格式 `《书名》-作者.md` | 纯配置，告诉用户改菜单即可，无需改代码 |

### 今天的关键技术发现（备忘）

1. **FNS 3D-RBAC**：Token scope 是 `p:<protocol> c:<client> f:<function>` 三维格式，Obsidian 用 ws、KOreader 用 rest，需要分开授权
2. **KOreader rapidjson 浮点输出**：把 Lua number（double）一律按 `xxx.0` 浮点字面量编码，Go int64 字段拒绝带小数点的 JSON 数字。`gsub("(%d)%.0([,}])", "%1%2")` 后处理是稳定的修复
3. **KOreader 菜单**：`text_func` + `enabled_func` 让菜单项动态刷新（保存后菜单立即显示新值，无需重启）
4. **`socket.skip(1, http.request(...))` 在网络错误时返回错误字符串**，会被上层误判为 HTTP code，需要 `type(code) == "string"` 防御（遗留 bug，未修）
