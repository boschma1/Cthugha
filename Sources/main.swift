import Cocoa
import MetalKit

// MTKView subclass that owns keyboard controls.
final class CthughaView: MTKView {
    weak var renderer: Renderer?
    weak var appDelegate: AppDelegate?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let renderer else { return }

        // Arrow keys cycle the colour palette (left/down = previous, right/up = next).
        switch event.keyCode {
        case 123, 125: // left, down
            renderer.prevPalette()
            appDelegate?.updateTitle()
            return
        case 124, 126: // right, up
            renderer.nextPalette()
            appDelegate?.updateTitle()
            return
        default:
            break
        }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch chars {
        case "f":
            window?.toggleFullScreen(nil)
        case " ", "m":
            renderer.nextMode()
        case "p":
            renderer.nextPalette()
        case "c":
            renderer.toggleColorCycle()
        case "i":
            appDelegate?.toggleAudioSource()
        case "v":
            if event.modifierFlags.contains(.shift) { renderer.prevStyle() }
            else { renderer.nextStyle() }
            appDelegate?.refreshStyleMenu()
        case "=", "+":
            renderer.changeWaveAmp(0.1)
        case "-", "_":
            renderer.changeWaveAmp(-0.1)
        case ".", ">":
            renderer.changeDecay(0.005)
        case ",", "<":
            renderer.changeDecay(-0.005)
        case "]":
            renderer.changeIntensity(0.1)
        case "[":
            renderer.changeIntensity(-0.1)
        case ")", "0":
            renderer.changeSwirl(0.25)
        case "(", "9":
            renderer.changeSwirl(-0.25)
        case "h":
            AppDelegate.printHelp()
        case "\u{1b}": // esc leaves full screen
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        default:
            break
        }
        appDelegate?.updateTitle()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var rootView: RootView!
    private var overlay: NowPlayingOverlay!
    private var view: CthughaView!
    private var renderer: Renderer!
    private let store = WaveformStore()
    private let nowPlaying = NowPlayingMonitor()

    private var systemSource: SystemAudioSource!
    private var micSource: MicAudioSource!
    private var currentSource: AudioSource?
    private var systemRetryTimer: Timer?

    private let startFullScreenKey = "StartFullScreen"
    private var startFullScreenItem: NSMenuItem?
    private var sourceMenu: NSMenu?
    private var styleMenu: NSMenu?

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
        rootView = RootView(frame: rect)
        rootView.metalView = view
        rootView.overlay = overlay
        rootView.addSubview(view)
        rootView.addSubview(overlay)

        window.contentView = rootView
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        // Full-screen preset: --fullscreen flag or a saved preference.
        let wantFullScreen = CommandLine.arguments.contains("--fullscreen")
            || UserDefaults.standard.bool(forKey: startFullScreenKey)
        if wantFullScreen {
            DispatchQueue.main.async { [weak self] in self?.window.toggleFullScreen(nil) }
        }

        systemSource = SystemAudioSource(store: store)
        micSource = MicAudioSource(store: store)
        AppDelegate.printHelp()
        startSystemAudio()
        updateTitle()

        // Now-playing overlay (Spotify / Apple Music).
        nowPlaying.onChange = { [weak self] info in
            self?.overlay.update(info)
            self?.rootView.needsLayout = true
        }
        nowPlaying.start()
    }

    // MARK: - Audio management

    private func startSystemAudio() {
        Task { @MainActor in
            do {
                try await systemSource.start()
                micSource.stop()
                currentSource = systemSource
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
    private func startMic() async {
        do {
            try await micSource.start()
            currentSource = micSource
        } catch {
            NSLog("Cthugha: microphone unavailable: \(error.localizedDescription)")
            currentSource = nil
        }
        updateTitle()
    }

    func toggleAudioSource() {
        // Manual switch takes over from the automatic retry.
        systemRetryTimer?.invalidate(); systemRetryTimer = nil
        currentSource?.stop()
        Task { @MainActor in
            if currentSource === systemSource {
                await startMic()
            } else {
                startSystemAudio()
            }
        }
    }

    // MARK: - Source selection (menu)

    @objc private func selectSystemSource(_ sender: Any?) {
        systemRetryTimer?.invalidate(); systemRetryTimer = nil
        currentSource?.stop()
        startSystemAudio()
    }

    @objc private func selectMicSource(_ sender: Any?) {
        systemRetryTimer?.invalidate(); systemRetryTimer = nil
        let old = currentSource
        Task { @MainActor in
            old?.stop()
            await startMic()
        }
    }

    @objc private func selectAppSource(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AudioApp else { return }
        systemRetryTimer?.invalidate(); systemRetryTimer = nil
        let old = currentSource
        let newSource = ProcessTapAudioSource(app: app, store: store)
        Task { @MainActor in
            old?.stop()
            do {
                try await newSource.start()
                currentSource = newSource
                NSLog("Cthugha: capturing \(newSource.name).")
                updateTitle()
            } catch {
                NSLog("Cthugha: \(newSource.name) capture failed: \(error.localizedDescription); " +
                      "falling back to system audio.")
                startSystemAudio()
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
        renderer.setStyle(i)
        updateTitle()
        rebuildStyleMenu()
    }

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

    static func printHelp() {
        NSLog("""
        Cthugha controls:
          space / m : next motion mode      p : next palette
          ← ↓ / → ↑  : previous / next colour palette
          v / ⇧v    : next / previous style  (Current, Solar Flare, Oil Shimmer,
                                               Metallic Lightning, Blue Fire)
          c         : toggle colour cycling i : toggle audio source (system/mic)
          + / -     : wave amplitude        , / . : feedback decay
          [ / ]     : intensity             9 / 0 : swirl strength
          f         : full screen           esc : leave full screen   h : help
          Source menu : pick a specific app (Spotify, Music, a browser…) to visualise
          Style menu  : jump straight to a look preset
        """)
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

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        metalView?.frame = bounds
        if let overlay {
            let s = overlay.intrinsicContentSize
            let w = min(s.width, bounds.width - 40)
            overlay.frame = NSRect(x: 20, y: 20, width: max(w, 0), height: s.height)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
