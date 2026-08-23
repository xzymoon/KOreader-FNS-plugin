# M10 菜单重设计：FNS 同步与 AI 读书助手双模块解耦

日期：2026-08-23
状态：修订版 v4（三轮审查结论均已并入：菜单/gating 两轮 + conf 导入一轮，待用户确认实施）
起因：Kindle 实测暴露 G1 拍板缺陷——"启用 FNS 同步"总开关语义误导（管本地笔记与 AI 加笔记的生死），用户卡在"开了 AI 开关却报 FNS 同步未启用"；工具 tab 过长，插件入口沉在第二页。

## 一、设计目标

1. 两大功能模块彻底独立：FNS 同步（笔记去向管理）与 AI 读书助手（AI 阅读辅助），单独使用任一均可
2. 本地笔记零门槛：未开 FNS 模式即自动本地，手动同步即点即用
3. 菜单入口位置（2026-08-23 用户拍板 + 源码审查修正）：
   - **AI 读书助手 → 工具 tab 最前**：代码内 `sorting_hint="tools"`（默认追加到 tab 末尾），配套生成 KOReader 官方用户自定义菜单顺序文件 `settings/reader_menu_order.lua` + `settings/filemanager_menu_order.lua` 把 `fns_ai` 插到 tools 列表第一位（menusorter.lua `readMSSettings` 机制，readermenu.lua:354 调用）。生成时必须基于 Kindle 实际部署版本（H:\koreader\frontend\ui\elements\*menu_order.lua）而非本地 master 源码。风险：tools 列表被文件固定，KOReader OTA 升级若改动 tools 列表需重新生成（tools 变动频率低，可接受）
   - **FNS 同步 → 设置▸网络 二级菜单**：`sorting_hint="network"`。注意"network"不是独立 tab 而是 setting tab 的 Network 子菜单（common_settings_menu_table.lua:273，reader/filemanager 两场景均存在，无崩溃风险）

## 二、语义重定义（核心）

| 项 | 现状 | 新语义 |
|---|---|---|
| `settings.enabled` | 功能总开关，拦截一切写入 | **模式开关**：true=FNS 服务器模式，false=离线（本地）模式 |
| `_isLocalMode()`（main.lua:1019） | `not isConfigured()`（自动推导） | `not self.settings.enabled`（显式开关） |
| `isConfigured()` | 决定模式 | 仅表示 FNS 服务配置完整性，只在 FNS 模式内使用 |
| `ai_enabled` | AI 总开关 | 不变（已独立） |

## 三、gating 调整

### 3.1 `_triggerSync`（main.lua:1163-1240）

现状（1170-1181）：
```lua
if not self.settings.enabled then → 弹"FNS 同步未启用" return end
local local_mode = self:_isLocalMode()  -- = not isConfigured()
```

新逻辑：
```lua
local local_mode = not self.settings.enabled   -- 模式开关直接决定
if not local_mode and not self:isConfigured() then
    -- 勾选了 FNS 模式但配置不完整：提示而非悄悄落本地
    if not silent then 弹"服务配置不完整，请到『服务设置』填写" end
    return
end
```
本地模式不再有任何开关拦截（手动/自动/AI 加笔记全部放行——AI 加笔记经决策 9 走 `_triggerSync`，自动修复）。

### 3.2 `_gateAutoSync`（main.lua:2042-2047）

现状：`enabled and auto_sync_enabled and 有书打开`
新：**去掉 enabled 检查**，保留 `auto_sync_enabled and 有书打开`（两种模式都可自动写，用户知情开关）。

### 3.3 `_autoSyncCurrentBook`（main.lua:2077）

新增前置短路：`if not self:_isLocalMode() and not self:isConfigured() then log skip return end`（FNS 模式未配置时避免每次高亮空跑到 `_triggerSync` 才被拦）。

### 3.4 `_processQueue`（main.lua:2450）

不变：队列是 FNS 专属（enabled + isConfigured 检查保留；新语义 enabled=false 即离线模式，队列天然不工作）。

### 3.5 双向同步 / 离线队列 / 测试连接

均为 FNS 专属：菜单仅 FNS 模式显示；代码层 `_triggerSync` 的 FNS 分支已有 isConfigured 拦截，无需额外改。

### 3.6 审查补丁（两轮审查发现，实施时一并落实）

1. **离线区子项 enabled_func 去 enabled**：现 sync_on_highlight / sync_on_book_close 子项（main.lua:2662-2674）的 `enabled_func` 含 `settings.enabled`——新菜单"离线笔记"区若沿用，离线模式（enabled=false）下自动写子项会全体变灰。离线区子项只看 `auto_sync_enabled`。
2. **开书拉取调度排除离线模式**：`pull_on_book_open` 调度点（main.lua:2582 附近）与 `_pullRemoteHighlights`（1997-2029）不查 enabled；离线模式用户若遗留 `bidirectional_sync_enabled=true`，开书定时拉取仍触发 → 经 local_mode 短路变成意外本地写。调度处加 `if self:_isLocalMode() then return end`。
3. **（二轮）手动同步按钮 enabled_func 删除**："同步到本地笔记"/"查看本地笔记"现有 `enabled_func = settings.enabled`（main.lua:2862、2870）——新语义下离线模式 enabled=false 会把这两项变灰，与"零门槛即点即用"直接矛盾。新菜单中这两项**不设 enabled 门禁**，改为无书守卫（见 §4.2）。
4. **（二轮；实施时裁定不适用）手动同步项无书守卫**：方案要求离线区/FNS 区手动同步项加 `enabled_func = _getCurrentBookPath() ~= nil`。**实施时发现前提不成立**：插件声明了 `is_doc_only = true`（main.lua:74，M6 HIGH-A 修复），KOReader 在 FileManager 场景不创建插件实例（filemanager.lua:419 过滤），菜单只出现在打开书的阅读器里——"书库无书点同步"场景不存在，无需实现。若未来移除 is_doc_only 则须补此守卫。

## 四、菜单重构（main.lua addToMainMenu，2632 起）

### 4.1 两个独立顶级入口

```lua
menu_items.fns_sync = {
    text = _("FNS 同步"),
    sorting_hint = "network",          -- → 设置▸网络 二级菜单（两场景安全）
    sub_item_table_func = function() ... end,  -- 按模式动态生成（touchmenu.lua:875 官方支持）
}
menu_items.fns_ai = {
    text = _("AI 读书助手"),
    sorting_hint = "tools",            -- → 工具 tab（默认末尾，靠前靠 menu_order 文件）
    sub_item_table = { ... },          -- 照搬现 AI 子菜单（2898-3036）
}
```

交互限制（V1 审查确认）：`sub_item_table_func` 在每次进入子菜单时求值，但 toggle 模式开关后**当前已展开的列表不会即时重排**，需返回再进入才看到新选项组——KOReader 惯例行为，接受。

### 4.1.1 menu_order 文件生成（AI 入口工具 tab 靠前）

生成 `koreader/settings/reader_menu_order.lua` 与 `filemanager_menu_order.lua`（**基于 Kindle 部署版 H:\koreader\frontend\ui\elements\ 下同名文件**复制 tools 键并插入 "fns_ai" 为第一项）：

```lua
return {
    tools = {
        "fns_ai",              -- AI 读书助手（插到最前）
        -- ↓ 以下照抄 Kindle 实际版本的 tools 列表
        "read_timer", "calibre", "exporter", ...
    },
}
```

mergeAndSort 只覆盖出现的键（pairs 遍历），其他 tab 顺序不受影响。

### 4.2 FNS 同步子菜单（动态，按模式开关切换显示）

```
FNS 同步（设置▸网络 二级菜单）
├── ☐ FNS 服务器模式            ← checked=enabled；toggle 勾选时检测
│                                  isConfigured，不完整弹 InfoMessage 提示
├── ── 离线笔记（enabled=false 时显示）──
│   ├── 自动写本地笔记            ← auto_sync_enabled（子项只看本开关，§3.6.1）
│   │   ├── 高亮修改时自动写      ← sync_on_highlight
│   │   ├── 关闭书籍时自动写      ← sync_on_book_close
│   │   └── 写入延迟（秒）        ← debounce_seconds
│   ├── 本地笔记存储位置          ← local_notes_root（**新增编辑项**：现菜单无此
│   │                                项，仅 config.lua:130 有默认值；二轮审查纠正
│   │                                了初稿"从笔记组织移入"的错误说法）
│   ├── 同步到本地笔记（手动）    ← onSyncCurrentBook（零门槛：无 enabled 门禁，
│   │                                仅无书守卫 §3.6.3/3.6.4）
│   └── 查看本地本书笔记          ← onViewLocalNote（零门槛，已有无书守卫）
├── ── FNS 服务器（enabled=true 时显示）──
│   ├── 服务设置 ▸                ← server_url/api_token/vault/测试连接
│   ├── 立即同步当前书            ← onSyncCurrentBook（无书守卫同上）
│   ├── 自动同步 ▸                ← auto_sync_enabled/高亮/关书/延迟
│   │   └── 双向同步 ▸            ← bidirectional（M7 子树原样）
│   ├── 立即拉取远端高亮          ← _pullRemoteHighlights
│   └── 离线队列 ▸                ← M6 子树原样
└── ── 共用 ──
    ├── 笔记组织 ▸                ← 模板/路径前缀/文件名/颜色（去掉 local_notes_root）
    └── 当前书信息 ▸              ← book_overrides 原样
```

删除项：原"启用 FNS 同步"开关（2641-2645，被模式开关取代；`_toggleBool("enabled")` 全文件无其他调用点，grep 证实）；"立即同步全部历史"（菜单项 2886-2892 **连同 onSyncAllHistory 空函数 2618-2622 及其注释一并删除**，避免死代码——二轮审查确认无 dispatcher/事件引用）；原 3252 行"已启用/未启用"状态文本（位于"关于"弹窗内，改由模式开关 checked 呈现）。

### 4.3 AI 读书助手子菜单

照搬现 2898-3036（启用 AI 对话 / API 设置 / 提示词模板 / 高级参数 / 说明）。说明文案（3029）中"同步到 Obsidian"一句**改写**为"加入笔记（FNS 模式同步到 Obsidian，离线模式写本地 FNS-Notes/）"——二轮审查：原句在离线模式下不准确，改写而非追加。

## 五、兼容与迁移

- 不 bump config_version（无字段重命名/默认值变化）
- 现有用户状态映射：
  - `enabled=false` → 离线模式（即装即用，含用户当前 Kindle）✓
  - `enabled=true + isConfigured` → FNS 模式，行为不变 ✓
  - `enabled=true + 未配置`（怪状态）→ 旧行为"悄悄写本地"变为"FNS 模式+提示配置"（行为变化，更符合直觉，可接受）
- Kindle settings.reader.lua 无需手工干预

## 六、测试与部署

- 检查 5 个现有测试文件中 enabled/_isLocalMode 相关断言并适配（第一轮审查确认：仅 test_config_ai.lua:40 涉 ai_enabled，不受影响；test_localstore.lua 无 gating 用例）
- 新增单测：_isLocalMode 新语义、_triggerSync 离线放行 / FNS 未配置拦截、_gateAutoSync 去 enabled
- 全量跑 167 项基线
- 部署 H:\koreader\plugins\fns_sync.koplugin\，git 提交，progress 记录

## 七、KOReader 源码契合验证结论（已由子代理完成，E:\koreader-src）

| # | 验证点 | 结论 |
|---|---|---|
| V1 | `sub_item_table_func` 支持 | ✅ touchmenu.lua:875，展开时求值；限制：toggle 后已展开列表不重排（见 §4.1） |
| V2 | sorting_hint="main" | ✅ 两场景存在（reader_menu_order.lua:11 / filemanager_menu_order.lua:10），但"目录"实际在 navi tab——已放弃 main 方案 |
| V3 | sorting_hint="network" | ✅ 两场景存在（common_settings_menu_table.lua:273；filemanagermenu.lua:509 注入），落点为设置▸网络二级菜单 |
| V4 | addToMainMenu 调用 | ✅ readermenu.lua:344 / filemanagermenu.lua:877，每次打开菜单重新注册，动态排序可行 |
| V5 | 键名 fns_ai | ✅ 全源码无冲突 |
| V6 | InfoMessage in callback | ✅ kosync main.lua:1071 等惯例 |

menusorter 崩溃风险确认：sorting_hint 目标不存在时 `sorting_hint_menu.sub_item_table` 对 nil 索引崩溃（menusorter.lua:180-181）——"network" 两场景均存在，安全；不可使用 "navi"（filemanager 无此 tab）。

## 八、插件逻辑审查结论（architect 子代理）

- 7 个关键场景推演全部正确（离线自动写/手动零门槛/FNS 未配置静默跳过/AI 加笔记写本地/队列失效等）
- 新装机默认即"离线+自动写本地"（DEFAULTS enabled=false + auto_sync_enabled=true）
- 补丁两项已并入 §3.6
- **现有 167 项测试不覆盖 gating**（仅 test_config_ai.lua:40 涉 ai_enabled，不受影响）——§六新增单测是唯一防线，必须落实
- 怪状态用户（enabled=true+未配置）链路完好：补配置后首次同步走种子上传 → .uploaded.bak，无数据一致性问题

## 九、第二轮审查结论（2026-08-23，两子代理并行）

**menu_order 机制二审（源码级验证，全部通过）**：
- 文件格式 `return {...}` 正确（dofile 无 return 则回退空表）；加载路径为**数据目录** `koreader/settings/`（datastorage.lua:59-61）
- 键级覆盖安全：只替换出现的键（menusorter.lua:36-40）
- 去重确认：order 命中后 item_table 置 nil（menusorter.lua:70-74），sorting_hint 不会二次插入
- **两份文件必须分别照抄**：reader 版 tools 含 progress_sync（reader_menu_order.lua:181），filemanager 版无（filemanager_menu_order.lua:122-137）；写错方向不崩溃但静默破坏排序
- separator 照抄安全（order 路径 67-69 + compress 86-91 处理）
- dispatcher.lua 的 dispatcher_menu_order 是独立机制，与本文件无关
- OTA 遮蔽的真实表现：升级后新 tools 内置项走孤儿路径追加到 tab **末尾**（不丢失、不加 "NEW:" 前缀）——比预想温和，文档注明"升级后重新生成"即可

**方案整体复审（无致命，3 重要已并入）**：
1. §3.6.3 手动同步按钮 enabled_func 删除（2862/2870）——离线模式核心可用性
2. §4.2 local_notes_root 为新增项非搬迁（初稿错误已纠正）
3. §3.6.4 无书守卫（书库场景文案误导）
- 建议 4-6 亦已并入（死代码清理、AI 文案改写、实施顺序合并，见 §九.1）
- checked_func 即时求值与 sub_item_table_func 重进求值的设计与 touchmenu 机制吻合，无其他误依赖

## 十一、fns_sync.conf 电脑端配置导入（2026-08-23 用户拍板并入本次改动；三轮审查后修订 v2）

**动机**：API Key/Token 太长，KOReader 虚拟键盘输入痛苦；settings.reader.lua 300+ 行且要求 Lua 语法，手工编辑易错（ai_enabled=false 事故）。先例：KOReader 官方 defaults.custom.lua 同构机制（pcall 损坏不致命模式，luadefaults.lua:18-43）。

### 设计

- **文件**：`koreader/settings/fns_sync.conf`（KOReader 用户数据目录；OTA 安全有源码证据——打包排除清单 Makefile:87-88，Kindle 端 ko_update_check 不触碰）
- **格式**：每行 `key = value`；`#` 注释（**模板中所有键默认注释掉**，用户取消注释并填值才生效）；不用引号/逗号
- **导入时机与锚点**：插件 init，**插入点写死在迁移收尾（main.lua:199）与落盘 saveSetting（main.lua:202）之间**——导入直接写 self.settings，由既有 202 行落盘，无需另调 saveSettings
- **部分键导入**：conf 中出现的键才覆盖，其余保持原值
- **内容指纹**：存**顶层键** `G_reader_settings["fns_sync_conf_hash"]`（不放 fns_sync 表内——onResetConfig 整表替换 1054-1057 不碰顶层键，重置后 conf 不会重新覆盖重置结果，符合"重置"语义）；指纹对**规范化后内容**（去 BOM/CRLF 后）计算，Windows 编辑器改变行尾不触发重复导入
- **模板自导入防护（三轮审查 F1，双保险）**：① 模板所有键以 `#` 注释（取消注释才生效）；② 生成模板的同时写入该模板内容的指纹——即使注释被误删，指纹匹配也不会导入
- **键名白名单（三轮审查 F2 修订）**：仅 Config.DEFAULTS 顶层**标量键**（排除 table 类型 book_overrides/color_emoji_map/ai_quick_prompts，排除默认值含换行的 note_template/excerpt_template——单行 conf 会破坏多行模板）；未知键 logger.warn 不静默失效
- **类型识别（Z3 修订）**：按 DEFAULTS 值类型定，不按内容猜——vault 名叫"123"仍存字符串；DEFAULTS 中数字键仅 debounce_seconds/ai_max_tokens/ai_timeout_sec/ai_temperature，布尔键仅各类开关
- **解析边界（6 项拍板）**：① CRLF：strip 行尾 `\r`（Lua read 保留 \r，残留会让 token 静默失效）；② UTF-8 BOM：strip 文件头；③ 值含 `=`：按第一个等号 split（base64 token 尾部 `==` 常见）；④ 空值：字符串键视为清空 ""，布尔/数字键跳过 + warn；⑤ 重复键：后行覆盖 + warn；⑥ 非法行（无等号/空键名）：warn 跳过
- **解析健壮性**：全程 pcall 包裹，损坏时 warn + 保留旧设置（对齐 defaults.custom.lua 模式）
- **IO 惯例**：对齐 localstore.lua（M9 已实测）——`require("datastorage"):getSettingsDir()`、`lfs.attributes` 判存在、`io.open` `read("*a")` 整读、写模板用 `\n`；模板注释注明"存为 UTF-8（无 BOM）"
- **日志打码**：导入记录写 crash.log，API Key/Token 值打码（仅键名与长度）
- **升级安全**：conf 在插件文件夹外，复制插件升级不触碰；DEFAULTS 回填只补 nil 键（main.lua:96-106）

### 新增单测（三轮审查后扩充）

tests/test_conf_import.lua：格式解析（注释/空行）；**BOM/CRLF/值含等号/空值/重复键/非法行** 6 类边界；**vault="123" 类型不误判**；**模板自导入防护**（生成模板后重启不导入示例值）；**onResetConfig 后指纹不重导**；部分键导入；指纹不变不导入/变化导入；白名单拒绝（table 键/模板键/未知键）；损坏文件 pcall 容错。

## 十二、实施顺序

1. **gating + 菜单重构 + conf 导入合并为一个提交**（二轮审查：gating/菜单分步会产生中间态混乱；conf 与 M10 同动 main.lua init，一并落地）+ 新增单测（gating + conf）→ 全量测试
2. 生成 menu_order 文件（§4.1.1，基于 Kindle 部署版两份 elements 文件分别照抄，fns_ai 插 tools 首位，保留 separator 与 more_tools）
3. 部署 Kindle → 真机验证清单（离线三件套 / FNS 模式 / 工具 tab AI 首位 / 设置▸网络 FNS / conf 导入：电脑端改 ai_api_key → 重启生效）
4. git + progress
