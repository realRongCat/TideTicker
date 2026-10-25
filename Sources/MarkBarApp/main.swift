import AppKit
import ServiceManagement

let arguments = ProcessInfo.processInfo.arguments
let registerLoginItem = arguments.contains("--register-login-item")
let unregisterLoginItem = arguments.contains("--unregister-login-item")

// Installation/migration commands exit before constructing the UI or its client.
if registerLoginItem || unregisterLoginItem {
    var operationError: String?
    if registerLoginItem && unregisterLoginItem {
        operationError = "Choose only one login-item operation."
    } else {
        do {
            if registerLoginItem {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    let status = SMAppService.mainApp.status
    let statusName: String
    switch status {
    case .notRegistered: statusName = "notRegistered"
    case .enabled: statusName = "enabled"
    case .requiresApproval: statusName = "requiresApproval"
    case .notFound: statusName = "notFound"
    @unknown default: statusName = "unknown"
    }
    let result: [String: Any] = [
        "app": "TideTicker",
        "operation": registerLoginItem && unregisterLoginItem ? "invalid" : (registerLoginItem ? "register" : "unregister"),
        "status": statusName,
        "statusCode": status.rawValue,
        "bundlePath": Bundle.main.bundleURL.path,
        "error": operationError as Any? ?? NSNull(),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    exit(operationError == nil ? EXIT_SUCCESS : EXIT_FAILURE)
}

let application = NSApplication.shared
let delegate = MarkBarAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
