import Compression
import Foundation
import Network
import SwiftUI
import UIKit

// Two ways to get a game out of the library and onto the Home Screen:
//
//   * "Add to Home Screen" installs a Web Clip whose URL is
//     applesauce://launch?file=<name>. The icon looks like an app, but tapping
//     it opens Applesauce, which starts that one game. Nothing is copied, saves
//     stay where they are, and JIT only ever has to be enabled once, for
//     Applesauce itself.
//
//   * "Export as Standalone App" writes an IPA that is a copy of Applesauce
//     with the game embedded and the library UI skipped. It runs on its own,
//     but it is a separate installed app: its own container, its own saves, and
//     its own JIT enable every time it is launched.

// MARK: - Deep links

/// The applesauce:// URL a Home Screen icon opens.
///
/// Caught in Sources/main.m, because SDL owns the scene delegate. Both the file
/// name and the guest bundle identifier are included: the file name is what
/// makes the link unique, the bundle identifier lets the link survive a rename.
enum GameLink {
    static let scheme = "applesauce"

    struct Target {
        let fileName: String?
        let bundleIdentifier: String?
    }

    static func url(forFileNamed fileName: String, bundleIdentifier: String?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "launch"

        var items = [URLQueryItem(name: "file", value: fileName)]
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            items.append(URLQueryItem(name: "bundle", value: bundleIdentifier))
        }
        components.queryItems = items

        return components.url
    }

    static func target(from url: URL) -> Target? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fileName = items.first { $0.name == "file" }?.value
        let bundleIdentifier = items.first { $0.name == "bundle" }?.value
        guard fileName != nil || bundleIdentifier != nil else { return nil }

        return Target(fileName: fileName, bundleIdentifier: bundleIdentifier)
    }
}

// MARK: - ZIP writing

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { raw in
                for byte in raw.bindMemory(to: UInt8.self) {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        appendLittleEndian(UInt16(value & 0xFFFF))
        appendLittleEndian(UInt16((value >> 16) & 0xFFFF))
    }
}

/// A minimal ZIP writer, enough to produce an IPA.
///
/// Hand-rolled rather than reached for through `NSFileCoordinator`'s
/// `.forUploading` archive because the POSIX permission bits matter here: the
/// Mach-O inside the Payload has to stay executable, and the coordinator gives
/// no say over what it records.
///
/// No ZIP64. An exported app is around 100 MB, and the writer refuses rather
/// than silently truncating if anything ever exceeds the 4 GiB the classic
/// format can address.
private final class ZipWriter {
    enum Failure: LocalizedError {
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "The app is too large to package."
            }
        }
    }

    private struct Entry {
        let name: String
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: UInt16
        let externalAttributes: UInt32
        let localHeaderOffset: UInt32
    }

    /// Bit 11 declares the file names to be UTF-8, so a game with a non-ASCII
    /// title still unpacks with the name it was given.
    private static let utf8NameFlag: UInt16 = 0x0800

    private let handle: FileHandle
    private let timestamp: (time: UInt16, date: UInt16)
    private var offset: UInt64 = 0
    private var entries: [Entry] = []

    init(creating url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        timestamp = ZipWriter.dosTimestamp(Date())
    }

    func addDirectory(named name: String) throws {
        try addEntry(
            name: name.hasSuffix("/") ? name : name + "/",
            payload: Data(),
            crc: 0,
            uncompressedSize: 0,
            method: 0,
            // 0x10 is the MS-DOS directory bit; the high half is the UNIX mode
            // that iOS actually reads.
            externalAttributes: UInt32(0o040755) << 16 | 0x10
        )
    }

    func addFile(named name: String, contents: Data, mode: UInt16) throws {
        var payload = contents
        var method: UInt16 = 0
        if let deflated = ZipWriter.deflate(contents) {
            payload = deflated
            method = 8
        }

        try addEntry(
            name: name,
            payload: payload,
            crc: CRC32.checksum(contents),
            uncompressedSize: contents.count,
            method: method,
            externalAttributes: UInt32(mode) << 16
        )
    }

    func addSymlink(named name: String, target: String) throws {
        let payload = Data(target.utf8)
        try addEntry(
            name: name,
            payload: payload,
            crc: CRC32.checksum(payload),
            uncompressedSize: payload.count,
            method: 0,
            externalAttributes: UInt32(0o120777) << 16
        )
    }

    func finish() throws {
        let centralDirectoryOffset = offset

        var central = Data()
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            central.appendLittleEndian(UInt32(0x0201_4B50))
            // Version made by: 3 (UNIX) in the high byte, so the permission
            // bits in externalAttributes are honoured.
            central.appendLittleEndian(UInt16(0x031E))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(ZipWriter.utf8NameFlag)
            central.appendLittleEndian(entry.method)
            central.appendLittleEndian(timestamp.time)
            central.appendLittleEndian(timestamp.date)
            central.appendLittleEndian(entry.crc)
            central.appendLittleEndian(entry.compressedSize)
            central.appendLittleEndian(entry.uncompressedSize)
            central.appendLittleEndian(UInt16(nameBytes.count))
            central.appendLittleEndian(UInt16(0)) // extra field length
            central.appendLittleEndian(UInt16(0)) // comment length
            central.appendLittleEndian(UInt16(0)) // disk number
            central.appendLittleEndian(UInt16(0)) // internal attributes
            central.appendLittleEndian(entry.externalAttributes)
            central.appendLittleEndian(entry.localHeaderOffset)
            central.append(nameBytes)
        }

        guard entries.count <= Int(UInt16.max),
              centralDirectoryOffset <= UInt64(UInt32.max),
              central.count <= Int(UInt32.max)
        else {
            throw Failure.tooLarge
        }

        var end = Data()
        end.appendLittleEndian(UInt32(0x0605_4B50))
        end.appendLittleEndian(UInt16(0)) // this disk
        end.appendLittleEndian(UInt16(0)) // disk with central directory
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt32(central.count))
        end.appendLittleEndian(UInt32(centralDirectoryOffset))
        end.appendLittleEndian(UInt16(0)) // comment length

        try write(central)
        try write(end)
        try handle.close()
    }

    func abandon() {
        try? handle.close()
    }

    private func addEntry(
        name: String,
        payload: Data,
        crc: UInt32,
        uncompressedSize: Int,
        method: UInt16,
        externalAttributes: UInt32
    ) throws {
        let nameBytes = Data(name.utf8)
        guard offset <= UInt64(UInt32.max),
              uncompressedSize <= Int(UInt32.max),
              payload.count <= Int(UInt32.max),
              nameBytes.count <= Int(UInt16.max)
        else {
            throw Failure.tooLarge
        }

        let localHeaderOffset = UInt32(offset)

        var header = Data()
        header.appendLittleEndian(UInt32(0x0403_4B50))
        header.appendLittleEndian(UInt16(20))
        header.appendLittleEndian(ZipWriter.utf8NameFlag)
        header.appendLittleEndian(method)
        header.appendLittleEndian(timestamp.time)
        header.appendLittleEndian(timestamp.date)
        header.appendLittleEndian(crc)
        header.appendLittleEndian(UInt32(payload.count))
        header.appendLittleEndian(UInt32(uncompressedSize))
        header.appendLittleEndian(UInt16(nameBytes.count))
        header.appendLittleEndian(UInt16(0)) // extra field length
        header.append(nameBytes)

        try write(header)
        if !payload.isEmpty {
            try write(payload)
        }

        entries.append(
            Entry(
                name: name,
                crc: crc,
                compressedSize: UInt32(payload.count),
                uncompressedSize: UInt32(uncompressedSize),
                method: method,
                externalAttributes: externalAttributes,
                localHeaderOffset: localHeaderOffset
            )
        )
    }

    private func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    /// `COMPRESSION_ZLIB` is Apple's name for raw DEFLATE (RFC 1951), which is
    /// exactly ZIP's method 8. Returns nil when compressing is not worth it, in
    /// which case the caller stores the file instead.
    private static func deflate(_ data: Data) -> Data? {
        guard data.count > 128 else { return nil }

        let capacity = data.count
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase.assumingMemoryBound(to: UInt8.self),
                    capacity,
                    sourceBase.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        // 0 means the encoder could not fit the result in the buffer, i.e. the
        // data does not compress. Truncating in place rather than copying the
        // prefix out keeps a 35 MB core from needing a second 35 MB buffer.
        guard written > 0, written < data.count else { return nil }
        output.count = written
        return output
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        // The DOS date field counts from 1980 and has room until 2107.
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | ((parts.second ?? 0) / 2))
        let day = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

// MARK: - Icons

enum GameIconRenderer {
    /// Home Screen icons are square and opaque — iOS rounds the corners itself,
    /// and an icon with holes in it looks broken there. Guest icons are 57x57 or
    /// 114x114, so everything here is an upscale.
    static func squareIcon(from image: UIImage, side: CGFloat, opaque: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = opaque

        let canvas = CGRect(x: 0, y: 0, width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: canvas.size, format: format)
        return renderer.image { context in
            if opaque {
                UIColor.black.setFill()
                context.fill(canvas)
            }
            context.cgContext.interpolationQuality = .high
            image.draw(in: aspectFitRect(for: image.size, in: canvas.size))
        }
    }

    private static func aspectFitRect(for size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }

        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

// MARK: - Home Screen icon (Web Clip)

enum WebClip {
    /// Builds the .mobileconfig that puts one game on the Home Screen.
    static func profile(
        label: String,
        launchURL: URL,
        icon: UIImage?,
        identifier: String
    ) -> Data? {
        var webClip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifier).webclip",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": label,
            "URL": launchURL.absoluteString,
            "Label": label,
            "IsRemovable": true,
            // Web Clip icons are drawn as-is; without this iOS adds the old
            // glossy highlight over the top of a game's artwork.
            "Precomposed": true,
            "FullScreen": true
        ]

        if let icon,
           let png = GameIconRenderer.squareIcon(from: icon, side: 180, opaque: true).pngData() {
            webClip["Icon"] = png
        }

        // iOS replaces a profile by PayloadIdentifier, so adding the same game
        // twice updates its icon rather than installing a second one.
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "\(label) Home Screen Icon",
            "PayloadDescription":
                "Adds \(label) to your Home Screen. Tapping it opens Applesauce and starts the game.",
            "PayloadOrganization": "Applesauce",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [webClip]
        ]

        return try? PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .xml,
            options: 0
        )
    }
}

/// Hands a .mobileconfig to Safari.
///
/// There is no API for installing a configuration profile from inside an app.
/// The one route that works is the one MDM enrolment pages use: serve the
/// profile over HTTP with the aspen-config content type and open that URL in
/// Safari, which recognises it and passes it to Settings. The profile never
/// leaves the device — the listener is bound to loopback, which is also why it
/// does not trip the local network permission prompt — and it is shut down
/// again as soon as Safari has fetched it.
@MainActor
final class ProfileServer {
    static let shared = ProfileServer()

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var shutdown: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var payload = Data()

    func start(payload: Data, completion: @escaping (Result<URL, Error>) -> Void) {
        stop()
        self.payload = payload

        // Opening Safari sends this app to the background, and a suspended app
        // cannot answer the fetch it just asked for. The assertion buys the few
        // seconds Safari needs.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Applesauce profile") {
            [weak self] in
            self?.stop()
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            completion(.failure(error))
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                self?.accept(connection)
            }
        }

        var reported = false
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, !reported else { return }
                switch state {
                case .ready:
                    guard let port = listener.port,
                          let url = URL(
                            string: "http://127.0.0.1:\(port.rawValue)/applesauce.mobileconfig"
                          )
                    else {
                        return
                    }
                    reported = true
                    completion(.success(url))
                case .failed(let error):
                    reported = true
                    self.stop()
                    completion(.failure(error))
                case .cancelled:
                    reported = true
                default:
                    break
                }
            }
        }

        listener.start(queue: .main)

        // Safari fetches within a second, but the user has to leave the app to
        // get there. Two minutes covers a slow trip through Settings; after
        // that the port closes whether or not anything asked for it.
        let shutdown = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        self.shutdown = shutdown
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: shutdown)
    }

    func stop() {
        shutdown?.cancel()
        shutdown = nil

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        payload = Data()

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)

        // This server has exactly one resource, so the request does not need
        // parsing: anything that arrives gets the profile.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] _, _, _, _ in
            DispatchQueue.main.async {
                self?.respond(on: connection)
            }
        }
    }

    private func respond(on connection: NWConnection) {
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/x-apple-aspen-config",
            "Content-Length: \(payload.count)",
            "Content-Disposition: attachment; filename=\"applesauce.mobileconfig\"",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(header.utf8)
        response.append(payload)

        connection.send(
            content: response,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}

// MARK: - Standalone app export

/// Builds a copy of Applesauce with one game baked into it.
///
/// The trick that makes this possible on-device is that nothing has to be
/// re-signed. The main Mach-O is copied through byte for byte, keeping the
/// signature and the JIT entitlements it was installed with; only the resources
/// around it change. Dropping `_CodeSignature` and the provisioning profile
/// leaves TrollStore to seal the result on install, which it does anyway.
///
/// The game itself is left inside the read-only app bundle. The emulator reads
/// IPAs in place as ZIP archives (src/fs.rs) and puts every guest write in
/// $HOME/Documents (src/paths.rs), so nothing ever tries to write back into it.
enum StandaloneApp {
    struct Request {
        let gameURL: URL
        let displayName: String
        let bundleIdentifier: String?
        /// Loose icon PNGs keyed by the file name they take in the bundle.
        /// Rendered by the caller on the main thread, so the build itself does
        /// not have to touch UIKit.
        let icons: [String: Data]
        let core: CoreKind
        let scaleHack: Int
        let orientation: Int
        let networkAccess: Bool
        let analogTilt: Bool
    }

    enum Failure: LocalizedError {
        case unreadableAppBundle
        case unreadableInfoPlist

        var errorDescription: String? {
            switch self {
            case .unreadableAppBundle:
                return "Applesauce could not read its own app bundle."
            case .unreadableInfoPlist:
                return "Applesauce could not read its own Info.plist."
            }
        }
    }

    /// Where finished IPAs are kept. Inside Documents on purpose: file sharing
    /// is on, so an export that TrollStore refuses is still reachable in Files.
    static var exportsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exported Apps", isDirectory: true)
    }

    static func build(_ request: Request, progress: @escaping (String) -> Void) throws -> URL {
        let source = Bundle.main.bundleURL
        let appFolderName = bundleFolderName(for: request.displayName)
        let gameFileName = request.gameURL.lastPathComponent

        progress("Reading app bundle…")

        // Files written fresh rather than copied from this app, keyed by their
        // path inside the .app.
        var replacements: [String: Data] = [:]
        replacements["Info.plist"] = try rewrittenInfoPlist(for: request, source: source)
        replacements["BundledGame.plist"] = try settingsPlist(
            for: request,
            gameFileName: gameFileName
        )
        for (name, png) in request.icons {
            replacements[name] = png
        }

        // The signature is regenerated by TrollStore on install, the
        // provisioning profile belongs to this install and not the new one, and
        // an emulator core the game does not use is 35 MB of dead weight.
        var exclusions: Set<String> = ["_CodeSignature", "embedded.mobileprovision", "SC_Info"]
        for kind in CoreKind.allCases where kind != request.core {
            exclusions.insert("Frameworks/\(kind.libraryName)")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw Failure.unreadableAppBundle
        }

        let items = enumerator.compactMap { $0 as? URL }
        let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"

        try FileManager.default.createDirectory(
            at: exportsDirectory,
            withIntermediateDirectories: true
        )
        let destination = exportsDirectory.appendingPathComponent("\(appFolderName).ipa")

        let writer = try ZipWriter(creating: destination)
        do {
            try writer.addDirectory(named: "Payload")
            try writer.addDirectory(named: "Payload/\(appFolderName).app")

            var written = 0
            for item in items {
                guard item.path.hasPrefix(sourcePrefix) else { continue }
                let relativePath = String(item.path.dropFirst(sourcePrefix.count))
                guard !relativePath.isEmpty, !isExcluded(relativePath, by: exclusions) else {
                    continue
                }

                written += 1
                if written % 25 == 0 {
                    progress("Packaging… \(percent(written, of: items.count))")
                }

                let entryName = "Payload/\(appFolderName).app/\(relativePath)"
                try autoreleasepool {
                    try add(item, as: entryName, replacement: replacements[relativePath], to: writer)
                }
                replacements.removeValue(forKey: relativePath)
            }

            // Whatever is left had no counterpart in this app's bundle: the
            // settings plist, and the icons if this build ships its own inside
            // the asset catalog rather than as loose files.
            for (relativePath, contents) in replacements {
                try writer.addFile(
                    named: "Payload/\(appFolderName).app/\(relativePath)",
                    contents: contents,
                    mode: 0o644
                )
            }

            progress("Adding \(request.displayName)…")
            try writer.addDirectory(named: "Payload/\(appFolderName).app/BundledGame")
            try autoreleasepool {
                let game = try Data(contentsOf: request.gameURL, options: [.mappedIfSafe])
                try writer.addFile(
                    named: "Payload/\(appFolderName).app/BundledGame/\(gameFileName)",
                    contents: game,
                    mode: 0o644
                )
            }

            progress("Finishing…")
            try writer.finish()
        } catch {
            writer.abandon()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        return destination
    }

    /// Asks TrollStore to install a finished IPA.
    static func installURL(for ipa: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "apple-magnifier"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        return components.url
    }

    private static func add(
        _ item: URL,
        as entryName: String,
        replacement: Data?,
        to writer: ZipWriter
    ) throws {
        let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

        if values.isSymbolicLink == true {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
            try writer.addSymlink(named: entryName, target: target)
            return
        }

        if values.isDirectory == true {
            try writer.addDirectory(named: entryName)
            return
        }

        if let replacement {
            try writer.addFile(named: entryName, contents: replacement, mode: 0o644)
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let contents = try Data(contentsOf: item, options: [.mappedIfSafe])
        try writer.addFile(named: entryName, contents: contents, mode: mode)
    }

    private static func isExcluded(_ relativePath: String, by exclusions: Set<String>) -> Bool {
        if exclusions.contains(relativePath) { return true }
        return exclusions.contains { relativePath.hasPrefix($0 + "/") }
    }

    private static func rewrittenInfoPlist(for request: Request, source: URL) throws -> Data {
        let infoURL = source.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard var info = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw Failure.unreadableInfoPlist
        }

        info["CFBundleIdentifier"] = bundleIdentifier(for: request)
        info["CFBundleDisplayName"] = request.displayName
        info["CFBundleName"] = String(request.displayName.prefix(15))

        // Only the real Applesauce answers for applesauce://; an exported app
        // that also claimed the scheme would make which one opens a Home Screen
        // icon a coin toss.
        info.removeValue(forKey: "CFBundleURLTypes")
        info.removeValue(forKey: "NSLocalNetworkUsageDescription")

        // The asset catalog still holds Applesauce's own icon, and iOS prefers
        // it over loose files while this key points at it.
        if !request.icons.isEmpty {
            info.removeValue(forKey: "CFBundleIconName")
            info["CFBundleIcons"] = iconDictionary(includingPad: false)
            info["CFBundleIcons~ipad"] = iconDictionary(includingPad: true)
        }

        return try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
    }

    private static func iconDictionary(includingPad: Bool) -> [String: Any] {
        let files = includingPad ? ["AppIcon60x60", "AppIcon76x76"] : ["AppIcon60x60"]
        return [
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": files,
                "UIPrerenderedIcon": false
            ]
        ]
    }

    private static func settingsPlist(for request: Request, gameFileName: String) throws -> Data {
        let settings: [String: Any] = [
            "file": gameFileName,
            "displayName": request.displayName,
            "bundleIdentifier": request.bundleIdentifier ?? "",
            "core": request.core.rawValue,
            "scaleHack": request.scaleHack,
            "orientation": request.orientation,
            "networkAccess": request.networkAccess,
            "analogTilt": request.analogTilt
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: settings,
            format: .xml,
            options: 0
        )
    }

    private static func bundleIdentifier(for request: Request) -> String {
        let source = request.bundleIdentifier?.isEmpty == false
            ? request.bundleIdentifier!
            : request.displayName

        let allowed = source.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        var stem = String(String.UnicodeScalarView(allowed)).lowercased()
        if stem.isEmpty {
            stem = "game"
        }

        // Two games whose names reduce to the same letters would otherwise get
        // the same identifier, and installing the second would replace the
        // first. The suffix is derived rather than random so that re-exporting
        // a game still updates the app it produced last time.
        return "io.github.johnny901901901.applesauce.game.\(stem.prefix(40)).\(fingerprint(source))"
    }

    /// FNV-1a. `hashValue` is seeded per process and would change the bundle
    /// identifier on every launch.
    private static func fingerprint(_ string: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in Array(string.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash % 0xFFFF_FFFF, radix: 36)
    }

    private static func bundleFolderName(for displayName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let filtered = displayName.unicodeScalars.filter { allowed.contains($0) }
        let name = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Applesauce" : String(name.prefix(40))
    }

    private static func percent(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(min(100, value * 100 / total))%"
    }
}

// MARK: - The game an exported app carries

/// Present only in an app produced by "Export as Standalone App". When it is,
/// the library is skipped and this game is what the app runs.
struct BundledGame {
    let url: URL
    let displayName: String
    let bundleIdentifier: String?
    let core: CoreKind
    let scaleHack: Int
    let orientation: Int
    let networkAccess: Bool
    let analogTilt: Bool

    static let current: BundledGame? = load()

    private static func load() -> BundledGame? {
        guard let plistURL = Bundle.main.url(forResource: "BundledGame", withExtension: "plist"),
              let data = try? Data(contentsOf: plistURL),
              let settings = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let fileName = settings["file"] as? String
        else {
            return nil
        }

        let url = Bundle.main.bundleURL
            .appendingPathComponent("BundledGame", isDirectory: true)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let bundleIdentifier = settings["bundleIdentifier"] as? String
        return BundledGame(
            url: url,
            displayName: settings["displayName"] as? String
                ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil,
            core: CoreKind(rawValue: settings["core"] as? String ?? "") ?? CoreSelection.defaultKind,
            scaleHack: settings["scaleHack"] as? Int ?? 3,
            orientation: settings["orientation"] as? Int ?? 0,
            networkAccess: settings["networkAccess"] as? Bool ?? false,
            analogTilt: settings["analogTilt"] as? Bool ?? true
        )
    }
}

// MARK: - Driving both from the library

extension StandaloneApp.Request {
    /// Renders the icons up front, on the main thread, so that building the app
    /// afterwards is pure file work and can run off it.
    @MainActor
    static func make(
        gameURL: URL,
        displayName: String,
        bundleIdentifier: String?,
        icon: UIImage?,
        core: CoreKind,
        scaleHack: Int,
        orientation: Int,
        networkAccess: Bool,
        analogTilt: Bool
    ) -> StandaloneApp.Request {
        // The names match the CFBundleIconFiles entries written into the
        // exported Info.plist: iOS resolves "AppIcon60x60" to the @2x or @3x
        // file this device wants.
        let wanted: [(name: String, side: CGFloat)] = [
            ("AppIcon60x60@2x.png", 120),
            ("AppIcon60x60@3x.png", 180),
            ("AppIcon76x76@2x~ipad.png", 152)
        ]

        var icons: [String: Data] = [:]
        if let icon {
            for entry in wanted {
                let rendered = GameIconRenderer.squareIcon(
                    from: icon,
                    side: entry.side,
                    opaque: true
                )
                if let png = rendered.pngData() {
                    icons[entry.name] = png
                }
            }
        }

        return StandaloneApp.Request(
            gameURL: gameURL,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            icons: icons,
            core: core,
            scaleHack: scaleHack,
            orientation: orientation,
            networkAccess: networkAccess,
            analogTilt: analogTilt
        )
    }
}

@MainActor
final class GameExportModel: ObservableObject {
    struct HomeScreenRequest {
        let fileName: String
        let displayName: String
        let bundleIdentifier: String?
        let icon: UIImage?
    }

    enum Stage: Equatable {
        case idle
        /// Building or preparing, with something to show the user meanwhile.
        case working(String)
        /// The profile is being served; this is the URL Safari has to open.
        case profileReady(URL)
        case ipaReady(URL)
        case failed(String)
    }

    @Published var stage: Stage = .idle

    var isActive: Bool { stage != .idle }

    func addToHomeScreen(_ request: HomeScreenRequest) {
        guard let launchURL = GameLink.url(
            forFileNamed: request.fileName,
            bundleIdentifier: request.bundleIdentifier
        ),
            let profile = WebClip.profile(
                label: request.displayName,
                launchURL: launchURL,
                icon: request.icon,
                identifier: profileIdentifier(for: request)
            )
        else {
            stage = .failed("The Home Screen icon could not be prepared.")
            return
        }

        stage = .working("Preparing Home Screen icon…")
        ProfileServer.shared.start(payload: profile) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.stage = .profileReady(url)
            case .failure(let error):
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    func exportStandaloneApp(_ request: StandaloneApp.Request) {
        stage = .working("Building \(request.displayName)…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let ipa = try StandaloneApp.build(request) { message in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // A cancelled or failed export must not be talked back
                        // into looking busy by a late progress message.
                        if case .working = self.stage {
                            self.stage = .working(message)
                        }
                    }
                }
                DispatchQueue.main.async {
                    self?.stage = .ipaReady(ipa)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.stage = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Closes the sheet. The profile server, if one is up, is left running:
    /// this is also what happens after handing the URL to Safari, and Safari
    /// still has to come back for it.
    func dismiss() {
        stage = .idle
    }

    func cancel() {
        ProfileServer.shared.stop()
        stage = .idle
    }

    private func profileIdentifier(for request: HomeScreenRequest) -> String {
        let source = request.bundleIdentifier?.isEmpty == false
            ? request.bundleIdentifier!
            : request.fileName
        let allowed = source.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        var stem = String(String.UnicodeScalarView(allowed)).lowercased()
        if stem.isEmpty {
            stem = "game"
        }
        return "io.github.johnny901901901.applesauce.homescreen.\(stem.prefix(40))"
    }
}

struct GameExportSheet: View {
    @ObservedObject var model: GameExportModel

    @Environment(\.openURL) private var openURL
    @State private var sharing: SharePayload?

    private struct SharePayload: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    var body: some View {
        VStack(spacing: 18) {
            switch model.stage {
            case .idle:
                EmptyView()

            case .working(let message):
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Keep Applesauce open until this finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .profileReady(let url):
                header(
                    symbol: "square.grid.2x2",
                    title: "Add to Home Screen",
                    detail: """
                        Safari will offer to download a profile. Allow it, then open \
                        Settings › General › VPN & Device Management and install it. \
                        The icon appears on your Home Screen and opens the game in \
                        Applesauce.
                        """
                )
                Button {
                    openURL(url)
                    model.dismiss()
                } label: {
                    Label("Continue in Safari", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Cancel", role: .cancel) {
                    model.cancel()
                }

            case .ipaReady(let url):
                header(
                    symbol: "app.badge.checkmark",
                    title: "App Exported",
                    detail: """
                        \(url.deletingPathExtension().lastPathComponent) is a full app of its \
                        own, with the game inside it. It does not need Applesauce to run, but \
                        it keeps its own save games, and JIT has to be enabled for it \
                        separately every time you start it.
                        """
                )
                Button {
                    install(url)
                } label: {
                    Label("Install with TrollStore", systemImage: "arrow.down.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    sharing = SharePayload(url: url)
                } label: {
                    Label("Share IPA…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Text("Also saved in Files under Applesauce › Exported Apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Done") {
                    model.dismiss()
                }

            case .failed(let message):
                header(symbol: "exclamationmark.triangle", title: "Didn’t Work", detail: message)
                Button("Done") {
                    model.dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $sharing) { payload in
            ShareSheet(url: payload.url)
        }
    }

    @ViewBuilder
    private func header(symbol: String, title: String, detail: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .medium))
            .foregroundStyle(.blue)
        Text(title)
            .font(.title2.bold())
        Text(detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func install(_ ipa: URL) {
        guard let installURL = StandaloneApp.installURL(for: ipa) else {
            sharing = SharePayload(url: ipa)
            return
        }

        // TrollStore may not be what answers apple-magnifier:// — on a stock
        // device that is Apple's Magnifier app, and on a device without either
        // nothing opens at all. Fall back to the share sheet rather than
        // leaving the user on a button that did nothing.
        openURL(installURL) { accepted in
            if !accepted {
                sharing = SharePayload(url: ipa)
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
