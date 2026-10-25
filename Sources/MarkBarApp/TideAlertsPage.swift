import SwiftUI
import MarkBarCore

@MainActor
struct TideAlertsPage: View {
    @ObservedObject var model: TideSettingsModel
    @ObservedObject var draft: TideAlertDraft

    private var contractID: String {
        model.preferences.watchlist.contains(where: { $0.id == draft.selectedContractID }) ? draft.selectedContractID : (model.preferences.watchlist.first?.id ?? "")
    }
    private var selectedContract: Contract? {
        model.preferences.watchlist.first { $0.id == contractID }
    }
    private var selectedPriceTitle: String { selectedContract?.priceTitle ?? "行情价格" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TideStyle.sectionSpacing) {
                TidePageHeading(title: "到价提醒", subtitle: "按品种对应的最新成交价或标记价触发提醒。") {
                    TideBadge(title: "\(model.preferences.alerts.filter(\.isEnabled).count) 条启用", symbol: "bell.badge")
                }
                notificationCard
                alertBoundary
                if model.preferences.watchlist.isEmpty {
                    TideCard {
                        TideEmptyState(symbol: "bell.slash", title: "先添加关注品种", detail: "在「关注行情」的「管理」中选择市场后，即可创建到价提醒。", compact: true)
                    }
                } else {
                    composer
                }
                rules
            }
            .padding(TideStyle.pagePadding)
        }
    }

    private var notificationCard: some View {
        HStack(spacing: 13) {
            Image(systemName: notificationSymbol)
                .font(.system(size: 18)).foregroundStyle(notificationColor)
                .frame(width: 40, height: 40)
                .background(notificationColor.opacity(0.09), in: RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.notificationStatus).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("未获系统通知授权时，不触发或消耗提醒规则。")
                    .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
            }
            Spacer(minLength: 12)
            notificationAction
        }
        .padding(TideStyle.cardPadding)
        .background(notificationColor.opacity(0.045), in: RoundedRectangle(cornerRadius: TideStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TideStyle.cardRadius, style: .continuous).strokeBorder(notificationColor.opacity(0.18), lineWidth: 1))
    }

    private var alertBoundary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(TideStyle.warning)
                .frame(width: 18)
            Text("OKX 系统网络使用 WebSocket；REST 采样、断连、报价过期和休眠期间可能漏报且不补发。仅用于辅助观察，不能替代交易所风控或止损。")
                .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OKX 系统网络使用 WebSocket。REST 采样、断连、报价过期和休眠期间可能漏报且不补发。仅用于辅助观察，不能替代交易所风控或止损。")
    }

    @ViewBuilder
    private var notificationAction: some View {
        switch model.notificationPermission {
        case .authorized:
            EmptyView()
        case .denied:
            Button("打开系统设置") { model.onOpenNotificationSettings?() }
                .buttonStyle(.bordered)
        case .notDetermined:
            Button("允许通知") { model.onRequestNotifications?() }
                .buttonStyle(TidePrimaryButtonStyle())
        case .unavailable, .failed:
            Button("重试") { model.onRequestNotifications?() }
                .buttonStyle(.bordered)
        }
    }

    private var notificationSymbol: String {
        switch model.notificationPermission {
        case .authorized: return "checkmark.circle.fill"
        case .denied, .failed: return "exclamationmark.triangle.fill"
        case .notDetermined, .unavailable: return "bell.badge"
        }
    }

    private var notificationColor: Color {
        switch model.notificationPermission {
        case .denied, .failed: return TideStyle.warning
        case .notDetermined, .authorized, .unavailable: return TideStyle.accent
        }
    }

    private var composer: some View {
        TideCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TideSectionHeading(title: "创建提醒", symbol: "plus.circle")
                    Picker("提醒模式", selection: Binding(
                        get: { draft.mode },
                        set: { mode in
                            draft.mode = mode
                            if mode == .simple && ![AlertDirection.above, .below].contains(draft.direction) {
                                draft.direction = .above
                            }
                        }
                    )) {
                        ForEach(TideAlertComposerMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 176)
                    .accessibilityLabel("提醒创建模式")
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("关注品种").font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                        Picker("品种", selection: Binding(get: { contractID }, set: { draft.selectedContractID = $0 })) {
                            ForEach(model.preferences.watchlist) { contract in
                                TideCoinPickerLabel(contract: contract)
                                    .tag(contract.id)
                            }
                        }
                        .labelsHidden().controlSize(.large).frame(height: 30)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(selectedPriceTitle)阈值").font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                        HStack(spacing: 8) {
                            TextField("例如 85000", text: $draft.threshold)
                                .textFieldStyle(.roundedBorder).accessibilityLabel("\(selectedPriceTitle)阈值")
                                .controlSize(.large).frame(height: 30)
                            Text(selectedContract?.quoteCurrency ?? "").font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("触发条件").font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    HStack(spacing: 8) {
                        if draft.mode == .simple {
                            ForEach(SimpleAlertTemplate.allCases, id: \.self) { template in
                                simpleConditionButton(template)
                            }
                        } else {
                            ForEach(AlertDirection.allCases, id: \.self) { condition in
                                conditionButton(condition)
                            }
                        }
                    }
                }
                Text(conditionDescription)
                    .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack(spacing: 16) {
                    Text("提醒频率").font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    Picker("提醒频率", selection: $draft.repeats) {
                        Text("仅一次").tag(false)
                        Text("每次 · 最多每分钟一次").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.large).frame(maxWidth: 310)
                    Toggle("需确认", isOn: $draft.requiresAcknowledgement)
                        .toggleStyle(.checkbox)
                        .help("触达后只发送一次系统通知，状态持续显示到确认；确认后重新布防")
                    Spacer(minLength: 0)
                    if draft.editingAlertID != nil {
                        Button("取消编辑", action: cancelEditing)
                            .buttonStyle(.bordered)
                    }
                    Button(action: saveAlert) {
                        Label(draft.editingAlertID == nil ? "添加提醒" : "保存修改",
                              systemImage: draft.editingAlertID == nil ? "plus" : "checkmark")
                    }
                        .buttonStyle(TidePrimaryButtonStyle())
                        .controlSize(.large)
                        .disabled(model.preferences.watchlist.isEmpty)
                }
                if !draft.validation.isEmpty {
                    Label(draft.validation, systemImage: draft.validationIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(TideStyle.caption).foregroundStyle(draft.validationIsError ? TideStyle.warning : TideStyle.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func conditionButton(_ condition: AlertDirection) -> some View {
        Button { draft.direction = condition } label: {
            HStack(spacing: 6) {
                Image(systemName: conditionSymbol(condition)).font(.system(size: 11, weight: .semibold))
                Text(condition.title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 32)
            .foregroundStyle(condition == draft.direction ? TideStyle.accent : TideStyle.secondaryText)
            .background(condition == draft.direction ? TideStyle.accent.opacity(0.09) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous).strokeBorder(condition == draft.direction ? TideStyle.accent.opacity(0.4) : TideStyle.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(condition == draft.direction ? .isSelected : [])
        .accessibilityLabel("\(condition.title)条件")
    }

    private func simpleConditionButton(_ template: SimpleAlertTemplate) -> some View {
        let condition = template.direction
        return Button { draft.direction = condition } label: {
            HStack(spacing: 7) {
                Image(systemName: conditionSymbol(condition)).font(.system(size: 12, weight: .semibold))
                Text(template.title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 34)
            .foregroundStyle(condition == draft.direction ? TideStyle.accent : TideStyle.secondaryText)
            .background(condition == draft.direction ? TideStyle.accent.opacity(0.09) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous)
                .strokeBorder(condition == draft.direction ? TideStyle.accent.opacity(0.4) : TideStyle.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: TideStyle.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(condition == draft.direction ? .isSelected : [])
        .accessibilityLabel("\(template.title)提醒条件")
        .accessibilityHint(template == .risesTo ? "从阈值下方到达或超过阈值时触发" : "从阈值上方到达或低于阈值时触发")
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 12) {
            TideSectionHeading(title: "我的提醒", symbol: "bell", detail: "\(model.preferences.alerts.count) 条规则")
            if model.preferences.alerts.isEmpty {
                TideCard {
                    TideEmptyState(symbol: "bell", title: "还没有到价提醒", detail: "选择品种与条件，添加你的第一条提醒。", compact: true)
                }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.preferences.alerts) { alert in alertRow(alert) }
                }
            }
        }
    }

    private func alertRow(_ alert: PriceAlert) -> some View {
        let pending = model.preferences.pendingAlerts.first { $0.ruleID == alert.id }
        return TideCard {
            HStack(alignment: .center, spacing: 13) {
                TideCoinAvatar(symbol: alert.contract.symbol)
                    .opacity(alert.isEnabled ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(alert.contract.displayTitle) · \(alert.direction.title) \(PriceFormatting.exact(alert.threshold)) \(alert.contract.quoteCurrency)")
                        .font(TideStyle.sectionTitle)
                        .foregroundStyle(alert.isEnabled ? Color.primary : TideStyle.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(alert.contract.exchange.title) · \(alert.contract.priceTitle) · \(triggerSummary(for: alert))")
                        .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let triggered = alert.lastTriggeredAt {
                        Text("上次触发：\(triggered.formatted(date: .abbreviated, time: .standard))")
                            .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    }
                    if let pending {
                        HStack(spacing: 8) {
                            Label("待确认 · 最新 \(PriceFormatting.compact(pending.latestPrice)) · \(pending.latestTriggeredAt.formatted(date: .omitted, time: .standard))",
                                  systemImage: "bell.badge.fill")
                                .font(TideStyle.caption).foregroundStyle(TideStyle.warning)
                            Button("确认") { model.onAcknowledgeAlert?(alert.id) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    } else if alert.requiresAcknowledgement {
                        Text("触达后需确认，确认后重新布防")
                            .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 5) {
                    Toggle("启用", isOn: Binding(
                        get: { model.preferences.alerts.first(where: { $0.id == alert.id })?.isEnabled ?? false },
                        set: { enabled in
                            model.update { preferences in
                                guard let index = preferences.alerts.firstIndex(where: { $0.id == alert.id }) else { return }
                                preferences.alerts[index].isEnabled = enabled
                                if enabled { preferences.alerts[index].lastTriggeredAt = nil }
                            }
                            if enabled { model.onRequestNotifications?() }
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("\(alert.contract.symbol) \(alert.direction.title) \(PriceFormatting.exact(alert.threshold)) 提醒")
                    .help(alert.isEnabled ? "停用提醒" : "重新启用提醒")
                    Text(alert.isEnabled ? "已启用" : "已停用").font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                }
                Button { editAlert(alert) } label: {
                    Image(systemName: "pencil")
                        .font(TideStyle.body)
                        .foregroundStyle(TideStyle.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("编辑提醒")
                .accessibilityLabel("编辑 \(alert.contract.symbol) \(alert.direction.title) \(PriceFormatting.exact(alert.threshold)) 提醒")
                TideDestructiveIconButton(symbol: "trash", help: "删除 \(alert.contract.symbol) \(alert.direction.title) \(PriceFormatting.exact(alert.threshold)) 提醒") {
                    if draft.editingAlertID == alert.id { cancelEditing() }
                    model.update { $0.alerts.removeAll { $0.id == alert.id } }
                }
            }
        }
    }

    private func conditionSymbol(_ condition: AlertDirection) -> String {
        switch condition {
        case .crossing: return "arrow.up.arrow.down"
        case .above: return "arrow.up.right"
        case .below: return "arrow.down.right"
        case .greaterThan: return "greaterthan"
        case .lessThan: return "lessthan"
        }
    }

    private var conditionDescription: String {
        let condition: String
        let repetition: String
        let price = selectedPriceTitle
        if draft.mode == .simple {
            switch draft.direction {
            case .below:
                condition = "\(price)从阈值上方跌到阈值或更低时提醒；首个有效报价只建立基准。"
                repetition = "再次跌到阈值才会重复，每分钟最多一次。"
            default:
                condition = "\(price)从阈值下方涨到阈值或更高时提醒；首个有效报价只建立基准。"
                repetition = "再次涨到阈值才会重复，每分钟最多一次。"
            }
            return draft.repeats ? condition + repetition : condition
        }
        switch draft.direction {
        case .crossing:
            condition = "\(price)从任一侧到达或越过阈值时提醒；首个有效报价只建立基准。"
            repetition = "再次到达或穿越才会重复，每分钟最多一次。"
        case .above:
            condition = "\(price)从下方向上到达或越过阈值时提醒；首个有效报价只建立基准。"
            repetition = "再次上穿才会重复，每分钟最多一次。"
        case .below:
            condition = "\(price)从上方向下到达或越过阈值时提醒；首个有效报价只建立基准。"
            repetition = "再次下穿才会重复，每分钟最多一次。"
        case .greaterThan:
            condition = "\(price)严格大于阈值时提醒。若当前已满足，下一个新鲜报价即可触发。"
            repetition = "持续满足时可重复，每分钟最多一次。"
        case .lessThan:
            condition = "\(price)严格小于阈值时提醒。若当前已满足，下一个新鲜报价即可触发。"
            repetition = "持续满足时可重复，每分钟最多一次。"
        }
        return draft.repeats ? condition + repetition : condition
    }

    private func triggerSummary(for alert: PriceAlert) -> String {
        guard alert.repeats else { return "仅一次" }
        let cooldown = alert.cooldown
        guard cooldown.isFinite, cooldown > 0 else { return "每次" }
        if cooldown == 60 { return "每次，最多每分钟一次" }
        if cooldown.truncatingRemainder(dividingBy: 60) == 0 {
            return "每次，每 \(NSDecimalNumber(value: cooldown / 60).stringValue) 分钟最多一次"
        }
        return "每次，每 \(NSDecimalNumber(value: cooldown).stringValue) 秒最多一次"
    }

    private func saveAlert() {
        guard let contract = model.preferences.watchlist.first(where: { $0.id == contractID }) else {
            draft.validation = "请先选择一个已关注的品种。"
            draft.validationIsError = true
            return
        }
        guard let value = TideSettingsModel.parseAlertThreshold(draft.threshold) else {
            draft.validation = "请输入大于 0 的十进制价格，不含逗号；最多 38 位有效数字。"
            draft.validationIsError = true
            return
        }
        if let editingAlertID = draft.editingAlertID,
           let existing = model.preferences.alerts.first(where: { $0.id == editingAlertID }) {
            let alert = PriceAlert(
                id: existing.id,
                contract: contract,
                direction: draft.direction,
                threshold: value,
                isEnabled: existing.isEnabled,
                repeats: draft.repeats,
                cooldown: existing.cooldown,
                lastTriggeredAt: nil,
                requiresAcknowledgement: draft.requiresAcknowledgement
            )
            model.update { preferences in
                guard let index = preferences.alerts.firstIndex(where: { $0.id == editingAlertID }) else { return }
                preferences.alerts[index] = alert
            }
        } else {
            let alert = PriceAlert(contract: contract, direction: draft.direction, threshold: value,
                                   isEnabled: true, repeats: draft.repeats, cooldown: 60,
                                   requiresAcknowledgement: draft.requiresAcknowledgement)
            model.update { $0.alerts.append(alert) }
        }
        model.onRequestNotifications?()
        let edited = draft.editingAlertID != nil
        draft.editingAlertID = nil
        draft.threshold = ""
        draft.validation = edited ? "已保存提醒修改。" : "已添加提醒。"
        draft.validationIsError = false
    }

    private func editAlert(_ alert: PriceAlert) {
        draft.editingAlertID = alert.id
        draft.selectedContractID = alert.contract.id
        draft.direction = alert.direction
        draft.mode = [.above, .below].contains(alert.direction) ? .simple : .advanced
        draft.threshold = PriceFormatting.exact(alert.threshold)
        draft.repeats = alert.repeats
        draft.requiresAcknowledgement = alert.requiresAcknowledgement
        draft.validation = "正在编辑 \(alert.contract.displayTitle) 的提醒。"
        draft.validationIsError = false
    }

    private func cancelEditing() {
        draft.editingAlertID = nil
        draft.mode = .simple
        draft.direction = .above
        draft.threshold = ""
        draft.repeats = false
        draft.requiresAcknowledgement = false
        draft.validation = ""
        draft.validationIsError = false
    }
}
