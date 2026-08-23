# KOreader FNS Sync Plugin

[English](./README.en.md) | 中文

把 KOreader 里的高亮和笔记同步出去——**两种模式自由切换**：连 [Fast Note Sync](https://github.com/haierkeys/fast-note-sync-service) 服务端同步到 Obsidian，或**无需任何服务器**直接写设备本地 Markdown。另有独立的 **AI 读书助手**模块，两者可单独使用。

## 功能

### 📝 笔记同步（FNS 同步模块，位于 设置 ▸ 网络）

- 🏠 **离线本地模式**（默认，零配置）：不勾"FNS 服务器模式"即用——高亮/AI 回答直接写到设备本地 `FNS-Notes/` 目录的 Markdown 文件，USB 连电脑即可查看
- 🔌 **FNS 服务器模式**（可选）：勾选模式开关并填写服务信息，同步到 Obsidian（基于 [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service) REST API）
- ✨ **自动同步**（高亮修改 / 关书时自动触发，debounce 合并连续操作；两种模式下均可用）
- 📦 **离线队列**（FNS 模式：断网入队、联网自动补推、失败重试 + 冻结机制）
- 🔄 **跨设备双向同步**（FNS 模式实验性：三路合并，在 Obsidian 删除 HL@ 块 = 跨设备删除高亮）
- 🌱 **种子迁移**：离线模式产生的本地笔记，后配 FNS 服务器首次同步时自动作为种子上传
- 📝 **条目级 HL@ marker**（你在 Obsidian 端穿插编辑的内容会被保留）
- 🎨 **可定制模板**（摘录 / 笔记 / 文件名模板、颜色 emoji）
- 📚 **每本书独立 override 书名/作者**（适合合集场景）

### 🤖 AI 读书助手（独立模块，位于 工具 tab 首位，与 FNS 完全解耦）

- 选中文字长按 **问 AI**，DeepSeek 等 OpenAI 兼容 API 多轮对话
- 快捷按钮：翻译 / 解释 / 评论 / 总结（提示词可自定义）
- 问题+回答一键**加入笔记**，紧贴原文摘录；删除摘录时 AI 回答自动级联删除
- 只用 AI 不用同步？完全可以——两个模块互不依赖

### 🖥️ 电脑端配置（USB 连接编辑一处文件即可）

API Key 太长、Kindle 键盘难输入？连接 USB 编辑 `koreader/settings/fns_sync.conf`（简单 `key = value` 格式，重启 KOReader 生效），只写你关心的键，其余设置不受影响。

## 安装

1. 下载 [最新版本](https://github.com/xzymoon/KOreader-FNS-plugin/releases) 或 clone 本仓库
2. 把 `plugin/fns_sync.koplugin/` 整个目录复制到 KOreader 的 `plugins/` 目录：
   - **Kindle**：USB 连接后拷贝到 `<KINDLE>:/koreader/plugins/fns_sync.koplugin/`
   - **其他设备**（Android / Desktop / 等）：参考 KOreader 文档的插件路径
3. （可选，推荐）复制 `extras/reader_menu_order.lua` 到 `<KINDLE>:/koreader/settings/`——把"AI 读书助手"钉在工具 tab **第一位**（不复制则排在工具 tab 末尾，功能不受影响）
4. 重启 KOreader

## 菜单结构

两个独立入口（`[✓]` 表示开，`[ ]` 表示关）：

**FNS 同步** —— 位于 设置 ▸ 网络。第一项是**模式开关**，勾选状态决定显示哪一组功能（切换后返回重进子菜单刷新）：

```
FNS 同步（设置 ▸ 网络）
├─ [ ] FNS 服务器模式          ← 模式开关：勾选=FNS 服务器，不勾=离线本地
│
├─ ── 以下离线模式显示（默认）──
│   ├─ [✓] 自动写本地笔记
│   ├─ 写入时机
│   │   ├─ [✓] 高亮修改时自动写
│   │   ├─ [ ] 关闭书籍时自动写
│   │   └─ 写入延迟（秒）
│   ├─ 本地笔记存储位置
│   ├─ 同步到本地笔记（手动）
│   └─ 查看本地本书笔记
│
├─ ── 以下 FNS 服务器模式显示 ──
│   ├─ 服务设置
│   │   ├─ FNS 服务 URL / API Token / Vault 名
│   │   └─ 测试连接
│   ├─ 立即同步当前书
│   ├─ 自动同步
│   │   ├─ [✓] 启用自动同步
│   │   ├─ [✓] 高亮修改时同步 / [ ] 关闭书籍时同步
│   │   ├─ 同步延迟（秒）
│   │   └─ 双向同步（实验性）
│   │       ├─ [ ] 启用双向同步 / [ ] 开书时自动拉取
│   │       └─ 说明
│   ├─ 立即拉取远端高亮
│   └─ 离线队列
│       ├─ [✓] 启用离线队列
│       ├─ 待同步队列(N 本) / 重试冻结条目 / 清空队列
│
├─ ── 两种模式共用 ──
│   ├─ 当前书信息（📁 文件名 / 📖 书名 / ✍️ 作者 / 🔄 重置）
│   ├─ 笔记组织（路径前缀 / 文件名模板 / 笔记模板）
│   ├─ 摘录渲染（页码 / 笔记标记 / 章节标题 / 颜色 emoji / 摘录模板）
│   └─ 高级（重置配置 / 关于）
```

**AI 读书助手** —— 工具 tab 独立入口：

```
AI 读书助手（工具 tab）
├─ [✓] 启用 AI 对话
├─ API 设置（服务 URL / API Key / 模型名）
├─ 提示词模板（系统提示词 / 翻译 / 解释 / 评论 / 总结）
├─ 高级参数（max_tokens / temperature / 超时）
└─ 说明
```

## 配置

### 方式一：电脑端编辑 conf 文件（推荐，改 API Key 等长内容）

1. USB 连接设备，编辑 `<KINDLE>:/koreader/settings/fns_sync.conf`（首次启动后自动生成带注释的模板）
2. 去掉对应行的行首 `#` 并填入你的值，例如：
   ```
   ai_enabled = true
   ai_api_base = https://api.deepseek.com
   ai_api_key = sk-xxxxxxxxxxxxxxxx
   ai_model = deepseek-chat
   ```
3. 保存（UTF-8 无 BOM），拔线重启 KOReader——只有 conf 里写了的键会被更新，其余保持不变；之后在菜单里的修改也不会被 conf 覆盖（内容指纹机制）

### 方式二：FNS 服务器模式

1. 进入 **设置 ▸ 网络 ▸ FNS 同步**，勾选 **FNS 服务器模式**（服务信息不全时会弹提示）
2. 进入 **服务设置** 填写：
   - **FNS 服务 URL**（例如 `https://fns.example.com:9000`）
   - **API Token**（在 FNS WebGUI 创建）
   - **Vault 名**
3. 点 **测试连接** 验证，点 **立即同步当前书** 触发第一次同步

### 方式三：AI 读书助手

1. 准备一个 **OpenAI 兼容 API**（默认 [DeepSeek](https://platform.deepseek.com)）
2. 进入 **工具 ▸ AI 读书助手 ▸ API 设置** 填写 URL / Key / 模型名（或用 conf 文件，见方式一）
3. 勾选 **启用 AI 对话**

使用：阅读时选中文字 → 长按菜单点 **问 AI** → 输入问题（或点快捷按钮翻译/解释/评论）→ 回答窗口可继续追问、让 AI 总结、**加入笔记**（FNS 模式写入 Obsidian，离线模式写入本地 FNS-Notes/；删除该摘录时 AI 回答一并删除）。

### 双向同步（FNS 模式，实验性）

进入 **自动同步 ▸ 双向同步（实验性）** 开启。开启后：在 Obsidian 删除 HL@ 块 = 跨设备删除本地高亮；其他设备新增的高亮会自动拉回本设备；每条高亮会额外记录 XPointer 坐标到笔记（首次开启有隐私确认）。仅支持 EPUB/MOBI/AZW3/FB2/TXT/HTML（crengine 格式），PDF 不支持拉取。

## 端到端示例

KOreader 里的高亮在 Obsidian 端被包裹成 HL@ 块。

**渲染模式(阅读视图)** — 用户实际看到的效果:

![Obsidian 渲染模式](./docs/obsidian-hl-rendered.png)

**源码模式(编辑视图)** — HL@ marker 和块结构清晰可见:

![Obsidian 源码模式](./docs/obsidian-hl-source.png)

块之间的区域是**安全编辑区**,你可以穿插写自己的感想(如上图中非高亮的文字),同步时会被保留。HL@ 块**内部**则会被同步覆盖,所以不要在块内编辑。详细机制见 [plugin/fns_sync.koplugin/README.md](./plugin/fns_sync.koplugin/README.md)。

## 文档

详细使用文档（HL@ 块结构、Obsidian 端安全编辑区、模板定制、故障排查）：
👉 [plugin/fns_sync.koplugin/README.md](./plugin/fns_sync.koplugin/README.md)

## 系统要求

- KOreader（开发基于 master 分支，需支持 `onNetworkConnected` 事件）
- **离线本地模式**：无需任何服务端，即装即用
- **FNS 服务器模式**（可选）：部署 [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service) 服务端（提供 REST API + WebGUI）
- **AI 读书助手**（可选）：任一 OpenAI 兼容 API（默认 DeepSeek）

## 隐私

队列数据（书 path + title）存储在 KOreader 全局配置文件 `settings.reader.lua` 的 `fns_sync_queue` 字段；**尚未同步的 AI 回答**存储在 `fns_sync_pending_ai` 字段（含回答正文与模型名）。**不包含 FNS token 等敏感凭据**。如不想使用离线队列功能，可在 **FNS 同步（FNS 模式）→ 离线队列 → 启用离线队列** 关闭。

⚠️ **AI API Key 以明文存储**在 `settings.reader.lua`（与 FNS api_token 同级信任）。KOreader 配置文件在设备上是明文的，加密只能防 USB 窥视、防不了设备丢失——如设备丢失请到 AI 服务商后台吊销 Key。`fns_sync.conf` 同理（导入后仍建议删除或保留均可，不影响）。开启双向同步后，笔记中会额外记录每条高亮的 XPointer 坐标（可推断阅读进度），共享 Vault 场景请知悉。

## 反馈与贡献

- 服务端问题：[haierkeys/fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service)
- 本插件：提 issue / PR

## 赞助

如果这个插件对你有帮助，欢迎请作者喝杯咖啡：
[![Donate](https://img.shields.io/badge/PayPal-Donate-blue.svg?logo=paypal)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=WTV8HNRMMMGEC)

<p align="center">
  <img src="./docs/sponsor-wechat.jpg" width="220" alt="微信赞助二维码" />
</p>

## 商业授权

本项目基于 PolyForm Noncommercial License 1.0.0 授权，允许个人学习、研究、教学、慈善、宗教等非商业用途。

**商业使用需另行获得授权。** 如需商业使用，请通过 [GitHub Issue](https://github.com/xzymoon/KOreader-FNS-plugin/issues/new) 联系作者。

## License

[PolyForm Noncommercial 1.0.0](./LICENSE)
