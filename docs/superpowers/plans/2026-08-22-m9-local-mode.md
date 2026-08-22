# M9 无 FNS 本地模式设计（2026-08-22 拍板）

## 背景与目标

三功能解耦：FNS 同步 / 笔记 / 问 AI 相互独立——没有自建 FNS 服务器的用户
即装即用（笔记 + 问 AI），有服务器的用户三者叠加（现有行为不变）。

## 决策记录（用户已拍板）

| # | 决策点 | 结论 |
|---|--------|------|
| D1 | 无 FNS 时"加入笔记"落点 | 分工式 C：AI@ → 本地 md（唯一落点，note 字段装不下 Q+A 长文本）；HL@ → 继续用 KOReader 原生高亮，本地 md 生成时带上 HL@ 做配对。**不做双源回写**（本地 md 是唯一笔记文件，note 字段不承诺同步） |
| D2 | 本地 md 根目录 | KOReader 统一目录（如 `/mnt/us/FNS-Notes/`），保留 note_path_prefix 子目录结构，USB 连电脑一次拷走全部 |
| D3 | 查看本地笔记入口 | 包含：菜单按钮 → TextViewer 显示本地 md 内容（约 30 行） |
| D4 | 后配 FNS 迁移 | 自动种子上传：FNS 模式首次同步某书时，服务器无此笔记且本地 md 存在 → 直接 POST 本地内容，历史 AI@ 无缝上服务器 |

## 调研结论（2026-08-22）

1. **AI 入口已解耦**：问 AI 按钮只看 `ai_enabled`（main.lua:280），不依赖
   FNS 配置——"没 FNS 也能问 AI"现已成立。
2. **同步管线几乎全本地**：Legacy 路径（main.lua:1249）中仅
   `Api:getNote`（1274）和 `Api:overwriteNote/createNote`（1342/1385）是
   网络调用；parse → diff → applyDiff → drain AI@ → cascadeDeleteAi →
   serialize 全是纯本地计算。
3. **resolvePath 纯本地**（excerpt.lua:244）：只依赖 note_path_prefix +
   note_filename_template，返回 vault 相对路径，本地模式直接复用。
4. **pending AI 块已持久化**（G_reader_settings，H-2 fix）：无 FNS 时数据
   不丢，只是 `_triggerSync`（main.lua:1162）拦截后不可见。

## 架构

### 模式判定（自动推导，零配置）

```
isConfigured() = server_url + api_token + vault 全非空
  ├─ true  → FNS 模式（现有行为 100% 不变）
  └─ false → 本地模式（store = LocalStore）
```

不新增显式开关：配置了 FNS 就用服务器，没配置就即装即用。

### 存储后端抽象

新文件 `localstore.lua`（约 80 行），与 `Api` 签名兼容：

```lua
LocalStore:getNote(settings, path)                  -- io.open 读；不存在 → exists=false
LocalStore:overwriteNote(settings, path, content)   -- 写回
LocalStore:createNote(settings, path, content)      -- util.makePath + 写入
```

本地根目录 = `<Kindle 用户分区>/FNS-Notes/` + resolvePath 相对路径
（resolvePath 已含 note_path_prefix，如 `KOReader/《三体》读书笔记.md`）。

`_doSyncCurrentBookLegacy` 参数化注入 store（默认 `Api`），本地模式传
`LocalStore`——Legacy 管线代码零复制，diff / drain / cascade 级联删除 /
防重复 / Q+A 格式全部复用。

### 数据流

```
FNS 模式（现状）:
  高亮 → render → Api:getNote → parse/diff/applyDiff → drain AI@
       → cascade → serialize → Api:POST → 成功后 commitDrainedAi

本地模式（新增）:
  高亮 → render → LocalStore:getNote（读本地md）→ 同一管线
       → LocalStore:overwrite（写本地md）→ 成功后 commitDrainedAi
```

### 分功能行为矩阵

| 功能 | FNS 模式 | 本地模式 |
|------|----------|----------|
| 问 AI / 多轮对话 | ✅ | ✅（不变） |
| 加入笔记（AI@） | drain → POST | drain → 写本地 md |
| 高亮同步（HL@） | diff → POST | diff → 写本地 md |
| 查看笔记 | Obsidian | 菜单「查看本地笔记」→ TextViewer |
| M7 双向 pull | ✅ | 跳过（无 remote 概念） |
| M6 离线队列 | ✅ | 不需要（本地写无网络错误；写失败保留 pending 重试） |
| 级联删除 / 防重复 / Q+A 格式 | ✅ | ✅（同一管线自动获得） |

## 改动清单

| 文件 | 改动 | 预估 |
|------|------|------|
| `localstore.lua` | 新增：LocalStore 三方法 + `util.makePath`（KOReader 现成 mkdir -p）+ `filemanagerutil.getHomeFolder()` 根目录 | ~80 行 |
| `main.lua` | ① `_triggerSync`：isConfigured false → 路由本地分支；② `_doSyncCurrentBookLegacy` 参数化 store；③ 菜单：本地模式下同步按钮文案「同步到本地笔记」+ 新增「查看本地笔记」；④ D4 种子上传：first-create 分支检查本地 md 存在则用其内容 | ~200 行 |
| `config.lua` | DEFAULTS 加 `local_notes_root`（默认 "FNS-Notes/"，可改） | ~3 行 |
| `_meta.lua` | 版本号提升 | 1 行 |
| `tests/test_localstore.lua` | 新增单测：读写、目录创建、签名兼容、管线端到端幂等 | ~150 行 |

## 测试策略

- 单测：LocalStore 读写/目录创建/错误路径；本地管线端到端
  （render → 本地写 → 重读 → 再 sync → 无 diff 幂等）；D4 种子上传逻辑。
- 现有 139 个 marker/AI 测试全部复用（marker 格式零变化）。
- main.lua 走语法检查 + Kindle 实测（项目惯例）。

Kindle 实测清单（实现后执行）：

1. 不配 FNS → 高亮一段 → 确认本地 md 生成、HL@ 块正确。
2. 问 AI → 翻译 → 加入笔记 → 本地 md 出现 AI@ 块（【问】标签 + 【答】全文）。
3. 删高亮 → 再同步 → 级联删除对应 AI@ 块。
4. 菜单「查看本地笔记」能打开看到最新内容。
5. 配上 FNS → 同步 → 服务器出现该笔记且含历史 AI@ 块（种子上传）。
6. crash.log grep `[FNS]` 无异常。

## 风险与边界

- **本地写失败**（磁盘满/权限）：InfoMessage 报错，pending_ai 与高亮保留，
  下次重试；不入 M6 队列（无网络语义）。
- **用户中途清空 FNS 配置**：M6 队列残留条目本地模式下静默跳过（日志记录），
  配置恢复后继续处理。
- **双模式文件一致性**：同一相对路径两套根目录（Obsidian vault vs 本地
  FNS-Notes/），切模式不冲突；D4 种子上传仅 first-create 时触发一次。
- **不做的事**：note 字段回写、本地 md 手动编辑的双向合并（本地模式下
  用户改 md 文件外的内容会被保留——parse 只重写 marker 区间，与服务器
  模式同语义）。

## 二轮审查（2026-08-22，对照 E:\koreader-src 源码）

### KOReader 兼容性验证（结论：全部可行，一处修订）

| 设计假设 | 验证结果 |
|----------|----------|
| 逐级 mkdir 自己实现 | **修订**：KOReader 有现成 `util.makePath(path)`（frontend/util.lua:855，mkdir -p 语义，已存在不报错），LocalStore 直接调用，不自己写 |
| 根目录"Kindle 用户分区"如何定位 | `filemanagerutil.getHomeFolder()`（filemanagerutil.lua:25）：`G_reader_settings home_dir → Device.home_dir → "."`，Kindle 上即 /mnt/us。bookshortcuts.koplugin/main.lua:69 同款用法（使用点运行时 require，filemanagerutil 是纯函数模块无 UI 依赖） |
| io.open 覆盖写文件 | 官方 exporter.koplugin/target/markdown.lua:108 同款直接 `io.open(path, "w")` 覆盖写，无原子写惯例——LocalStore 照此即可（tmp+rename 可选优化，非必须） |
| lfs 的 require 方式 | 插件标准：`require("libs/libkoreader-lfs")`（bookshortcuts/coverimage/coverbrowser 同款） |
| `require("util")` | 本项目已在用（excerpt.lua:18、api.lua:30），零新增依赖 |
| TextViewer 查看笔记 | main.lua:49 已 require，AI 对话窗口已在用 |
| 本地模式绕过 runWhenOnline | 现有 `opts.skip_run_when_online` 参数（main.lua:1141/1217）直接复用——飞行模式下本地同步不弹"开 WiFi" |
| 中文文件名 | KOReader 书籍本身就是中文名；resolvePath 的 util.getSafeFilename 已处理 |

### 设计缺口（审查发现，5 项）

| # | 级别 | 缺口 | 处置 |
|---|------|------|------|
| G1 | CRITICAL | **`enabled` 总开关挡住本地模式**：DEFAULTS `enabled=false`（config.lua:116），`_triggerSync` 先查 enabled 再查 isConfigured（main.lua:1156/1162）——新用户没开总开关时本地模式不工作，"即装即用"落空。且菜单项 `enabled and isConfigured()`（main.lua:2661 等）在本地模式全灰 | **已拍板 (a)**：本地模式尊重 enabled 总开关（用户开一次"启用"），isConfigured 不再拦截本地分支；菜单项 enabled_func 放宽为只看 enabled，模式路由在触发时判断 |
| G2 | HIGH | **手动同步的 runWhenOnline 包装**：本地模式无需网络，必须传 skip_run_when_online=true，否则飞行模式点"同步到本地笔记"被弹开网提示 | 实现时本地分支固定 skip（技术细节，直接定） |
| G3 | MEDIUM | **D4 种子上传后本地 md 的处置没写**：上传成功后若保留原文件，FNS 模式今后只写服务器，本地文件停在旧状态，用户翻 FNS-Notes/ 会看到过期内容 | **已拍板 (a)**：上传成功后重命名 `<原名>.uploaded.bak`（防误删手改内容，目录里不留"看似最新"的旧文件） |
| G4 | MEDIUM | **LocalStore 返回结构兼容细节**：Api:getNote 返回 `{ok, exists, content, note={ctime}}`，overwriteNote 带 original_ctime 乐观锁。本地实现：`lfs.attributes(path).modification` 充当 ctime；V1 乐观锁直接忽略（单客户端单设备场景，外部并发改写风险低），结构字段对齐 | 实现时对齐（技术细节，直接定） |
| G5 | LOW | **M5 自动同步 gating 未提**：`_gateAutoSync`（main.lua:1959）含 isConfigured，本地模式下高亮后自动写本地 md（debounce 照旧）需把该检查改为"或本地模式可用"。建议自动也写（体验一致，本地写快） | 按建议实现（技术细节，直接定） |
