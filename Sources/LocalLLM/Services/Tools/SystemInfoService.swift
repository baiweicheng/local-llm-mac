import AppKit
import Foundation
import IOKit

/// Phase 5: the system_info tool — basic facts about this Mac from
/// public APIs (ProcessInfo, sysctl, the home volume's resource
/// values, IOKit's power-source list, NSWorkspace's running apps).
/// Read-only by construction: nothing here can change the system.
enum SystemInfoService {

    static func systemInfo() -> String {
        var lines: [String] = []
        let process = ProcessInfo.processInfo

        let model = sysctlString("hw.model") ?? "Mac"
        let chip = sysctlString("machdep.cpu.brand_string")
        lines.append("Model: \(model)\(chip.map { " (\($0))" } ?? "")")
        lines.append("macOS: \(process.operatingSystemVersionString)")
        lines.append("Memory: \(ByteCountFormatter.string(fromByteCount: Int64(process.physicalMemory), countStyle: .memory))")

        if let free = freeStorageBytes() {
            lines.append("Free storage: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
        if let battery = batterySummary() {
            lines.append("Battery: \(battery)")
        }
        lines.append("Uptime: \(uptimeText(process.systemUptime))")
        if let name = Host.current().localizedName {
            lines.append("Computer name: \(name)")
        }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .sorted()
        if !apps.isEmpty {
            let cap = 25
            var appLine = "Open apps: " + apps.prefix(cap).joined(separator: ", ")
            if apps.count > cap { appLine += ", and \(apps.count - cap) more" }
            lines.append(appLine)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func freeStorageBytes() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func batterySummary() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [AnyObject],
              !list.isEmpty else {
            return nil
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? NSDictionary,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int,
                  max > 0 else {
                continue
            }
            let percent = Int((Double(current) / Double(max) * 100).rounded())
            let state = description[kIOPSPowerSourceStateKey] as? String
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            if state == (kIOPSACPowerValue as String) {
                return charging ? "\(percent)% (plugged in, charging)" : "\(percent)% (plugged in)"
            }
            return "\(percent)% (on battery)"
        }
        return nil
    }

    private static func uptimeText(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
