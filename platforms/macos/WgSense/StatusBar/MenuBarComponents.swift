import AppKit
import CoreText
import Darwin

// 菜单栏组件：网速 / 日期徽章 / 时间。移植自 NetTimeBar（同作者，MIT），
// 与盾牌图标合并在同一个 NSStatusItem 里，由 WgStatusBarController 排版。

// MARK: - 设置

@MainActor
final class MenuBarComponentSettings {
    private enum Key {
        static let showSpeed = "menuBar.showSpeed"
        static let showDate = "menuBar.showDate"
        static let showTime = "menuBar.showTime"
        static let showUpload = "menuBar.showUpload"
        static let showDownload = "menuBar.showDownload"
        static let use24HourClock = "menuBar.use24HourClock"
        static let timeZoneIdentifier = "menuBar.timeZoneIdentifier"
        static let refreshInterval = "menuBar.refreshInterval"
        static let dateGlassEnabled = "menuBar.dateGlassEnabled"
        static let dateTintOpacity = "menuBar.dateTintOpacity"
        static let useBitsPerSecond = "menuBar.useBitsPerSecond"
        static let importedNetTimeBar = "menuBar.importedNetTimeBar"
    }

    static let refreshIntervals: [TimeInterval] = [0.1, 0.3, 0.5, 1.0, 2.0]
    static let tintOpacities: [Double] = [0.25, 0.4, 0.55, 0.7]

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Key.showSpeed: true,
            Key.showDate: true,
            Key.showTime: true,
            Key.showUpload: true,
            Key.showDownload: true,
            Key.use24HourClock: true,
            Key.timeZoneIdentifier: "system",
            Key.refreshInterval: 1.0,
            Key.dateGlassEnabled: true,
            Key.dateTintOpacity: 0.4,
            Key.useBitsPerSecond: false
        ])
        importNetTimeBarPreferencesOnce()
    }

    /// 首次启动时沿用独立版 NetTimeBar 已保存的偏好，只导入一次。
    private func importNetTimeBarPreferencesOnce() {
        guard !defaults.bool(forKey: Key.importedNetTimeBar) else { return }
        defaults.set(true, forKey: Key.importedNetTimeBar)
        guard let legacy = UserDefaults(suiteName: "com.local.NetTimeBar") else { return }
        let mapping: [(String, String)] = [
            ("showUpload", Key.showUpload),
            ("showDownload", Key.showDownload),
            ("use24HourClock", Key.use24HourClock),
            ("timeZoneIdentifier", Key.timeZoneIdentifier),
            ("refreshInterval", Key.refreshInterval),
            ("dateGlassEnabled", Key.dateGlassEnabled),
            ("dateTintOpacity", Key.dateTintOpacity),
            ("useBitsPerSecond", Key.useBitsPerSecond)
        ]
        for (old, new) in mapping {
            if let value = legacy.object(forKey: old) {
                defaults.set(value, forKey: new)
            }
        }
    }

    var showSpeed: Bool {
        get { defaults.bool(forKey: Key.showSpeed) }
        set { defaults.set(newValue, forKey: Key.showSpeed) }
    }

    var showDate: Bool {
        get { defaults.bool(forKey: Key.showDate) }
        set { defaults.set(newValue, forKey: Key.showDate) }
    }

    var showTime: Bool {
        get { defaults.bool(forKey: Key.showTime) }
        set { defaults.set(newValue, forKey: Key.showTime) }
    }

    var showUpload: Bool {
        get { defaults.bool(forKey: Key.showUpload) }
        set { defaults.set(newValue, forKey: Key.showUpload) }
    }

    var showDownload: Bool {
        get { defaults.bool(forKey: Key.showDownload) }
        set { defaults.set(newValue, forKey: Key.showDownload) }
    }

    var use24HourClock: Bool {
        get { defaults.bool(forKey: Key.use24HourClock) }
        set { defaults.set(newValue, forKey: Key.use24HourClock) }
    }

    var timeZoneIdentifier: String {
        get { defaults.string(forKey: Key.timeZoneIdentifier) ?? "system" }
        set { defaults.set(newValue, forKey: Key.timeZoneIdentifier) }
    }

    var selectedTimeZone: TimeZone {
        if timeZoneIdentifier == "system" {
            return .autoupdatingCurrent
        }
        return TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
    }

    var refreshInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: Key.refreshInterval)
            return Self.refreshIntervals.contains(value) ? value : 1.0
        }
        set { defaults.set(newValue, forKey: Key.refreshInterval) }
    }

    var dateGlassEnabled: Bool {
        get { defaults.bool(forKey: Key.dateGlassEnabled) }
        set { defaults.set(newValue, forKey: Key.dateGlassEnabled) }
    }

    var dateTintOpacity: Double {
        get {
            let value = defaults.double(forKey: Key.dateTintOpacity)
            return Self.tintOpacities.contains(value) ? value : 0.4
        }
        set { defaults.set(newValue, forKey: Key.dateTintOpacity) }
    }

    var useBitsPerSecond: Bool {
        get { defaults.bool(forKey: Key.useBitsPerSecond) }
        set { defaults.set(newValue, forKey: Key.useBitsPerSecond) }
    }
}

// MARK: - 网速采样

struct PhysicalNetworkSpeed {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double

    static let zero = PhysicalNetworkSpeed(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
}

/// 只累计物理出口（enN / pdp_ipN），不算 utun 等虚拟接口，
/// 隧道流量已经包含在物理网卡里，避免同一个包被算两次。
final class PhysicalNetworkMonitor {
    private struct InterfaceCounters {
        let receivedBytes: UInt64
        let sentBytes: UInt64
    }

    private struct Snapshot {
        let interfaces: [String: InterfaceCounters]
        let uptime: TimeInterval
    }

    private var previousSnapshot: Snapshot?

    func sample() -> PhysicalNetworkSpeed {
        let current = readSnapshot()
        defer { previousSnapshot = current }

        guard let previous = previousSnapshot else { return .zero }

        let elapsed = current.uptime - previous.uptime
        guard elapsed > 0 else { return .zero }

        var receivedDelta: UInt64 = 0
        var sentDelta: UInt64 = 0

        // 新插入的网卡先建立基线，不把它的累计计数当成瞬时速率。
        for (name, counters) in current.interfaces {
            guard let oldCounters = previous.interfaces[name] else { continue }
            if counters.receivedBytes >= oldCounters.receivedBytes {
                receivedDelta += counters.receivedBytes - oldCounters.receivedBytes
            }
            if counters.sentBytes >= oldCounters.sentBytes {
                sentDelta += counters.sentBytes - oldCounters.sentBytes
            }
        }

        return PhysicalNetworkSpeed(
            downloadBytesPerSecond: Double(receivedDelta) / elapsed,
            uploadBytesPerSecond: Double(sentDelta) / elapsed
        )
    }

    private func readSnapshot() -> Snapshot {
        let uptime = ProcessInfo.processInfo.systemUptime
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        var interfaces: [String: InterfaceCounters] = [:]

        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return Snapshot(interfaces: [:], uptime: uptime)
        }
        defer { freeifaddrs(firstAddress) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interfacePointer = cursor {
            let interface = interfacePointer.pointee
            defer { cursor = interface.ifa_next }

            let name = String(cString: interface.ifa_name)
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  Self.isPhysicalExternalInterface(name),
                  let rawData = interface.ifa_data else {
                continue
            }

            let data = rawData.assumingMemoryBound(to: if_data.self).pointee
            interfaces[name] = InterfaceCounters(
                receivedBytes: UInt64(data.ifi_ibytes),
                sentBytes: UInt64(data.ifi_obytes)
            )
        }

        return Snapshot(interfaces: interfaces, uptime: uptime)
    }

    private static func isPhysicalExternalInterface(_ name: String) -> Bool {
        if name.hasPrefix("en"), Int(name.dropFirst(2)) != nil {
            return true
        }
        if name.hasPrefix("pdp_ip"), Int(name.dropFirst(6)) != nil {
            return true
        }
        return false
    }
}

// MARK: - 格式化

enum MenuBarSpeedFormatter {
    /// 固定 4 列数字 + 单位（0.00m / 12.3m / 999m），菜单栏宽度不跳动。
    static func speed(_ bytesPerSecond: Double, useBitsPerSecond: Bool) -> String {
        let ratePerSecond = max(0, bytesPerSecond) * (useBitsPerSecond ? 8 : 1)
        var value = ratePerSecond / 1_000_000
        var unit = "m"

        if value >= 999.5 {
            value /= 1_000
            unit = "g"
        }

        let number: String
        if value < 9.995 {
            number = String(format: "%4.2f", value)
        } else if value < 99.95 {
            number = String(format: "%4.1f", value)
        } else {
            number = String(format: "%4.0f", min(value, 999))
        }
        return number + unit
    }
}

final class MenuBarTimeFormatter {
    private let formatter = DateFormatter()
    private var configuredTimeZoneIdentifier: String?
    private var configuredFor24HourClock: Bool?

    init() {
        formatter.locale = Locale.autoupdatingCurrent
    }

    func string(date: Date, timeZone: TimeZone, use24HourClock: Bool) -> String {
        if configuredTimeZoneIdentifier != timeZone.identifier
            || configuredFor24HourClock != use24HourClock {
            formatter.timeZone = timeZone
            formatter.dateFormat = use24HourClock ? "HH:mm" : "h:mm a"
            configuredTimeZoneIdentifier = timeZone.identifier
            configuredFor24HourClock = use24HourClock
        }
        return formatter.string(from: date)
    }
}

// MARK: - 绘制视图（全部不接收点击，交给状态栏按钮）

@MainActor
final class MenuBarShieldView: NSImageView {
    static let width: CGFloat = 22

    func update(symbolName: String) {
        guard image?.accessibilityDescription != symbolName else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName)?
            .withSymbolConfiguration(config)
        symbol?.isTemplate = true
        image = symbol
        contentTintColor = .labelColor
        imageScaling = .scaleNone
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class MenuBarNetworkSpeedView: NSView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
    private let horizontalPadding: CGFloat = 4
    private let rowCenterOffset: CGFloat = 4.5
    private var upload: String?
    private var download: String?

    var fixedWidth: CGFloat {
        let sample = "↑ 0.00m" as NSString
        return ceil(sample.size(withAttributes: textAttributes).width + horizontalPadding * 2)
    }

    func update(upload: String?, download: String?) {
        guard self.upload != upload || self.download != download else { return }
        self.upload = upload
        self.download = download
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let upload, let download {
            draw(upload, centeredAtY: bounds.midY + rowCenterOffset)
            draw(download, centeredAtY: bounds.midY - rowCenterOffset)
        } else if let singleLine = upload ?? download {
            draw(singleLine, centeredAtY: bounds.midY)
        }
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    private func draw(_ text: String, centeredAtY centerY: CGFloat) {
        let size = (text as NSString).size(withAttributes: textAttributes)
        let origin = NSPoint(x: horizontalPadding, y: centerY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: textAttributes)
    }
}

@MainActor
final class MenuBarTimeView: NSView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private let horizontalPadding: CGFloat = 4
    private var text = ""

    /// 按当前制式的最宽样本定宽，分钟变化时不挪位。
    func fixedWidth(use24HourClock: Bool) -> CGFloat {
        let sample = (use24HourClock ? "88:88" : "88:88 PM") as NSString
        return ceil(sample.size(withAttributes: textAttributes).width + horizontalPadding * 2)
    }

    func update(text: String) {
        guard self.text != text else { return }
        self.text = text
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let size = (text as NSString).size(withAttributes: textAttributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: textAttributes)
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }
}

@MainActor
final class MenuBarDateBadgeView: NSView {
    static let width: CGFloat = 26

    private let effectView = NSVisualEffectView()
    private let tintView = NSView()
    private let numberView = CenteredDateNumberView()
    private var day = 1
    private var weekday = 1
    private var glassEnabled = true
    private var tintOpacity = 0.4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        tintView.wantsLayer = true
        addSubview(effectView)
        effectView.addSubview(tintView)
        effectView.addSubview(numberView)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    func update(day: Int, weekday: Int) {
        guard self.day != day || self.weekday != weekday else { return }
        self.day = day
        self.weekday = weekday
        updateAppearance()
    }

    func updateStyle(glassEnabled: Bool, tintOpacity: Double) {
        guard self.glassEnabled != glassEnabled || self.tintOpacity != tintOpacity else { return }
        self.glassEnabled = glassEnabled
        self.tintOpacity = tintOpacity
        updateAppearance()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let diameter = floor(min(20, min(bounds.width - 2, bounds.height - 2)))
        let circleFrame = NSRect(
            x: floor(bounds.midX - diameter / 2),
            y: floor(bounds.midY - diameter / 2),
            width: diameter,
            height: diameter
        )
        effectView.frame = circleFrame
        effectView.layer?.cornerRadius = diameter / 2
        effectView.layer?.masksToBounds = true
        tintView.frame = effectView.bounds
        numberView.frame = effectView.bounds
    }

    private func updateAppearance() {
        let color = Self.thaiColor(for: weekday)
        effectView.material = glassEnabled ? .menu : .contentBackground
        effectView.blendingMode = glassEnabled ? .behindWindow : .withinWindow
        tintView.layer?.backgroundColor = color
            .withAlphaComponent(glassEnabled ? tintOpacity : 1)
            .cgColor
        numberView.update(text: "\(day)", color: Self.foregroundColor(for: color))
    }

    /// 泰国星期色：日红、一黄、二粉、三绿、四橙、五蓝、六紫。
    private static func thaiColor(for weekday: Int) -> NSColor {
        switch weekday {
        case 1: return NSColor(red: 0.91, green: 0.25, blue: 0.28, alpha: 1)
        case 2: return NSColor(red: 0.96, green: 0.82, blue: 0.25, alpha: 1)
        case 3: return NSColor(red: 0.94, green: 0.43, blue: 0.63, alpha: 1)
        case 4: return NSColor(red: 0.27, green: 0.67, blue: 0.35, alpha: 1)
        case 5: return NSColor(red: 0.96, green: 0.52, blue: 0.18, alpha: 1)
        case 6: return NSColor(red: 0.27, green: 0.65, blue: 0.91, alpha: 1)
        case 7: return NSColor(red: 0.55, green: 0.34, blue: 0.72, alpha: 1)
        default: return .systemGray
        }
    }

    private static func foregroundColor(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return .black }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.55 ? .black : .white
    }
}

@MainActor
private final class CenteredDateNumberView: NSView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private var text = ""
    private var color = NSColor.labelColor

    func update(text: String, color: NSColor) {
        guard self.text != text || self.color != color else { return }
        self.text = text
        self.color = color
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

        let attributedText = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        let line = CTLineCreateWithAttributedString(attributedText)
        // 按字形实际轮廓居中，而不是按行高，数字才在圆心。
        let glyphBounds = CTLineGetBoundsWithOptions(
            line,
            [.useGlyphPathBounds, .excludeTypographicLeading]
        )

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: bounds.midX - glyphBounds.midX,
            y: bounds.midY - glyphBounds.midY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
