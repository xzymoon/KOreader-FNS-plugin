# 2026-08-22 daily progress

## M9 启动：无 FNS 本地模式设计拍板（未写代码）

### 决策过程

用户选择 C 方向（结合 KOReader note 字段 + 本地 md），经代码调研后细化为
**分工式 C**（用户确认）：

- AI@（问答，多行长文本）→ 本地 md 文件（唯一落点；note 字段装不下）
- HL@（高亮+短笔记）→ KOReader 原生高亮（现状不动），本地 md 生成时带上
  HL@ 做配对上下文
- 不做双源回写（note 字段不承诺同步，避免 diff/合并复杂度）

AskUserQuestion 三项拍板（均选推荐项）：

| 决策点 | 结论 |
|--------|------|
| 本地 md 根目录 | KOReader 统一目录 `FNS-Notes/`（保留 note_path_prefix 结构，USB 一次拷走） |
| 查看入口 | 包含：菜单「查看本地笔记」→ TextViewer（~30 行） |
| 后配 FNS 迁移 | 自动种子上传：first-create 时服务器无笔记且本地 md 存在 → 直接 POST 本地内容 |

### 调研结论（设计依据）

1. **AI 入口已解耦**：问 AI 按钮只看 `ai_enabled`（main.lua:280），
   "没 FNS 也能问 AI"现已成立，无需改动。
2. **同步管线几乎全本地**：Legacy 路径（main.lua:1249）仅 `Api:getNote`
   （1274）+ `Api:overwriteNote/createNote`（1342/1385）是网络调用，
   parse/diff/applyDiff/drain/cascade/serialize 全是纯本地计算。
3. **resolvePath 纯本地**（excerpt.lua:244），本地模式直接复用相对路径。
4. **pending AI 块已持久化**（G_reader_settings），无 FNS 时数据不丢，
   只是 `_triggerSync`（main.lua:1162）拦截后不可见。

### 架构要点

- 模式判定自动推导（零配置）：`isConfigured()` false → 本地模式，true →
  现有行为 100% 不变。
- 新文件 `localstore.lua`：与 `Api` 签名兼容的
  getNote/overwriteNote/createNote（本地文件 IO）；`_doSyncCurrentBookLegacy`
  参数化注入 store，管线代码零复制。
- M6 队列/M7 双向 pull 在本地模式跳过；级联删除/防重复/Q+A 格式自动复用。

### 产出

- 设计文档：`docs/superpowers/plans/2026-08-22-m9-local-mode.md`
  （含改动清单、测试策略、Kindle 实测清单、风险边界）
- 预估核心改动：localstore.lua 新增 ~80 行 + main.lua ~200 行 +
  config.lua ~3 行 + 单测 ~150 行

### 下一步

用户确认后开始实现（待询问"是否可以开始改动"）。
