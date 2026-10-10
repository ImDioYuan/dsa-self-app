import SwiftUI

/// 搜索城市（Open-Meteo 的免费地名搜索，不用 key），选中后返回中英文名和经纬度
struct PlaceSearchSheet: View {
    let onPick: (UserConfig.Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlaceSearch.Found] = []
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                } else if results.isEmpty && !query.isEmpty {
                    Text("没有找到，换个写法试试（中文或英文都可以）").foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(results) { found in
                    Button {
                        onPick(found.place)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(found.place.nameZh).foregroundStyle(.primary)
                            Text(found.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "城市名，例如 Sydney、东京")
            .task(id: query) {
                // 停止输入 0.4 秒后再搜
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await search()
            }
            .navigationTitle("添加城市")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .macSheetFrame(minWidth: 420, minHeight: 480)
        .themedTint()
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await PlaceSearch.search(text)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum PlaceSearch {
    struct Found: Identifiable {
        /// Open-Meteo 的地名 id（同名城市不止一个）
        var id: Int
        var place: UserConfig.Place
        var subtitle: String
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            var id: Int
            var name: String
            var latitude: Double
            var longitude: Double
            var country_code: String?
            var country: String?
            var admin1: String?
        }
        var results: [Result]?
    }

    /// 同时用中文和英文搜，拿到两种语言的名字（州名用英文，Worker 靠它匹配澳洲气象局的警告）
    static func search(_ name: String) async throws -> [Found] {
        async let zh = fetch(name, language: "zh")
        async let en = fetch(name, language: "en")
        let (zhResults, enResults) = try await (zh, en)
        let english = Dictionary(enResults.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 用中文搜时英文结果可能没有，反过来也一样：以搜到的为准
        let primary = zhResults.isEmpty ? enResults : zhResults
        return primary.map { r in
            let en = english[r.id] ?? r
            let place = UserConfig.Place(
                id: ConfigFormat.slug(en.name),
                nameZh: r.name,
                nameEn: en.name,
                lat: (r.latitude * 100).rounded() / 100,
                lon: (r.longitude * 100).rounded() / 100,
                country: r.country_code ?? "",
                admin1: en.admin1 ?? ""
            )
            let subtitle = [en.name, r.admin1, r.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return Found(id: r.id, place: place, subtitle: subtitle)
        }
    }

    private static func fetch(_ name: String, language: String) async throws -> [Response.Result] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data).results ?? []
    }
}
