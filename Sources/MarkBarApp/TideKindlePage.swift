import AppKit
import SwiftUI

@MainActor
struct TideExternalDisplayPage: View {
    @ObservedObject var model: TideKindleModel
    @State private var confirmsReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TideStyle.sectionSpacing) {
                TidePageHeading(
                    title: "外部显示",
                    subtitle: "管理 TideTicker 的独立显示方式。"
                )
                TideCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TideSectionHeading(title: "Kindle 展示", symbol: "book")
                        settingRow(title: "启用 Kindle 展示", detail: "在可信局域网中提供为墨水屏优化的只读页面") {
                            Toggle("启用 Kindle 展示", isOn: Binding(
                                get: { model.enabled },
                                set: { model.setEnabled($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel("启用 Kindle 展示")
                        }
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: statusSymbol)
                                .foregroundStyle(statusColor)
                            Text(model.status).font(TideStyle.body.weight(.medium))
                            Spacer(minLength: 0)
                        }
                    }
                }

                if model.enabled {
                    TideCard {
                        VStack(alignment: .leading, spacing: 14) {
                            TideSectionHeading(title: "访问地址", symbol: "link")
                            if model.address.isEmpty {
                                Text("等待局域网地址…")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(TideStyle.secondaryText)
                            } else {
                                Text(model.address)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 10) {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(model.address, forType: .string)
                                    } label: {
                                        Label("复制地址", systemImage: "doc.on.doc")
                                    }
                                    .buttonStyle(TidePrimaryButtonStyle())
                                    Button {
                                        guard let url = URL(string: model.address) else { return }
                                        NSWorkspace.shared.open(url)
                                    } label: {
                                        Label("浏览器预览", systemImage: "safari")
                                    }
                                    Button {
                                        confirmsReset = true
                                    } label: {
                                        Label("重置配对地址", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            Text("地址包含随机配对令牌。重置后，旧书签会立即失效。")
                                .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                        }
                    }

                    TideCard {
                        VStack(alignment: .leading, spacing: 14) {
                            TideSectionHeading(title: "墨水屏刷新", symbol: "rectangle.3.group")
                            settingRow(title: "价格展示间隔", detail: "Mac 端仍实时接收行情；这里只限制 Kindle 重绘频率") {
                                Picker("价格展示间隔", selection: Binding(
                                    get: { model.refreshInterval },
                                    set: { model.setRefreshInterval($0) }
                                )) {
                                    ForEach([TimeInterval(5), 10, 15, 30], id: \.self) { interval in
                                        Text("\(Int(interval)) 秒").tag(interval)
                                    }
                                }
                                .labelsHidden().pickerStyle(.segmented).frame(width: 248)
                            }
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Label("只读展示", systemImage: "lock")
                                    .font(TideStyle.body.weight(.medium))
                                Text("Kindle 不能修改关注、提醒或来源。过期、断线、可能漏报和待确认提醒会优先刷新。")
                                    .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    TideCard {
                        VStack(alignment: .leading, spacing: 10) {
                            TideSectionHeading(title: "连接步骤", symbol: "book")
                            connectionStep("1", "让 Kindle 与这台 Mac 连接同一个 Wi-Fi。")
                            connectionStep("2", "在 Kindle 的体验版浏览器中打开上方地址，并添加书签。")
                            connectionStep("3", "保持 TideTicker 运行；离开可信网络前关闭展示服务。")
                        }
                    }
                }
            }
            .padding(TideStyle.pagePadding)
        }
        .confirmationDialog("重置 Kindle 配对地址？", isPresented: $confirmsReset) {
            Button("重置地址", role: .destructive) { model.resetToken() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前 Kindle 书签将无法继续访问，需要使用新地址重新打开。")
        }
    }

    private var statusSymbol: String {
        switch model.serviceState {
        case .disabled: return "circle"
        case .starting, .awaitingAddress: return "clock"
        case .ready: return "checkmark.circle.fill"
        case .failed, .stopped: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.serviceState {
        case .ready: return TideStyle.accent
        case .failed, .stopped: return TideStyle.error
        case .disabled, .starting, .awaitingAddress: return TideStyle.secondaryText
        }
    }

    private func settingRow<Control: View>(title: String, detail: String,
                                           @ViewBuilder control: () -> Control) -> some View {
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

    private func connectionStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(TideStyle.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(TideStyle.raised, in: Circle())
            Text(text).font(TideStyle.body).padding(.top, 3)
        }
    }
}
