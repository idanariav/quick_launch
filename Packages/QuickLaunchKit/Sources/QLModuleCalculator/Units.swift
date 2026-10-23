import Foundation
import QLCore

/// `20 cm in inches` → 7.874 in. Conversion is Foundation's (`Measurement`); this only
/// reads the query and knows what units are called.
struct UnitAnswerer: QueryAnswerer {
    /// Words between the two units.
    private static let connectors: Set<String> = ["in", "to", "as", "into"]

    func answer(_ query: String) -> Answer? {
        guard let (amount, rest) = NumberText.leadingNumber(Phrase.normalize(query)) else { return nil }
        let words = rest.split(separator: " ").map(String.init)
        // "in" is also inches ("5 in in cm"), so try every connector until both sides are units.
        for (index, word) in words.enumerated() where Self.connectors.contains(word) {
            guard let from = UnitNames.unit(words[..<index].joined(separator: " ")),
                  let to = UnitNames.unit(words[(index + 1)...].joined(separator: " ")),
                  UnitNames.areComparable(from, to) else { continue }
            let source = Measurement(value: amount, unit: from)
            let result = source.converted(to: to)
            return Answer(
                title: Self.format(result, style: .medium), subtitle: "\(Self.format(source, style: .long)) = \(Self.format(result, style: .long))",
                icon: .symbol("ruler"), copyText: NumberText.plain(result.value)
            )
        }
        return nil
    }

    private static func format(_ measurement: Measurement<Dimension>, style: Formatter.UnitStyle) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = style
        formatter.numberFormatter.maximumSignificantDigits = 8
        return formatter.string(from: measurement)
    }
}

/// What units are called in queries, lowercase.
enum UnitNames {
    static func unit(_ name: String) -> Dimension? {
        byName[name.hasPrefix("°") ? String(name.dropFirst()) : name]
    }

    /// Same kind of quantity. Foundation's units are private subclasses of their dimension
    /// (`_NSStatic_NSUnitLength`), so compare the dimensions' base units instead.
    static func areComparable(_ first: Dimension, _ second: Dimension) -> Bool {
        type(of: first).baseUnit().symbol == type(of: second).baseUnit().symbol
    }

    /// Foundation's km/h is rounded (0.277778 m/s), which shows in the fifth digit.
    private static let kilometersPerHour = UnitSpeed(symbol: "km/h", converter: UnitConverterLinear(coefficient: 1000.0 / 3600))
    private static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))

    private static let names: [(Dimension, [String])] = [
        // Length
        (UnitLength.millimeters, ["mm", "millimeter", "millimeters", "millimetre", "millimetres"]),
        (UnitLength.centimeters, ["cm", "centimeter", "centimeters", "centimetre", "centimetres"]),
        (UnitLength.meters, ["m", "meter", "meters", "metre", "metres"]),
        (UnitLength.kilometers, ["km", "kilometer", "kilometers", "kilometre", "kilometres"]),
        (UnitLength.inches, ["in", "inch", "inches", "\""]),
        (UnitLength.feet, ["ft", "foot", "feet", "'"]),
        (UnitLength.yards, ["yd", "yard", "yards"]),
        (UnitLength.miles, ["mi", "mile", "miles"]),
        (UnitLength.nauticalMiles, ["nmi", "nautical mile", "nautical miles"]),
        // Mass
        (UnitMass.milligrams, ["mg", "milligram", "milligrams"]),
        (UnitMass.grams, ["g", "gram", "grams"]),
        (UnitMass.kilograms, ["kg", "kilo", "kilos", "kilogram", "kilograms"]),
        (UnitMass.metricTons, ["t", "tonne", "tonnes", "metric ton", "metric tons"]),
        (UnitMass.ounces, ["oz", "ounce", "ounces"]),
        (UnitMass.pounds, ["lb", "lbs", "pound", "pounds"]),
        (UnitMass.stones, ["st", "stone", "stones"]),
        // Temperature
        (UnitTemperature.celsius, ["c", "celsius", "degrees celsius", "degrees c"]),
        (UnitTemperature.fahrenheit, ["f", "fahrenheit", "degrees fahrenheit", "degrees f"]),
        (UnitTemperature.kelvin, ["k", "kelvin"]),
        // Volume (US customary)
        (UnitVolume.milliliters, ["ml", "milliliter", "milliliters", "millilitre", "millilitres"]),
        (UnitVolume.liters, ["l", "liter", "liters", "litre", "litres"]),
        (UnitVolume.teaspoons, ["tsp", "teaspoon", "teaspoons"]),
        (UnitVolume.tablespoons, ["tbsp", "tablespoon", "tablespoons"]),
        (UnitVolume.fluidOunces, ["fl oz", "floz", "fluid ounce", "fluid ounces"]),
        (UnitVolume.cups, ["cup", "cups"]),
        (UnitVolume.pints, ["pt", "pint", "pints"]),
        (UnitVolume.quarts, ["qt", "quart", "quarts"]),
        (UnitVolume.gallons, ["gal", "gallon", "gallons"]),
        // Area
        (UnitArea.squareCentimeters, ["cm2", "cm²", "sq cm", "square centimeter", "square centimeters"]),
        (UnitArea.squareMeters, ["m2", "m²", "sq m", "square meter", "square meters", "square metre", "square metres"]),
        (UnitArea.squareKilometers, ["km2", "km²", "sq km", "square kilometer", "square kilometers"]),
        (UnitArea.squareFeet, ["ft2", "ft²", "sq ft", "square foot", "square feet"]),
        (UnitArea.squareMiles, ["mi2", "mi²", "sq mi", "square mile", "square miles"]),
        (UnitArea.acres, ["ac", "acre", "acres"]),
        (UnitArea.hectares, ["ha", "hectare", "hectares"]),
        // Speed
        (kilometersPerHour, ["km/h", "kmh", "kph", "kilometers per hour"]),
        (UnitSpeed.milesPerHour, ["mph", "miles per hour"]),
        (UnitSpeed.metersPerSecond, ["m/s", "meters per second"]),
        (UnitSpeed.knots, ["kn", "knot", "knots"]),
        // Duration
        (UnitDuration.milliseconds, ["ms", "millisecond", "milliseconds"]),
        (UnitDuration.seconds, ["s", "sec", "secs", "second", "seconds"]),
        (UnitDuration.minutes, ["min", "mins", "minute", "minutes"]),
        (UnitDuration.hours, ["h", "hr", "hrs", "hour", "hours"]),
        (day, ["day", "days"]),
        (week, ["week", "weeks"]),
        // Data (decimal, as Finder counts; binary units by their own names)
        (UnitInformationStorage.bits, ["bit", "bits"]),
        (UnitInformationStorage.bytes, ["b", "byte", "bytes"]),
        (UnitInformationStorage.kilobytes, ["kb", "kilobyte", "kilobytes"]),
        (UnitInformationStorage.megabytes, ["mb", "megabyte", "megabytes"]),
        (UnitInformationStorage.gigabytes, ["gb", "gigabyte", "gigabytes"]),
        (UnitInformationStorage.terabytes, ["tb", "terabyte", "terabytes"]),
        (UnitInformationStorage.kibibytes, ["kib", "kibibyte", "kibibytes"]),
        (UnitInformationStorage.mebibytes, ["mib", "mebibyte", "mebibytes"]),
        (UnitInformationStorage.gibibytes, ["gib", "gibibyte", "gibibytes"]),
    ]

    private static let byName: [String: Dimension] = Dictionary(
        names.flatMap { unit, names in names.map { ($0, unit) } }, uniquingKeysWith: { first, _ in first }
    )
}
