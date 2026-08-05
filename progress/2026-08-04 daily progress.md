# 2026-08-04 开发进度

## 主要任务

场景 1 实测验证 + 诊断/修复 M4 升级后的 settings 残留问题。

## 完成清单

### 1. 场景 1 实测通过

用户删除 Obsidian 端旧笔记后重新同步，验证：

- ✅ 305 错误已修复（gsub 后处理 rapidjson 浮点字面量）
- ✅ 增加高亮 → 同步成功
- ✅ 删除高亮 → 同步成功

### 2. 诊断：M4 升级后 settings 持久化残留

#### 现象

新生成的笔记里同时出现 3 种 marker：

| Marker | 来源 |
|---|---|
| `<!-- HIGHLIGHTS_START -->` / `<!-- HIGHLIGHTS_END -->` 空区 | 旧 `note_template` 残留 |
| `<!-- HL@ts -->` ... `<!-- /HL@ts -->` 条目块 | 新代码（正确）|
| `<!-- H:ts -->` 摘录时间戳（HTML 注释）| 旧 `excerpt_template` 残留 |

#### 根因

`main.lua:init` 的 backfill 逻辑只在字段为 `nil` 时填默认值：

```lua
for k, v in pairs(Config.DEFAULTS) do
    if self.settings[k] == nil then  -- 已有旧值不覆盖
        self.settings[k] = v
    end
end
```

M4 之前用户用过插件，旧 `note_template`（含 HIGHLIGHTS_START/END）和 `excerpt_template`（含 `<!-- H:{datetime} -->`）已被持久化到 KOreader 的 `settings.reader.lua`。M4 升级后，`Config.DEFAULTS` 改了，但旧值不会被覆盖。

后果：
- `renderFullNote` 找不到 `{{HIGHLIGHTS}}` 占位符 → 走 fallback 分支，把 HL@ 块追加到末尾，旧的 HIGHLIGHTS_START/END 空区留在原位
- `renderExcerpt` 仍按旧模板渲染 `<!-- H:.. -->` 时间戳

### 3. 修复：加 settings schema 版本迁移机制

**Commit**: `fix: 加 settings schema 版本迁移，强制刷新 M4 之前的旧模板`

`config.lua`:
- 新增 `Config.CURRENT_CONFIG_VERSION = 2`
- 注释说明 bump 时机（默认值不兼容变更时）

`main.lua:init`:
- 在 backfill 之后加版本迁移块
- v1→v2 强制覆盖 `note_template` 和 `excerpt_template` 为新默认值
- 链式 `if prev < N` 结构，未来 v3、v4 扩展时叠加新块即可（v1→v3 会跑 v1→v2 + v2→v3）
- 迁移完成后写入 `self.settings.config_version = CURRENT_CONFIG_VERSION`，下次启动不再触发

```lua
local prev_version = self.settings.config_version or 1
if prev_version < Config.CURRENT_CONFIG_VERSION then
    if prev_version < 2 then
        self.settings.note_template = Config.DEFAULTS.note_template
        self.settings.excerpt_template = Config.DEFAULTS.excerpt_template
    end
    self.settings.config_version = Config.CURRENT_CONFIG_VERSION
end
```

## 待用户操作

部署 2 个文件到 Kindle：
- `config.lua`
- `main.lua`

测试步骤：
1. 重启 KOreader（触发 init 迁移）
2. 删除 Obsidian 端的《钱穆国学作品集》笔记
3. 触发同步 → 验证新生成笔记：
   - ❌ 不应再有 `<!-- HIGHLIGHTS_START -->` / `<!-- HIGHLIGHTS_END -->`
   - ✅ 时间戳应为 `*H: ...*` 斜体（不是 HTML 注释）
   - ✅ HL@ 块格式正确

## 关键设计决策

### 为什么需要显式版本号（而不是每次启动都强制覆盖）

考虑过两个替代方案：

| 方案 | 优点 | 缺点 |
|---|---|---|
| **A. 每次启动都把模板覆盖成默认值** | 实现极简 | 用户自定义的模板会被抹掉，违背"backfill 保留用户值"的契约 |
| **B. 检测旧模板特征字符串（如 `HIGHLIGHTS_START`）后覆盖** | 不需要版本号 | 启发式脆弱，未来模板演进时特征字符串可能误判 |
| **C. 显式 config_version（采用）** | 一次性触发，幂等，可链式扩展 | 多一个字段（成本极小）|

方案 C 最稳健，符合"配置 schema 演进"的工业实践（类比 SQLite 的 user_version、Rails 的 ActiveRecord::Migration）。

### 为什么 config_version 不放进 DEFAULTS

如果 `Config.DEFAULTS.config_version = 2`，那 backfill 会把 nil 字段（包括新用户的 config_version）填成 2。但这意味着老用户首次启动时也被 backfill 填成 2，迁移永远不触发——bug。

所以 config_version 故意**不放**进 DEFAULTS，只作为模块级常量。新用户 settings 里没有这个字段 → `prev_version = nil or 1 = 1` → 触发 v1→v2 迁移（幂等：把已经是默认值的字段再赋一次默认值，无害）→ 写入 config_version=2。

### 迁移语义：v1→v2 覆盖用户自定义模板是否过激？

考虑过：是否应该检测用户的模板"是否还是旧默认值"，只覆盖未自定义过的字段？结论是不值得——M4 是不兼容变更，旧模板跟新代码完全不兼容（`renderFullNote` 找不到 `{{HIGHLIGHTS}}` 占位符就 fallback），保留旧模板没意义。如果用户真的深度自定义过模板，重新基于新模板改一次成本也不高。

未来如果出现"用户自定义值得保留"的迁移场景（如字段改名），可以加更精细的检测逻辑。

## 下次工作的候选优先级

| 编号 | 任务 | 启动条件 |
|---|---|---|
| 🧪 | 验证迁移后笔记格式干净 | 用户部署后报告 |
| 2 | 场景 2（合集 override：改书名为「国史大纲」）| 上一步通过后 |
| 3 | 场景 3（在两条 HL@ 之间穿插编辑保留）| 上一步通过后 |
| 4 | 场景 4（删一条高亮 → 对应 HL@ 块消失）| 上一步通过后 |
| M5 | 自动同步（高亮/开书/关书事件 + debounce）| 用户说"开始 M5" |
| 遗留 | `_rawRequest` 网络错误显示 `HTTP CLOSE NIL` | 用户说"修这个" |
| 需求 3 | 文件名格式 `《书名》-作者.md` | 纯配置，告诉用户改菜单即可 |

---

## 下午：诊断"幽灵笔记"——跨客户端路径分隔符不一致

### 现象

settings schema 迁移完成后（note_template 已是新默认值），用户删除 Obsidian 端笔记重新同步，新笔记里**仍然**出现 `<!-- HIGHLIGHTS_START -->` / `<!-- HIGHLIGHTS_END -->` 空区。

### 排查过程

1. 时间戳是新的 `*H: ...*`（excerpt_template 已迁移）
2. 菜单里查看 note_template，确认含 `{{HIGHLIGHTS}}` 占位符（迁移生效）
3. main.lua 已重新部署，含 `config_version` 字符串（迁移代码到位）
4. 删 Obsidian 端笔记重同步仍出现 HIGHLIGHTS_START/END → 矛盾

**用户自己发现根因**：`note_path_prefix` 设置为 `谢子衍的读书笔记\`（带反斜杠）。

### 根因

`excerpt.lua:resolvePath` 只处理正斜杠 `/`，**完全忽略反斜杠 `\`**：

```lua
prefix = prefix:gsub("^/+", ""):gsub("/+$", "")  -- 只 strip /
```

导致 prefix `谢子衍的读书笔记\` 原样进入最终路径：`谢子衍的读书笔记\/<filename>.md`。

跨客户端对 `\` 的处理不一致：

| 客户端 | 行为 |
|---|---|
| **FNS 服务端** | 字面存储，`\` 当路径键的一部分 |
| **Obsidian** | 规范化，把 `\` 转 `/`（Windows-friendly）|

→ Obsidian 端的笔记路径是 `谢子衍的读书笔记/<filename>.md`（规范化后），FNS 端的路径键是 `谢子衍的读书笔记\/<filename>.md`（字面）→ **两边对"同一条笔记"的认知不一致**。Obsidian 端删除只删了 Obsidian 视角的路径，FNS 视角的路径键仍存在 → KOreader GET 时拿到 FNS 的旧内容（带 HIGHLIGHTS_START/END），走 diff 分支，旧内容被 Marker.parse 当 user 段保留。

### 修复

**Commit**: `fix: resolvePath 标准化路径分隔符（\ → /），避免跨客户端幽灵笔记`

`excerpt.lua:resolvePath`:
- 进入处理前把 prefix 和 template 的所有 `\` 替换为 `/`
- 下游逻辑统一按 `/` 处理（split / strip / sanitize）
- 文档注释新增"步骤 1：normalize path separators"，说明 Windows 用户习惯和跨客户端行为差异

`main.lua` 菜单 hint:
- "笔记路径前缀"：从 `Config.DEFAULTS.note_path_prefix` 改成 `只需文件夹名，例如 KOReader/刘慈欣（无需 / 或 \ 结尾）`
- "笔记文件名模板"：补充 `\ 会自动转为 /`

### 责任分摊与上游反馈

| 方 | 责任 |
|---|---|
| **FNS 服务端** | 跨客户端同步服务理应规范化路径。Git、WebDAV 都明确规定了路径分隔符的规范化规则。当前"字面处理"不算 bug，但不够稳健 |
| **KOreader 插件** | 客户端也应防御性处理用户输入。之前的疏漏只 strip 正斜杠 |
| **Obsidian** | 把 `\` 规范化为 `/` 是 Windows-friendly 的合理行为，不算错 |

→ 真正的"罪魁祸首"是 FNS 和 Obsidian 对 `\` 的处理**不一致**——任何一方做对都不会出问题。

**建议向 FNS 作者（`haierkeys/fast-note-sync-service`）提 issue**：
- 标题：`Path normalization inconsistency between FNS and Obsidian clients causes "ghost notes"`
- 复现：客户端 A 创建 `foo\bar.md` → Obsidian 端删除 → FNS 端 `foo\bar.md` 仍存在 → A 再次同步被视为 exists 走 diff 分支
- 建议：服务端在存储前 `path = strings.ReplaceAll(path, "\\", "/")`，或拒绝含 `\` 的路径并返回 400

这是上游修复（治本），本次客户端改动是治标 + 自我保护。

### 部署清单（累积）

 Kindle 上现在需要更新的文件（覆盖 M4 以来所有改动）：
- `api.lua`（305 修复）
- `marker.lua`（新建）
- `excerpt.lua`（重写 + 路径分隔符标准化）
- `main.lua`（重写 _doSyncCurrentBook + 当前书信息子菜单 + settings schema 迁移 + UI hint）
- `config.lua`（默认模板 + book_overrides + CURRENT_CONFIG_VERSION）

### 下次工作的候选优先级（更新）

| 编号 | 任务 | 启动条件 |
|---|---|---|
| 🧪 | 重新部署 + 验证笔记格式干净（HIGHLIGHTS_START/END 消失，时间戳是 `*H: ...*`）| 用户准备好部署 |
| 2 | 场景 2（合集 override：改书名为「国史大纲」）| 上一步通过后 |
| 3 | 场景 3（在两条 HL@ 之间穿插编辑保留）| 上一步通过后 |
| 4 | 场景 4（删一条高亮 → 对应 HL@ 块消失）| 上一步通过后 |
| 上游 | 向 FNS 作者提路径规范化 issue | 用户决定是否提交 |
| M5 | 自动同步（高亮/开书/关书事件 + debounce）| 用户说"开始 M5" |
| 遗留 | `_rawRequest` 网络错误显示 `HTTP CLOSE NIL` | 用户说"修这个" |
| 需求 3 | 文件名格式 `《书名》-作者.md` | 纯配置，告诉用户改菜单即可 |

---

## 傍晚：4 场景实测全过 + 摘录渲染优化 + FNS 上游 issue

### 场景测试结果

用户在 Kindle 上部署完整改动后跑完 4 个场景，全部通过：

| # | 场景 | 结果 |
|---|---|---|
| 1 | 删 Obsidian 笔记重新同步 | ✅ 新笔记格式干净（无 HIGHLIGHTS_START/END，HL@ 块正确）|
| 2 | 合集 override（改书名「国史大纲」）| ✅ 文件名变成新值 |
| 3 | 两条 HL@ 块之间穿插感想 → 再同步 | ✅ 感想保留 |
| 4 | 删一条高亮 → 同步 | ✅ 对应 HL@ 块消失 |

至此 M4 条目 marker + 需求 2（per-book override）+ 305 修复 + settings 迁移 + 路径分隔符标准化的核心功能全部验证通过。

### 用户向 FNS 提交上游 issue

用户用我提供的模板向 `haierkeys/fast-note-sync-service` 提交了路径分隔符不一致的 issue。检索确认无重复（#181 是补偿机制问题、#176 是 ACK 问题、#364 是冲突覆盖问题，均不重复）。issue 内容含问题描述、复现步骤、根因分析、Go 代码修复建议、与已有 issue 的区分说明。

### 摘录渲染优化（用户提的新需求）

用户观察到多行摘录（如包含"一、二、三、"的列表）在 Obsidian 渲染时对齐不美观，提出 4 个调整：

1. 页码与正文换行，不空行
2. 章节与页码之间不空行
3. marker 块头尾与内容之间不空行
4. 两个 marker 块之间空两行（源码层面）

#### 实施（Commit: `46d0d00`）

**`config.lua`** — `DEFAULT_EXCERPT_TEMPLATE` 改为：
```
> 📖 第 {page} 页
> {text}

{note}
```
- 页码单独一行，正文紧跟
- 去掉 `*H: {datetime}*`（HL@ 块头尾 marker 已显示 datetime，重复）
- `CURRENT_CONFIG_VERSION` 从 2 → 3

**`excerpt.lua:renderExcerpt`** — 两处改动：
- `{text}` 替换前把 `\n` 替换成 `\n> `，让多行摘录每行都有 `>` 前缀，整体在同一个 Markdown blockquote 内
- 渲染后 trim 末尾 `\n+`，避免 `{note}` 为空时出现多余空行（让 `<!-- /HL@ -->` 直接跟正文）

**`excerpt.lua:renderExcerptBlock`** — chapter 前置从 `\n\n` 改 `\n`：
- 章节标题与摘录正文之间不空行，更紧凑

**`marker.lua:serialize`** — 相邻 hl 段分隔从 `\n\n` 改 `\n\n\n`：
- 源码里 2 个空行（视觉边界清晰）
- Markdown 渲染时合并为段落分隔（视觉上仍 1 个空行，符合规范）

**`main.lua:init`** — 加 v2→v3 迁移块：
- 强制刷新 `excerpt_template` 为新默认值
- 链式迁移：v1→v3 会依次跑 v1→v2 + v2→v3

### 插件 README（用户提的新需求）

新建 `plugin/fns_sync.koplugin/README.md`，含：
- 插件功能与安装
- 配置菜单结构
- **HL@ 块结构图示**（重点）
- **安全编辑区图示**（marker 行不动、块内不动、块外随便写）
- 同步流程
- 常见故障排查（305 / 315 / 幽灵笔记 / 配置升级）

### 设计权衡记录

#### 为什么去掉 `*H: {datetime}*` 时间戳

用户认为 HL@ 块头尾 marker `<!-- HL@ts -->` / `<!-- /HL@ts -->` 已经显示了 datetime，正文里再放一个时间戳是冗余信息。去掉后：
- 视觉更干净
- HL@ 块内部只剩"章节 + 摘录正文 + 笔记"三部分
- 用户如想要时间戳，可用自定义模板加回 `{datetime}` 占位符

#### 为什么相邻 HL@ 块用 `\n\n\n`（2 个源码空行）而非 `\n\n`

Markdown 规范会把多个连续空行合并为 1 个段落分隔——所以渲染时视觉上还是 1 个空行。但源码层面有 2 个空行，**人工编辑时**更容易区分两个 HL@ 块的边界。如果用户希望渲染时也视觉看到 2 个空行，需要 `<br>` 标签，但会让源码变脏——权衡后选择 `\n\n\n`。

#### 为什么 chapter 后置用 `\n` 而非 `\n\n`

用户希望"章节与页码之间不空行"。Markdown 渲染时 `## chapter\n> body` 会被识别为紧凑列表（章节标题直接接引用块），视觉上更密集、信息密度高。

### 累积部署清单（截至本次）

Kindle 上需要更新的文件（覆盖全部）：
- `api.lua`（305 修复）
- `marker.lua`（新建 + serialize 调整）
- `excerpt.lua`（重写 + 路径分隔符标准化 + renderExcerpt/renderExcerptBlock 调整）
- `main.lua`（重写 _doSyncCurrentBook + 当前书信息子菜单 + settings schema 迁移 v1/v2/v3 + UI hint）
- `config.lua`（默认模板 v3 + book_overrides + CURRENT_CONFIG_VERSION=3）
- `README.md`（新建，可选，不影响运行）

### 下次工作的候选优先级（最终）

| 编号 | 任务 | 启动条件 |
|---|---|---|
| 🧪 | 部署 v3 摘录优化 + 验证新格式（页码换行、多行对齐、块间空两行）| 用户准备好部署 |
| 上游 | 跟进 FNS 作者对路径分隔符 issue 的回复 | 收到通知 |
| M5 | 自动同步（高亮/开书/关书事件 + debounce）| 用户说"开始 M5" |
| 遗留 | `_rawRequest` 网络错误显示 `HTTP CLOSE NIL` | 用户说"修这个" |
| 需求 3 | 文件名格式 `《书名》-作者.md` | 纯配置，告诉用户改菜单即可 |

### 今天的关键设计决策（备忘）

1. **Settings schema 版本迁移**：`config_version` 字段 + `if prev < N` 链式迁移块。借鉴 SQLite user_version / Rails ActiveRecord::Migration 模式。未来每次不兼容变更 bump 版本号即可，老用户首次启动自动迁移，新用户从最新版起步（迁移代码幂等）
2. **路径分隔符标准化**：客户端层（治标）+ 上游层（治本）。客户端做 `\` → `/` 防御，FNS 服务端做路径规范化是真正解法
3. **HL@ 块作为 diff key**：每条 KOreader 高亮独立包裹，datetime 是唯一 key。Marker.parse 把笔记分成 user/hl 两类 segment，user 段原样保留，hl 段按 ts 匹配做 insert/update/delete。这是用户能"在两条摘录之间穿插感想"的基础
4. **多行摘录加 `> ` 前缀**：让每行都进入同一个 Markdown blockquote，避免 lazy continuation 在不同 markdown 解析器下行为不一致

---

## 晚间：close marker 加 `>` 前缀避免 Obsidian 蓝线包裹

### 问题

用户在 Obsidian 阅读模式看到：HL@ 块摘录正文用 `>` 引用块（蓝线竖线），紧贴正文下方的 `<!-- /HL@ts -->` 因 Markdown lazy continuation 被识别为 blockquote 的一部分，蓝线视觉延伸到 marker 行——视觉不干净。

### 根因

Markdown lazy continuation 规则：blockquote 内的 `>` 行后面紧跟的非 `>` 行（中间没有空行）会被当作 blockquote 内容。当前 serialize 输出：

```
> 二、所謂...
<!-- /HL@ts -->     ← 紧跟在 > 行之后，被 lazy continuation 吸进 blockquote
```

→ Obsidian 渲染时蓝线延伸到 marker 行。

### 修复（Commit: `96bc7ee`）

`marker.lua:serialize` 在 close marker 前加 `> ` 前缀：

```
> 二、所謂...
> <!-- /HL@ts -->   ← 显式成为 blockquote 的一行
```

HTML 注释不渲染，`<blockquote>` 元素虽然包含这一行但不占视觉空间——蓝线视觉上停在正文末尾。

### 兼容性处理

`marker.lua:parse` 提取 raw_block 时，需要兼容两种 close marker 格式：
- 新格式（serialize 输出）：close 前是 `\n> ` → raw_block 末尾是 `\n> `
- 旧格式（之前同步的笔记）：close 前是 `\n` → raw_block 末尾是 `\n`

加一行 `raw_block:gsub("\n%s*>%s*$", "")` 剥离末尾的 `\n>`（如果有），再用原来的 trim 处理。两种格式都能正确解析。

### 一次性副作用

二次同步时所有现有 HL@ 块会触发 update（content 没变，但 serialize 输出格式变了 → parse 出来的 content 跟新 serialize 输出不一致 → diff 检测到 update）。一次性，第二次同步稳定。

不需要 bump config_version——这不是模板变更，是 marker 序列化格式变更，旧的笔记二次同步自动升级。

### 设计权衡

考虑过的替代方案：

| 方案 | 问题 |
|---|---|
| 在 close 前加空行中断 blockquote | 违背用户"块尾与正文不空行"的明确要求 |
| 用 `</blockquote>` 显式中断 | 没有对应 `<blockquote>` 开标签，渲染错误 |
| 摘录正文不用 `>` blockquote | 失去摘录的视觉标记 |
| 在 close 前加零宽空格 `&#8203;` | 源码出现奇怪字符，不干净 |

最终方案（close marker 加 `>` 前缀）最干净：1 行改动，向后兼容，视觉问题彻底解决。

---

## 晚间后续：上一方案实测无效，改用空行方案

### 实测结果

用户部署后反馈：close marker 加 `> ` 前缀的方案**没解决**蓝线延伸问题。Obsidian 把 blockquote 内的 HTML 注释行也算作视觉空间，蓝线仍延伸到 marker 行。

### 替代方案

用户主动提议：放弃"close 紧贴正文"的要求，在 close marker 前加一个空行，让 Markdown 规范的 blockquote 中断规则生效。

**Commit: `7a6a195`**

`marker.lua:serialize` 把 close 前的 `"\n> "` 改回 `"\n\n"`（空行中断 blockquote）：

```
> 二、所謂...       ← blockquote 内（蓝线覆盖）
                    ← 空行（无 > 前缀），中断 blockquote
<!-- /HL@ts -->     ← 不在 blockquote 内，蓝线不延伸
```

parse 的 `gsub("\n%s*>%s*$", "")` 保留——兼容曾用 `>` 前缀的中间版本笔记，避免 diff 死循环。

### 教训

第一个方案（`>` 前缀）在 CommonMark 规范层面是正确的——HTML 注释不渲染，blockquote 元素视觉边界应该只到内容末尾。但 Obsidian 的 CSS 实现可能给整个 `<blockquote>` 元素加了 padding/margin，包括 HTML 注释占的 DOM 位置——视觉上仍延伸。

**应该先实测 Obsidian 的具体行为再设计**，而不是依赖规范层面的推断。下次涉及视觉渲染的改动，先用最小测试用例验证再做大改动。

### 一次性副作用

二次同步会再次触发 update（serialize 格式又变了，所有 HL@ 块再次升级）。一次性，第二次同步稳定。

---

## 晚间最终：抽出 Marker.wrapBlock 统一两条路径的 block 格式

### 问题

用户报告：需要点击**两次同步**才生效——第一次没解决蓝线问题，第二次才解决。

### 根因

新建笔记和已存在笔记走的是两条代码路径，包装 block 的格式不一致：

| 分支 | 函数 | close 前格式 |
|---|---|---|
| 新建笔记 | `excerpt.lua:renderFullNote` | `\n`（紧贴，蓝线延伸）|
| 已存在笔记 | `marker.lua:serialize` | `\n\n`（空行中断 blockquote）|

`renderFullNote` 里自己拼 block 字符串，没用 `marker.lua:serialize`。之前改 `marker.lua` 时漏了 `excerpt.lua`——DRY 违反导致的格式漂移。

用户流程：
1. 删 Obsidian 笔记 → 第一次同步走 `renderFullNote`（新建分支）→ close 紧贴 → 蓝线问题没解决
2. 第二次同步走 `serialize`（diff 分支）→ close 前空行 → 蓝线问题解决

### 修复（Commit: `7965f7a`）

DRY 重构：
- `marker.lua` 新增公开函数 `wrapBlock(ts, content)`，集中定义 block 格式
- `marker.lua:serialize` 改用 `wrapBlock`
- `excerpt.lua:renderFullNote` 改用 `Marker.wrapBlock`，块间分隔从 `\n\n` 同步为 `\n\n\n`

未来改 block 格式只改 `wrapBlock` 一处，避免再次漂移。

### 经验

涉及"两条代码路径做同一件事"的改动，必须先确认两条路径都改到位。本次先发现 serialize 漏改 renderFullNote，根本原因是 DRY 违反——两处独立定义 block 格式。重构为单一来源后，未来不会再出现这种"第一次/第二次同步不一致"的症状。

---

## 夜间：修复遗留 bug — HTTP CLOSE NIL + 需求 3 配置完成

### 遗留 bug：网络错误显示 `HTTP CLOSE NIL`

**Commit: `8ee4a2a`**

#### 根因

LuaSocket 的 `http.request` 返回值有歧义：
- 成功：`(1, http_code, status_line, headers)` → `socket.skip(1, ...)` 后 `code` 是 HTTP 状态码（数字）
- 失败：`(nil, error_string)` → `socket.skip(1, ...)` 后 `code` 是错误字符串（如 `"closed"`、`"timeout"`）

`api.lua:_rawRequest` 直接把 socket.skip 后的 code 返回给 `makeRequest`。`makeRequest:126` 的网络错误判断只检测 `nil` 或 `0`，**不检测字符串**：

```lua
if http_code == nil or http_code == 0 then  -- ← 不命中字符串
    -- 网络错误分支
end
```

→ 字符串 `"closed"` 被当成 HTTP code，最终格式化成 `"HTTP closed: nil"` 显示给用户。

#### 修复

在 `_rawRequest` 返回前加类型检测，把字符串错误挪到 status 位置：

```lua
if type(code) == "string" then
    return nil, table.concat(sink), code  -- code=nil, status=error_string
end
```

这样 `makeRequest:126` 的现有 `nil`/`0` 判断就能命中，走 `network_error = true` 分支，显示 `"网络错误：closed"`。

#### 教训

LuaSocket 的双返回值模式（成功 vs 失败的形状不同）是常见陷阱。应该在**最底层**（_rawRequest）规范化返回值形状，让上层只关心成功路径。`type(code) == "string"` 是 Lua 里区分"伪 code"的惯用写法。

### 需求 3：文件名格式 — 纯配置已搞定

用户自己在菜单里改 `note_filename_template` 为 `《{title}》-作者.md`（用 `{author}` 占位符，去掉"读书笔记"后缀），无需代码改动。

### 累积 commit 清单（今日全部）

| 时间 | Commit | 内容 |
|---|---|---|
| 上午 | `3e1df1b` | settings schema 版本迁移（v1→v2）|
| 上午 | `36db711` | daily progress 上午 |
| 下午 | `77794b1` | resolvePath 标准化路径分隔符 |
| 下午 | `0c1f734` | daily progress 下午 |
| 傍晚 | `46d0d00` | 摘录渲染优化 + README |
| 傍晚 | `7cb080b` | daily progress 傍晚 |
| 晚间 | `96bc7ee` | close marker 加 > 前缀（无效方案）|
| 晚间 | `645c757` | daily progress 晚间 |
| 晚间 | `7a6a195` | close marker 改用空行中断 blockquote |
| 晚间 | `1cc0491` | daily progress 晚间后续 |
| 晚间 | `7965f7a` | 抽出 Marker.wrapBlock DRY 重构 |
| 晚间 | `fa734e3` | daily progress 晚间最终 |
| 夜间 | `8ee4a2a` | _rawRequest 检测 LuaSocket 错误字符串 |

共 13 个 commit（含 6 个 docs）。所有 M4 以来的核心功能 + 已知 bug 全部收尾。

