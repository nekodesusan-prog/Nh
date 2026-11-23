// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Settings files: a game's own .ini files (Documents/My Games,
//  the game's folder), added per game and edited in the app, section by section,
//  without the Files app. A file keeps its line endings, encoding, comments and
//  order: only the values that change are rewritten. A game that rewrote its
//  file since it was saved here (New Vegas rewrites sD3DDevice after a crash) is
//  noted when the file opens.
//
//  Everything above "MARK: Views" is Foundation only:
//  tests/host/check-ini-editor.py compiles it with a test harness.
//

import Foundation
import SwiftUI

/// An .ini file's text, its settings found by line. Setting a value rewrites
/// that line only; every other byte stays as it was.
struct IniDocument: Equatable {
    struct Setting: Equatable, Identifiable {
        let line: Int
        let section: String
        let key: String
        var value: String
        var id: Int { line }
    }

    private(set) var lines: [String]
    private(set) var settings: [Setting]
    /// "\r\n" or "\n", as the file had it.
    let newline: String
    let endsWithNewline: Bool

    init(text: String) {
        // Swift reads "\r\n" as one Character, so the ends are checked by scalar.
        newline = text.range(of: "\r\n") != nil ? "\r\n" : "\n"
        let scalars = text.unicodeScalars
        endsWithNewline = scalars.last == "\n"
        var body = text
        if endsWithNewline {
            let crlf = scalars.count >= 2 && scalars[scalars.index(scalars.endIndex, offsetBy: -2)] == "\r"
            body = String(String.UnicodeScalarView(scalars.dropLast(newline == "\r\n" && crlf ? 2 : 1)))
        }
        lines = body.isEmpty && endsWithNewline ? [] : body.components(separatedBy: newline)
        settings = []
        var section = ""
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let parts = Self.split(raw) else { continue }
            settings.append(Setting(line: i, section: section, key: parts.key, value: parts.value))
        }
    }

    /// "  iSize W = 1280 " -> key "iSize W", value "1280", and where the value starts.
    private static func split(_ raw: String) -> (key: String, value: String, valueStart: String.Index)? {
        guard let eq = raw.firstIndex(of: "=") else { return nil }
        let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var start = raw.index(after: eq)
        while start < raw.endIndex, raw[start] == " " || raw[start] == "\t" { start = raw.index(after: start) }
        var value = String(raw[start...])
        while let last = value.last, last == " " || last == "\t" { value.removeLast() }
        return (key, value, start)
    }

    /// The sections in file order, each with its settings.
    var sections: [(name: String, settings: [Setting])] {
        var order: [String] = []
        var grouped: [String: [Setting]] = [:]
        for s in settings {
            if grouped[s.section] == nil { order.append(s.section) }
            grouped[s.section, default: []].append(s)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// Sets the setting on `line` to `value`; the text before the value is kept.
    mutating func set(line: Int, to value: String) {
        guard let i = settings.firstIndex(where: { $0.line == line }), let parts = Self.split(lines[line]) else { return }
        let raw = lines[line]
        var tail = ""
        if let last = raw.last, last == " " || last == "\t" {
            tail = String(raw.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        }
        lines[line] = String(raw[..<parts.valueStart]) + value + (value.isEmpty ? "" : tail)
        settings[i].value = value
    }

    /// The value of `key` in `section` (case-insensitive), the first one in the file.
    func value(section: String, key: String) -> String? {
        settings.first { $0.section.caseInsensitiveCompare(section) == .orderedSame && $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    var text: String { lines.joined(separator: newline) + (endsWithNewline ? newline : "") }
}

/// A file's bytes as text, and back in the same encoding (UTF-8, with or
/// without a byte order mark, else Windows Latin 1, which every byte decodes as).
struct IniFileText: Equatable {
    var text: String
    let bom: Bool
    let utf8: Bool

    init?(data: Data) {
        let marker = Data([0xEF, 0xBB, 0xBF])
        bom = data.starts(with: marker)
        let body = bom ? data.dropFirst(3) : data[...]
        if let s = String(data: Data(body), encoding: .utf8) { text = s; utf8 = true }
        else if let s = String(data: Data(body), encoding: .windowsCP1252) ?? String(data: Data(body), encoding: .isoLatin1) { text = s; utf8 = false }
        else { return nil }
    }

    func data(_ text: String) -> Data? {
        guard let body = text.data(using: utf8 ? .utf8 : .windowsCP1252) ?? text.data(using: .isoLatin1) else { return nil }
        return (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + body
    }
}

/// The .ini files each game has added, by the game's Windows path, as paths
/// under drive_c ("users/steamuser/Documents/My Games/FalloutNV/Fallout.ini").
enum GameIniFiles {
    static let listKey = "madeira.library.iniFiles"
    static let savedKey = "madeira.library.iniSaved"

    static func files(_ windowsPath: String, defaults: UserDefaults = .standard) -> [String] {
        (defaults.dictionary(forKey: listKey) as? [String: [String]])?[windowsPath.lowercased()] ?? []
    }

    static func setFiles(_ files: [String], for windowsPath: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: listKey) as? [String: [String]]) ?? [:]
        all[windowsPath.lowercased()] = files.isEmpty ? nil : files
        defaults.set(all, forKey: listKey)
    }

    static func add(_ file: String, for windowsPath: String, defaults: UserDefaults = .standard) {
        var list = files(windowsPath, defaults: defaults)
        guard !list.contains(where: { $0.caseInsensitiveCompare(file) == .orderedSame }) else { return }
        list.append(file)
        setFiles(list, for: windowsPath, defaults: defaults)
    }

    static func remove(_ file: String, for windowsPath: String, defaults: UserDefaults = .standard) {
        setFiles(files(windowsPath, defaults: defaults).filter { $0 != file }, for: windowsPath, defaults: defaults)
    }

    /// A short name for a file: from "My Games" on, or from the game's folder on.
    static func label(_ file: String, gameFolder: String?) -> String {
        let parts = file.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0.caseInsensitiveCompare("My Games") == .orderedSame }) {
            return parts[i...].joined(separator: "\\")
        }
        if let folder = gameFolder?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !folder.isEmpty,
           file.lowercased().hasPrefix(folder.lowercased() + "/") {
            let name = folder.split(separator: "/").last.map(String.init) ?? folder
            return name + "\\" + file.dropFirst(folder.count + 1).replacingOccurrences(of: "/", with: "\\")
        }
        return file.replacingOccurrences(of: "/", with: "\\")
    }

    /// The game's folder under drive_c: a Steam game's install folder, else the
    /// program's folder. `relativePath` is LibraryEntry.relativePath.
    static func gameFolder(relativePath: String, isDirectory: Bool) -> String {
        if isDirectory { return relativePath }
        return relativePath.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// The .ini files a game is likely to use, under drive_c: its own folder (five
    /// levels down) and every user's Documents/My Games. At most `limit`.
    static func candidates(drive: URL, gameFolder: String, limit: Int = 400) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func scan(_ folder: URL, depth: Int) {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for case let url as URL in walker {
                if found.count >= limit { return }
                if walker.level > depth { walker.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "ini" else { continue }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(drive.path + "/") else { continue }
                let relative = String(path.dropFirst(drive.path.count + 1))
                if seen.insert(relative.lowercased()).inserted { found.append(relative) }
            }
        }
        let users = drive.appendingPathComponent("users", isDirectory: true)
        for user in ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).sorted() {
            let games = users.appendingPathComponent(user).appendingPathComponent("Documents/My Games", isDirectory: true)
            if FileManager.default.fileExists(atPath: games.path) { scan(games, depth: 3) }
        }
        if !gameFolder.isEmpty { scan(drive.appendingPathComponent(gameFolder, isDirectory: true), depth: 5) }
        return found
    }

    /// A short fingerprint of a file's bytes (FNV-1a), to notice a game rewriting it.
    static func fingerprint(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    static func savedFingerprint(_ file: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: savedKey) as? [String: String])?[file.lowercased()]
    }

    static func setSavedFingerprint(_ value: String, for file: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: savedKey) as? [String: String]) ?? [:]
        all[file.lowercased()] = value
        defaults.set(all, forKey: savedKey)
    }

    /// Is this a 0/1 switch? Bethesda's names say so: bUseWaterShader.
    static func isSwitch(key: String, value: String) -> Bool {
        guard value == "0" || value == "1", key.count > 1, key.first == "b" else { return false }
        return key.dropFirst().first?.isUppercase == true
    }
}

/// What a setting in a Bethesda game's .ini file does, for the ⓘ next to it. Known
/// settings have a sentence; any other gets what its name's first letter says about
/// its value (bName a switch, iName a whole number, and so on), or nothing.
enum IniSettingHelp {
    static func describe(key: String) -> String? {
        let name = key.trimmingCharacters(in: .whitespaces)
        if let known = known[name.lowercased()] { return known }
        return kind(name)
    }

    /// The Bethesda naming habit: one lower- or upper-case letter for the type, then the name.
    static func kind(_ key: String) -> String? {
        let chars = Array(key)
        guard chars.count > 1, chars[1].isUppercase else { return nil }
        switch chars[0] {
        case "b": return "A switch: 1 is on, 0 is off."
        case "i": return "A whole number."
        case "u": return "A whole number, 0 or more."
        case "f": return "A number that can have a decimal point."
        case "s", "S": return "Text."
        default: return nil
        }
    }

    /// Keys in lower case. Shared by Fallout 3, New Vegas, Oblivion and Skyrim unless a sentence says otherwise.
    static let known: [String: String] = [
        // [Display]
        "isize w": "The game's width in pixels. Madeira's display size is set per game in Display; keep them the same.",
        "isize h": "The game's height in pixels. Madeira's display size is set per game in Display; keep them the same.",
        "bfull screen": "Full screen (1) or a window (0).",
        "imultisample": "Anti-aliasing: smooths jagged edges. 0 is off and fastest; 2, 4 or 8 look smoother but cost a lot of speed.",
        "imaxanisotropy": "Texture sharpness at an angle (anisotropic filtering), from 0 to 16. Higher looks sharper and costs a little speed.",
        "ipresentinterval": "V-sync: 1 waits for the screen and stops tearing, 0 does not.",
        "itexmipmapskip": "Texture quality: 0 is full, 1 is half size, 2 is a quarter. Higher saves memory and speed.",
        "ishadowmapresolution": "The size of shadow textures. Lower (512 or 1024) is faster and blurrier.",
        "iactorshadowcountext": "How many characters cast shadows outdoors. Lower is faster.",
        "iactorshadowcountint": "How many characters cast shadows indoors. Lower is faster.",
        "bshadowsongrass": "Grass gets shadows. Off is faster.",
        "bdodepthoffield": "Blurs the background (depth of field). Off is faster and sharper.",
        "busewaterreflections": "Water reflects the world. Off is faster.",
        "flodfadeoutmultobjects": "How far away objects stay visible. Lower is faster.",
        "flodfadeoutmultitems": "How far away small items stay visible. Lower is faster.",
        "flodfadeoutmultactors": "How far away characters stay visible. Lower is faster.",
        "fdefaultfov": "Field of view in degrees: how wide the camera sees.",
        "sd3ddevice": "The graphics card the game last saw. Madeira keeps it in step with the Older NVIDIA card setting; changing it by hand makes the game reopen its launcher.",
        // [Grass]
        "fgrassstartfadedistance": "How far away grass is drawn. Lower is faster.",
        "imingrasssize": "Grass spacing: higher means less grass and more speed.",
        // [General]
        "ugridstoload": "How many cells (blocks of world) around you load in full detail. 5 is normal; higher is much slower and can crash.",
        "ugriddistanttreerange": "How many cells away distant trees are drawn.",
        "ugriddistantcount": "How many cells away the distant landscape and buildings are drawn.",
        "uinterior cell buffer": "How many indoor areas stay in memory after you leave them.",
        "uexterior cell buffer": "How many outdoor cells stay in memory after you leave them.",
        "ipreloadsizelimit": "Memory, in bytes, set aside for loading things ahead of time.",
        "bpreemptivelyunloadcells": "Frees areas from memory as soon as you leave them. Can lower memory use.",
        "inumhwthreads": "How many processor threads the game plans for.",
        "busethreadedai": "Runs characters' AI on its own thread.",
        "isavegamebackupcount": "How many backup copies of a save are kept when you save over it.",
        "ballowscriptedautosave": "Lets quests save the game automatically.",
        "bdisplaymissingcontentdialogue": "Warns when a save needs a mod or add-on that is missing.",
        "ssavegamesafecellid": "Where the game puts you if a save cannot load your spot. Leave it as it is.",
        "slanguage": "The language the game's text is in.",
        "sintrosequence": "The videos played at start. Empty skips them.",
        "bloadfacegenheadegtfiles": "New Vegas: loads the files that colour characters' faces. On fixes faces that do not match their necks; it uses more memory.",
        // [Controls]
        "busejoystick": "Controller support: 1 on, 0 off.",
        "binvertyvalues": "Inverts looking up and down.",
    ]
}

/// madeira: a game's `ue-engine-ini` line ("r.Distortion=0; r.DisableDistortion=1")
/// written into the [SystemSettings] section of its Unreal Engine user Engine.ini
/// (users/<name>/Documents/<game>/Saved/Config/WindowsNoEditor/Engine.ini, or
/// Documents/My Games/<game>/..., AppData/Local/<game>/...) before each launch.
/// The same settings a .pak "performance mod" carries, without adding files to
/// the game's folder. Only folders the game already made are touched; `ue-project`
/// names the folder when it differs from the game's own folder name.
enum UnrealUserConfig {
    static func pairs(_ value: String) -> [(key: String, value: String)] {
        value.split(whereSeparator: { $0 == ";" || $0 == "\n" }).compactMap { item -> (key: String, value: String)? in
            let t = item.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { return nil }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces), v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if k.isEmpty { return nil }
            return (key: k, value: v)
        }
    }

    /// `text` with each pair set in `section`: an existing key's line rewritten,
    /// a missing one added at the end of the section (or a new section at the end).
    static func merge(_ text: String, section: String, pairs: [(key: String, value: String)]) -> String {
        let nl = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: nl)
        if lines.last == "" { lines.removeLast() }
        var current = "", sectionEnd: Int? = nil, done = Set<String>()
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
                current = String(t[t.index(after: t.startIndex)..<close])
                if current.caseInsensitiveCompare(section) == .orderedSame { sectionEnd = i }
                continue
            }
            guard current.caseInsensitiveCompare(section) == .orderedSame else { continue }
            if !t.isEmpty { sectionEnd = i }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            if let p = pairs.first(where: { $0.key.caseInsensitiveCompare(k) == .orderedSame }) {
                lines[i] = "\(p.key)=\(p.value)"; done.insert(p.key.lowercased())
            }
        }
        let missing = pairs.filter { !done.contains($0.key.lowercased()) }.map { "\($0.key)=\($0.value)" }
        if !missing.isEmpty {
            if let end = sectionEnd { lines.insert(contentsOf: missing, at: end + 1) }
            else { if let l = lines.last, !l.isEmpty { lines.append("") }; lines.append("[\(section)]"); lines += missing }
        }
        return lines.joined(separator: nl) + nl
    }

    /// The Saved/Config/WindowsNoEditor folders under drive_c that belong to `names`.
    static func configFolders(drive: URL, names: [String]) -> [URL] {
        let fm = FileManager.default
        let users = drive.appendingPathComponent("users", isDirectory: true)
        let wanted = Set(names.map { $0.lowercased() }.filter { !$0.isEmpty })
        var out: [URL] = []
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            for root in ["Documents", "Documents/My Games", "AppData/Local"] {
                let base = user.appendingPathComponent(root, isDirectory: true)
                for dir in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
                where wanted.contains(dir.lastPathComponent.lowercased()) {
                    let cfg = dir.appendingPathComponent("Saved/Config/WindowsNoEditor", isDirectory: true)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: dir.appendingPathComponent("Saved").path, isDirectory: &isDir), isDir.boolValue { out.append(cfg) }
                }
            }
        }
        return out
    }

    /// Writes `value` (a `ue-engine-ini` line) into each matching Engine.ini; returns log lines.
    @discardableResult
    static func apply(_ value: String, drive: URL, names: [String]) -> [String] {
        let ps = pairs(value)
        guard !ps.isEmpty else { return ["[ue-ini] ue-engine-ini has no key=value pairs"] }
        let folders = configFolders(drive: drive, names: names)
        guard !folders.isEmpty else {
            return ["[ue-ini] no Saved folder for \(names.joined(separator: " / ")) under Documents, My Games or AppData/Local; start the game once, or name the folder with ue-project"]
        }
        var log: [String] = []
        for folder in folders {
            let file = folder.appendingPathComponent("Engine.ini")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var text = "", utf16 = false
            if let data = try? Data(contentsOf: file) {
                if data.starts(with: [0xFF, 0xFE]) { utf16 = true; text = String(data: data, encoding: .utf16LittleEndian) ?? "" }
                else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }
                if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            }
            let merged = merge(text, section: "SystemSettings", pairs: ps)
            let out = utf16 ? Data([0xFF, 0xFE]) + (merged.data(using: .utf16LittleEndian) ?? Data()) : Data(merged.utf8)
            do { try out.write(to: file, options: .atomic); log.append("[ue-ini] \(file.path.components(separatedBy: "drive_c/").last ?? file.path): [SystemSettings] \(ps.map { "\($0.key)=\($0.value)" }.joined(separator: " "))") }
            catch { log.append("[ue-ini] could not write \(file.lastPathComponent): \(error.localizedDescription)") }
        }
        return log
    }
}

// MARK: Views

/// Game details › Settings files: the game's added .ini files, and "Add .ini file".
struct GameIniFilesSection: View {
    let windowsPath: String
    let gameFolder: String
    @State private var files: [String] = []

    var body: some View {
        Section {
            ForEach(files, id: \.self) { file in
                NavigationLink {
                    IniFileEditor(file: file, title: (file as NSString).lastPathComponent)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((file as NSString).lastPathComponent)
                        Text(GameIniFiles.label(file, gameFolder: gameFolder)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { GameIniFiles.remove(files[i], for: windowsPath) }
                files = GameIniFiles.files(windowsPath)
            }
            // Pushed, not a sheet: a sheet hung on a row of this Form closed by itself
            // when the page redrew (Cameron, iPhone, 2026-10-26).
            NavigationLink {
                IniFilePicker(gameFolder: gameFolder, added: Set(files.map { $0.lowercased() })) { file in
                    GameIniFiles.add(file, for: windowsPath)
                    files = GameIniFiles.files(windowsPath)
                }
            } label: {
                Label("Add .ini file", systemImage: "plus")
            }
        } footer: {
            Text("A game's own settings files, like Fallout.ini or FalloutPrefs.ini. Changes are saved into the file; close the game first. Swipe left to take a file off this list (the file stays).")
        }
        .onAppear { files = GameIniFiles.files(windowsPath) }
    }
}

/// The .ini files under the game's folder and Documents/My Games, to add one.
struct IniFilePicker: View {
    let gameFolder: String
    let added: Set<String>
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var found: [String]?
    @State private var query = ""

    var body: some View {
        List {
            if let found {
                let shown = query.isEmpty ? found : found.filter { $0.localizedCaseInsensitiveContains(query) }
                if shown.isEmpty {
                    Text(found.isEmpty ? "No .ini files in the game's folder or Documents › My Games yet. A game often writes its files the first time it runs." : "No file matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.self) { file in
                    Button {
                        pick(file); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((file as NSString).lastPathComponent).foregroundStyle(.primary)
                                Text(GameIniFiles.label(file, gameFolder: gameFolder)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if added.contains(file.lowercased()) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(added.contains(file.lowercased()))
                }
            } else {
                HStack { ProgressView(); Text("Looking for .ini files").foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $query, prompt: "File name")
        .navigationTitle("Add .ini file").navigationBarTitleDisplayMode(.inline)
        .task {
            guard found == nil else { return }
            let folder = gameFolder, drive = LibraryModel.drive
            let list = await Task.detached(priority: .userInitiated) { GameIniFiles.candidates(drive: drive, gameFolder: folder) }.value
            found = list
        }
    }
}

/// One .ini file, section by section: each setting's value can be changed;
/// Save writes only the changed lines.
struct IniFileEditor: View {
    let file: String
    let title: String
    @State private var original: Data?
    @State private var encoding: IniFileText?
    @State private var document: IniDocument?
    @State private var changed = false
    @State private var query = ""
    @State private var note: String?
    @State private var error: String?
    @State private var info: IniDocument.Setting?

    private var url: URL { LibraryModel.drive.appendingPathComponent(file) }

    var body: some View {
        Form {
            if let note { Section { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if let document {
                if document.settings.isEmpty { Section { Text("This file has no settings (key = value lines).").foregroundStyle(.secondary) } }
                ForEach(document.sections, id: \.name) { group in
                    let rows = query.isEmpty ? group.settings : group.settings.filter { $0.key.localizedCaseInsensitiveContains(query) || group.name.localizedCaseInsensitiveContains(query) }
                    if !rows.isEmpty {
                        Section(group.name.isEmpty ? "Settings" : "[\(group.name)]") {
                            ForEach(rows) { setting in row(setting) }
                        }
                    }
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .searchable(text: $query, prompt: "Setting or section")
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!changed) }
        }
        .onAppear { if document == nil { load() } }
        .alert(info?.key ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } }), presenting: info) { _ in
            Button("OK") {}
        } message: { setting in
            let section = setting.section.isEmpty ? "" : "In [\(setting.section)]. "
            Text(section + (IniSettingHelp.describe(key: setting.key) ?? "No description for this setting yet."))
        }
    }

    @ViewBuilder private func row(_ setting: IniDocument.Setting) -> some View {
        if GameIniFiles.isSwitch(key: setting.key, value: setting.value) {
            Toggle(isOn: Binding(get: { setting.value == "1" }, set: { update(setting.line, $0 ? "1" : "0") })) {
                label(setting)
            }
        } else {
            LabeledContent {
                TextField("", text: Binding(get: { setting.value }, set: { update(setting.line, $0) }))
                    .multilineTextAlignment(.trailing).font(.callout.monospaced())
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } label: {
                label(setting)
            }
        }
    }

    /// The key, and a blue ⓘ that shows its full name and what it does.
    private func label(_ setting: IniDocument.Setting) -> some View {
        HStack(spacing: 6) {
            Text(setting.key).font(.callout.monospaced())
            Button { info = setting } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).foregroundStyle(.blue)
                .accessibilityLabel("About \(setting.key)")
        }
    }

    private func update(_ line: Int, _ value: String) {
        guard document?.settings.first(where: { $0.line == line })?.value != value else { return }
        document?.set(line: line, to: value)
        changed = true
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), let decoded = IniFileText(data: data) else {
            error = "This file could not be read. It may have been moved or deleted."
            return
        }
        original = data; encoding = decoded
        document = IniDocument(text: decoded.text)
        changed = false
        if let saved = GameIniFiles.savedFingerprint(file), saved != GameIniFiles.fingerprint(data) {
            note = "The game changed this file after it was last saved here. Check your changes are still set."
        }
    }

    private func save() {
        guard let document, let encoding, let out = encoding.data(document.text) else { return }
        // A game running (or another app) may have written it since it opened here.
        if let now = try? Data(contentsOf: url), now != original {
            error = "The file changed while it was open here, so nothing was saved. Go back and open it again."
            return
        }
        do {
            try out.write(to: url, options: .atomic)
            original = out; changed = false; error = nil; note = nil
            GameIniFiles.setSavedFingerprint(GameIniFiles.fingerprint(out), for: file)
            LogStore.shared.log("[ini-editor] saved \(file)")
        } catch {
            self.error = "Not saved: \(error.localizedDescription)"
        }
    }
}
