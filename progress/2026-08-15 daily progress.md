# 2026-08-15 开发进度

## 主要任务

**M8 Task E-step1：DeepSeek 反复网络错误 / AI 回复为空——诊断 + 修复**

用户反馈"反复出现网络错误，AI 回复为空"，连上 Kindle（H:）抓 crash.log 诊断。结论：**不是网络问题，是两个代码 bug**，均在 PC 上复现验证。

---

## 阶段一：诊断

### 日志证据（crash.log 22:15-22:19 段）

```
22:15:31 POST /chat/completions → 22:15:42 WARN wantread        ← 恰好 ~10 秒
22:18:38 POST → 22:18:48 WARN empty content in response:
  {"choices":[{"message":{"content":"","reasoning_con...  ← content 空、reasoning 有
22:18:56 / 22:19:29 同样 empty content，连续 3 次
```

### PC 复现验证（从电脑直接调 DeepSeek API）

| 实验 | 结果 |
|------|------|
| 简单问题 | ✅ 1.5s 成功，content 48 字 |
| 读书类长问题（模拟 199 字选段）| ⚠️ **9.8 秒**才回完，输出 951 tokens（贴着 1024 上限）|
| 强制 max_tokens=100 | ❌ 复现 Kindle 现象：`finish_reason:"length"`, `content:""`, reasoning_tokens=100 |

### 根因

`deepseek-v4-flash` 是**推理模型**：先消耗 token 打草稿（reasoning_content），再写正文（content）。两个坑：

1. **wantread**：ai.lua 硬编码 `Config.AI_HTTP_TIMEOUTS = {10, 60}`（block 10 秒），忽略已存在的 `settings.ai_timeout_sec = 30`。读书类问题推理 10 秒+，Kindle 网络稍慢即撞线。config 注释写着"DeepSeek 推理可能要 30 秒"，代码却没用这个值——Task B 遗留 bug。
2. **AI 回复为空**：max_tokens=1024 上限被推理草稿耗光，正文一个字没写 → `content=""` + `finish_reason="length"`。

时好时坏的原因：问题简单 → 推理短、回复快（<10s）→ 碰巧躲过两个坑；问题复杂 → 全踩。

---

## 阶段二：修复（TDD）

### 红：新测试文件 tests/test_ai_chat.lua

首次跑：7 项失败，正好覆盖三个修复点。（中途发现 mock 签名错误：ai.lua 冒号调用 `socketutil:set_timeout`，mock 需按 `(self, block, total)` 接收——已对照 KOReader 源码 `frontend/socketutil.lua:52` 确认真实签名。）

### 绿：三个修复

| 修复 | 文件 | 改动 |
|------|------|------|
| 超时接线 | ai.lua | `set_timeout(tonumber(ai_timeout_sec) or 30, ×4)`，删除硬编码常量 |
| max_tokens | config.lua | 默认 1024 → 4096（含注释说明推理模型占用）|
| 明确报错 | ai.lua | `finish_reason=="length"` → "思考过程用尽了字数上限，请调大 max_tokens"；否则维持"AI 回复为空" |
| 版本迁移 | main.lua | v5→v6：存量 `ai_max_tokens==1024`（含字符串 "1024"）升到 4096；用户自定义值保留 |
| 清理 | config.lua / ai.lua | 删除 `Config.AI_HTTP_TIMEOUTS`（孤儿常量）+ ai.lua 的孤儿 `require("config")` |

---

## 阶段三：Code Reviewer agent 审查

Verdict: WARNING（核心修复正确可提交，1 HIGH 建议带上）

| 级别 | 问题 | 处理 |
|------|------|------|
| HIGH-1 | "正在思考…"提示**从未被绘制**：KOReader 主循环先跑 nextTick 任务再 repaint，阻塞的 Ai:chat 执行时 loading 还没上屏；修复前 10 秒就失败冻结短，修复后 15-40s+ 无反馈，用户会误判死机 | ✅ 已修：`UIManager:show(loading)` 后加 `forceRePaint()`。这解释了昨天"点了问 AI 没反应" |
| MEDIUM-1 | `_editString` 菜单存的是字符串："1024" 不被迁移匹配；且字符串直传 JSON 会变 `"max_tokens":"4096"`（API 400）| ✅ 已修：迁移处 + ai.lua 均加 tonumber（temperature 同）|
| MEDIUM-2 | `ai_timeout_sec=0` → set_timeout(0,0) → 全部请求秒失败 | ✅ 已修：`<=0` 回退 30 |
| LOW-1 | max_tokens 菜单 hint 仍是 "1024" | ✅ 已修：改 "4096" |
| LOW-2 | v5→v6 迁移日志无条件打印"1024→4096"误导诊断 | ✅ 已修：按实际动作分支打印（对齐 v3→v4 先例）|
| LOW-3 | total timeout=×4 只是名义上限（socket 层 't' 模式会被重置）| 不改（与 api.lua 同款模式，风险已知）|
| LOW-4 | 测试缺 reset_timeout 断言 + 网络错误路径 | ✅ 已补：+9 项测试 |

### 最终测试

**112 项全过**：config_ai 14 + ai_chat 23（新文件）+ marker_ai 56 + threeway 19。语法检查（luajit -b）main.lua / config.lua / ai.lua 全 OK。

---

## 改动文件清单

| 文件 | 改动 |
|------|------|
| `plugin/fns_sync.koplugin/ai.lua` | 超时接线 + tonumber 强转 + 下界保护 + finish_reason 区分报错 + 删孤儿 require |
| `plugin/fns_sync.koplugin/config.lua` | 版本 5→6 + ai_max_tokens 4096 + 删 AI_HTTP_TIMEOUTS |
| `plugin/fns_sync.koplugin/main.lua` | v5→v6 迁移 + forceRePaint + 菜单 hint 4096 |
| `tests/test_ai_chat.lua` | 新文件，23 项测试 |
| `tests/test_config_ai.lua` | 断言更新（版本 6 / 4096 / 删常量断言）|

已部署到 Kindle（H:/koreader/plugins/fns_sync.koplugin/，3 个文件 cmp 校验一致）。

---

## 安全备注

诊断过程中一条 sed 命令的打码正则未生效，将 Kindle settings.reader.lua 里的 DeepSeek API key 完整打印进了会话输出。该 key 仅在本机会话记录中暴露；如会话记录可能被分享，建议去 DeepSeek 后台换 key。

---

## 阶段四：下午实测结果（T0-T6 清单）

| 测试 | 结果 | 日志证据 |
|------|------|----------|
| T0 重启迁移 | ✅ | `migrated settings v5→v6: ai_max_tokens 1024 → 4096` |
| T1 深入解释复测 | ✅ | 5 秒成功 1237 字（此前必失败场景）|
| T2 快速问题回归 | ✅ | 2 秒成功 |
| T3 同一高亮连续追问 | ❌→已定位 | 三次 wantread **精确 30 秒**（11:29-12:59）；重试 3/6/17 秒成功——多轮上下文推理超 30s，`ai_timeout_sec=30` 仍不够 |
| T4 已有高亮 AI 块紧贴摘录 | ✅ | hl_ts 正确（Phase 3.E 完成）|
| T5 断网加笔记不丢（手机热点）| ✅ | 恢复后 commit（Phase 3.B 完成）|
| T6a 飞行模式问 AI | ✅ | 报网络错误不闪退（Phase 4 完成）|
| T6b 快速连续加两块 | 取消 | Kindle 反应速度不允许；日志间接证明：当日 3 次 commit 全部"正好一次" |

附：10:17:41 `temporary failure in name resolution` = 切热点瞬间 DNS 失败，预期行为。

**Phase 1-5 至此全部完成**（3.A/3.B/3.C/3.D 由方案 Z 验证与 T3-T5 覆盖，3.E 由 T4 覆盖）。

## 阶段五：超时 30→60（T3 修复）

- 根因：多轮对话（5 条消息上下文）推理时间超 30 秒，三次精确 30s wantread 为铁证
- 改动：config.lua DEFAULTS 60 + 版本 v7 + main.lua v6→v7 迁移（30→60，tonumber 兼容字符串）+ ai.lua fallback/下界 60
- 用迁移而非手改 Kindle settings.reader.lua：避免"KOReader 运行中退出覆盖手改值"的时序坑（与 v5→v6 同模式）
- 测试：config_ai 14 + ai_chat 23（显式 30 仍被尊重的用例保留）+ marker 56 + threeway 19 = 112 全过
- 已部署 Kindle（重启 KOreader 后生效）

## 用户提出的新需求（下一轮）

1. **删除高亮应级联删除其附属 AI 块**——现状 AI@ 残留成孤儿（详见方案 B）
2. **"加入笔记"后对话框不应关闭**——应可继续追问（详见方案 A）


