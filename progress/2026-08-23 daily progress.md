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

# M10 菜单重设计 + conf 电脑端导入（当日主体工作）

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

## 二轮真机待验证

- 离线区新 toggle 结构（自动写本地笔记开 → 高亮 5 秒自动写）
- 工具 tab 首位出现 AI 读书助手（menu_order 生效）
- （可选）删除高亮 → 手动同步 → 对应 AI@ 一起消失（drop 逻辑）
