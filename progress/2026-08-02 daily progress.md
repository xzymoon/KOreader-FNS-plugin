# 2026-08-02 项目进度

## 今日工作概述

完成 **M1 里程碑**：插件骨架 + 完整菜单树 + 配置读写 + 测试连接。

今日新增文件：

```
E:\KOreader\plugin\fns_sync.koplugin\
├─ _meta.lua       (插件元数据，KOreader 自动加载)
├─ config.lua      (默认配置 + Marker 常量 + 笔记/摘录模板)
├─ api.lua         (HTTP 客户端：makeRequest 通用封装 + testConnection)
└─ main.lua        (WidgetContainer:extend + 完整菜单树 + 配置读写)
```

## 实施前调研结论（编码前必读 KOreader 源码）

通过 `git clone --depth=1 --filter=blob:none --sparse` 拉取 KOreader 源码（`/tmp/koreader-probe`），重点阅读：

### 1. `plugins/exporter.koplugin/main.lua`

- 插件继承 `WidgetContainer:extend{ name = "xxx" }`
- `init()` 内 `G_reader_settings:readSetting("plugin_name", {})` 读配置
- `addToMainMenu(menu_items)` 注册主菜单，菜单项可无限嵌套 `sub_item_table`
- `NetworkMgr:runWhenOnline(callback)` 异步等网络在线（**离线队列的现成基础设施**）
- `UIManager:nextTick(fn)` 把耗时操作放到下一帧执行，不阻塞 UI
- 配置存储惯例：`G_reader_settings:saveSetting("plugin_name", settings_table)`
- `Dispatcher:registerAction` 注册手势/快捷键（M5 用）

### 2. `plugins/exporter.koplugin/target/readwise.lua` + `base.lua`

- `BaseExporter:makeJsonRequest(endpoint, method, body, headers)` 完整封装 HTTP POST + JSON
- 底层栈：`socket.http` + `ltn12` + `rapidjson` + `socketutil`
- 超时：`socketutil:set_timeout(LARGE_BLOCK_TIMEOUT=10s, LARGE_TOTAL_TIMEOUT=30s)`
- 配置存储结构：`G_reader_settings.exporter["target_name"]`
- `InputDialog`：单字段输入（token 类）
- `MultiInputDialog`：多字段输入（文件名模板）

### 3. `frontend/apps/reader/modules/readerhighlight.lua` + `readerannotation.lua`

**核心事件**：`AnnotationsModified`（不是文档里猜的 `onAnnotationModified`）

触发位置：
- `readerhighlight.lua:2247` 添加新高亮（`saveHighlight`）
- `readerhighlight.lua:1043` 修改高亮边界（`updateHighlight`）
- `readerhighlight.lua:1325` 删除笔记

事件 payload：
```lua
Event:new("AnnotationsModified", {
    annotation,                -- annotation 对象（在 items[1]）
    nb_highlights_added = 1,
    index_modified = index,
    modify_datetime = ...,
})
```

**annotation 字段**（readerhighlight.lua:2225-2245）：

| 字段 | EPUB (rolling) | PDF (paging) |
|---|---|---|
| `page` | XPointer 字符串 | 页码数字 |
| `pos0/pos1` | XPointer | `{x, y, page}` |
| `pageno` | 由 XPointer 算出 | 同 page |
| `pageref` | 显示用页码 | 同 page |
| `text` | 选中文字 | 有文字层时有；扫描件为空 |
| `note/chapter/datetime/color/drawer` | 一致 | 一致 |
| `pboxes` | 无 | 矩形选区数组（PDF） |

→ 渲染统一用 `pageno`，`[p.123]` 对 PDF 也成立；扫描件 PDF（无文字层）暂不支持（M1 范围外）。

### 4. `frontend/ui/widget/inputdialog.lua`

**关键修正**：
- 字段是 `allow_newline`（不是 `multiline`）
- 标准模式：`save_callback` + `reset_callback`，KOreader 自动渲染 |Reset|Save|Close| 三按钮
- 不需要手写 buttons（最初我手写 buttons 是错的，已改）

### 5. `frontend/ui/widget/confirmbox.lua`

- 二次确认用 `ConfirmBox:new{text=, ok_text=, ok_callback=}`
- 比"输入 yes 确认"友好得多（最初我用 InputDialog 让用户输入 yes，已改）

### 6. `frontend/util.lua:1460`

- `util.urlEncode(url, preserve_chars)`：第二参数是"保留不编码的字符"，不是"要编码的字符"
- 不传第二参数时按 RFC 3986 默认行为（保留 `A-Z a-z 0-9 - . _ ~`）
- 最初我传错参数，已改

## 设计决策（在 2026-07-31 基础上今日新增）

### 决策 1：不做独立设置界面

KOreader 惯例是所有插件配置都通过主菜单的嵌套子菜单实现（参考 exporter 插件）。我们 11+ 项配置完全可以分组到树状菜单，无需独立"设置中心"。

好处：① 与其他 KOreader 插件风格一致；② 实现简单；③ Kindle 上方向键导航即可。

### 决策 2：增量同步，永不覆盖 Obsidian 端编辑

- 插件本地维护 `fns_sync_state.lua`，记录每本书已成功同步的 `annotation.datetime` 集合
- 同步策略：单条摘录渲染 → `note_replace` 在 `<!-- HIGHLIGHTS_END -->` marker 前插入
- 用户在 Obsidian 端的手动编辑永远不会被覆盖
- 代价：用户在 KOreader 端修改已同步摘录的笔记内容，Obsidian 端不会更新（合理取舍）

### 决策 3：摘录格式"双轨"可配置

- 简单用户：4 个开关（显示页码/笔记标记/章节二级标题/颜色 emoji）
- 高级用户：直接编辑"自定义摘录模板"字符串（占位符 `{page}` `{text}` `{note}` `{chapter}` `{datetime}` `{color}`）

### 决策 4：批量历史同步策略（盲点 3）

- 每本书一次 `note_replace` 调用（不是每条摘录一次）
- 串行执行，UI 显示进度"23/100"
- 单本失败入队，继续下一本
- 全部完成后 InfoMessage 汇总

### 决策 5：M1 范围

- ✅ 插件骨架（`_meta` + `main` + `config`）
- ✅ 完整菜单树（所有规划项，未来里程碑只填回调不改菜单结构）
- ✅ 配置读写（`G_reader_settings`）
- ✅ 测试连接（实际可用）
- ✅ 重置配置（实际可用）
- ⏸ 立即同步当前书（M3 实现，菜单项 disabled）
- ⏸ 立即同步全部历史（M6 实现，菜单项 disabled）

## M1 文件结构

### `_meta.lua`

```lua
local _ = require("gettext")
return {
    fullname = _("FNS Sync"),
    description = _("Sync highlights and notes to Obsidian via Fast Note Sync service."),
}
```

### `config.lua`

- `HIGHLIGHTS_START_MARKER` / `HIGHLIGHTS_END_MARKER`：HTML 注释 marker
- `DEFAULT_EXCERPT_TEMPLATE`：单条摘录模板（占位符 `{page}` `{text}` `{note}` `{chapter}` `{datetime}` `{color}`）
- `DEFAULT_NOTE_TEMPLATE`：完整笔记模板（含 `{{VALUE:xxx}}` 占位符 + Marker）
- `DEFAULT_COLOR_EMOJI_MAP`：颜色 → emoji 映射（待 M5 校准）
- `DEFAULTS`：所有用户可调设置及默认值

### `api.lua`

- `Api:makeRequest(settings, method, path, body, query)`：通用 HTTP 请求（GET/POST/PATCH）
- `Api:testConnection(settings)`：用 `GET /api/files?vault=<vault>&path=/` 探测，按 HTTP code 区分 URL/token/vault 错误

### `main.lua`

- `FnsSync:init()`：读 settings + backfill defaults + 注册主菜单
- `FnsSync:_editString(key, title, hint, allow_newline)`：通用输入对话框 helper
- `FnsSync:_toggleBool(key)`：通用开关切换 helper
- `FnsSync:onTestConnection()`：调 `Api:testConnection` + 显示结果
- `FnsSync:onResetConfig()`：ConfirmBox 二次确认 + 重置
- `FnsSync:onSyncCurrentBook()` / `onSyncAllHistory()`：M3/M6 占位
- `FnsSync:addToMainMenu(menu_items)`：完整菜单树

菜单结构（M1 完成版）：

```
FNS 同步
├─ 启用 FNS 同步           [开关]
├─ ───
├─ 立即同步当前书           [disabled, M3]
├─ 立即同步全部历史         [disabled, M6]
├─ 测试连接                 [实际可用]
├─ ───
└─ 设置
   ├─ 服务连接
   │   ├─ FNS 服务 URL
   │   ├─ API Token
   │   └─ Vault 名
   ├─ 笔记组织
   │   ├─ 笔记路径前缀
   │   ├─ 摘录章节标题
   │   └─ 笔记模板 (multiline)
   ├─ 摘录渲染
   │   ├─ 显示页码           [开关]
   │   ├─ 显示笔记标记       [开关]
   │   ├─ 章节二级标题       [开关]
   │   ├─ 颜色转 emoji       [开关]
   │   └─ 自定义摘录模板 (multiline)
   ├─ 触发模式
   │   ├─ 高亮即同步         [开关]
   │   ├─ 开书同步           [开关]
   │   ├─ 关书同步           [开关]
   │   └─ 防抖延迟（秒）
   └─ 高级
       ├─ 重置配置           [实际可用]
       └─ 关于
```

## 已知小问题（M1 不阻塞，后续里程碑修）

1. **`debounce_seconds` 是数字但用字符串存**：`_editString` 把它当 string 存。M5 实现防抖逻辑时改成 InputDialog 的 number 类型，或加 `tonumber` 校验。
2. **`color_emoji_map` 是 table 类型，按引用赋值**：M1 没有暴露编辑入口，所以不会污染 DEFAULTS。M5 加颜色映射编辑时需深拷贝。
3. **token 输入框未做 `text_type = "password"` 遮蔽**：Kindle 上单人使用不强制，M7 打磨时加。
4. **HTTPS 在 Kindle LuaSec 是否可用未验证**：M1 代码兼容 HTTPS（`socket.http` 自动处理），但 Kindle 镜像 LuaSec 实际可用性需 M7 实机测试。

## 验证情况

- ✅ **代码自审**：4 个文件全部读一遍，无语法错误、无遗漏 import、无未关闭的 block
- ✅ **API 调用对齐 KOreader 源码**：InputDialog / ConfirmBox / util.urlEncode / socketutil 全部对齐实际签名
- ✅ **菜单项闭包 bug 已修**：`local s = self.settings` 会在 `onResetConfig` 替换 self.settings 后失效，已改成全部直接读 `self.settings.xxx`
- ❌ **Lua 语法 lint**：开发机无 lua/luajit/luac，未做静态语法检查
- ❌ **KOreader 实机加载测试**：未部署到 Kindle 实测，M2 完成后一起测

## 待用户操作（可选）

如希望立即在 Kindle 上验证 M1（不强制，M2 完成后再测也可以）：

1. 把 `E:\KOreader\plugin\fns_sync.koplugin\` 整个目录拷贝到 Kindle 的 `/mnt/us/koreader/plugins/` 下
2. 重启 KOreader
3. 顶部菜单 → 工具 → 应出现"FNS 同步"
4. 进入"FNS 同步 → 设置 → 服务连接"，填 FNS URL / Token / Vault
5. 点"测试连接"应返回成功（前提：FNS 服务已部署且 `/api/files` 端点接受 `vault` + `path` 查询参数）

如果"FNS 同步"菜单没出现 → 说明 `_meta.lua` 或 `main.lua` 加载报错，需要看 KOreader 日志（`crash.log` 或 `koreader.log`）。

## 今日 git 操作

待 task #7 执行：commit M1 成果。

## 今日追加设计决策（M1 完成后讨论）

M1 完成后与用户对齐两个设计 gap。

### Q1：笔记文件名规则

**决策：B（用户可配置模板）+ sanitize**

- 在菜单"笔记组织"下将新增"笔记文件名模板"项（M3 加 UI；M2 api 已支持路径计算）
- 默认模板：`《{title}》读书笔记.md`
- 支持占位符：`{title}` `{author}` `{year}` `{language}` `{date}`
- `/` 在模板里表示子文件夹层级（如 `{author}/{title}.md` 按作者分子文件夹）
- 渲染后调 `util.getSafeFilename` 做 sanitize：替换 Windows 非法字符（`\ : * ? " < > |`）、剥路径穿越（`..`）、空 fallback `Untitled`

### Q2：标题语义

**决策：A（单标题分组）**

- 所有摘录统一加到用户配置的"摘录章节标题"下（默认 `# 摘录 ：`）
- 在该标题下的 marker 区（`<!-- HIGHLIGHTS_START -->` ... `<!-- HIGHLIGHTS_END -->`）内，按章节用 `## 第N章 章节名` 二级标题分组显示
- 整份笔记只有一对 marker，简化实现与 Obsidian 端维护

### Obsidian 兼容性结论

模板占位符替换**完全兼容** Obsidian：
- Obsidian 用底层文件系统，无额外字符限制
- 中文、空格、emoji 等任意合法字符都支持
- `[[文件名]]` 链接语法对合法字符无敏感
- KOreader 自己的 exporter 插件已用同样模式（`%D-%M %A - %T`）
- 唯一风险点（M3 必须处理）：书名/作者含 Windows 非法字符 → sanitize 替换为 `_`

### 示例文件名模板

| 模板 | 渲染结果（前缀 `KOReader/`） |
|---|---|
| `《{title}》读书笔记.md`（默认推荐） | `KOReader/《三体》读书笔记.md` |
| `{author}/{title}.md` | `KOReader/刘慈欣/三体.md` |
| `{year}/{title}.md` | `KOReader/2008/三体.md` |
| `{date}-{title}.md` | `KOReader/2026-08-02-三体.md` |

## M2 完成情况：完整 FNS HTTP 客户端

### FNS 服务源码调研结论（来自 `haierkeys/fast-note-sync-service`）

通过 `git clone --depth=1` 拉取源码，重点阅读：
- `internal/routers/router_api.go` —— 路由注册
- `internal/routers/api_router/handler_note.go` —— 笔记 handler
- `internal/dto/note_dto.go` —— 请求/响应 DTO
- `internal/service/note_service.go` —— 业务逻辑（含 ReplaceContent）
- `internal/middleware/user_auth_token.go` —— 鉴权中间件
- `pkg/app/app.go` —— 响应封装
- `pkg/code/common.go` —— 业务码定义

#### 关键发现 1：响应格式（重要修正 M1）

FNS 所有响应 HTTP code 都是 200，业务成败在 body 的 `code` 字段：

```json
{
    "code": 1,            // 1=Success, 2=Created, 3=Updated, 4=Deleted, 5/6 也是成功
    "status": "success",
    "message": "...",
    "data": {...},
    "details": "...",     // 错误详情（可选）
    "vault": "..."        // vault 名（可选）
}
```

→ M1 的 testConnection 按 HTTP code 区分错误（200/401/404）是错的，**已在 M2 修正**：解析 body 的 `code` 字段。

#### 关键发现 2：鉴权 header

FNS 支持三种 token 传递（`middleware/user_auth_token.go:38`）：
1. `Authorization: Bearer <token>` ✅（首选，我们 api.lua 已用）
2. `Token: <token>`
3. `?token=<token>` query 参数

可选校验（取决于 token 签发配置）：`x-client` header、`User-Agent`、绑定 IP。M2 阶段都不传。

#### 关键发现 3：业务错误码（`pkg/code/common.go`）

| code | 含义 | 我们如何用 |
|---|---|---|
| 1/2/3/4/5/6 | 成功 | `SUCCESS_CODES` 表 |
| 305 | 参数错误 | testConnection 提示 vault 名不合法 |
| 307 | 未提供 token | testConnection 提示 |
| 308 | token 无效 | testConnection 提示 |
| 310 | token 过期 | testConnection 提示 |
| 315 | scope 受限（vault 不属于该 token） | testConnection 提示 |
| 430 | note 不存在 | getNote 返回 exists=false；replaceNote 返回 not_found=true |
| 431 | note 已存在 | createNote 返回 already_exists=true |
| 442 | 无匹配（replace 时 find 未命中且 failIfNoMatch=true） | replaceNote 返回 no_match=true |
| 443 | 正则错误 | replaceNote 返回 invalid_regex=true |

#### 关键发现 4：DTO 字段（不再需要猜）

- `POST /api/note`（CreateOrUpdate）：`{vault, path, content, createOnly, ctime, mtime, ...}` —— **`createOnly=true` 时已存在则失败**
- `POST /api/note/replace`：`{vault, path, find, replace, regex, all, failIfNoMatch}` —— 返回 `{matchCount, note}`
- `GET /api/note`：query `{vault, path}` —— 返回 NoteDTO（含 `content`）
- `pathHash` 字段：服务端会自动计算（`if params.PathHash == "" { params.PathHash = util.EncodeHash32(params.Path) }`），客户端不必传
- `ctime/mtime`：服务端用毫秒（`time.Now().UnixMilli()`），客户端要 `os.time() * 1000`

#### 关键发现 5：路由清单（与笔记同步相关）

| Method | Path | Handler | 用途 |
|---|---|---|---|
| GET | `/api/note` | Get | 读单条笔记 |
| POST | `/api/note` | CreateOrUpdate | 创建/覆盖（createOnly 控制行为） |
| DELETE | `/api/note` | Delete | 删除 |
| POST | `/api/note/append` | Append | 追加到文件末尾 |
| POST | `/api/note/prepend` | Prepend | 加到开头 |
| POST | `/api/note/replace` | Replace | find/replace |
| PATCH | `/api/note/frontmatter` | PatchFrontmatter | 改 frontmatter |
| GET | `/api/files` | fileHandler.List | 文件列表（testConnection 用） |
| GET | `/api/notes` | noteHandler.List | 笔记列表 |
| GET | `/api/health` | healthHandler.Check | 健康检查（无 auth） |

### M2 文件改动

**`plugin/fns_sync.koplugin/api.lua`** 重写：

- 新增 `_rawRequest`（底层 HTTP 调用，无业务码解析）
- 重写 `makeRequest`：HTTP 调用 + 解析 body 的 `code` 字段，返回统一 result table
  ```
  { ok, network_error, http_code, biz_code, message, data, details }
  ```
- 重写 `testConnection`：按 biz_code 给具体友好提示（307/308/310/315/305 各自对应中文消息）
- 新增 `getNote(settings, path)` → `{ok, exists, content, note, ...}`，430 → exists=false
- 新增 `createNote(settings, path, content)` → `{ok, created, already_exists, ...}`，createOnly=true 保证不覆盖
- 新增 `replaceNote(settings, path, find, replace, opts)` → `{ok, match_count, not_found, no_match, invalid_regex, ...}`

### M2 设计要点

1. **`createOnly=true` 保护用户笔记**：创建笔记时永远 `createOnly=true`，已存在则返回 `already_exists=true`，由调用方决定 fallback（用 replace 或 append）。
2. **`failIfNoMatch=true` 让 marker 丢失暴露为可恢复错误**：M4 实现时如果用户在 Obsidian 端删了 marker，replaceNote 返回 `no_match=true`，调用方可以 fallback 到 `append`（追加到文件末尾）或提示用户。
3. **错误分层**：`network_error`（socket 失败）vs `http_code != 200`（反向代理/404/502）vs `biz_code != 1..6`（FNS 业务错误）—— 三层分开处理。
4. **`pathHash` 不传**：服务端会自动算，简化客户端逻辑。

### 验证情况

- ✅ **API 字段对齐 FNS 源码**：DTO、路由、错误码、鉴权 header 全部对齐实际实现
- ✅ **M1 testConnection 逻辑修正**：从 HTTP code 判断改为 body code 判断（兼容 M1 的菜单 UI，无需改 main.lua）
- ✅ **main.lua 不需改动**：M1 用 `result.success`/`result.message`，新 testConnection 返回兼容
- ❌ **本地 curl 验证 FNS 实际响应**：开发机未部署 FNS 服务，未实测；M7 Kindle 实机时一并验证
- ❌ **Lua 语法 lint**：开发机无 lua 解释器

### 待 M3 实现的内容

1. **`markdown.lua`** 模块：annotation → markdown 渲染
   - 渲染单条摘录（按用户模板 + 4 个开关）
   - 渲染整份笔记（按用户笔记模板 + 填充 `{{VALUE:书名}}` 等占位符）
   - 计算最终路径（路径前缀 + 文件名模板 + `util.getSafeFilename` sanitize）
2. **`main.lua` 实现 `onSyncCurrentBook`**：
   - 拿当前书的所有 annotations
   - 按 datetime 排序
   - 调 `getNote` 检查笔记是否存在
   - 不存在 → `createNote`（用默认模板）
   - 存在 → `replaceNote`（在 `<!-- HIGHLIGHTS_END -->` 前插入新摘录块）
3. **M3 验证标准**：手动触发"立即同步当前书"，Obsidian 端出现 `KOReader/《书名》读书笔记.md`，第二条摘录正确追加到 marker 前不覆盖首条

## M3 完成情况：渲染 + 端到端同步

### 策略调整（重要）

原 M3 计划用 FNS 的 `regex=true` replace 来精确替换 marker 区。审查后发现 3 个问题，**改用方案 B**：

- ❌ FNS 用 Go RE2 正则，`.` 默认不匹配换行（需要 `(?s)`），多行 marker 区匹配不可控
- ❌ marker 丢失时 fallback 不灵活（regex 失败就是失败，客户端没法智能补救）
- ❌ 性能与可移植性差（依赖服务端正则库版本）

**改为方案 B（GET → Lua 字符串替换 → POST 覆盖）**：

```
1. Api:getNote(path)              拿当前笔记 content
2. Lua: string.find(content, marker, 1, true)  ← plain 字面匹配
   找到 marker 区起止位置
3. Lua: 字符串拼接构造新 content（替换 marker 区，区外原样保留）
4. Api:overwriteNote(path, new_content, original_ctime)  写回
```

好处：不依赖 FNS 正则行为；marker 丢失时可在客户端做 fallback（M3 先报错，M7 加智能补救）；性能更好。

### M3 文件改动

```
plugin/fns_sync.koplugin/
├─ excerpt.lua        (新增 9.8K)  渲染 + 路径计算（5 个方法）
├─ api.lua            (改)         新增 overwriteNote（createOnly=false，保留原 ctime）
├─ config.lua         (改)         新增 note_filename_template 字段
└─ main.lua           (改)         实现 onSyncCurrentBook + _doSyncCurrentBook + _getBookMetadata + _showSyncError
                                   新增"笔记文件名模板"菜单项
                                   解除"立即同步当前书"的 disabled
```

### excerpt.lua 五个核心方法

| 方法 | 作用 |
|---|---|
| `renderExcerpt(ann, settings)` | 单条 annotation → markdown 字符串（按用户模板 + 4 个开关） |
| `renderExcerptBlock(anns, settings)` | 所有摘录按 datetime 排序、按 chapter 分组拼成一个字符串 |
| `renderFullNote(anns, settings, meta)` | 完整笔记（默认模板 + 填充 `{{VALUE:书名}}`/`{{VALUE:作者}}`/`{{VALUE:语言}}` + 摘录块插入 marker 区） |
| `replaceMarkerZone(content, block)` | 在现有笔记内容里替换 marker 区，区外原样保留 |
| `resolvePath(settings, meta)` | 计算最终路径（前缀 + 模板渲染 + 按 `/` 分割逐段 sanitize + 拼回） |

### 关键调研结论（写代码前查证）

1. **KOreader `doc_props` 字段**：`title / authors / series / series_index / language / keywords / description / pages` —— **没有 year 和 publisher**。所以模板里 `{{VALUE:出版社}}` `{{VALUE:年份}}` `{{VALUE:阅读开始}}` 保留原样，由用户在 Obsidian 端用 Templater/QuickAdd 填。

2. **`util.getSafeFilename(str)` 不传 path 时按 VFAT 严格模式**：替换 `\ / : * ? " < > |` 等 9 个 Windows 非法字符。但 **会把 `/` 也替换掉**（它假设输入是单文件名）。所以路径模板 `{author}/{title}.md` 必须先按 `/` 分割成多段，每段单独 sanitize，再拼回。

3. **FNS `ModifyOrCreate` 第 445 行**：`note.Ctime = params.Ctime` 无条件覆盖。所以 `overwriteNote` 必须传 `original_ctime`，否则 ctime 会被覆盖为 0 或当前时间（破坏原笔记的创建时间）。

4. **KOreader 插件 `require` 命名空间不隔离**（`pluginloader.lua:285`）：所有插件路径永久加到 `package.path`。所以 `require("markdown")` 会和 `exporter.koplugin/markdown.lua` 冲突（取决于加载顺序）。**改名为 `excerpt.lua`** 规避。

5. **Lua pattern 不是正则**：`{` `}` 是 pattern 字符。`string.gsub` 的 replacement 也支持 `%` 元字符。所以**不能用 gsub 替换 `{page}` 这种占位符**——用 `string.find(s, needle, init, true)`（plain 字面匹配）+ 手动拼接代替。excerpt.lua 里 `safeReplace` helper 实现这个。

### 同步流程（main.lua 的 onSyncCurrentBook）

```
1. 检查 enabled + isConfigured() + annotations 非空
2. meta = _getBookMetadata()  (title/author/language)
3. path = Excerpt:resolvePath(settings, meta)
4. NetworkMgr:runWhenOnline(...) 异步执行
5. excerpt_block = Excerpt:renderExcerptBlock(annotations, settings)
6. get_result = Api:getNote(path)
7. if not exist → Api:createNote(path, renderFullNote(meta))
   if exists   → new_content = Excerpt:replaceMarkerZone(content, excerpt_block)
                 Api:overwriteNote(path, new_content, original_ctime)
                 marker 丢失 → 提示用户检查 Obsidian 端
```

### Known Limitations（M3 不修，记下来给 M7）

1. **关闭"显示页码"时模板里 `[p.{page}]` 会残留 `[p.]`**：占位符替换为空字符串，但方括号不会跟着消失。用户可改模板为 `> {text}`（不带 `[p.]`）规避。
2. **关闭"显示笔记标记"时 `{note}` 行变空行**：模板里 `{note}` 通常单独一行，关闭后这行残留为空行。影响小。
3. **`{color}` 占位符默认模板里没用**：默认 excerpt_template 没引用 `{color}`，所以颜色信息当前不显示。需要颜色的用户自行在模板里加 `{color}`。
4. **`color_emoji_map` 是引用赋值**：M1 已记录的 TODO，M5 加颜色映射编辑入口时需深拷贝。

### 验证情况

- ✅ **代码自审**：4 个文件通读一遍，所有改动一致生效
- ✅ **API 调用对齐**：`overwriteNote` 字段（`createOnly=false` + 传 `ctime`）对齐 FNS `ModifyOrCreate` 第 445 行的行为
- ✅ **路径 sanitize 顺序**：先 `/` 分割再每段 sanitize，不会破坏子文件夹层级
- ✅ **占位符替换**：用 `string.find(plain=true)` 避免 Lua pattern 误解 `{` `}`
- ❌ **Lua 语法 lint**：开发机无 lua 解释器
- ❌ **端到端实测**：M3 完成后用户在 Kindle 上一次性实测

### 跳过的内容（原 M4）

原里程碑 M4"模板 + marker + replace 精确追加"——M3 已经实现了 marker 区"覆盖写"（每次同步重写 marker 区为最新所有摘录）。这比"精确追加"更简单且一致：

- 用户在 KOreader 端删了一条高亮 → 下次同步后 Obsidian 端对应摘录也消失（合理）
- 用户在 marker 区内的编辑会被覆盖（marker 区是"自动管理区"，应在区外做笔记）

如果未来用户反馈需要"在 marker 区内的手动编辑不被覆盖"，再做 M4 精确追加（基于 datetime set 去重，只追加新的，不重写老的）。

### 待 M5 实现（下一步）

- 订阅 KOreader 的 `AnnotationsModified` 事件
- 高亮即同步（debounce 3 秒，避免连续高亮时多次 HTTP 请求）
- M5 验证标准：加一条新高亮 → 几秒内 Obsidian 端笔记自动更新

## 追加改动：logger 调用便于实测诊断

### 目的

M3 完成后用户即将做 Kindle 实测。原代码只在 `api.lua` 一处用了 `logger.warn`，同步失败时 InfoMessage 只在屏幕显示几秒就消失，crash.log 里没记录，用户难以截屏发我。

为方便诊断，**给 main.lua / excerpt.lua / api.lua 加了 logger 调用**，全部带 `[FNS]` 前缀写入 `/mnt/us/koreader/crash.log`。实测出问题时，用户只需把 crash.log 发我，grep `[FNS]` 即可还原现场。

### 加在哪些位置（共 13 处）

**api.lua**（4 处，集中在 `makeRequest`）：
- 网络错（`http_code == nil`）
- 非 200 HTTP（反向代理 5xx）
- 非 JSON 响应（服务端异常 HTML）
- 成功（含 biz_code + message + details）

**excerpt.lua**（3 处）：
- `resolvePath` 返回前：记录最终路径
- `renderExcerptBlock` 返回前：记录摘录数 + 字符数
- `replaceMarkerZone` marker 丢失时（START / END 分别记）

**main.lua**（6 处）：
- `_showSyncError`：所有同步失败的统一日志（biz_code 或 network_error）
- `onSyncCurrentBook`：同步开始（title/author/annotations/path）
- `_doSyncCurrentBook` 各分支：
  - 进入 exists 分支（替换 marker 区）
  - 进入 not exists 分支（创建新笔记）
  - overwrite 成功 / create 成功（含 N 条摘录 + 路径）
  - already_exists race condition（罕见但记录）

### 怎么从 crash.log 找 FNS 相关日志

USB 连 Kindle 后，把 `/mnt/us/koreader/crash.log` 拷到电脑，用任意文本编辑器打开，搜索 `[FNS]`（带方括号），可看到所有 FNS Sync 插件相关的日志。

样例（一次成功的同步）：
```
... INFO  [FNS] resolved path: KOReader/《三体》读书笔记.md
... INFO  [FNS] rendered 12 annotations to excerpt block (4523 chars)
... INFO  [FNS] sync current book: title=三体 author=刘慈欣 annotations=12 path=KOReader/《三体》读书笔记.md
... INFO  [FNS] GET /api/note biz_code=1 msg=
... INFO  [FNS] note does not exist, creating new
... INFO  [FNS] POST /api/note biz_code=2 msg=
... INFO  [FNS] sync success: created note with 12 annotations at KOReader/《三体》读书笔记.md
```

样例（同步失败：marker 丢失）：
```
... INFO  [FNS] sync current book: ...
... INFO  [FNS] GET /api/note biz_code=1
... INFO  [FNS] note exists, replacing marker zone
... WARN  [FNS] HIGHLIGHTS_START marker missing in note content
```

样例（同步失败：网络错）：
```
... INFO  [FNS] sync current book: ...
... WARN  [FNS] GET /api/note network error: connection refused
... WARN  [FNS] sync error (network): connection refused
```

## 代码审查 + 6 个修复（M3 后）

M3 完成后做了一次完整代码审查（自己通读 + code-reviewer agent 独立交叉验证），共发现 6 个真实问题。已全部修复。

### 审查方法

1. **自己通读**：5 个 lua 文件全部读一遍，对照 FNS 服务源码（`/tmp/fns-service`）和 KOreader 源码（`/tmp/koreader-probe`）验证 API 用法
2. **code-reviewer agent 独立审查**：让它不带任何上下文审查，找 Lua 陷阱和潜在 bug
3. **交叉验证**：agent 报的 CRITICAL（`getSafeFilename` 会替换 `《》`）实测源码后是**误报**——`util.lua:962` 只替换 9 个 Windows 非法字符 `[\\/:*?"<>|]`

### 修复清单

| # | 严重度 | 问题 | 修复方式 |
|---|---|---|---|
| 1 | HIGH | `highlights_section_title` 配置完全没用到（设计 gap：菜单能改但不生效，标题实际硬编码在 note_template 里） | 删除 config 字段 + 菜单项，标题统一在 note_template 里改 |
| 2 | HIGH | 路径穿越防御不完整：`..` 经过 getSafeFilename 后变空字符串，但没二次过滤，`../etc/passwd` 可能拼成 `/etc/passwd` | resolvePath 在 sanitize 后再次过滤空 segment |
| 3 | MEDIUM | URL 拼接双斜杠：用户配 `server_url` 末尾带 `/` 时拼出 `//api/files` | `buildUrl` 先 `base:gsub("/+$", "")` 去尾斜杠 |
| 4 | MEDIUM | testConnection 用 `/api/files?vault=&path=/`，但 FNS 的 `FileListRequest` DTO **没有 path 字段**（被静默忽略），语义不对 | 改用 `/api/notes?vault=<vault>`（笔记列表），更贴近使用场景 |
| 5 | MEDIUM | 模板不带 `.md` 后缀时路径无扩展名，Obsidian 端不识别为 markdown | resolvePath 自动补 `.md`（仅当最后一段无 `.` 时） |
| 6 | MEDIUM | prefix 开头带 `/` 时变绝对路径（如 `/KOReader/三体.md`） | normalize prefix：去掉首尾 `/`，统一中间用单 `/` |

### 文件改动

```
plugin/fns_sync.koplugin/
├─ config.lua  (-1 行)   删除 highlights_section_title 字段
├─ main.lua    (-9 行)   删除"摘录章节标题"菜单项
├─ api.lua     (+8 -5)   buildUrl normalize + testConnection 改 /api/notes
└─ excerpt.lua (+25 -16) resolvePath 重写（含路径穿越防御 + .md 自动补 + prefix normalize）
```

### 修复后的 resolvePath 完整流程

```
1. 模板占位符替换（{title} {author} {language} {year} {date}）
2. split "/" 成 segments
3. 每个 segment：
   a. trim 首尾空白
   b. 非空 → util.getSafeFilename(seg)
   c. sanitize 后仍非空 → 加入 segments（**这是 fix #2 的关键**）
4. join "/" 成 path
5. path 为空 → fallback "Untitled"（极边角情况）
6. 最后一段无 `.` → 自动补 ".md"（fix #5）
7. normalize prefix：去首尾 `/`（fix #6）
8. prefix 非空 → path = prefix .. "/" .. path
```

### 验证场景

| 输入 | 修复前 | 修复后 |
|---|---|---|
| `prefix="KOReader/"`, `template="《{title}》读书笔记.md"`, `title="三体"` | `KOReader/《三体》读书笔记.md` | 同（行为不变） |
| `prefix="KOReader/"`, `template="{title}"`, `title="三体"` | `KOReader/三体`（无扩展名） | `KOReader/三体.md` ✅ |
| `prefix="/KOReader/"`, `template="{title}.md"`, `title="三体"` | `/KOReader/三体.md`（绝对路径） | `KOReader/三体.md` ✅ |
| `prefix="KOReader/"`, `template="{author}/{title}.md"`, `author="../etc"`, `title="passwd"` | `KOReader//etc/passwd.md`（穿越） | `KOReader/etc/passwd.md` ✅（路径被钳制在 vault 内） |
| `prefix="KOReader/"`, `template="{title}.md"`, `title=""` | `KOReader/.md` | `KOReader/Untitled.md` ✅ |

### agent 误报说明

- ❌ agent 报 CRITICAL：`getSafeFilename` 会替换 `《》` 和 `()` → 实测 `util.lua:962` 只替换 `[\\/:*?"<>|]` 9 个字符，`《》` 安全保留
- ✅ agent 报 HIGH：`debounce_seconds` 类型问题 → 真实，但 M5 才用到，留到 M5 修
- ✅ agent 报 MEDIUM：response 大小无限制 → 真实但低风险，M7 加防护

### 是否达到最初目的评估

| 用户目的 | 当前状态 |
|---|---|
| ① 高亮/笔记发送到 FNS | ✅ onSyncCurrentBook 完整实现 |
| ② FNS 中转到 Obsidian | ✅ 通过 FNS `/api/note` |
| ③ 用户指定格式 | ✅ 摘录模板 + 4 开关 + 笔记模板 |
| ④ 用户指定目标文件/文件夹 | ✅ note_path_prefix + note_filename_template（路径穿越已防御） |
| ⑤ 添加到哪个文档标题 | ✅ 通过编辑 note_template 控制（修复 #1 后单一来源） |
| ⑥ 自动发送（高亮即同步） | ❌ M5 内容（订阅 AnnotationsModified 事件） |

**结论**：M1-M3 + 本次审查修复已覆盖目的 ①-⑤。⑥ 必须等 M5。

## Kindle 实测情况（部分）+ sorting_hint 修复

用户把插件拷到 Kindle 并重启 KOreader 后，做了第一次实测：

### 实测发现

✅ **插件被 KOreader 识别**：
- 工具 → 更多工具 → 插件管理 → 用户插件 → 出现 "FNS Sync"
- 长按显示 description："Sync highlights and notes to Obsidian via Fast Note Sync service."
- 说明 `_meta.lua` 加载成功，PluginLoader 注册正常

❌ **工具菜单下看不到"FNS 同步"入口**：
- 用户在工具菜单的各个子菜单里都找不到
- 只能在"插件管理"里看到（那是 KOreader 列出所有已加载插件的界面，不等于菜单注册成功）

### 根因调查

读 KOreader 源码 `frontend/ui/menusorter.lua:161-186` 发现：

KOreader 用 `MenuSorter` 模块对所有 `menu_items` 分类。规则：
- 菜单项如果**没在 order 配置里被引用 + 没 `sorting_hint` 字段** → 当 orphaned 处理
- orphaned 项加 `"NEW: "` 前缀（`menusorter.lua:15`），扔到第一个 tab

我们的 `menu_items.fns_sync` **没设 `sorting_hint`**，所以变成 orphaned，掉到了用户找不到的角落。

参考 `plugins/terminal.koplugin/main.lua:529`（虽然被注释了）：
```lua
-- sorting_hint = "more_tools",
```

证实了 sorting_hint 的用法：值是某个已存在 menu item 的 id（如 `tools` / `more_tools`）。

### 修复

`main.lua:addToMainMenu` 里给 `menu_items.fns_sync` 加一行：

```lua
menu_items.fns_sync = {
    text = _("FNS 同步"),
    sorting_hint = "tools",   -- ← 新增，让菜单显示在"工具"tab 下
    sub_item_table = { ... }
}
```

commit `439e8cc`。

### 实测暂停

修复后用户未做第二次实测（明天继续）。明天测试步骤：

1. **只重拷 main.lua**（其他 4 个文件没动）到 Kindle 的 `/mnt/us/koreader/plugins/fns_sync.koplugin/main.lua`
2. 完全退出 KOreader 后重启
3. 打开一本书 → 工具菜单 → 应出现"FNS 同步"
4. 按之前规划的 3 阶段测试：
   - 阶段 2：配置 URL/Token/Vault + 测试连接
   - 阶段 3：启用 + 立即同步当前书
5. 出问题把 `/mnt/us/koreader/crash.log` 拷回来 grep `[FNS]`

## 今日 git 操作汇总

7 个 commit（按时间顺序）：

| commit | 内容 |
|---|---|
| `f29b9b8` | M1：插件骨架 + 完整菜单树 + 测试连接 |
| `46314da` | M2：基于 FNS 源码重写 HTTP 客户端 + 三高层方法 |
| `f805c1d` | M3：渲染 + 端到端单本书同步 |
| `b76ecb8` | 加 logger 调用便于 Kindle 实测诊断 |
| `8e35572` | 代码审查后修复 6 个问题（HIGH/MEDIUM） |
| `439e8cc` | fix：菜单不显示——加 sorting_hint = "tools" |

工作目录 clean，所有改动已 commit。

## 待用户确认事项

无（M1 范围全部按既定方案完成）。
