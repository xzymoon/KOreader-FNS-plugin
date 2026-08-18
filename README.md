# KOreader FNS Sync Plugin

[English](./README.en.md) | 中文

把 KOreader 里的高亮和笔记同步到 Obsidian，通过 [Fast Note Sync](https://github.com/haierkeys/fast-note-sync-service) 服务端。

## 功能

- ✨ **自动同步**（划线 / 改笔记 / 关书时自动触发，debounce 合并连续操作）
- 📦 **离线队列**（断网时入队，联网后自动补推；失败重试 + 冻结机制）
- 🔄 **跨设备双向同步**（三路合并：在 Obsidian 删除 HL@ 块 = 跨设备删除高亮；其他设备新增的高亮自动拉回本设备）
- 🤖 **AI 阅读助手**（选中文字长按"问 AI"，DeepSeek 等 OpenAI 兼容 API 对话；问题+回答一键加入笔记，紧贴原文摘录，删除摘录时自动级联删除）
- 📝 **条目级 HL@ marker**（用户在 Obsidian 端穿插编辑的内容会被保留）
- 🎨 **可定制模板**（摘录模板 / 笔记模板 / 文件名模板 / 颜色 emoji / AI 快捷提问模板）
- 📚 **跨书籍多端同步**（每本书可独立 override title / author，适合合集场景）
- 🔌 **基于 FNS REST API**（与 [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service) 服务端通信）

## 安装

1. 下载 [最新版本](https://github.com/xzymoon/KOreader-FNS-plugin/releases) 或 clone 本仓库
2. 把 `plugin/fns_sync.koplugin/` 整个目录复制到 KOreader 的 `plugins/` 目录：
   - **Kindle**：USB 连接后拷贝到 `<KINDLE>:/koreader/plugins/fns_sync.koplugin/`
   - **其他设备**（Android / Desktop / 等）：参考 KOreader 文档的插件路径
3. 重启 KOreader

## 菜单结构

进入 **KOreader 顶部菜单 → 工具 → FNS 同步**,菜单层级如下(`[✓]` 表示开,`[ ]` 表示关):

```
FNS 同步
├─ [✓] 启用 FNS 同步
├────────────────────────
├─ [✓] 自动同步
│   ├─ [✓] 启用自动同步
│   ├─ [✓] 高亮修改时同步
│   ├─ [✓] 关闭书籍时同步
│   ├─ 同步延迟(秒)
│   └─ 双向同步（实验性）
│       ├─ [ ] 启用双向同步
│       ├─ [ ] 开书时自动拉取
│       └─ 说明
├────────────────────────
├─ [✓] 离线队列
│   ├─ [✓] 启用离线队列
│   ├─ 待同步队列(N 本)
│   ├─ 重试冻结条目
│   └─ 清空队列
├────────────────────────
├─ 立即同步当前书
├─ 立即拉取远端高亮
├─ 立即同步全部历史
├─ AI 助手
│   ├─ [✓] 启用 AI 对话
│   ├─ API 设置
│   │   ├─ API 服务 URL
│   │   ├─ API Key
│   │   ├─ 模型名
│   │   └─ 系统提示词
│   ├─ 快捷模板
│   │   ├─ 翻译模板
│   │   ├─ 解释模板
│   │   ├─ 评论模板
│   │   └─ 总结模板
│   └─ 高级参数
│       ├─ max_tokens
│       ├─ temperature
│       ├─ 超时（秒）
│       └─ 说明
├─ 测试连接
├─ 当前书信息
│   ├─ 📁 文件名
│   ├─ 📖 书名: ...
│   ├─ ✍️ 作者: ...
│   └─ 🔄 重置为文件元数据
└─ 设置
    ├─ 服务连接
    │   ├─ FNS 服务 URL
    │   ├─ API Token
    │   └─ Vault 名
    ├─ 笔记组织
    │   ├─ 笔记路径前缀
    │   ├─ 笔记文件名模板
    │   └─ 笔记模板
    ├─ 摘录渲染
    │   ├─ [✓] 显示页码
    │   ├─ [✓] 显示笔记标记
    │   ├─ [✓] 章节二级标题
    │   ├─ [✓] 颜色转 emoji
    │   └─ 自定义摘录模板
    ├─ 触发模式
    │   ├─ [✓] 高亮即同步
    │   ├─ [✓] 关书同步
    │   └─ 防抖延迟(秒)
    └─ 高级
        ├─ 重置配置
        └─ 关于
```

## 配置

进入 **KOreader 顶部菜单 → 工具 → FNS 同步**：

1. **启用 FNS 同步**（主开关）
2. 进入 **设置 → 服务连接**，填写：
   - **FNS 服务 URL**（例如 `https://fns.example.com:9000`）
   - **API Token**（在 FNS WebGUI 创建）
   - **Vault 名**
3. 点 **测试连接** 验证配置
4. 点 **立即同步当前书** 触发第一次同步

启用后，划线 / 改笔记 / 关书时会自动触发同步（默认 5 秒 debounce）。

### AI 阅读助手（可选）

1. 在 FNS 服务端已有账号的基础上，准备一个 **OpenAI 兼容 API**（默认 [DeepSeek](https://platform.deepseek.com)，其他兼容服务也可）
2. 进入 **工具 → FNS 同步 → AI 助手 → API 设置**，填写：
   - **API 服务 URL**（如 `https://api.deepseek.com`）
   - **API Key**
   - **模型名**（如 `deepseek-chat`；注意推理型模型会先消耗 max_tokens 思考，建议配合较大的 max_tokens）
3. 勾选 **启用 AI 对话**

使用：阅读时选中文字 → 长按菜单点 **问 AI** → 输入问题（或点快捷按钮翻译/解释/评论）→ 回答窗口可继续追问、让 AI 总结、**加入笔记**（问题+回答成对写入笔记，紧贴该条原文摘录；快捷提问只记标签，手输问题自动去掉其中重复的原文；删除该摘录时 AI 回答一并删除）。

### 双向同步（可选，实验性）

进入 **自动同步 → 双向同步（实验性）** 开启。开启后：

- 在 Obsidian 删除 HL@ 块 = 跨设备删除本地高亮
- 其他设备新增的高亮会自动拉到本设备
- 每条高亮会额外记录 XPointer 坐标到 Obsidian 笔记（首次开启有隐私确认）

仅支持 EPUB/MOBI/AZW3/FB2/TXT/HTML（crengine 格式），PDF 不支持拉取。

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
- 部署 [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service) 服务端（提供 REST API + WebGUI）
- AI 阅读助手（可选）：任一 OpenAI 兼容 API（默认 DeepSeek）

## 隐私

队列数据（书 path + title）存储在 KOreader 全局配置文件 `settings.reader.lua` 的 `fns_sync_queue` 字段；**尚未同步的 AI 回答**存储在 `fns_sync_pending_ai` 字段（含回答正文与模型名）。**不包含 FNS token 等敏感凭据**。如不想使用离线队列功能，可在 **工具 → FNS 同步 → 离线队列 → 启用离线队列** 关闭。

⚠️ **AI API Key 以明文存储**在 `settings.reader.lua` 的 `fns_sync.ai_api_key`（与 FNS api_token 同级信任）。KOreader 配置文件在设备上是明文的，加密只能防 USB 窥视、防不了设备丢失——如设备丢失请到 AI 服务商后台吊销 Key。开启双向同步后，笔记中会额外记录每条高亮的 XPointer 坐标（可推断阅读进度），共享 Vault 场景请知悉。

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
