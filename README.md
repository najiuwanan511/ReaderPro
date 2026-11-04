# 阅读Pro / ReaderPro（自用 · TrollStore 侧载）

仿「开源阅读 / Legado」的 iOS 阅读器。原生 SwiftUI 编写，自用、不上架，通过 **TrollStore 侧载**（永久签名，无需 Apple 开发者账号）。App 图标与显示名已定制为「阅读Pro」。

本仓库在 [原起步包](https://github.com/najiuwanan511/CialloReaderIOS) 基础上改写阅读器、书源引擎和管理界面。当前仍是持续开发的 iOS 实现，功能和规则兼容性并未完全等同于 legado-E。

最新修复、失败记录、对应构建和未齐项目见 [对齐修复记录](docs/ParityRepairPlan.md)。自动化测试使用固定样例；模拟器通过不等于实体 iPhone / TrollStore 已验收，也不代表所有安卓书源均可使用。本轮不开发备份与同步兼容，不下载、分析或测试 1329 书源合集。

## 构建与安装（无需 Mac）

1. 把本仓库推到你的 GitHub（`.github/workflows/` 必须在根目录）。
2. GitHub → Actions → **iOS unsigned build** → Run workflow。
3. 构建完成后在 Artifacts 下载 `unsigned-ipa`，得到 `ReaderPro-unsigned.ipa`。
4. **TrollStore 安装**：把 IPA 通过 AirDrop / 文件 传到手机，用 TrollStore 的「Install IPA」直接装即可（永久签名，比 AltStore 7 天过期省心）。

> 构建产物是未签名 IPA（`CODE_SIGNING_ALLOWED=NO`），TrollStore 会自行伪签名，无需证书。

## 功能清单

**阅读器（核心）**
- TextKit 分页：按屏幕、字号、行距、段距和边距排版，并用相同的单页布局渲染
- **五档翻页动画**：覆盖 / 平移 / 滚动 / 无 / **仿真（pageCurl 卷曲，开源阅读同款）**，翻页速度可调
- 点按三区翻页 + 中间弹菜单（开源阅读同款交互）
- **8 套背景主题** + 自定义字体（苹方/宋体/楷体/黑体/圆体 + 全部系统字体）
- 排版设置：字号、字重、字距、行距、段距、边距、亮度（跟随系统）、页眉页脚；可预览导入安卓排版 ZIP/JSON，保存包内字体与背景，按名称更新并选择昼间/夜间/墨水屏配色应用
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
- 搜索范围、历史、后续结果分页；发现分类控件、按源筛选、长按登录/接口切换、编辑及置顶
- **书源详情**：查看全部规则（搜索 / 目录 / 正文）+ 单源测试搜索
- **换源**：阅读中一键换源重拉目录；**整本缓存**：一键下载全书离线读
- **专门适配 yckceo 源仓库**：书源详情页链接自动转 JSON 接口导入

**订阅源（Legado rssSource）**
- 订阅源导入（粘贴 JSON / 网络链接），启用 / 停用 / 删除
- **源仓库导航**：singleUrl 订阅源（如 yckceo 官方源仓库）点开用内置浏览器进源仓库找书源
- 识别 RSS 规则源（带 ruleArticles 的源会标注）
- 按规则读取文章、分页、收藏、阅读记录、朗读；源级登录、Cookie、CSS 和网页脚本配置
- 规则订阅可检查更新、预览差异并保存待应用状态

**既有备份（不纳入本轮安卓兼容开发）**
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

## 书源校验与回归测试

- 管理页常驻搜索栏可搜索名称、分组、网址和失败原因；状态筛选包含成功、失败、未完整验证和未校验。
- 校验依次检查已配置的搜索入口、已启用发现的首个分类、样本书详情、目录分页和首章；按文本、漫画、音频、视频与文件源执行相应解析检查。可配置项目、超时和关键词。书源关闭发现时跳过发现检查；检查通过不代表视频已在每台设备实际播放。
- 成功表示这次抽样阅读链路通过，不表示每本书、每个分类或以后一直可用。搜索无结果、部分能力可用或脚本不兼容标记为未完整验证；没有可用入口且请求失败才标记为失败。失败仅描述本次检查，不自动停用书源。
- 报告保存关键词、时间、失败阶段及原因，修改书源规则后旧结果失效。
- 与 Android 一致，封面和简介脚本出错时保留书籍及阅读入口，详情和校验报告记录附加信息警告；书名、作者、详情地址、目录和正文的错误仍会报告，取消及总超时不会被忽略。
- 网络导入同时展开直接书源与嵌套子合集，显示实际新增、更新、重复及失败文件地址；子合集循环会去重，单次超过 5000 个子合集明确报告。
- 默认 IPA 构建先执行固定样例单测、iOS 模拟器界面测试和正文像素检查，通过后才打包。覆盖 1500 条自建书源导入、混合合集、请求头/POST/中文关键词、发现→详情→目录→正文、连续翻章和校验记录持久化。
- 真实站点、书源合集审计为单独的诊断流程，默认打包跳过相关用例；不能把这些跳过的用例计为通过。本轮没有测试 1329 合集。历史合集数量与审计结果只适用于各自保存的版本和报告，不代表当前网站状态。
- 固定回归使用本仓库原创样本、本地 HTTP/HTTPS/代理服务，并保留 UI 截图、日志及测试结果；证据上传为 `source-regression-evidence`，iOS 17 Release 另存对应证据。模拟器测试不能代替真机和用户所在网络的验证。
- 搜索按源持续返回结果，显示完成数与失败原因，可随时取消和重新搜索；发现分类、分类列表与目录加载有超时和重试提示。
- 支持脚本内书籍字段模板、节点列表转换、带排除索引的组合 CSS、嵌套替换模板、原始源身份保留与请求网址空白清理，以及带 type 的 Base64 内嵌/二进制请求。动态登录表单、可见网页验证、图片验证码和登录检测已接入；支持范围以实际脚本接口为准。
- 常用 JavaImporter 加密接口提供 AES/DES Cipher、HMAC Mac、SecretKeySpec、IV、Base64、Arrays、HashMap 与 RSA SHA-1/256/384/512 签名适配；测试使用 NIST/RFC 向量和独立 OpenSSL 生成的 RSA 签名。测试密钥仅用于回归，无任何账户用途。
- 动态执行的书源备注解密库同样适配 Java 字符串 `length()`，兼容 Rhino 简单数组解构箭头参数；`book.getVariable/putVariable` 按书源与书籍隔离并持久保存，支持缺失值和删除。
- 网络超时同时约束脚本执行：针对部分合集中的无限 `while/catch` 重试，JSC watchdog 会直接终止脚本，避免搜索永久等待。相关测试包含无限循环、取消和后续脚本恢复。此侧载实现使用 JavaScriptCore 导出的执行中断 SPI；未来如上架 App Store，需要替换这部分实现。系统不提供该接口时会明确拒绝执行脚本。

## Android 可用但 iOS 报 SSL 错误

legado-E 的网络客户端默认忽略 HTTPS 证书及域名校验。ReaderPro 默认使用系统证书校验，因此过期、自签名或域名不匹配的证书可能在两端产生不同结果。对于你信任的旧站点，可到「书源管理 → 该源详情 → 旧站点证书兼容」单独开启后重新校验；开启会跳过该书源请求的 HTTPS 证书校验。

这项选择仅保存在本机，不由导入的 JSON 自动开启，不影响其他书源或 WebDAV。自动化 HTTPS 测试验证默认拒绝、明确开启后可用、关闭后恢复验证，以及普通请求、脚本网络和 WebView 之间的隔离。兼容选项不能修复已失效的域名或系统不再支持的 TLS 协议。

## 已知限制

- 使用 JavaScriptCore 执行 JS、SwiftSoup 解析 Jsoup/CSS 选择器、Kanna/libxml2 解析 XPath。已实现常用网络、DOM、加密、文件和脚本桥接口，仍非完整 Android Java / Rhino 环境；未知 Java 类会明确报错，不能承诺通用兼容。
- 第三方网站的失效域名、证书、登录、验证码、地区限制及防盗链仍可能导致失败。客户端允许旧式 HTTP；HTTPS 默认校验证书，旧站点兼容需针对该源明确开启。
- 发现分类完整 Flexbox 语义、全部阅读样式/系统交互和逐屏 UI 尚未完全对齐；不能称为安卓界面的完整移植。
- 排版包保留原始配置与资源，但标题配置、下划线、页眉页脚提示/分隔线、颜色透明度及安卓系统栏尚未完整映射；不对称边距目前取均值，配色需手动应用。导入预览会显示兼容说明。
- 带 DRM 的加密书无法读取。
- 漫画增强是本机 CoreImage 滤镜，不是 MangaJaNai AI 画质模型。
- 原生媒体播放和图片请求已沿用源级请求头、Cookie 与代理配置；站点防盗链和平台解码能力仍可能导致失败。DASH 当前只覆盖单 Period 静态 MP4 的部分格式，dynamic、多 Period、SegmentBase/sidx、WebM 和 DRM 未齐。
- iOS 17 网页代理已验证 HTTP、HTTPS、认证 SOCKS5；代理访问本机地址明确拒绝，不支持 SOCKS4，URLSession 的 HTTP 代理认证仍有平台限制。

## 协议

自用项目，未引入额外版权素材。开源阅读（Legado）为 GPL-3.0；本仓库为独立 Swift 实现，如对外发布请自行遵循 GPL-3.0。
