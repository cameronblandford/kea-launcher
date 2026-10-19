import Foundation

public struct Conversion: Equatable {
    public var value: Double
    public var unit: String
}

/// Exchange rates relative to `base`, as served by frankfurter.app.
public struct CurrencyRates: Codable, Equatable {
    public var base: String
    public var rates: [String: Double]
    public var date: String

    public init(base: String, rates: [String: Double], date: String) {
        self.base = base
        self.rates = rates
        self.date = date
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(CurrencyRates.self, from: data)
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        let f = from.uppercased(), t = to.uppercased()
        func rate(_ code: String) -> Double? { code == base.uppercased() ? 1 : rates[code] }
        guard let rf = rate(f), let rt = rate(t) else { return nil }
        return amount / rf * rt
    }
}

/// Parses "10 mi in km", "72f to c", "100 usd in eur" and converts.
public enum UnitConverter {
    public static func convert(_ text: String, rates: CurrencyRates?) -> Conversion? {
        guard let (amount, from, to) = parse(text) else { return nil }
        if let fu = unit(named: from), let tu = unit(named: to) {
            guard sameFamily(fu, tu) else { return nil }
            let m = Measurement(value: amount, unit: fu).converted(to: tu)
            return Conversion(value: m.value, unit: tu.symbol)
        }
        if isCurrency(from), isCurrency(to) {
            guard let rates, let v = rates.convert(amount, from: from, to: to) else { return nil }
            return Conversion(value: v, unit: to.uppercased())
        }
        return nil
    }

    static func parse(_ text: String) -> (Double, String, String)? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        // Use the LAST separator so "10 in in cm" treats the first "in" as inches.
        var split: (String, String)?
        for sep in [" in ", " to "] {
            if let r = lower.range(of: sep, options: .backwards) {
                let candidate = (String(lower[..<r.lowerBound]), String(lower[r.upperBound...]))
                if split == nil || candidate.0.count > split!.0.count { split = candidate }
            }
        }
        guard let (lhs, to) = split else { return nil }
        let toUnit = to.trimmingCharacters(in: .whitespaces)
        guard !toUnit.isEmpty, toUnit.allSatisfy({ $0.isLetter || $0 == "/" }) else { return nil }

        let cleaned = lhs.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let digits = cleaned.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(digits) else { return nil }
        let from = cleaned.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, from.allSatisfy({ $0.isLetter || $0 == "/" }) else { return nil }
        return (amount, from, toUnit)
    }

    private static let families: [Dimension.Type] = [
        UnitLength.self, UnitMass.self, UnitTemperature.self, UnitVolume.self, UnitSpeed.self,
        UnitDuration.self, UnitInformationStorage.self, UnitArea.self, UnitEnergy.self,
    ]

    /// Foundation's unit constants are private subclasses, so compare by family, not exact class.
    static func sameFamily(_ a: Dimension, _ b: Dimension) -> Bool {
        families.contains { a.isKind(of: $0) && b.isKind(of: $0) }
    }

    public static func isCurrency(_ s: String) -> Bool {
        s.count == 3 && s.allSatisfy(\.isLetter)
    }

    private static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604800))

    static func unit(named raw: String) -> Dimension? {
        let n = raw.lowercased()
        let table: [String: Dimension] = [
            // length
            "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters, "km": UnitLength.kilometers,
            "in": UnitLength.inches, "inch": UnitLength.inches, "inches": UnitLength.inches,
            "ft": UnitLength.feet, "feet": UnitLength.feet, "foot": UnitLength.feet,
            "yd": UnitLength.yards, "yards": UnitLength.yards,
            "mi": UnitLength.miles, "mile": UnitLength.miles, "miles": UnitLength.miles,
            "nmi": UnitLength.nauticalMiles,
            // mass
            "mg": UnitMass.milligrams, "g": UnitMass.grams, "kg": UnitMass.kilograms,
            "oz": UnitMass.ounces, "lb": UnitMass.pounds, "lbs": UnitMass.pounds, "pounds": UnitMass.pounds,
            "st": UnitMass.stones, "stone": UnitMass.stones,
            // temperature
            "c": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit, "k": UnitTemperature.kelvin,
            "celsius": UnitTemperature.celsius, "fahrenheit": UnitTemperature.fahrenheit,
            // volume
            "ml": UnitVolume.milliliters, "l": UnitVolume.liters, "liters": UnitVolume.liters,
            "gal": UnitVolume.gallons, "gallon": UnitVolume.gallons, "gallons": UnitVolume.gallons,
            "qt": UnitVolume.quarts, "pt": UnitVolume.pints, "cup": UnitVolume.cups, "cups": UnitVolume.cups,
            "floz": UnitVolume.fluidOunces, "tsp": UnitVolume.teaspoons, "tbsp": UnitVolume.tablespoons,
            // speed
            "kph": UnitSpeed.kilometersPerHour, "kmh": UnitSpeed.kilometersPerHour, "km/h": UnitSpeed.kilometersPerHour,
            "mph": UnitSpeed.milesPerHour, "m/s": UnitSpeed.metersPerSecond, "kn": UnitSpeed.knots, "knots": UnitSpeed.knots,
            // duration
            "s": UnitDuration.seconds, "sec": UnitDuration.seconds, "seconds": UnitDuration.seconds,
            "min": UnitDuration.minutes, "mins": UnitDuration.minutes, "minutes": UnitDuration.minutes,
            "h": UnitDuration.hours, "hr": UnitDuration.hours, "hrs": UnitDuration.hours, "hours": UnitDuration.hours,
            "d": day, "day": day, "days": day, "wk": week, "week": week, "weeks": week,
            // data
            "b": UnitInformationStorage.bytes, "bytes": UnitInformationStorage.bytes,
            "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes,
            "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
            "kib": UnitInformationStorage.kibibytes, "mib": UnitInformationStorage.mebibytes,
            "gib": UnitInformationStorage.gibibytes, "tib": UnitInformationStorage.tebibytes,
            "bit": UnitInformationStorage.bits, "bits": UnitInformationStorage.bits,
            // area
            "sqm": UnitArea.squareMeters, "sqft": UnitArea.squareFeet, "sqkm": UnitArea.squareKilometers,
            "sqmi": UnitArea.squareMiles, "acre": UnitArea.acres, "acres": UnitArea.acres, "ha": UnitArea.hectares,
            // energy
            "j": UnitEnergy.joules, "kj": UnitEnergy.kilojoules, "cal": UnitEnergy.calories, "kcal": UnitEnergy.kilocalories,
            "kwh": UnitEnergy.kilowattHours,
        ]
        return table[n]
    }
}
