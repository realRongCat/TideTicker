import SwiftUI
import MarkBarCore

@MainActor
struct TideOverviewPage: View {
    @ObservedObject var model: TideSettingsModel
    @ObservedObject var quotes: TideOverviewModel
    let selectMode: (TideMarketMode) -> Void

    private var rows: [TideOverviewQuote] {
        model.preferences.watchlist.map { contract in
            quotes.snapshot.rows.first(where: { $0.contract.id == contract.id }) ??
                TideOverviewQuote(contract: contract, price: nil, dataTime: nil, receivedAt: nil,
                                  isStale: true, possiblyMissed: true, error: nil, supplement: nil)
        }
    }
    private var freshCount: Int { rows.filter { $0.price != nil && !$0.isStale }.count }
    private var enabledAlerts: Int { model.preferences.alerts.filter(\.isEnabled).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TideStyle.sectionSpacing) {
                TidePageHeading(title: "关注行情", subtitle: "\(model.preferences.exchange.title) · 现货 · USDT 永续 · 币本位永续") {
                    HStack(spacing: 10) {
                        TideMarketModePicker(selection: .overview, onSelect: selectMode)
                        Button { model.onRefresh?() } label: {
                            Label(quotes.snapshot.isRefreshing ? "刷新中" : "刷新行情", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(quotes.snapshot.isRefreshing || quotes.snapshot.isPaused || rows.isEmpty)
                        .controlSize(.large)
                    }
                }
                summary
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TideSectionHeading(title: "实时行情", symbol: "waveform.path", detail: "最新成交价 / 标记价")
                        Button("管理") { selectMode(.manage) }.buttonStyle(.link).font(TideStyle.caption)
                    }
                    if rows.isEmpty {
                        TideCard {
                            VStack(spacing: 0) {
                                TideEmptyState(symbol: "star", title: "从一个关注开始", detail: "从官方市场目录添加品种，在这里查看价格与更新状态。")
                                Button("添加关注品种") { selectMode(.manage) }
                                    .buttonStyle(TidePrimaryButtonStyle())
                            }
                            .frame(maxWidth: .infinity).padding(.bottom, 14)
                        }
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(rows, id: \.contract.id) { row in
                                TideQuoteCard(row: row, pin: pin(for: row.contract))
                            }
                        }
                        .frame(maxWidth: 980, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                    Text("现货主报价为最新成交价，永续主报价为标记价。数据时间距现在超过 \(Int(model.preferences.staleAfter)) 秒时，保留上次价格并标为过期。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
            }
            .padding(TideStyle.pagePadding)
        }
    }

    private var summary: some View {
        TideCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    metric(title: "关注品种", value: "\(rows.count)", suffix: "/ 20", symbol: "star")
                    Divider().frame(height: 43)
                    metric(title: "新鲜报价", value: "\(freshCount)", suffix: "/ \(rows.count)", symbol: "dot.radiowaves.left.and.right")
                    Divider().frame(height: 43)
                    metric(title: "菜单栏常驻", value: "\(model.preferences.pinnedIDs.count)", suffix: "/ 2", symbol: "menubar.rectangle")
                    Divider().frame(height: 43)
                    metric(title: "启用提醒", value: "\(enabledAlerts)", suffix: "条", symbol: "bell.badge")
                }
                Divider()
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        if rows.isEmpty {
                            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 48, height: 5)
                        }
                        ForEach(rows, id: \.contract.id) { row in
                            Capsule().fill(statusColor(row)).frame(maxWidth: 30).frame(height: 5)
                                .help("\(row.contract.symbol)：\(statusTitle(row))")
                        }
                    }
                    .frame(width: min(130, max(24, CGFloat(rows.count) * 28 - 4)), alignment: .leading)
                    Text(statusDescription).font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    Spacer(minLength: 0)
                    if quotes.snapshot.isPaused {
                        TideBadge(title: "更新已暂停", color: TideStyle.warning, symbol: "pause.fill")
                    } else {
                        TideBadge(title: quotes.snapshot.isRefreshing ? "正在更新" : "每 \(Int(model.preferences.refreshInterval)) 秒更新",
                                  symbol: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
    }

    private func metric(title: String, value: String, suffix: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                Text(suffix).font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusDescription: String {
        if rows.isEmpty { return "尚未关注品种" }
        let errors = rows.filter { $0.error != nil }.count
        if errors > 0 { return "\(errors) 个品种连接异常 · 新鲜报价 \(freshCount)/\(rows.count)" }
        let gaps = rows.filter(\.possiblyMissed).count
        if gaps > 0 { return "\(gaps) 个品种可能漏报 · 新鲜报价 \(freshCount)/\(rows.count)" }
        if freshCount == rows.count { return "全部关注品种均有新鲜报价" }
        return "\(rows.count - freshCount) 个品种等待更新"
    }

    private func pin(for contract: Contract) -> String? {
        guard let index = model.preferences.pinnedIDs.firstIndex(of: contract.id) else { return nil }
        return index == 0 ? "上行" : "下行"
    }
}

private func statusColor(_ row: TideOverviewQuote) -> Color {
    if row.error != nil { return TideStyle.warning }
    if row.price == nil { return .secondary.opacity(0.4) }
    return row.isStale || row.possiblyMissed ? TideStyle.warning : TideStyle.accent
}

private func statusTitle(_ row: TideOverviewQuote) -> String {
    if row.isStale && row.price != nil { return "报价已过期" }
    if row.error != nil { return "连接异常" }
    if row.possiblyMissed { return "可能漏报" }
    return row.price == nil ? "等待报价" : "报价新鲜"
}

private struct TideQuoteCard: View {
    let row: TideOverviewQuote
    let pin: String?

    var body: some View {
        TideCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    TideContractLabel(contract: row.contract, showsInstrumentID: false, compact: true)
                    Spacer(minLength: 0)
                    if let pin {
                        TideBadge(title: pin, color: .secondary, symbol: "pin.fill")
                            .help("菜单栏常驻\(pin)")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(row.price.map(PriceFormatting.compact) ?? "—")
                        .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(row.price != nil && row.isStale ? TideStyle.secondaryText : Color.primary)
                        .lineLimit(1).minimumScaleFactor(0.55)
                        .help(row.price.map(PriceFormatting.exact) ?? "尚未收到\(row.contract.priceTitle)")
                    Text(row.contract.quoteCurrency).font(.system(size: 10, weight: .medium)).foregroundStyle(TideStyle.secondaryText)
                }
                HStack(spacing: 6) {
                    Circle().fill(statusColor(row)).frame(width: 6, height: 6)
                    Text(statusTitle(row)).font(TideStyle.caption).foregroundStyle(statusColor(row))
                    Spacer(minLength: 0)
                    if let dataTime = row.dataTime {
                        Text("数据 \(dataTime.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(TideStyle.secondaryText)
                            .help("数据时间：\(dataTime.formatted(date: .abbreviated, time: .standard))\n\(row.contract.dataTimeDescription)")
                    }
                }
                if let supplement = row.supplement {
                    supplementGrid(supplement)
                }
                messageLine
            }
        }
        .help(technicalHelp)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.contract.displayTitle) \(row.contract.priceTitle)，\(statusTitle(row))")
    }

    private var technicalHelp: String {
        let received = row.receivedAt?.formatted(date: .abbreviated, time: .standard) ?? "等待更新"
        var lines = ["原生品种：\(row.contract.instrumentID)", "本地收到时间：\(received)"]
        if row.possiblyMissed { lines.append("当前传输可能漏过短暂触价") }
        if let error = row.error { lines.append(error) }
        return lines.joined(separator: "\n")
    }

    private func supplementGrid(_ supplement: TideOverviewSupplement) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                supplementMetric("24h", supplement.change24h)
                supplementMetric("费率", supplement.fundingRate)
            }
            GridRow {
                supplementMetric("距结算", supplement.fundingCountdown)
                supplementMetric("现货差", supplement.premium)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func supplementMetric(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let value {
                Text(label).foregroundStyle(TideStyle.secondaryText)
                Spacer(minLength: 4)
                Text(value).monospacedDigit().foregroundStyle(Color.primary.opacity(0.82))
                    .lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Color.clear
            }
        }
        .font(TideStyle.caption)
        .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
    }

    @ViewBuilder private var messageLine: some View {
        if let text = messageText {
            Text(text)
                .font(TideStyle.caption)
                .foregroundStyle(TideStyle.warning)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
                .textSelection(.enabled)
        }
    }

    private var messageText: String? {
        var parts: [String] = []
        if row.possiblyMissed { parts.append("当前传输可能漏过短暂触价") }
        if row.supplement?.isStale == true { parts.append("补充行情已过期") }
        if let error = row.error { parts.append(error) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
