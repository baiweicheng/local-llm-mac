import Contacts
import EventKit
import Foundation
import MusicKit
import Photos

/// Phase 5: reading and requesting the system permissions behind the
/// visibility sources.
///
/// `PermissionStatusReader` is the read half: plain synchronous status
/// lookups, safe to call from anywhere (the tool runtime consults it
/// at execution time, the Settings panel through `PermissionCenter`).
/// `PermissionCenter` is the write half: the @MainActor store the
/// Settings panel binds to, which also performs the requests when a
/// source is first enabled.
///
/// A note on prompts: macOS shows permission dialogs based on the
/// app's bundle usage-description strings. Those ship with the
/// packaged app (Scripts/Info.plist, assembled by
/// Scripts/make-app.sh); when the app is run from Xcode during
/// development, macOS attributes the access to Xcode instead. Every
/// request here is wrapped so a failure lands as a state the UI can
/// explain, never a crash.
enum PermissionStatusReader {

    static func currentState(for source: VisibilitySource) -> PermissionState {
        switch source {
        case .calendar:
            return mapEventKit(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return mapEventKit(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            return mapContacts(CNContactStore.authorizationStatus(for: .contacts))
        case .photos:
            return mapPhotos(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        case .music:
            return mapMusic(MusicAuthorization.currentStatus)
        case .spotlight, .files, .system, .clipboard:
            // No macOS permission gates these: Spotlight searches the
            // user's own index, shared folders are granted by picking
            // them, and system/clipboard reads are always available.
            return .authorized
        }
    }

    private static func mapEventKit(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        case .writeOnly: return .denied // can add events but not read them
        case .authorized: return .authorized // pre-macOS-14 name for full access
        @unknown default: return .unavailable
        }
    }

    private static func mapContacts(_ status: CNAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .authorized
        @unknown default: return .unavailable
        }
    }

    private static func mapPhotos(_ status: PHAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .authorized // "selected photos" still reads
        @unknown default: return .unavailable
        }
    }

    private static func mapMusic(_ status: MusicAuthorization.Status) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }
}

@MainActor
@Observable
final class PermissionCenter {

    private(set) var states: [VisibilitySource: PermissionState] = [:]

    init() {
        refresh()
    }

    func state(for source: VisibilitySource) -> PermissionState {
        states[source] ?? PermissionStatusReader.currentState(for: source)
    }

    func refresh() {
        for source in VisibilitySource.allCases {
            states[source] = PermissionStatusReader.currentState(for: source)
        }
    }

    /// Ask macOS for a source's permission (only called when the user
    /// first enables the source, or taps Allow in Settings). Ends with
    /// a refresh either way — a refused or failed request shows up as
    /// the state the panel explains.
    func request(_ source: VisibilitySource) async {
        do {
            switch source {
            case .calendar:
                _ = try await EKEventStore().requestFullAccessToEvents()
            case .reminders:
                _ = try await EKEventStore().requestFullAccessToReminders()
            case .contacts:
                _ = try await requestContactsAccess()
            case .photos:
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            case .music:
                _ = await MusicAuthorization.request()
            case .spotlight, .files, .system, .clipboard:
                break // nothing to ask for
            }
        } catch {
            // No dialog could be shown (for example, the running build
            // has no usage-description strings yet). The refresh below
            // records the resulting state and the panel explains it.
        }
        refresh()
    }

    private func requestContactsAccess() async throws -> Bool {
        let store = CNContactStore()
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
