import AppKit
import SwiftUI
import MarkBarCore

@MainActor
struct TideSourcePage: View {
    @ObservedObject var model: TideSettingsModel
    @State private var showsDiagnosticDetails = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TidePageHeading(title: "行情来源", subtitle: "选择官方行情来源，调整连接方式与更新偏好。")
                sourceSection
                Divider()
                networkSection
                if model.connectionTesting || model.connectionDiagnostic != nil {
                    Divider()
                    diagnosticSection
                }
                Divider()
                displaySection
            }
            .padding(TideStyle.pagePadding)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TideSectionHeading(title: "交易所", symbol: "building.columns", detail: "现货 · USDT 永续 · 币本位永续")
            HStack(spacing: 10) {
                ForEach(Exchange.allCases, id: \.self) { exchange in
                    exchangeOption(exchange)
                }
            }
            HStack(alignment: .center, spacing: 14) {
                Text("目录和报价连接验证成功后才会切换。各来源分别保存关注列表与提醒。")
                    .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.catalogLoading { ProgressView().controlSize(.small) }
                Button { model.onTestConnection?() } label: {
                    Label(model.connectionTesting ? "测试中" : "测试连接", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.catalogLoading || model.connectionTesting)
            }
        }
    }

    private func exchangeOption(_ exchange: Exchange) -> some View {
        let selected = model.preferences.exchange == exchange
        return Button {
            guard !selected else { return }
            model.onSelectExchange?(exchange)
        } label: {
            HStack(spacing: 11) {
                TideExchangeMark(exchange: exchange, selected: selected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(exchange.title).font(TideStyle.label)
                    Text(selected ? "当前来源" : "验证后切换")
                        .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? TideStyle.accent : TideStyle.secondaryText.opacity(0.55))
            }
            .padding(.horizontal, 13).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(selected ? TideStyle.accent.opacity(0.10) : TideStyle.card,
                        in: RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous)
                .strokeBorder(selected ? TideStyle.accent.opacity(0.50) : TideStyle.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.catalogLoading || model.connectionTesting)
        .accessibilityLabel("\(exchange.title)，\(selected ? "当前来源" : "验证后切换")")
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TideSectionHeading(title: "网络连接", symbol: "network", detail: "对所有来源生效")
            HStack(spacing: 10) {
                networkOption(.system, symbol: "globe", badge: "默认推荐", caption: "沿用 macOS 代理、DNS 与路由")
                networkOption(.physicalDirect, symbol: "cable.connector", badge: "高级", caption: "需要物理 IPv4、DoH 与官方端点可达")
            }
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                Text("\(model.preferences.networkMode.detail) 选择后立即重新连接；失败时不会自动回退。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
        }
    }

    private func networkOption(_ mode: NetworkMode, symbol: String, badge: String, caption: String) -> some View {
        let selected = model.preferences.networkMode == mode
        return Button {
            guard !selected else { return }
            model.update { $0.networkMode = mode }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? TideStyle.accent : TideStyle.secondaryText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(mode.title).font(TideStyle.label)
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(mode == .system ? TideStyle.accent : TideStyle.secondaryText)
                    }
                    Text(caption).font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? TideStyle.accent : TideStyle.secondaryText.opacity(0.55))
            }
            .padding(.horizontal, 13).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(selected ? TideStyle.accent.opacity(0.10) : TideStyle.card,
                        in: RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous)
                .strokeBorder(selected ? TideStyle.accent.opacity(0.50) : TideStyle.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: TideStyle.optionRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.connectionTesting)
        .accessibilityLabel("\(mode.title)，\(badge)，\(selected ? "已选择" : "未选择")，\(caption)")
    }

    @ViewBuilder
    private var diagnosticSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TideSectionHeading(title: "连接诊断", symbol: "stethoscope", detail: "目录与代表报价")
                if let report = model.connectionDiagnostic {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.copyText, forType: .string)
                        model.setMessage("已复制脱敏连接诊断摘要。", kind: .success, dismissAfter: 4)
                    } label: {
                        Label("复制摘要", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("复制不含代理凭据、本地路径、IP、偏好和关注列表的诊断摘要")
                }
            }
            if model.connectionTesting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在刷新官方市场目录；通过后继续测试一个代表报价。")
                        .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                }
            } else if let report = model.connectionDiagnostic {
                TideCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(report.succeeded ? TideStyle.accent : TideStyle.warning)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.succeeded ? "连接诊断通过" : "连接诊断未通过")
                                    .font(TideStyle.sectionTitle)
                                Text("\(report.exchange.title) · \(report.networkMode.title) · \(duration(report.duration))")
                                    .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Text(report.startedAt.formatted(date: .omitted, time: .standard))
                                .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                        }
                        Text(report.recommendation)
                            .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("阶段结果", isExpanded: $showsDiagnosticDetails) {
                            VStack(spacing: 0) {
                                ForEach(report.steps) { step in
                                    diagnosticStep(step)
                                    if step.id != report.steps.last?.id { Divider() }
                                }
                            }
                            .padding(.top, 8)
                        }
                        .font(TideStyle.body.weight(.medium))
                    }
                }
            }
        }
    }

    private func diagnosticStep(_ step: ConnectionDiagnosticStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.succeeded ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(step.succeeded ? TideStyle.accent : TideStyle.warning)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.stage.title).font(TideStyle.label)
                    Spacer(minLength: 8)
                    Text(duration(step.duration)).font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                }
                Text("\(step.market) · \(step.hostnames.joined(separator: "、"))")
                    .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    .textSelection(.enabled)
                Text(step.errorCategory?.title ?? step.detail)
                    .font(TideStyle.caption)
                    .foregroundStyle(step.succeeded ? TideStyle.secondaryText : TideStyle.warning)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func duration(_ value: TimeInterval) -> String {
        String(format: "%.2f 秒", max(0, value.isFinite ? value : 0))
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TideSectionHeading(title: "更新与显示", symbol: "slider.horizontal.3")
            settingRow(title: "行情刷新间隔", detail: "各品种独立更新与判断过期") {
                Picker("行情刷新间隔", selection: Binding(
                    get: { model.preferences.refreshInterval },
                    set: { interval in model.update { $0.refreshInterval = interval } }
                )) {
                    ForEach([TimeInterval(5), 10, 15, 30], id: \.self) { interval in
                        Text("\(Int(interval)) 秒").tag(interval)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 248)
            }
            Divider()
            settingRow(title: "显示补充行情", detail: "开启后约 60 秒更新：现货显示 24h 涨跌，永续另显示资金费率、结算倒计时和同所溢折价") {
                Toggle("显示补充行情", isOn: Binding(
                    get: { model.preferences.showsMarketDetails },
                    set: { enabled in model.update { $0.showsMarketDetails = enabled } }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("显示补充行情")
            }
        }
    }

    private func settingRow<Control: View>(title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TideStyle.body.weight(.medium))
                Text(detail).font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.vertical, 2)
    }
}
