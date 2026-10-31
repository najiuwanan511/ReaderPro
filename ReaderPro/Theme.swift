import SwiftUI
import UIKit

// MARK: - 全局主题（开源阅读原版风）
// 主色 + 卡片色，深浅色模式自动适配。所有页面统一从这里取色，视觉才不会散。
enum AppTheme {
    // 主色（accent）：legado 原版红色（复选框/开关/按钮/选中 tab 都是红），深浅色自动适配
    static let accent = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.94, green: 0.33, blue: 0.33, alpha: 1)  // #EF5353
            : UIColor(red: 0.90, green: 0.22, blue: 0.21, alpha: 1)  // #E53935
    })
    // 深主色（标题、强调）
    static let accentDeep = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.96, green: 0.55, blue: 0.55, alpha: 1)
            : UIColor(red: 0.78, green: 0.16, blue: 0.15, alpha: 1)  // #C62828
    })
    // 浅主色（标签底色）
    static let accentSoft = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.28, green: 0.14, blue: 0.13, alpha: 1)
            : UIColor(red: 0.99, green: 0.93, blue: 0.92, alpha: 1)
    })
    // 卡片背景（深色：藏青风，对标阅读Sigma书架 #1a2230 的暗青底）
    static let card = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1)
            : UIColor.white
    })
    // 页面背景（深色：深藏青）
    static let background = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1)
    })
    // Legado-E 顶栏棕色（书架/发现截图里的深棕顶栏，约 #6D4C41）
    static let headerBrown = Color(red: 0.43, green: 0.30, blue: 0.26)
    // 未读角标蓝（阅读Sigma书架右上角数字徽章，深浅色都用醒目的蓝）
    static let unreadBadge = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1)
            : UIColor(red: 0.16, green: 0.45, blue: 0.95, alpha: 1)
    })
}

// MARK: - 未读角标（书架封面右上角，蓝色圆角数字徽章，对标阅读Sigma）
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Group {
            if count > 0 {
                Text(count > 999 ? "999+" : "\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.unreadBadge))
                    .overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
            }
        }
    }
}

// MARK: - 精致书封（无封面书的占位，开源阅读书架质感）
struct BookCover: View {
    let title: String
    let width: CGFloat
    var height: CGFloat { width * 1.42 }  // 接近 3:4 的书封比例

    var body: some View {
        let grad = Self.gradient(for: title)
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.10, style: .continuous)
                .fill(LinearGradient(colors: grad, startPoint: .topLeading, endPoint: .bottomTrailing))
            // 书脊高光（左侧一束亮）
            RoundedRectangle(cornerRadius: width * 0.10, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.22), .clear, .clear],
                                     startPoint: .leading, endPoint: .trailing))
            // 顶部留白短线
            VStack {
                HStack {
                    Capsule().fill(.white.opacity(0.55)).frame(width: width * 0.34, height: 2)
                    Spacer()
                }
                Spacer()
            }.padding(width * 0.15)
            // 书名竖排（中文书封质感，最多 4 字）
            VStack(spacing: width * 0.05) {
                ForEach(Array(titleGlyphs.enumerated()), id: \.offset) { _, ch in
                    Text(ch)
                        .font(.system(size: width * 0.20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            // 底部装饰
            VStack {
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(.white.opacity(0.5)).frame(width: 2.5, height: 2.5)
                    }
                }
            }.padding(.bottom, width * 0.12)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.22), radius: width * 0.10, x: 0, y: width * 0.05)
    }

    private var titleGlyphs: [String] {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return ["?"] }
        return Array(t.prefix(4)).map { String($0) }
    }

    // 莫兰迪低饱和配色（书卷气，不刺眼）
    static func gradient(for title: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.35, green: 0.42, blue: 0.75), Color(red: 0.22, green: 0.28, blue: 0.55)],
            [Color(red: 0.62, green: 0.45, blue: 0.35), Color(red: 0.42, green: 0.28, blue: 0.22)],
            [Color(red: 0.33, green: 0.55, blue: 0.45), Color(red: 0.20, green: 0.38, blue: 0.30)],
            [Color(red: 0.60, green: 0.40, blue: 0.55), Color(red: 0.42, green: 0.25, blue: 0.38)],
            [Color(red: 0.52, green: 0.42, blue: 0.65), Color(red: 0.34, green: 0.27, blue: 0.47)],
            [Color(red: 0.42, green: 0.55, blue: 0.65), Color(red: 0.27, green: 0.38, blue: 0.48)],
        ]
        let idx = abs(title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % palettes.count
        return palettes[idx]
    }
}

// MARK: - legado 设置项组件（对标开源阅读「我的/设置」页）

/// 设置项统一组件：左侧彩色圆角图标 + 标题/灰色摘要 + 右侧箭头/开关/当前值。
/// 开源阅读设置页的灵魂就是这种 Material 列表行。点击交给外部 NavigationLink / Button 处理。
struct SettingRow: View {
    let icon: String
    var iconTint: Color = AppTheme.accent
    let title: String
    var summary: String? = nil
    var value: String = ""          // 右侧当前值（非空则不显示箭头）
    var isOn: Binding<Bool>? = nil  // 开关（非空则显示 Toggle）

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(iconTint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let s = summary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let isOn = isOn {
                Toggle("", isOn: isOn).labelsHidden()
            } else if !value.isEmpty {
                Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

/// 设置分组标题（legado 用主题色小字分组，非 iOS 默认灰色大写）
struct SettingSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .textCase(nil)
    }
}

// MARK: - 网格书封（发现页 / 书架网格用，宽度自适应）
struct GridBookCover: View {
    let title: String
    var height: CGFloat = 150
    var body: some View {
        let grad = BookCover.gradient(for: title)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: grad, startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.18), .clear, .clear], startPoint: .leading, endPoint: .trailing))
            VStack(spacing: 5) {
                ForEach(Array(title.prefix(3).enumerated()), id: \.offset) { _, ch in
                    Text(String(ch)).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

// MARK: - 书架满铺书封（legado-E 风格：封面铺满单元格、无固定高度，书名由外部叠渐变）
struct ShelfCoverView: View {
    let title: String
    var body: some View {
        let grad = BookCover.gradient(for: title)
        ZStack {
            LinearGradient(colors: grad, startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: [.white.opacity(0.18), .clear, .clear], startPoint: .leading, endPoint: .trailing)
            VStack(spacing: 5) {
                ForEach(Array(title.prefix(3).enumerated()), id: \.offset) { _, ch in
                    Text(String(ch)).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
    }
}

/// 书架网格单元格（legado-E：满铺封面 + 底部渐变书名 + 右上角未读角标 / 多选勾）
struct ShelfGridCell: View {
    let title: String
    let coverUrl: String
    let unreadCount: Int
    let selecting: Bool
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(0.72, contentMode: .fit)
                .overlay {
                    if !coverUrl.isEmpty, let url = URL(string: coverUrl) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            ShelfCoverView(title: title)
                        }
                    } else {
                        ShelfCoverView(title: title)
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .clear, Color.black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? AppTheme.accent : .white)
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .padding(3)
            } else {
                UnreadBadge(count: unreadCount).padding(3)
            }
        }
    }
}
