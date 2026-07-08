import AppKit

// A subtle rounded pill in the bottom-left showing the current track. Layer-backed
// so it composites cleanly over the Metal view. Fades out when nothing is playing.
final class NowPlayingOverlay: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.45).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        label.shadow = shadow

        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = label.intrinsicContentSize
        return NSSize(width: s.width + 28, height: 36)
    }

    func update(_ info: TrackInfo?) {
        hideTimer?.invalidate()
        guard let info else {
            fadeOut()
            return
        }
        let mark = info.playing ? "♪" : "❚❚"
        let artist = info.artist.isEmpty ? "" : "\(info.artist) — "
        label.stringValue = "\(mark)  \(artist)\(info.title)"
        invalidateIntrinsicContentSize()
        needsLayout = true
        fadeIn()
        // Auto-dim after a while if paused; keep visible while playing.
        if !info.playing {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                self?.fadeOut()
            }
        }
    }

    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.35
            animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.6
            animator().alphaValue = 0
        }
    }
}
