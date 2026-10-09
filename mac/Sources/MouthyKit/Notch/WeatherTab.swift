import Foundation
import MouthyNotch
import SwiftUI

/// Weather from Open-Meteo (free, no key) for a place the person types. No location permission.
/// Refreshes when the tab opens, at most every 20 minutes. Off in Local Only Mode.
@MainActor final class WeatherTab: ObservableObject, NotchTab {
    static let shared = WeatherTab()
    struct Place: Codable, Equatable { var name: String; var latitude: Double; var longitude: Double; var fahrenheit: Bool }
    struct Day: Identifiable, Equatable { var id: Date { date }; let date: Date; let high: Double; let low: Double; let code: Int; let rain: Int }
    struct Now: Equatable { let temperature: Double; let feels: Double; let code: Int; let wind: Double }

    let id = "mouthy.weather"
    let title = "Weather"
    let symbolName = "cloud.sun"
    @Published var place: Place? { didSet { if let place { NotchFile.save(place, "weather.json") } } }
    @Published private(set) var now: Now?
    @Published private(set) var days: [Day] = []
    @Published private(set) var status = ""
    /// A lookup is running (finding a city or fetching the forecast).
    @Published private(set) var loading = false
    /// The lookup passed `NotchLoad.timeout`; the tab offers Retry.
    @Published private(set) var timedOut = false
    @Published var query = ""
    private var fetchedAt: Date?
    private var timeoutTask: Task<Void, Never>?
    private var lastSearch = ""

    private init() { place = NotchFile.load(Place.self, "weather.json") }

    var networkAllowed: Bool { MouthyTabs.networkAllowed() }

    func refresh(force: Bool = false) {
        guard let place, networkAllowed else { return }
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 1200 { return }
        begin("Updating…")
        Task {
            guard let decoded = await Self.forecast(for: place) else {
                finish(status: "Weather is unavailable right now.")
                return
            }
            now = Now(temperature: decoded.current.temperature_2m, feels: decoded.current.apparent_temperature,
                      code: decoded.current.weather_code, wind: decoded.current.wind_speed_10m)
            let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"
            days = decoded.daily.time.indices.compactMap { index in
                guard let date = parser.date(from: decoded.daily.time[index]) else { return nil }
                return Day(date: date, high: decoded.daily.temperature_2m_max[index], low: decoded.daily.temperature_2m_min[index],
                           code: decoded.daily.weather_code[index], rain: decoded.daily.precipitation_probability_max[index] ?? 0)
            }
            fetchedAt = Date()
            finish(status: "")
            NotchHub.shared.tabDidChange(id: id)
        }
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, networkAllowed else { return }
        lastSearch = text
        begin("Finding \(text)…")
        Task {
            guard let found = await Self.geocode(text) else { finish(status: "Couldn't find \(text)."); return }
            let usesFahrenheit = Locale.current.measurementSystem == .us
            place = Place(name: [found.name, found.admin1].compactMap { $0 }.joined(separator: ", "),
                          latitude: found.latitude, longitude: found.longitude, fahrenheit: usesFahrenheit)
            query = ""; fetchedAt = nil
            loading = false
            refresh(force: true)
        }
    }

    /// Tries the last lookup again after a timeout or failure.
    func retry() {
        if place == nil, !lastSearch.isEmpty { query = lastSearch; search() } else { refresh(force: true) }
    }

    private func begin(_ message: String) {
        status = message
        loading = true
        timedOut = false
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: NotchLoad.timeout) } catch { return }
            guard let self, self.loading else { return }
            self.timedOut = true
        }
    }

    private func finish(status message: String) {
        status = message
        loading = false
        timedOut = false
        timeoutTask?.cancel()
    }

    /// The forecast for a place, or nil (without any request) in Local Only Mode.
    static func forecast(for place: Place) async -> Forecast? {
        guard MouthyTabs.networkAllowed() else { return nil }
        let unit = place.fahrenheit ? "&temperature_unit=fahrenheit&wind_speed_unit=mph" : ""
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(place.latitude)&longitude=\(place.longitude)&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=7\(unit)"),
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 9)) else { return nil }
        return try? JSONDecoder().decode(Forecast.self, from: data)
    }

    /// The geocoder matches place names only, so "Paris, France" searches "Paris" and picks the
    /// result whose region or country matches the rest. Nil, without any request, in Local Only Mode.
    static func geocode(_ text: String) async -> Geocode.Result? {
        guard MouthyTabs.networkAllowed() else { return nil }
        let parts = text.split(whereSeparator: { $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        var attempts = [(text, [String]())]
        let words = text.split(separator: " ").map(String.init)
        if parts.count > 1 { attempts.append((parts[0], Array(parts.dropFirst()))) }
        if words.count > 1 { attempts.append((words.dropLast().joined(separator: " "), [words.last!])) }
        for (name, hints) in attempts {
            var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            components.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "10")]
            guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: components.url!, timeoutInterval: 9)),
                  let results = try? JSONDecoder().decode(Geocode.self, from: data).results, !results.isEmpty else { continue }
            if hints.isEmpty { return results[0] }
            let wanted = hints.joined(separator: " ").lowercased()
            if let match = results.first(where: { [$0.admin1, $0.country, $0.country_code].compactMap { $0?.lowercased() }
                .contains { $0.hasPrefix(wanted) || wanted.hasPrefix($0) } }) { return match }
        }
        return nil
    }

    /// Warm light for the sky: mic glow for sun, warm creams for cloud, rain and snow, ember for storms.
    var ambientColor: Color? {
        guard let code = now?.code else { return nil }
        switch code {
        case 0, 1: return MouthyTheme.glow
        case 2, 3, 45, 48: return MouthyTheme.cream2
        case 51...67, 80...82: return MouthyTheme.cream2.opacity(0.8)
        case 71...77, 85, 86: return MouthyTheme.cream
        case 95...99: return MouthyTheme.ember
        default: return nil
        }
    }

    func toggleUnit() { place?.fahrenheit.toggle(); refresh(force: true) }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: return "sun.max"
        case 1, 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67, 80...82: return "cloud.rain"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    /// First open with no saved place: use the city in the Mac's time zone (America/New_York → New York), no location access.
    private func guessPlaceIfNeeded() {
        guard place == nil, status.isEmpty, networkAllowed, let city = TimeZone.current.identifier.split(separator: "/").last else { return }
        query = city.replacingOccurrences(of: "_", with: " ")
        search()
    }

    func makeBody() -> AnyView { guessPlaceIfNeeded(); refresh(); return AnyView(WeatherView(model: self)) }

    struct Forecast: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let apparent_temperature: Double; let weather_code: Int; let wind_speed_10m: Double }
        struct Daily: Decodable { let time: [String]; let weather_code: [Int]; let temperature_2m_max: [Double]; let temperature_2m_min: [Double]; let precipitation_probability_max: [Int?] }
        let current: Current; let daily: Daily
    }
    struct Geocode: Decodable {
        struct Result: Decodable { let name: String; let admin1: String?; let country: String?; let country_code: String?; let latitude: Double; let longitude: Double }
        let results: [Result]?
    }

    /// Renders and tests: shows a forecast without fetching one.
    func showForPreview(place: Place, now: Now, days: [Day]) {
        self.place = place; self.now = now; self.days = days
        fetchedAt = Date(); finish(status: "")
    }

    /// Renders and tests: the first lookup in progress, before any forecast has arrived.
    func showLoadingForPreview() {
        now = nil; days = []
        begin("Updating…")
    }

    /// Placeholder data shaped like a real forecast, drawn redacted while loading.
    static let sampleNow = Now(temperature: 68, feels: 66, code: 1, wind: 6)
    static var sampleDays: [Day] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<7).map { offset in
            Day(date: Calendar.current.date(byAdding: .day, value: offset, to: start) ?? start,
                high: 70 + Double(offset % 3) * 3, low: 48 + Double(offset % 2) * 4, code: offset % 3 == 0 ? 1 : 3, rain: 0)
        }
    }
}

struct WeatherView: View {
    @ObservedObject var model: WeatherTab
    var body: some View {
        if !model.networkAllowed {
            NotchEmptyState(pose: .sleep, title: "Off while network use is blocked", message: "Weather needs the network. Everything else in the notch runs on this Mac.")
        } else if let now = model.now {
            // A slow refresh keeps showing the last forecast.
            forecast(now: now, days: model.days, glow: model.ambientColor, loading: false)
        } else if model.loading, !model.timedOut {
            forecast(now: WeatherTab.sampleNow, days: WeatherTab.sampleDays, glow: nil, loading: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                controls.frame(maxWidth: 236)
                if model.timedOut {
                    NotchEmptyState(pose: .sleep, title: "Weather didn't answer", message: "That took too long.", actionTitle: "Retry") { model.retry() }
                } else if !model.status.isEmpty {
                    NotchEmptyState(pose: .sleep, title: model.status, actionTitle: model.place == nil ? nil : "Retry") { model.retry() }
                } else {
                    NotchEmptyState(pose: .wave, title: "Where are you?", message: "Type a city. No location access needed.")
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The city field and the unit switch.
    private var controls: some View {
        HStack(spacing: 8) {
            NotchField(prompt: model.place == nil ? "Type a city for weather" : "Change city", text: $model.query) { model.search() }
            if let place = model.place {
                PillButton(title: place.fahrenheit ? "°F" : "°C") { model.toggleUnit() }
                    .help("Switch units")
            }
        }
    }

    /// Controls and now on the left, the week on the right at the panel's full height, so its bars end with the
    /// same bottom margin as every other tab.
    private func forecast(now: WeatherTab.Now, days: [WeatherTab.Day], glow: Color?, loading: Bool) -> some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                controls
                NowView(now: now, place: loading ? "City name" : model.place?.name, glow: glow, fahrenheit: model.place?.fahrenheit ?? false)
                    .skeleton(loading)
            }
            .frame(width: 236, alignment: .leading)
            WeekView(days: days)
                .skeleton(loading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The temperature now, how it feels, and where.
struct NowView: View {
    let now: WeatherTab.Now
    let place: String?
    let glow: Color?
    var fahrenheit = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: WeatherTab.symbol(now.code))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(now.code <= 2 ? AnyShapeStyle(barGradient) : AnyShapeStyle(MouthyTheme.cream))
                .font(.system(size: 34, weight: .light))
                .shadow(color: (glow ?? MouthyTheme.glow).opacity(0.6), radius: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Int(now.temperature.rounded()))°").font(.system(size: 36, weight: .light, design: .rounded))
                    .foregroundStyle(MouthyTheme.cream)
                    .contentTransition(.numericText())
                Text("Feels \(Int(now.feels.rounded()))° · wind \(Int(now.wind.rounded())) \(fahrenheit ? "mph" : "km/h")")
                    .font(.system(size: 12.5)).foregroundStyle(MouthyTheme.cream2).lineLimit(1)
                if let place {
                    Label(place, systemImage: "mappin")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(MouthyTheme.cream2).lineLimit(1)
                }
            }
        }
    }
}

/// The week as columns: weekday, sky, high, the day's range as a bar floating within the week's, low, and
/// the chance of rain when any day has one worth showing. The bars take whatever height is left.
struct WeekView: View {
    let days: [WeatherTab.Day]
    @Environment(\.redactionReasons) private var redaction
    var body: some View {
        let placeholder = redaction.contains(.placeholder)
        let low = days.map(\.low).min() ?? 0, high = days.map(\.high).max() ?? 1
        let showsRain = days.contains { $0.rain >= 30 }
        HStack(alignment: .top, spacing: 4) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    // Every column gets its weekday; today is the bright one. "Today" did not fit seven columns.
                    let today = Calendar.current.isDateInToday(day.date)
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 12, weight: today ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(today ? MouthyTheme.cream : MouthyTheme.cream2)
                        .fixedSize()
                        .accessibilityLabel(today ? "Today" : day.date.formatted(.dateTime.weekday(.wide)))
                    Image(systemName: WeatherTab.symbol(day.code))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(day.code <= 2 ? MouthyTheme.glow : MouthyTheme.cream)
                        .frame(height: 16)
                    Text("\(Int(day.high.rounded()))°").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                    // This day's range against the week's: the bar floats between the week's low and high.
                    GeometryReader { box in
                        let span = max(high - low, 1)
                        let top = box.size.height * (high - day.high) / span
                        let bottom = box.size.height * (day.low - low) / span
                        ZStack(alignment: .top) {
                            Capsule(style: .circular).fill(MouthyTheme.cream.opacity(0.07))
                            Capsule(style: .circular).fill(placeholder ? AnyShapeStyle(MouthyTheme.cream.opacity(0.12)) : AnyShapeStyle(barGradient))
                                .padding(.top, top).padding(.bottom, bottom)
                        }
                    }
                    .frame(width: 5)
                    .frame(minHeight: 14, maxHeight: .infinity)
                    Text("\(Int(day.low.rounded()))°").font(.system(size: 12, design: .rounded)).foregroundStyle(MouthyTheme.cream2)
                    if showsRain {
                        // Same height in every column, so the bars stay comparable.
                        Text(day.rain >= 30 ? "\(day.rain)%" : " ")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.glow)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    /// The shimmering placeholder only while the first forecast loads.
    @ViewBuilder func skeleton(_ loading: Bool) -> some View {
        if loading { notchSkeleton(loading: true) } else { self }
    }
}
