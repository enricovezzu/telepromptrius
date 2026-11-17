import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CryptoKit

/// Traduzioni: la chiave è il testo italiano, le altre lingue stanno in <lingua>.lproj/Localizable.strings.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

// MARK: - Modelli

enum MirrorMode: String, CaseIterable, Identifiable {
    case none, horizontal, vertical, rotated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return L("Dritto (nessuno specchio)")
        case .horizontal: return L("Specchio orizzontale ↔")
        case .vertical: return L("Specchio verticale ↕")
        case .rotated: return L("Ruotato di 180°")
        }
    }
    var hint: String {
        switch self {
        case .none: return L("Testo normale")
        case .horizontal: return L("Per teleprompter con vetro/beam splitter")
        case .vertical: return L("Capovolto sopra-sotto")
        case .rotated: return L("Specchio orizzontale + verticale")
        }
    }
    var sx: CGFloat { (self == .horizontal || self == .rotated) ? -1 : 1 }
    var sy: CGFloat { (self == .vertical || self == .rotated) ? -1 : 1 }
    var next: MirrorMode {
        let all = MirrorMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum TextTint: String, CaseIterable, Identifiable {
    case white, yellow, green, cyan
    var id: String { rawValue }
    var title: String {
        switch self { case .white: return L("Bianco"); case .yellow: return L("Giallo"); case .green: return L("Verde"); case .cyan: return L("Azzurro") }
    }
    var ns: NSColor {
        switch self {
        case .white: return .white
        case .yellow: return NSColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
        case .green: return NSColor(red: 0.4, green: 1, blue: 0.5, alpha: 1)
        case .cyan: return NSColor(red: 0.4, green: 0.9, blue: 1, alpha: 1)
        }
    }
}

struct ScreenInfo: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

let sampleText = """
Benvenuto nel tuo teleprompter.

Incolla qui il tuo testo. Sul tuo schermo lo vedi dritto, mentre sullo schermo esteso viene mostrato specchiato nel modo che scegli.

Premi Spazio per far partire o fermare lo scorrimento. Le frecce su e giù cambiano la velocità, sinistra e destra la dimensione del testo.
"""

// MARK: - Testi salvati

struct Script: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var modified = Date()
    var fileName: String? = nil      // nome del file .txt nella cartella dei testi
    var diskDate: Date? = nil        // data del file l'ultima volta che l'abbiamo letto o scritto

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? L("Senza titolo") : t
    }
    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    /// Durata stimata a un ritmo di lettura naturale (150 parole al minuto).
    var estimate: String {
        let sec = wordCount * 60 / 150
        return sec < 60 ? L("< 1 min") : LF("≈ %ld min", Int((Double(sec) / 60).rounded()))
    }

    static func titleFrom(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = first.trimmingCharacters(in: .whitespaces)
        return clean.count > 48 ? String(clean.prefix(48)) + "…" : clean
    }
}

/// Archivio dei testi: un file .txt per testo nella cartella iCloud Drive → Telepromptrius
/// (sincronizzata da iCloud su Mac, iPhone e iPad). Senza iCloud Drive usa una cartella locale.
enum Library {
    static let iCloudRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static var inICloud: Bool { FileManager.default.fileExists(atPath: iCloudRoot.path) }

    static let folder: URL = {
        // Solo per prove e screenshot: TP_LIBRARY_DIR usa un'altra cartella di testi.
        if let d = ProcessInfo.processInfo.environment["TP_LIBRARY_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        let base = inICloud
            ? iCloudRoot.appendingPathComponent("Telepromptrius", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Telepromptrius/Testi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let oldJSON = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Telepromptrius/scripts.json")

    struct Entry { let name: String; let text: String; let modified: Date }
    struct Scan {
        var ok = true                       // cartella leggibile
        var entries: [Entry] = []
        var cloudOnly = Set<String>()       // file non ancora scaricati da iCloud (nomi reali)
        var unreadable = Set<String>()      // file presenti ma non leggibili in questo momento
        var isEmpty: Bool { entries.isEmpty && cloudOnly.isEmpty && unreadable.isEmpty }
    }

    static func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }
    private static var downloadRequested = Set<String>()

    static func readText(_ u: URL) -> String? {
        if let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        var enc = String.Encoding.utf8
        return try? String(contentsOf: u, usedEncoding: &enc)
    }

    /// Elenca i testi della cartella; i file non ancora scaricati da iCloud vengono richiesti una volta.
    static func scan() -> Scan {
        let fm = FileManager.default
        var out = Scan()
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            out.ok = false; return out
        }
        for u in urls {
            let n = u.lastPathComponent
            if n.hasPrefix("."), n.hasSuffix(".icloud") {
                let realName = String(n.dropFirst().dropLast(7))
                guard ["txt", "md"].contains((realName as NSString).pathExtension.lowercased()) else { continue }
                out.cloudOnly.insert(realName)
                if !downloadRequested.contains(realName) {
                    downloadRequested.insert(realName)
                    let real = folder.appendingPathComponent(realName)
                    if (try? fm.startDownloadingUbiquitousItem(at: real)) == nil {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
                        p.arguments = ["download", real.path]; try? p.run()
                    }
                }
                continue
            }
            guard ["txt", "md"].contains(u.pathExtension.lowercased()) else { continue }
            guard let body = readText(u) else { out.unreadable.insert(n); continue }
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            out.entries.append(Entry(name: n, text: body, modified: date))
        }
        return out
    }

    static func exists(_ name: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(name).path)
            || fm.fileExists(atPath: folder.appendingPathComponent("." + name + ".icloud").path)
    }

    static func modDate(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.modificationDate] as? Date
    }

    /// Nome di file valido e libero per un titolo: libero sia in memoria sia su disco (anche per i file solo in iCloud).
    static func fileName(for title: String, taken: Set<String>, own: String? = nil) -> String {
        var base = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasPrefix(".") { base = String(base.drop(while: { $0 == "." })) }
        if base.isEmpty { base = L("Senza titolo") }
        if base.count > 80 { base = String(base.prefix(80)) }
        let lower = Set(taken.map { $0.lowercased() })
        func free(_ n: String) -> Bool {
            if let own, n.lowercased() == own.lowercased() { return true }
            return !lower.contains(n.lowercased()) && !exists(n)
        }
        var name = base + ".txt", n = 2
        while !free(name) { name = "\(base) \(n).txt"; n += 1 }
        return name
    }

    @discardableResult
    static func write(_ text: String, to name: String) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil
    }
    static func move(_ from: String, to: String) -> Bool {
        (try? FileManager.default.moveItem(at: folder.appendingPathComponent(from), to: folder.appendingPathComponent(to))) != nil
    }
    static func trash(_ name: String) {
        try? FileManager.default.trashItem(at: folder.appendingPathComponent(name), resultingItemURL: nil)
    }

    /// Prima volta: porta nella cartella i testi del vecchio archivio. Solo se la cartella è davvero vuota
    /// (nemmeno file in attesa da iCloud) e una sola volta; il vecchio archivio resta come backup solo se tutto è stato scritto.
    static func migrateIfNeeded(_ d: UserDefaults) {
        guard !d.bool(forKey: "migratedToFiles") else { return }
        let current = scan()
        guard current.ok else { return }
        guard current.isEmpty else { d.set(true, forKey: "migratedToFiles"); return }
        var list: [Script] = []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: oldJSON), let old = try? dec.decode([Script].self, from: data) {
            list = old
        } else {
            let old = d.string(forKey: "text") ?? sampleText
            list = [Script(title: Script.titleFrom(old), text: old)]
        }
        var taken = Set<String>(), allWritten = true
        for sc in list {
            let name = fileName(for: sc.displayTitle, taken: taken)
            taken.insert(name)
            if write(sc.text, to: name) {
                try? FileManager.default.setAttributes([.modificationDate: sc.modified], ofItemAtPath: folder.appendingPathComponent(name).path)
            } else { allWritten = false }
        }
        guard allWritten else { return }
        if FileManager.default.fileExists(atPath: oldJSON.path) {
            let backup = oldJSON.deletingLastPathComponent().appendingPathComponent("scripts-backup.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: oldJSON, to: backup)
        }
        d.set(true, forKey: "migratedToFiles")
    }
}

// MARK: - Stato

final class ScrollClock: ObservableObject {
    @Published var offset: Double = 0
}

struct PositionSlider: View {
    @ObservedObject var clock: ScrollClock
    let s: TeleState
    var body: some View {
        Slider(value: Binding(get: { clock.offset }, set: { s.offset = $0 }), in: 0...max(1, s.textHeight))
    }
}

final class TeleState: NSObject, ObservableObject {
    @Published var text: String {
        didSet {
            guard !loadingScript, let i = currentIndex, scripts[i].text != text else { return }
            scripts[i].text = text
            scripts[i].modified = Date()
            dirty.insert(scripts[i].id)
        }
    }
    @Published var scripts: [Script] = []
    @Published var currentID: UUID?
    @Published var showLibrary = true
    @Published var librarySearch = ""
    @Published var renameID: UUID?
    @Published var renameText = ""
    @Published var deleteID: UUID?
    private var loadingScript = false
    private var dirty = Set<UUID>()          // testi modificati non ancora scritti su file
    private var folderWatch: DispatchSourceFileSystemObject?
    private var rescanWork: DispatchWorkItem?
    @Published var fontSize: Double
    @Published var speed: Double
    @Published var margin: Double
    @Published var lineSpacing: Double
    @Published var tint: TextTint
    @Published var mirror: MirrorMode
    @Published var showGuide: Bool
    @Published var previewMirrored: Bool
    @Published var screenID: UInt32 { didSet { if !autoSelecting { preferredScreenID = screenID } } }
    private var preferredScreenID: UInt32 = 0
    private var autoSelecting = false
    @Published var fontName: String
    @Published var bold: Bool
    @Published var appearance: String { didSet { applyAppearance() } }
    let clock = ScrollClock()
    private var _offset: Double = 0
    private var tickCount = 0
    private var listeners: [ObjectIdentifier: (Double) -> Void] = [:]
    var offset: Double {
        get { _offset }
        set { _offset = newValue; clock.offset = newValue; notify() }
    }
    func addListener(_ key: AnyObject, _ f: @escaping (Double) -> Void) { listeners[ObjectIdentifier(key)] = f }
    func removeListener(_ key: AnyObject) { listeners[ObjectIdentifier(key)] = nil }
    private func notify() { for f in listeners.values { f(_offset) } }
    @Published var textHeight: Double = 0 { didSet { if _offset > textHeight { offset = textHeight } } }
    @Published var playing = false {
        didSet {
            link?.isPaused = !playing          // nessun ridisegno a vuoto quando è in pausa
            if playing { NSCursor.setHiddenUntilMouseMoves(true) }
            updateActivity()
        }
    }
    @Published var externalOpen = false { didSet { updateActivity() } }
    @Published var showEditor: Bool
    @Published var showMini: Bool
    @Published var showInspector: Bool
    @Published var openDrawers: Set<String>
    @Published var screens: [ScreenInfo] = []

    private var window: NSWindow?
    private var link: CADisplayLink?
    private var activity: NSObjectProtocol?
    private var last = CACurrentMediaTime()
    private var bag = Set<AnyCancellable>()
    private let d = UserDefaults.standard

    override init() {
        Library.migrateIfNeeded(d)
        let library = Library.scan().entries.map {
            Script(title: Library.stem($0.name), text: $0.text, modified: $0.modified, fileName: $0.name, diskDate: $0.modified)
        }
        let lastFile = d.string(forKey: "currentFile")
        let current = library.first(where: { $0.fileName == lastFile }) ?? library.max(by: { $0.modified < $1.modified })
        text = current?.text ?? ""
        fontSize = d.object(forKey: "fontSize") as? Double ?? 64
        speed = d.object(forKey: "speed") as? Double ?? 60
        margin = d.object(forKey: "margin") as? Double ?? 80
        lineSpacing = d.object(forKey: "lineSpacing") as? Double ?? 12
        tint = TextTint(rawValue: d.string(forKey: "tint") ?? "") ?? .white
        mirror = MirrorMode(rawValue: d.string(forKey: "mirror") ?? "") ?? .horizontal
        showGuide = d.object(forKey: "showGuide") as? Bool ?? true
        previewMirrored = d.object(forKey: "previewMirrored") as? Bool ?? false
        let savedScreen = UInt32(d.integer(forKey: "screenID"))
        screenID = savedScreen
        preferredScreenID = savedScreen
        showMini = d.object(forKey: "showMini") as? Bool ?? true
        fontName = d.string(forKey: "fontName") ?? ""
        bold = d.object(forKey: "bold") as? Bool ?? true
        appearance = d.string(forKey: "appearance") ?? "dark"
        showEditor = d.object(forKey: "showEditor") as? Bool ?? true
        showInspector = d.object(forKey: "showInspector") as? Bool ?? true
        openDrawers = Set(d.stringArray(forKey: "openDrawers") ?? ["mirror", "screen", "text"])
        super.init()
        scripts = library
        currentID = current?.id
        watchFolder()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rescan()
        }
        if CommandLine.arguments.contains("--prompter"), currentID != nil { showLibrary = false }   // apertura diretta (prove)
        if CommandLine.arguments.contains("--play") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.toggle() } }
        DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
        refreshScreens()

        objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        makeLink()
        installMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Updater.shared.checkAutomatically() }

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let w = n.object as? NSWindow, w !== self?.window, !(w is NSPanel), w.styleMask.contains(.titled) else { return }
            self?.closeExternal()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.save()
        }
    }

    private func makeLink() {
        link?.invalidate()
        guard let scr = NSScreen.screens.first ?? NSScreen.main else { link = nil; return }
        let l = scr.displayLink(target: self, selector: #selector(displayTick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.isPaused = !playing
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func screensChanged() {
        // Se il monitor del teleprompter viene scollegato, chiudo la finestra invece di
        // farla saltare a tutto schermo sul Mac sopra la finestra di controllo.
        if externalOpen && targetScreen == nil { closeExternal() }
        refreshScreens()
        reposition()
        makeLink()
    }

    private func updateActivity() {
        let need = playing || externalOpen
        if need, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                             reason: "Teleprompter in uso")
        } else if !need, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }


    func installMonitor() {
        let s = self
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.modifierFlags.contains(.command) { return e }
            let typing = NSApp.keyWindow?.firstResponder is NSTextView
            if e.keyCode == 53 {
                if typing { NSApp.keyWindow?.makeFirstResponder(nil); return nil }
                if s.externalOpen { s.closeExternal(); return nil }
                return e
            }
            if typing || s.showLibrary { return e }
            if e.isARepeat && [49, 15, 46, 121].contains(e.keyCode) { return nil }
            switch e.keyCode {
            case 49: s.toggle()
            case 126: s.speed = min(400, s.speed + 5)
            case 125: s.speed = max(5, s.speed - 5)
            case 123: s.fontSize = max(24, s.fontSize - 4)
            case 124: s.fontSize = min(200, s.fontSize + 4)
            case 15: s.reset()
            case 121: s.toggle()
            case 116: s.offset = max(0, s.offset - 250)
            case 46: s.mirror = s.mirror.next
            default: return e
            }
            return nil
        }
    }

    func applyAppearance() {
        switch appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    func save() {
        flushScripts()
        d.set(scripts.first(where: { $0.id == currentID })?.fileName, forKey: "currentFile")
        d.set(fontSize, forKey: "fontSize"); d.set(speed, forKey: "speed")
        d.set(margin, forKey: "margin"); d.set(lineSpacing, forKey: "lineSpacing"); d.set(tint.rawValue, forKey: "tint")
        d.set(mirror.rawValue, forKey: "mirror"); d.set(showGuide, forKey: "showGuide")
        d.set(previewMirrored, forKey: "previewMirrored"); d.set(Int(preferredScreenID), forKey: "screenID"); d.set(appearance, forKey: "appearance"); d.set(fontName, forKey: "fontName"); d.set(bold, forKey: "bold")
        d.set(showEditor, forKey: "showEditor"); d.set(showMini, forKey: "showMini"); d.set(showInspector, forKey: "showInspector"); d.set(Array(openDrawers), forKey: "openDrawers")
    }

    @objc private func displayTick() { tick() }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - last, 0.1)
        last = now
        guard playing else { return }
        _offset = min(_offset + speed * dt, textHeight)
        notify()
        tickCount &+= 1
        if tickCount % 8 == 0 { clock.offset = _offset }
        if _offset >= textHeight { clock.offset = _offset; playing = false }
    }

    func toggle() {
        if !playing && offset >= textHeight - 1 { offset = 0 }
        last = CACurrentMediaTime()
        playing.toggle()
    }

    func reset() { playing = false; offset = 0 }

    // Libreria
    var currentIndex: Int? { scripts.firstIndex { $0.id == currentID } }

    var currentTitle: String {
        get { currentIndex.map { scripts[$0].title } ?? "" }
        set {
            guard let i = currentIndex, scripts[i].title != newValue else { return }
            scripts[i].title = newValue; scripts[i].modified = Date(); dirty.insert(scripts[i].id)
        }
    }

    /// Scrive su file i testi modificati (rinominando il file se è cambiato il titolo).
    /// Un testo resta "da salvare" finché la scrittura non riesce. Se il file è stato cambiato
    /// da un altro dispositivo dopo l'ultima lettura, la versione locale va in "Titolo (conflitto).txt".
    func flushScripts() {
        guard !dirty.isEmpty else { return }
        var conflicts: [Script] = []
        for id in dirty {
            guard let i = scripts.firstIndex(where: { $0.id == id }) else { dirty.remove(id); continue }
            var sc = scripts[i]
            let taken = Set(scripts.compactMap { $0.id == id ? nil : $0.fileName })

            // Conflitto: il file su disco è più recente di quello che conoscevamo e ha un contenuto diverso.
            if let name = sc.fileName, let known = sc.diskDate, let onDisk = Library.modDate(name),
               onDisk.timeIntervalSince(known) > 1,
               let remote = Library.readText(Library.folder.appendingPathComponent(name)), remote != sc.text {
                let copyName = Library.fileName(for: sc.displayTitle + " (" + L("conflitto") + ")", taken: taken.union([name]))
                if Library.write(sc.text, to: copyName) {
                    conflicts.append(Script(title: Library.stem(copyName), text: sc.text, fileName: copyName, diskDate: Library.modDate(copyName)))
                    sc.text = remote; sc.diskDate = onDisk; sc.modified = onDisk
                    if id == currentID { loadingScript = true; text = remote; loadingScript = false }
                    scripts[i] = sc
                    dirty.remove(id)
                }
                continue
            }

            let wanted = Library.fileName(for: sc.displayTitle, taken: taken, own: sc.fileName)
            if let old = sc.fileName, old != wanted, Library.stem(old) != sc.displayTitle {
                if Library.move(old, to: wanted) { sc.fileName = wanted }
                else if !Library.exists(old) { sc.fileName = wanted }    // il vecchio file non c'è più: ne creo uno nuovo
            } else if sc.fileName == nil {
                sc.fileName = wanted
            }
            if Library.write(sc.text, to: sc.fileName!) {
                sc.diskDate = Library.modDate(sc.fileName!)
                dirty.remove(id)
            }
            scripts[i] = sc
        }
        if !conflicts.isEmpty { scripts.append(contentsOf: conflicts) }
    }

    /// Rilegge la cartella: testi aggiunti, cambiati o tolti da altri dispositivi (o dal Finder).
    func rescan() {
        flushScripts()
        let scan = Library.scan()
        guard scan.ok else { watchFolder(); return }          // cartella sparita o non leggibile: non tocco la lista
        var known = [String: Script]()
        for sc in scripts { if let f = sc.fileName { known[f.lowercased()] = sc } }
        var result: [Script] = []
        for e in scan.entries {
            if var sc = known.removeValue(forKey: e.name.lowercased()) {
                if sc.fileName != e.name { sc.title = Library.stem(e.name); sc.fileName = e.name }   // rinominato da fuori
                if sc.text != e.text && !dirty.contains(sc.id) {
                    sc.text = e.text; sc.modified = e.modified
                    if sc.id == currentID { loadingScript = true; text = e.text; loadingScript = false }
                }
                sc.diskDate = e.modified
                result.append(sc)
            } else {
                result.append(Script(title: Library.stem(e.name), text: e.text, modified: e.modified, fileName: e.name, diskDate: e.modified))
            }
        }
        // Testi noti momentaneamente non leggibili o solo in iCloud: li tengo come sono.
        let keep = Set((scan.cloudOnly.union(scan.unreadable)).map { $0.lowercased() })
        for (name, sc) in known where keep.contains(name) || dirty.contains(sc.id) { result.append(sc) }
        // Testi nuovi non ancora scritti
        result += scripts.filter { $0.fileName == nil }
        if result != scripts { scripts = result }
        if let id = currentID, !scripts.contains(where: { $0.id == id }) {
            currentID = nil
            if !showLibrary { goToLibrary() }
        }
    }

    private func watchFolder() {
        folderWatch?.cancel(); folderWatch = nil
        let fd = Darwin.open(Library.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            self?.rescanWork?.cancel()
            let w = DispatchWorkItem { self?.rescan() }
            self?.rescanWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        folderWatch = src
    }

    func revealFolder() { NSWorkspace.shared.activateFileViewerSelecting([Library.folder]) }

    var filteredScripts: [Script] {
        let q = librarySearch.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = scripts.sorted { $0.modified > $1.modified }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.title.lowercased().contains(q) || $0.text.lowercased().contains(q) }
    }

    func open(_ id: UUID) {
        guard let sc = scripts.first(where: { $0.id == id }) else { return }
        playing = false
        loadingScript = true
        currentID = id
        text = sc.text
        loadingScript = false
        offset = 0
        showLibrary = false
    }

    func goToLibrary() {
        playing = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        librarySearch = ""
        showLibrary = true
    }

    func newScript() {
        let sc = Script(title: L("Nuovo testo"), text: "")
        scripts.append(sc)
        dirty.insert(sc.id)
        open(sc.id)
        showEditor = true
    }

    func duplicate(_ id: UUID) {
        guard var sc = scripts.first(where: { $0.id == id }) else { return }
        sc.id = UUID(); sc.title = sc.displayTitle + " (" + L("copia") + ")"; sc.modified = Date(); sc.fileName = nil
        scripts.append(sc)
        dirty.insert(sc.id)
    }

    func askRename(_ id: UUID) {
        renameText = scripts.first(where: { $0.id == id })?.title ?? ""
        renameID = id
    }

    func commitRename() {
        if let id = renameID, let i = scripts.firstIndex(where: { $0.id == id }) {
            scripts[i].title = renameText; scripts[i].modified = Date(); dirty.insert(id)
        }
        renameID = nil
        flushScripts()
    }

    func delete(_ id: UUID) {
        if let f = scripts.first(where: { $0.id == id })?.fileName { Library.trash(f) }
        dirty.remove(id)
        scripts.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        deleteID = nil
    }

    func importScripts() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .rtf, .rtfd] + ["docx", "doc", "odt", "md"].compactMap { UTType(filenameExtension: $0) }
        panel.message = L("Scegli uno o più testi da importare (Word, RTF, testo)")
        guard panel.runModal() == .OK else { return }
        var added: [Script] = []
        for url in panel.urls {
            let body = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
                ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            added.append(Script(title: url.deletingPathExtension().lastPathComponent, text: body))
        }
        scripts.append(contentsOf: added)
        added.forEach { dirty.insert($0.id) }
        flushScripts()
        if added.count == 1 { open(added[0].id) }
    }

    // Schermi
    func refreshScreens() {
        screens = NSScreen.screens.enumerated().map { i, s in
            let size = "\(Int(s.frame.width))×\(Int(s.frame.height))"
            return ScreenInfo(id: s.displayID, name: "\(s.localizedName) (\(size))\(i == 0 ? " – " + L("principale") : "")")
        }
        let all = NSScreen.screens
        guard !all.isEmpty else { return }
        let wanted = all.contains(where: { $0.displayID == preferredScreenID })
            ? preferredScreenID : (all.count > 1 ? all[1] : all[0]).displayID
        if wanted != screenID { autoSelecting = true; screenID = wanted; autoSelecting = false }
    }

    static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var targetScreen: NSScreen? { NSScreen.screens.first { $0.displayID == screenID } }

    var targetAspect: Double {
        guard let f = targetScreen?.frame, f.height > 0 else { return 16.0 / 9.0 }
        return Double(f.width / f.height)
    }

    func toggleExternal() { externalOpen ? closeExternal() : openExternal() }

    func openExternal() {
        guard let screen = targetScreen else { return }
        let w = window ?? NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.backgroundColor = .black
        w.hasShadow = false
        if window == nil { w.contentView = NSHostingView(rootView: ExternalView(s: self)) }
        window = w
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        externalOpen = true
    }

    func closeExternal() {
        window?.orderOut(nil)
        externalOpen = false
    }

    func reposition() {
        guard externalOpen, let screen = targetScreen else { return }
        window?.setFrame(screen.frame, display: true)
    }
}

// MARK: - Vista del teleprompter (identica su anteprima e schermo esterno)

let guideFraction: CGFloat = 0.35

struct TeleprompterView: View {
    @ObservedObject var s: TeleState
    let mirror: MirrorMode
    var reportsHeight = false

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / 1000
            let H = geo.size.height
            ZStack(alignment: .topLeading) {
                Color.black
                ScrollingTextView(s: s, mirror: mirror, reports: reportsHeight,
                                  text: s.text, fontName: s.fontName, bold: s.bold, fontSize: s.fontSize,
                                  margin: s.margin, lineSpacing: s.lineSpacing, tint: s.tint)
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: H * 0.12)
                    if s.showGuide {
                        let y = H * guideFraction
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y - 18 * k)); p.addLine(to: CGPoint(x: 30 * k, y: y)); p.addLine(to: CGPoint(x: 0, y: y + 18 * k)); p.closeSubpath()
                            p.move(to: CGPoint(x: geo.size.width, y: y - 18 * k)); p.addLine(to: CGPoint(x: geo.size.width - 30 * k, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y + 18 * k)); p.closeSubpath()
                        }
                        .fill(Color.red.opacity(0.85))
                    }
                }
                .frame(width: geo.size.width, height: H, alignment: .topLeading)
                .scaleEffect(x: mirror.sx, y: mirror.sy)
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: H)
            .clipped()
        }
        .background(Color.black)
    }
}

// MARK: - Testo su CATiledLayer (disegnato una volta, poi scorre solo il layer)

final class TextTileLayer: CATiledLayer {
    var renderer: ((CGContext) -> Void)?
    override class func fadeDuration() -> CFTimeInterval { 0 }
    override func draw(in ctx: CGContext) { renderer?(ctx) }
}

struct ScrollingTextView: NSViewRepresentable {
    let s: TeleState
    let mirror: MirrorMode
    let reports: Bool
    let text: String
    let fontName: String
    let bold: Bool
    let fontSize: Double
    let margin: Double
    let lineSpacing: Double
    let tint: TextTint

    func makeNSView(context: Context) -> ScrollCanvasView {
        let v = ScrollCanvasView(state: s)
        return v
    }
    func updateNSView(_ v: ScrollCanvasView, context: Context) {
        v.params = ScrollCanvasView.Params(text: text, fontName: fontName, bold: bold, fontSize: fontSize,
                                           margin: margin, lineSpacing: lineSpacing, tint: tint, mirror: mirror, reports: reports)
    }
    static func dismantleNSView(_ v: ScrollCanvasView, coordinator: ()) { v.detach() }
}

/// Fonte dei tile: vive fuori dalla NSView, così i thread di disegno non trattengono la vista.
/// Il main thread sostituisce solo un riferimento (lock brevissimo); ogni impaginazione ha
/// il proprio lock per serializzare l'uso dello stesso NSLayoutManager fra i tile.
final class TileSource {
    final class Layout {
        let storage: NSTextStorage, lm: NSLayoutManager, tc: NSTextContainer
        let originX: CGFloat
        let lock = NSLock()
        init(storage: NSTextStorage, lm: NSLayoutManager, tc: NSTextContainer, originX: CGFloat) {
            self.storage = storage; self.lm = lm; self.tc = tc; self.originX = originX
        }
    }
    struct Snap { let layout: Layout; let scale: CGFloat; let layerH: CGFloat }

    private let swapLock = NSLock()
    private var snap: Snap?
    func set(_ s: Snap) { swapLock.lock(); snap = s; swapLock.unlock() }

    func draw(_ ctx: CGContext) {
        swapLock.lock(); let s = snap; swapLock.unlock()
        guard let s, s.scale > 0 else { return }
        let L = s.layout
        L.lock.lock(); defer { L.lock.unlock() }
        let clip = ctx.boundingBoxOfClipPath
        ctx.saveGState()
        ctx.translateBy(x: 0, y: s.layerH)
        ctx.scaleBy(x: s.scale, y: -s.scale)          // coordinate logiche, y verso il basso
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let rect = CGRect(x: clip.minX / s.scale - L.originX, y: (s.layerH - clip.maxY) / s.scale,
                          width: clip.width / s.scale, height: clip.height / s.scale)
        let gr = L.lm.glyphRange(forBoundingRect: rect, in: L.tc)
        L.lm.drawGlyphs(forGlyphRange: gr, at: CGPoint(x: L.originX, y: 0))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}

final class ScrollCanvasView: NSView {
    struct Params: Equatable {
        var text = "", fontName = "", bold = true
        var fontSize = 64.0, margin = 80.0, lineSpacing = 12.0
        var tint = TextTint.white, mirror = MirrorMode.none, reports = false
    }

    let state: TeleState
    private let container = CALayer()
    private lazy var tile = makeTile()
    private let source = TileSource()
    private var layoutBox: TileSource.Layout?
    private var logicalH: CGFloat = 1
    private var layerH: CGFloat = 1
    private var builtKey = ""
    private var builtDrawKey = ""
    var params = Params() { didSet { if params != oldValue { needsLayout = true } } }

    init(state: TeleState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(container)
        container.addSublayer(tile)
        state.addListener(self) { [weak self] o in self?.place(o) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeTile() -> TextTileLayer {
        let l = TextTileLayer()
        l.anchorPoint = .zero
        l.levelsOfDetail = 1
        l.tileSize = CGSize(width: 1024, height: 1024)
        l.isOpaque = false
        l.contentsScale = window?.backingScaleFactor ?? 2
        l.renderer = { [source] ctx in source.draw(ctx) }
        return l
    }

    func detach() { state.removeListener(self) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil) }

    override func scrollWheel(with e: NSEvent) {
        guard bounds.width > 1 else { return }
        let k = Double(bounds.width / 1000)
        let dir: Double = params.mirror.sy < 0 ? -1 : 1
        let dy = Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 1.0 : 8.0) * dir
        let new = min(max(0, state.offset - dy / k), max(0, state.textHeight))
        if new != state.offset { state.offset = new }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tile.contentsScale = window?.backingScaleFactor ?? 2
        builtDrawKey = ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = bounds
        let m = params.mirror
        container.setAffineTransform(CGAffineTransform(scaleX: m.sx, y: m.sy))
        tile.contentsScale = window?.backingScaleFactor ?? 2
        rebuildIfNeeded()
        place(state.offset)
        CATransaction.commit()
    }

    /// Impagina il testo su una larghezza logica fissa (1000) e lo scala solo in disegno:
    /// anteprima e schermo esteso vanno a capo esattamente nelle stesse parole.
    private func rebuildIfNeeded() {
        let k = bounds.width / 1000
        let p = params
        let layoutKey = "\(p.text)|\(p.fontName)|\(p.bold)|\(p.fontSize)|\(p.margin)|\(p.lineSpacing)|\(p.tint)"
        let drawKey = "\(bounds.width)|\(tile.contentsScale)"
        let relayout = layoutKey != builtKey || layoutBox == nil
        guard relayout || drawKey != builtDrawKey else { return }

        if relayout {
            builtKey = layoutKey
            let size = CGFloat(p.fontSize)
            let w: NSFont.Weight = p.bold ? .bold : .regular
            let font = p.fontName.isEmpty ? NSFont.systemFont(ofSize: size, weight: w)
                : (NSFontManager.shared.font(withFamily: p.fontName, traits: p.bold ? .boldFontMask : [], weight: 5, size: size)
                   ?? NSFont.systemFont(ofSize: size, weight: w))
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineSpacing = CGFloat(p.lineSpacing)
            let attr = NSAttributedString(string: p.text, attributes: [.font: font, .foregroundColor: p.tint.ns, .paragraphStyle: para])
            let st = NSTextStorage(attributedString: attr)
            let lm = NSLayoutManager()
            let tc = NSTextContainer(size: CGSize(width: max(10, 1000 - 2 * CGFloat(p.margin)), height: .greatestFiniteMagnitude))
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            st.addLayoutManager(lm)
            lm.ensureLayout(for: tc)
            logicalH = ceil(lm.usedRect(for: tc).height) + 2
            layoutBox = TileSource.Layout(storage: st, lm: lm, tc: tc, originX: CGFloat(p.margin))

            if p.reports {
                let logical = Double(logicalH), s = state
                DispatchQueue.main.async { if abs(s.textHeight - logical) > 0.5 { s.textHeight = logical } }
            }
        }

        builtDrawKey = drawKey
        layerH = logicalH * k
        source.set(.init(layout: layoutBox!, scale: k, layerH: layerH))
        // Livello nuovo a ogni cambio: un tile ancora in disegno con la geometria vecchia
        // non può restare in memoria e comparire stirato (il vecchio livello viene buttato).
        let fresh = makeTile()
        fresh.contentsScale = tile.contentsScale
        fresh.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: layerH)
        fresh.position = tile.position
        tile.renderer = nil
        container.replaceSublayer(tile, with: fresh)
        tile = fresh
        fresh.setNeedsDisplay()
    }

    private func place(_ offset: Double) {
        guard bounds.height > 1 else { return }
        let k = bounds.width / 1000
        let topOffset = bounds.height * guideFraction - CGFloat(offset) * k
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tile.position = CGPoint(x: 0, y: bounds.height - topOffset - layerH)
        CATransaction.commit()
    }
}

struct ExternalView: View {
    @ObservedObject var s: TeleState
    var body: some View {
        TeleprompterView(s: s, mirror: s.mirror).ignoresSafeArea()
    }
}

// MARK: - Finestra di controllo (Liquid Glass)

struct ControlView: View {
    @ObservedObject var s: TeleState

    var body: some View {
        Group {
            if s.showLibrary { LibraryView(s: s).transition(.opacity) } else { prompter.transition(.opacity) }
        }
        .animation(.smooth, value: s.showLibrary)
        .frame(minWidth: 1100, minHeight: 600)
        .containerBackground(.ultraThinMaterial, for: .window)
        .navigationTitle(s.showLibrary ? "Telepromptrius" : s.currentTitle)
        .onChange(of: s.screenID) { s.reposition() }
        .toolbar {
            if !s.showLibrary {
                ToolbarItemGroup(placement: .navigation) {
                    Button { s.goToLibrary() } label: { Label(L("Testi"), systemImage: "chevron.left") }
                        .labelStyle(.titleAndIcon)
                        .help(L("Torna ai tuoi testi (⌘L)"))
                        .keyboardShortcut("l", modifiers: .command)
                    Button { s.showEditor.toggle() } label: { Image(systemName: "sidebar.left") }
                        .help(L("Mostra/nascondi il testo (⌘E)"))
                        .keyboardShortcut("e", modifiers: .command)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { s.toggleExternal() } label: {
                    Label(s.externalOpen ? L("Chiudi") : L("Proietta"),
                          systemImage: s.externalOpen ? "xmark.rectangle.fill" : "play.rectangle.on.rectangle")
                }
                .tint(s.externalOpen ? .red : .accentColor)
                .help(L("Apri/chiudi il teleprompter a tutto schermo (Esc per chiudere)"))
                if !s.showLibrary {
                    Button { s.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(L("Mostra/nascondi le tendine (⌘I)"))
                        .keyboardShortcut("i", modifiers: .command)
                }
            }
        }
    }

    private var prompter: some View {
        HStack(spacing: 12) {
            if s.showEditor {
                editorPanel
                    .frame(width: 320)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 12) {
                TeleprompterView(s: s, mirror: s.previewMirrored ? s.mirror : .none, reportsHeight: true)
                    .aspectRatio(s.targetAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .frame(maxWidth: .infinity)
                transportBar
            }
            .frame(maxHeight: .infinity)
            if s.showInspector {
                inspector
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .animation(.smooth, value: s.showEditor)
        .animation(.smooth, value: s.showInspector)
        .animation(.smooth, value: s.showMini)
        .animation(.smooth, value: s.openDrawers)
    }

    // Mini monitor: lo schermo secondario come appare davvero (con lo specchio applicato)

    private var miniMonitor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(s.externalOpen ? Color.red : Color.secondary).frame(width: 7, height: 7)
                Text(s.externalOpen ? L("Schermo esteso · in onda") : L("Schermo esteso · chiuso"))
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 4)
                Text(s.mirror == .none ? L("dritto") : L("specchiato")).font(.caption2).foregroundStyle(.secondary)
            }
            TeleprompterView(s: s, mirror: s.mirror)
                .aspectRatio(s.targetAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.25)))
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .help(L("Come si vede lo schermo secondario"))
    }

    // Testo

    private var wordCount: Int { s.text.split(whereSeparator: { $0.isWhitespace }).count }

    private var wordsPerMinute: String {
        guard s.textHeight > 0 else { return "–" }
        return "\(Int((Double(wordCount) * s.speed / s.textHeight * 60).rounded()))"
    }

    private var duration: String {
        guard s.speed > 0, s.textHeight > 0 else { return "–" }
        let sec = Int(s.textHeight / s.speed)
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("Titolo"), text: Binding(get: { s.currentTitle }, set: { s.currentTitle = $0 }))
                .textFieldStyle(.plain)
                .font(.title3.bold())
            HStack {
                Label(L("Testo"), systemImage: "text.alignleft").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(LF("%ld parole · ≈ %@", wordCount, duration))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            TextEditor(text: $s.text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    // Barra comandi

    private var transportBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 18) {
                Button { s.reset() } label: { Image(systemName: "backward.end.fill").font(.title3).frame(width: 30, height: 26) }
                    .buttonStyle(.glass).help(L("Torna all'inizio (R)"))
                Button { s.toggle() } label: {
                    Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 60, height: 30)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help(L("Avvia/pausa (Spazio)"))

                PositionSlider(clock: s.clock, s: s)

                Divider().frame(height: 30)
                Image(systemName: "speedometer").font(.title3).foregroundStyle(.secondary)
                Slider(value: $s.speed, in: 5...400).frame(width: 170)
                Text(LF("%@ parole/min", wordsPerMinute)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                    .help(L("Velocità di lettura stimata"))
                Image(systemName: "textformat.size").font(.title3).foregroundStyle(.secondary)
                Slider(value: $s.fontSize, in: 24...200).frame(width: 170)
            }
            .controlSize(.large)
            .font(.body)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .glassEffect(.regular, in: .capsule)
        }
    }

    // Tendine laterali

    private func drawer<C: View>(_ id: String, _ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        let open = s.openDrawers.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { s.openDrawers.remove(id) } else { s.openDrawers.insert(id) }
            } label: {
                HStack {
                    Label(title, systemImage: icon).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 10) { content() }.padding(.top, 12)
            }
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            if s.showMini {
                miniMonitor
                    .padding([.horizontal, .top], 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            inspectorDrawers
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var inspectorDrawers: some View {
        ScrollView {
            VStack(spacing: 10) {
                drawer("mirror", L("Specchio"), "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    Picker("", selection: $s.mirror) {
                        ForEach(MirrorMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.radioGroup).labelsHidden()
                    Text(s.mirror.hint).font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Mini monitor dello schermo esteso"), isOn: $s.showMini)
                    Toggle(L("Anteprima grande specchiata"), isOn: $s.previewMirrored)
                }
                drawer("screen", L("Schermo esterno"), "display") {
                    Picker("", selection: $s.screenID) {
                        ForEach(s.screens) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                    if s.screens.count < 2 {
                        Label(L("Nessun monitor esterno collegato: Proietta coprirà questo schermo. Esc per chiudere."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button { s.toggleExternal() } label: {
                        Label(s.externalOpen ? L("Chiudi schermo esterno") : L("Proietta a tutto schermo"),
                              systemImage: s.externalOpen ? "xmark.rectangle" : "play.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass).controlSize(.large)
                }
                drawer("text", L("Aspetto del testo"), "textformat") {
                    Picker(L("Font"), selection: $s.fontName) {
                        Text(L("Sistema")).tag("")
                        ForEach(TeleState.fontFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle(L("Grassetto"), isOn: $s.bold)
                    labeled(L("Margini"), $s.margin, 0...300)
                    labeled(L("Interlinea"), $s.lineSpacing, 0...80)
                    Picker(L("Colore"), selection: $s.tint) {
                        ForEach(TextTint.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Toggle(L("Indicatore di lettura"), isOn: $s.showGuide)
                }
                drawer("theme", L("Tema e scorciatoie"), "circle.lefthalf.filled") {
                    Picker("", selection: $s.appearance) {
                        Text(L("Scuro")).tag("dark"); Text(L("Chiaro")).tag("light"); Text(L("Sistema")).tag("system")
                    }.pickerStyle(.segmented).labelsHidden()
                    Text(L("Spazio o Pagina giù avvia/pausa · Pagina su torna indietro · clic sull'anteprima per uscire dal testo · ↑↓ velocità · ←→ dimensione · M specchio · R inizio · Esc chiude lo schermo esteso · ⌘E testo · ⌘I tendine · trackpad per scorrere."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func labeled(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text("\(Int(v.wrappedValue))").foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: v, in: r)
        }
    }
}

// MARK: - Libreria dei testi

struct LibraryView: View {
    @ObservedObject var s: TeleState
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            let list = s.filteredScripts
            if list.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(list) { card($0) }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 32).padding(.top, 20)
        .alert(L("Rinomina testo"), isPresented: Binding(get: { s.renameID != nil }, set: { if !$0 { s.renameID = nil } })) {
            TextField(L("Titolo"), text: $s.renameText)
            Button(L("Rinomina")) { s.commitRename() }.keyboardShortcut(.defaultAction)
            Button(L("Annulla"), role: .cancel) { s.renameID = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { s.deleteID != nil }, set: { if !$0 { s.deleteID = nil } })) {
            Button(L("Elimina"), role: .destructive) { if let id = s.deleteID { s.delete(id) } }
            Button(L("Annulla"), role: .cancel) { s.deleteID = nil }
        } message: { Text(L("Il file del testo verrà spostato nel Cestino.")) }
    }

    private var deleteTitle: String {
        let name = s.scripts.first(where: { $0.id == s.deleteID })?.displayTitle ?? ""
        return LF("Eliminare «%@»?", name)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("I tuoi testi")).font(.largeTitle.bold())
                HStack(spacing: 6) {
                    Text(s.scripts.count == 1 ? L("1 testo") : LF("%ld testi", s.scripts.count))
                    Text(L("·"))
                    Button { s.revealFolder() } label: {
                        Label(Library.inICloud ? L("in iCloud Drive") : L("in questo Mac"),
                              systemImage: Library.inICloud ? "icloud" : "internaldrive")
                    }
                    .buttonStyle(.plain)
                    .help(L("Mostra la cartella dei testi nel Finder"))
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Cerca nei testi"), text: $s.librarySearch).textFieldStyle(.plain)
                if !s.librarySearch.isEmpty {
                    Button { s.librarySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(width: 260)
            .glassEffect(.regular, in: .capsule)
            Button { s.importScripts() } label: { Label(L("Importa…"), systemImage: "square.and.arrow.down") }
                .buttonStyle(.glass).controlSize(.large)
                .help(L("Importa da Word, RTF o file di testo"))
            Button { s.newScript() } label: { Label(L("Nuovo testo"), systemImage: "plus") }
                .buttonStyle(.glassProminent).controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: s.scripts.isEmpty ? "text.page" : "magnifyingglass")
                .font(.system(size: 54)).foregroundStyle(.secondary)
            Text(s.scripts.isEmpty ? L("Nessun testo") : LF("Nessun risultato per «%@»", s.librarySearch)).font(.title2.bold())
            if s.scripts.isEmpty {
                Text(L("Crea un testo nuovo o importane uno da Word, RTF o file di testo.")).foregroundStyle(.secondary)
                Button { s.newScript() } label: { Label(L("Nuovo testo"), systemImage: "plus") }
                    .buttonStyle(.glassProminent).controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ sc: Script) -> some View {
        let isCurrent = sc.id == s.currentID
        return ZStack(alignment: .topTrailing) {
            Button { s.open(sc.id) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(sc.displayTitle)
                        .font(.title3.bold()).lineLimit(2)
                        .padding(.trailing, 28)
                    Text(sc.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Testo vuoto") : sc.text)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Text(LF("%ld parole · %@", sc.wordCount, sc.estimate))
                        Spacer(minLength: 8)
                        if isCurrent {
                            Circle().fill(.tint).frame(width: 6, height: 6)
                            Text(L("Ultimo aperto"))
                        } else {
                            Text(sc.modified, format: .relative(presentation: .named))
                        }
                    }
                    .lineLimit(1)
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(height: 200, alignment: .topLeading)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isCurrent ? 0.6 : 0), lineWidth: 1.5)
                .allowsHitTesting(false))

            Menu {
                cardActions(sc)
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 28, height: 28)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .padding(12)
        }
        .contextMenu { cardActions(sc) }
    }

    @ViewBuilder private func cardActions(_ sc: Script) -> some View {
        Button { s.open(sc.id) } label: { Label(L("Apri"), systemImage: "play.rectangle") }
        Button { s.askRename(sc.id) } label: { Label(L("Rinomina…"), systemImage: "pencil") }
        Button { s.duplicate(sc.id) } label: { Label(L("Duplica"), systemImage: "plus.square.on.square") }
        Divider()
        Button(role: .destructive) { s.deleteID = sc.id } label: { Label(L("Elimina…"), systemImage: "trash") }
    }
}

// MARK: - Aggiornamenti automatici (GitHub Releases)

/// Controlla l'ultima release su GitHub, scarica il pacchetto .zip, verifica la firma Ed25519
/// con la chiave pubblica scritta in Info.plist e sostituisce l'app, poi la riavvia.
/// Finestra "È disponibile una nuova versione" in stile Liquid Glass.
enum UpdateChoice { case update, later, skip }

enum UpdateWindow {
    private static var window: NSWindow?

    static func show(version: String, current: String, notes: [String], done: @escaping (UpdateChoice) -> Void) {
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.title = L("Aggiornamento disponibile")
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        let finish: (UpdateChoice) -> Void = { c in w.close(); window = nil; done(c) }
        let host = NSHostingView(rootView: UpdateView(version: version, current: current, notes: notes, act: finish))
        let bg = NSVisualEffectView()
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        host.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
                                     host.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
                                     host.topAnchor.constraint(equalTo: bg.topAnchor),
                                     host.bottomAnchor.constraint(equalTo: bg.bottomAnchor)])
        w.contentView = bg
        w.setContentSize(host.fittingSize)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct UpdateView: View {
    let version: String
    let current: String
    let notes: [String]
    let act: (UpdateChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 68, height: 68)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("NUOVA VERSIONE")).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    Text("Telepromptrius \(version)").font(.title2.weight(.bold))
                    Text(LF("Ora hai la versione %@", current)).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Cosa c'è di nuovo")).font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(notes.indices, id: \.self) { i in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "sparkle").font(.caption).foregroundStyle(.tint)
                                    Text(notes[i]).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            HStack(spacing: 10) {
                Button(L("Salta questa versione")) { act(.skip) }
                    .buttonStyle(.glass)
                Spacer()
                Button(L("Più tardi")) { act(.later) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(L("Aggiorna e riavvia")) { act(.update) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(width: 480)
    }
}

/// Nessun dato dell'utente viene inviato: solo una richiesta anonima all'API pubblica di GitHub.
final class Updater {
    static let shared = Updater()
    private let info = Bundle.main.infoDictionary ?? [:]
    private var repo: String { info["TPUpdateRepo"] as? String ?? "" }
    private var publicKey: String { info["TPUpdatePublicKey"] as? String ?? "" }
    var current: String { info["CFBundleShortVersionString"] as? String ?? "0" }
    private var busy = false

    struct Release: Decodable {
        let tag_name: String; let body: String?; let html_url: String; let assets: [Asset]
    }
    struct Asset: Decodable { let name: String; let browser_download_url: URL }
    struct UpdateError: LocalizedError { let errorDescription: String? }

    /// All'avvio: al massimo un controllo ogni 6 ore, in silenzio se non c'è niente di nuovo.
    /// Solo per le prove: TP_UPDATE_FEED punta a un finto "releases/latest" locale,
    /// TP_UPDATE_AUTOINSTALL=1 salta la domanda (la firma viene verificata comunque).
    private let env = ProcessInfo.processInfo.environment

    func checkAutomatically() {
        if env["TP_UPDATE_FEED"] != nil { check(userInitiated: false); return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !busy, !repo.isEmpty,
              let url = URL(string: env["TP_UPDATE_FEED"] ?? "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        busy = true
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Telepromptrius-updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                self.busy = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                guard let data, let rel = try? JSONDecoder().decode(Release.self, from: data) else {
                    if userInitiated { self.alert(L("Impossibile controllare gli aggiornamenti"), L("Controlla la connessione a internet e riprova.")) }
                    return
                }
                let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Self.isNewer(latest, than: self.current) {
                    if !userInitiated && UserDefaults.standard.string(forKey: "skippedVersion") == latest { return }
                    self.offer(rel, version: latest)
                } else if userInitiated {
                    self.alert(L("Telepromptrius è aggiornata"), LF("Hai già la versione più recente (%@).", self.current))
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func offer(_ rel: Release, version: String) {
        if env["TP_UPDATE_AUTOINSTALL"] == "1" { install(rel); return }
        let lines = (rel.body ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-*•· ")) }
            .filter { !$0.isEmpty }
        NSApp.activate()
        UpdateWindow.show(version: version, current: current, notes: Array(lines.prefix(15))) { choice in
            switch choice {
            case .update: self.install(rel)
            case .skip: UserDefaults.standard.set(version, forKey: "skippedVersion")
            case .later: break
            }
        }
    }

    private func install(_ rel: Release) {
        let target = Bundle.main.bundleURL
        if target.path.hasPrefix("/Volumes/") {
            alert(L("Sposta prima l'app in Applicazioni"), L("Telepromptrius è aperta dall'immagine disco: trascinala in Applicazioni, aprila da lì e riprova."))
            return
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            failed(rel, LF("Non ho i permessi per sostituire l'app in %@.", target.deletingLastPathComponent().path))
            return
        }
        guard let zip = rel.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let sig = rel.assets.first(where: { $0.name == zip.name + ".sig" }) else {
            failed(rel, L("In questa versione manca il pacchetto di aggiornamento automatico."))
            return
        }
        Task {
            do {
                let (zipFile, _) = try await URLSession.shared.download(from: zip.browser_download_url)
                let zipData = try Data(contentsOf: zipFile)
                let (sigData, _) = try await URLSession.shared.data(from: sig.browser_download_url)
                guard self.verify(zipData, signature: sigData) else {
                    throw UpdateError(errorDescription: L("La firma dell'aggiornamento non corrisponde: per sicurezza non lo installo."))
                }
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("telepromptrius-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zipPath = work.appendingPathComponent("update.zip")
                try zipData.write(to: zipPath)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zipPath.path, work.path])
                let newApp = work.appendingPathComponent("Telepromptrius.app")
                guard let b = Bundle(url: newApp), b.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw UpdateError(errorDescription: L("Il pacchetto scaricato non contiene Telepromptrius."))
                }
                await MainActor.run { self.replaceAndRelaunch(target: target, with: newApp) }
            } catch {
                await MainActor.run { self.failed(rel, error.localizedDescription) }
            }
        }
    }

    private func verify(_ data: Data, signature: Data) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let sig = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Un piccolo processo aspetta che l'app si chiuda, sostituisce il pacchetto e la riapre.
    private func replaceAndRelaunch(target: URL, with newApp: URL) {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(target.path)) && /usr/bin/ditto \(q(newApp.path)) \(q(target.path))
        /usr/bin/xattr -dr com.apple.quarantine \(q(target.path)) 2>/dev/null
        /usr/bin/open \(q(target.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do { try p.run() } catch { alert(L("Aggiornamento non riuscito"), error.localizedDescription); return }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError(errorDescription: L("Non riesco ad aprire il pacchetto scaricato.")) }
    }

    private func failed(_ rel: Release, _ why: String) {
        let a = NSAlert()
        a.messageText = L("Aggiornamento non riuscito")
        a.informativeText = why + "\n\n" + L("Puoi scaricare la nuova versione a mano dalla pagina di GitHub.")
        a.addButton(withTitle: L("Apri la pagina"))
        a.addButton(withTitle: L("Chiudi"))
        if a.runModal() == .alertFirstButtonReturn, let u = URL(string: rel.html_url) { NSWorkspace.shared.open(u) }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TeleprompterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = TeleState()

    var body: some Scene {
        WindowGroup("Telepromptrius") {
            ControlView(s: state)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button(L("Informazioni su Telepromptrius")) {
                    let credits = NSAttributedString(
                        string: L("Teleprompter con schermo esteso specchiato.\nI testi sono in iCloud Drive → Telepromptrius."),
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                    NSApp.activate()
                }
                Button(L("Controlla aggiornamenti…")) { Updater.shared.check(userInitiated: true) }
            }
        }
    }
}
