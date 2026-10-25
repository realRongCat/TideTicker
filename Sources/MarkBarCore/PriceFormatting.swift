import Foundation

public enum PriceFormatting {
    /// Keep familiar two-decimal large prices, but retain meaningful digits for
    /// small tokens. Formatting never changes the Decimal used by alert rules.
    public static func compact(_ value: Decimal) -> String {
        guard !value.isNaN, value > 0 else { return "--" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        var digits = value >= 100 ? 2 : 4
        if value < 1 {
            var scaled = value
            var leading = 0
            while scaled < 1 && leading < 18 {
                scaled *= 10
                leading += 1
            }
            digits = min(18, leading + 4)
        }
        formatter.maximumFractionDigits = digits
        let result = formatter.string(from: NSDecimalNumber(decimal: value))
        if let result, result != "0.00" { return result }
        return exact(value)
    }

    public static func exact(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    public static func percent(_ value: Decimal, signed: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        let number = formatter.string(from: NSDecimalNumber(decimal: value)) ?? exact(value)
        return "\(signed && value > 0 ? "+" : "")\(number)%"
    }
}
