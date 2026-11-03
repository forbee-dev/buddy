import AppKit
import BuddyCore

/// Community skins: the bundled examples (read-only, off by default) plus `~/Library/Application Support/Buddy/skins/*.json`
/// (on by default). A directory watch reloads them; it is an event source, not a timer.
@MainActor
@Observable
final class SkinStore {
    static let shared = SkinStore()

    struct Entry: Identifiable {
        var id: String
        var file: String
        var bundled: Bool
        var skin: Skin?
        var error: String?
        /// Hash of the file bytes: a reload with the same files and bytes changes nothing.
        var hash = 0
    }

    private(set) var entries: [Entry] = []
    /// Skin name → on/off, for skins the user switched.
    private(set) var switched: [String: Bool]
    /// Switched-on skins that are applied: on, valid, and without a char or color key of an earlier one.
    private(set) var enabled: [Skin] = []
    /// Entry id → why a switched-on skin is not applied.
    private(set) var conflicts: [String: String] = [:]
    let folder = UninstallPlan.supportFolder(home: NSHomeDirectory()) + "/skins"
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The newest reload; the demo waits for it.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?

    private init() {
        switched = UserDefaults.standard.dictionary(forKey: PrefKey.skinsEnabled) as? [String: Bool] ?? [:]
    }

    func isOn(_ e: Entry) -> Bool { e.skin.map { switched[$0.name] ?? !e.bundled } ?? false }

    /// Applies the switched-on skins in list order (bundled first), skipping one that reuses an earlier one's char or color key.
    private func apply() {
        var accepted: [Skin] = []
        var why: [String: String] = [:]
        for e in entries where isOn(e) {
            guard let skin = e.skin else { continue }
            if let c = SkinLoader.conflict(skin, with: accepted) { why[e.id] = c.description } else { accepted.append(skin) }
        }
        enabled = accepted
        conflicts = why
        model?.applySkins(accepted)
    }

    func setOn(_ e: Entry, _ on: Bool) {
        guard let name = e.skin?.name else { return }
        switched[name] = on
        UserDefaults.standard.set(switched, forKey: PrefKey.skinsEnabled)
        apply()
    }

    #if DEBUG
    /// Demo only: on for this run, not saved.
    func demoEnable(_ name: String) {
        switched[name] = true
        apply()
    }
    #endif

    func start(model: AppModel) {
        self.model = model
        #if DEBUG
        // The demo never touches the real support folder.
        if Demo.on { reload(); return }
        #endif
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            log.error("Skins folder: \(error.localizedDescription, privacy: .public)")
        }
        reload()
        watch()
    }

    /// Reads and checks the files off the main thread; the newest reload wins.
    func reload() {
        guard let base = model?.baseSheet else { return }
        #if DEBUG
        let userFolder: String? = Demo.on ? nil : folder
        #else
        let userFolder: String? = folder
        #endif
        let bundled = Self.bundledFolder
        generation += 1
        let gen = generation
        loading = Task {
            let loaded = await Task.detached(priority: .utility) { Self.load(base: base, bundled: bundled, user: userFolder) }.value
            guard gen == generation else { return }
            let same = loaded.map { [$0.id, "\($0.hash)", $0.error ?? ""] } == entries.map { [$0.id, "\($0.hash)", $0.error ?? ""] }
            guard !same else { return }
            entries = loaded
            apply()
        }
    }

    private nonisolated static func load(base: SpriteSheet, bundled: (dir: String, inApp: Bool)?, user: String?) -> [Entry] {
        var names = Set<String>()
        func load(_ path: String, bundled: Bool, checkOwner: Bool) -> Entry {
            let file = (path as NSString).lastPathComponent
            var e = Entry(id: (bundled ? "bundled:" : "") + file, file: file, bundled: bundled)
            do {
                let data = try read(path, checkOwner: checkOwner)
                // Every byte: `Data.hashValue` reads only a prefix, so an edit further in would look unchanged.
                var h = Hasher()
                data.withUnsafeBytes { h.combine(bytes: $0) }
                e.hash = h.finalize()
                e.skin = try SkinLoader.validate(data, base: base, names: &names)
            } catch {
                e.error = "\(error)"
            }
            return e
        }
        // Files inside the signed app bundle are code-signed resources (often owned by root): no owner check.
        let b = bundled.map { dir in jsonFiles(in: dir.dir).map { load($0, bundled: true, checkOwner: !dir.inApp) } } ?? []
        return b + (user.map { jsonFiles(in: $0).map { load($0, bundled: false, checkOwner: true) } } ?? [])
    }

    func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }

    /// The app bundle's skins; debug builds also take a source checkout.
    private static var bundledFolder: (dir: String, inApp: Bool)? {
        AppServices.bundledResource("skins", devPath: "design/skins").map { ($0.path, $0.path.hasPrefix(Bundle.main.bundlePath + "/")) }
    }

    private nonisolated static func jsonFiles(in dir: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().prefix(100).map { dir + "/" + $0 }
    }

    /// Size and type from lstat first, so the error names the real reason; then a no-follow read.
    private nonisolated static func read(_ path: String, checkOwner: Bool) throws -> Data {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard attrs?[.type] as? FileAttributeType == .typeRegular else { throw SkinError.unreadable }
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= SkinLoader.maxBytes else { throw SkinError.tooBig(size) }
        guard let data = SafeFile.contents(path, maxBytes: SkinLoader.maxBytes, uid: checkOwner ? getuid() : nil) else { throw SkinError.unreadable }
        return data
    }

    /// A file added, removed, or renamed in the folder (editors save by rename) reloads the skins.
    private func watch() {
        let fd = open(folder, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        // Debounced: an editor's save is several events; reload 300 ms after the last one.
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingReload?.cancel()
                self.pendingReload = Task { @MainActor [weak self] in
                    guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
                    self?.reload()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}
