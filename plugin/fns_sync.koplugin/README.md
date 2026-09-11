# FNS Sync — KOreader Plugin

把 KOreader 里的高亮和笔记同步到 Obsidian（通过 [Fast Note Sync](https://github.com/haierkeys/fast-note-sync-service) 服务）。

## 功能

- 手动触发同步当前书的所有高亮
- 条目级 marker 机制（HL@ 块），用户在 Obsidian 端穿插编辑的内容会被保留
- 每本书可独立 override title / author（合集场景）
- 自定义摘录模板、笔记模板、文件名模板
- 跨书籍多端同步，支持 REST API（与 FNS 服务端通信）

## 安装

把整个 `fns_sync.koplugin/` 目录复制到 KOreader 的 `plugins/` 目录：

- **Kindle**：`/mnt/us/koreader/plugins/fns_sync.koplugin/`
- **其他设备**：参考 KOreader 文档的插件路径

复制后重启 KOreader。

## 配置

进入 **KOreader 顶部菜单 → 工具 → FNS 同步**：

1. **启用 FNS 同步**（主开关）
2. **设置 → 服务连接**：填 FNS 服务 URL、API Token、Vault 名
   - Token 需在 FNS WebGUI 创建，scope 必须包含 `p:rest c:koreader f:note_r,note_w`
3. **设置 → 笔记组织**：路径前缀、文件名模板、笔记模板
4. **设置 → 摘录渲染**：页码、章节标题、颜色 emoji、自定义摘录模板
5. **当前书信息**：为本本书独立 override title/author
6. **立即同步当前书**：触发同步

## 自动同步（M5）

启用后，以下操作会**自动触发**同步，不需要手动按钮：

- 划线 / 改笔记（debounce 5 秒合并连续操作）
- 关书（立即触发）

设置路径：**工具 → FNS 同步 → 自动同步**

| 子项 | 默认 | 说明 |
|------|------|------|
| 启用自动同步 | 开 | 总开关（在主开关 `enabled` 之下）|
| 高亮修改时同步 | 开 | 划线 / 改笔记触发 |
| 关闭书籍时同步 | 开 | 关书事件触发 |
| 同步延迟（秒） | 5 | debounce 时长，避免狂划线时频繁请求 |

离线时自动同步会**静默跳过**（不弹 WiFi 对话框），高亮数据由 KOreader 本地 `metadata.lua` 保存。如果启用了离线队列（见下节），下次联网会自动补推。

## 离线队列（M6）

启用后，离线期间的高亮修改会进入**持久化队列**，联网后自动补推，不丢数据。

设置路径：**工具 → FNS 同步 → 离线队列**

### 行为

| 触发场景 | 行为 |
|---------|------|
| 离线 + 划线 / 改笔记 | 入队（按书 path 去重，同一本书多次修改只占一条）|
| 联网（自动检测 WiFi 连接） | 触发队列处理 |
| 开书 / 关书 / 手动同步 | 兜底触发（防止联网事件漏掉）|
| 单条同步失败 | 重试，连续 5 次失败冻结 |
| Token 失效（FNS code 307/308） | 立即冻结所有条目 + 弹一次性 toast 提示 |
| 重启 KOreader | 队列保留（持久化在 settings.lua）|

### 子菜单

- **启用离线队列**：总开关
- **待同步队列（N 本）**：查看队列详情，每条显示书名 + 失败次数 / 冻结状态
- **重试冻结条目**：手动重置冻结条目的失败计数，立即触发处理
- **清空队列**：放弃所有待同步状态（高亮本身仍保留在 `metadata.lua`，但不再自动同步到 Obsidian）

### 队列条目的生命周期

```
入队 (offline + 划线)
  ↓
等待联网事件 / 兜底触发
  ↓
处理（串行，按 ts 早晚）
  ├─ 成功 → 移除条目
  ├─ 失败 → attempts++
  │         ├─ < 5 次：保留，等下次触发
  │         └─ ≥ 5 次：冻结（不再自动重试）
  ├─ Token 失效 → 全部队列冻结 + toast
  └─ 书文件丢失 → 立即移除（不消耗 attempts）
```

### 隐私

队列存储在 KOreader 全局配置 `settings.reader.lua` 的 `fns_sync_queue` 字段，包含书 path + title（属于个人阅读信息），**不包含 token 等敏感凭据**。KOreader 全局配置备份时此字段会被一起带走，请知悉。如不希望使用此功能，可在菜单关闭。

## HL@ 块结构（重要）

每条 KOreader 高亮在 Obsidian 笔记里被包裹成一个 HL@ 块：

```
<!-- HL@<datetime> -->
## <chapter>
> 📖 第 <page> 页
> <highlighted text line 1>
> <highlighted text line 2>
<!-- /HL@<datetime> -->
```

- `datetime` 是这条高亮在 KOreader 里的创建时间戳（唯一 key）
- 整个块（从 `<!-- HL@ts -->` 到 `<!-- /HL@ts -->`）在同步时会被 diff 检测并按需更新/删除

## 安全编辑区（在 Obsidian 端手动编辑时必读）

```
笔记文件
│
├─ ✅ 笔记头部（SAFE）              自由编辑
│  # 标题、frontmatter、书籍信息
│  # 摘录 ：
│
├─ 🔴 HL@ 块 1（DANGER — 勿改内部）
│  <!-- HL@ts -->                  ← marker 行，勿动
│  ## 章节标题
│  > 📖 第 N 页
│  > 摘录正文
│  <!-- /HL@ts -->                 ← marker 行，勿动
│
├─ ✅ 块间区（SAFE，推荐）           ← 感想写这里
│  💡 在两条摘录之间穿插写感想
│
├─ 🔴 HL@ 块 2（DANGER — 勿改内部）
│  ...
│
└─ ✅ 笔记尾部（SAFE）              ← 总评写这里
```

### 简单记忆

> **marker 行不动，块内不动，块外随便写。**

### 禁区原因

- 改 `<!-- HL@ts -->` 或 `<!-- /HL@ts -->` 行 → 失去对这条摘录的追踪（diff 找不到匹配的 ts）
- 在 HL@ 块**内部**加内容 → 下次同步被检测成"内容变化"，触发 update 覆盖你加的内容

### 块间区 vs 块内

| 操作 | 下次同步结果 |
|---|---|
| 在两个 HL@ 块之间加文字 | ✅ 保留 |
| 在所有 HL@ 块之前加文字 | ✅ 保留 |
| 在所有 HL@ 块之后加文字 | ✅ 保留 |
| 在 HL@ 块**内部**加文字 | ❌ 被覆盖 |
| 删除整条高亮（在 KOreader 端） | 对应 HL@ 块消失，块外内容保留 |
| 修改高亮的备注（在 KOreader 端） | 对应 HL@ 块内容更新，块外内容保留 |

## 同步流程

1. KOreader 触发同步 → 调用 FNS REST API
2. GET 笔记路径
3. 笔记存在：`parse → diff → applyDiff → serialize → overwrite`
4. 笔记不存在：用 `note_template` 渲染新笔记 → createNote

## 故障排查

### 同步失败 `code 305 Invalid Params`

通常是 rapidjson 把 Lua number（double）编码成 `xxx.0` 浮点字面量，Go int64 字段拒绝带小数点的 JSON 数字。代码已用 `gsub("(%d)%.0([,}])", "%1%2")` 后处理修复。如再次出现，检查 KOreader 的 datetime 字段是否包含意外的小数。

### 同步失败 `code 315 ErrorAuthTokenScopeRestricted`

Token 的 scope 不允许 REST 协议。在 FNS WebGUI 新建 Token，scope 包含 `p:rest c:koreader f:note_r,note_w`。

### Obsidian 端删除笔记后重新同步又出现

通常是路径分隔符不一致（`/` vs `\`）导致的"幽灵笔记"。代码已做 `\` → `/` 标准化，但如果之前已写入字面 `\` 路径，需要手动登录 FNS WebGUI 清理。

### 配置升级后行为异常

每次插件升级时 `init` 会检测 `config_version`，自动迁移旧 settings。如怀疑 settings 残留，进入 **设置 → 高级 → 重置配置**（会清空 server_url/token/vault，需重填）。

## 反馈与贡献

- 服务端问题：[haierkeys/fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service)
- 本插件：在本仓库提 issue / PR

## License

参考仓库根目录的 [AGPL-3.0](../../LICENSE)。
