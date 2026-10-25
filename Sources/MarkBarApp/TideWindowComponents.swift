import AppKit
import SwiftUI
import MarkBarCore

enum TideStyle {
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cardGap: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let controlRadius: CGFloat = 6
    static let optionRadius: CGFloat = 7
    static let cardRadius: CGFloat = 8
    static let logoRadius: CGFloat = 8
    static let sidebarRowHeight: CGFloat = 40

    static let caption: Font = .system(size: 11.5)
    static let body: Font = .system(size: 12)
    static let label: Font = .system(size: 13, weight: .medium)
    static let sectionTitle: Font = .system(size: 14, weight: .semibold)
    static let pageTitle: Font = .system(size: 24, weight: .semibold)
    static let price: Font = .system(size: 28, weight: .medium, design: .rounded)

    // The bright acid-lime stays concentrated on selection and primary actions.
    // Light appearance uses a darker text accent while keeping the same fill.
    static let accentFill = Color(red: 183 / 255, green: 1, blue: 26 / 255)
    static let accent = dynamicColor(
        dark: NSColor(red: 183 / 255, green: 1, blue: 26 / 255, alpha: 1),
        light: NSColor(red: 82 / 255, green: 116 / 255, blue: 0, alpha: 1)
    )
    static let accentForeground = Color(red: 16 / 255, green: 18 / 255, blue: 16 / 255)
    static let secondaryText = dynamicColor(
        dark: NSColor(red: 164 / 255, green: 169 / 255, blue: 174 / 255, alpha: 1),
        light: NSColor(red: 87 / 255, green: 94 / 255, blue: 100 / 255, alpha: 1)
    )
    static let warning = Color(red: 242 / 255, green: 184 / 255, blue: 75 / 255)
    static let error = Color(red: 1, green: 104 / 255, blue: 104 / 255)
    static let canvasColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 21 / 255, green: 23 / 255, blue: 24 / 255, alpha: 1)
            : NSColor(red: 244 / 255, green: 246 / 255, blue: 244 / 255, alpha: 1)
    }
    static let canvas = Color(nsColor: canvasColor)
    static let sidebar = dynamicColor(
        dark: NSColor(red: 25 / 255, green: 27 / 255, blue: 29 / 255, alpha: 1),
        light: NSColor(red: 236 / 255, green: 239 / 255, blue: 236 / 255, alpha: 1)
    )
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 34 / 255, green: 36 / 255, blue: 38 / 255, alpha: 1)
            : NSColor.white
    })
    static let raised = dynamicColor(
        dark: NSColor(red: 41 / 255, green: 45 / 255, blue: 47 / 255, alpha: 1),
        light: NSColor(red: 231 / 255, green: 234 / 255, blue: 230 / 255, alpha: 1)
    )
    static let border = dynamicColor(
        dark: NSColor.white.withAlphaComponent(0.085),
        light: NSColor.black.withAlphaComponent(0.10)
    )

    private static func dynamicColor(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct TideCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(TideStyle.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TideStyle.card, in: RoundedRectangle(cornerRadius: TideStyle.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TideStyle.cardRadius, style: .continuous).strokeBorder(TideStyle.border, lineWidth: 0.75))
    }
}

struct TidePageHeading<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(alignment: .center, spacing: TideStyle.cardGap) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(TideStyle.pageTitle)
                Text(subtitle).font(TideStyle.body).foregroundStyle(TideStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.bottom, 4)
    }
}

extension TidePageHeading where Accessory == EmptyView {
    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = EmptyView()
    }
}

struct TideMarketModePicker: View {
    let selection: TideMarketMode
    let onSelect: (TideMarketMode) -> Void

    var body: some View {
        Picker("关注行情视图", selection: Binding(
            get: { selection },
            set: { mode in onSelect(mode) }
        )) {
            ForEach(TideMarketMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 156)
        .accessibilityLabel("关注行情视图")
    }
}

struct TideSectionHeading: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol)
                .font(TideStyle.sectionTitle)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
            }
        }
    }
}

struct TideBadge: View {
    let title: String
    var color: Color = TideStyle.accent
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .medium)) }
            Text(title).font(TideStyle.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
        .fixedSize()
    }
}

struct TideEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var compact = false
    var body: some View {
        VStack(spacing: compact ? 7 : 10) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 19 : 23, weight: .light))
                .foregroundStyle(TideStyle.accent)
                .frame(width: compact ? 40 : 52, height: compact ? 40 : 52)
                .background(TideStyle.accent.opacity(0.07), in: Circle())
            Text(title).font(TideStyle.sectionTitle)
            Text(detail).font(TideStyle.body).foregroundStyle(TideStyle.secondaryText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, compact ? 8 : 14)
    }
}

struct TideContractLabel: View {
    let contract: Contract
    var showsInstrumentID = true
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            TideCoinAvatar(symbol: contract.symbol, size: compact ? 26 : 32)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(compact ? contract.pairTitle : contract.displayTitle).font(TideStyle.label)
                    .lineLimit(1).truncationMode(.middle).help(contract.displayTitle)
                Text(compact
                     ? "\(contract.marketKind.title) · \(contract.priceTitle)"
                     : showsInstrumentID
                         ? "\(contract.exchange.title) · \(contract.priceTitle) · \(contract.instrumentID)"
                         : "\(contract.exchange.title) · \(contract.priceTitle)")
                    .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    .lineLimit(1).truncationMode(.middle).help(contract.instrumentID)
            }
        }
    }
}

@MainActor
struct TideCoinAvatar: View {
    let symbol: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: TideCoinIcon.image(for: symbol, size: size))
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .frame(width: size + 4, height: size + 4)
            .accessibilityHidden(true)
    }
}

/// Keep native popup menus and their selected labels on the same icon source
/// as the larger contract rows. The complete symbol remains the text identity.
@MainActor
struct TideCoinPickerLabel: View {
    let contract: Contract

    var body: some View {
        Label {
            Text(contract.displayTitle)
        } icon: {
            Image(nsImage: TideCoinIcon.image(for: contract.symbol, size: 16))
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
        .labelStyle(.titleAndIcon)
    }
}

struct TideBrandImage: View {
    private static let appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        Group {
            if let appIcon = Self.appIcon {
                Image(nsImage: appIcon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "waveform.path").font(.title2).foregroundStyle(TideStyle.accent)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: TideStyle.logoRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TideStyle.logoRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
        .accessibilityHidden(true)
    }
}

struct TideCreatorLink: View {
    @State private var isHovered = false
    private static let creatorAvatar = Bundle.main.url(forResource: "CreatorAvatar", withExtension: "jpg")
        .flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        Link(destination: URL(string: "https://x.com/rongcat")!) {
            HStack(spacing: 8) {
                Group {
                    if let creatorAvatar = Self.creatorAvatar {
                        Image(nsImage: creatorAvatar).resizable().interpolation(.high).scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(TideStyle.secondaryText)
                    }
                }
                .frame(width: 20, height: 20).clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                Text("@rongcat").font(TideStyle.caption.weight(.medium)).foregroundStyle(TideStyle.secondaryText)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(TideStyle.secondaryText)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(isHovered ? Color.primary.opacity(0.045) : .clear,
                        in: RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("访问 @rongcat 的 X 主页")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isLink)
        .accessibilityLabel("作者 @rongcat 的 X 主页")
        .accessibilityHint("在默认浏览器中打开 https://x.com/rongcat")
    }
}

struct TideExchangeMark: View {
    let exchange: Exchange
    var selected = false

    private var initials: String {
        switch exchange {
        case .okx: return "OX"
        case .binance: return "BN"
        case .bybit: return "BY"
        }
    }

    var body: some View {
        Group {
            if let image = TideExchangeIcon.image(for: exchange) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text(initials)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.82))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TideStyle.raised)
            }
        }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? TideStyle.accent.opacity(0.72) : TideStyle.border,
                              lineWidth: selected ? 1.25 : 0.75))
            .accessibilityHidden(true)
    }
}

struct TidePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TideStyle.body.weight(.semibold))
            .foregroundStyle(TideStyle.accentForeground.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 13)
            .frame(minHeight: 30)
            .background(TideStyle.accentFill.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.32),
                        in: RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous))
    }
}

struct TideDestructiveIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(TideStyle.body)
                .foregroundStyle(isHovered ? TideStyle.error : TideStyle.secondaryText)
                .frame(width: 28, height: 28)
                .background(isHovered ? TideStyle.error.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
