# 2026-07-31 项目进度

## 今日工作概述

今天**未改任何代码**，全部是调研与方案设计。目标是论证"把 KOreader 高亮/摘录自动同步到 Obsidian 笔记库"的可行路径，并选定实现方案。

## 项目目标

让 Kindle 上的 KOreader 摘录/高亮，在联网时自动同步到 Obsidian 笔记库（通过自托管的 Fast Note Sync 服务），按书籍生成/追加到指定的读书笔记中，省去手工整理。

## 调研结论

### 1. Unearthed 项目（https://github.com/Unearthed-App）

- **不是单体应用**，是云服务生态：`KOreader Lua 插件 → Unearthed 云端（Next.js + Postgres + Clerk + AWS Amplify）→ Obsidian 插件`。
- `unearthed-local`（桌面端 Local 模式）**闭源**。
- KOreader 端 Lua 插件读 `.sdr/custom_metadata.lua` + `metadata.lua`（Lua table，非 SQLite），POST 到云端。
- Obsidian 端插件用 `app.vault` API 直接写 Vault 文件，无 REST API 抽象。
- 输出端零抽象（`unearthed-obsidian/main.ts` 单文件 ~1300 行），改造成本可控。
- **结论：Unearthed 在我们要做的链路里是冗余的"中间商"，不采纳。**

### 2. Fast Note Sync（FNS）项目（https://github.com/haierkeys）

- **双仓库架构**：
  - `haierkeys/obsidian-fast-note-sync` 仅是 Obsidian 客户端插件
  - **`haierkeys/fast-note-sync-service`**（Go + Gin + WebSocket，~2k stars）才是后端，HTTP/MCP 都在这里
- **REST API 关键端点**（base URL `http://host:9000/api`，鉴权 `Authorization: Bearer <token>`）：
  - `POST /api/note`：创建/整体覆盖笔记，body `{vault, path, content, ...}`
  - `POST /api/note/append`：**追加到文件末尾**（DTO 字段 `{vault, path, content}`，无定位参数）
  - `POST /api/note/prepend`：加到开头
  - `POST /api/note/replace`：**find/replace 模式**（`{vault, path, find, replace, regex, all, failIfNoMatch}`）—— 这是实现"在特定标题下插入"的关键能力
  - `PATCH /api/note/frontmatter`、`GET /api/note`、`POST /api/folder`、`/api/files` 等
- **原生 MCP**：`/api/mcp`（StreamableHTTP）+ `/api/mcp/sse`，工具覆盖 note/file/folder/vault 全套（本项目暂不使用 MCP，直接用 REST 更轻）
- 自托管、Apache-2.0、无外部账号依赖
- 部署：用户已部署在 NAS + 公网域名 + HTTPS

### 3. KOreader 项目（https://github.com/koreader/koreader）

- **摘录存储**：每本书旁的 `<bookname>.sdr/metadata.<ext>.lua`（Lua table 序列化，非 SQLite）。新版统一在 `annotations` 数组里，单条字段：`datetime / page / pos0/pos1 / text / note / drawer / color / chapter`。
- **官方 exporter 框架**（`plugins/exporter.koplugin/`）：
  - `base.lua` 提供 `BaseExporter:makeJsonRequest(endpoint, method, body, headers)` —— HTTP POST + JSON 编解码全封装
  - `target/readwise.lua` 是 108 行的极简 HTTP 同步参考
  - 触发方式只有**手动菜单 / Dispatcher 手势**，**没有事件订阅钩子**（不支持"高亮即同步"）
  - target 列表在 `main.lua` L79-89 硬编码注册
- **关键判断**：要实现"高亮即同步"，必须**写独立 `koplugin`**，不能只用 target。

## 方案决策

最终方案：**写独立 koplugin（不走 Unearthed，也不走 exporter target）**，直接 KOreader → FNS → Obsidian Vault。

链路：`KOreader 高亮事件 → koplugin 监听 → 渲染 markdown → FNS API（replace + marker 精确插入）→ Obsidian 笔记`

### 用户拍板的关键偏好

1. **写入策略**：追加式（保留 Obsidian 端手动编辑）→ 用 FNS `note_replace` + HTML 注释 marker 实现"在某标题下追加"，而非 `note_append`（只能加文件末尾）
2. **触发档位**：高亮即同步（订阅 KOreader 高亮事件）
3. **笔记组织**：指定文件夹 + `《书名》读书笔记.md` + 摘录追加到 `# 摘录 ：` 标题下；按章节用 `## 第N章 章节名` 二级标题分组（轻量分组方案）

### 笔记模板（用户指定）

```
# 📖 《 {{VALUE:书名}} 》读书笔记

## 📌 书籍信息
- **书名**：《 {{VALUE:书名}} 》
- **作者**： {{VALUE:作者}}
- **出版社**： {{VALUE:出版社}}
- **出版年份**： {{VALUE:年份}}
- **阅读状态**: 在读/读完/待整理
- **阅读开始**: {{VALUE:阅读开始}}
- **阅读结束**: 
- **评分**: ⭐⭐⭐⭐⭐
---



# 摘录 ：

```

实施时在 `# 摘录 ：` 后插入两个 HTML 注释 marker：`<!-- HIGHLIGHTS_START -->` 和 `<!-- HIGHLIGHTS_END -->`，所有摘录插入到两 marker 之间。

### 字段填充策略

- 替换 `{{VALUE:书名}}`、`{{VALUE:作者}}` 为 KOreader 实际值
- 其他 `{{VALUE:xxx}}`（出版社、年份、阅读开始等）**保留原样**，用户在 Obsidian 端用 Templater/QuickAdd 处理
- KOreader 没有这些字段，不强行填充

### 单条摘录渲染格式（建议默认，待 Q1 确认）

```
## 第十章 章节名    ← 仅当与上一条摘录章节不同时输出

> [p.123] 摘录原文

**笔记**：用户批注
<!-- H:2025-07-31-14-30-00 -->
```

## 实施规划（已定稿，未开始编码）

### 目录结构

```
E:\KOreader\
├─ plugin\
│   └─ fns_sync.koplugin\         # 部署到 Kindle 的 ~/.local/share/koreader/plugins/
│       ├─ _meta.lua
│       ├─ main.lua               # WidgetContainer:extend，UI 菜单 + 事件订阅
│       ├─ config.lua             # 默认配置常量
│       ├─ api.lua                # FNS HTTP/HTTPS 客户端
│       ├─ markdown.lua           # annotation → markdown 渲染
│       ├─ dedupe.lua             # 去重（本地状态 + 远程 marker 检查）
│       └─ event_handler.lua      # 事件订阅 + 触发同步
├─ docs\
└─ progress\
```

### 里程碑

| M | 内容 | 验证标准 |
|---|---|---|
| M1 | 骨架 + 配置 UI（`_meta` + `main` + `config`） | 插件在 KOreader 加载，菜单能配 token/URL/vault |
| M2 | FNS HTTP/HTTPS 客户端（`api.lua`） | "测试连接"菜单按钮返回成功 |
| M3 | 手动同步单本书（按钮触发，整份笔记覆盖写） | Obsidian 出现 `KOReader/《书名》读书笔记.md` |
| M4 | 模板 + marker + replace 精确追加 | 第二条摘录正确插入到 marker 前，不覆盖首条 |
| M5 | 事件订阅 + 高亮即同步 | 加高亮 → 几秒内 Obsidian 文件出现新摘录 |
| M6 | 去重 + 离线队列 | 同一高亮重复触发不重复写入；离线加高亮 → 联网后补传 |
| M7 | 打磨：错误提示、日志、配置细化 | Kindle 实机测试一遍 |

### 配置项（KOreader UI 菜单）

启用开关 / FNS 服务 URL / API Token / Vault 名 / 笔记路径前缀（默认 `KOReader/`）/ 摘录章节标题（默认 `# 摘录 ：`）/ 触发模式（高亮即同步 / 开书同步 / 关书同步）/ 章节二级标题开关 / 颜色转 emoji（默认关）/ 立即同步当前书 / 立即同步全部历史 / 测试连接。

## 实施前还需读源码确认（不算猜测，是要读的）

1. **KOreader 高亮事件名**：精确名称（猜测 `onAnnotationModified` / `onHighlightAdd`），需读 `frontend/apps/reader/modules/readerhighlight.lua` 和 `readerannotation.lua`
2. **annotation 对象字段**：传给事件回调的对象上能拿到哪些字段
3. **LuaSec 在 Kindle 镜像里的可用性**：影响 HTTPS 写法（用户走公网域名必须 HTTPS）

## 待用户确认事项（明天接续时第一件事）

- **Q1**：单条摘录格式中的 `[p.123]` 页码标记和 `**笔记**：` 批注标记，是否需要调整？（如 `[note]:`、`💡 笔记：`、不加页码等）
- **Q2**：颜色转 emoji 是否开启？

## 今日 git 操作

**今天无 git 操作**。
- 工作目录 `E:\KOreader` 当前不是 git 仓库
- 按 CLAUDE.md 第 5 条"代码改动后必须 git"——今日未改任何代码（全为调研与规划讨论），故无需 commit
- 明日开始写代码（M1）前，**先 `git init`** 初始化仓库，把首个里程碑的代码和本进度文档一起作为首次 commit

## 明日计划

1. 先把 Q1 / Q2 与用户对齐（决定摘录渲染细节）
2. `git init` 初始化仓库，建立 `.gitignore`（排除 `.claude/` 等）
3. 读 KOreader 源码确认高亮事件名和 annotation 字段（实施前必做）
4. 进入 M1：写 `_meta.lua` + `main.lua` 骨架 + `config.lua`，确保插件能在 KOreader 加载
