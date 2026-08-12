# 2026-08-12 开发进度

## 主要任务

**全天（M8 AI对话功能开发与回滚）**：添加完整的 AI 对话功能（ai.lua、ai_config.lua、高亮菜单集成），因多个未解决的技术问题导致长按闪退，最终回滚到 8月11日版本。

## 故障经过（盲目实现 → 缺乏调查 → 越修越坏 → 回滚）

| 时间 | 事件 |
|------|------|
| 上午 | 添加 ai.lua、ai_config.lua 等 M8 核心模块 |
| 上午 | main.lua 添加"问 AI"菜单项和 _askAI() 方法 |
| 下午 | 发现两个问题：API配置无法加载、长按高亮菜单没有按钮 |
| 下午 | 没有调查问题根因，直接写代码修复 |
| 下午 | 修复后发现问题依然存在：API仍显示未配置、高亮菜单仍没有按钮 |
| 晚上 | 用户要求全盘审查 M8 代码，发现多个错误： |
| - | aiConfigOverrideLoader 使用 require，导致缓存问题 |
| - | onShowHighlightMenu 事件根本不会被 KOReader 调用 |
| - | 缺少 init() 中的高亮按钮注册代码 |
| 晚上 | 根据调查结果修复代码，重新提交 |
| 晚上 | 用户测试发现长按直接闪退，比之前更严重 |
| 晚上 | 用户要求回滚到 8月11日晚上的版本 |
| 晚上 | 执行 `git reset --hard b219caf`，删除所有 M8 代码 |

## 根本问题分析

### 问题 1：没有先调查就写代码
- 没有查看 qrclipboard 等参考插件的实现
- 没有查看 KOReader 源码理解高亮菜单机制
- 假设了错误的事件名 `onShowHighlightMenu`
- 盲目写代码，然后让用户测试

### 问题 2：配置加载机制理解错误
- 没有理解 require 的 package.loaded 缓存机制
- 没有检查 KOReader 的插件目录是否在 package.path 中
- 直接写 `pcall(require, path)`，导致首次加载失败后无法重试

### 问题 3：缺乏防御性编程
- 没有检查 state.cfg.quick_prompts 可能为 nil
- 没有检查 self.ui.highlight 在 init() 时是否已初始化
- 代码在边界情况下会崩溃

## 应该的正确流程

1. **先查看参考代码**：qrclipboard.koplugin 如何注册高亮菜单
2. **查看源码**：ReaderHighlight.lua 的高亮菜单机制
3. **理解机制**：KOReader 使用 addToHighlightDialog() 而不是事件回调
4. **设计方案**：基于调查结果设计正确的实现
5. **编写代码**：按照方案实现
6. **自测审查**：检查边界情况和错误处理
7. **然后** 才让用户测试

## 回滚详情

**删除的文件**：
- `plugin/fns_sync.koplugin/ai.lua`
- `plugin/fns_sync.koplugin/ai_config.lua`
- `plugin/fns_sync.koplugin/ai_config_override.lua.example`
- `tests/test_ai.lua`
- `tests/test_ai_config.lua`
- `tests/test_marker_ai.lua`
- marker.lua 中的 AI@ 块支持代码
- main.lua 中的所有 M8 相关代码

**当前状态**：
- 插件恢复到 8月11日晚版本
- 只有 FNS 同步功能（M1-M7）
- 没有 AI 对话功能
- 长按高亮恢复正常

## 经验教训

1. **永远不要基于猜测写代码**
   - 先看参考代码
   - 再看源码
   - 然后写代码

2. **不要让用户测试未审查的代码**
   - 先自己审查
   - 检查边界情况
   - 添加错误处理

3. **越修越坏时立即停止**
   - 回滚到最后一个工作版本
   - 重新调查问题
   - 不要继续堆叠修复

## 下一步计划

**M8 重新启动**（待定）：
- 如果要重新实现 AI 对话功能，需要：
  1. 仔细研究 qrclipboard.koplugin 的实现
  2. 查看 ReaderHighlight.lua 的源码
  3. 设计正确的实现方案
  4. 逐个功能实现并测试
  5. 每个功能自测通过后再让用户测试
