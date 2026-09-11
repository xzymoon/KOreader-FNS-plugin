# 2026-09-11 daily progress

## 移除 PayPal 捐赠入口

### 背景

用户的 PayPal 收款一直未配置成功，决定移除仓库中所有 PayPal 捐赠入口，仅保留微信二维码赞助。

### 改动内容

排查发现 PayPal 入口共 3 处（不止 README 页面可见的徽章）：

| 位置 | 改动 |
|------|------|
| `README.md`「赞助」区（原 171 行） | 删除 shields.io PayPal 捐赠徽章，微信二维码保留 |
| `README.en.md`「Sponsor」区（原 171 行） | 同上（英文 README） |
| `.github/FUNDING.yml` | 整文件删除——该文件仅含此 PayPal 链接，是 GitHub 仓库 About 区 **Sponsor 按钮** 的数据源 |

### 说明

- FUNDING.yml 若保留为空文件或残留链接会导致 Sponsor 按钮异常/仍指向 PayPal，故整文件删除；删除后 GitHub 页面 Sponsor 按钮自动消失。
- 微信二维码（`docs/sponsor-wechat.jpg`）不动，赞助区文案保留。
- 历史提交中该链接仍可追溯（git 历史不可改写，属正常）。

### 验证

- `grep -ri paypal README.md README.en.md .github/` 无匹配。
- 推送到 GitHub 后检查仓库页面：README 无 PayPal 徽章、About 区无 Sponsor 按钮。

## License 切换：PolyForm Noncommercial 1.0.0 → AGPL-3.0

### 背景

用户觉得现 license"有点问题"，提议换 AGPL-3.0。排查确认了一个真实存在的合规瑕疵：

- **KOreader 本体是 AGPL-3.0**，本插件 `require` 了 20+ 个 KOreader 源码模块（`ui/widget/*`、`ui/uimanager`、`ui/network/manager`、`docsettings`、`socketutil`、`libs/libkoreader-lfs`、`ffi/util` 等）；
- 按 KOReader 社区一贯立场，koplugin 属于 KOReader 的**衍生作品**，衍生作品必须以 AGPL 兼容条款分发；
- PolyForm Noncommercial（全面禁商用 + 禁止再许可）与 AGPL **不兼容**——当前分发状态本身违反上游授权条款。

换成 AGPL-3.0 是修正而非妥协，且与 KOReader 生态（官方插件全为 AGPL）一致。

### 用户已知的 trade-off（明确确认后执行）

| 失去 | 获得 |
|------|------|
| 「商业使用需授权」的谈判筹码（AGPL 允许开源商用、公司内部使用） | 上游合规；强 copyleft（闭源修改分发/SaaS 仍被禁止）；双许可可能性（用户是唯一版权人，124/124 commits） |

### 改动内容

| 位置 | 改动 |
|------|------|
| `LICENSE` | 全文替换：版权头 + GNU 官网 agpl-3.0.txt 全文（curl 下载保证逐字准确，661 行） |
| `README.md` | 删「商业授权」章节；License 区改为 AGPL-3.0 + 一句话说明 |
| `README.en.md` | 删 "Commercial Licensing" 章节；License 区同步 |
| `plugin/fns_sync.koplugin/README.md` | License 章节改为指向 AGPL-3.0，删商业授权提示 |

Lua 源码无 license header（沿用现状，不加）。

### 历史不可改写（沿 2026-08-05 MIT→PolyForm 同一原则）

- v1.0.0 ~ v1.2.0 release/tag 快照仍是 PolyForm，属诚实历史记录，不动。
- GitHub About 区 license 标签随 master LICENSE 文件自动更新为 AGPL-3.0。

### 验证

- `sed`/`tail` 核对 LICENSE：版权头 → `GNU AFFERO GENERAL PUBLIC LICENSE Version 3, 19 November 2007` → 标准结尾，完整无缺。
- `grep -rin polyform README.md README.en.md plugin/ .github/` 无匹配。
- 推送后核对 GitHub 页面 License 标签与 README License 章节。

