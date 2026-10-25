import AppKit
import SwiftUI
import MarkBarCore

@MainActor
final class TideUpdatePanelController: NSWindowController {
    private var dismissTask: Task<Void, Never>?
    private var onDismiss: (() -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 124),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.title = "TideTicker 更新"
        panel.setAccessibilityTitle("TideTicker 更新")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { nil }

    func presentRelease(_ release: AppRelease, currentVersion: AppVersion,
                        anchor: NSStatusItem?, onOpen: @escaping () -> Void,
                        onRemindLater: @escaping () -> Void,
                        onSkip: @escaping () -> Void) {
        dismissTask?.cancel()
        onDismiss = onRemindLater
        window?.contentView = NSHostingView(rootView: TideUpdatePanelView(
            presentation: .release(release, currentVersion: currentVersion),
            onPrimary: onOpen,
            onSecondary: onRemindLater,
            onTertiary: onSkip,
            onClose: onRemindLater
        ))
        position(anchor: anchor)
        window?.orderFrontRegardless()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissUsingDefaultAction()
        }
    }

    func presentMessage(title: String, detail: String, symbol: String,
                        anchor: NSStatusItem?, dismissAfter: TimeInterval = 6) {
        dismissTask?.cancel()
        onDismiss = nil
        window?.contentView = NSHostingView(rootView: TideUpdatePanelView(
            presentation: .message(title: title, detail: detail, symbol: symbol),
            onPrimary: { [weak self] in self?.dismiss() },
            onSecondary: nil,
            onTertiary: nil,
            onClose: { [weak self] in self?.dismiss() }
        ))
        position(anchor: anchor)
        window?.orderFrontRegardless()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, dismissAfter) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        onDismiss = nil
        window?.orderOut(nil)
    }

    private func dismissUsingDefaultAction() {
        let action = onDismiss
        dismiss()
        action?()
    }

    private func position(anchor: NSStatusItem?) {
        guard let window else { return }
        let size = window.frame.size
        let anchorFrame: NSRect? = anchor?.button.flatMap { button in
            guard let buttonWindow = button.window else { return nil }
            return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let screen = anchor?.button?.window?.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let targetX = anchorFrame.map { $0.midX - size.width / 2 } ?? (visibleFrame.maxX - size.width - 16)
        let x = min(max(targetX, visibleFrame.minX + 12), visibleFrame.maxX - size.width - 12)
        let targetY = anchorFrame.map { $0.minY - size.height - 8 } ?? (visibleFrame.maxY - size.height - 16)
        let y = min(max(targetY, visibleFrame.minY + 12), visibleFrame.maxY - size.height - 12)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private enum TideUpdatePresentation {
    case release(AppRelease, currentVersion: AppVersion)
    case message(title: String, detail: String, symbol: String)
}

private struct TideUpdatePanelView: View {
    let presentation: TideUpdatePresentation
    let onPrimary: () -> Void
    let onSecondary: (() -> Void)?
    let onTertiary: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(TideStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(TideStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(TideStyle.body).foregroundStyle(TideStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).frame(width: 24, height: 24)
                .help("关闭")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let onTertiary {
                    Button("跳过此版本", action: onTertiary).buttonStyle(.borderless)
                }
                if let onSecondary {
                    Button("24 小时后提醒", action: onSecondary)
                }
                Button(action: onPrimary) {
                    Label(primaryTitle, systemImage: primarySymbol)
                }
                .buttonStyle(.borderedProminent)
                .tint(TideStyle.accent)
            }
        }
        .padding(16)
        .frame(width: 372, height: 124, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(TideStyle.border, lineWidth: 0.75))
    }

    private var title: String {
        switch presentation {
        case let .release(release, _): return "发现 TideTicker \(release.version)"
        case let .message(title, _, _): return title
        }
    }

    private var detail: String {
        switch presentation {
        case let .release(_, currentVersion):
            return "当前版本 \(currentVersion)。新版本已发布，可前往 GitHub 查看发布说明和源码。"
        case let .message(_, detail, _): return detail
        }
    }

    private var symbol: String {
        switch presentation {
        case .release: return "arrow.down.circle"
        case let .message(_, _, symbol): return symbol
        }
    }

    private var primaryTitle: String {
        if case .release = presentation { return "查看发布页" }
        return "知道了"
    }

    private var primarySymbol: String {
        if case .release = presentation { return "arrow.up.right.square" }
        return "checkmark"
    }
}
