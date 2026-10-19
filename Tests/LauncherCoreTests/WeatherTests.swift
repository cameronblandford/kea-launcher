import XCTest
@testable import LauncherCore

final class WeatherTests: XCTestCase {
    let sample = """
    {"latitude":40.64,"longitude":-73.94,"timezone":"America/New_York",
     "current":{"time":"2026-10-02T13:30","temperature_2m":81.0,"apparent_temperature":82.6,"weather_code":2,"wind_speed_10m":13.0,"relative_humidity_2m":60,"is_day":1},
     "hourly":{"time":["2026-10-02T13:00","2026-10-02T14:00","2026-10-02T15:00"],"temperature_2m":[80.4,81.2,79.9],"weather_code":[2,3,61],"precipitation_probability":[0,10,null]},
     "daily":{"time":["2026-10-02","2026-10-03"],"weather_code":[2,95],"temperature_2m_max":[83.1,70.0],"temperature_2m_min":[66.4,58.2],"precipitation_probability_max":[10,80]}}
    """

    func testParseForecast() throws {
        let f = try XCTUnwrap(Weather.parseForecast(Data(sample.utf8)))
        XCTAssertEqual(f.current.temperature, 81)
        XCTAssertEqual(f.current.code, 2)
        XCTAssertTrue(f.current.isDay)
        XCTAssertEqual(f.hours.count, 3)
        XCTAssertEqual(f.hours[2].rainChance, 0, "null rain chance reads as 0")
        XCTAssertEqual(f.days.map(\.rainChance), [10, 80])
        XCTAssertEqual(f.timeZone.identifier, "America/New_York")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = f.timeZone
        XCTAssertEqual(cal.component(.hour, from: f.hours[1].time), 14)
    }

    func testParsePlace() {
        let json = #"{"results":[{"name":"Portland","latitude":45.52,"longitude":-122.68,"admin1":"Oregon"}]}"#
        let p = Weather.parsePlace(Data(json.utf8))
        XCTAssertEqual(p?.name, "Portland, Oregon")
        XCTAssertNil(Weather.parsePlace(Data(#"{"generationtime_ms":0.1}"#.utf8)))
        let tokyo = #"{"results":[{"name":"Tokyo","latitude":35.7,"longitude":139.7,"admin1":"Tokyo"}]}"#
        XCTAssertEqual(Weather.parsePlace(Data(tokyo.utf8))?.name, "Tokyo")
    }

    func testDescribeAndFormat() {
        XCTAssertEqual(Weather.describe(0).text, "Clear")
        XCTAssertEqual(Weather.describe(0, isDay: false).symbol, "moon.stars.fill")
        XCTAssertEqual(Weather.describe(95).text, "Thunderstorm")
        XCTAssertEqual(Weather.degrees(72.5), "73°")
        XCTAssertEqual(Weather.degrees(-0.4), "0°")
    }

    func testURLsAndUpcoming() throws {
        let u = Weather.forecastURL(latitude: 40.65, longitude: -73.95, metric: true).absoluteString
        XCTAssertTrue(u.contains("temperature_unit=celsius"))
        XCTAssertTrue(Weather.geocodeURL("São Paulo").absoluteString.contains("S%C3%A3o%20Paulo"))
        let f = try XCTUnwrap(Weather.parseForecast(Data(sample.utf8)))
        let now = f.hours[1].time.addingTimeInterval(20 * 60)   // 14:20
        XCTAssertEqual(Weather.upcoming(f.hours, from: now, count: 5).count, 2)
    }
}

final class WeatherAdviceTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func hour(_ h: Int, feels: Double, rain: Int = 0, code: Int = 1, wind: Double = 5, uv: Double = 2, day: Int = 2) -> Weather.Hour {
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h))!
        return Weather.Hour(time: d, temperature: feels, code: code, rainChance: rain, feelsLike: feels, wind: wind, uv: uv)
    }

    func testMildDryDay() {
        let a = Weather.advice(for: [hour(9, feels: 62), hour(13, feels: 68), hour(18, feels: 64)], when: "Today", metric: false, calendar: cal)!
        XCTAssertEqual(a.summary, "Long sleeves or a light layer")
        XCTAssertEqual(a.details.first, "Long sleeves or a light layer: it feels like 62° to 68°")
        let flat = Weather.advice(for: [hour(9, feels: 42.2), hour(10, feels: 41.8)], when: "Today", metric: false, calendar: cal)!
        XCTAssertEqual(flat.details.first, "A jacket: it feels like 42°")
    }

    func testRainLaterAndWindyMeansJacket() {
        let a = Weather.advice(for: [hour(9, feels: 55), hour(17, feels: 52, rain: 70, code: 63, wind: 18)], when: "Today", metric: false, calendar: cal)!
        XCTAssertEqual(a.summary, "A sweater or light jacket · rain jacket from 5pm")
        let calm = Weather.advice(for: [hour(9, feels: 55), hour(17, feels: 52, rain: 70, code: 63)], when: "Today", metric: false, calendar: cal)!
        XCTAssertTrue(calm.summary.hasSuffix("umbrella from 5pm"))
    }

    func testSwingSnowSunAndMetric() {
        let swing = Weather.advice(for: [hour(8, feels: 45), hour(15, feels: 72, uv: 7)], when: "Today", metric: false, calendar: cal)!
        XCTAssertEqual(swing.summary, "A jacket · bring a layer · sunscreen")
        XCTAssertTrue(swing.details[1].contains("cold now, warm later"))
        let snow = Weather.advice(for: [hour(9, feels: 25, code: 73)], when: "Today", metric: false, calendar: cal)!
        XCTAssertTrue(snow.summary.contains("boots"))
        let celsius = Weather.advice(for: [hour(12, feels: 22)], when: "Today", metric: true, calendar: cal)!   // 72°F
        XCTAssertEqual(celsius.summary, "A t-shirt")
    }

    func testOutingHours() {
        let hours = (6...23).map { hour($0, feels: 60) } + (0...23).map { hour($0, feels: 50, day: 3) }
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12, minute: 30))!
        let today = Weather.outingHours(hours, now: noon, calendar: cal)
        XCTAssertEqual(today.when, "Today")
        XCTAssertEqual(today.hours.map { cal.component(.hour, from: $0.time) }, Array(12...22))
        let late = Weather.outingHours(hours, now: cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 21))!, calendar: cal)
        XCTAssertEqual(late.when, "Tomorrow")
        XCTAssertEqual(late.hours.count, 13)
    }
}
