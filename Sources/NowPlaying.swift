import AppKit

struct TrackInfo: Equatable {
    let app: String     // "Spotify" or "Music"
    let title: String
    let artist: String
    let playing: Bool
}

// Polls Spotify / Apple Music for the current track via AppleScript. Only
// queries apps that are already running (never launches them). The first query
// triggers macOS Automation (Apple Events) permission for that app.
final class NowPlayingMonitor {
    var onChange: ((TrackInfo?) -> Void)?
    private var timer: Timer?
    private var lastKey = "<init>"

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func isRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    private func poll() {
        let info = query(app: "Spotify", bundleId: "com.spotify.client")
            ?? query(app: "Music", bundleId: "com.apple.Music")
        let key = info.map { "\($0.app)|\($0.title)|\($0.artist)|\($0.playing)" } ?? ""
        if key != lastKey {
            lastKey = key
            onChange?(info)
        }
    }

    private func query(app: String, bundleId: String) -> TrackInfo? {
        guard isRunning(bundleId) else { return nil }
        let source = """
        tell application "\(app)"
            if it is running then
                set st to (player state as string)
                set tn to (name of current track)
                set ta to (artist of current track)
                return st & linefeed & tn & linefeed & ta
            end if
        end tell
        """
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&err)
        if let err {
            // -1743 = not authorized (Automation permission not granted yet).
            NSLog("Cthugha: now-playing (\(app)) unavailable: \(err[NSAppleScript.errorMessage] ?? "?")")
            return nil
        }
        let parts = (result.stringValue ?? "").components(separatedBy: "\n")
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        let playing = parts[0].lowercased().contains("playing")
        return TrackInfo(app: app, title: parts[1], artist: parts[2], playing: playing)
    }
}
