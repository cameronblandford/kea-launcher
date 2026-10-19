import AppKit
import CoreLocation
import LauncherCore

/// `weather` shows the current weather, the next hours, and 7 days from Open-Meteo.
/// `weather <place>` looks up any place. The place comes from `weather.location`
/// in config, else Location Services, else the city of the Mac's time zone.
/// Answers are kept for 10 minutes. The default place also loads in the background
/// once a day (at launch, then at the first panel open of a new day).
final class WeatherCommand: NSObject, CLLocationManagerDelegate {
    let keyword: String
    private let configuredPlace: String
    private let metric: Bool

    private struct Entry {
        var name: String
        var forecast: Weather.Forecast?
        var fetched: Date
        var error: String?
    }

    private var cache: [String: Entry] = [:]
    private var loading: Set<String> = []
    private var location: CLLocationManager?
    private var here: (latitude: Double, longitude: Double, name: String)?
    private var locationFailed = false
    private var locationRequested = false
    /// Set after a failure that can pass (no fix yet, no network at login): when to ask
    /// again. Without it one bad start left the time zone's city in place of the real one
    /// until the next launch.
    private var locationRetryAfter: Date?

    /// True while something is still loading, so the list keeps refreshing.
    var isLive: Bool { !loading.isEmpty }

    init(config: Config.WeatherSettings) {
        keyword = config.keyword
        configuredPlace = config.location
        switch config.units.lowercased() {
        case "metric", "c", "celsius": metric = true
        case "imperial", "f", "fahrenheit": metric = false
        default: metric = Locale.current.measurementSystem == .metric
        }
        super.init()
    }

    // MARK: Location

    /// "America/New_York" -> "New York": a fair guess when location is unavailable.
    private var timeZoneCity: String {
        TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "London"
    }

    /// The one manager. Making it asks nothing of the user.
    private func manager() -> CLLocationManager {
        if let location { return location }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        location = m
        return m
    }

    private func startLocation() {
        guard !locationRequested, Bundle.main.bundleIdentifier != nil else { return }
        locationRequested = true
        let m = manager()
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() }
        m.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            let m = marks?.first
            let name = [m?.subLocality ?? m?.locality, m?.administrativeArea].compactMap { $0 }.joined(separator: ", ")
            DispatchQueue.main.async {
                guard let self else { return }
                self.here = (lat, lon, name.isEmpty ? "Here" : name)
                self.cache["here"] = nil
                self.loading.remove("here")
                self.continuePreload()
                // The place arrived after a failure: load its forecast now, ahead of the next `weather`.
                if self.locationFailed {
                    self.locationFailed = false
                    _ = self.results(argument: "")
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.write("weather: location failed: \(error.localizedDescription)")
        locationFailed = true
        let code = (error as? CLError)?.code
        if code == .locationUnknown || code == .network { locationRetryAfter = Date().addingTimeInterval(60) }
        loading.remove("here")
        continuePreload()
    }

    /// Asks for the place again after a failure that can pass. The time zone's city shows meanwhile.
    private func retryLocation() {
        guard let after = locationRetryAfter, Date() > after else { return }
        locationRetryAfter = nil
        manager().requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted: locationFailed = true; loading.remove("here"); continuePreload()
        case .authorizedAlways: manager.requestLocation()
        default: break
        }
        if preloadWaitsForAuthorization, manager.authorizationStatus != .notDetermined {
            preloadWaitsForAuthorization = false
            preloadIfNewDay()
        }
    }

    // MARK: Fetching

    private func fetch(key: String, place: String?) {
        guard !loading.contains(key) else { return }
        loading.insert(key)
        Task { [metric] in
            var entry = Entry(name: place ?? "", forecast: nil, fetched: Date(), error: nil)
            do {
                var coords: (Double, Double)
                if let place {
                    let (data, _) = try await URLSession.shared.data(from: Weather.geocodeURL(place))
                    guard let p = Weather.parsePlace(data) else { throw URLError(.cannotFindHost) }
                    coords = (p.latitude, p.longitude)
                    entry.name = p.name
                } else {
                    let h = await MainActor.run { self.here }!
                    coords = (h.latitude, h.longitude)
                    entry.name = h.name
                }
                let (data, _) = try await URLSession.shared.data(from: Weather.forecastURL(latitude: coords.0, longitude: coords.1, metric: metric))
                entry.forecast = Weather.parseForecast(data)
                if entry.forecast == nil { entry.error = "The forecast could not be read" }
            } catch {
                entry.error = place.map { "Could not find \"\($0)\" or reach the forecast service" } ?? "Could not reach the forecast service"
                Log.write("weather: \(error.localizedDescription)")
            }
            let done = entry
            await MainActor.run {
                self.cache[key] = done
                self.loading.remove(key)
                // A failed load (no network yet at login) lets the next panel open try again.
                if done.forecast == nil { self.preloaded = nil }
            }
        }
    }

    // MARK: Preload

    private var preloaded: Date?
    private var preloadWaitsForLocation = false
    private var preloadWaitsForAuthorization = false

    /// Loads the default place ahead of the first `weather`, once per calendar day, so the
    /// rows are there at once (an old answer shows while a new one loads). It never makes
    /// macOS ask for location: until that prompt has an answer, `weather` itself asks.
    func preloadIfNewDay() {
        if let preloaded, Calendar.current.isDateInToday(preloaded) { return }
        let needsLocation = configuredPlace.isEmpty && here == nil && !locationFailed
        // A new manager says "not determined" until the system answers it, so the real
        // status comes through locationManagerDidChangeAuthorization, which calls back here.
        if needsLocation, manager().authorizationStatus == .notDetermined {
            preloadWaitsForAuthorization = true
            return
        }
        preloaded = Date()
        preloadWaitsForLocation = needsLocation
        Log.write("weather: preload for the day")
        _ = results(argument: "")
    }

    /// The location (or its failure) arrived: now the forecast can load.
    private func continuePreload() {
        guard preloadWaitsForLocation else { return }
        preloadWaitsForLocation = false
        _ = results(argument: "")
    }

    // MARK: Results

    private static func icon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor, .systemYellow, .systemBlue]))
    }

    func results(argument: String) -> [Result] {
        let arg = argument.trimmingCharacters(in: .whitespaces)
        // Which place, and its cache key.
        var key: String
        var place: String?
        if !arg.isEmpty {
            key = "place:" + arg.lowercased(); place = arg
        } else if !configuredPlace.isEmpty {
            key = "place:" + configuredPlace.lowercased(); place = configuredPlace
        } else if here != nil {
            key = "here"
        } else if locationFailed || Bundle.main.bundleIdentifier == nil {
            retryLocation()
            key = "place:" + timeZoneCity.lowercased(); place = timeZoneCity
        } else {
            startLocation()
            loading.insert("here")
            return [Result(id: "weather:loading", title: "Finding your location…", subtitle: "Location Services may ask once",
                           icon: Self.icon("location"), action: .none)]
        }

        let entry = cache[key]
        // An error is tried again much sooner than a good answer.
        let keep: TimeInterval = entry?.forecast == nil ? 30 : 600
        if entry == nil || Date().timeIntervalSince(entry!.fetched) > keep { fetch(key: key, place: place) }
        guard let entry, let f = entry.forecast else {
            if let error = entry?.error, !loading.contains(key) {
                return [Result(id: "weather:error", title: error, subtitle: "weather <city> looks up another place", icon: Self.icon("exclamationmark.triangle"), action: .none)]
            }
            return [Result(id: "weather:loading", title: "Loading the weather…", subtitle: place ?? "Your location", icon: Self.icon("cloud"), action: .none)]
        }
        return rows(f, name: entry.name)
    }

    private func rows(_ f: Weather.Forecast, name: String) -> [Result] {
        let openWeather = ResultAction.openPath("/System/Applications/Weather.app")
        let c = f.current
        let (text, symbol) = Weather.describe(c.code, isDay: c.isDay)
        let wind = metric ? "km/h" : "mph"
        let today = f.days.first
        var details = ["Feels \(Weather.degrees(c.feelsLike))"]
        if let today { details.append("H \(Weather.degrees(today.high)) L \(Weather.degrees(today.low))") }
        details += ["wind \(Int(c.wind.rounded())) \(wind)", "humidity \(c.humidity)%"]
        if let today, today.rainChance > 0 { details.append("rain \(today.rainChance)%") }
        var out = [Result(id: "weather:now", title: "\(Weather.degrees(c.temperature)) \(text)\(name.isEmpty ? "" : " · \(name)")",
                          subtitle: details.joined(separator: " · "), icon: Self.icon(symbol), action: openWeather)]

        var cal0 = Calendar.current
        cal0.timeZone = f.timeZone
        let outing = Weather.outingHours(f.hours, now: Date(), calendar: cal0)
        if let advice = Weather.advice(for: outing.hours, when: outing.when, metric: metric, calendar: cal0) {
            var r = Result(id: "weather:wear", title: "\(advice.when): \(advice.summary)",
                           subtitle: advice.details.joined(separator: "\n"), icon: Self.icon("tshirt.fill"), action: openWeather)
            r.expanded = true
            out.append(r)
        }

        let hourFormat = DateFormatter()
        hourFormat.timeZone = f.timeZone
        hourFormat.dateFormat = "ha"
        let next = Weather.upcoming(f.hours, from: Date(), count: 12)
        if !next.isEmpty {
            let line = next.enumerated().map { i, h -> String in
                let rain = h.rainChance >= 30 ? " ☂\(h.rainChance)%" : ""
                let label = i == 0 && h.time <= Date() ? "now" : hourFormat.string(from: h.time).lowercased()
                return "\(label) \(Weather.degrees(h.temperature))\(rain)"
            }.joined(separator: " · ")
            var r = Result(id: "weather:hours", title: "Next 12 hours", subtitle: line, icon: Self.icon("clock"), action: openWeather)
            r.expanded = true
            out.append(r)
        }

        let dayFormat = DateFormatter()
        dayFormat.timeZone = f.timeZone
        dayFormat.dateFormat = "EEEE"
        var cal = Calendar.current
        cal.timeZone = f.timeZone
        for d in f.days {
            let (dText, dSymbol) = Weather.describe(d.code)
            let label = cal.isDateInToday(d.date) ? "Today" : cal.isDateInTomorrow(d.date) ? "Tomorrow" : dayFormat.string(from: d.date)
            out.append(Result(id: "weather:day:\(d.date.timeIntervalSince1970)", title: "\(label) · \(Weather.degrees(d.high)) / \(Weather.degrees(d.low))",
                              subtitle: dText + (d.rainChance > 0 ? " · rain \(d.rainChance)%" : ""), icon: Self.icon(dSymbol), action: openWeather))
        }
        return out
    }
}

extension WeatherCommand {
    var command: KeaCommand {
        KeaCommand(id: "weather", name: "Weather", keywords: [keyword],
                   help: [.init(keyword: keyword, summary: "Weather now, the next 12 hours, and 7 days", example: "weather · weather tokyo")],
                   // Refresh while the location or the forecast loads.
                   live: (0.3, { [unowned self] in isLive }),
                   results: { [unowned self] in results(argument: $0.argument) })
    }
}
