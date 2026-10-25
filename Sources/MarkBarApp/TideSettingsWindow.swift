import AppKit
import SwiftUI
import MarkBarCore

enum TideWindowPage: String, CaseIterable {
    case market, source, alerts, externalDisplay, advanced

    var title: String {
        switch self {
        case .market: return "关注行情"
        case .source: return "行情来源"
        case .alerts: return "到价提醒"
        case .externalDisplay: return "外部显示"
        case .advanced: return "高级设置"
        }
    }

    var symbol: String {
        switch self {
        case .market: return "waveform.path"
        case .source: return "network"
        case .alerts: return "bell"
        case .externalDisplay: return "display.2"
        case .advanced: return "gearshape"
        }
    }
}

enum TideMarketMode: String, CaseIterable {
    case overview, manage

    var title: String {
        switch self {
        case .overview: return "概览"
        case .manage: return "管理"
        }
    }
}

@MainActor
private final class TideWindowNavigation: ObservableObject {
    @Published private(set) var page: TideWindowPage = .market
    @Published private(set) var marketMode: TideMarketMode = .overview
    var onChange: (() -> Void)?

    func select(_ page: TideWindowPage) {
        guard self.page != page else { return }
        self.page = page
        onChange?()
    }

    func selectMarket(_ mode: TideMarketMode) {
        guard page != .market || marketMode != mode else { return }
        page = .market
        marketMode = mode
        onChange?()
    }
}

@MainActor
final class TideSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let navigation = TideWindowNavigation()
    private let quotes = TideOverviewModel()
    private let watchlistDraft = TideWatchlistDraft()
    private let alertDraft = TideAlertDraft()
    private let kindleModel: TideKindleModel
    private var isPresented = false
    var onRequestQuoteSnapshot: (() -> Void)?
    var onClose: (() -> Void)?

    var wantsQuoteUpdates: Bool {
        isPresented && window?.isVisible == true && window?.isMiniaturized == false
            && navigation.page == .market && navigation.marketMode == .overview
    }

    init(model: TideSettingsModel, kindleModel: TideKindleModel) {
        self.kindleModel = kindleModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TideTicker"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = TideStyle.canvasColor
        window.minSize = NSSize(width: 940, height: 700)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TideSettingsRoot(
            model: model, navigation: navigation, quotes: quotes,
            watchlistDraft: watchlistDraft, alertDraft: alertDraft,
            kindleModel: kindleModel
        ))
        window.center()
        window.setFrameAutosaveName("TideMainWindow")
        super.init(window: window)
        window.delegate = self
        navigation.onChange = { [weak self] in
            guard let self, self.wantsQuoteUpdates else { return }
            self.onRequestQuoteSnapshot?()
        }
    }

    required init?(coder: NSCoder) { return nil }

    func present(page: TideWindowPage? = nil, marketMode: TideMarketMode? = nil) {
        if let marketMode { navigation.selectMarket(marketMode) }
        else if let page { navigation.select(page) }
        isPresented = true
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if wantsQuoteUpdates { onRequestQuoteSnapshot?() }
    }

    func updateQuotes(_ rows: [TideOverviewQuote], isRefreshing: Bool, isPaused: Bool) {
        guard wantsQuoteUpdates else { return }
        quotes.update(rows, isRefreshing: isRefreshing, isPaused: isPaused)
    }

    func windowWillClose(_ notification: Notification) {
        isPresented = false
        onClose?()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if wantsQuoteUpdates { onRequestQuoteSnapshot?() }
    }
}

@MainActor
private struct TideSettingsRoot: View {
    // Only navigation is observed here. Quote publications never rebuild the
    // retained root or sidebar, including after the window has been closed.
    let model: TideSettingsModel
    @ObservedObject var navigation: TideWindowNavigation
    let quotes: TideOverviewModel
    let watchlistDraft: TideWatchlistDraft
    let alertDraft: TideAlertDraft
    let kindleModel: TideKindleModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 206)
                .frame(maxHeight: .infinity)
                .background(TideStyle.sidebar)
            Rectangle().fill(TideStyle.border).frame(width: 0.75)
            VStack(spacing: 0) {
                Group {
                    switch navigation.page {
                    case .market:
                        switch navigation.marketMode {
                        case .overview:
                            TideOverviewPage(model: model, quotes: quotes,
                                             selectMode: navigation.selectMarket)
                        case .manage:
                            TideWatchlistPage(model: model, draft: watchlistDraft,
                                              selectMode: navigation.selectMarket)
                        }
                    case .source:
                        TideSourcePage(model: model)
                    case .alerts:
                        TideAlertsPage(model: model, draft: alertDraft)
                    case .externalDisplay:
                        TideExternalDisplayPage(model: kindleModel)
                    case .advanced:
                        TideAdvancedSettingsPage(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                TideSettingsMessage(model: model)
            }
            .background(TideStyle.canvas)
        }
        .tint(TideStyle.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TideBrandImage()
                VStack(alignment: .leading, spacing: 4) {
                    Text("TideTicker").font(.system(size: 17, weight: .semibold))
                    Text("让行情，一目了然")
                        .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 28)
            Text("行情与偏好")
                .font(TideStyle.caption.weight(.medium)).foregroundStyle(TideStyle.secondaryText)
                .padding(.horizontal, 24).padding(.bottom, 8)
            VStack(spacing: 4) {
                ForEach(TideWindowPage.allCases, id: \.self) { page in
                    Button { navigation.select(page) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.symbol)
                                .font(.system(size: 14, weight: .medium)).frame(width: 20)
                            Text(page.title)
                                .font(TideStyle.label.weight(navigation.page == page ? .semibold : .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(navigation.page == page ? TideStyle.accent : Color.primary.opacity(0.78))
                        .padding(.horizontal, 12).frame(height: TideStyle.sidebarRowHeight)
                        .background(navigation.page == page ? TideStyle.accent.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(navigation.page == page ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 24)
            TideSidebarContext(model: model).padding(.horizontal, 18).padding(.bottom, 14)
            Divider().padding(.horizontal, 18)
            TideCreatorLink().padding(.horizontal, 10).padding(.vertical, 5)
        }
    }
}

@MainActor
private struct TideSidebarContext: View {
    @ObservedObject var model: TideSettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            contextRow(label: "交易所", value: model.preferences.exchange.title) {
                TideExchangeMark(exchange: model.preferences.exchange, selected: true)
            }
            contextRow(label: "市场", value: "现货与永续") {
                Image(systemName: "chart.xyaxis.line").frame(width: 24)
            }
            contextRow(label: "网络", value: model.preferences.networkMode.title) {
                Image(systemName: model.preferences.networkMode == .system ? "globe" : "cable.connector")
                    .frame(width: 24)
            }
        }
    }

    private func contextRow<Icon: View>(label: String, value: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            icon().foregroundStyle(TideStyle.secondaryText)
            Text(label).frame(width: 38, alignment: .leading)
            Text(value).lineLimit(1)
        }
        .font(TideStyle.caption)
        .foregroundStyle(TideStyle.secondaryText)
        .help("\(label)：\(value)")
    }
}

@MainActor
private struct TideSettingsMessage: View {
    @ObservedObject var model: TideSettingsModel
    var body: some View {
        if !model.message.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                if model.messageKind == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: messageSymbol).foregroundStyle(messageColor)
                }
                Text(model.message).textSelection(.enabled).lineLimit(3).help(model.message)
                Spacer(minLength: 0)
            }
            .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
            .padding(.horizontal, TideStyle.pagePadding).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(messageColor.opacity(0.055))
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var messageSymbol: String {
        switch model.messageKind {
        case .info: return "info.circle"
        case .loading: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var messageColor: Color {
        switch model.messageKind {
        case .info, .loading, .success: return TideStyle.accent
        case .error: return TideStyle.error
        }
    }
}
