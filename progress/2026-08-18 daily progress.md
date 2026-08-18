# 2026-08-18 daily progress

# 2026-08-18 daily progress

## 实测复盘：20:41 网络恢复后 Q+A 合并实测成功 → 用户决策 A+B 去掉占位符

换网后实测成功：AI@ 块成对出现【问】【答】，同步到 Obsidian 正常。
用户对问句中的 `〔原文〕` 占位标记观感不佳（"请把下面这段话翻译成
中文：〔原文〕"句子悬空），决策 **A+B**：

- 快捷提问（翻译/解释/评论按钮）→ 问题只记两字标签（如"翻译"）；
- 手输问题 → 记全文，但把完整包含的原文**整段删除**（不留占位符）；
- 删除后问题为空（如只发了原文本身）→ 退回只写回答。

实现（main.lua `_addAiContentToNote`）：

- 快捷模板匹配：`filled = template:gsub("{text}", original)` 与问题精确
  相等 → 记标签。刻意复刻按钮填充（_openAiInputDialog）的同款 gsub
  写法（含 % 字符的边界行为），保证比对与实际发出的问题一致。
- 删除原文：按字节转义后 gsub 替换为空串 + 首尾空白修剪（" 是什么
  意思"→"是什么意思"；"请解释：\n\n"→"请解释："）。
- "让 AI 总结"问题不含原文、不匹配模板 → 原样记录。
- TextViewer 顶部提示同步改为"写入最后一问一答"。

笔记效果（快捷翻译）：

```
<!-- AI@ … hl="…" model="…" -->
【问】
翻译

【答】
……译文……
<!-- /AI@ … -->
```

test_marker_ai.lua 用例 27 样例内容同步更新；**83/23/14/19 全部通过**，
main.lua 语法检查 OK。

Kindle 复测清单：

1. 快捷"翻译" → 加入笔记 → 【问】下只有"翻译"二字。
2. 手输问题（贴整段原文）→ 原文被删掉、只剩问题本身。
3. "让 AI 总结" → 问题仍记"请总结以上对话"。

## 实测复盘：20:22 首次实测失败 —— Kindle 网络故障（非代码问题）

用户 Kindle 实测报"AI 回复解析失败"+"笔记不自动同步 Obsidian"。crash.log
（/h/koreader/crash.log）诊断结论：

**三个错误全是网络层，与本次代码改动无关**（新代码路径当天未执行到——
AI 调用在网络层就失败了，日志中无 `queued AI@ block (Q+A merged)`）：

| 时间 | 错误 | 层级 |
|------|------|------|
| 20:22:51 | `temporary failure in name resolution` | DNS 解析失败 |
| 20:23:35 | `JSON parse failed: body: <html>` | AI 接口返回 HTML 而非 JSON |
| 20:23:35 起（每次同步） | `GET /api/note network error: tlsv1 alert protocol version` | FNS 服务器 TLS 握手被拒 |

佐证：

- 两个独立服务端点（api.deepseek.com + notesync.xzymoon.top:8444）同时
  出网络层错误；PC 侧实测两服务均正常（0.36s 返回 401 / 0.1s 返回 200，
  TLS 验证通过）→ 故障在 Kindle 当前 WiFi 环境（典型：需登录的门户 WiFi、
  路由器劫持、WiFi 假连接）。
- 昨天（08/17）同一 Kindle、同一配置端到端成功（12:39 success + committed）。
- 部署确认：Kindle main.lua 19:58:52 拷贝，已含新代码（grep `Q+A merged` 命中）。

影响与恢复：

- 今天的高亮不丢：同步失败自动进 M6 离线队列（日志见 queue sync fail +
  back-off），网络恢复后自动重试，或菜单手动"立即同步"。
- 处理建议：断开 USB、换网络（如手机热点）重试问 AI；网络通了再按下方
  实测清单验证 Q+A 合并功能。

## 改动 1：问 AI 加入笔记时合并"问题 + 回答"（M8 优化）

### 背景

用户反馈：AI 问答"加入笔记"后，AI@ 块里只有回答没有问题，笔记可读性差
（不知道当时问了什么）。

### 方案讨论与决策（用户确认）

1. 记录格式：**问题 + 回答完整记录**，与对话窗口的【问】/【答】格式一致。
2. 快捷提问（翻译/解释/评论）模板会把高亮原文整段带进问题 → 写入时把
   **完整包含的原文替换为 `〔原文〕` 占位**（原文已在紧邻的 HL@ 块里，
   避免重复）。
3. 多轮追问仍只记"最后一问一答"（沿用原决策 3 的范围，只加问题）。
4. 旧笔记里的旧 AI@ 块不追溯修改。

### 自查（对照插件代码 + KOreader 源码 E:\koreader-src）

发现并处理：

- **修正 1（必须）**：找"对应问题"的扫描下限定为 index 3 —— messages[1]
  是 system、messages[2] 是"【原文摘录】"引导消息，都不算问题；找不到时
  退回只写回答（防御，正常流程不可达）。
- **实现细节**：原文做 gsub 替换前按字节转义（`[^%w]` → `%%%1`，中文
  多字节逐字节转后仍表字面量），防原文含 `%` `(` `)` 等 Lua 模式特殊
  字符；gsub 双返回值用括号包一层。
- **验证安全**（源码依据）：
  - marker.lua parse（131-207 行）对 AI@ 块内容按字面量捕获，多行安全；
    首尾空白修剪（197 行）不影响本内容（以"【问】"开头、回答结尾）。
  - drainAiBlocks（447-499 行）content 纯透传，孤儿兜底同样透传。
  - KOreader dump.lua:49 用 `string.format("%q")` 序列化，多行字符串
    持久化安全（且 AI 回答本来就是多行，路径已过实测）。
  - 本次改动不调用任何 KOreader API，兼容面为零。
  - 问题放 content 而非 meta：meta 是 `key="value"` 属性拼接，问题含
    双引号会破坏标记行 —— 排除 meta 方案。
- **既有风险（不放大，不处理）**：内容含字面量 `<!-- /AI@… -->` 或结尾
  为 `> ` 会被 parse 提前闭合/修剪 —— 回答内容今天就有同样风险面。
- **接受的小瑕疵**：高亮特别短（一个词）且手输问题恰好含该词 → 会被
  替换成〔原文〕，语义仍通，不加长度阈值规则。

### 代码改动

**main.lua `_addAiContentToNote`**（唯一函数改动）：

- 找最后一条 assistant 时同时记下位置 `last_assistant_idx`。
- 从 `last_assistant_idx - 1` 向下扫到 3，取最近的 user 消息为问题。
- 问题中完整包含的原文替换为 `〔原文〕`（按字节转义后 gsub）。
- `content = "【问】\n" .. q .. "\n\n【答】\n" .. 回答`；无问题退回纯回答。
- **防重复键不变**：仍比较纯回答文本（`last_added_assistant`）。
- pending 块结构（ts/hl_ts/model/book_path）不变，同步/级联删除/孤儿
  兜底路径全部照旧。
- 日志 chars 改为记合并后的总长度。

**tests/test_marker_ai.lua** 新增用例 27：Q+A 合并内容（含【问】【答】
〔原文〕、多行、特殊字符 `%d` 与括号）走 drain→serialize→parse→serialize，
断言幂等 + 内容逐字保留 + 标签完整。

说明：main.lua 的拼接/转义逻辑依赖 KOreader UI 全家桶，无法单测（项目
惯例：main.lua 改动走"语法检查 + Kindle 实测看 crash.log"）；转义逻辑
已手工推演 + 下方实测路径验证。

### 测试结果

- test_marker_ai.lua：**83 passed, 0 failed**（含新增 4 项断言）
- test_ai_chat.lua：23 passed, 0 failed
- test_config_ai.lua：14 passed, 0 failed
- test_threeway.lua：19 passed, 0 failed
- main.lua loadfile 语法检查 OK

### Kindle 实测清单（待用户执行）

1. 选一段文字 → 问 AI → 点"翻译" → 发送 → 加入笔记 → 同步。
2. Obsidian 确认 AI@ 块：【问】下是"请把下面这段话翻译成中文：〔原文〕"，
   【答】下是翻译全文。
3. 手动输入一个自拟问题（引用部分原文）→ 加入笔记 → 确认整段包含的原文
   被替换、部分引用保留。
4. 点"让 AI 总结" → 加入笔记 → 确认问题记为"请总结以上对话"。
5. 同一回答连点两次"加入笔记" → 第二次仍应提示"已加入过"（防重复未变）。
6. crash.log grep `[FNS-AI]`，确认有 `queued AI@ block ... (Q+A merged)`。
