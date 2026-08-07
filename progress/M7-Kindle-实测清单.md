# M7 Kindle 实测清单

> 用户回来后照此清单做 M7 双向同步的 Kindle 实测。完成 Phase 3-4（多 agent 审查 + bug 修复）后开始。

---

## 0. 部署 + 准备

- [ ] 两台 Kindle（A 和 B），都装同一版本 KOreader
- [ ] 把 `plugin/fns_sync.koplugin/` 整个文件夹复制到两台的 `/koreader/plugins/`
- [ ] 重启 KOreader（两台）
- [ ] 两台都已配置 FNS 服务（M5 已实测过）
- [ ] 准备两本 EPUB：《测试书 A》（两台都装同一版本，用于版本一致测试）、《测试书 B》（B 设备装不同翻译版本，用于版本不一致测试）

---

## 1. 回归测试（M5/M6 不能退化）

**关键**：Commit 1-6 都承诺"行为不变性"，必须先验证。

- [ ] A 设备：打开《测试书 A》，划 1 条线
- [ ] 等 5 秒，应该看到 toast"同步成功（+1 更新0 删除0）"
- [ ] A 设备 USB 连电脑，看 `crash.log`：
  ```
  grep "\[FNS\]" /koreader/crash.log | tail -50
  ```
  - 应该看到 `sync start (auto)` → `note exists, doing item-level diff` → `sync success`
  - **不应该**看到 `bidirectional` 字样（因为还没启用双向）
- [ ] A 设备：关书，crash.log 应该看到 `event: onCloseDocument`
- [ ] A 设备：开飞行模式 → 划线 → 关书 → 关飞行模式 → 等几秒 → 应该自动同步（队列生效）
- [ ] A 设备 `settings.reader.lua` 里 `fns_sync_queue` 应该清空

如果以上任何一步失败，**M7 实测暂停**，先排查回归 bug。

---

## 2. 启用双向同步

- [ ] A 设备：菜单 → FNS 同步 → 自动同步 → 双向同步（实验性）→ 启用双向同步
- [ ] 弹出"即将开启双向同步"对话框，文案含【隐私告知】【数据流变化】【首次启用】三段
- [ ] 点"取消" → 状态应该保持关闭
- [ ] 再次点"启用双向同步" → 弹窗 → 点"开启"
- [ ] toast"双向同步已开启"
- [ ] crash.log 应该看到 `bidirectional_sync_enabled=true (first-use confirmed)`
- [ ] 再次点"启用双向同步" → 不应再弹窗（bidirectional_first_use_confirmed 防重弹）
- [ ] B 设备同样启用

---

## 3. 首次双向同步（A 已有数据，B 启用前 server 有笔记）

前置：A 设备已经用 M5 同步过《测试书 A》，server 上有 HL@ 块（无 META 字段，因为是 Legacy 路径写的）。

- [ ] B 设备：菜单 → 立即拉取远端高亮
- [ ] **预期**：toast 显示"双向同步完成：+本地 N -本地 0\n+远端 0 -远端 0\n跳过 N 条"
- [ ] **预期**：所有 server 端旧 HL@ 块因为缺 META 字段都被跳过（`n_skip_no_meta`）
- [ ] crash.log 应该看到多次 `pull insert skipped (server seg has no meta, old note?)`
- [ ] B 设备原文不应该出现高亮着色（因为都被跳过了）

**结论**：这是预期行为——M5 写的旧笔记没 META，无法跨设备恢复高亮位置。需要 M5 重新同步一次（自动覆盖写入 META），下次 B 设备拉取才能成功。

### 3.5 让 A 设备写一次带 META 的笔记

- [ ] A 设备：菜单 → 立即同步当前书（让 A 走 Bidirectional 路径，重写笔记带 META）
- [ ] crash.log 看到 `bidirectional sync success`
- [ ] 在 Obsidian 端打开《测试书 A》笔记，HL@ 起标记应该有 `pos0="..." pos1="..." chapter="..."`
- [ ] B 设备：菜单 → 立即拉取远端高亮
- [ ] **预期**：toast 显示"+本地 N"（N 是 A 设备的旧高亮数）
- [ ] **预期**：B 设备原文出现所有高亮着色，位置正确
- [ ] B 设备高亮列表显示正确文字（不是 markdown 乱码）

---

## 4. 双向新增

- [ ] A 设备：在《测试书 A》新划 2 条线
- [ ] B 设备：同时新划 1 条线（不同位置）
- [ ] 等两台自动同步（debounce 5 秒 + close-document）
- [ ] A 设备 crash.log 应该看到 `threeway actions: +server=1 -server=0 +local=0 -local=0`（B 的 1 条）
- [ ] B 设备 crash.log 应该看到 `threeway actions: +server=2 -server=0 +local=0 -local=0`（A 的 2 条）
- [ ] A 设备应该看到 B 划的 1 条高亮（自动出现）
- [ ] B 设备应该看到 A 划的 2 条高亮（自动出现）

---

## 5. 跨设备删除（KOreader 端删）

- [ ] A 设备：在高亮列表里删掉 1 条
- [ ] 等自动同步
- [ ] A 设备 crash.log 应该看到 `threeway actions: +server=0 -server=1 +local=0 -local=0`
- [ ] Obsidian 端笔记对应的 HL@ 块应该消失
- [ ] B 设备：菜单 → 立即拉取远端高亮
- [ ] B 设备 crash.log 应该看到 `threeway actions: +server=0 -server=0 +local=0 -local=1`
- [ ] B 设备这条高亮应该消失

---

## 6. Obsidian 端删（用户决策 #2：跨设备同步删除）

- [ ] 在 Obsidian 客户端打开《测试书 A》笔记
- [ ] 删掉一个完整的 HL@ 块（从 `<!-- HL@ts` 到 `<!-- /HL@ts -->`）
- [ ] 等 Obsidian sync 到 FNS server（通常即时）
- [ ] A 设备：菜单 → 立即拉取远端高亮
- [ ] A 设备应该看到这条高亮消失（`-local=1`）
- [ ] B 设备同样

---

## 7. 版本不一致（M7 关键场景）

测试用户拍板的"跳过+警告"策略。

- [ ] A 设备：在《测试书 A》划 1 条线，记录这段文字内容（例如"宇宙就是一座黑暗森林"）
- [ ] 等同步到 server
- [ ] B 设备：关掉《测试书 A》，打开《测试书 B》（不同翻译版本，XPointer 定位到不同文字）
- [ ] B 设备：菜单 → 立即拉取远端高亮
- [ ] **预期**：toast 显示"双向同步完成：+本地 0 ... 跳过 1 条（详见 crash.log）"
- [ ] B 设备 crash.log 应该看到 `pull insert skipped (text mismatch, version diff?)` + extracted_head（错的文字）+ server_content_head（对的文字）
- [ ] B 设备原文不应该出现高亮着色（被跳过）
- [ ] B 设备高亮列表也不应该有这条

### 7.5 验证下次同步重试

- [ ] B 设备：再次按"立即拉取远端高亮"
- [ ] crash.log 应该再次看到同样的 mismatch warn（last_synced 没记录这个 ts，自动重试）
- [ ] **关键**：toast 仍然显示"跳过 1 条"，不会因为"已经在 last 里"就放弃

---

## 8. PDF 不支持

- [ ] A 设备：打开一份 PDF，划线，启用双向同步
- [ ] B 设备：在 PDF 划线（仅 server 推送，无拉取）
- [ ] A 设备：菜单 → 立即拉取远端高亮
- [ ] **预期**：toast 显示"双向同步完成"（数字取决于场景）
- [ ] A 设备 crash.log 应该看到 `bidirectional sync: paging mode (PDF?), pull phase will be skipped`
- [ ] A 设备原文不应该有 B 推上来的高亮着色（PDF 不支持拉取）
- [ ] 但 server 端笔记应该有 A 和 B 的高亮（推送仍正常）

---

## 9. 异常路径（可选，看时间）

### 9.1 Server 笔记格式损坏
- [ ] 在 Obsidian 端把笔记的某个 HL@ 起标记改成 `<!-- HL@ts (broken)`（缺 `-->`）
- [ ] A 设备：菜单 → 立即拉取远端高亮
- [ ] **预期**：toast 提示"服务器笔记格式异常（无法解析 HL@ 块），跳过同步以免误删本地高亮"
- [ ] 本地高亮不应该被删

### 9.2 网络中断
- [ ] A 设备开飞行模式 → 按"立即拉取远端高亮"
- [ ] **预期**：NetworkMgr 提示打开 WiFi（手动按钮场景）

### 9.3 同时编辑（A、B 同时划 + 同时同步）
- [ ] 难以精确触发，可观察 crash.log 是否有 race 处理

---

## 10. crash.log 关键 grep

```bash
# 完整 [FNS] 日志（最近 200 行）
grep "\[FNS\]" /koreader/crash.log | tail -200

# 三路合并统计
grep "threeway actions:" /koreader/crash.log

# 跳过原因
grep "pull insert skipped" /koreader/crash.log

# 异常路径
grep -E "pcall failed|format corrupted|anomaly" /koreader/crash.log

# 启用确认
grep "bidirectional_sync_enabled" /koreader/crash.log
```

---

## 11. 验收标准

M7 实测通过需要 **全部** 满足：

1. ✅ 阶段 1：M5/M6 完全没退化
2. ✅ 阶段 2：首次启用弹窗正确显示，bidirectional_first_use_confirmed 防重弹
3. ✅ 阶段 3.5：带 META 的笔记能跨设备恢复高亮
4. ✅ 阶段 4-6：双向同步所有方向（新增、删除）都正确
5. ✅ 阶段 7：版本不一致时跳过+警告，且下次同步重试
6. ✅ 阶段 8：PDF 不支持拉取但推送仍正常
7. ✅ crash.log 没有任何 Lua 错误堆栈
8. ✅ 启用双向同步后，M5 实时同步（高亮即同步）仍正常工作

---

## 12. 失败时排查

| 现象 | 可能原因 | 排查 |
|------|---------|------|
| 启用后按"立即拉取"无反应 | dispatcher 没分流 | grep `bidirectional_sync_enabled` 看是否为 true |
| B 设备拉取后看不到高亮 | server 笔记没 META（旧 Legacy 笔记） | Obsidian 端检查 HL@ 起标记是否含 `pos0="..."` |
| 拉取后高亮位置错位 | 版本不一致 + 校验未生效 | grep `text mismatch` 看是否触发 skip |
| 拉取后 M5 失效 | _pull_in_flight 卡死（H1 bug） | grep `pull in flight`，如果持续出现说明修复未生效 |
| crash.log 有 Lua stack trace | 异常路径未捕获 | 把 stack trace 贴回来分析 |

---

完成实测后，把结果记录到当日 progress 文档。如果有 bug，新建 task 修复。
