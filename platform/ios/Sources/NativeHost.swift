import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - iOS 15 compatibility
//
// The deployment target is iOS 15.0 so that TrollStore devices (iOS 14.0-17.0)
// are covered as well as StikDebug ones (17.4+). Anything newer than iOS 15
// has to sit behind `#available`, including types such as `NavigationStack`
// that would otherwise fail to resolve at all.

/// `NavigationStack` on iOS 16+, `NavigationView` in stack style on iOS 15.
private struct TouchHLENavigationContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(root: content)
        } else {
            NavigationView(content: content)
                // Without this iPads get the split-view presentation, which
                // this UI is not laid out for.
                .navigationViewStyle(.stack)
        }
    }
}

/// `ContentUnavailableView` on iOS 17+, a hand-rolled equivalent below it.
private struct TouchHLEEmptyState: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }
}

extension View {
    /// `onChange(of:)` without tripping the iOS 17 two-parameter signature,
    /// which does not exist on iOS 15 or 16.
    @ViewBuilder
    func touchHLEOnChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

/// Interface and device orientations are mirrored for the landscape cases.
private func touchHLEDeviceOrientation(
    for mask: UIInterfaceOrientationMask
) -> UIDeviceOrientation? {
    if mask.contains(.landscapeLeft) {
        return .landscapeRight
    }
    if mask.contains(.landscapeRight) {
        return .landscapeLeft
    }
    if mask.contains(.portrait) {
        return .portrait
    }
    return nil
}

/// Ask UIKit to rotate. On iOS 16+ that is `requestGeometryUpdate` plus
/// `setNeedsUpdateOfSupportedInterfaceOrientations`. Neither exists on iOS 15,
/// where the only lever is the device orientation UIKit follows, so set that
/// and re-ask UIKit to rotate.
@MainActor
private func touchHLEApplyOrientation(
    _ mask: UIInterfaceOrientationMask,
    viewController: UIViewController?,
    scene: UIWindowScene?
) {
    if #available(iOS 16.0, *) {
        viewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    } else {
        // `UIDevice.orientation` is read-only in the public API, but UIKit
        // backs it with a settable property, and driving it is the only way to
        // start a rotation before iOS 16. `responds(to:)` keeps this a no-op
        // rather than a crash if that ever stops being true.
        let device = UIDevice.current
        if let deviceOrientation = touchHLEDeviceOrientation(for: mask),
           device.responds(to: NSSelectorFromString("setOrientation:")) {
            device.setValue(deviceOrientation.rawValue, forKey: "orientation")
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

/// Values stored in the "orientation" setting. These are the user's choice, not
/// the guest orientation codes the emulator takes — `launchOrientation` maps
/// between them.
private enum OrientationSetting {
    static let automatic = 0
    static let landscapeLeft = 1
    static let landscapeRight = 2
    // 3 is skipped on purpose: the emulator maps that one to --upside-down.
    static let portrait = 4
}

/// Gamevil titles that really are portrait games, despite the family-wide
/// landscape policy in `launchOrientation`. Mirrors
/// `PORTRAIT_ONLY_GAMEVIL_BUNDLES` in `src/bundle.rs`; keep the two in step.
///
/// Lowercased for comparison, because Gamevil were not consistent about the
/// casing of their identifiers.
private let portraitOnlyGamevilBundles: Set<String> = ["com.gamevil.airpenguin"]

private struct GameFile: Identifiable {
    let url: URL
    let displayName: String
    let bundleIdentifier: String?
    let orientationCapabilities: UInt32
    let icon: UIImage?

    var id: String { url.path }

    func launchOrientation(
        override orientation: Int,
        currentInterfaceOrientation: UIInterfaceOrientation
    ) -> Int {
        let supportsPortrait = orientationCapabilities & 1 != 0
        let supportsLandscape = orientationCapabilities & 2 != 0
        // An explicit landscape or portrait choice overrides what the device is
        // doing, but never what a single-orientation bundle declares.
        let isExplicitLandscape = orientation == OrientationSetting.landscapeLeft
            || orientation == OrientationSetting.landscapeRight
        let isExplicitPortrait = orientation == OrientationSetting.portrait

        // Air Penguin is the exception to the rule below: a genuine portrait
        // game, played by tilting a tall screen rather than turning it. Neither
        // a saved landscape setting nor the device's current rotation may start
        // it sideways.
        if let bundleID = bundleIdentifier,
           portraitOnlyGamevilBundles.contains(bundleID.lowercased()) {
            return 0
        }

        // Gamevil's legacy engines render through landscape OpenGL surfaces.
        // Do not allow a saved portrait setting or an inaccurate Info.plist to
        // start the host in a portrait geometry.
        if bundleIdentifier?.hasPrefix("com.gamevil.") == true {
            return isExplicitLandscape ? orientation : OrientationSetting.landscapeLeft
        }

        if supportsPortrait && !supportsLandscape {
            return 0
        }
        if supportsLandscape && !supportsPortrait {
            if isExplicitLandscape {
                return orientation
            }
            // Some games advertise landscape but render portrait anyway —
            // Sword of Fargoal builds a 320x480 view — so allow forcing it.
            if isExplicitPortrait {
                return 0
            }
            return currentInterfaceOrientation == .landscapeRight ? 2 : 1
        }
        if isExplicitLandscape {
            return orientation
        }
        if isExplicitPortrait {
            return 0
        }
        switch currentInterfaceOrientation {
        case .landscapeLeft:
            return 1
        case .landscapeRight:
            return 2
        default:
            return 0
        }
    }
}

/// A launch held back because JIT is not enabled, kept so it can be started
/// unchanged if the user goes ahead anyway.
private struct HeldLaunch: Identifiable {
    let game: GameFile
    let scaleHack: Int
    let orientation: Int
    let networkAccess: Bool
    let analogTilt: Bool

    var id: String { game.id }
}

@MainActor
private final class GameLibrary: ObservableObject {
    @Published var games: [GameFile] = []
    @Published var importError: String?
    @Published var launchError: String?
    @Published var heldLaunch: HeldLaunch?
    @Published var isLaunching = false

    let appsDirectory: URL

    /// The core used to read game metadata. Whichever core will actually run a
    /// game is loaded when it starts. If the default core cannot be loaded, any
    /// other core reports the same things, and a library with names and icons
    /// beats one without.
    private var metadataCore: EmulatorCore? {
        let preferred = CoreSelection.defaultKind
        if let core = try? EmulatorCore.load(preferred) {
            return core
        }
        return CoreKind.installed
            .filter { $0 != preferred }
            .lazy
            .compactMap { try? EmulatorCore.load($0) }
            .first
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        appsDirectory = documents.appendingPathComponent("touchHLE_apps", isDirectory: true)
        migrateLegacyNetworkSetting(in: documents)
        reload()
    }

    func reload() {
        do {
            try FileManager.default.createDirectory(
                at: appsDirectory,
                withIntermediateDirectories: true
            )
            games = try FileManager.default.contentsOfDirectory(
                at: appsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { ["ipa", "app", "z3pkg"].contains($0.pathExtension.lowercased()) }
            .map(gameFile(from:))
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    func importGame(from sourceURL: URL) {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: appsDirectory,
                withIntermediateDirectories: true
            )
            let destinationURL = uniqueDestination(for: sourceURL.lastPathComponent)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            reload()
        } catch {
            importError = error.localizedDescription
        }
    }

    func delete(_ game: GameFile) {
        do {
            try FileManager.default.removeItem(at: game.url)
            reload()
        } catch {
            importError = error.localizedDescription
        }
    }

    /// The game a Home Screen icon is asking for.
    ///
    /// The file name is what the link was built from and is unique within the
    /// library. The guest bundle identifier is a fallback for a game that has
    /// been re-imported since, and so is sitting under a slightly different
    /// name than the icon remembers.
    func game(matching target: GameLink.Target) -> GameFile? {
        if let fileName = target.fileName,
           let match = games.first(where: { $0.url.lastPathComponent == fileName }) {
            return match
        }

        guard let bundleIdentifier = target.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        return games.first {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    /// The game an exported standalone app carries. Read through the same
    /// metadata path as the library, so it gets its icon and its declared
    /// orientations rather than only what was written into the export.
    func bundledGameFile(_ bundled: BundledGame) -> GameFile {
        gameFile(from: bundled.url)
    }

    func launch(
        _ game: GameFile,
        scaleHack: Int,
        orientation: Int,
        networkAccess: Bool,
        analogTilt: Bool
    ) {
        guard touchhle_ios_jit_available() else {
            heldLaunch = HeldLaunch(
                game: game,
                scaleHack: scaleHack,
                orientation: orientation,
                networkAccess: networkAccess,
                analogTilt: analogTilt
            )
            return
        }

        start(
            game,
            scaleHack: scaleHack,
            orientation: orientation,
            networkAccess: networkAccess,
            analogTilt: analogTilt
        )
    }

    func start(_ held: HeldLaunch) {
        start(
            held.game,
            scaleHack: held.scaleHack,
            orientation: held.orientation,
            networkAccess: held.networkAccess,
            analogTilt: held.analogTilt
        )
    }

    private func start(
        _ game: GameFile,
        scaleHack: Int,
        orientation: Int,
        networkAccess: Bool,
        analogTilt: Bool
    ) {
        let core: EmulatorCore
        do {
            core = try EmulatorCore.load(
                CoreSelection.kind(forBundleIdentifier: game.bundleIdentifier)
            )
        } catch {
            launchError = error.localizedDescription
            return
        }

        isLaunching = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let launchOrientation = game.launchOrientation(
                override: orientation,
                currentInterfaceOrientation: TouchHLENativeHost.currentInterfaceOrientation
            )
            TouchHLENativeHost.hideHostWindow()
            TouchHLENativeHost.prepareGameControls(
                launchOrientation: launchOrientation
            ) { [weak self] in
                guard let self else { return }
                let result = EmulatorCore.withRunning(core) {
                    game.url.path.withCString { path in
                        touchhle_ios_launch_game(
                            core.runGame,
                            path,
                            Int32(scaleHack),
                            Int32(launchOrientation),
                            networkAccess ? 1 : 0,
                            analogTilt ? 1 : 0
                        )
                    }
                }

                TouchHLENativeHost.hideGameControls()
                TouchHLENativeHost.restoreHostWindow()
                self.isLaunching = false
                if result != 0 {
                    self.launchError = "\(core.kind.displayName) could not start this game. The diagnostic log has been saved in Files."
                }
            }
        }
    }

    private func uniqueDestination(for fileName: String) -> URL {
        let original = appsDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: original.path) else {
            return original
        }

        let source = URL(fileURLWithPath: fileName)
        let stem = source.deletingPathExtension().lastPathComponent
        let fileExtension = source.pathExtension
        var index = 2

        while true {
            let candidateName = fileExtension.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(fileExtension)"
            let candidate = appsDirectory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func gameFile(from url: URL) -> GameFile {
        let fallbackName = url.deletingPathExtension().lastPathComponent
        // Reading a game's name, icon and orientations does not run it, and the
        // cores all report the same things, so the default core does this for
        // the whole library rather than loading every core up front.
        guard let core = metadataCore,
              let metadata = url.path.withCString({ core.metadataCreate($0) })
        else {
            return GameFile(
                url: url,
                displayName: fallbackName,
                bundleIdentifier: nil,
                orientationCapabilities: 1,
                icon: nil
            )
        }
        defer { core.metadataFree(metadata) }

        let metadataDisplayName = core.metadataDisplayName(metadata)
            .map { String(cString: $0) } ?? fallbackName
        let displayName = preferredDisplayName(
            metadataName: metadataDisplayName,
            fallbackName: fallbackName
        )
        let bundleIdentifier = core.metadataBundleIdentifier(metadata)
            .map { String(cString: $0) }
        let orientationCapabilities = core.metadataOrientationCapabilities(metadata)

        return GameFile(
            url: url,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            orientationCapabilities: orientationCapabilities,
            icon: gameIcon(from: metadata, core: core)
        )
    }

    private func preferredDisplayName(metadataName: String, fallbackName: String) -> String {
        let metadataIsAbbreviated = metadataName.contains("...") || metadataName.contains("…")
        let fallbackIsComplete = !fallbackName.contains("...") && !fallbackName.contains("…")
        guard metadataIsAbbreviated, fallbackIsComplete else { return metadataName }

        return fallbackName.replacingOccurrences(of: "_", with: " ")
    }

    private func gameIcon(from metadata: OpaquePointer, core: EmulatorCore) -> UIImage? {
        let width = Int(core.metadataIconWidth(metadata))
        let height = Int(core.metadataIconHeight(metadata))
        guard width > 0,
              height > 0,
              let pixels = core.metadataIconRGBA(metadata)
        else {
            return nil
        }

        let data = Data(bytes: pixels, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    .byteOrder32Big
                ],
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else {
            return nil
        }

        return UIImage(cgImage: image)
    }

    private func migrateLegacyNetworkSetting(in documents: URL) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "networkAccess") == nil else { return }

        let legacyURL = documents.appendingPathComponent(".touchHLE_network_access")
        guard let value = try? String(contentsOf: legacyURL, encoding: .utf8) else { return }
        defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines) == "enabled", forKey: "networkAccess")
    }
}

private final class GameControlsWindow: UIWindow {
    // Only `hitTest` may be overridden here. Overriding `point(inside:)` on a
    // UIWindow also changes how UIKit picks which window an event belongs to,
    // which stops *every* window in the scene (including the SDL game window)
    // from receiving touches. Letting `super.hitTest` do the work and merely
    // filtering the result keeps the pass-through behaviour without that.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hitView = super.hitTest(point, with: event) else {
            return nil
        }
        // Which view is live changes over time — the exit handle normally, the
        // confirmation panel while that is up — so ask the controller instead
        // of caching a view here. A stale reference in this window silently
        // swallows every touch, which is exactly how the first attempt at the
        // confirmation dialog ended up unusable.
        guard let controls = rootViewController as? GameControlsViewController,
              controls.shouldDeliverTouch(to: hitView)
        else {
            return nil
        }
        return hitView
    }
}

private final class GameControlsViewController: UIViewController {
    var allowedOrientations: UIInterfaceOrientationMask = .portrait
    var onExit: (() -> Void)?

    // MARK: - Exit handle
    //
    // The exit button used to sit fully visible in the top-right corner, where
    // it covered the game's own UI and a stray tap dropped you straight back to
    // the library. It now rests as a sliver against the trailing edge: only
    // `handleSize - retractedInset` points of it are on screen, it has to be
    // dragged out before a tap does anything, and that tap then asks for
    // confirmation. Dragging also moves it vertically, so it can be parked
    // clear of whatever the game draws in that corner; the position is
    // remembered across launches.

    private static let handleSize: CGFloat = 48
    /// How far the button hangs off the trailing edge when it is put away.
    private static let retractedInset: CGFloat = 34
    /// Margin between the button and the trailing edge once it is pulled out.
    private static let revealedInset: CGFloat = -16
    private static var handleTravel: CGFloat { retractedInset - revealedInset }
    /// Fraction of `handleTravel` the button must be dragged to stay out.
    private static let revealFraction: CGFloat = 0.5
    private static let retractedAlpha: CGFloat = 0.4
    /// Idle time after which a revealed button puts itself away again.
    private static let autoRetractDelay: TimeInterval = 5
    private static let verticalOffsetKey = "exitHandleVerticalOffset"
    private static let defaultVerticalOffset: CGFloat = 10

    private static var storedVerticalOffset: CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: verticalOffsetKey) != nil else {
            return defaultVerticalOffset
        }
        return CGFloat(defaults.double(forKey: verticalOffsetKey))
    }

    private var handleTrailingConstraint: NSLayoutConstraint!
    private var handleTopConstraint: NSLayoutConstraint!
    private var isRevealed = true
    private var panStartInset: CGFloat = 0
    private var panStartOffset: CGFloat = 0
    private var retractTimer: Timer?

    private(set) lazy var exitButton: UIButton = {
        let button = UIButton(type: .system)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
        }
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .bold)
        configuration.image = UIImage(
            systemName: "rectangle.portrait.and.arrow.right",
            withConfiguration: symbolConfiguration
        )?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .systemRed
        button.configuration = configuration
        button.tintColor = .systemRed
        button.accessibilityLabel = "Exit Game"
        button.accessibilityHint =
            "Drag away from the edge of the screen, then tap and confirm to stop the game"
        button.addTarget(self, action: #selector(exitButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        )
        return button
    }()

    private lazy var fpsIndicator: UIButton = {
        let indicator = UIButton(type: .system)
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
        }
        configuration.title = "— FPS"
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .systemYellow
        indicator.configuration = configuration
        indicator.isUserInteractionEnabled = false
        indicator.accessibilityLabel = "Frame rate"
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private var fpsTimer: Timer?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        allowedOrientations
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(exitButton)

        handleTrailingConstraint = exitButton.trailingAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: Self.revealedInset
        )
        handleTopConstraint = exitButton.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor,
            constant: Self.storedVerticalOffset
        )
        NSLayoutConstraint.activate([
            handleTopConstraint,
            handleTrailingConstraint,
            exitButton.widthAnchor.constraint(equalToConstant: Self.handleSize),
            exitButton.heightAnchor.constraint(equalToConstant: Self.handleSize)
        ])

        // Start out visible so the control is discoverable, then put itself
        // away once the player has had a chance to see it.
        scheduleAutoRetract()

        guard UserDefaults.standard.bool(forKey: "showFPSOverlay") else { return }

        view.addSubview(fpsIndicator)
        // Anchored independently of the exit handle: the handle moves when it
        // is dragged, and the FPS pill dragging along with it would be odd.
        // The trailing inset keeps it clear of the retracted handle's sliver.
        NSLayoutConstraint.activate([
            fpsIndicator.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Self.defaultVerticalOffset
            ),
            fpsIndicator.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -(Self.handleSize - Self.retractedInset) - 10
            ),
            fpsIndicator.heightAnchor.constraint(equalToConstant: Self.handleSize)
        ])

        updateFPS()
        fpsTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(updateFPS),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(fpsTimer!, forMode: .common)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A rotation or a safe-area change can leave a remembered offset
        // pointing off the bottom of the screen.
        let clamped = clampedVerticalOffset(handleTopConstraint.constant)
        if clamped != handleTopConstraint.constant {
            handleTopConstraint.constant = clamped
        }
    }

    deinit {
        fpsTimer?.invalidate()
        retractTimer?.invalidate()
    }

    // MARK: Handle interaction

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            cancelAutoRetract()
            panStartInset = handleTrailingConstraint.constant
            panStartOffset = handleTopConstraint.constant
        case .changed:
            let inset = min(
                Self.retractedInset,
                max(Self.revealedInset, panStartInset + translation.x)
            )
            handleTrailingConstraint.constant = inset
            handleTopConstraint.constant = clampedVerticalOffset(panStartOffset + translation.y)
            let progress = min(max((Self.retractedInset - inset) / Self.handleTravel, 0), 1)
            exitButton.alpha = Self.retractedAlpha + (1 - Self.retractedAlpha) * progress
        case .ended, .cancelled, .failed:
            let pulledOut = Self.retractedInset - handleTrailingConstraint.constant
            setRevealed(pulledOut >= Self.handleTravel * Self.revealFraction, animated: true)
            persistVerticalOffset()
        default:
            break
        }
    }

    @objc private func exitButtonTapped() {
        // Exiting always takes a deliberate drag first: while the handle is
        // put away, a tap only pulls it out.
        guard isRevealed else {
            setRevealed(true, animated: true)
            return
        }
        presentExitConfirmation()
    }

    // MARK: Exit confirmation
    //
    // Built from plain views inside this controller's own hierarchy rather than
    // with UIAlertController. The alert did show up, but none of its buttons
    // ever responded: UIKit presents it into a transition view that is not a
    // descendant of anything `GameControlsWindow.hitTest` recognises, and the
    // run loop only turns once per frame, which is a poor place to rely on
    // UIKit's presentation machinery. The exit handle works in exactly this
    // hierarchy, so the confirmation panel lives here too.

    private(set) var isShowingExitConfirmation = false

    private lazy var confirmationOverlay: UIView = {
        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        overlay.alpha = 0

        let panel = UIView()
        panel.backgroundColor = .secondarySystemBackground
        panel.layer.cornerRadius = 16
        panel.layer.cornerCurve = .continuous
        panel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(panel)

        let title = UILabel()
        title.text = "Exit Game?"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label
        title.textAlignment = .center
        title.numberOfLines = 0
        title.translatesAutoresizingMaskIntoConstraints = false

        let message = UILabel()
        message.text = "The game will stop and you will return to your library. "
            + "Anything it has not saved yet will be lost."
        message.font = .preferredFont(forTextStyle: .footnote)
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 0
        message.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            title,
            message,
            self.confirmationButton(
                title: "Keep Playing",
                tint: .label,
                action: #selector(keepPlayingTapped)
            ),
            self.confirmationButton(
                title: "Exit Game",
                tint: .systemRed,
                action: #selector(confirmExitTapped)
            )
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(20, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        // High priority rather than required, so the two safe-area margins
        // below win on a narrow screen instead of breaking.
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 300)
        preferredWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            preferredWidth,
            panel.leadingAnchor.constraint(
                greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor,
                constant: 24
            ),
            panel.trailingAnchor.constraint(
                lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor,
                constant: -24
            ),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20)
        ])
        return overlay
    }()

    private func confirmationButton(title: String, tint: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var configuration: UIButton.Configuration = .gray()
        configuration.title = title
        configuration.cornerStyle = .large
        configuration.baseForegroundColor = tint
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return button
    }

    private func presentExitConfirmation() {
        guard !isShowingExitConfirmation else { return }
        cancelAutoRetract()
        isShowingExitConfirmation = true

        let overlay = confirmationOverlay
        // Autoresizing rather than constraints: the overlay is added and
        // removed repeatedly, and a frame that follows `view.bounds` needs no
        // constraints to be torn down and rebuilt each time.
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        view.layoutIfNeeded()

        UIView.animate(withDuration: 0.2) {
            overlay.alpha = 1
        }
    }

    private func hideExitConfirmation() {
        guard isShowingExitConfirmation else { return }
        isShowingExitConfirmation = false

        let overlay = confirmationOverlay
        UIView.animate(
            withDuration: 0.2,
            animations: { overlay.alpha = 0 },
            // Guarded in case the panel was brought back up while the fade was
            // still running, which would otherwise tear down the live overlay.
            completion: { [weak self] _ in
                guard self?.isShowingExitConfirmation != true else { return }
                overlay.removeFromSuperview()
            }
        )
    }

    @objc private func keepPlayingTapped() {
        hideExitConfirmation()
        setRevealed(false, animated: true)
    }

    @objc private func confirmExitTapped() {
        // Torn down without the fade: the game is about to stop, and the
        // animation's completion block would need another run loop turn that
        // the emulator may no longer be around to provide.
        isShowingExitConfirmation = false
        confirmationOverlay.removeFromSuperview()
        exitButton.isEnabled = false
        onExit?()
    }

    /// Which touches `GameControlsWindow` should keep for UIKit instead of
    /// passing through to the game underneath.
    func shouldDeliverTouch(to hitView: UIView) -> Bool {
        // The flag is checked first so a stray touch never instantiates the
        // lazy overlay just to compare against it.
        if isShowingExitConfirmation {
            return hitView === confirmationOverlay
                || hitView.isDescendant(of: confirmationOverlay)
        }
        return hitView === exitButton || hitView.isDescendant(of: exitButton)
    }

    private func setRevealed(_ revealed: Bool, animated: Bool) {
        isRevealed = revealed
        handleTrailingConstraint.constant = revealed ? Self.revealedInset : Self.retractedInset

        let apply = {
            self.exitButton.alpha = revealed ? 1 : Self.retractedAlpha
            self.view.layoutIfNeeded()
        }
        if animated {
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: apply
            )
        } else {
            apply()
        }

        if revealed {
            scheduleAutoRetract()
        } else {
            cancelAutoRetract()
        }
    }

    private func scheduleAutoRetract() {
        cancelAutoRetract()
        let timer = Timer(timeInterval: Self.autoRetractDelay, repeats: false) { [weak self] _ in
            guard let self, !self.isShowingExitConfirmation else { return }
            self.setRevealed(false, animated: true)
        }
        // The emulator owns the main thread and only lets the run loop turn
        // once per frame via SDL's event pump, so the timer has to be in the
        // common modes to fire while the game is running.
        RunLoop.main.add(timer, forMode: .common)
        retractTimer = timer
    }

    private func cancelAutoRetract() {
        retractTimer?.invalidate()
        retractTimer = nil
    }

    private func clampedVerticalOffset(_ offset: CGFloat) -> CGFloat {
        let available = view.safeAreaLayoutGuide.layoutFrame.height - Self.handleSize
        guard available > 0 else { return max(0, offset) }
        return min(max(0, offset), available)
    }

    private func persistVerticalOffset() {
        UserDefaults.standard.set(
            Double(handleTopConstraint.constant),
            forKey: Self.verticalOffsetKey
        )
    }

    @objc private func updateFPS() {
        let fps = EmulatorCore.running?.currentFPS() ?? 0
        fpsIndicator.configuration?.title = fps > 0 ? "\(Int(fps.rounded())) FPS" : "— FPS"
        fpsIndicator.accessibilityValue = fps > 0 ? "\(Int(fps.rounded())) frames per second" : "Unavailable"
    }
}

@objc(TouchHLENativeHost)
final class TouchHLENativeHost: NSObject {
    private static let shared = TouchHLENativeHost()
    private var window: UIWindow?
    private var gameControlsWindow: GameControlsWindow?

    @MainActor
    static var currentInterfaceOrientation: UIInterfaceOrientation {
        shared.window?.windowScene?.interfaceOrientation ?? .portrait
    }

    @MainActor
    @objc class func start() {
        shared.presentLibrary()
    }

    @MainActor
    static func restoreHostWindow() {
        guard let window = shared.window else { return }
        window.makeKeyAndVisible()
        if #available(iOS 16.0, *) {
            window.windowScene?.requestGeometryUpdate(
                .iOS(interfaceOrientations: .portrait)
            )
        }
    }

    @MainActor
    static func hideHostWindow() {
        shared.window?.isHidden = true
    }

    @MainActor
    static func prepareGameControls(
        launchOrientation: Int,
        completion: @escaping @MainActor () -> Void
    ) {
        shared.presentGameControls(
            launchOrientation: launchOrientation,
            completion: completion
        )
    }

    @MainActor
    static func hideGameControls() {
        shared.dismissGameControls()
    }

    @MainActor
    private func presentLibrary() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return
        }

        let window = UIWindow(windowScene: windowScene)
        // An app produced by "Export as Standalone App" carries exactly one
        // game and has no library to show.
        if let bundled = BundledGame.current {
            window.rootViewController = UIHostingController(
                rootView: StandaloneGameView(bundled: bundled)
            )
        } else {
            window.rootViewController = UIHostingController(rootView: LibraryView())
        }
        window.tintColor = .systemBlue
        window.makeKeyAndVisible()
        self.window = window
    }

    @MainActor
    private func presentGameControls(
        launchOrientation: Int,
        completion: @escaping @MainActor () -> Void
    ) {
        guard gameControlsWindow == nil,
              let windowScene = window?.windowScene
        else {
            completion()
            return
        }

        let controlsWindow = GameControlsWindow(windowScene: windowScene)
        controlsWindow.windowLevel = UIWindow.Level.normal + 3
        controlsWindow.accessibilityIdentifier = "touchHLE.gameControls"
        controlsWindow.backgroundColor = .clear

        let viewController = GameControlsViewController()
        let launchOrientationMask: UIInterfaceOrientationMask
        switch launchOrientation {
        case 1:
            launchOrientationMask = .landscapeLeft
        case 2:
            launchOrientationMask = .landscapeRight
        default:
            launchOrientationMask = .portrait
        }
        viewController.allowedOrientations = launchOrientationMask
        viewController.onExit = { [weak self] in
            self?.returnToLibrary()
        }

        controlsWindow.rootViewController = viewController
        viewController.loadViewIfNeeded()
        controlsWindow.isHidden = false
        gameControlsWindow = controlsWindow

        touchHLEApplyOrientation(
            launchOrientationMask,
            viewController: viewController,
            scene: windowScene
        )
        waitForGameSurface(
            windowScene: windowScene,
            orientationMask: launchOrientationMask,
            expectsLandscape: launchOrientation == 1 || launchOrientation == 2,
            remainingAttempts: 30,
            completion: completion
        )
    }

    @MainActor
    private func waitForGameSurface(
        windowScene: UIWindowScene,
        orientationMask: UIInterfaceOrientationMask,
        expectsLandscape: Bool,
        remainingAttempts: Int,
        completion: @escaping @MainActor () -> Void
    ) {
        let bounds = windowScene.coordinateSpace.bounds
        let hasExpectedShape = expectsLandscape
            ? bounds.width > bounds.height
            : bounds.height >= bounds.width
        let hasExpectedOrientation = expectsLandscape
            ? windowScene.interfaceOrientation.isLandscape
            : windowScene.interfaceOrientation.isPortrait

        if (hasExpectedShape && hasExpectedOrientation) || remainingAttempts == 0 {
            gameControlsWindow?.frame = bounds
            gameControlsWindow?.layoutIfNeeded()
            if let viewController = gameControlsWindow?.rootViewController as? GameControlsViewController {
                viewController.allowedOrientations = orientationMask
                touchHLEApplyOrientation(
                    orientationMask,
                    viewController: viewController,
                    scene: nil
                )
            }
            print(
                "touchHLE game surface ready: orientation=\(windowScene.interfaceOrientation.rawValue) " +
                "bounds=\(Int(bounds.width))x\(Int(bounds.height))"
            )
            // `interfaceOrientation` flips as soon as the rotation is applied,
            // but UIKit's scene-geometry transaction can still be in flight.
            // The emulator takes the main thread and never gives it back, so if
            // we start it mid-transition the scene never finishes rotating and
            // UIKit stops dispatching touches to every window in it — timers
            // and hit-testing keep working, which is what made this so hard to
            // see. Give the transition run-loop turns to commit first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                completion()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForGameSurface(
                windowScene: windowScene,
                orientationMask: orientationMask,
                expectsLandscape: expectsLandscape,
                remainingAttempts: remainingAttempts - 1,
                completion: completion
            )
        }
    }

    @MainActor
    private func dismissGameControls() {
        gameControlsWindow?.isHidden = true
        gameControlsWindow?.rootViewController = nil
        gameControlsWindow = nil
    }

    @MainActor
    @objc private func returnToLibrary() {
        EmulatorCore.running?.requestExit()
    }
}

private struct LibraryView: View {
    @StateObject private var library = GameLibrary()
    @StateObject private var export = GameExportModel()
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var showingAbout = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @AppStorage("scaleHack") private var scaleHack = 3
    @AppStorage("orientation") private var orientation = 0
    @AppStorage("networkAccess") private var networkAccess = false
    @AppStorage("analogTilt") private var analogTilt = true

    private static let ipaType = UTType(filenameExtension: "ipa") ?? .archive
    private static let z3pkgType = UTType(filenameExtension: "z3pkg") ?? .archive

    var body: some View {
        TouchHLENavigationContainer {
            ZStack {
                LibraryBackground()

                if library.games.isEmpty {
                    TouchHLEEmptyState(
                        title: "No Games Yet",
                        systemImage: "gamecontroller",
                        description: "Import a 32-bit iPhone game to add it to your library."
                    )
                } else {
                    grid
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingAbout = true
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    EnableJITButton()

                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Import Game", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .touchHLEImportButtonStyle()
                .padding(.bottom, 8)
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [Self.ipaType, Self.z3pkgType],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        library.importGame(from: url)
                    }
                case .failure(let error):
                    library.importError = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
            .sheet(isPresented: exportBinding) {
                GameExportSheet(model: export)
            }
            .alert("Couldn’t Import Game", isPresented: errorBinding(for: $library.importError)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.importError ?? "Unknown error")
            }
            .alert("Game Couldn’t Start", isPresented: errorBinding(for: $library.launchError)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.launchError ?? "Unknown error")
            }
            .alert(
                "JIT Isn’t Enabled",
                isPresented: heldLaunchBinding,
                presenting: library.heldLaunch
            ) { held in
                Button("Enable JIT") {
                    if let url = StikDebug.enableJITURL {
                        openURL(url)
                    }
                }
                Button("Start Anyway", role: .destructive) {
                    library.start(held)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(JITMethod.current.unavailableMessage)
            }
            .overlay {
                if library.isLaunching {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Starting game…")
                            .font(.headline)
                    }
                    .padding(24)
                    .touchHLELaunchOverlayStyle()
                }
            }
        }
        .touchHLEOnChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                library.reload()
                startPendingDeepLink()
            }
        }
        .onAppear {
            // A Home Screen icon that cold-launched the app delivered its URL
            // before SwiftUI existed, so it is waiting rather than announced.
            startPendingDeepLink()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(ApplesauceDidReceiveLaunchURLNotification)
            )
        ) { _ in
            startPendingDeepLink()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 16)],
                spacing: 16
            ) {
                ForEach(library.games) { game in
                    card(for: game)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .refreshable {
            library.reload()
        }
    }

    /// One grid tile.
    ///
    /// This lives outside `body` on purpose. Inlined, its five closures pushed
    /// the enclosing `LazyVGrid` past what the Swift type checker will solve in
    /// its time budget, and the build failed with "unable to type-check this
    /// expression in reasonable time". A function with a written-out parameter
    /// type is a separate, small problem for it to solve.
    private func card(for game: GameFile) -> GameCard {
        GameCard(
            game: game,
            launch: { start(game) },
            addToHomeScreen: { addToHomeScreen(game) },
            exportApp: { exportApp(game) },
            delete: { library.delete(game) }
        )
    }

    private func start(_ game: GameFile) {
        library.launch(
            game,
            scaleHack: scaleHack,
            orientation: orientation,
            networkAccess: networkAccess,
            analogTilt: analogTilt
        )
    }

    private func addToHomeScreen(_ game: GameFile) {
        let request = GameExportModel.HomeScreenRequest(
            fileName: game.url.lastPathComponent,
            displayName: game.displayName,
            bundleIdentifier: game.bundleIdentifier,
            icon: game.icon
        )
        export.addToHomeScreen(request)
    }

    private func exportApp(_ game: GameFile) {
        let core = CoreSelection.kind(forBundleIdentifier: game.bundleIdentifier)
        let request = StandaloneApp.Request.make(
            gameURL: game.url,
            displayName: game.displayName,
            bundleIdentifier: game.bundleIdentifier,
            icon: game.icon,
            core: core,
            scaleHack: scaleHack,
            orientation: orientation,
            networkAccess: networkAccess,
            analogTilt: analogTilt
        )
        export.exportStandaloneApp(request)
    }

    /// Starts the game a Home Screen icon asked for, if one did.
    ///
    /// The URL is read from the shared slot rather than from the notification,
    /// so whichever of the two paths above gets there first consumes it and the
    /// other finds nothing left to do.
    private func startPendingDeepLink() {
        guard !library.isLaunching,
              library.heldLaunch == nil,
              let url = touchhle_ios_take_pending_launch_url(),
              let target = GameLink.target(from: url as URL)
        else {
            return
        }

        guard let game = library.game(matching: target) else {
            library.launchError = "That game is no longer in your library."
            return
        }

        library.launch(
            game,
            scaleHack: scaleHack,
            orientation: orientation,
            networkAccess: networkAccess,
            analogTilt: analogTilt
        )
    }

    /// Dismissing the export sheet must not cancel what it started: after
    /// "Continue in Safari" the profile server still has to answer a fetch, and
    /// a build that is already running keeps going and reopens the sheet with
    /// its result.
    private var exportBinding: Binding<Bool> {
        Binding(
            get: { export.isActive },
            set: { isPresented in
                if !isPresented {
                    export.dismiss()
                }
            }
        )
    }

    private var heldLaunchBinding: Binding<Bool> {
        Binding(
            get: { library.heldLaunch != nil },
            set: { isPresented in
                if !isPresented {
                    library.heldLaunch = nil
                }
            }
        )
    }

    private func errorBinding(for error: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { error.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    error.wrappedValue = nil
                }
            }
        )
    }
}

/// The whole UI of an app exported with "Export as Standalone App".
///
/// There is no library and no import button: the game is inside the bundle and
/// the app exists to run it. It still needs a screen, because JIT has to be
/// enabled per launch on most devices and because a game that exits has to land
/// somewhere.
private struct StandaloneGameView: View {
    let bundled: BundledGame

    @StateObject private var library = GameLibrary()
    @State private var game: GameFile?
    @State private var hasAutoStarted = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        TouchHLENavigationContainer {
            ZStack {
                LibraryBackground()
                content
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EnableJITButton()
                }
            }
            .alert("Game Couldn’t Start", isPresented: launchErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.launchError ?? "Unknown error")
            }
            .alert(
                "JIT Isn’t Enabled",
                isPresented: heldLaunchBinding,
                presenting: library.heldLaunch
            ) { held in
                Button("Enable JIT") {
                    if let url = StikDebug.enableJITURL {
                        openURL(url)
                    }
                }
                Button("Start Anyway", role: .destructive) {
                    library.start(held)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(JITMethod.current.unavailableMessage)
            }
            .overlay {
                if library.isLaunching {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Starting game…")
                            .font(.headline)
                    }
                    .padding(24)
                    .touchHLELaunchOverlayStyle()
                }
            }
        }
        .onAppear {
            if game == nil {
                game = library.bundledGameFile(bundled)
            }
            // Straight into the game the first time, so the app behaves like
            // the one it is pretending to be. Only once: coming back here after
            // the game exits must not start it again.
            guard !hasAutoStarted else { return }
            hasAutoStarted = true
            start()
        }
    }

    /// Split out of `body` for the Swift type checker's sake: inlined, this
    /// stack plus the toolbar, two alerts and the overlay make one expression
    /// too large for it to solve in its time budget.
    private var content: some View {
        VStack(spacing: 20) {
            Spacer()

            icon
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: start) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .touchHLEImportButtonStyle()

            Text(jitNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
    }

    /// Resolved outside the view builder. `Text` has enough overloads that a
    /// `??` or `?:` in its argument is expensive to type-check in place.
    private var title: String {
        game?.displayName ?? bundled.displayName
    }

    private var jitNote: String {
        if JITMethod.current == .permanent {
            return "JIT is always on for this app."
        }
        return "JIT has to be enabled each time this app starts."
    }

    @ViewBuilder
    private var icon: some View {
        if let icon = game?.icon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        } else {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(.blue)
        }
    }

    private func start() {
        let game = self.game ?? library.bundledGameFile(bundled)
        self.game = game
        // An export ships only the core its game was set to use, so the
        // fallback in CoreSelection would land on it anyway. Pin it regardless:
        // it costs one UserDefaults write and stops being luck.
        CoreSelection.setOverride(bundled.core, forBundleIdentifier: game.bundleIdentifier)
        library.launch(
            game,
            scaleHack: bundled.scaleHack,
            orientation: bundled.orientation,
            networkAccess: bundled.networkAccess,
            analogTilt: bundled.analogTilt
        )
    }

    private var heldLaunchBinding: Binding<Bool> {
        Binding(
            get: { library.heldLaunch != nil },
            set: { isPresented in
                if !isPresented {
                    library.heldLaunch = nil
                }
            }
        )
    }

    private var launchErrorBinding: Binding<Bool> {
        Binding(
            get: { library.launchError != nil },
            set: { isPresented in
                if !isPresented {
                    library.launchError = nil
                }
            }
        )
    }
}

private enum StikDebug {
    /// Asks StikDebug to attach to this app and enable JIT.
    static var enableJITURL: URL? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }

        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleIdentifier),
            URLQueryItem(name: "script-name", value: "universal.js")
        ]
        return components.url
    }
}

/// How this install can get JIT, which decides what the UI should offer.
private enum JITMethod {
    /// TrollStore granted `dynamic-codesigning`: JIT is on and stays on.
    case permanent
    /// StikDebug can attach on demand, from inside the app (iOS 17.4+).
    case stikDebug
    /// A debugger has to be attached from outside before the game starts —
    /// TrollStore's "Enable JIT" below iOS 17.4, or AltJIT. There is nothing
    /// useful for the app to offer here beyond saying so.
    case external

    static var current: JITMethod {
        if touchhle_ios_jit_available() && !touchhle_ios_jit_is_from_debugger() {
            return .permanent
        }
        if #available(iOS 17.4, *) {
            return .stikDebug
        }
        return .external
    }

    /// Shown when a launch is held back because JIT is off.
    var unavailableMessage: String {
        switch self {
        case .permanent, .stikDebug:
            return "Games need JIT, and without it Applesauce closes the moment one starts. "
                + "Enable JIT in StikDebug, then start the game again."
        case .external:
            return "Games need JIT, and without it Applesauce closes the moment one starts. "
                + "Enable JIT for Applesauce in TrollStore, or with AltJIT, then start the "
                + "game again."
        }
    }

    /// Explains what has to happen, and how often.
    var footer: String {
        switch self {
        case .permanent:
            return "This install has permanent JIT, so there is nothing to enable."
        case .stikDebug:
            return "JIT must be enabled again whenever Applesauce starts as a new app process."
        case .external:
            return "StikDebug needs iOS 17.4 or newer. Enable JIT for Applesauce in TrollStore, "
                + "or with AltJIT, each time it starts as a new app process."
        }
    }
}

private struct EnableJITButton: View {
    @Environment(\.openURL) private var openURL
    @State private var showingUnavailableAlert = false

    var body: some View {
        // Hidden when it cannot help: StikDebug is iOS 17.4+, and a TrollStore
        // build with permanent JIT never needs it.
        if JITMethod.current == .stikDebug {
            button
        }
    }

    private var button: some View {
        Button {
            guard let url = StikDebug.enableJITURL else {
                showingUnavailableAlert = true
                return
            }

            openURL(url) { accepted in
                if !accepted {
                    showingUnavailableAlert = true
                }
            }
        } label: {
            Label("Enable JIT", systemImage: "bolt.fill")
        }
        .accessibilityHint("Opens StikDebug and enables JIT for Applesauce")
        .alert("StikDebug Not Available", isPresented: $showingUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Install and configure StikDebug, then try again. LocalDevVPN must be connected.")
        }
    }
}

private extension View {
    @ViewBuilder
    func touchHLEImportButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(.blue).interactive(), in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(.blue.opacity(0.2), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func touchHLELaunchOverlayStyle() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
        }
    }
}

private struct LibraryBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.13),
                    Color.clear,
                    Color.indigo.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct GameCard: View {
    let game: GameFile
    let launch: () -> Void
    let addToHomeScreen: () -> Void
    let exportApp: () -> Void
    let delete: () -> Void

    /// `nil` means this game follows the default core.
    @State private var coreOverride: CoreKind?
    @AppStorage("defaultCore") private var defaultCoreRaw = ""

    private var defaultCore: CoreKind {
        CoreSelection.kind(forStoredDefault: defaultCoreRaw)
    }

    private var core: CoreKind {
        coreOverride ?? defaultCore
    }

    private var coreSelection: Binding<CoreKind?> {
        Binding(
            get: { coreOverride },
            set: { newValue in
                coreOverride = newValue
                CoreSelection.setOverride(newValue, forBundleIdentifier: game.bundleIdentifier)
            }
        )
    }

    var body: some View {
        Button(action: launch) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.2), .indigo.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    if let icon = game.icon {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 82, height: 82)
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    } else {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(height: 112)

                VStack(alignment: .leading, spacing: 3) {
                    Text(game.displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(game.displayName)
        .accessibilityHint("Starts this game in \(core.displayName)")
        .contextMenu {
            menu
        }
        .onAppear {
            coreOverride = CoreSelection.override(forBundleIdentifier: game.bundleIdentifier)
        }
    }

    private var subtitle: String {
        CoreKind.installed.count > 1 ? core.displayName : "Tap to play"
    }

    /// Split out of `body`, which grew past what the Swift type checker will
    /// solve in one expression when the export entries were added.
    @ViewBuilder
    private var menu: some View {
        if CoreKind.installed.count > 1, game.bundleIdentifier != nil {
            Picker("Core", selection: coreSelection) {
                Text("Default (\(defaultCore.displayName))")
                    .tag(CoreKind?.none)
                ForEach(CoreKind.installed) { kind in
                    Text(kind.displayName).tag(CoreKind?.some(kind))
                }
            }
        }

        Button(action: addToHomeScreen) {
            Label("Add to Home Screen", systemImage: "square.grid.2x2")
        }

        Button(action: exportApp) {
            Label("Export as Standalone App", systemImage: "square.and.arrow.up.on.square")
        }

        Divider()

        Button(role: .destructive, action: delete) {
            Label("Remove from Library", systemImage: "trash")
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scaleHack") private var scaleHack = 3
    @AppStorage("orientation") private var orientation = 0
    @AppStorage("networkAccess") private var networkAccess = false
    @AppStorage("analogTilt") private var analogTilt = true
    @AppStorage("defaultCore") private var defaultCoreRaw = ""

    private var defaultCore: CoreKind {
        CoreSelection.kind(forStoredDefault: defaultCoreRaw)
    }

    var body: some View {
        TouchHLENavigationContainer {
            Form {
                if CoreKind.installed.count > 1 {
                    Section {
                        ForEach(CoreKind.installed) { kind in
                            CoreChoiceRow(kind: kind, isSelected: kind == defaultCore) {
                                defaultCoreRaw = kind.rawValue
                            }
                        }
                    } header: {
                        Text("Emulator Core")
                    } footer: {
                        Text("Games use this core unless you pick a different one for them. Touch and hold a game in your library to do that.")
                    }
                }

                Section("Display") {
                    Picker("Resolution Scale", selection: $scaleHack) {
                        Text("Off").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                        Text("4×").tag(4)
                    }

                    Picker("Starting Orientation", selection: $orientation) {
                        Text("Automatic").tag(OrientationSetting.automatic)
                        Text("Portrait").tag(OrientationSetting.portrait)
                        Text("Landscape Left").tag(OrientationSetting.landscapeLeft)
                        Text("Landscape Right").tag(OrientationSetting.landscapeRight)
                    }
                }

                Section {
                    Toggle("Network Access", isOn: $networkAccess)
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Some games need network access. Leave this off unless a game requires it.")
                }

                Section("Controls") {
                    Toggle("Analog Sticks Control Tilt", isOn: $analogTilt)
                }

                Section {
                    EnableJITButton()
                } header: {
                    Text("JIT")
                } footer: {
                    Text(JITMethod.current.footer)
                }

                Section("Advanced") {
                    NavigationLink {
                        DeveloperToolsView()
                    } label: {
                        Label("Developer Tools", systemImage: "wrench.and.screwdriver")
                    }
                }

                Section {
                    Text("Settings apply the next time you start a game.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// One core in the settings list: name, version, what it is for, and a
/// checkmark. A list of these reads more clearly than a picker, and it leaves
/// room to say what each core actually does.
private struct CoreChoiceRow: View {
    let kind: CoreKind
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(kind.displayName)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Text(kind.version)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(kind.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct DeveloperToolsView: View {
    @AppStorage("showFPSOverlay") private var showFPSOverlay = false

    var body: some View {
        Form {
            Section {
                Toggle("Show FPS During Games", isOn: $showFPSOverlay)
            } header: {
                Text("Performance")
            } footer: {
                Text("Displays a small frame-rate counter beside the exit button. This is intended for testing and is off by default.")
            }
        }
        .navigationTitle("Developer Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// The asset catalog copy, not the app icon. `CFBundleIconFiles` only
    /// reaches `AppIcon60x60`, whose largest bundled representation is 120x120,
    /// and this is drawn at 88pt — 264 pixels on a 3x screen, so the icon
    /// arrived visibly upscaled. Falls back to the old lookup if the asset is
    /// ever missing.
    private var appIcon: UIImage? {
        if let icon = UIImage(named: "AboutIcon") {
            return icon
        }

        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
            let iconName = iconFiles.last
        else {
            return nil
        }

        return UIImage(named: iconName)
    }

    var body: some View {
        TouchHLENavigationContainer {
            List {
                Section {
                    VStack(spacing: 14) {
                        Group {
                            if let appIcon {
                                Image(uiImage: appIcon)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "iphone.gen3")
                                    .font(.system(size: 42, weight: .medium))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                        VStack(spacing: 4) {
                            Text("Applesauce")
                                .font(.title2.bold())
                            Text("A playful emulator for iOS")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Text(
                            CoreKind.installed
                                .map { "\($0.displayName) \($0.version)" }
                                .joined(separator: " • ")
                        )
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }

                Section("About") {
                    Text("Applesauce plays older 32-bit iPhone games on modern devices, without including any Apple software. It is an experimental community project, and no games are included.")

                    Link(destination: URL(string: "https://github.com/johnny901901901/Applesauce")!) {
                        Label("Applesauce on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }

                Section {
                    Text("The emulation is entirely the work of touchHLE and its fork HyperHLE. Applesauce is the iOS app built around them — the interface, the build system and the packaging — and ships both cores so you can choose which one runs each game.")

                    Text("Applesauce is an unaffiliated fork. Neither project is connected to it or endorses it, and problems you hit here should be reported to Applesauce rather than to them.")

                    Link(destination: URL(string: "https://touchhle.org/")!) {
                        Label("touchHLE Website", systemImage: "safari")
                    }

                    Link(destination: URL(string: "https://github.com/touchHLE/touchHLE")!) {
                        Label("touchHLE Upstream", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Link(destination: URL(string: "https://github.com/HyperHLE/HyperHLE")!) {
                        Label("HyperHLE Core", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Link(destination: URL(string: "https://appdb.touchhle.org/")!) {
                        Label("Game Compatibility", systemImage: "checkmark.seal")
                    }
                } header: {
                    Text("Credits")
                } footer: {
                    Text("Licensed under MPL-2.0, subject to the existing third-party licence requirements.")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
