import SwiftUI

@main
struct LocalLectureSTTApp: App {
    @NSApplicationDelegateAdaptor(MacLifecycleDelegate.self) private var lifecycleDelegate
    @StateObject private var storageRoots: StorageRootViewModel
    @StateObject private var catalogStartup: CatalogStartupCoordinator
    @StateObject private var recording: RecordingSessionViewModel

    init() {
        let roots = StorageRootManager.live()
        let catalog = Self.makeCatalog(roots: roots)
        let repository = FileSessionRepository(roots: roots)
        let activity = SessionActivityRegistry()
        let processActivity = ProcessInfoLifecycleActivityAdapter()
        let authority = LifecycleWorkAuthority(activity: { processActivity.update($0) })
        let permission = AVFoundationMicrophonePermissionAuthorizer()
        let capture = MicrophoneCaptureController(
            permission: permission,
            driver: AVAudioEngineMicrophoneDriver(),
            monitor: InputSignalMonitor()
        )
        let finalization = AudioFinalizationCoordinator(worker: FileAudioFinalizer(roots: roots, catalog: catalog), authority: authority)
        let recovery = SessionRecoveryCoordinator(
            scanner: SessionFileScanner(roots: roots),
            persistence: repository,
            finalization: finalization,
            catalog: catalog,
            activity: activity, authority: authority
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
            activity: activity, authority: authority
        )
        let lifetime = RecordingFinalizationCoordinator(recording: recordingCoordinator, finalization: finalization,
                                                        startupRecovery: recovery, activity: activity, authority: authority)
        _catalogStartup = StateObject(wrappedValue: coordinator)
        _recording = StateObject(wrappedValue: RecordingSessionViewModel(coordinator: lifetime, finalization: finalization))
        _storageRoots = StateObject(wrappedValue: StorageRootViewModel(
            controller: roots,
            directorySelector: OpenPanelDirectorySelector(),
            onRootChanged: { coordinator.refreshAfterRootChange() }
        ))
        lifecycleDelegate.configure(recording: lifetime, finalization: finalization, recovery: recovery, authority: authority)
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

    static func makeCatalog(roots: StorageRootManager,
                            directory: @escaping @Sendable () -> URL = {
                                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            }) -> DeferredSessionCatalog {
        DeferredSessionCatalog {
            let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: directory())
            return SessionCatalogReconciler(scanner: SessionFileScanner(roots: roots), store: store)
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
