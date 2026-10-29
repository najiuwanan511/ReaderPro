# Ciallo Reader iOS：Windows + 云构建起步包（自用，不上架）

目标：先跑通一条最小闭环——Windows 改代码 → GitHub Actions 云编译 → 下载未签名 IPA → AltStore 装到自己的 iOS 17 iPhone 上。
这个包里的 App 只有一个占位书架，功能后面再填。不要把它当成已验证成品：第一次云构建就是验证步骤。

## 1. Windows 上准备

- 安装 Git、VS Code（只做编辑和语法提示，没有 iOS SDK，不能本地编译 iOS App，这是这条路的固有代价）。
- 在 GitHub 建一个**私有**仓库，把本包里的全部文件按原结构推到仓库根目录（`.github/workflows/` 必须在根目录，否则 Actions 找不到 workflow）。

## 2. 云构建（不需要 Apple ID、不需要往仓库放任何密钥）

- GitHub 仓库 → Actions → “iOS unsigned build”→ Run workflow。
- 构建成功后在 Artifacts 里下载 `unsigned-ipa`，得到 `CialloReaderIOS-unsigned.ipa`。
- 原理：云端用 `CODE_SIGNING_ALLOWED=NO` 编出未签名 IPA，签名这一步留给本机 AltStore 做，所以 CI 全程不需要证书和密码。

## 3. 装到手机（AltStore，Windows）

- Windows 上先卸载微软商店版 iTunes / iCloud，改装苹果官网版（商店版会导致签名失败，这是常见坑）。
- 装 AltServer，手机连线点信任，iTunes 里开“通过 Wi-Fi 同步”。
- 用 AltServer 装 AltStore 到手机；手机上：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID；设置 → 隐私与安全性 → 开发者模式 → 打开（iOS 16+ 需要）。
- 在 AltStore 的 My Apps 里点 + 选刚才的 IPA 安装。
- 免费 Apple ID 的限制要认：证书 7 天过期，AltServer 需在同一 Wi-Fi 下运行才能刷新；免费账号同时最多 3 个侧载 App。

## 4. 以后开发的节奏

- 纯逻辑（EPUB 解析、书源规则解析）尽量抽成不依赖 UIKit 的 Swift 代码，UI 层保持薄——这样逻辑可以在 Windows 的 Swift 工具链下先测，iOS UI 的问题再靠云构建 + 真机验证。
- 构建设成手动触发（workflow_dispatch），别每次 push 都自动跑，省云构建分钟数。
- 部署目标定死 iOS 17.0，别用 iOS 18+ 才有的 API，否则你那台不能升级的 iPhone 跑不了。

## 5. 如果这条路卡住，备选（按顺序试）

1. 构建失败先看 Actions 日志：最可能卡在 Xcode 版本或 XcodeGen 的 project.yml，改对应版本号再跑一次。
2. AltStore 装不上未签名 IPA：改用 Sideloadly 在 Windows 本机重签一次再装。
3. 还不行：租一小时云 Mac，用 Xcode 做一次自动签名导出已签名 IPA；或直接付 99 美元/年开发者账号，走 CI 手动签名。
