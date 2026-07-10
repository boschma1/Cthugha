import Cocoa
import MetalKit
import IOKit.pwr_mgt

// The audio source to reopen on the next launch. Persisted (JSON) in UserDefaults
// so Cthugha reopens whatever the user last chose: system audio, the microphone,
// or a specific application's audio (remembered by bundle id).
enum SavedSource: Codable {
    case system
    case microphone
    case app(bundleID: String, name: String)
}

// MTKView subclass that owns keyboard controls.
final class CthughaView: MTKView {
    weak var renderer: Renderer?
    weak var appDelegate: AppDelegate?

    override var acceptsFirstResponder: Bool { true }

    // Double-click anywhere in the visualiser toggles full screen; the cursor is
    // then hidden by the window delegate (single clicks fall through as normal).
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let ad = appDelegate else { return }

        // Arrow keys cycle the colour palette (left/down = previous, right/up = next).
        switch event.keyCode {
        case 123, 125: // left, down
            ad.performPrevPalette()
            return
        case 124, 126: // right, up
            ad.performNextPalette()
            return
        default:
            break
        }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch chars {
        case "f":
            window?.toggleFullScreen(nil)
        case " ", "m":
            ad.performNextMode()
        case "p":
            ad.performNextPalette()
        case "c":
            ad.performToggleColorCycle()
        case "i":
            ad.performToggleSource()
        case "v":
            if event.modifierFlags.contains(.shift) { ad.performPrevStyle() }
            else { ad.performNextStyle() }
        case "=", "+":
            ad.performAmp(0.1)
        case "-", "_":
            ad.performAmp(-0.1)
        case ".", ">":
            ad.performDecay(0.005)
        case ",", "<":
            ad.performDecay(-0.005)
        case "]":
            ad.performIntensity(0.1)
        case "[":
            ad.performIntensity(-0.1)
        case ")", "0":
            ad.performSwirl(0.25)
        case "(", "9":
            ad.performSwirl(-0.25)
        case "h":
            ad.showHelp()
        case "\u{1b}": // esc leaves full screen
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        default:
            break
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var rootView: RootView!
    private var overlay: NowPlayingOverlay!
    private var hud: HUDOverlay!
    private var view: CthughaView!
    private var renderer: Renderer!
    private let store = WaveformStore()
    private let nowPlaying = NowPlayingMonitor()

    private var systemSource: SystemAudioSource!
    private var micSource: MicAudioSource!
    private var currentSource: AudioSource?
    private var systemRetryTimer: Timer?
    private var appTapWatchdog: Timer?

    private let startFullScreenKey = "StartFullScreen"
    private let rendererSettingsKey = "RendererSettings"
    private let audioSourceKey = "AudioSource"
    private var startFullScreenItem: NSMenuItem?
    private var sourceMenu: NSMenu?
    private var styleMenu: NSMenu?

    // Whether we currently hold an NSCursor.hide() (balanced with unhide()).
    private var cursorHidden = false

    // Power assertion held while full screen is active so the screensaver /
    // display sleep can't kick in mid-visualisation. 0 means "not held".
    private var sleepAssertionID: IOPMAssertionID = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this system.")
        }
        guard let renderer = Renderer(device: device, store: store) else {
            fatalError("Failed to create renderer.")
        }
        self.renderer = renderer

        // App icon (also drives the Dock tile).
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        let rect = NSRect(x: 0, y: 0, width: 1000, height: 640)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.center()
        window.title = "Cthugha"
        window.backgroundColor = .black

        view = CthughaView(frame: rect, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.renderer = renderer
        view.appDelegate = self
        renderer.setColorPixelFormat(view.colorPixelFormat)
        view.delegate = renderer

        overlay = NowPlayingOverlay(frame: .zero)
        hud = HUDOverlay(frame: .zero)
        rootView = RootView(frame: rect)
        rootView.metalView = view
        rootView.overlay = overlay
        rootView.hud = hud
        rootView.addSubview(view)
        rootView.addSubview(overlay)
        rootView.addSubview(hud)

        window.contentView = rootView
        window.delegate = self
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        // Restore the look (style, palette, mode, amp, decay…) from the last run.
        if let saved = loadRendererSettings() {
            renderer.restoreSettings(saved)
            rebuildStyleMenu()
        }

        // Full-screen preset: --fullscreen flag or a saved preference.
        let wantFullScreen = CommandLine.arguments.contains("--fullscreen")
            || UserDefaults.standard.bool(forKey: startFullScreenKey)
        if wantFullScreen {
            DispatchQueue.main.async { [weak self] in self?.window.toggleFullScreen(nil) }
        }

        systemSource = SystemAudioSource(store: store)
        micSource = MicAudioSource(store: store)
        AppDelegate.printHelp()
        // The microphone source and the system-audio mic fallback need Microphone
        // (audio-input) authorization, so ask for it up front. Per-app taps and the
        // ScreenCaptureKit system-audio path instead need "Screen & System Audio
        // Recording", whose prompt is surfaced when a capture starts below.
        Task { await ProcessAudio.requestAudioInputAccess() }
        restoreAudioSource()
        updateTitle()

        // Now-playing overlay (Spotify / Apple Music).
        nowPlaying.onChange = { [weak self] info in
            self?.overlay.update(info)
            self?.rootView.needsLayout = true
        }
        nowPlaying.start()

        warnIfTranslocated()
    }

    // MARK: - Full screen (NSWindowDelegate)

    // Hide the mouse pointer while full screen is active — covers every entry
    // path (double-click, the `f` key, the View menu, and the --fullscreen /
    // saved preset) — and restore it when leaving full screen. The screensaver
    // and display sleep are suppressed for the same window.
    func windowDidEnterFullScreen(_ notification: Notification) {
        setCursorHidden(true)
        setScreensaverPrevented(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        setCursorHidden(false)
        setScreensaverPrevented(false)
    }

    func windowWillClose(_ notification: Notification) {
        setCursorHidden(false)
        setScreensaverPrevented(false)
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    // Hold an IOKit power assertion while full screen so macOS won't start the
    // screensaver or idle-sleep the display. Balanced: create once, release once.
    private func setScreensaverPrevented(_ prevented: Bool) {
        if prevented {
            guard sleepAssertionID == 0 else { return }
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Cthugha full-screen visualiser" as CFString,
                &sleepAssertionID)
        } else {
            guard sleepAssertionID != 0 else { return }
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }

    // A browser-downloaded (quarantined) app is run by Gatekeeper from a random
    // read-only "App Translocation" path, which can break audio/permission grants.
    // Nudge the user to move it into /Applications, where it runs normally.
    private func warnIfTranslocated() {
        guard Bundle.main.bundlePath.contains("/AppTranslocation/") else { return }
        NSLog("Cthugha: running translocated — move Cthugha.app to Applications.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.hud.showList("Move Cthugha to your Applications folder\n\n" +
                "It is running from a temporary, read-only location (macOS Gatekeeper),\n" +
                "which can block audio capture. Drag Cthugha.app into Applications,\n" +
                "then reopen it.")
        }
    }

    // MARK: - Audio management

    private func startSystemAudio() {
        Task { @MainActor in
            do {
                try await systemSource.start()
                micSource.stop()
                currentSource = systemSource
                store.resetGain()
                systemRetryTimer?.invalidate(); systemRetryTimer = nil
                NSLog("Cthugha: capturing system audio.")
                updateTitle()
            } catch {
                NSLog("Cthugha: system audio unavailable (\(error.localizedDescription)); " +
                      "using microphone and retrying system audio in the background. " +
                      "Enable 'Screen & System Audio Recording' for Cthugha to capture Spotify/Music.")
                await startMic()
                scheduleSystemRetry()
            }
        }
    }

    // Once the user grants Screen Recording, pick up system audio automatically
    // (no relaunch needed if macOS allows it) and switch away from the mic.
    private func scheduleSystemRetry() {
        guard systemRetryTimer == nil else { return }
        systemRetryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.currentSource !== self.systemSource else { return }
            Task { @MainActor in
                do {
                    try await self.systemSource.start()
                    self.micSource.stop()
                    self.currentSource = self.systemSource
                    self.store.resetGain()
                    self.systemRetryTimer?.invalidate(); self.systemRetryTimer = nil
                    NSLog("Cthugha: system audio now available — switched from microphone.")
                    self.updateTitle()
                } catch {
                    // Still not granted; keep waiting silently.
                }
            }
        }
    }

    @MainActor
    private func startMic(announceFailure: Bool = false) async {
        do {
            try await micSource.start()
            currentSource = micSource
            store.resetGain()
        } catch {
            NSLog("Cthugha: microphone unavailable: \(error.localizedDescription)")
            currentSource = nil
            if announceFailure {
                hud.showList(error.localizedDescription)
            }
        }
        updateTitle()
    }

    func toggleAudioSource() {
        // Manual switch takes over from the automatic retry / watchdog.
        systemRetryTimer?.invalidate(); systemRetryTimer = nil
        appTapWatchdog?.invalidate(); appTapWatchdog = nil
        let switchingToMic = (currentSource === systemSource)
        currentSource?.stop()
        saveAudioSource(switchingToMic ? .microphone : .system)
        Task { @MainActor in
            if switchingToMic {
                await startMic(announceFailure: true)
            } else {
                startSystemAudio()
            }
        }
    }

    // MARK: - Source selection (menu)

    @objc private func selectSystemSource(_ sender: Any?) {
        systemRetryTimer?.invalidate(); systemRetryTimer = nil
        appTapWatchdog?.invalidate(); appTapWatchdog = nil
        saveAudioSource(.system)
        currentSource?.stop()
        startSystemAudio()
    }

    @objc private func selectMicSource(_ sender: Any?) {
        systemRetryTimer?.invalidate(); systemRetryTimer = nil
        appTapWatchdog?.invalidate(); appTapWatchdog = nil
        saveAudioSource(.microphone)
        let old = currentSource
        Task { @MainActor in
            old?.stop()
            await startMic(announceFailure: true)
        }
    }

    @objc private func selectAppSource(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AudioApp else { return }
        activateAppSource(app)
    }

    // Start (or restore) a per-app tap. Shared by the Source menu and by
    // restoreAudioSource() at launch.
    func activateAppSource(_ app: AudioApp) {
        systemRetryTimer?.invalidate(); systemRetryTimer = nil
        appTapWatchdog?.invalidate(); appTapWatchdog = nil
        saveAudioSource(.app(bundleID: app.bundleID, name: app.name))
        let old = currentSource
        let newSource = ProcessTapAudioSource(app: app, store: store)
        Task { @MainActor in
            old?.stop()
            do {
                try await newSource.start()
                currentSource = newSource
                store.resetGain()
                NSLog("Cthugha: capturing \(newSource.name).")
                updateTitle()
                startAppTapWatchdog(for: app.bundleID)
            } catch let error as ProcessTapError {
                // e.g. Screen & System Audio Recording is off — tell the user how
                // to fix it and fall back to system audio so there's still
                // something on screen.
                NSLog("Cthugha: \(newSource.name) capture blocked: \(error.localizedDescription)")
                hud.showList(error.localizedDescription)
                startSystemAudio()
            } catch {
                NSLog("Cthugha: \(newSource.name) capture failed: \(error.localizedDescription); " +
                      "falling back to system audio.")
                startSystemAudio()
            }
        }
    }

    // Watches an active per-app tap and rebuilds it if it falls silent while the
    // app's audio processes have changed (track change, pause/resume, engine
    // re-init) — a cached process-object id can otherwise keep delivering silence.
    private func startAppTapWatchdog(for bundleID: String) {
        appTapWatchdog?.invalidate()
        appTapWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self,
                  let tap = self.currentSource as? ProcessTapAudioSource,
                  tap.bundleID == bundleID else { return }
            // Still receiving audio → nothing to do.
            guard tap.secondsSinceAudio() > 3 else { return }
            // Silent: only rebuild if fresh, *different* process objects exist
            // (if the app is simply paused there are none, so we leave it be).
            let fresh = ProcessAudio.objectIDs(forBundleID: bundleID)
            guard !fresh.isEmpty, fresh != tap.activeObjectIDs else { return }
            Task { @MainActor in
                guard self.currentSource === tap else { return }
                tap.stop()
                let app = AudioApp(bundleID: bundleID, name: tap.name, objectIDs: fresh)
                let rebuilt = ProcessTapAudioSource(app: app, store: self.store)
                do {
                    try await rebuilt.start()
                    self.currentSource = rebuilt
                    self.store.resetGain()
                    NSLog("Cthugha: reattached tap for \(rebuilt.name) (audio process changed).")
                    self.updateTitle()
                } catch {
                    NSLog("Cthugha: could not reattach \(app.name): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - UI

    func updateTitle() {
        let src = currentSource?.name ?? "No audio"
        window.title = "Cthugha  —  \(src)  —  \(renderer.status)"
        // Dock badge reflects the active audio source.
        if currentSource === systemSource {
            NSApp.dockTile.badgeLabel = "SYS"
        } else if currentSource === micSource {
            NSApp.dockTile.badgeLabel = "MIC"
        } else if let tap = currentSource as? ProcessTapAudioSource {
            NSApp.dockTile.badgeLabel = tap.badgeTag
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Cthugha",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cthugha", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let fs = NSMenuItem(title: "Toggle Full Screen",
                            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)

        viewMenu.addItem(.separator())
        let preset = NSMenuItem(title: "Start in Full Screen",
                                action: #selector(toggleStartFullScreenPreset(_:)), keyEquivalent: "")
        preset.target = self
        preset.state = UserDefaults.standard.bool(forKey: startFullScreenKey) ? .on : .off
        viewMenu.addItem(preset)
        startFullScreenItem = preset

        // "Controls" menu — the complete keyboard-command list. Every item runs
        // its action on click and shows the shortcut natively; the shortcuts also
        // keep working directly (see CthughaView.keyDown).
        let controlsItem = NSMenuItem()
        mainMenu.addItem(controlsItem)
        let ctl = NSMenu(title: "Controls")
        controlsItem.submenu = ctl
        let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        func ctlAdd(_ title: String, _ action: Selector, _ key: String,
                    _ mods: NSEvent.ModifierFlags = []) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            ctl.addItem(it)
        }
        ctlAdd("Next Motion Mode", #selector(ctlNextMode(_:)), "m")
        ctlAdd("Previous Palette", #selector(ctlPrevPalette(_:)), leftArrow)
        ctlAdd("Next Palette", #selector(ctlNextPalette(_:)), rightArrow)
        ctlAdd("Toggle Colour Cycling", #selector(ctlToggleColorCycle(_:)), "c")
        ctl.addItem(.separator())
        ctlAdd("Next Style", #selector(ctlNextStyle(_:)), "v")
        ctlAdd("Previous Style", #selector(ctlPrevStyle(_:)), "v", [.shift])
        ctl.addItem(.separator())
        ctlAdd("Wave Amplitude – More  ( + )", #selector(ctlAmpUp(_:)), "")
        ctlAdd("Wave Amplitude – Less  ( - )", #selector(ctlAmpDown(_:)), "")
        ctlAdd("Feedback Decay – Longer  ( . )", #selector(ctlDecayUp(_:)), "")
        ctlAdd("Feedback Decay – Shorter  ( , )", #selector(ctlDecayDown(_:)), "")
        ctlAdd("Intensity – More  ( ] )", #selector(ctlIntensityUp(_:)), "")
        ctlAdd("Intensity – Less  ( [ )", #selector(ctlIntensityDown(_:)), "")
        ctlAdd("Swirl – More  ( 0 )", #selector(ctlSwirlUp(_:)), "")
        ctlAdd("Swirl – Less  ( 9 )", #selector(ctlSwirlDown(_:)), "")
        ctl.addItem(.separator())
        ctlAdd("Toggle Audio Source (System / Mic)", #selector(ctlToggleSource(_:)), "i")
        let fsCtl = NSMenuItem(title: "Toggle Full Screen",
                               action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fsCtl.keyEquivalentModifierMask = []
        ctl.addItem(fsCtl)
        ctlAdd("Show Keyboard Shortcuts", #selector(ctlHelp(_:)), "h")

        // Dynamic "Source" menu — lists system audio, microphone, and every app
        // currently producing audio. Rebuilt each time it opens (menuNeedsUpdate).
        let sourceItem = NSMenuItem()
        mainMenu.addItem(sourceItem)
        let srcMenu = NSMenu(title: "Source")
        srcMenu.delegate = self
        sourceItem.submenu = srcMenu
        sourceMenu = srcMenu
        rebuildSourceMenu()

        // "Style" menu — cycle named look presets (Current + the variations).
        let styleMenuItem = NSMenuItem()
        mainMenu.addItem(styleMenuItem)
        let stMenu = NSMenu(title: "Style")
        stMenu.delegate = self
        styleMenuItem.submenu = stMenu
        styleMenu = stMenu
        rebuildStyleMenu()

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Source menu building

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sourceMenu { rebuildSourceMenu() }
        else if menu === styleMenu { rebuildStyleMenu() }
    }

    func refreshStyleMenu() {
        updateTitle()
        rebuildStyleMenu()
    }

    private func rebuildStyleMenu() {
        guard let menu = styleMenu else { return }
        menu.removeAllItems()
        let active = renderer.currentStyleIndex
        for i in 0..<Renderer.styleCount {
            let item = NSMenuItem(title: Renderer.styleName(i),
                                  action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = i
            item.state = (i == active) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Cycle with the “v” key (⇧v = previous)",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        performSetStyle(i)
    }

    // MARK: - Control actions (shared by the Controls menu and CthughaView.keyDown)
    // Each performs the change, refreshes the title/Style checkmark (manual tweaks
    // call markCustom() and drop back to "Current"), and flashes the on-screen HUD.
    func performNextMode() { renderer.nextMode(); afterChange(); flash("Mode", renderer.modeName) }
    func performNextPalette() { renderer.nextPalette(); afterChange(); flash("Palette", renderer.paletteName) }
    func performPrevPalette() { renderer.prevPalette(); afterChange(); flash("Palette", renderer.paletteName) }
    func performToggleColorCycle() {
        renderer.toggleColorCycle(); afterChange()
        flash("Colour Cycling", renderer.colorCycleOn ? "On" : "Off")
    }
    func performNextStyle() { renderer.nextStyle(); afterChange(); flash("Style", renderer.currentStyleName) }
    func performPrevStyle() { renderer.prevStyle(); afterChange(); flash("Style", renderer.currentStyleName) }
    func performSetStyle(_ i: Int) { renderer.setStyle(i); afterChange(); flash("Style", renderer.currentStyleName) }
    func performAmp(_ d: Float) {
        renderer.changeWaveAmp(d); afterChange()
        flashLevel("Wave Amplitude", renderer.waveAmpValue, 0.1...3.0, decimals: 2)
    }
    func performDecay(_ d: Float) {
        renderer.changeDecay(d); afterChange()
        flashLevel("Feedback Decay", renderer.decayValue, 0.80...0.995, decimals: 3)
    }
    func performIntensity(_ d: Float) {
        renderer.changeIntensity(d); afterChange()
        flashLevel("Intensity", renderer.intensityValue, 0.2...4.0, decimals: 2)
    }
    func performSwirl(_ d: Float) {
        renderer.changeSwirl(d); afterChange()
        flashLevel("Swirl", renderer.swirlValue, -3.0...3.0, decimals: 2)
    }
    func performToggleSource() {
        toggleAudioSource(); updateTitle()
        flash("Source", currentSource?.name ?? "No audio")
    }

    private func afterChange() {
        updateTitle()
        rebuildStyleMenu()
        saveRendererSettings()
    }

    // MARK: - Settings persistence

    // Save the current look so the next launch reopens with it. Called after every
    // visual change (mode, palette, style, amp, decay, intensity, swirl, cycle).
    private func saveRendererSettings() {
        guard let renderer,
              let data = try? JSONEncoder().encode(renderer.exportSettings()) else { return }
        UserDefaults.standard.set(data, forKey: rendererSettingsKey)
    }

    private func loadRendererSettings() -> Renderer.Settings? {
        guard let data = UserDefaults.standard.data(forKey: rendererSettingsKey) else { return nil }
        return try? JSONDecoder().decode(Renderer.Settings.self, from: data)
    }

    // Remember which audio source the user chose, so the next launch reopens it.
    private func saveAudioSource(_ source: SavedSource) {
        guard let data = try? JSONEncoder().encode(source) else { return }
        UserDefaults.standard.set(data, forKey: audioSourceKey)
    }

    private func loadAudioSource() -> SavedSource? {
        guard let data = UserDefaults.standard.data(forKey: audioSourceKey) else { return nil }
        return try? JSONDecoder().decode(SavedSource.self, from: data)
    }

    // Reopen the audio source saved from the previous run. Falls back to system
    // audio when nothing was saved, or when a remembered app isn't currently
    // producing audio (so there's always something on screen).
    private func restoreAudioSource() {
        switch loadAudioSource() {
        case .microphone:
            Task { @MainActor in
                await startMic(announceFailure: false)
                if currentSource == nil { startSystemAudio() }
            }
        case .app(let bundleID, let name):
            let ids = ProcessAudio.objectIDs(forBundleID: bundleID)
            guard !ids.isEmpty else {
                NSLog("Cthugha: remembered source '\(name)' isn't producing audio right now; " +
                      "using system audio.")
                startSystemAudio()
                return
            }
            activateAppSource(AudioApp(bundleID: bundleID, name: name, objectIDs: ids))
        case .system, .none:
            startSystemAudio()
        }
    }

    private func flash(_ title: String, _ detail: String) {
        hud.show("\(title)  ·  \(detail)", fraction: nil)
    }

    private func flashLevel(_ title: String, _ value: Float, _ range: ClosedRange<Float>, decimals: Int) {
        let span = range.upperBound - range.lowerBound
        let frac = span > 0 ? Double((value - range.lowerBound) / span) : 0
        hud.show("\(title)  ·  \(String(format: "%.\(decimals)f", value))", fraction: frac)
    }

    // Lists every keyboard shortcut on the HUD (also mirrored to the console).
    func showHelp() {
        AppDelegate.printHelp()
        hud.showList(AppDelegate.helpText)
    }

    // Thin @objc wrappers so the Controls menu triggers the same actions.
    @objc private func ctlNextMode(_ s: Any?) { performNextMode() }
    @objc private func ctlNextPalette(_ s: Any?) { performNextPalette() }
    @objc private func ctlPrevPalette(_ s: Any?) { performPrevPalette() }
    @objc private func ctlToggleColorCycle(_ s: Any?) { performToggleColorCycle() }
    @objc private func ctlNextStyle(_ s: Any?) { performNextStyle() }
    @objc private func ctlPrevStyle(_ s: Any?) { performPrevStyle() }
    @objc private func ctlAmpUp(_ s: Any?) { performAmp(0.1) }
    @objc private func ctlAmpDown(_ s: Any?) { performAmp(-0.1) }
    @objc private func ctlDecayUp(_ s: Any?) { performDecay(0.005) }
    @objc private func ctlDecayDown(_ s: Any?) { performDecay(-0.005) }
    @objc private func ctlIntensityUp(_ s: Any?) { performIntensity(0.1) }
    @objc private func ctlIntensityDown(_ s: Any?) { performIntensity(-0.1) }
    @objc private func ctlSwirlUp(_ s: Any?) { performSwirl(0.25) }
    @objc private func ctlSwirlDown(_ s: Any?) { performSwirl(-0.25) }
    @objc private func ctlToggleSource(_ s: Any?) { performToggleSource() }
    @objc private func ctlHelp(_ s: Any?) { showHelp() }

    private func rebuildSourceMenu() {
        guard let menu = sourceMenu else { return }
        menu.removeAllItems()

        let sys = NSMenuItem(title: "All System Audio",
                             action: #selector(selectSystemSource(_:)), keyEquivalent: "")
        sys.target = self
        sys.state = (currentSource === systemSource) ? .on : .off
        menu.addItem(sys)

        let mic = NSMenuItem(title: "Microphone",
                             action: #selector(selectMicSource(_:)), keyEquivalent: "")
        mic.target = self
        mic.state = (currentSource === micSource) ? .on : .off
        menu.addItem(mic)

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Applications", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let excluded = Bundle.main.bundleIdentifier ?? "ink.qualified.cthugha"
        let apps = ProcessAudio.listAudioApps(excludingBundleID: excluded)
        if apps.isEmpty {
            let hint = NSMenuItem(title: "Play audio in an app to list it here",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        } else {
            let activeBundle = (currentSource as? ProcessTapAudioSource)?.bundleID
            for app in apps {
                let item = NSMenuItem(title: app.name,
                                      action: #selector(selectAppSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app
                item.state = (app.bundleID == activeBundle) ? .on : .off
                menu.addItem(item)
            }
        }
    }

    @objc private func toggleStartFullScreenPreset(_ sender: NSMenuItem) {
        let newValue = !UserDefaults.standard.bool(forKey: startFullScreenKey)
        UserDefaults.standard.set(newValue, forKey: startFullScreenKey)
        sender.state = newValue ? .on : .off
    }

    static let helpText = """
    Keyboard shortcuts
    ──────────────────
    space / m      Next motion mode
    p              Next palette
    ← ↓  /  → ↑    Previous / next palette
    v / ⇧v         Next / previous style
    c              Toggle colour cycling
    i              Toggle audio source
    + / −          Wave amplitude
    , / .          Feedback decay
    [ / ]          Intensity
    9 / 0          Swirl strength
    f              Toggle full screen (or double-click the window)
    esc            Leave full screen
    h              Show this list
    """

    static func printHelp() {
        NSLog("Cthugha controls:\n%@", helpText)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        currentSource?.stop()
        nowPlaying.stop()
    }
}

// Container that keeps the Metal view full-bleed and pins the now-playing
// overlay to the bottom-left.
final class RootView: NSView {
    weak var metalView: NSView?
    weak var overlay: NowPlayingOverlay?
    weak var hud: HUDOverlay?

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        metalView?.frame = bounds
        if let overlay {
            let s = overlay.intrinsicContentSize
            let w = min(s.width, bounds.width - 40)
            overlay.frame = NSRect(x: 20, y: 20, width: max(w, 0), height: s.height)
        }
        if let hud {
            let s = hud.intrinsicContentSize
            let w = min(s.width, bounds.width - 80)
            let x = (bounds.width - w) / 2
            let y = bounds.height * 0.17
            hud.frame = NSRect(x: x, y: y, width: max(w, 0), height: s.height)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
