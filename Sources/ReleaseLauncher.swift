import SwiftUI
import AppKit

// MARK: - Модель

struct Tracked: Identifiable, Codable, Hashable {
    var id = UUID()
    var repo: String                 // owner/name
    var installed = ""               // установленная версия (можно оставить пустой)
    var pattern = ""                 // фильтр имени файла, напр. "arm64.dmg"
    var latest = ""
    var releaseURL = ""
    var assetURL = ""
    var assetName = ""
    var error = ""

    var name: String { String(repo.split(separator: "/").last ?? "") }
    var checked: Bool { !latest.isEmpty }
    var hasUpdate: Bool { checked && !installed.isEmpty && Ver.newer(latest, than: installed) }
}

enum Ver {
    static func parts(_ s: String) -> [Int] {
        s.lowercased().split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
    static func newer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        if x.isEmpty || y.isEmpty { return a != b }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

struct GHRelease: Decodable {
    let tag_name: String
    let html_url: String
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let browser_download_url: String }
}

struct Err: LocalizedError {
    let m: String
    init(_ m: String) { self.m = m }
    var errorDescription: String? { m }
}

// MARK: - Хранилище и логика

@MainActor
final class Store: ObservableObject {
    @Published var items: [Tracked] = [] { didSet { save() } }
    @Published var checking = false
    @Published var busy: Set<UUID> = []

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReleaseLauncher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("apps.json")
    }()

    init() {
        if let d = try? Data(contentsOf: file),
           let v = try? JSONDecoder().decode([Tracked].self, from: d) { items = v }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: file) }
    }

    var sorted: [Tracked] {
        items.sorted { ($0.hasUpdate ? 0 : 1, $0.name.lowercased()) < ($1.hasUpdate ? 0 : 1, $1.name.lowercased()) }
    }
    var updatesCount: Int { items.filter(\.hasUpdate).count }

    func mutate(_ id: UUID, _ f: (inout Tracked) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { f(&items[i]) }
    }

    // Принимает одну или несколько ссылок / "owner/repo" (через пробел или с новой строки)
    func add(_ text: String) {
        for raw in text.split(whereSeparator: \.isWhitespace) {
            var s = String(raw)
            for p in ["https://github.com/", "http://github.com/", "https://www.github.com/", "github.com/"] {
                if s.hasPrefix(p) { s.removeFirst(p.count); break }
            }
            let parts = s.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { continue }
            let repo = parts[0] + "/" + parts[1].replacingOccurrences(of: ".git", with: "")
            if items.contains(where: { $0.repo.lowercased() == repo.lowercased() }) { continue }
            items.append(Tracked(repo: repo))
        }
        Task { await checkAll() }
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    func checkAll() async {
        guard !checking else { return }
        checking = true
        let token = UserDefaults.standard.string(forKey: "token") ?? ""
        let jobs = items.map { ($0.id, $0.repo, $0.pattern) }

        await withTaskGroup(of: (UUID, String, GHRelease?, String).self) { g in
            for (id, repo, pattern) in jobs {
                g.addTask {
                    do { return (id, pattern, try await Store.fetch(repo, token), "") }
                    catch { return (id, pattern, nil, error.localizedDescription) }
                }
            }
            for await (id, pattern, rel, err) in g {
                mutate(id) { t in
                    guard let r = rel else { t.error = err; return }
                    let a = Store.pick(r, pattern: pattern)
                    t.error = ""
                    t.latest = r.tag_name
                    t.releaseURL = r.html_url
                    t.assetURL = a?.browser_download_url ?? ""
                    t.assetName = a?.name ?? ""
                }
            }
        }
        checking = false
        NSApp.dockTile.badgeLabel = updatesCount > 0 ? "\(updatesCount)" : nil
    }

    nonisolated static func fetch(_ repo: String, _ token: String) async throws -> GHRelease {
        func get(_ path: String) async throws -> (Data, Int) {
            var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!)
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (d, resp) = try await URLSession.shared.data(for: r)
            return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var (d, code) = try await get("releases/latest")
        if code == 404 {   // нет stable-релиза — берём любой последний
            (d, code) = try await get("releases?per_page=1")
            if code == 200, let l = try JSONDecoder().decode([GHRelease].self, from: d).first { return l }
            throw Err("Релизов нет")
        }
        if code == 403 || code == 429 { throw Err("Лимит GitHub — добавьте токен в настройках") }
        guard code == 200 else { throw Err("Ошибка HTTP \(code)") }
        return try JSONDecoder().decode(GHRelease.self, from: d)
    }

    // Выбор файла: фильтр пользователя → dmg/pkg/zip → universal → под архитектуру этого Mac
    nonisolated static func pick(_ r: GHRelease, pattern: String) -> GHRelease.Asset? {
        let p = pattern.lowercased()
        let byName = r.assets.filter { p.isEmpty || $0.name.lowercased().contains(p) }
        let mac = byName.filter { ["dmg", "pkg", "zip"].contains(($0.name as NSString).pathExtension.lowercased()) }
        let pool = mac.isEmpty ? byName : mac
        #if arch(x86_64)
        let own = ["x86_64", "x64", "intel", "amd64"]
        #else
        let own = ["arm64", "aarch64", "apple"]
        #endif
        func has(_ a: GHRelease.Asset, _ keys: [String]) -> Bool {
            let n = a.name.lowercased(); return keys.contains { n.contains($0) }
        }
        return pool.first { has($0, ["universal"]) }
            ?? pool.first { has($0, own) }
            ?? pool.first { has($0, ["mac", "darwin", "osx"]) }
            ?? pool.first
    }

    // Скачивает файл в «Загрузки» и показывает в Finder
    func download(_ id: UUID) async {
        guard let t = items.first(where: { $0.id == id }) else { return }
        guard let url = URL(string: t.assetURL), !t.assetURL.isEmpty else {
            if let u = URL(string: t.releaseURL) { NSWorkspace.shared.open(u) }
            return
        }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dest = dir.appendingPathComponent(t.assetName)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
            mutate(id) { $0.installed = $0.latest; $0.error = "" }
            NSApp.dockTile.badgeLabel = updatesCount > 0 ? "\(updatesCount)" : nil
        } catch {
            mutate(id) { $0.error = error.localizedDescription }
        }
    }
}

// MARK: - Интерфейс

struct Row: View {
    @EnvironmentObject var s: Store
    let item: Tracked
    @State private var editing: Tracked?

    private var tint: Color {
        let h = item.repo.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360
        return Color(hue: Double(h) / 360, saturation: 0.55, brightness: 0.95)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.18))
                Text(String(item.name.prefix(1)).uppercased())
                    .font(.title3.bold()).foregroundColor(tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                Text(item.repo).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            status
            action
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .contextMenu {
            Button("Версия и фильтр файла…") { editing = item }
            Button("Открыть релиз на GitHub") {
                if let u = URL(string: item.releaseURL.isEmpty ? "https://github.com/\(item.repo)/releases" : item.releaseURL) {
                    NSWorkspace.shared.open(u)
                }
            }
            if item.checked { Button("Отметить актуальной") { s.mutate(item.id) { $0.installed = $0.latest } } }
            Divider()
            Button("Удалить из списка", role: .destructive) { s.remove(item.id) }
        }
        .sheet(item: $editing) { EditSheet(item: $0) }
    }

    @ViewBuilder private var status: some View {
        if !item.error.isEmpty {
            Text(item.error).font(.caption).foregroundColor(.red).lineLimit(2).frame(maxWidth: 200, alignment: .trailing)
        } else if !item.checked {
            Text("—").foregroundColor(.secondary)
        } else if item.installed.isEmpty {
            Text("Последняя: \(item.latest)").font(.callout).foregroundColor(.secondary)
        } else if item.hasUpdate {
            Text("\(item.installed) → \(item.latest)").font(.callout.monospaced()).foregroundColor(.orange)
        } else {
            Label(item.latest, systemImage: "checkmark.circle.fill").font(.callout).foregroundColor(.green)
        }
    }

    @ViewBuilder private var action: some View {
        if s.busy.contains(item.id) {
            ProgressView().controlSize(.small).frame(width: 90)
        } else if item.hasUpdate {
            Button("Обновить") { Task { await s.download(item.id) } }
                .buttonStyle(.borderedProminent).frame(width: 90)
        } else if item.checked && item.installed.isEmpty {
            Button("Скачать") { Task { await s.download(item.id) } }
                .buttonStyle(.bordered).frame(width: 90)
        } else {
            Color.clear.frame(width: 90, height: 1)
        }
    }
}

struct EditSheet: View {
    @EnvironmentObject var s: Store
    @Environment(\.dismiss) private var dismiss
    @State var item: Tracked

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.repo).font(.headline)
            TextField("Установленная версия (например 1.2.3)", text: $item.installed)
            TextField("Фильтр имени файла (например arm64.dmg)", text: $item.pattern)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    let v = item
                    s.mutate(v.id) { $0.installed = v.installed; $0.pattern = v.pattern }
                    dismiss()
                    Task { await s.checkAll() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 380)
    }
}

struct ContentView: View {
    @EnvironmentObject var s: Store
    @AppStorage("token") private var token = ""
    @State private var input = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                if s.items.isEmpty {
                    Text("Вставьте ссылки на GitHub-репозитории ниже")
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(s.sorted) { Row(item: $0) }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            addBar
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .task { await s.checkAll() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Release Launcher").font(.title2.bold())
                Text(s.updatesCount > 0 ? "Доступно обновлений: \(s.updatesCount)" : "Все отслеживаемые приложения")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .popover(isPresented: $showSettings) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GitHub-токен (необязательно)").font(.headline)
                        SecureField("ghp_…", text: $token).textFieldStyle(.roundedBorder)
                        Text("Без токена GitHub пускает 60 запросов в час, с токеном — 5000.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(16).frame(width: 300)
                }
            Button {
                Task { await s.checkAll() }
            } label: {
                if s.checking { ProgressView().controlSize(.small).frame(width: 80) }
                else { Label("Проверить", systemImage: "arrow.clockwise").frame(width: 80) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(s.checking || s.items.isEmpty)
        }
        .padding(16)
    }

    private var addBar: some View {
        HStack {
            TextField("Ссылка на GitHub или owner/repo (можно несколько)", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Добавить", action: add).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
    }

    private func add() {
        s.add(input)
        input = ""
    }
}

@main
struct ReleaseLauncherApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 620, minHeight: 440)
                .preferredColorScheme(.dark)
        }
    }
}
