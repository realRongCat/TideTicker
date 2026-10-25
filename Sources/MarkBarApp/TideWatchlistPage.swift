import SwiftUI
import MarkBarCore

@MainActor
struct TideWatchlistPage: View {
    @ObservedObject var model: TideSettingsModel
    @ObservedObject var draft: TideWatchlistDraft
    let selectMode: (TideMarketMode) -> Void

    private var results: [Contract] {
        let query = draft.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.catalogue.filter { contract in
            contract.exchange == model.preferences.exchange &&
            (draft.marketKind == nil || contract.marketKind == draft.marketKind) &&
            (query.isEmpty || contract.symbol.localizedCaseInsensitiveContains(query) || contract.instrumentID.localizedCaseInsensitiveContains(query))
        }.sorted { $0.instrumentID.localizedStandardCompare($1.instrumentID) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TideStyle.sectionSpacing) {
                TidePageHeading(title: "关注行情", subtitle: "管理现货、USDT 永续与币本位永续，为菜单栏选择最多两条常驻报价。") {
                    HStack(spacing: 10) {
                        TideMarketModePicker(selection: .manage, onSelect: selectMode)
                        TideBadge(title: "\(model.preferences.watchlist.count) / 20 个关注", symbol: "star.fill")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: TideStyle.cardGap) {
                        watchlist
                        pinnedConfiguration.frame(width: 300)
                    }
                    VStack(alignment: .leading, spacing: TideStyle.cardGap) {
                        watchlist
                        pinnedConfiguration
                    }
                }
                catalogue
            }
            .padding(TideStyle.pagePadding)
        }
    }

    private var watchlist: some View {
        TideCard {
            VStack(alignment: .leading, spacing: 14) {
                TideSectionHeading(title: "我的关注", symbol: "star", detail: "菜单按此顺序排列")
                if model.preferences.watchlist.isEmpty {
                    TideEmptyState(symbol: "star", title: "还没有关注品种", detail: "从下方官方市场目录添加。", compact: true)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.preferences.watchlist) { contract in
                            watchedRow(contract)
                            if model.preferences.watchlist.last?.id != contract.id { Divider() }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func watchedRow(_ contract: Contract) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                TideContractLabel(contract: contract)
                if unavailable(contract) {
                    Text("官方目录中不可用，可移除")
                        .font(TideStyle.caption).foregroundStyle(TideStyle.warning)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                iconButton("chevron.up", label: "上移 \(contract.symbol)") { model.moveContract(contract, offset: -1) }
                    .disabled(model.preferences.watchlist.first?.id == contract.id)
                iconButton("chevron.down", label: "下移 \(contract.symbol)") { model.moveContract(contract, offset: 1) }
                    .disabled(model.preferences.watchlist.last?.id == contract.id)
                TideDestructiveIconButton(symbol: "minus.circle", help: "移除 \(contract.instrumentID) 及其到价提醒") {
                    model.update { $0.watchlist.removeAll { $0.id == contract.id } }
                }
            }
        }
        .frame(minHeight: 65)
    }

    private var pinnedConfiguration: some View {
        TideCard {
            VStack(alignment: .leading, spacing: 16) {
                TideSectionHeading(title: "菜单栏常驻", symbol: "menubar.rectangle")
                VStack(alignment: .leading, spacing: 10) {
                    pinnedPicker(title: "上行", position: 0)
                    pinnedPicker(title: "下行", position: 1)
                }
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "pin").foregroundStyle(TideStyle.accent)
                    Text("常驻位置独立保存，调整关注顺序不会改变常驻报价。")
                        .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.preferences.pinnedIDs.isEmpty {
                    Text("当前菜单栏显示 TideTicker")
                        .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func pinnedPicker(title: String, position: Int) -> some View {
        HStack(spacing: 10) {
            Text(title).font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText).frame(width: 28, alignment: .leading)
            Picker(title, selection: Binding(
                get: { model.preferences.pinnedIDs.indices.contains(position) ? model.preferences.pinnedIDs[position] : "" },
                set: { model.setPinned($0, position: position) }
            )) {
                Text(model.preferences.watchlist.isEmpty ? "暂无品种" : "不显示").tag("")
                ForEach(model.preferences.watchlist) { contract in
                    TideCoinPickerLabel(contract: contract).tag(contract.id)
                }
            }
            .labelsHidden()
            .disabled(model.preferences.watchlist.isEmpty || (position == 1 && model.preferences.pinnedIDs.isEmpty))
        }
    }

    private var catalogue: some View {
        TideCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TideSectionHeading(title: "添加关注", symbol: "plus.circle", detail: "\(model.preferences.exchange.title) 官方目录")
                    if model.catalogLoading { ProgressView().controlSize(.small) }
                    Button { model.onReloadCatalog?() } label: { Label("刷新目录", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .disabled(model.catalogLoading)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(TideStyle.secondaryText)
                    TextField("搜索品种，例如 BTC、SOL、1000PEPE", text: $draft.search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索官方市场目录")
                    if !draft.search.isEmpty {
                        Button { draft.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(TideStyle.secondaryText) }
                            .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                    }
                }
                .padding(10).background(TideStyle.raised, in: RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous))
                Picker("市场", selection: $draft.marketKind) {
                    Text("全部").tag(nil as MarketKind?)
                    ForEach(MarketKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind as MarketKind?)
                    }
                }
                .pickerStyle(.segmented)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").frame(width: 16)
                    Text(marketUsageDescription)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("市场用途：\(marketUsageDescription)")
                if results.isEmpty {
                    TideEmptyState(symbol: model.catalogLoading ? "arrow.triangle.2.circlepath" : "magnifyingglass",
                                   title: model.catalogLoading ? "正在读取官方目录" : (model.catalogue.isEmpty ? "目录尚未加载" : "没有匹配的品种"),
                                   detail: model.catalogLoading ? "加载后即可搜索与添加关注。" : (model.catalogue.isEmpty ? "点击刷新目录，读取当前来源的可用市场。" : "切换市场，或缩短搜索词。"),
                                   compact: true)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.prefix(60))) { contract in
                            catalogueRow(contract)
                            Divider()
                        }
                    }
                }
                Text(results.count > 60 ? "共 \(results.count) 个匹配，显示前 60 个；输入名称可缩小范围。" : "目录只包含交易所当前正常交易的品种。")
                    .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
            }
        }
    }

    private var marketUsageDescription: String {
        draft.marketKind?.usageDescription
            ?? "同一币种可能同时出现在多个市场；添加前请确认市场、报价与结算口径。"
    }

    private func catalogueRow(_ contract: Contract) -> some View {
        let watched = model.preferences.watchlist.contains { $0.id == contract.id }
        return HStack(spacing: 12) {
            TideContractLabel(contract: contract)
            Spacer()
            Button {
                guard model.preferences.watchlist.count < 20,
                      !model.preferences.watchlist.contains(where: { $0.id == contract.id }) else { return }
                model.update { $0.watchlist.append(contract) }
            } label: {
                Label(watched ? "已关注" : "关注", systemImage: watched ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .medium)).frame(width: 58)
            }
            .buttonStyle(.bordered)
            .disabled(watched || model.preferences.watchlist.count >= 20)
            .help(watched ? "已经在关注列表中" : (model.preferences.watchlist.count >= 20 ? "最多关注 20 个品种，请先移除一个" : "关注 \(contract.displayTitle)"))
        }
        .padding(.vertical, 9)
    }

    private func unavailable(_ contract: Contract) -> Bool {
        !model.catalogue.isEmpty && !model.catalogue.contains(where: { $0.id == contract.id })
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(TideStyle.caption).frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}
