import SwiftUI

@main
struct LocalLectureSTTApp: App {
    @NSApplicationDelegateAdaptor(MacLifecycleDelegate.self) private var lifecycleDelegate
    @StateObject private var storageRoots: StorageRootViewModel
    @StateObject private var catalogStartup: CatalogStartupCoordinator
    @StateObject private var recording: RecordingSessionViewModel
    @StateObject private var modelManagement: ModelManagementViewModel
    @StateObject private var sessionDetail: SessionDetailViewModel

    init() {
        let roots = StorageRootManager.live()
        let catalog = Self.makeCatalog(roots: roots)
        let repository = FileSessionRepository(roots: roots)
        let sources = ModelImportSources()
        let models = FileModelRepository(sources: sources, validator: WhisperCppModelValidator(),
                                         references: SessionModelReferenceChecker(roots: roots))
        let activity = SessionActivityRegistry()
        let processActivity = ProcessInfoLifecycleActivityAdapter()
        let authority = LifecycleWorkAuthority(activity: { processActivity.update($0) })
        let modelManagement = ModelManagementViewModel(repository: models, downloader: ModelDownloadService(repository: models), authority: authority,
            supports: { ProductionSpeechModel.supports($0) }, importFolder: { descriptor in
                guard let url = OpenPanelDirectorySelector().chooseDirectory() else { return nil }
                let source = await sources.registerSelectedDirectory(url)
                do {
                    let result = try await models.importPackage(from: source, descriptor: descriptor, origin: .suppliedLocal)
                    await sources.unregister(source); return result
                } catch { await sources.unregister(source); throw error }
            })
        _modelManagement = StateObject(wrappedValue: modelManagement)
        let permission = AVFoundationMicrophonePermissionAuthorizer()
        let capture = MicrophoneCaptureController(
            permission: permission,
            driver: AVAudioEngineMicrophoneDriver(),
            monitor: InputSignalMonitor()
        )
        let microphonePreview = MicrophonePreviewViewModel(permission: permission, capture: capture, authority: authority)
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
            makeSpeechModel: { try ProductionSpeechModel.make(repository: models) },
            makeSelectedSpeechModel: { try ProductionSpeechModel.make(repository: models, descriptor: $0) },
            prepareCapture: { await microphonePreview.stop() },
            makeSpeechConverter: { SpeechPCMConverter() },
            activity: activity, authority: authority
        )
        let transcripts = FileTranscriptRepository(roots: roots, catalog: catalog)
        let finalization = AudioFinalizationCoordinator(worker: SessionFinalizationWorker(
            audio: FileAudioFinalizer(roots: roots, catalog: catalog), transcripts: transcripts,
            settleSpeech: { location, control in
                try await recordingCoordinator.settleSpeechForTranscript(at: location, control: control)
            }), authority: authority)
        let recovery = SessionRecoveryCoordinator(
            scanner: SessionFileScanner(roots: roots),
            persistence: repository,
            finalization: finalization,
            catalog: catalog,
            activity: activity, authority: authority
        )
        let coordinator = CatalogStartupCoordinator(catalog: catalog, recovery: recovery)
        let detail = SessionDetailViewModel(store: FileSessionDetailStore(roots: roots, transcripts: transcripts,
            catalog: catalog, activity: activity), player: SessionAudioPlayer(roots: roots, activity: activity),
            authority: authority, changed: { await coordinator.refreshItems() })
        _sessionDetail = StateObject(wrappedValue: detail)
        let lifetime = RecordingFinalizationCoordinator(recording: recordingCoordinator, finalization: finalization,
                                                        startupRecovery: recovery, activity: activity, authority: authority)
        _catalogStartup = StateObject(wrappedValue: coordinator)
        _recording = StateObject(wrappedValue: RecordingSessionViewModel(
            coordinator: lifetime, finalization: finalization, sessionActivity: activity, modelName: ProductionSpeechModel.displayName, models: modelManagement,
            microphonePreview: microphonePreview
        ))
        _storageRoots = StateObject(wrappedValue: StorageRootViewModel(
            controller: roots,
            directorySelector: OpenPanelDirectorySelector(),
            onRootChanged: { coordinator.refreshAfterRootChange() }
        ))
        lifecycleDelegate.configure(recording: lifetime, finalization: finalization, recovery: recovery, authority: authority,
                                    auxiliary: LifecycleAuxiliaryGroup([modelManagement, microphonePreview, detail]))
    }

    var body: some Scene {
        Window("Local Lecture STT", id: "main") {
            MainWindowView(storageRoots: storageRoots, catalogStartup: catalogStartup, recording: recording, detail: sessionDetail)
        }
        .defaultSize(width: 1000, height: 680)

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
