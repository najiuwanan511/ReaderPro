# 阅读Pro / ReaderPro（自用 · TrollStore 侧载）

仿「开源阅读 / Legado」的 iOS 阅读器。原生 SwiftUI 编写，自用、不上架，通过 **TrollStore 侧载**（永久签名，无需 Apple 开发者账号）。App 图标与显示名已定制为「阅读Pro」。

本仓库在 [原起步包](https://github.com/najiuwanan511/CialloReaderIOS) 基础上，**重写了阅读器并补齐了完整功能**，保留并复用其成熟的引擎层（书源规则 / 多格式解析 / 备份）。

## 构建与安装（无需 Mac）

1. 把本仓库推到你的 GitHub（`.github/workflows/` 必须在根目录）。
2. GitHub → Actions → **iOS unsigned build** → Run workflow。
3. 构建完成后在 Artifacts 下载 `unsigned-ipa`，得到 `ReaderPro-unsigned.ipa`。
4. **TrollStore 安装**：把 IPA 通过 AirDrop / 文件 传到手机，用 TrollStore 的「Install IPA」直接装即可（永久签名，比 AltStore 7 天过期省心）。

> 构建产物是未签名 IPA（`CODE_SIGNING_ALLOWED=NO`），TrollStore 会自行伪签名，无需证书。

## 功能清单

**阅读器（核心）**
- TextKit 精确分页：按屏幕 + 字号 + 行距 + 段距 + 边距逐字排版，怎么调都不溢出
- **五档翻页动画**：覆盖 / 平移 / 滚动 / 无 / **仿真（pageCurl 卷曲，开源阅读同款）**，翻页速度可调
- 点按三区翻页 + 中间弹菜单（开源阅读同款交互）
- **8 套背景主题** + 自定义字体（苹方/宋体/楷体/黑体/圆体 + 全部系统字体）
- 完整排版设置：字号、行距、段距、边距、亮度（跟随系统）、页眉页脚
- **朗读续读**：从当前页读到章末，语速 / 音色可调
- **自动翻页**：间隔可调
- **书内搜索**：本章 / 全文跨章
- **书签**：阅读中加书签，书签列表可跳转
- 进度记忆（章 + 字符偏移）+ **阅读时长统计**

**书架**
- 网格 / 列表视图切换、排序、搜索、多选删除
- **收藏**（星标）与收藏过滤
- 封面（网络封面 + 标题取色占位）、进度、阅读时长显示

**书源**
- Legado JSON 书源导入（粘贴 / 网络订阅 / 扫码），多源并发搜索、目录拉取、换源
- **书源详情**：查看全部规则（搜索 / 目录 / 正文）+ 单源测试搜索
- **换源**：阅读中一键换源重拉目录；**整本缓存**：一键下载全书离线读
- **专门适配 yckceo 源仓库**：书源详情页链接自动转 JSON 接口导入

**订阅源（Legado rssSource）**
- 订阅源导入（粘贴 JSON / 网络链接），启用 / 停用 / 删除
- **源仓库导航**：singleUrl 订阅源（如 yckceo 官方源仓库）点开用内置浏览器进源仓库找书源
- 识别 RSS 规则源（带 ruleArticles 的源会标注）

**同步**
- 本地备份互传（.ciallo，实为 ZIP）
- **WebDAV 云备份**：坚果云 / Nextcloud / 自建，备份到云端 + 从云端恢复

**内置浏览器 & 视频小窗**
- 内置 WKWebView 浏览器：地址栏、前进后退、刷新、网页视频原生画中画
- **ALOOK 式视频弹窗**：自动探测网页 `<video>` → 一键「小窗」进入系统画中画，退出浏览器 / 切 App 仍悬浮播放
- 入口：设置 → 内置浏览器；书源详情 → 在浏览器打开书源网站

**其他**
- 本地导入：TXT / EPUB / DOCX / FB2 / MOBI / AZW3 / PDF / CBZ（漫画）
- 漫画：单页 / 条漫、缩放、本机滤镜增强、OCR、图片磁盘缓存
- **在线漫画**：漫画书源（bookSourceType=2 或正文带 imageUrl 规则）自动识别，按章节拉图、翻页 / 条漫、自动缓存离线看
- 替换净化（正则去广告）、导出 EPUB / TXT

## 目录结构

```
ReaderPro/
├── App.swift                    # 入口
├── ContentView.swift            # 书架 / 书源 / 设置（含 WebDAV 配置）
├── ReaderView.swift             # ★ 阅读器（重写，含仿真翻页/书签/全文搜索/换源/缓存）
├── MangaView.swift              # ★ 漫画（本地 CBZ + 在线漫画书源，图片缓存/OCR）
├── ReaderCore.swift             # ★ 主题 / 精确分页 / 朗读 / 字体枚举 / pageCurl 控制器
├── BrowserView.swift            # ★ 内置浏览器 + 视频画中画小窗
├── WebDAV.swift                 # ★ WebDAV 客户端（云备份）
├── BookEngine.swift             # 数据模型 / BookStore / TXT/EPUB/CBZ 解析 / 备份
├── SourceEngine.swift           # 书源 / 订阅源（RssSource）模型与导入 / 网络
├── LegadoRuleEngine.swift       # Legado 书源规则引擎
├── ExtraFormats.swift           # MOBI/PDF/ZIP/OCR
├── MoreFormats.swift            # DOCX/FB2/导出
├── DiscoveryAndManagement.swift # 发现 / 书源管理 / 订阅源管理 / 书源详情 / 替换规则编辑
├── Info.plist                   # 含 ATS 例外 + 后台音频（画中画需要）
└── project.yml                  # XcodeGen 配置
```

## yckceo 源仓库接口清单

「阅读 / 开源阅读」最大的书源社区之一。域名：主站 `www.yckceo.com`、备用 `www.yck2026.fun`、防失联发布页 `yckceo.vip`。

| 用途 | 地址 |
|---|---|
| 书源列表页 | `https://www.yckceo.com/yuedu/shuyuans/index.html` |
| 书源详情页（单源） | `https://www.yckceo.com/yuedu/shuyuans/content/id/{id}.html` |
| 书源 JSON 接口（可直接网络导入） | `https://www.yckceo.com/yuedu/shuyuan/json/id/{id}.json`（或 `shuyuans`） |
| 订阅源列表页 | `https://www.yckceo.com/yuedu/rss/index.html` |
| 订阅源详情页 | `https://www.yckceo.com/yuedu/rss/content/id/{id}.html` |
| 订阅源 JSON 接口（可直接网络导入） | `https://www.yckceo.com/yuedu/rss/json/id/{id}.json` |
| 官方源仓库订阅（纯净） | `https://www.yckceo.com/yuedu/rss/json/id/193.json` |

**用法**：App 里「书源管理 / 订阅源管理 → 网络导入」粘贴上面对应链接即可；详情页链接会自动转成 JSON 接口再拉取，无需手动改。

## 已知限制

- 书源规则引擎对 JS 书源支持有限（原生 Swift 无 JS 运行时），复杂 JS 书源可能解析失败。
- 订阅源目前支持「导入 / 管理 / 源仓库导航」，带规则的 RSS 全文阅读（ruleArticles 解析渲染）尚未实现。
- 带 DRM 的加密书无法读取。
- 漫画增强是本机 CoreImage 滤镜，不是 MangaJaNai AI 画质模型。
- 视频小窗用 AVPlayer 直接播提取到的视频 URL，会丢失网页的 cookie/referer，带强防盗链的视频源可能 403；此类视频请用网页内嵌播放器自带的画中画按钮。
- 在线漫画图片同样可能被防盗链拦截；已带 UA 下载 + 本地缓存，但强 referer 防盗链的图床仍可能失败。

## 协议

自用项目，未引入额外版权素材。开源阅读（Legado）为 GPL-3.0；本仓库为独立 Swift 实现，如对外发布请自行遵循 GPL-3.0。
