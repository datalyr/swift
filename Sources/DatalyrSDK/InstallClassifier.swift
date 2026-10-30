import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// What the first SDK launch on this device is.
///
/// The SDK used to fire `app_install` on its first launch, keyed only on its own
/// storage flag, so an app that added DATALYR in an update reported every existing
/// user as an install (Clema 2026-10: ~3,300 of 3,563, 952 sent to Meta). The
/// question that matters is not "how old is the install" but "did a build of this
/// app already run on this device before this process": files the app wrote in an
/// earlier process predate this process's start.
///
/// Decided ONCE, as the first thing initialize() does (before the SDK writes its own
/// ids or markers, which would otherwise look like an earlier run), and persisted:
/// a kill before app_install is enqueued re-fires the same class next launch.
public enum InstallType: String, Codable {
    case new
    case reinstall
    case existingUser = "existing_user"
    case unknown
}

struct InstallClassification: Codable, Equatable {
    let type: InstallType
    /// How it was decided: host_hint | ran_before | app_transaction | bundle_vs_container | none.
    let method: String
    /// Coarse age of the earlier install (<1d, 1-7d, 7-30d, 30-365d, >1y). Raw dates
    /// never leave the device.
    let priorInstallAge: String?
    /// AppTransaction.originalAppVersion (the build the Apple Account first got), production only.
    let originalAppVersion: String?

    var eventProperties: [String: Any] {
        var properties: [String: Any] = ["install_type": type.rawValue, "detection_method": method]
        if let priorInstallAge { properties["prior_install_age"] = priorInstallAge }
        if let originalAppVersion { properties["original_app_version"] = originalAppVersion }
        return properties
    }
}

/// The App Store's record of this Apple Account and the app (AppTransaction), production only.
struct StoreInstallRecord: Equatable {
    let originalAppVersion: String
    let originalPurchaseDate: Date
}

/// Everything the decision reads. Production reads the device; tests inject values.
struct InstallSignals {
    /// A file the app writes (its preferences plist, Documents, Application Support)
    /// was created before this process started. nil = unreadable.
    var ranBefore: Bool?
    /// The app bundle is well newer than the data container: updated on this device.
    var bundleNewerThanContainer: Bool?
    /// Creation date of the app's data container (Library). Never sent.
    var containerCreatedAt: Date?
    /// nil = unavailable (iOS < 16, sandbox / TestFlight / Xcode, signed out, offline, timeout).
    var store: StoreInstallRecord?
    /// CFBundleVersion of the running build.
    var currentBuild: String
    var now: Date
}

enum InstallClassifier {
    /// A reinstall's App Store record predates this container by at least this much.
    static let reinstallGap: TimeInterval = 24 * 3600

    static func classify(_ s: InstallSignals, hint: Bool?) -> InstallClassification {
        if hint == true {
            return InstallClassification(type: .existingUser, method: "host_hint",
                                         priorInstallAge: ageBucket(s.store?.originalPurchaseDate ?? s.containerCreatedAt, now: s.now),
                                         originalAppVersion: s.store?.originalAppVersion)
        }
        let storeBuildDiffers = s.store.map { $0.originalAppVersion != s.currentBuild }
        if s.ranBefore == true {
            // An earlier process of this app wrote files here. An existing user who updated
            // into the SDK, unless the record says this very build was the first one this
            // Apple Account got AND the app was not updated on this device: then it is a new
            // user whose app started the SDK late (consent / login gate).
            if storeBuildDiffers == false && s.bundleNewerThanContainer != true {
                return InstallClassification(type: .new, method: "app_transaction",
                                             priorInstallAge: nil, originalAppVersion: s.store?.originalAppVersion)
            }
            let method = s.bundleNewerThanContainer == true ? "bundle_vs_container"
                : (storeBuildDiffers == true ? "app_transaction" : "ran_before")
            return InstallClassification(type: .existingUser, method: method,
                                         priorInstallAge: ageBucket(earliest(s.containerCreatedAt, s.store?.originalPurchaseDate), now: s.now),
                                         originalAppVersion: s.store?.originalAppVersion)
        }
        guard let store = s.store else {
            // Nothing ran here before, but no App Store record to say whether this Apple
            // Account had the app: sent like an install, labelled so it can be told apart.
            return InstallClassification(type: s.ranBefore == false ? .new : .unknown,
                                         method: s.ranBefore == false ? "ran_before" : "none",
                                         priorInstallAge: nil, originalAppVersion: nil)
        }
        if let container = s.containerCreatedAt, store.originalPurchaseDate < container.addingTimeInterval(-reinstallGap) {
            // A fresh container, but this Apple Account got the app earlier: deleted and
            // reinstalled, a new device, or a Family Sharing member.
            return InstallClassification(type: .reinstall, method: "app_transaction",
                                         priorInstallAge: ageBucket(store.originalPurchaseDate, now: s.now),
                                         originalAppVersion: store.originalAppVersion)
        }
        return InstallClassification(type: .new, method: "app_transaction", priorInstallAge: nil,
                                     originalAppVersion: store.originalAppVersion)
    }

    static func ageBucket(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let days = now.timeIntervalSince(date) / 86_400
        switch days {
        case ..<1: return "<1d"
        case ..<7: return "1-7d"
        case ..<30: return "7-30d"
        case ..<365: return "30-365d"
        default: return ">1y"
        }
    }

    private static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return min(a, b)
        default: return a ?? b
        }
    }
}

// MARK: - Device signals

enum DeviceInstallSignals {
    /// How long the App Store record may take before it counts as unavailable.
    static let storeTimeout: UInt64 = 3_000_000_000

    static func read(now: Date = Date()) async -> InstallSignals {
        let fileManager = FileManager.default
        let processStart = processStartDate()
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        let containerCreatedAt = library.flatMap { creationDate($0) }
        var ranBefore: Bool? = nil
        if let processStart {
            ranBefore = appWrittenFiles().contains { url in
                guard let created = creationDate(url) else { return false }
                return created < processStart.addingTimeInterval(-1)
            }
        }
        var bundleNewer: Bool? = nil
        if let bundleDate = creationDate(Bundle.main.bundleURL), let containerCreatedAt {
            bundleNewer = bundleDate > containerCreatedAt.addingTimeInterval(3600)
        }
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        return InstallSignals(ranBefore: ranBefore, bundleNewerThanContainer: bundleNewer,
                              containerCreatedAt: containerCreatedAt, store: await storeRecord(),
                              currentBuild: build, now: now)
    }

    /// Files only the app itself creates: its preferences plist and the top level of
    /// Documents and Application Support. Never Library or Caches themselves, which
    /// the system creates at install time.
    static func appWrittenFiles() -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first,
           let bundleId = Bundle.main.bundleIdentifier {
            urls.append(library.appendingPathComponent("Preferences/\(bundleId).plist"))
        }
        for directory in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory] {
            guard let root = fileManager.urls(for: directory, in: .userDomainMask).first,
                  let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey],
                                                                       options: [.skipsHiddenFiles]) else { continue }
            urls.append(contentsOf: children.prefix(50))
        }
        return urls
    }

    static func creationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// This process's start time (sysctl KERN_PROC_PID), nil when unreadable.
    static func processStartDate() -> Date? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let seconds = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        #else
        return nil
        #endif
    }

    /// AppTransaction.shared in production only, capped at storeTimeout. Never refresh():
    /// that shows an App Store sign-in prompt.
    static func storeRecord() async -> StoreInstallRecord? {
        #if canImport(StoreKit)
        guard #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) else { return nil }
        return await withTaskGroup(of: StoreInstallRecord?.self) { group in
            group.addTask {
                guard let result = try? await AppTransaction.shared else { return nil }
                let transaction: AppTransaction
                switch result {
                case .verified(let value), .unverified(let value, _): transaction = value
                }
                guard transaction.environment == .production else { return nil }
                return StoreInstallRecord(originalAppVersion: transaction.originalAppVersion,
                                          originalPurchaseDate: transaction.originalPurchaseDate)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: storeTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        return nil
        #endif
    }
}
