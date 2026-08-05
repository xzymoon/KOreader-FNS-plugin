# KOreader FNS Sync Plugin

[English](./README.en.md) | 中文

把 KOreader 里的高亮和笔记同步到 Obsidian，通过 [Fast Note Sync](https://github.com/haierkeys/fast-note-sync-service) 服务端。

## 功能

- ✨ **自动同步**（划线 / 改笔记 / 关书时自动触发，debounce 合并连续操作）
- 📦 **离线队列**（断网时入队，联网后自动补推；失败重试 + 冻结机制）
- 📝 **条目级 HL@ marker**（用户在 Obsidian 端穿插编辑的内容会被保留）
- 🎨 **可定制模板**（摘录模板 / 笔记模板 / 文件名模板 / 颜色 emoji）
- 📚 **跨书籍多端同步**（每本书可独立 override title / author，适合合集场景）
- 🔄 **基于 FNS REST API**（与 [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service) 服务端通信）

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
│   └─ 同步延迟(秒)
├────────────────────────
├─ [✓] 离线队列
│   ├─ [✓] 启用离线队列
│   ├─ 待同步队列(N 本)
│   ├─ 重试冻结条目
│   └─ 清空队列
├────────────────────────
├─ 立即同步当前书
├─ 立即同步全部历史  (未启用)
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
    │   ├─ [ ] 开书同步
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

## 文档

详细使用文档（HL@ 块结构、Obsidian 端安全编辑区、模板定制、故障排查）：
👉 [plugin/fns_sync.koplugin/README.md](./plugin/fns_sync.koplugin/README.md)

## 系统要求

- KOreader（开发基于 master 分支，需支持 `onNetworkConnected` 事件）
- 部署 [fast-note-sync-service](https://github.com/haierkeys/fast-note-sync-service) 服务端（提供 REST API + WebGUI）

## 隐私

队列数据（书 path + title）存储在 KOreader 全局配置文件 `settings.reader.lua` 的 `fns_sync_queue` 字段。**不包含 token 等敏感凭据**。如不想使用离线队列功能，可在 **工具 → FNS 同步 → 离线队列 → 启用离线队列** 关闭。

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
