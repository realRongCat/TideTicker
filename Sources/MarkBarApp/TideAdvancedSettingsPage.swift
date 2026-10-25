import SwiftUI
import MarkBarCore

@MainActor
struct TideAdvancedSettingsPage: View {
    @ObservedObject var model: TideSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TideStyle.sectionSpacing) {
                TidePageHeading(
                    title: "高级设置",
                    subtitle: "调整菜单栏外观、登录启动和软件更新。"
                )

                TideCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TideSectionHeading(title: "菜单栏", symbol: "menubar.rectangle")
                        settingRow(
                            title: "使用币种图标",
                            detail: "在菜单栏常驻报价中显示币种图标；关闭后使用 BTC、ETH 等文字代号"
                        ) {
                            Toggle("使用币种图标", isOn: Binding(
                                get: { model.advancedSettings.showsCoinIcons },
                                set: { model.onSetCoinIcons?($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel("菜单栏使用币种图标")
                        }
                    }
                }

                TideCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TideSectionHeading(title: "登录启动", symbol: "power")
                        settingRow(title: "登录时启动", detail: loginDetail) {
                            Toggle("登录时启动", isOn: Binding(
                                get: { loginIsRegistered },
                                set: { model.onSetLoginItem?($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(!model.advancedSettings.canManageLoginItem
                                      || model.advancedSettings.loginIsBusy)
                        }
                        Divider()
                        HStack {
                            Text(loginStatus)
                                .font(TideStyle.caption)
                                .foregroundStyle(loginStatusColor)
                            Spacer(minLength: 16)
                            Button {
                                model.onOpenLoginSettings?()
                            } label: {
                                Label("打开登录项设置", systemImage: "gearshape")
                            }
                            .disabled(!model.advancedSettings.canManageLoginItem)
                        }
                    }
                }

                TideCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TideSectionHeading(title: "软件更新", symbol: "arrow.triangle.2.circlepath")
                        settingRow(
                            title: "自动检查更新",
                            detail: "定期检查 TideTicker 的最新稳定版本；关闭后仍可手动检查"
                        ) {
                            Toggle("自动检查更新", isOn: Binding(
                                get: { model.advancedSettings.automaticallyChecksForUpdates },
                                set: { model.onSetAutomaticChecks?($0) }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(!model.advancedSettings.canChangeAutomaticChecks)
                        }
                        Divider()
                        HStack {
                            Text("手动检查不会更改自动检查设置。")
                                .font(TideStyle.caption).foregroundStyle(TideStyle.secondaryText)
                            Spacer(minLength: 16)
                            Button {
                                model.onCheckForUpdates?()
                            } label: {
                                Label("检查更新", systemImage: "arrow.clockwise")
                            }
                            .disabled(!model.advancedSettings.canChangeAutomaticChecks)
                        }
                    }
                }
            }
            .padding(TideStyle.pagePadding)
        }
    }

    private var loginIsRegistered: Bool {
        switch model.advancedSettings.loginStatus {
        case .enabled, .requiresApproval: return true
        case .unknown, .notRegistered, .notFound: return false
        }
    }

    private var loginDetail: String {
        "登录 macOS 后自动运行 TideTicker，并在菜单栏恢复行情观察"
    }

    private var loginStatus: String {
        if let error = model.advancedSettings.loginError {
            return "设置失败：\(error)"
        }
        if model.advancedSettings.loginIsBusy { return "正在更新登录项…" }
        switch model.advancedSettings.loginStatus {
        case .unknown: return "正在检查登录项…"
        case .notRegistered: return "当前未启用"
        case .enabled: return "已启用"
        case .requiresApproval: return "已注册，请在系统设置中批准"
        case .notFound: return "请先将 TideTicker 安装到应用程序文件夹"
        }
    }

    private var loginStatusColor: Color {
        if model.advancedSettings.loginError != nil { return TideStyle.error }
        if model.advancedSettings.loginStatus == .requiresApproval { return TideStyle.warning }
        return TideStyle.secondaryText
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
}
