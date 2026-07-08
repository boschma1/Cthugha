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

// A centred heads-up display that briefly flashes the setting a control just
// changed (like the macOS volume HUD) and fades out. Continuous values also get
// a level bar. Layer-backed so it composites cleanly over the Metal view.
final class HUDOverlay: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let barBG = NSView()
    private let barFill = NSView()
    private var hideTimer: Timer?
    private var fillWidth: NSLayoutConstraint!
    private var titleCenterY: NSLayoutConstraint!
    private var showsBar = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        barBG.wantsLayer = true
        barBG.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.20).cgColor
        barBG.layer?.cornerRadius = 2.5
        barBG.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barBG)

        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = NSColor.white.cgColor
        barFill.layer?.cornerRadius = 2.5
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barBG.addSubview(barFill)

        titleCenterY = titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        fillWidth = barFill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            titleCenterY,
            barBG.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            barBG.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            barBG.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            barBG.heightAnchor.constraint(equalToConstant: 5),
            barFill.leadingAnchor.constraint(equalTo: barBG.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barBG.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barBG.bottomAnchor),
            fillWidth
        ])

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        titleLabel.shadow = shadow

        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    private var listMode = false

    override var intrinsicContentSize: NSSize {
        let s = titleLabel.intrinsicContentSize
        if listMode {
            return NSSize(width: s.width + 56, height: s.height + 40)
        }
        return NSSize(width: max(s.width + 64, 240), height: showsBar ? 88 : 58)
    }

    // A brief, single-line flash. fraction == nil → text only; otherwise a 0…1 bar.
    func show(_ text: String, fraction: Double?) {
        configureFlash()
        titleLabel.stringValue = text
        showsBar = fraction != nil
        barBG.isHidden = !showsBar
        titleCenterY.constant = showsBar ? -14 : 0
        relayout()
        if let f = fraction {
            let clamped = CGFloat(max(0, min(1, f)))
            fillWidth.constant = max(barBG.bounds.width, 0) * clamped
            layoutSubtreeIfNeeded()
        }
        present(after: 1.1)
    }

    // A multi-line panel (used for the keyboard-shortcut list) that lingers longer.
    func showList(_ text: String) {
        listMode = true
        showsBar = false
        barBG.isHidden = true
        titleLabel.alignment = .left
        titleLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        titleLabel.maximumNumberOfLines = 0
        titleCenterY.constant = 0
        titleLabel.stringValue = text
        relayout()
        present(after: 6.0)
    }

    private func configureFlash() {
        listMode = false
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        titleLabel.maximumNumberOfLines = 1
    }

    private func relayout() {
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
    }

    private func present(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.5
                self?.animator().alphaValue = 0
            }
        }
    }
}
