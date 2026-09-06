import SwiftUI

@main
struct LocalLectureSTTApp: App {
    @StateObject private var storageRoots: StorageRootViewModel
    @StateObject private var catalogStartup: CatalogStartupCoordinator
    @StateObject private var recording: RecordingSessionViewModel

    init() {
        let roots = StorageRootManager.live()
        let catalog: any SessionCataloging
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: support)
            catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
        } catch let error as CatalogError {
            catalog = UnavailableSessionCatalog(error: error.code)
        } catch {
            catalog = UnavailableSessionCatalog(error: .openFailed)
        }
        let repository = FileSessionRepository(roots: roots)
        let activity = SessionActivityRegistry()
        let permission = AVFoundationMicrophonePermissionAuthorizer()
        let capture = MicrophoneCaptureController(
            permission: permission,
            driver: AVAudioEngineMicrophoneDriver(),
            monitor: InputSignalMonitor()
        )
        let finalization = AudioFinalizationCoordinator(worker: FileAudioFinalizer(roots: roots, catalog: catalog))
        let recovery = SessionRecoveryCoordinator(
            scanner: SessionFileScanner(roots: roots),
            persistence: repository,
            finalization: finalization,
            catalog: catalog,
            activity: activity
        )
        let coordinator = CatalogStartupCoordinator(catalog: catalog, recovery: recovery)
        let recordingCoordinator = RecordingSessionCoordinator(
            roots: roots,
            permission: permission,
            capture: capture,
            recorders: ClosureAudioRecorderFactory { AVFoundationAudioRecorder(roots: roots) },
            repository: repository,
            catalog: catalog,
            environment: RecordingSessionEnvironment(
                appVersion: Self.appVersion,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString
            ),
            activity: activity
        )
        let lifetime = RecordingFinalizationCoordinator(recording: recordingCoordinator, finalization: finalization,
                                                        startupRecovery: recovery, activity: activity)
        _catalogStartup = StateObject(wrappedValue: coordinator)
        _recording = StateObject(wrappedValue: RecordingSessionViewModel(coordinator: lifetime, finalization: finalization))
        _storageRoots = StateObject(wrappedValue: StorageRootViewModel(
            controller: roots,
            directorySelector: OpenPanelDirectorySelector(),
            onRootChanged: { coordinator.refreshAfterRootChange() }
        ))
    }

    var body: some Scene {
        Window("Local Lecture STT", id: "main") {
            MainWindowView(storageRoots: storageRoots, catalogStartup: catalogStartup, recording: recording)
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsView(storageRoots: storageRoots)
        }
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "0.1.0"
        }
    }
}
