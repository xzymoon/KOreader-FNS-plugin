# 2026-08-23 daily progress

## 修复：AI 助手菜单死锁导致"问 AI"无法启用

### 问题现象

用户在 Kindle 上配置好 AI（API Key / Base / 模型均已填入 `settings.reader.lua`），但高亮菜单中"问 AI"按钮始终不显示；被迫手工编辑 `settings.reader.lua`，改动又反复被"写回"。

### 诊断过程

1. **按钮显示条件**（main.lua 高亮菜单 `show_in_highlight_dialog_func`）：需要
   - `ai_enabled == true`（严格布尔比较）
   - `ai_api_key` 非空
   用户三项中只差 `ai_enabled`（仍为 false）。

2. **"写回"机制还原**（用户怀疑"未配置 FNS 导致插件重置"）：
   - 代码审查排除：`ai_enabled` 仅有三个写入点（DEFAULTS nil 回填 / 菜单 toggle / 版本迁移不触碰），**不存在**"FNS 未配置即关闭 AI"的逻辑。
   - 真正机制：用户手工编辑时 KOReader 旧进程仍存活（Kindle 连 USB 不一定杀进程），退出时内存旧设置整表覆盖文件。
   - 铁证：`settings.reader.lua` mtime（PC 显示 10:42:34 +0800）与 crash.log 中 KOReader 退出时刻（设备时间 18:42:34）**秒级吻合**（8 小时为时区显示差异）。

3. **根因——菜单死锁**：
   - main.lua "AI 助手"子菜单入口的 `enabled_func` 要求 `ai_enabled == true` 才能点开；
   - 而打开 `ai_enabled` 的开关（"启用 AI 对话"）**就在该子菜单内部**；
   - 关闭状态下菜单无法进入 → 唯一入口被锁死 → 用户被迫手工编辑文件。

### 修复

- 删除"AI 助手"菜单项的 `enabled_func`（子菜单始终可进入；内部开关用 `checked_func` 显示状态，符合 KOReader 插件惯例）。
- 注释中说明不可再加回 `enabled_func` 的原因，防止回归。

### 验证

- 本地测试：167 项全部通过（ai_chat 23 + config_ai 14 + localstore 28 + marker_ai 83 + threeway 19），与 M9 基线一致，无回退。
- 已部署到 Kindle（H:\koreader\plugins\fns_sync.koplugin\main.lua，diff 一致）。

### 用户侧操作指引（已告知）

- `settings.reader.lua` 中 `ai_enabled` 已改为 `true`（USB 模式下 KOReader 进程已退出，本次改动不会被覆盖）。
- 拔线后从 KUAL 重新启动 KOReader，高亮菜单即出现"问 AI"。
- 手工编辑设置文件的正确姿势：必须先完全退出 KOReader（菜单退出或重启设备），再连 USB 编辑。
- 安全提醒：API Key 已出现在对话/明文文件中，测试完成后建议到 DeepSeek 后台轮换。

---

## M10 菜单重设计 + conf 电脑端导入（当日主体工作）

方案文档：`docs/superpowers/plans/2026-08-23-m10-menu-redesign.md`（v4，三轮子代理审查全过：菜单机制源码验证 ×2 + gating 逻辑 ×2 + conf 机制 ×2）。

## 实施（一个提交落地）

1. **语义重定义**：`enabled` 从功能总开关改为**模式开关**（true=FNS 服务器，false=离线本地）；`_isLocalMode()` 改为 `not enabled`；本地模式零门槛（手动同步/AI 加笔记不再被拦——实测 C3 验证通过）。
2. **gating**：新模块 `gate.lua`（isLocalMode/syncEntry/autoSyncAllowed/pullAllowed 纯函数，20 项单测）；main.lua 七处改造（含 `_gateAutoSync` 去 enabled、拉取调度 FNS-only）。
3. **菜单**：FNS 同步 → 设置▸网络（`sub_item_table_func` 按模式动态生成）；AI 读书助手 → 工具 tab 独立入口（`menu_items.fns_ai`）；删除旧总开关/全部历史/旧"设置"包装层。
4. **conf 导入**（`confimport.lua`，43 项单测）：`settings/fns_sync.conf` 电脑端编辑一处生效；部分键导入 + 内容指纹防打架（顶层键，onResetConfig 不误删）+ 白名单类型过滤 + 模板全注释双保险 + BOM/CRLF/首等号/空值/重复键/非法行六项边界。实测 D1-D3 全过。
5. **menu_order**：`H:\koreader\settings\reader_menu_order.lua` 把 fns_ai 插工具 tab 首位（基于 Kindle v2026.07.2 实际列表生成；OTA 升级后需重新生成）。

## 真机测试（第一轮）结果与修复

通过：A1-A7、B2-B4、C1-C4、D1-D3。发现并修复两个问题：

1. **离线区"自动写本地笔记"无法开启**（B1 失败根因）：外层复选框仅为状态显示（KOReader 带子菜单项点击=进入），子菜单又漏了启用开关 → 无处开启。修复：改为**纯 toggle + 独立"写入时机"子菜单**（用户实测反馈驱动）。注：用户 settings 中 auto_sync_enabled=false 为历史值，修复后可在菜单直接打开。
2. **orphaned AI@ 块残留**（C 组反馈）：M8 的 LOW-4 行为（宿主高亮已删的 pending AI 以 orphaned 追加到笔记末尾）会"复活"用户已删除高亮的 AI 回答，且永不清理。**用户拍板：宿主没了就删**。修复：`marker.lua drainAiBlocks` 改为 drop（drained 含 dropped 块确保 pending 清理）；测试 14/25 适配；Kindle 笔记文件中历史 orphaned 块已手工清理。

## 部署

全部 8 个插件文件 + menu_order 已部署 H:\koreader（diff 验证一致）；测试 230 项全过（原 167 基线 + gate 20 + conf 43）。

## 二轮真机待验证（清单，结果见下节）

- 离线区新 toggle 结构（自动写本地笔记开 → 高亮 5 秒自动写）
- 工具 tab 首位出现 AI 读书助手（menu_order 生效）
- （可选）删除高亮 → 手动同步 → 对应 AI@ 一起消失（drop 逻辑）

## 二轮真机验证（21:07-21:09）：全部通过，M10 闭环

1. 工具 tab 首位出现 AI 读书助手（menu_order 生效）✓
2. 离线区纯 toggle 勾选"自动写本地笔记"后，高亮/删除事件 5 秒自动写本地 md ✓
   ——日志证据：`21:08:15 onAnnotationsModified(hl_added=-1) → 21:08:20 sync start (auto)`
3. 删除带 AI 回答的高亮 → 同步后 HL@ 与 AI@ 一起消失 ✓
   ——日志证据：`deleting AI@ ts=21:07:34 (cascade from HL@21:06:22)`；笔记文件仅剩配对块

## 第三轮：FNS 服务器模式真机验证（第二台 Kindle，21:24-21:35）

第二台 Kindle（自建 FNS 服务 notesync.xzymoon.top:8444，enabled=true + 配置完整——正是方案 §五 承诺的兼容路径：旧 FNS 用户升级 M10 后行为不变）。M10 已由用户部署（文件 diff 一致）。

结果：**A1-A3、B1-B3 全过**（服务器同步 / AI@ 上传 / 兼容迁移正确：模式开关显示已勾选、conf 模板生成）。三项"未通过"经 crash.log 分析全部澄清为测试时序/清单预期问题，**无代码缺陷**：

| # | 表象 | 日志分析结论 |
|---|---|---|
| B4 | 离线队列未补推 | 机制正常：`21:33:25 enqueued → 21:35:15 picked → offline at last mile (no attempt burn)`。恢复网络后等 NetworkConnected/开书事件触发 drain 是设计行为；补验证=恢复 WiFi 后开任意书 |
| C2 | 无 .uploaded.bak | **清单预期设定错误**（本文档作者之误）：B1 已把笔记同步到服务器（`GET → note exists → diff`），不再满足种子上传前提（服务器无笔记+本地有 md）。代码走正常 diff 更新（+1 成功）为正确行为 |
| C3 | 高亮后不自动同步 | 自动同步实际正常：`21:34:31 sync start (auto) → POST Success -3`（3 个删除事件 5 秒防抖合并）。用户所观察的高亮发生在离线时段（21:33:07 → 走入队，设计行为） |

**FNS 模式验证结论**：服务器同步 ✓、AI@ 上传 ✓、在线自动同步 ✓、离线队列入队/保护 ✓、模式切换 ✓——M10 对存量 FNS 用户无回归。

## 当日总结

- **4 个提交**：2be6bb6（AI 菜单死锁修复）→ a0c0505（M10 主体，+1246/-349）→ 55609d7（二轮验证记录）→ b2219d0（文档收尾）
- **测试基线**：167 → 230 项（新增 gate 20 + conf 43），全过
- **审查**：方案阶段 3 轮子代理审查（KOReader 源码契合 ×2 + 插件逻辑 ×2 + conf 机制 ×2），代码阶段 2 个子代理复审，发现并修复 2 致命（模板自导入/白名单类型）+ 多项重要
- **真机验证**：两台 Kindle 三轮（离线模式两轮 + FNS 服务器模式一轮），全链路通过；两台均已部署 M10 最终版
- **遗留事项**：① KOReader OTA 升级后 tools 列表若变化，需重新生成 reader_menu_order.lua；② 种子上传（.uploaded.bak）场景待自然验证——需"服务器无此书笔记 + 本地已有 md"前提，留给日常使用中遇到（逻辑已由 M9 单测覆盖）；③ automem-memory.txt / claude-debug-log.txt 为会话文件，保持不提交

## 收尾：README 全面更新 + GitHub 推送（ec7327e）

- README.md / README.en.md 重写至 M10：双模式简介、功能三分区（笔记同步/AI 助手/conf）、新菜单树、conf 配置方式、FNS 服务端改为可选、隐私章节路径更新
- 新增 `extras/reader_menu_order.lua`（安装可选步骤：AI 入口钉工具 tab 首位）
- 推送 170e174..ec7327e（M9 4 个 + 本日 6 个提交）

## 收尾：Release 体系修正（v1.2.0 发布 + 旧版补附件）

- 发现旧 release 无自定义附件（用户看到的"整项目打包"是 GitHub 自动 Source code 链接，平台标配不可移除）
- v1.2.0 发布（M10）：附件 fns_sync-v1.2.0.zip = fns_sync.koplugin/ + reader_menu_order.lua + INSTALL.txt（81.8K）
- v1.1.0 / v1.0.0：从对应 git tag 检出插件代码分别打包补传（70.8K / 37.0K），下载即用

## 修复：删光高亮后本地笔记块残留（M9 时代遗留缺陷）

- 现象（Kindle① 21:56）：用户删除书中全部 2 条高亮 → 自动同步触发（21:56:28 local mode 日志）但无 sync start——被"空高亮守卫"静默拦截，笔记文件块残留。
- 根因：两道防误删守卫（_triggerSync:1212 与 _doSyncCurrentBookLegacy:1354，M6/M9 时代为防"空推送清空服务器笔记"而设）**无差别拦截**了本地模式——而"用户删光高亮"恰是需要落盘清空的场景。
- 修复（风险分级）：本地模式（手动/自动）0 高亮 → **执行清空**（本地可恢复：高亮存于 metadata.lua，重新同步即重建）；FNS 模式保留跳过（空推送一键清空服务器笔记风险过高），仅 M7 双向拉取豁免照旧。
- 验证方式：重新打开该书 → 点"同步到本地笔记"或关书 → 文件中 HL@/AI@ 块应全部清除（保留模板头）。

- 验证结果（用户实测）：通过——重新打开《女性主义40年》→ 同步 → 残留的 2 对 HL@/AI@ 块全部清除，仅剩模板头。修复闭环（b7b57aa + v1.2.0 附件重传）。
