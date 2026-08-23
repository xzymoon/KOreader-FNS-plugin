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
