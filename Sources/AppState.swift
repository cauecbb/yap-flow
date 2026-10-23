import AppKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let modelContainer: ModelContainer
    let permissions = PermissionsManager()
    let launchAtLogin = LaunchAtLoginService()
    let vocabulary = VocabularyStore()
    let keys = APIKeyStore()
    let appleCleanup = TranscriptCleanupService()
    private(set) var cloud: CloudTranscriptionRouter!
    private(set) var cleanup: CleanupRouter!

    var currentInputName: String?
    var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    /// Who transcribes. Anything but on-device sends the audio to that provider.
    var transcriptionProvider: TranscriptionProvider {
        didSet {
            UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: "transcriptionProvider")
            // A transcript as heard wants cleaning; start with the same provider.
            if cleanupProvider == .off, let same = CleanupProvider(rawValue: transcriptionProvider.rawValue) {
                cleanupProvider = same
            }
        }
    }

    /// Who tidies the transcript when the transcription provider doesn't.
    var cleanupProvider: CleanupProvider {
        didSet {
            UserDefaults.standard.set(cleanupProvider.rawValue, forKey: "cleanupProvider")
            if cleanupProvider == .apple { appleCleanup.prewarm() }
        }
    }

    var mainPage: MainPage = .settings

    var modifierTrigger: ModifierTrigger {
        didSet {
            UserDefaults.standard.set(modifierTrigger.rawValue, forKey: "modifierTrigger")
            modifierHotkeys.trigger = modifierTrigger
        }
    }

    /// Wispr Flow-style: hold fn to talk, fn+space for hands-free.
    var pushToTalkFn: Bool {
        didSet {
            UserDefaults.standard.set(pushToTalkFn, forKey: "pushToTalkFn")
            pushToTalk.enabled = pushToTalkFn
            // A tap-to-toggle on fn would fight the hold.
            if pushToTalkFn, modifierTrigger == .function { modifierTrigger = .none }
        }
    }

    var functionKeyTrigger: FunctionKeyTrigger {
        didSet {
            UserDefaults.standard.set(functionKeyTrigger.rawValue, forKey: "functionKeyTrigger")
            functionKeys.trigger = functionKeyTrigger
        }
    }

    var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyDockVisibility()
        }
    }

    /// With this and `showInDock` both off, Yap runs on the shortcut alone and puts
    /// nothing on screen. Opening it again from Spotlight or Finder is the way back:
    /// `applicationShouldHandleReopen` surfaces a window without launching a second copy.
    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }

    /// "system" follows the OS locale; otherwise a BCP-47 identifier.
    var dictationLanguage: String {
        didSet {
            UserDefaults.standard.set(dictationLanguage, forKey: "dictationLanguage")
            applyDictationLocale()
        }
    }

    private(set) var availableLocales: [Locale] = []

    var effectiveDictationLocale: Locale {
        dictationLanguage == Self.systemLanguage ? .current : Locale(identifier: dictationLanguage)
    }

    static let systemLanguage = "system"

    private(set) var coordinator: RecordingCoordinator!

    private let hotkeys = HotkeyManager()
    private let modifierHotkeys = ModifierHotkeyMonitor()
    private let functionKeys = FunctionKeyMonitor()
    private let pushToTalk = PushToTalkMonitor()
    private let escapeMonitor = EscapeMonitor()
    private let injector = TextInjector()
    private let hud = HUDController()
    private let sounds = SystemSoundPlayer()
    private let deviceObserver = DefaultInputObserver()
    private var history: HistoryStore!
    private var windowCloseObserver: NSObjectProtocol?
    private let dictation: DictationSession

    private init() {
        do {
            modelContainer = try ModelContainer(for: Transcript.self)
        } catch {
            fatalError("Yap: failed to create model container: \(error)")
        }

        soundsEnabled = (UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool) ?? true
        showInDock = (UserDefaults.standard.object(forKey: "showInDock") as? Bool) ?? true
        showInMenuBar = (UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool) ?? true
        // Settings from before there were providers: a Gemini on/off switch and
        // an Apple Intelligence cleanup switch.
        let defaults = UserDefaults.standard
        transcriptionProvider = TranscriptionProvider(rawValue: defaults.string(forKey: "transcriptionProvider") ?? "")
            ?? ((defaults.object(forKey: "geminiEnabled") as? Bool) == false ? .onDevice : .gemini)
        cleanupProvider = CleanupProvider(rawValue: defaults.string(forKey: "cleanupProvider") ?? "")
            ?? (((defaults.object(forKey: "cleanupEnabled") as? Bool) ?? false) ? .apple : .off)
        modifierTrigger = ModifierTrigger(
            rawValue: UserDefaults.standard.string(forKey: "modifierTrigger") ?? ""
        ) ?? .none
        pushToTalkFn = (UserDefaults.standard.object(forKey: "pushToTalkFn") as? Bool) ?? true
        functionKeyTrigger = FunctionKeyTrigger(
            rawValue: UserDefaults.standard.string(forKey: "functionKeyTrigger") ?? ""
        ) ?? .none
        currentInputName = AudioDevices.defaultInputName()

        let language = UserDefaults.standard.string(forKey: "dictationLanguage") ?? Self.systemLanguage
        let dictation = DictationSession(
            locale: language == Self.systemLanguage ? .current : Locale(identifier: language)
        )
        self.dictation = dictation
        dictationLanguage = language

        let history = HistoryStore(context: modelContainer.mainContext)
        self.history = history

        sounds.enabled = { [weak self] in self?.soundsEnabled ?? true }

        cloud = CloudTranscriptionRouter(keys: keys) { [weak self] in self?.transcriptionProvider ?? .onDevice }
        cleanup = CleanupRouter(apple: appleCleanup, keys: keys) { [weak self] in self?.cleanupProvider ?? .off }

        coordinator = RecordingCoordinator(
            session: dictation,
            injector: injector,
            history: history,
            hud: hud,
            sounds: sounds,
            cleaner: cleanup,
            cleanupEnabled: { [weak self] in self?.cleanupProvider != .off },
            vocabulary: { [weak self] in self?.vocabulary.terms ?? [] },
            deviceName: { [weak self] in self?.currentInputName },
            cloud: cloud,
            cloudEnabled: { [weak self] in self?.transcriptionProvider != .onDevice }
        )

        dictation.contextualStrings = { [weak self] in self?.vocabulary.terms ?? [] }
    }

    func bootstrap() {
        applyDockVisibility()
        observeWindowClosesForDockVisibility()
        permissions.refresh()
        launchAtLogin.refresh()
        keys.load()

        // Accessibility takes effect live — no restart needed. Observing simply
        // keeps the UI honest the moment the user grants it.
        permissions.onAccessibilityGranted = { [weak self] in
            self?.pushToTalk.start()
            self?.functionKeys.start()
        }
        permissions.startObserving()

        hotkeys.onToggle { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.toggle() }
        }

        modifierHotkeys.onTap = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.toggle() }
        }
        modifierHotkeys.trigger = modifierTrigger
        modifierHotkeys.start()

        functionKeys.onTap = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.toggle() }
        }
        functionKeys.trigger = functionKeyTrigger
        functionKeys.start()

        bindPushToTalk()

        escapeMonitor.onEscape = { [weak self] in
            self?.coordinator.handleEscape()
        }
        escapeMonitor.start()

        // Build the HUD window and resolve the speech model up front, so the
        // first press of the shortcut is immediate rather than paying setup cost.
        hud.prepare()
        let locale = effectiveDictationLocale
        Task.detached(priority: .utility) {
            await DictationSession.prewarm(locale: locale)
        }

        Task { [weak self] in
            let locales = await TranscriptionService.availableLocales()
            self?.availableLocales = locales.sorted {
                Self.languageName(for: $0).localizedCaseInsensitiveCompare(Self.languageName(for: $1)) == .orderedAscending
            }
        }
        if cleanupProvider == .apple { appleCleanup.prewarm() }

        // Delivered on the main queue by the observer, so assign directly.
        deviceObserver.start { [weak self] name in
            self?.currentInputName = name
        }
    }

    private func bindPushToTalk() {
        pushToTalk.isDictating = { [weak self] in self?.coordinator.state == .recording }
        pushToTalk.onPress = { [weak self] in
            guard let self, self.coordinator.state == .idle else { return }
            self.hud.setControlsVisible(false)
            Task { await self.coordinator.toggle() }
        }
        pushToTalk.onRelease = { [weak self] in
            guard let self, self.coordinator.state == .recording else { return }
            Task { await self.coordinator.toggle() }
        }
        // A tap or fn+space. In a Task so it queues behind the press's start.
        pushToTalk.onLock = { [weak self] in
            Task { @MainActor in
                guard let self, self.coordinator.state == .recording else { return }
                self.sounds.playLock()
                self.hud.setControlsVisible(true)
            }
        }
        pushToTalk.onStopHandsFree = { [weak self] in
            guard let self, self.coordinator.state == .recording else { return }
            Task { await self.coordinator.toggle() }
        }
        pushToTalk.onCombo = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.cancel(silently: true) }
        }
        // Wispr cancels on the first escape, not the second.
        pushToTalk.onEscape = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.cancel() }
        }
        pushToTalk.enabled = pushToTalkFn
        if pushToTalkFn, modifierTrigger == .function { modifierTrigger = .none }

        // First launch of this build: start at login, like Wispr does.
        if UserDefaults.standard.object(forKey: "wisprSetupApplied") == nil {
            UserDefaults.standard.set(true, forKey: "wisprSetupApplied")
            launchAtLogin.set(true)
        }
    }

    private func applyDockVisibility() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    /// Flipping the policy to `.accessory` does not drop the Dock icon while a
    /// window is still on screen, so turning off "Show in Dock" from Settings
    /// leaves the icon until the window closes. Re-assert the policy once a window
    /// closes so closing Settings actually hides it.
    private func observeWindowClosesForDockVisibility() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.showInDock else { return }
                self.applyDockVisibility()
            }
        }
    }

    private func applyDictationLocale() {
        let locale = effectiveDictationLocale
        dictation.setLocale(locale)
        Task.detached(priority: .utility) {
            await DictationSession.prewarm(locale: locale)
        }
    }

    static func languageName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier(.bcp47))
            ?? locale.identifier(.bcp47)
    }

    func toggleRecording() {
        Task { await coordinator.toggle() }
    }

    /// Manual restart escape hatch. Never runs mid-dictation — that would throw
    /// away audio the user already spoke.
    func restartApp() {
        guard coordinator.state == .idle else { return }
        hud.show(device: nil)
        hud.setPhase(.restarting)
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            AppRelauncher.relaunch()
        }
    }

    /// Surfaces a window when the user opens Yap from Finder/Dock. Without this,
    /// launching an already-running agent app appears to do nothing at all.
    func presentMainWindow() {
        if permissions.allGranted {
            openMain(page: mainPage)
        } else {
            openOnboarding()
        }
    }

    /// Settings and History are pages within one window, not separate windows,
    /// so transcripts are always a click away.
    func openMain(page: MainPage = .settings) {
        mainPage = page
        WindowManager.shared.show(
            id: "main", title: "Yap",
            size: NSSize(width: 460, height: 740)
        ) {
            MainWindowView()
                .environment(self)
                .modelContainer(self.modelContainer)
        }
    }

    func openAbout() {
        WindowManager.shared.show(
            id: "about", title: "About Yap",
            size: NSSize(width: 360, height: 440), resizable: false
        ) { AboutView() }
    }

    func openOnboarding() {
        WindowManager.shared.show(
            id: "onboarding", title: "Welcome to Yap",
            size: NSSize(width: 460, height: 560), resizable: false
        ) { OnboardingView().environment(self) }
    }
}
