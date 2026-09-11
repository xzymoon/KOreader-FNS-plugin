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
