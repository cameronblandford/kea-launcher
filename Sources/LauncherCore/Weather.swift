import Foundation

/// Forecasts from Open-Meteo (free, no key). This file builds the request, reads the
/// answer, and words it; WeatherCommand.swift does location and networking.
public enum Weather {
    public struct Current: Equatable {
        public var temperature: Double
        public var feelsLike: Double
        public var code: Int
        public var wind: Double
        public var humidity: Int
        public var isDay: Bool
    }

    public struct Hour: Equatable {
        public var time: Date
        public var temperature: Double
        public var code: Int
        public var rainChance: Int
        public var feelsLike: Double
        public var wind: Double
        public var uv: Double

        public init(time: Date, temperature: Double, code: Int, rainChance: Int, feelsLike: Double? = nil, wind: Double = 0, uv: Double = 0) {
            self.time = time
            self.temperature = temperature
            self.code = code
            self.rainChance = rainChance
            self.feelsLike = feelsLike ?? temperature
            self.wind = wind
            self.uv = uv
        }
    }

    public struct Day: Equatable {
        public var date: Date
        public var code: Int
        public var high: Double
        public var low: Double
        public var rainChance: Int
    }

    public struct Forecast: Equatable {
        public var current: Current
        public var hours: [Hour]
        public var days: [Day]
        public var timeZone: TimeZone
    }

    public static func forecastURL(latitude: Double, longitude: Double, metric: Bool) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", latitude)),
            .init(name: "longitude", value: String(format: "%.3f", longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m,is_day"),
            .init(name: "hourly", value: "temperature_2m,apparent_temperature,weather_code,precipitation_probability,wind_speed_10m,uv_index"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: metric ? "celsius" : "fahrenheit"),
            .init(name: "wind_speed_unit", value: metric ? "kmh" : "mph"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "7"),
        ]
        return c.url!
    }

    public static func geocodeURL(_ place: String) -> URL {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: place), .init(name: "count", value: "1")]
        return c.url!
    }

    /// The first match of a geocoding answer: coordinates and a "Portland, Oregon" name.
    public static func parsePlace(_ data: Data) -> (latitude: Double, longitude: Double, name: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return nil }
        // "Tokyo" in "Tokyo" is just "Tokyo".
        var parts = [first["name"] as? String].compactMap { $0 }
        if let region = first["admin1"] as? String, region != parts.first { parts.append(region) }
        let name = parts.joined(separator: ", ")
        return (lat, lon, name)
    }

    public static func parseForecast(_ data: Data) -> Forecast? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = obj["current"] as? [String: Any],
              let tzName = obj["timezone"] as? String else { return nil }
        let tz = TimeZone(identifier: tzName) ?? .current
        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        let current = Current(temperature: num(cur, "temperature_2m"), feelsLike: num(cur, "apparent_temperature"),
                              code: Int(num(cur, "weather_code")), wind: num(cur, "wind_speed_10m"),
                              humidity: Int(num(cur, "relative_humidity_2m")), isDay: num(cur, "is_day") != 0)
        // Times come as local "2026-10-02T13:00" (hourly) and "2026-10-02" (daily).
        func parse(_ s: String, _ format: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = format
            return f.date(from: s)
        }
        var hours: [Hour] = []
        if let h = obj["hourly"] as? [String: Any], let times = h["time"] as? [String],
           let temps = h["temperature_2m"] as? [NSNumber], let codes = h["weather_code"] as? [NSNumber] {
            let rain = (h["precipitation_probability"] as? [Any]) ?? []
            let feels = (h["apparent_temperature"] as? [Any]) ?? []
            let wind = (h["wind_speed_10m"] as? [Any]) ?? []
            let uv = (h["uv_index"] as? [Any]) ?? []
            func at(_ a: [Any], _ i: Int) -> Double? { i < a.count ? (a[i] as? NSNumber)?.doubleValue : nil }
            for (i, t) in times.enumerated() where i < temps.count && i < codes.count {
                guard let date = parse(t, "yyyy-MM-dd'T'HH:mm") else { continue }
                hours.append(Hour(time: date, temperature: temps[i].doubleValue, code: codes[i].intValue,
                                  rainChance: Int(at(rain, i) ?? 0), feelsLike: at(feels, i), wind: at(wind, i) ?? 0, uv: at(uv, i) ?? 0))
            }
        }
        var days: [Day] = []
        if let d = obj["daily"] as? [String: Any], let times = d["time"] as? [String],
           let codes = d["weather_code"] as? [NSNumber], let highs = d["temperature_2m_max"] as? [NSNumber],
           let lows = d["temperature_2m_min"] as? [NSNumber] {
            let rain = (d["precipitation_probability_max"] as? [Any]) ?? []
            for (i, t) in times.enumerated() where i < codes.count && i < highs.count && i < lows.count {
                guard let date = parse(t, "yyyy-MM-dd") else { continue }
                days.append(Day(date: date, code: codes[i].intValue, high: highs[i].doubleValue, low: lows[i].doubleValue,
                                rainChance: (i < rain.count ? (rain[i] as? NSNumber)?.intValue : nil) ?? 0))
            }
        }
        return Forecast(current: current, hours: hours, days: days, timeZone: tz)
    }

    /// WMO weather codes as words and an SF Symbol.
    public static func describe(_ code: Int, isDay: Bool = true) -> (text: String, symbol: String) {
        switch code {
        case 0: return ("Clear", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1: return ("Mostly clear", isDay ? "sun.max.fill" : "moon.fill")
        case 2: return ("Partly cloudy", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("Cloudy", "cloud.fill")
        case 45, 48: return ("Fog", "cloud.fog.fill")
        case 51, 53, 55: return ("Drizzle", "cloud.drizzle.fill")
        case 56, 57: return ("Freezing drizzle", "cloud.sleet.fill")
        case 61: return ("Light rain", "cloud.rain.fill")
        case 63: return ("Rain", "cloud.rain.fill")
        case 65: return ("Heavy rain", "cloud.heavyrain.fill")
        case 66, 67: return ("Freezing rain", "cloud.sleet.fill")
        case 71: return ("Light snow", "cloud.snow.fill")
        case 73: return ("Snow", "cloud.snow.fill")
        case 75: return ("Heavy snow", "cloud.snow.fill")
        case 77: return ("Snow grains", "cloud.snow.fill")
        case 80, 81: return ("Showers", "cloud.sun.rain.fill")
        case 82: return ("Heavy showers", "cloud.heavyrain.fill")
        case 85, 86: return ("Snow showers", "cloud.snow.fill")
        case 95: return ("Thunderstorm", "cloud.bolt.rain.fill")
        case 96, 99: return ("Thunderstorm with hail", "cloud.bolt.rain.fill")
        default: return ("Unknown", "questionmark.circle")
        }
    }

    /// "72°" (whole degrees; the unit is implied by the settings).
    public static func degrees(_ t: Double) -> String { "\(Int(t.rounded()))°" }

    /// The next `count` hours from `now`, starting with the current hour.
    public static func upcoming(_ hours: [Hour], from now: Date, count: Int) -> [Hour] {
        let start = now.addingTimeInterval(-3599)
        return Array(hours.filter { $0.time > start }.prefix(count))
    }

    // MARK: What to wear

    public struct Advice: Equatable {
        /// "Tomorrow" when the advice is for the next day, else "Today".
        public var when: String
        /// "A light jacket · umbrella from 5pm"
        public var summary: String
        /// One line per point, for the expanded row.
        public var details: [String]
    }

    /// The hours to dress for: the rest of today until 10pm, or 8am–8pm tomorrow once it is 8pm or later.
    public static func outingHours(_ hours: [Hour], now: Date, calendar: Calendar) -> (when: String, hours: [Hour]) {
        let hour = calendar.component(.hour, from: now)
        if hour >= 20, let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            let day = hours.filter { calendar.isDate($0.time, inSameDayAs: tomorrow) && (8...20).contains(calendar.component(.hour, from: $0.time)) }
            return ("Tomorrow", day)
        }
        let start = now.addingTimeInterval(-3599)
        let today = hours.filter { $0.time > start && calendar.isDate($0.time, inSameDayAs: now) && calendar.component(.hour, from: $0.time) <= 22 }
        return ("Today", today)
    }

    /// Clothing by the coldest "feels like" you will be out in. Thresholds are in °F.
    static func layer(_ coldestF: Double) -> String {
        switch coldestF {
        case 80...: return "Shorts and a t-shirt"
        case 70..<80: return "A t-shirt"
        case 60..<70: return "Long sleeves or a light layer"
        case 50..<60: return "A sweater or light jacket"
        case 40..<50: return "A jacket"
        case 30..<40: return "A warm coat"
        default: return "A heavy coat, hat and gloves"
        }
    }

    static let snowCodes: Set<Int> = [71, 73, 75, 77, 85, 86]
    static let stormCodes: Set<Int> = [95, 96, 99]

    /// Clothing, layers, rain gear, snow boots, sun and wind, for `hours`.
    /// `metric` says the temperatures are °C and wind is km/h.
    public static func advice(for hours: [Hour], when: String, metric: Bool, calendar: Calendar) -> Advice? {
        guard !hours.isEmpty else { return nil }
        let toF: (Double) -> Double = metric ? { $0 * 9 / 5 + 32 } : { $0 }
        let mph: (Double) -> Double = metric ? { $0 / 1.609 } : { $0 }
        let feels = hours.map(\.feelsLike)
        let lo = feels.min()!, hi = feels.max()!
        let f = DateFormatter()
        f.timeZone = calendar.timeZone
        f.dateFormat = "ha"
        func time(_ d: Date) -> String { f.string(from: d).lowercased() }

        var summary = [layer(toF(lo))]
        let range = degrees(lo) == degrees(hi) ? degrees(lo) : "\(degrees(lo)) to \(degrees(hi))"
        var details = ["\(layer(toF(lo))): it feels like \(range)"]

        // A wide swing: dress for the cold part, carry a layer for the warm part or the reverse.
        if toF(hi) - toF(lo) >= 15 {
            let coldFirst = hours.first!.feelsLike < hours.last!.feelsLike
            summary.append("bring a layer")
            details.append("Bring a layer: \(coldFirst ? "cold now, warm later" : "warm now, cold later") (\(degrees(lo)) to \(degrees(hi)))")
        }

        let rainy = hours.filter { $0.rainChance >= 30 }
        let maxRain = hours.map(\.rainChance).max() ?? 0
        let windy = (hours.map(\.wind).max()).map(mph) ?? 0
        if let firstWet = rainy.first {
            let from = firstWet.time <= hours.first!.time ? "now" : "from \(time(firstWet.time))"
            if maxRain >= 60 {
                let gear = windy >= 15 ? "rain jacket" : "umbrella"
                summary.append("\(gear) \(from)")
                details.append(windy >= 15 ? "Rain jacket: rain \(maxRain)% \(from), and too windy for an umbrella (\(Int(windy.rounded())) mph)"
                                           : "Umbrella: rain \(maxRain)% \(from)")
            } else {
                summary.append("maybe an umbrella")
                details.append("Maybe an umbrella: rain up to \(maxRain)% \(from)")
            }
        }
        if let storm = hours.first(where: { stormCodes.contains($0.code) }) {
            details.append("Thunderstorms possible \(storm.time <= hours.first!.time ? "now" : "from \(time(storm.time))")")
        }
        if hours.contains(where: { snowCodes.contains($0.code) }) {
            summary.append("boots")
            details.append("Boots: snow expected")
        }
        if windy >= 20, rainy.isEmpty {
            details.append("Windy, up to \(Int(windy.rounded())) mph: a windproof layer helps")
        }
        let uv = hours.map(\.uv).max() ?? 0
        if uv >= 6 {
            summary.append("sunscreen")
            details.append("Sunscreen and sunglasses: UV index \(Int(uv.rounded()))")
        }
        return Advice(when: when, summary: summary.joined(separator: " · "), details: details)
    }
}
