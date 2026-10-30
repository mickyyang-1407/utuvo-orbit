import Foundation

enum CalculationError: LocalizedError, Equatable {
    case invalid, tooComplex, divideByZero, nonFinite, incompatibleUnits, belowAbsoluteZero
    var errorDescription: String? {
        switch self {
        case .invalid: "Check the expression / 請檢查算式"
        case .tooComplex: "Expression is too long or deeply nested / 算式太長或巢狀過深"
        case .divideByZero: "Cannot divide by zero / 不能除以零"
        case .nonFinite: "Result is outside the supported range / 結果超出範圍"
        case .incompatibleUnits: "Choose units of the same kind / 請選擇同類單位"
        case .belowAbsoluteZero: "Temperature is below absolute zero / 溫度低於絕對零度"
        }
    }
}

/// A bounded arithmetic grammar, never an executable expression or a scripting engine.
enum OrbitCalculator {
    static func evaluate(_ input: String) throws -> Double {
        guard input.count <= 512 else { throw CalculationError.tooComplex }
        let normalized = input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "π", with: "pi")
        var parser = try Parser(normalized)
        let result = try parser.parse(0, depth: 0)
        guard parser.index == parser.tokens.count else { throw CalculationError.invalid }
        guard result.isFinite else { throw CalculationError.nonFinite }
        return result == 0 ? 0 : result
    }
    static func format(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private enum Token: Equatable { case number(Double), name(String), op(Character), left, right }
    private struct Parser {
        var tokens: [Token] = []
        var index = 0
        init(_ input: String) throws {
            let chars = Array(input); var i = 0
            func digit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if digit(c) || c == "." {
                    let start = i
                    while i < chars.count && digit(chars[i]) { i += 1 }
                    if i < chars.count && chars[i] == "." {
                        i += 1; while i < chars.count && digit(chars[i]) { i += 1 }
                    }
                    if i < chars.count && (chars[i] == "e" || chars[i] == "E") {
                        i += 1
                        if i < chars.count && (chars[i] == "+" || chars[i] == "-") { i += 1 }
                        let exponent = i
                        while i < chars.count && digit(chars[i]) { i += 1 }
                        guard i > exponent else { throw CalculationError.invalid }
                    }
                    guard let value = Double(String(chars[start..<i])), value.isFinite else { throw CalculationError.invalid }
                    tokens.append(.number(value))
                } else if c >= "a" && c <= "z" {
                    let start = i
                    while i < chars.count && chars[i] >= "a" && chars[i] <= "z" { i += 1 }
                    tokens.append(.name(String(chars[start..<i])))
                } else {
                    switch c {
                    case "(": tokens.append(.left)
                    case ")": tokens.append(.right)
                    case "+", "-", "*", "/", "^", "%": tokens.append(.op(c))
                    default: throw CalculationError.invalid
                    }
                    i += 1
                }
            }
        }
        mutating func parse(_ minimum: Int, depth: Int) throws -> Double {
            guard depth < 32 else { throw CalculationError.tooComplex }
            guard index < tokens.count else { throw CalculationError.invalid }
            let token = tokens[index]; index += 1
            var value: Double
            switch token {
            case .number(let n): value = n
            case .op(let sign) where sign == "+" || sign == "-":
                let n = try parse(25, depth: depth + 1); value = sign == "-" ? -n : n
            case .left:
                value = try parse(0, depth: depth + 1); try close()
            case .name("pi"): value = .pi
            case .name("e"): value = M_E
            case .name(let name):
                guard index < tokens.count, tokens[index] == .left else { throw CalculationError.invalid }
                index += 1
                let n = try parse(0, depth: depth + 1); try close()
                switch name {
                case "sqrt": value = sqrt(n)
                case "abs": value = abs(n)
                case "round": value = n.rounded()
                case "floor": value = floor(n)
                case "ceil": value = ceil(n)
                case "sin": value = sin(n)
                case "cos": value = cos(n)
                default: throw CalculationError.invalid
                }
            default: throw CalculationError.invalid
            }
            while index < tokens.count, case .op(let op) = tokens[index] {
                if op == "%" {
                    guard minimum <= 40 else { break }
                    index += 1; value /= 100; continue
                }
                let binding = op == "^" ? 30 : (op == "*" || op == "/" ? 20 : 10)
                guard binding >= minimum else { break }
                index += 1
                let rhs = try parse(binding + (op == "^" ? 0 : 1), depth: depth + 1)
                switch op {
                case "+": value += rhs
                case "-": value -= rhs
                case "*": value *= rhs
                case "/":
                    guard rhs != 0 else { throw CalculationError.divideByZero }; value /= rhs
                case "^": value = pow(value, rhs)
                default: throw CalculationError.invalid
                }
                guard value.isFinite else { throw CalculationError.nonFinite }
            }
            guard value.isFinite else { throw CalculationError.nonFinite }
            return value
        }
        mutating func close() throws {
            guard index < tokens.count, tokens[index] == .right else { throw CalculationError.invalid }
            index += 1
        }
    }
}

enum ConversionKind: String, CaseIterable, Identifiable {
    case length, mass, temperature, area, volume, speed, duration, data, angle, energy
    var id: Self { self }
    func title(_ c: ToolCopy) -> String {
        switch self {
        case .length: c("長度", "Length"); case .mass: c("重量", "Mass")
        case .temperature: c("溫度", "Temperature"); case .area: c("面積", "Area")
        case .volume: c("體積", "Volume"); case .speed: c("速度", "Speed")
        case .duration: c("時間長度", "Duration"); case .data: c("資料容量", "Data")
        case .angle: c("角度", "Angle"); case .energy: c("能量", "Energy")
        }
    }
    var units: [ConversionUnit] { ConversionUnit.all.filter { $0.kind == self } }
}

struct ConversionUnit: Identifiable, Equatable {
    let id: String
    let kind: ConversionKind
    let scale: Double
    var offset: Double = 0
    static let all: [Self] = [
        .init(id: "m", kind: .length, scale: 1), .init(id: "cm", kind: .length, scale: 0.01),
        .init(id: "mm", kind: .length, scale: 0.001), .init(id: "km", kind: .length, scale: 1000),
        .init(id: "in", kind: .length, scale: 0.0254), .init(id: "ft", kind: .length, scale: 0.3048),
        .init(id: "yd", kind: .length, scale: 0.9144), .init(id: "mi", kind: .length, scale: 1609.344),
        .init(id: "kg", kind: .mass, scale: 1), .init(id: "g", kind: .mass, scale: 0.001),
        .init(id: "mg", kind: .mass, scale: 0.000001), .init(id: "lb", kind: .mass, scale: 0.45359237),
        .init(id: "oz", kind: .mass, scale: 0.028349523125),
        .init(id: "°C", kind: .temperature, scale: 1, offset: 273.15),
        .init(id: "°F", kind: .temperature, scale: 5 / 9, offset: 459.67),
        .init(id: "K", kind: .temperature, scale: 1),
        .init(id: "m²", kind: .area, scale: 1), .init(id: "cm²", kind: .area, scale: 0.0001),
        .init(id: "km²", kind: .area, scale: 1_000_000), .init(id: "ft²", kind: .area, scale: 0.09290304),
        .init(id: "acre", kind: .area, scale: 4046.8564224), .init(id: "ha", kind: .area, scale: 10_000),
        .init(id: "L", kind: .volume, scale: 1), .init(id: "mL", kind: .volume, scale: 0.001),
        .init(id: "m³", kind: .volume, scale: 1000), .init(id: "US gal", kind: .volume, scale: 3.785411784),
        .init(id: "US fl oz", kind: .volume, scale: 0.0295735295625),
        .init(id: "m/s", kind: .speed, scale: 1), .init(id: "km/h", kind: .speed, scale: 1 / 3.6),
        .init(id: "mph", kind: .speed, scale: 0.44704), .init(id: "kn", kind: .speed, scale: 0.514444444444),
        .init(id: "s", kind: .duration, scale: 1), .init(id: "ms", kind: .duration, scale: 0.001),
        .init(id: "min", kind: .duration, scale: 60), .init(id: "h", kind: .duration, scale: 3600),
        .init(id: "d", kind: .duration, scale: 86400),
        .init(id: "B", kind: .data, scale: 1), .init(id: "kB", kind: .data, scale: 1000),
        .init(id: "MB", kind: .data, scale: 1_000_000), .init(id: "GB", kind: .data, scale: 1_000_000_000),
        .init(id: "KiB", kind: .data, scale: 1024), .init(id: "MiB", kind: .data, scale: 1_048_576),
        .init(id: "GiB", kind: .data, scale: 1_073_741_824),
        .init(id: "rad", kind: .angle, scale: 1), .init(id: "deg", kind: .angle, scale: .pi / 180),
        .init(id: "turn", kind: .angle, scale: 2 * .pi),
        .init(id: "J", kind: .energy, scale: 1), .init(id: "kJ", kind: .energy, scale: 1000),
        .init(id: "kWh", kind: .energy, scale: 3_600_000), .init(id: "kcal", kind: .energy, scale: 4184)
    ]
    static func convert(_ value: Double, from: String, to: String) throws -> Double {
        guard let source = all.first(where: { $0.id == from }), let target = all.first(where: { $0.id == to }),
              source.kind == target.kind else { throw CalculationError.incompatibleUnits }
        guard value.isFinite else { throw CalculationError.nonFinite }
        let base = (value + source.offset) * source.scale
        if source.kind == .temperature, base < -0.0000001 { throw CalculationError.belowAbsoluteZero }
        let result = base / target.scale - target.offset
        guard result.isFinite else { throw CalculationError.nonFinite }
        return abs(result) < 1e-12 ? 0 : result
    }
}

struct WorldClockReading: Equatable {
    let time: String
    let date: String
    let offset: String
    let dayDifference: Int
}

enum WorldClock {
    static func reading(zoneID: String, at instant: Date, relativeTo baseID: String, locale: Locale) -> WorldClockReading? {
        guard let zone = TimeZone(identifier: zoneID), let base = TimeZone(identifier: baseID) else { return nil }
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"; let time = formatter.string(from: instant)
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d"); let date = formatter.string(from: instant)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let local = calendar.dateComponents([.year, .month, .day], from: instant)
        calendar.timeZone = base; let source = calendar.dateComponents([.year, .month, .day], from: instant)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let localDate = calendar.date(from: local), let baseDate = calendar.date(from: source) else { return nil }
        let seconds = zone.secondsFromGMT(for: instant), minutes = abs(seconds) / 60
        let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", minutes / 60, minutes % 60)
        return WorldClockReading(time: time, date: date, offset: offset,
                                 dayDifference: calendar.dateComponents([.day], from: baseDate, to: localDate).day ?? 0)
    }
}
