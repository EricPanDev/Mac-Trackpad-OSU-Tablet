import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

private let multitouchSupportPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
private let targetNames: Set<String> = ["osu", "osu!"]
private let minimumTrackpadRegionSize = 0.05
private let absolutePositionEnabled = true
private let absolutePositionClampToInputRegion = true
private let absolutePositionInvertX = false
private let absolutePositionInvertY = false
private let absoluteMouseEventUserData: Int64 = 0x6F7375
private let debugPrintVisibleWindows = false
private let selectorTrackpadAspectRatio: CGFloat = 1.6
private let knownOsuBundleIdentifiers = ["sh.ppy.osu.lazer"]
private let mainAppBundleIdentifier = "com.eric.TrackpadOSU"
private let helperAppBundleIdentifier = "com.eric.TrackpadOSUHelper"
private let displayAppName = "Mac Trackpad Tablet for OSU!"

private let supportDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/TrackpadOSU", isDirectory: true)

private let defaultTrackpadInputRegion = TrackpadRegion(
    left: 0.48794716282894735,
    right: 0.8538497121710527,
    bottom: 0.32635078721374045,
    top: 0.7405921994274809
)

private struct TrackpadRegion: Codable, Equatable {
    var left: Double
    var right: Double
    var bottom: Double
    var top: Double

    static let full = TrackpadRegion(left: 0.0, right: 1.0, bottom: 0.0, top: 1.0)

    var isValid: Bool {
        (0.0 ... 1.0).contains(left)
            && (0.0 ... 1.0).contains(right)
            && (0.0 ... 1.0).contains(bottom)
            && (0.0 ... 1.0).contains(top)
            && left < right
            && bottom < top
    }

    func ensuringMinimumSize() -> TrackpadRegion {
        var region = self
        let width = region.right - region.left
        if width < minimumTrackpadRegionSize {
            let center = (region.left + region.right) / 2.0
            region.left = clamp(center - minimumTrackpadRegionSize / 2.0, min: 0.0, max: 1.0 - minimumTrackpadRegionSize)
            region.right = region.left + minimumTrackpadRegionSize
        }

        let height = region.top - region.bottom
        if height < minimumTrackpadRegionSize {
            let center = (region.bottom + region.top) / 2.0
            region.bottom = clamp(center - minimumTrackpadRegionSize / 2.0, min: 0.0, max: 1.0 - minimumTrackpadRegionSize)
            region.top = region.bottom + minimumTrackpadRegionSize
        }

        return region
    }
}

private struct OutputRegion {
    var left: Double
    var right: Double
    var top: Double
    var bottom: Double

    static let full = OutputRegion(left: 0.0, right: 1.0, top: 0.0, bottom: 1.0)

    var isValid: Bool {
        (0.0 ... 1.0).contains(left)
            && (0.0 ... 1.0).contains(right)
            && (0.0 ... 1.0).contains(top)
            && (0.0 ... 1.0).contains(bottom)
            && left < right
            && top < bottom
    }
}

private struct TouchSnapshot {
    let id: String
    let device: String
    let firstSeenSequence: Int64
    let normalizedX: Double
    let normalizedY: Double
    let deviceX: Double
    let deviceY: Double
    let width: Double
    let height: Double
    let size: Double
    let region: String
}

private struct WindowBounds {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct OsuWindow {
    let owner: String
    let cgTitle: String
    let title: String
    let accessibilityTitle: String?
    let pid: Int
    let bounds: WindowBounds
}

private struct ConfigFile: Codable {
    let trackpadInputRegion: TrackpadRegion
}

private struct RuntimeOptions {
    enum Mode {
        case launcher
        case monitor
        case overlay
        case selector
        case requestPermissions
        case checkOsuRunning
        case helper
        case registerHelper
        case unregisterHelper
    }

    var mode: Mode
    var forceShowSelector: Bool
    var shouldPromptForPermissions: Bool
    var permissionStatusFilePath: String?
}

private struct PermissionSnapshot {
    let accessibilityTrusted: Bool
    let postEventAccess: Bool

    var allGranted: Bool {
        accessibilityTrusted && postEventAccess
    }

    var missingItems: [String] {
        var items: [String] = []
        if !accessibilityTrusted {
            items.append("Accessibility")
        }
        if !postEventAccess {
            items.append("Event posting")
        }
        return items
    }

    var summary: String {
        "accessibility=\(accessibilityTrusted) event_posting=\(postEventAccess)"
    }

    var missingDescription: String {
        missingItems.joined(separator: ", ")
    }
}

private func preferredTouch(from activeTouches: [String: TouchSnapshot]) -> TouchSnapshot? {
    activeTouches.values.min { lhs, rhs in
        if lhs.firstSeenSequence != rhs.firstSeenSequence {
            return lhs.firstSeenSequence < rhs.firstSeenSequence
        }
        return lhs.id < rhs.id
    }
}

private enum Permissions {
    static func current() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibilityTrusted: AXIsProcessTrusted(),
            postEventAccess: postEventAccessGranted()
        )
    }

    static func requestPrompts() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if #available(macOS 10.15, *) {
            if !CGPreflightPostEventAccess() {
                _ = CGRequestPostEventAccess()
            }
        }
    }

    static func postEventAccessGranted() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightPostEventAccess()
        }
        return true
    }
}

private protocol ExitCodeReporting: AnyObject {
    var exitCode: Int32 { get }
}

private final class ProcessInstanceLock {
    private let fileDescriptor: Int32
    let path: String

    private init(fileDescriptor: Int32, path: String) {
        self.fileDescriptor = fileDescriptor
        self.path = path
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func acquire(name: String) -> ProcessInstanceLock? {
        do {
            try FileManager.default.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("failed to create lock directory: \(error)")
            return nil
        }

        let path = supportDirectoryURL.appendingPathComponent("\(name).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            print("failed to open lock file \(path)")
            return nil
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return nil
        }

        return ProcessInstanceLock(fileDescriptor: descriptor, path: path)
    }
}

private var processInstanceLock: ProcessInstanceLock?

private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
    Swift.max(minimum, Swift.min(maximum, value))
}

private func classifyTouch(x: Double, y: Double, width: Double, height: Double) -> String {
    let horizontal: String
    if x < width * 0.33 {
        horizontal = "left"
    } else if x > width * 0.66 {
        horizontal = "right"
    } else {
        horizontal = "center"
    }

    let vertical: String
    if y > height * 0.66 {
        vertical = "top"
    } else if y < height * 0.33 {
        vertical = "bottom"
    } else {
        vertical = "middle"
    }

    return "\(vertical)-\(horizontal)"
}

private func normalize(_ string: String?) -> String {
    (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func isExactOsuText(_ string: String?) -> Bool {
    targetNames.contains(normalize(string))
}

private func runningAppLooksLikeOsu(_ app: NSRunningApplication?) -> Bool {
    guard let app else {
        return false
    }

    if isExactOsuText(app.localizedName) {
        return true
    }

    let bundle = normalize(app.bundleIdentifier)
    return bundle.hasSuffix(".osu") || targetNames.contains(bundle)
}

private func osuWindowTitleIndicatesGameplay(_ title: String?) -> Bool {
    let normalizedTitle = normalize(title)
    return !normalizedTitle.isEmpty && !targetNames.contains(normalizedTitle)
}

private final class ConfigStore {
    let url = supportDirectoryURL.appendingPathComponent("config.json")

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }

    private func loadRegion(from sourceURL: URL) throws -> TrackpadRegion {
        let data = try Data(contentsOf: sourceURL)
        let config = try makeDecoder().decode(ConfigFile.self, from: data)
        guard config.trackpadInputRegion.isValid else {
            throw NSError(
                domain: "TrackpadOSU.ConfigStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The file does not contain a valid trackpad region."]
            )
        }

        return config.trackpadInputRegion
    }

    private func encodedConfigData(for region: TrackpadRegion) throws -> Data {
        var data = try makeEncoder().encode(ConfigFile(trackpadInputRegion: region))
        if let newline = "\n".data(using: .utf8) {
            data.append(newline)
        }
        return data
    }

    private func write(region: TrackpadRegion, to destinationURL: URL) throws {
        let data = try encodedConfigData(for: region)
        try data.write(to: destinationURL, options: .atomic)
    }

    func load() -> TrackpadRegion? {
        guard exists else {
            return nil
        }

        do {
            let region = try loadRegion(from: url)
            print("loaded trackpad region from \(url.path): \(region)")
            return region
        } catch {
            print("failed to load config \(url.path): \(error)")
            return nil
        }
    }

    func importRegion(from sourceURL: URL) throws -> TrackpadRegion {
        let region = try loadRegion(from: sourceURL)
        print("imported trackpad region from \(sourceURL.path): \(region)")
        return region
    }

    func export(region: TrackpadRegion, to destinationURL: URL) throws {
        try write(region: region, to: destinationURL)
        print("exported trackpad region to \(destinationURL.path): \(region)")
    }

    func save(region: TrackpadRegion) {
        do {
            try FileManager.default.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
            try write(region: region, to: url)
            print("saved trackpad region to \(url.path): \(region)")
        } catch {
            print("failed to save config \(url.path): \(error)")
        }
    }
}

private func findOsuPIDs() -> Set<pid_t> {
    Set(NSWorkspace.shared.runningApplications.compactMap { app in
        runningAppLooksLikeOsu(app) ? app.processIdentifier : nil
    })
}

private func currentOsuApplication() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first(where: runningAppLooksLikeOsu)
}

private func locateOsuApplicationURL() -> URL? {
    if let runningURL = currentOsuApplication()?.bundleURL {
        return runningURL
    }

    for bundleIdentifier in knownOsuBundleIdentifiers {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
    }

    let fileManager = FileManager.default
    let candidatePaths = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/osu!.app").path,
        "/Applications/osu!.app",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/osu.app").path,
        "/Applications/osu.app",
    ]

    return candidatePaths.first(where: { fileManager.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
}

private func embeddedHelperBundleURL() -> URL {
    Bundle.main.bundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("LoginItems", isDirectory: true)
        .appendingPathComponent("TrackpadOSUHelper.app", isDirectory: true)
}

private func containingMainAppBundleURL(from bundleURL: URL) -> URL? {
    var current = bundleURL
    for _ in 0 ..< 4 {
        current.deleteLastPathComponent()
    }

    return current.pathExtension == "app" ? current : nil
}

private func setLoginItemEnabled(_ enabled: Bool) throws {
    if #available(macOS 13.0, *) {
        do {
            let service = SMAppService.loginItem(identifier: helperAppBundleIdentifier)
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return
        } catch {
            print("SMAppService login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    typealias SMLoginItemSetEnabledFn = @convention(c) (CFString, Bool) -> Bool
    guard let handle = dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_NOW) else {
        throw NSError(
            domain: "TrackpadOSU.LoginItem",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "The ServiceManagement framework could not be loaded."]
        )
    }
    defer { dlclose(handle) }

    guard let symbol = dlsym(handle, "SMLoginItemSetEnabled") else {
        throw NSError(
            domain: "TrackpadOSU.LoginItem",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "The legacy login item API is not available on this system."]
        )
    }

    let legacySetEnabled = unsafeBitCast(symbol, to: SMLoginItemSetEnabledFn.self)
    let success = legacySetEnabled(helperAppBundleIdentifier as CFString, enabled)
    if !success {
        throw NSError(
            domain: "TrackpadOSU.LoginItem",
            code: enabled ? 1 : 2,
            userInfo: [NSLocalizedDescriptionKey: "The login item helper could not be \(enabled ? "enabled" : "disabled")."]
        )
    }
}

private func accessibilityFocusedWindowTitle(for pid: pid_t) -> String? {
    guard AXIsProcessTrusted() else {
        return nil
    }

    let appElement = AXUIElementCreateApplication(pid)

    var focusedWindowValue: CFTypeRef?
    let focusedWindowResult = AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindowValue
    )
    guard focusedWindowResult == .success, let focusedWindowValue else {
        return nil
    }

    let focusedWindowElement = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
    var titleValue: CFTypeRef?
    let titleResult = AXUIElementCopyAttributeValue(
        focusedWindowElement,
        kAXTitleAttribute as CFString,
        &titleValue
    )
    guard titleResult == .success else {
        return nil
    }

    return titleValue as? String
}

private func resolvedOsuWindowTitle(cgTitle: String, accessibilityTitle: String?) -> String {
    if osuWindowTitleIndicatesGameplay(cgTitle) {
        return cgTitle
    }

    if osuWindowTitleIndicatesGameplay(accessibilityTitle) {
        return accessibilityTitle ?? cgTitle
    }

    if !normalize(cgTitle).isEmpty {
        return cgTitle
    }

    return accessibilityTitle ?? cgTitle
}

private func windowBounds(from info: [String: Any]) -> WindowBounds? {
    guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else {
        return nil
    }

    guard let rect = CGRect(dictionaryRepresentation: boundsDict) else {
        return nil
    }

    return WindowBounds(
        x: Double(rect.origin.x),
        y: Double(rect.origin.y),
        width: Double(rect.size.width),
        height: Double(rect.size.height)
    )
}

private struct CandidateScore: Comparable {
    let ownerExact: Int
    let pidMatch: Int
    let gameplayTitle: Int
    let titlePresent: Int
    let area: Double

    static func < (lhs: CandidateScore, rhs: CandidateScore) -> Bool {
        if lhs.ownerExact != rhs.ownerExact { return lhs.ownerExact < rhs.ownerExact }
        if lhs.pidMatch != rhs.pidMatch { return lhs.pidMatch < rhs.pidMatch }
        if lhs.gameplayTitle != rhs.gameplayTitle { return lhs.gameplayTitle < rhs.gameplayTitle }
        if lhs.titlePresent != rhs.titlePresent { return lhs.titlePresent < rhs.titlePresent }
        return lhs.area < rhs.area
    }
}

private func debugPrintWindows() {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return
    }

    print("----- visible windows -----")
    for info in windows.prefix(120) {
        let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
        let title = (info[kCGWindowName as String] as? String) ?? ""
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard let bounds = windowBounds(from: info) else {
            continue
        }

        if bounds.width > 0 && bounds.height > 0 {
            print(
                "pid=\(pid) layer=\(layer) alpha=\(String(format: "%.2f", alpha)) owner=\(owner.debugDescription) title=\(title.debugDescription) bounds=(\(bounds.x), \(bounds.y), \(bounds.width), \(bounds.height))"
            )
        }
    }
    print("---------------------------")
}

private func findOsuWindow() -> OsuWindow? {
    let osuPIDs = findOsuPIDs()
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    var bestWindow: OsuWindow?
    var bestScore: CandidateScore?
    var accessibilityTitleCache: [pid_t: String?] = [:]

    for info in windows {
        let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
        let title = (info[kCGWindowName as String] as? String) ?? ""
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard let bounds = windowBounds(from: info) else {
            continue
        }

        if layer != 0 || alpha <= 0 || bounds.width <= 50 || bounds.height <= 50 {
            continue
        }

        let ownerExact = isExactOsuText(owner)
        let titleExact = isExactOsuText(title)
        let pidMatch = osuPIDs.contains(pid_t(pid))

        if !(ownerExact || titleExact || pidMatch) {
            continue
        }

        let processID = pid_t(pid)
        let accessibilityTitle: String?
        if let cached = accessibilityTitleCache[processID] {
            accessibilityTitle = cached
        } else {
            let fetchedTitle = accessibilityFocusedWindowTitle(for: processID)
            accessibilityTitleCache[processID] = fetchedTitle
            accessibilityTitle = fetchedTitle
        }

        let resolvedTitle = resolvedOsuWindowTitle(cgTitle: title, accessibilityTitle: accessibilityTitle)

        let score = CandidateScore(
            ownerExact: ownerExact ? 1 : 0,
            pidMatch: pidMatch ? 1 : 0,
            gameplayTitle: osuWindowTitleIndicatesGameplay(resolvedTitle) ? 1 : 0,
            titlePresent: normalize(resolvedTitle).isEmpty ? 0 : 1,
            area: bounds.width * bounds.height
        )

        if bestScore == nil || score > bestScore! {
            bestScore = score
            bestWindow = OsuWindow(
                owner: owner,
                cgTitle: title,
                title: resolvedTitle,
                accessibilityTitle: accessibilityTitle,
                pid: pid,
                bounds: bounds
            )
        }
    }

    return bestWindow
}

private func collectOsuWindowCandidateDescriptions() -> [String] {
    let osuPIDs = findOsuPIDs()
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    var descriptions: [String] = []
    var accessibilityTitleCache: [pid_t: String?] = [:]

    for info in windows {
        let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
        let title = (info[kCGWindowName as String] as? String) ?? ""
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard let bounds = windowBounds(from: info) else {
            continue
        }

        if layer != 0 || alpha <= 0 || bounds.width <= 50 || bounds.height <= 50 {
            continue
        }

        let ownerExact = isExactOsuText(owner)
        let titleExact = isExactOsuText(title)
        let processID = pid_t(pid)
        let pidMatch = osuPIDs.contains(processID)

        if !(ownerExact || titleExact || pidMatch) {
            continue
        }

        let accessibilityTitle: String?
        if let cached = accessibilityTitleCache[processID] {
            accessibilityTitle = cached
        } else {
            let fetchedTitle = accessibilityFocusedWindowTitle(for: processID)
            accessibilityTitleCache[processID] = fetchedTitle
            accessibilityTitle = fetchedTitle
        }

        let resolvedTitle = resolvedOsuWindowTitle(cgTitle: title, accessibilityTitle: accessibilityTitle)
        let inMap = osuWindowTitleIndicatesGameplay(resolvedTitle)
        descriptions.append(
            "pid=\(pid) owner=\(owner.debugDescription) cgTitle=\(title.debugDescription) axTitle=\((accessibilityTitle ?? "").debugDescription) resolvedTitle=\(resolvedTitle.debugDescription) inMap=\(inMap) bounds=(\(bounds.x), \(bounds.y), \(bounds.width), \(bounds.height))"
        )
    }

    return descriptions
}

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTData {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var normalized: MTVector
    var size: Float
    var unknown3: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var unknown4: MTVector
    var unknown5_1: Int32
    var unknown5_2: Int32
    var unknown6: Float
}

private typealias MTContactCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterContactFrameCallbackFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

private final class GlobalTrackpadMonitor {
    private static weak var currentMonitor: GlobalTrackpadMonitor?
    private static let callback: MTContactCallback = { device, dataPtr, nFingers, _, _ in
        GlobalTrackpadMonitor.currentMonitor?.handleContactFrame(device: device, dataPtr: dataPtr, nFingers: Int(nFingers)) ?? 0
    }

    var onTouchesChanged: (() -> Void)?

    private let lock = NSLock()
    private var deviceTouches: [String: [String: TouchSnapshot]] = [:]
    private var activeTouches: [String: TouchSnapshot] = [:]
    private var nextTouchSequence: Int64 = 0
    private var devices: [UnsafeMutableRawPointer] = []
    private var deviceList: CFArray?
    private var libraryHandle: UnsafeMutableRawPointer?
    private var createList: MTDeviceCreateListFn?
    private var registerCallback: MTRegisterContactFrameCallbackFn?
    private var deviceStart: MTDeviceStartFn?
    private var isAvailable = false
    private var debugEnabled = false
    private var started = false

    init() {
        guard let handle = dlopen(multitouchSupportPath, RTLD_NOW) else {
            if let error = dlerror() {
                print("global trackpad monitor unavailable: \(String(cString: error))")
            } else {
                print("global trackpad monitor unavailable: failed to open MultitouchSupport")
            }
            return
        }

        libraryHandle = handle
        if let symbol = loadSymbol(named: "MTDeviceCreateList") {
            createList = unsafeBitCast(symbol, to: MTDeviceCreateListFn.self)
        }
        if let symbol = loadSymbol(named: "MTRegisterContactFrameCallback") {
            registerCallback = unsafeBitCast(symbol, to: MTRegisterContactFrameCallbackFn.self)
        }
        if let symbol = loadSymbol(named: "MTDeviceStart") {
            deviceStart = unsafeBitCast(symbol, to: MTDeviceStartFn.self)
        }
        isAvailable = createList != nil && registerCallback != nil && deviceStart != nil
    }

    deinit {
        if let libraryHandle {
            dlclose(libraryHandle)
        }
    }

    private func loadSymbol(named name: String) -> UnsafeMutableRawPointer? {
        guard let libraryHandle, let symbol = dlsym(libraryHandle, name) else {
            print("global trackpad monitor unavailable: missing symbol \(name)")
            return nil
        }

        return symbol
    }

    func start() {
        guard isAvailable, !started, let createList, let registerCallback, let deviceStart else {
            return
        }

        guard let devicesArray = createList()?.takeRetainedValue() else {
            print("global trackpad monitor unavailable: no multitouch device list")
            return
        }

        deviceList = devicesArray
        let count = CFArrayGetCount(devicesArray)
        guard count > 0 else {
            print("global trackpad monitor unavailable: no multitouch devices found")
            return
        }

        GlobalTrackpadMonitor.currentMonitor = self

        for index in 0 ..< count {
            guard let rawDevice = CFArrayGetValueAtIndex(devicesArray, index) else {
                continue
            }

            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            let deviceKey = String(UInt(bitPattern: device))
            devices.append(device)
            deviceTouches[deviceKey] = [:]
            registerCallback(device, Self.callback)
            deviceStart(device, 0)
        }

        if !devices.isEmpty {
            started = true
            print("global trackpad monitor started for \(devices.count) device(s)")
        }
    }

    func getActiveTouches() -> [String: TouchSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return activeTouches
    }

    func setDebugEnabled(_ enabled: Bool) {
        debugEnabled = enabled
    }

    private func allocateTouchSequence() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        nextTouchSequence += 1
        return nextTouchSequence
    }

    private func makeTouchData(deviceKey: String, touchKey: String, firstSeenSequence: Int64, data: MTData) -> TouchSnapshot {
        let normalizedX = clamp(Double(data.normalized.position.x), min: 0.0, max: 1.0)
        let normalizedY = clamp(Double(data.normalized.position.y), min: 0.0, max: 1.0)

        return TouchSnapshot(
            id: touchKey,
            device: deviceKey,
            firstSeenSequence: firstSeenSequence,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            deviceX: normalizedX,
            deviceY: normalizedY,
            width: 1.0,
            height: 1.0,
            size: Double(data.size),
            region: classifyTouch(x: normalizedX, y: normalizedY, width: 1.0, height: 1.0)
        )
    }

    private func touchChanged(old: TouchSnapshot, new: TouchSnapshot) -> Bool {
        abs(old.normalizedX - new.normalizedX) > 0.0001
            || abs(old.normalizedY - new.normalizedY) > 0.0001
            || abs(old.size - new.size) > 0.0001
    }

    private func printTouchBatch(label: String, touches: [TouchSnapshot]) {
        guard !touches.isEmpty else {
            return
        }

        for touch in touches {
            print(
                "\(label): id=\(touch.id) sequence=\(touch.firstSeenSequence) normalized=(\(String(format: "%.4f", touch.normalizedX)), \(String(format: "%.4f", touch.normalizedY))) trackpad=(\(String(format: "%.4f", touch.deviceX)), \(String(format: "%.4f", touch.deviceY))) size=\(String(format: "%.4f", touch.size)) region=\(touch.region)"
            )
        }
    }

    private func handleContactFrame(device: UnsafeMutableRawPointer?, dataPtr: UnsafeMutableRawPointer?, nFingers: Int) -> Int32 {
        guard let device else {
            return 0
        }

        let deviceKey = String(UInt(bitPattern: device))
        lock.lock()
        let previousTouches = deviceTouches[deviceKey] ?? [:]
        lock.unlock()
        let touchCount = max(0, nFingers)
        let buffer: UnsafeBufferPointer<MTData>
        if touchCount > 0, let dataPtr {
            let typedData = dataPtr.assumingMemoryBound(to: MTData.self)
            buffer = UnsafeBufferPointer(start: typedData, count: touchCount)
        } else {
            buffer = UnsafeBufferPointer(start: nil, count: 0)
        }

        var newTouches: [String: TouchSnapshot] = [:]
        var began: [TouchSnapshot] = []
        var moved: [TouchSnapshot] = []
        var activeIDs = Set<String>()

        for data in buffer {
            let touchKey = "\(deviceKey):\(data.identifier)"
            let firstSeenSequence = previousTouches[touchKey]?.firstSeenSequence ?? allocateTouchSequence()
            let touch = makeTouchData(
                deviceKey: deviceKey,
                touchKey: touchKey,
                firstSeenSequence: firstSeenSequence,
                data: data
            )
            activeIDs.insert(touch.id)
            newTouches[touch.id] = touch

            if let previous = previousTouches[touch.id] {
                if touchChanged(old: previous, new: touch) {
                    moved.append(touch)
                }
            } else {
                began.append(touch)
            }
        }

        let ended = previousTouches.values.filter { !activeIDs.contains($0.id) }

        lock.lock()
        deviceTouches[deviceKey] = newTouches
        activeTouches = deviceTouches.values.reduce(into: [:]) { partialResult, touchesForDevice in
            for (key, value) in touchesForDevice {
                partialResult[key] = value
            }
        }
        lock.unlock()

        if debugEnabled {
            printTouchBatch(label: "began", touches: began)
            printTouchBatch(label: "moved", touches: moved)
            printTouchBatch(label: "ended", touches: ended)
        }

        if !began.isEmpty || !moved.isEmpty || !ended.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onTouchesChanged?()
            }
        }

        return 0
    }
}

private final class RegionSelectorView: NSView {
    override var acceptsFirstResponder: Bool { true }

    var touchMonitor: GlobalTrackpadMonitor? {
        didSet { needsDisplay = true }
    }

    var onRegionChanged: ((TrackpadRegion) -> Void)?

    private(set) var region = TrackpadRegion.full {
        didSet { needsDisplay = true }
    }

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    func setRegion(_ region: TrackpadRegion) {
        self.region = region
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private func padRect() -> NSRect {
        let marginX: CGFloat = 16.0
        let marginY: CGFloat = 16.0
        let availableRect = bounds.insetBy(dx: marginX, dy: marginY)
        guard availableRect.width > 0.0, availableRect.height > 0.0 else {
            return .zero
        }

        var width = availableRect.width
        var height = width / selectorTrackpadAspectRatio
        if height > availableRect.height {
            height = availableRect.height
            width = height * selectorTrackpadAspectRatio
        }

        return NSRect(
            x: availableRect.midX - width / 2.0,
            y: availableRect.midY - height / 2.0,
            width: width,
            height: height
        )
    }

    private func pointToNormalized(_ point: CGPoint, clampToBounds: Bool) -> CGPoint? {
        let pad = padRect()
        var x = (point.x - pad.origin.x) / pad.size.width
        var y = (point.y - pad.origin.y) / pad.size.height

        if clampToBounds {
            x = clamp(x, min: 0.0, max: 1.0)
            y = clamp(y, min: 0.0, max: 1.0)
        } else if !(0.0 ... 1.0).contains(x) || !(0.0 ... 1.0).contains(y) {
            return nil
        }

        return CGPoint(x: x, y: y)
    }

    private func normalizedToViewPoint(x: Double, y: Double) -> CGPoint {
        let pad = padRect()
        return CGPoint(
            x: pad.origin.x + CGFloat(x) * pad.size.width,
            y: pad.origin.y + CGFloat(y) * pad.size.height
        )
    }

    private func selectionRect() -> NSRect {
        let pad = padRect()
        return NSRect(
            x: pad.origin.x + CGFloat(region.left) * pad.size.width,
            y: pad.origin.y + CGFloat(region.bottom) * pad.size.height,
            width: CGFloat(region.right - region.left) * pad.size.width,
            height: CGFloat(region.top - region.bottom) * pad.size.height
        )
    }

    private func currentPrimaryTouch() -> TouchSnapshot? {
        guard let touchMonitor else {
            return nil
        }

        let activeTouches = touchMonitor.getActiveTouches()
        return preferredTouch(from: activeTouches)
    }

    private func commit(region newRegion: TrackpadRegion) {
        let adjusted = newRegion.ensuringMinimumSize()
        guard adjusted.isValid else {
            return
        }

        region = adjusted
        onRegionChanged?(adjusted)
    }

    private func updateDragRegion(commit: Bool) {
        guard let dragStart, let dragCurrent else {
            return
        }

        let nextRegion = TrackpadRegion(
            left: min(dragStart.x, dragCurrent.x),
            right: max(dragStart.x, dragCurrent.x),
            bottom: min(dragStart.y, dragCurrent.y),
            top: max(dragStart.y, dragCurrent.y)
        ).ensuringMinimumSize()

        if commit {
            self.commit(region: nextRegion)
        } else {
            region = nextRegion
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1.0).set()
        bounds.fill()

        let pad = padRect()
        let padBackground = NSBezierPath(roundedRect: pad, xRadius: 22.0, yRadius: 22.0)
        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.24, alpha: 1.0),
                NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.17, alpha: 1.0),
            ]
        )
        gradient?.draw(in: padBackground, angle: 90.0)

        let padBorder = NSBezierPath(roundedRect: pad, xRadius: 22.0, yRadius: 22.0)
        NSColor(calibratedWhite: 1.0, alpha: 0.08).set()
        padBorder.lineWidth = 2.0
        padBorder.stroke()

        NSColor(calibratedWhite: 1.0, alpha: 0.06).set()
        let gridPath = NSBezierPath()
        for step in 1 ..< 4 {
            let x = pad.minX + pad.width * CGFloat(step) / 4.0
            gridPath.move(to: NSPoint(x: x, y: pad.minY))
            gridPath.line(to: NSPoint(x: x, y: pad.maxY))
        }
        for step in 1 ..< 3 {
            let y = pad.minY + pad.height * CGFloat(step) / 3.0
            gridPath.move(to: NSPoint(x: pad.minX, y: y))
            gridPath.line(to: NSPoint(x: pad.maxX, y: y))
        }
        gridPath.lineWidth = 1.0
        gridPath.stroke()

        let selection = NSBezierPath(roundedRect: selectionRect(), xRadius: 12.0, yRadius: 12.0)
        NSColor(calibratedRed: 0.18, green: 0.78, blue: 0.38, alpha: 0.22).set()
        selection.fill()

        NSColor(calibratedRed: 0.18, green: 0.92, blue: 0.45, alpha: 0.95).set()
        selection.lineWidth = 3.0
        selection.stroke()

        if let touch = currentPrimaryTouch() {
            let point = normalizedToViewPoint(x: touch.normalizedX, y: touch.normalizedY)
            let indicatorRect = NSRect(x: point.x - 7.0, y: point.y - 7.0, width: 14.0, height: 14.0)
            let indicator = NSBezierPath(ovalIn: indicatorRect)
            NSColor(calibratedRed: 1.0, green: 0.33, blue: 0.24, alpha: 0.95).set()
            indicator.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let normalized = pointToNormalized(point, clampToBounds: false) else {
            return
        }

        if event.clickCount >= 2 {
            commit(region: .full)
            return
        }

        dragStart = normalized
        dragCurrent = normalized
        updateDragRegion(commit: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let normalized = pointToNormalized(point, clampToBounds: true) else {
            return
        }

        dragCurrent = normalized
        updateDragRegion(commit: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if let normalized = pointToNormalized(point, clampToBounds: true) {
            dragCurrent = normalized
        }

        updateDragRegion(commit: true)
        dragStart = nil
        dragCurrent = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            commit(region: .full)
            return
        }

        super.keyDown(with: event)
    }
}

private final class OverlayAppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let configStore = ConfigStore()
    private let selectorOnly: Bool
    private let forceShowSelector: Bool
    private let launchesOsuSession: Bool
    private let touchMonitor = GlobalTrackpadMonitor()
    private let outputRegion = OutputRegion.full

    private var trackpadInputRegion = defaultTrackpadInputRegion
    private var pendingTrackpadInputRegion = defaultTrackpadInputRegion

    private var regionSelectorWindow: NSWindow?
    private var regionSelectorView: RegionSelectorView?
    private weak var selectorStatusLabel: NSTextField?
    private weak var selectorSaveButton: NSButton?

    private var updateTimer: Timer?
    private var observerTokens: [NSObjectProtocol] = []

    private var performanceActivity: NSObjectProtocol?
    private var mouseMoveTap: CFMachPort?
    private var mouseMoveTapSource: CFRunLoopSource?

    private var lastSignature: String?
    private var lastInMap: Bool?
    private var lastOsuBounds: WindowBounds?
    private var lastOsuProcessID: pid_t?
    private var lastAbsolutePoint: CGPoint?
    private var primaryTouchID: String?
    private var pointerLocked = false
    private var osuActive = false
    private var overlayMode = false
    private var printedDebug = false
    private var hasLoggedOsuExit = false
    private var lastWindowDiagnostics: String?
    private var accessibilityTrusted = false
    private var postEventAccessGranted = false
    private var didLogMissingAccessibilityPermission = false
    private var didLogMissingPostPermission = false
    private var didLogAbsoluteInjectionMode = false
    private var hasSeenOsuProcess = false
    private var didAttemptOsuLaunch = false
    private var hasLoggedWaitingForOsuLaunch = false
    private let usesModernAbsolutePointerInjection = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    private let absolutePointerEventSource = OverlayAppController.makeAbsolutePointerEventSource()

    init(selectorOnly: Bool, forceShowSelector: Bool, launchesOsuSession: Bool = false) {
        self.selectorOnly = selectorOnly
        self.forceShowSelector = forceShowSelector
        self.launchesOsuSession = launchesOsuSession
        super.init()
    }

    private static func makeAbsolutePointerEventSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return nil
        }

        let allowNonMouseEvents = CGEventFilterMask(rawValue: 0x00000002 | 0x00000004)
        source.setLocalEventsFilterDuringSuppressionState(
            allowNonMouseEvents,
            state: CGEventSuppressionState(rawValue: 0)!
        )
        source.setLocalEventsFilterDuringSuppressionState(
            allowNonMouseEvents,
            state: CGEventSuppressionState(rawValue: 1)!
        )
        source.localEventsSuppressionInterval = 0.25
        return source
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        trackpadInputRegion = configStore.load() ?? defaultTrackpadInputRegion
        pendingTrackpadInputRegion = trackpadInputRegion
        let permissionSnapshot = Permissions.current()
        accessibilityTrusted = permissionSnapshot.accessibilityTrusted
        postEventAccessGranted = permissionSnapshot.postEventAccess

        touchMonitor.onTouchesChanged = { [weak self] in
            self?.handleTrackpadActivity()
        }
        touchMonitor.start()
        createRegionSelectorWindow()

        if !selectorOnly {
            installWorkspaceObservers()
            startTimers()
        } else {
            updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.regionSelectorView?.needsDisplay = true
            }
        }

        print(
            "absolute positioning config: trackpad_region=\(trackpadInputRegion) output_region=\(outputRegion) invert_x=\(absolutePositionInvertX) invert_y=\(absolutePositionInvertY)"
        )

        if !trackpadInputRegion.isValid {
            print("absolute positioning disabled: invalid trackpad input region")
        }
        if !outputRegion.isValid {
            print("absolute positioning disabled: invalid output region")
        }

        let shouldShowSelector = selectorOnly || forceShowSelector || !configStore.exists
        if shouldShowSelector {
            showRegionSelectorWindow()
        }

        if selectorOnly {
            return
        }

        if currentOsuApp() != nil {
            hasSeenOsuProcess = true
        }

        if runningAppLooksLikeOsu(NSWorkspace.shared.frontmostApplication) {
            activateOverlayMode()
        } else if launchesOsuSession {
            launchOrActivateOsuApplication()
        } else {
            print("watching for osu activation...")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        selectorOnly
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        updateTimer = nil

        unlockPointer()
        endPerformanceActivity()

        if let mouseMoveTapSource {
            CFRunLoopSourceInvalidate(mouseMoveTapSource)
            self.mouseMoveTapSource = nil
        }

        if let mouseMoveTap {
            CFMachPortInvalidate(mouseMoveTap)
            self.mouseMoveTap = nil
        }

        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        if selectorOnly, let window = notification.object as? NSWindow, window === regionSelectorWindow {
            NSApp.terminate(nil)
        }
    }

    private func startTimers() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateOverlay()
        }
        updateTimer?.tolerance = 0.0
    }

    private func logOsuWindowDiagnostics(reason: String) {
        let candidates = collectOsuWindowCandidateDescriptions()
        let summary = ([reason] + candidates).joined(separator: "\n")
        guard summary != lastWindowDiagnostics else {
            return
        }

        print("osu diagnostics: \(reason)")
        if candidates.isEmpty {
            print("  no visible osu-related windows matched the current heuristics")
        } else {
            for candidate in candidates {
                print("  candidate \(candidate)")
            }
        }

        lastWindowDiagnostics = summary
    }

    private func handleTrackpadActivity() {
        regionSelectorView?.needsDisplay = true
        updateAbsolutePointerFromCurrentTouch()
    }

    private func currentOsuApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: runningAppLooksLikeOsu)
    }

    private func createRegionSelectorWindow() {
        guard regionSelectorWindow == nil else {
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 680, height: 580)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = displayAppName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)
        window.minSize = NSSize(width: 620.0, height: 520.0)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let rootView = NSView(frame: frame)
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1.0).cgColor

        let titleLabel = makeSelectorLabel(
            displayAppName,
            font: NSFont.systemFont(ofSize: 28.0, weight: .semibold),
            color: NSColor(calibratedWhite: 0.98, alpha: 1.0)
        )
        let subtitleLabel = makeSelectorLabel(
            "Choose which part of your trackpad maps to osu!.",
            font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
            color: NSColor(calibratedWhite: 0.76, alpha: 1.0)
        )
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping

        let view = RegionSelectorView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.touchMonitor = touchMonitor
        view.setRegion(pendingTrackpadInputRegion)
        view.onRegionChanged = { [weak self] region in
            self?.handlePendingRegionChanged(region)
        }

        let statusLabel = makeSelectorLabel(
            "",
            font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            color: NSColor(calibratedWhite: 0.72, alpha: 1.0),
            alignment: .center
        )

        let resetButton = makeSelectorButton(title: "Reset", action: #selector(resetRegionSelection))
        let importButton = makeSelectorButton(title: "Import...", action: #selector(importRegionSelection))
        let exportButton = makeSelectorButton(title: "Export...", action: #selector(exportRegionSelection))
        let saveButton = makeSelectorButton(title: "Save", action: #selector(saveRegionSelection))
        saveButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [resetButton, importButton, exportButton, saveButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .gravityAreas
        buttonRow.spacing = 12.0

        let footerLabel = makeSelectorLabel(
            "Developed by EricPanDev",
            font: NSFont.systemFont(ofSize: 12.0, weight: .regular),
            color: NSColor(calibratedWhite: 0.48, alpha: 1.0),
            alignment: .center
        )

        rootView.addSubview(titleLabel)
        rootView.addSubview(subtitleLabel)
        rootView.addSubview(view)
        rootView.addSubview(statusLabel)
        rootView.addSubview(buttonRow)
        rootView.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24.0),
            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 28.0),
            titleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -28.0),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8.0),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            view.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18.0),
            view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24.0),
            view.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24.0),
            view.heightAnchor.constraint(equalToConstant: 350.0),

            statusLabel.topAnchor.constraint(equalTo: view.bottomAnchor, constant: 16.0),
            statusLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24.0),
            statusLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24.0),

            buttonRow.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12.0),
            buttonRow.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),

            footerLabel.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 18.0),
            footerLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20.0),
        ])

        window.contentView = rootView
        regionSelectorWindow = window
        regionSelectorView = view
        selectorStatusLabel = statusLabel
        selectorSaveButton = saveButton
        updateSelectorControls()
    }

    private func showRegionSelectorWindow() {
        createRegionSelectorWindow()
        NSApp.activate(ignoringOtherApps: true)
        regionSelectorView?.needsDisplay = true
        regionSelectorWindow?.makeKeyAndOrderFront(nil)
    }

    private func handlePendingRegionChanged(_ region: TrackpadRegion) {
        pendingTrackpadInputRegion = region
        updateSelectorControls()
    }

    private func makeSelectorLabel(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        return label
    }

    private func makeSelectorButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }

    private func updateSelectorControls(statusMessage: String? = nil) {
        let hasUnsavedChanges = pendingTrackpadInputRegion != trackpadInputRegion
        let message = statusMessage ?? (
            hasUnsavedChanges
                ? "Unsaved changes. Save to apply this region."
                : "Drag to preview the active trackpad area, then save when it feels right."
        )

        selectorStatusLabel?.stringValue = message
        selectorStatusLabel?.textColor = hasUnsavedChanges
            ? NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.39, alpha: 1.0)
            : NSColor(calibratedWhite: 0.72, alpha: 1.0)
        selectorSaveButton?.isEnabled = hasUnsavedChanges
    }

    private func presentSelectorAlert(title: String, message: String) {
        guard let window = regionSelectorWindow else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    @objc private func resetRegionSelection() {
        pendingTrackpadInputRegion = .full
        regionSelectorView?.setRegion(.full)
        updateSelectorControls(statusMessage: "Reset to the full trackpad. Save to apply it.")
    }

    @objc private func importRegionSelection() {
        guard let window = regionSelectorWindow else {
            return
        }

        let panel = NSOpenPanel()
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else {
                return
            }

            do {
                let region = try self.configStore.importRegion(from: url)
                self.pendingTrackpadInputRegion = region
                self.regionSelectorView?.setRegion(region)
                self.updateSelectorControls(statusMessage: "Imported \(url.lastPathComponent). Save to apply it.")
            } catch {
                self.presentSelectorAlert(title: "Couldn't Import Region", message: error.localizedDescription)
            }
        }
    }

    @objc private func exportRegionSelection() {
        guard let window = regionSelectorWindow else {
            return
        }

        let panel = NSSavePanel()
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "MacTrackpadTabletForOSU-region.json"
        panel.prompt = "Export"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else {
                return
            }

            do {
                try self.configStore.export(region: self.pendingTrackpadInputRegion, to: url)
                self.updateSelectorControls(statusMessage: "Exported \(url.lastPathComponent).")
            } catch {
                self.presentSelectorAlert(title: "Couldn't Export Region", message: error.localizedDescription)
            }
        }
    }

    @objc private func saveRegionSelection() {
        trackpadInputRegion = pendingTrackpadInputRegion
        configStore.save(region: trackpadInputRegion)
        updateSelectorControls(statusMessage: "Saved current trackpad region.")
    }

    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.workspaceDidActivateApplication(notification)
            }
        )

        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.workspaceDidDeactivateApplication(notification)
            }
        )

        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.workspaceDidTerminateApplication(notification)
            }
        )
    }

    private func workspaceApplication(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func workspaceDidActivateApplication(_ notification: Notification) {
        guard let app = workspaceApplication(from: notification) else {
            return
        }

        let name = app.localizedName ?? ""
        let bundle = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier
        print("activated app pid=\(pid) name=\(name.debugDescription) bundle=\(bundle.debugDescription)")

        if runningAppLooksLikeOsu(app) {
            hasSeenOsuProcess = true
            hasLoggedWaitingForOsuLaunch = false
            activateOverlayMode()
            return
        }

        if app.processIdentifier == NSRunningApplication.current.processIdentifier {
            return
        }

        if osuActive {
            deactivateOverlayMode(reason: "switched to \(name.isEmpty ? bundle : name)")
        }
    }

    private func workspaceDidDeactivateApplication(_ notification: Notification) {
        guard let app = workspaceApplication(from: notification) else {
            return
        }

        let name = app.localizedName ?? ""
        let bundle = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier
        print("deactivated app pid=\(pid) name=\(name.debugDescription) bundle=\(bundle.debugDescription)")
    }

    private func workspaceDidTerminateApplication(_ notification: Notification) {
        guard let app = workspaceApplication(from: notification), runningAppLooksLikeOsu(app) else {
            return
        }

        print("osu exited -> quitting TrackpadOSU")
        NSApp.terminate(nil)
    }

    private func launchOrActivateOsuApplication() {
        if let runningOsu = currentOsuApp() {
            hasSeenOsuProcess = true
            print("osu is already running -> activating existing session")
            runningOsu.activate(options: [.activateAllWindows])
            return
        }

        guard !didAttemptOsuLaunch else {
            return
        }
        didAttemptOsuLaunch = true

        guard let appURL = locateOsuApplicationURL() else {
            print("failed to locate the osu! app bundle")
            NSApp.terminate(nil)
            return
        }

        print("launching osu! from \(appURL.path)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if let error {
                    print("failed to launch osu!: \(error)")
                    NSApp.terminate(nil)
                    return
                }

                if let app {
                    print("launch request submitted for osu! pid=\(app.processIdentifier)")
                } else {
                    print("launch request submitted for osu!")
                }
            }
        }
    }

    private func beginPerformanceActivity() {
        guard performanceActivity == nil else {
            return
        }

        performanceActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Low-latency osu absolute positioning"
        )
        print("requested macOS low-latency activity")
    }

    private func endPerformanceActivity() {
        guard let performanceActivity else {
            return
        }

        ProcessInfo.processInfo.endActivity(performanceActivity)
        self.performanceActivity = nil
        print("ended macOS low-latency activity")
    }

    private func eventMask(for eventTypes: [CGEventType]) -> CGEventMask {
        eventTypes.reduce(0) { partialResult, eventType in
            partialResult | (CGEventMask(1) << eventType.rawValue)
        }
    }

    private func installMouseSuppressionTap() {
        guard mouseMoveTap == nil else {
            return
        }

        let mask = eventMask(for: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged])
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let controller = Unmanaged<OverlayAppController>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handleMouseSuppressionTap(proxy: proxy, type: type, event: event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            print("mouse suppression tap unavailable")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        mouseMoveTap = tap
        mouseMoveTapSource = source
        print("mouse suppression tap installed")
    }

    private func handleMouseSuppressionTap(proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let mouseMoveTap, pointerLocked {
                CGEvent.tapEnable(tap: mouseMoveTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventUserData = event.getIntegerValueField(.eventSourceUserData)
        if eventUserData == absoluteMouseEventUserData {
            return Unmanaged.passUnretained(event)
        }

        if pointerLocked {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func lockPointer() {
        guard !pointerLocked else {
            return
        }

        installMouseSuppressionTap()
        guard let mouseMoveTap else {
            print("pointer lock unavailable: mouse suppression tap could not be created")
            return
        }

        CGEvent.tapEnable(tap: mouseMoveTap, enable: true)
        pointerLocked = true
        print("pointer movement suppressed")
    }

    private func unlockPointer() {
        guard pointerLocked else {
            return
        }

        if let mouseMoveTap {
            CGEvent.tapEnable(tap: mouseMoveTap, enable: false)
        }

        pointerLocked = false
        print("pointer movement restored")
    }

    private func getPrimaryTouch() -> TouchSnapshot? {
        let activeTouches = touchMonitor.getActiveTouches()
        guard !activeTouches.isEmpty else {
            primaryTouchID = nil
            return nil
        }

        if let primaryTouchID, let touch = activeTouches[primaryTouchID] {
            return touch
        }

        guard let touch = preferredTouch(from: activeTouches) else {
            return nil
        }

        primaryTouchID = touch.id
        return touch
    }

    private func mapTouchToAbsolutePoint(_ touch: TouchSnapshot, bounds: WindowBounds) -> CGPoint? {
        guard absolutePositionEnabled, trackpadInputRegion.isValid, outputRegion.isValid else {
            return nil
        }

        let inputWidth = trackpadInputRegion.right - trackpadInputRegion.left
        let inputHeight = trackpadInputRegion.top - trackpadInputRegion.bottom
        guard inputWidth > 0, inputHeight > 0 else {
            return nil
        }

        var localX = (touch.normalizedX - trackpadInputRegion.left) / inputWidth
        var localY = (touch.normalizedY - trackpadInputRegion.bottom) / inputHeight

        if absolutePositionClampToInputRegion {
            localX = clamp(localX, min: 0.0, max: 1.0)
            localY = clamp(localY, min: 0.0, max: 1.0)
        } else if !(0.0 ... 1.0).contains(localX) || !(0.0 ... 1.0).contains(localY) {
            return nil
        }

        if absolutePositionInvertX {
            localX = 1.0 - localX
        }

        let screenLocalY = absolutePositionInvertY ? localY : (1.0 - localY)
        let outputX = outputRegion.left + localX * (outputRegion.right - outputRegion.left)
        let outputY = outputRegion.top + screenLocalY * (outputRegion.bottom - outputRegion.top)

        return CGPoint(
            x: bounds.x + outputX * bounds.width,
            y: bounds.y + outputY * bounds.height
        )
    }

    private func makeAbsoluteMoveEvent(at point: CGPoint) -> CGEvent? {
        guard let moveEvent = CGEvent(
            mouseEventSource: usesModernAbsolutePointerInjection ? absolutePointerEventSource : nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return nil
        }

        moveEvent.setIntegerValueField(.eventSourceUserData, value: absoluteMouseEventUserData)
        return moveEvent
    }

    private func moveCursorDirectlyForModernMacOS(to point: CGPoint) -> CGError {
        return CGWarpMouseCursorPosition(point)
    }

    private func injectAbsolutePointer(to point: CGPoint) {
        if usesModernAbsolutePointerInjection {
            let moveResult = moveCursorDirectlyForModernMacOS(to: point)

            if !didLogAbsoluteInjectionMode {
                print("absolute pointer injection active: mode=warp_cursor move_result=\(moveResult.rawValue)")
                didLogAbsoluteInjectionMode = true
            }
            return
        }

        if let moveEvent = makeAbsoluteMoveEvent(at: point) {
            moveEvent.post(tap: .cgSessionEventTap)
        }

        if !didLogAbsoluteInjectionMode {
            print("absolute pointer injection active: mode=session_event_post")
            didLogAbsoluteInjectionMode = true
        }
    }

    private func updateAbsolutePointerFromCurrentTouch() {
        guard overlayMode, let lastOsuBounds else {
            primaryTouchID = nil
            lastAbsolutePoint = nil
            return
        }

        guard postEventAccessGranted else {
            if !didLogMissingPostPermission {
                print("absolute pointer updates unavailable: event posting permission not granted")
                didLogMissingPostPermission = true
            }
            lastAbsolutePoint = nil
            return
        }

        guard let touch = getPrimaryTouch() else {
            lastAbsolutePoint = nil
            return
        }

        guard let point = mapTouchToAbsolutePoint(touch, bounds: lastOsuBounds) else {
            return
        }

        if let lastAbsolutePoint,
           abs(lastAbsolutePoint.x - point.x) < 0.25,
           abs(lastAbsolutePoint.y - point.y) < 0.25
        {
            return
        }

        injectAbsolutePointer(to: point)
        lastAbsolutePoint = point
    }

    private func showOverlay(title: String) {
        guard !overlayMode else {
            return
        }

        print("osu map detected -> enabling absolute positioning for \(title.debugDescription)")
        overlayMode = true
        touchMonitor.setDebugEnabled(true)
        beginPerformanceActivity()
        lockPointer()
    }

    private func hideOverlay(reason: String) {
        guard overlayMode else {
            return
        }

        print("disabling absolute positioning: \(reason)")
        overlayMode = false
        lastOsuBounds = nil
        lastOsuProcessID = nil
        lastAbsolutePoint = nil
        primaryTouchID = nil
        touchMonitor.setDebugEnabled(false)
        unlockPointer()
        endPerformanceActivity()
    }

    private func activateOverlayMode() {
        guard !osuActive else {
            return
        }

        print("osu became active -> waiting for a map title")
        osuActive = true
        lastSignature = nil
        lastInMap = nil
        updateOverlay()
    }

    private func deactivateOverlayMode(reason: String) {
        guard osuActive || overlayMode else {
            return
        }

        osuActive = false
        lastSignature = nil
        lastInMap = nil
        lastOsuBounds = nil
        hideOverlay(reason: reason)
    }

    private func updateOverlay() {
        if debugPrintVisibleWindows, !printedDebug {
            debugPrintWindows()
            printedDebug = true
        }

        regionSelectorView?.needsDisplay = true

        if selectorOnly {
            return
        }

        if let osuApp = currentOsuApp() {
            hasSeenOsuProcess = true
            hasLoggedOsuExit = false
            hasLoggedWaitingForOsuLaunch = false

            if !osuActive, runningAppLooksLikeOsu(NSWorkspace.shared.frontmostApplication) {
                activateOverlayMode()
            }
            _ = osuApp
        } else {
            if launchesOsuSession, !hasSeenOsuProcess {
                if !hasLoggedWaitingForOsuLaunch {
                    print("waiting for osu! to launch...")
                    hasLoggedWaitingForOsuLaunch = true
                }
                return
            }

            if !hasLoggedOsuExit {
                print("osu is no longer running -> quitting TrackpadOSU")
                hasLoggedOsuExit = true
            }
            NSApp.terminate(nil)
            return
        }

        guard osuActive else {
            if overlayMode {
                hideOverlay(reason: "osu is not active")
            }
            lastOsuProcessID = nil
            return
        }

        guard let windowInfo = findOsuWindow() else {
            lastSignature = nil
            lastInMap = nil
            lastOsuBounds = nil
            lastOsuProcessID = nil
            logOsuWindowDiagnostics(reason: "osu window not found")
            hideOverlay(reason: "osu window not found")
            return
        }

        lastOsuProcessID = pid_t(windowInfo.pid)

        let signature = "\(windowInfo.pid)|\(windowInfo.owner)|\(windowInfo.cgTitle)|\(windowInfo.title)|\(windowInfo.accessibilityTitle ?? "")|\(windowInfo.bounds.x)|\(windowInfo.bounds.y)|\(windowInfo.bounds.width)|\(windowInfo.bounds.height)"
        if signature != lastSignature {
            print(
                "tracking osu candidate pid=\(windowInfo.pid) owner=\(windowInfo.owner.debugDescription) cgTitle=\(windowInfo.cgTitle.debugDescription) axTitle=\((windowInfo.accessibilityTitle ?? "").debugDescription) resolvedTitle=\(windowInfo.title.debugDescription) bounds=(\(windowInfo.bounds.x), \(windowInfo.bounds.y), \(windowInfo.bounds.width), \(windowInfo.bounds.height))"
            )
            lastSignature = signature
        }

        let inMap = osuWindowTitleIndicatesGameplay(windowInfo.title)
        if inMap != lastInMap {
            if inMap {
                print("osu title now looks like gameplay: \(windowInfo.title.debugDescription)")
            } else {
                print("osu title no longer looks like gameplay: \(windowInfo.title.debugDescription)")
            }
            lastInMap = inMap
        }

        guard inMap else {
            lastOsuBounds = nil
            logOsuWindowDiagnostics(reason: "osu active but title did not look like gameplay")
            hideOverlay(reason: "osu is active but not in a map (title=\(windowInfo.title.debugDescription))")
            return
        }

        lastWindowDiagnostics = nil
        showOverlay(title: windowInfo.title)
        lastOsuBounds = windowInfo.bounds
    }
}

private final class PermissionRequestController: NSObject, NSApplicationDelegate, ExitCodeReporting {
    private(set) var exitCode: Int32 = 0
    private let shouldPrompt: Bool
    private let statusFileURL: URL?
    private var permissionPollTimer: Timer?
    private var permissionPollDeadline: Date?

    init(shouldPrompt: Bool, statusFileURL: URL?) {
        self.shouldPrompt = shouldPrompt
        self.statusFileURL = statusFileURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.beginPermissionRequestFlow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func beginPermissionRequestFlow() {
        let before = Permissions.current()
        if shouldPrompt {
            print("permission status before request: \(before.summary)")
            Permissions.requestPrompts()
            startPermissionPolling(timeout: 3.0)
            return
        }

        print("permission status on re-check: \(before.summary)")
        finishPermissionRequest(with: before)
    }

    private func startPermissionPolling(timeout: TimeInterval) {
        permissionPollTimer?.invalidate()
        permissionPollDeadline = Date().addingTimeInterval(timeout)

        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let snapshot = Permissions.current()
            if snapshot.allGranted {
                timer.invalidate()
                self.permissionPollTimer = nil
                self.finishPermissionRequest(with: snapshot)
                return
            }

            guard let deadline = self.permissionPollDeadline, Date() >= deadline else {
                return
            }

            timer.invalidate()
            self.permissionPollTimer = nil
            self.finishPermissionRequest(with: snapshot)
        }
        permissionPollTimer?.tolerance = 0.0
    }

    private func finishPermissionRequest(with snapshot: PermissionSnapshot) {
        if snapshot.allGranted {
            if shouldPrompt {
                print("permission status after request: \(snapshot.summary)")
            } else {
                print("permission status on re-check: \(snapshot.summary)")
            }
            exitCode = 0
            writePermissionStatusFile()
            NSApp.terminate(nil)
            return
        }

        if shouldPrompt {
            print("permission status after request: \(snapshot.summary)")
        } else {
            print("permission status on re-check: \(snapshot.summary)")
        }
        print("please provide \(displayAppName) these permissions in System Settings > Privacy & Security: \(snapshot.missingDescription)")
        exitCode = 3
        writePermissionStatusFile()
        NSApp.terminate(nil)
    }

    private func writePermissionStatusFile() {
        guard let statusFileURL else {
            return
        }

        do {
            try "\(exitCode)\n".write(to: statusFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("failed to write permission status file \(statusFileURL.path): \(error)")
        }
    }
}

private final class MonitorAppController: NSObject, NSApplicationDelegate {
    private var observerTokens: [NSObjectProtocol] = []
    private var overlayApplication: NSRunningApplication?
    private var overlayLaunchInProgress = false
    private var intentionallyStoppedOverlayPID: pid_t?

    private var appBundleURL: URL {
        containingMainAppBundleURL(from: Bundle.main.bundleURL) ?? Bundle.main.bundleURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installWorkspaceObservers()
        ensureDesiredState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()

        stopOverlay(forceKillAfterDelay: false)
    }

    private func currentOsuApp() -> NSRunningApplication? {
        currentOsuApplication()
    }

    private func workspaceApplication(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private func installWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, let app = self.workspaceApplication(from: notification) else {
                    return
                }

                let name = app.localizedName ?? ""
                let bundle = app.bundleIdentifier ?? ""
                print("launched app pid=\(app.processIdentifier) name=\(name.debugDescription) bundle=\(bundle.debugDescription)")

                if runningAppLooksLikeOsu(app) {
                    self.launchOverlayIfNeeded()
                }
            }
        )

        observerTokens.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, let app = self.workspaceApplication(from: notification) else {
                    return
                }

                let name = app.localizedName ?? ""
                let bundle = app.bundleIdentifier ?? ""
                print("terminated app pid=\(app.processIdentifier) name=\(name.debugDescription) bundle=\(bundle.debugDescription)")

                if bundle == mainAppBundleIdentifier,
                   self.overlayApplication?.processIdentifier == app.processIdentifier
                {
                    let pid = app.processIdentifier
                    let wasIntentional = self.intentionallyStoppedOverlayPID == pid
                    if wasIntentional {
                        self.intentionallyStoppedOverlayPID = nil
                    }

                    self.overlayApplication = nil
                    self.overlayLaunchInProgress = false
                    print("overlay app ended pid=\(pid) intentional=\(wasIntentional)")
                    if !wasIntentional, self.currentOsuApp() != nil {
                        self.launchOverlayIfNeeded()
                    }
                }

                if runningAppLooksLikeOsu(app) {
                    self.stopOverlay(forceKillAfterDelay: true)
                }
            }
        )
    }

    private func ensureDesiredState() {
        if currentOsuApp() != nil {
            launchOverlayIfNeeded()
        } else {
            stopOverlay(forceKillAfterDelay: false)
        }
    }

    private func launchOverlayIfNeeded() {
        if let overlayApplication, !overlayApplication.isTerminated {
            return
        }

        guard !overlayLaunchInProgress else {
            return
        }
        overlayLaunchInProgress = true

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--overlay"]
        if #available(macOS 10.15, *) {
            configuration.createsNewApplicationInstance = true
        }

        NSWorkspace.shared.openApplication(at: appBundleURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.overlayLaunchInProgress = false

                if let error {
                    print("failed to launch overlay app: \(error)")
                    return
                }

                self.overlayApplication = app
                self.intentionallyStoppedOverlayPID = nil
                if let app {
                    print("launched overlay app pid=\(app.processIdentifier)")
                } else {
                    print("launched overlay app")
                }
            }
        }
    }

    private func stopOverlay(forceKillAfterDelay: Bool) {
        guard let application = overlayApplication else {
            return
        }

        overlayApplication = nil
        overlayLaunchInProgress = false
        intentionallyStoppedOverlayPID = application.processIdentifier

        guard !application.isTerminated else {
            return
        }

        print("stopping overlay app pid=\(application.processIdentifier)")
        application.terminate()

        guard forceKillAfterDelay else {
            return
        }

        let pid = application.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !application.isTerminated {
                kill(pid, SIGKILL)
            }
        }
    }
}

private func parseOptions() -> RuntimeOptions {
    let rawArguments = Array(CommandLine.arguments.dropFirst())
    let arguments = Set(rawArguments)
    let shouldPromptForPermissions = !arguments.contains("--no-permission-prompt")
    let permissionStatusFilePath = rawArguments.first(where: { $0.hasPrefix("--permission-status-file=") }).map {
        String($0.dropFirst("--permission-status-file=".count))
    }
    let isHelperBundle = Bundle.main.bundleIdentifier == helperAppBundleIdentifier

    if arguments.contains("--request-permissions") {
        return RuntimeOptions(
            mode: .requestPermissions,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if arguments.contains("--osu-running") {
        return RuntimeOptions(
            mode: .checkOsuRunning,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if arguments.contains("--register-helper") {
        return RuntimeOptions(
            mode: .registerHelper,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if arguments.contains("--unregister-helper") {
        return RuntimeOptions(
            mode: .unregisterHelper,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if arguments.contains("--helper") {
        return RuntimeOptions(
            mode: .helper,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if arguments.contains("--launcher") {
        return RuntimeOptions(
            mode: .launcher,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if arguments.contains("--monitor") {
        return RuntimeOptions(
            mode: .monitor,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if arguments.contains("--overlay") {
        return RuntimeOptions(
            mode: .overlay,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if arguments.contains("--selector") {
        return RuntimeOptions(
            mode: .selector,
            forceShowSelector: true,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    if isHelperBundle {
        return RuntimeOptions(
            mode: .helper,
            forceShowSelector: false,
            shouldPromptForPermissions: shouldPromptForPermissions,
            permissionStatusFilePath: permissionStatusFilePath
        )
    }

    return RuntimeOptions(
        mode: .launcher,
        forceShowSelector: arguments.contains("--show-selector"),
        shouldPromptForPermissions: shouldPromptForPermissions,
        permissionStatusFilePath: permissionStatusFilePath
    )
}

private func runApp() {
    let options = parseOptions()

    let lockName: String?
    switch options.mode {
    case .monitor, .helper:
        lockName = "background-observer"
    case .overlay:
        lockName = "overlay"
    case .launcher, .selector, .requestPermissions, .checkOsuRunning, .registerHelper, .unregisterHelper:
        lockName = nil
    }

    if let lockName {
        guard let instanceLock = ProcessInstanceLock.acquire(name: lockName) else {
            print("\(lockName) instance already running, exiting duplicate process")
            Foundation.exit(0)
        }
        processInstanceLock = instanceLock
    }

    let shouldRedirectLogs: Bool
    let logFileName: String
    switch options.mode {
    case .monitor:
        shouldRedirectLogs = true
        logFileName = "monitor.log"
    case .helper:
        shouldRedirectLogs = true
        logFileName = "helper.log"
    case .launcher, .overlay, .selector:
        shouldRedirectLogs = true
        logFileName = "monitor.log"
    case .requestPermissions, .checkOsuRunning, .registerHelper, .unregisterHelper:
        shouldRedirectLogs = false
        logFileName = ""
    }

    if shouldRedirectLogs {
        do {
            try FileManager.default.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
            let logPath = supportDirectoryURL.appendingPathComponent(logFileName).path
            _ = logPath.withCString { freopen($0, "a", stdout) }
            _ = logPath.withCString { freopen($0, "a", stderr) }
        } catch {
            print("failed to prepare background log directory: \(error)")
        }
    }

    setbuf(stdout, nil)
    setbuf(stderr, nil)

    if options.mode == .checkOsuRunning {
        Foundation.exit(currentOsuApplication() == nil ? 1 : 0)
    }

    if options.mode == .registerHelper {
        do {
            try setLoginItemEnabled(true)
            print("login item helper enabled")
            Foundation.exit(0)
        } catch {
            print("failed to enable login item helper: \(error)")
            Foundation.exit(1)
        }
    }

    if options.mode == .unregisterHelper {
        do {
            try setLoginItemEnabled(false)
            print("login item helper disabled")
            Foundation.exit(0)
        } catch {
            print("failed to disable login item helper: \(error)")
            Foundation.exit(1)
        }
    }

    let app = NSApplication.shared

    let delegate: NSObject & NSApplicationDelegate
    switch options.mode {
    case .launcher:
        app.setActivationPolicy(.accessory)
        delegate = OverlayAppController(selectorOnly: false, forceShowSelector: options.forceShowSelector, launchesOsuSession: true)
    case .monitor:
        app.setActivationPolicy(.prohibited)
        delegate = MonitorAppController()
    case .selector:
        app.setActivationPolicy(.accessory)
        delegate = OverlayAppController(selectorOnly: true, forceShowSelector: true)
    case .requestPermissions:
        app.setActivationPolicy(.accessory)
        delegate = PermissionRequestController(
            shouldPrompt: options.shouldPromptForPermissions,
            statusFileURL: options.permissionStatusFilePath.map { URL(fileURLWithPath: $0) }
        )
    case .overlay:
        app.setActivationPolicy(.accessory)
        delegate = OverlayAppController(selectorOnly: false, forceShowSelector: options.forceShowSelector, launchesOsuSession: false)
    case .helper:
        app.setActivationPolicy(.prohibited)
        delegate = MonitorAppController()
    case .checkOsuRunning, .registerHelper, .unregisterHelper:
        return
    }

    app.delegate = delegate
    app.run()

    if let exitCodeDelegate = delegate as? ExitCodeReporting {
        Foundation.exit(exitCodeDelegate.exitCode)
    }
}

runApp()
