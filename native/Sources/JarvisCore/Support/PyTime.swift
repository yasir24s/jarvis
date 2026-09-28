import Foundation

// Python time/datetime formatting as jarvis.py uses it, and Python round() (plan: M00 §3.6,
// §2.3). Proven against Python by the `pytime` and `pyround` golden suites.
//
// Local time comes from `TimeZone.secondsFromGMT(for:)` only; no Calendar, no locale. Names
// are the C-locale English ones that Python's time.strftime produces (it never sets LC_TIME).

public enum PyTime {
    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                                   "Friday", "Saturday"]                  // tm_wday order
    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]

    /// `time.strftime(format, time.localtime(t))` for the directive set jarvis.py uses:
    /// %A %B %H %I %M %S %Y %d %m %p and %% (zero-padded; %p is "AM"/"PM"). Seconds are
    /// floored, as `time.localtime(float)` does. Any other directive is a precondition
    /// failure, so a new one cannot silently mis-render.
    public static func strftime(_ format: String, _ date: Date, timeZone: TimeZone) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let c = Civil(local: seconds + Int64(offset(seconds, timeZone)))
        var out = ""
        var it = format.unicodeScalars.makeIterator()
        while let ch = it.next() {
            guard ch == "%" else { out.unicodeScalars.append(ch); continue }
            guard let d = it.next() else { preconditionFailure("PyTime.strftime: trailing % in \(format)") }
            switch d {
            case "A": out += weekdays[c.weekday]
            case "B": out += months[c.month - 1]
            case "H": out += pad2(c.hour)
            case "I": out += pad2(c.hour % 12 == 0 ? 12 : c.hour % 12)
            case "M": out += pad2(c.minute)
            case "S": out += pad2(c.second)
            case "Y": out += String(c.year)
            case "d": out += pad2(c.day)
            case "m": out += pad2(c.month)
            case "p": out += c.hour < 12 ? "AM" : "PM"
            case "%": out += "%"
            default: preconditionFailure("PyTime.strftime: unsupported directive %\(d) in \(format)")
            }
        }
        return out
    }

    /// `datetime.fromtimestamp(t).isoformat()`: naive local "YYYY-MM-DDTHH:MM:SS", plus
    /// ".ffffff" iff the microseconds are non-zero. Microseconds are rounded half-even from
    /// the fractional part, exactly as CPython's `_PyTime_ObjectToTimeval` does (so
    /// x.9999996 carries into the next second).
    public static func isoformat(_ date: Date, timeZone: TimeZone) -> String {
        let t = date.timeIntervalSince1970
        var whole = t.rounded(.towardZero)                          // modf
        var us = ((t - whole) * 1e6).rounded(.toNearestOrEven)
        if us >= 1e6 { us -= 1e6; whole += 1 } else if us < 0 { us += 1e6; whole -= 1 }
        let seconds = Int64(whole)
        let c = Civil(local: seconds + Int64(offset(seconds, timeZone)))
        var s = pad(c.year, 4) + "-" + pad2(c.month) + "-" + pad2(c.day) + "T"
            + pad2(c.hour) + ":" + pad2(c.minute) + ":" + pad2(c.second)
        if us != 0 { s += "." + pad(Int(us), 6) }
        return s
    }

    /// `datetime.fromisoformat(s).timestamp()` for naive local strings of the forms
    /// `YYYY-MM-DD` and `YYYY-MM-DD?HH[:MM[:SS[(.|,)f…]]]` (any single separator character;
    /// fractions truncated to microseconds; `24:00[:00]` is the next midnight). A time in
    /// the DST gap or overlap resolves like Python's fold=0. nil where Python raises — and
    /// also for the forms native does not support: basic format (`20260928T0900`), ISO week
    /// dates, and any UTC offset (Python returns an aware datetime there).
    public static func fromisoformat(_ s: String, timeZone: TimeZone) -> Date? {
        let u = Array(s.unicodeScalars)
        func num(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= u.count else { return nil }
            var v = 0
            for k in from..<(from + count) {
                guard let d = asciiDigit(u[k]) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard u.count >= 10, u[4] == "-", u[7] == "-",
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2) else { return nil }
        var hour = 0, minute = 0, second = 0, micro = 0
        if u.count > 10 {
            var j = 11                                              // u[10] is the separator
            guard let h = num(j, 2) else { return nil }
            hour = h
            j += 2
            if j < u.count {
                guard u[j] == ":", let m = num(j + 1, 2) else { return nil }
                minute = m
                j += 3
                if j < u.count {
                    guard u[j] == ":", let sec = num(j + 1, 2) else { return nil }
                    second = sec
                    j += 3
                    if j < u.count {
                        guard u[j] == "." || u[j] == "," else { return nil }
                        j += 1
                        var digits = 0
                        while j < u.count, let d = asciiDigit(u[j]) {
                            if digits < 6 { micro = micro * 10 + d }
                            digits += 1
                            j += 1
                        }
                        guard digits > 0, j == u.count else { return nil }
                        for _ in digits..<max(digits, 6) { micro *= 10 }
                    }
                }
            }
        }
        guard (1...12).contains(month), (1...daysIn(month, year)).contains(day),
              (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var days = daysFromCivil(year, month, day)
        if hour == 24 {
            guard minute == 0, second == 0, micro == 0 else { return nil }
            hour = 0
            days += 1
        }
        guard (0...23).contains(hour) else { return nil }
        let wall = days * 86400 + Int64(hour * 3600 + minute * 60 + second)
        let seconds = localToSeconds(wall, timeZone)
        return Date(timeIntervalSince1970: Double(seconds) + Double(micro) / 1e6)
    }

    // MARK: helpers

    private static func asciiDigit(_ c: Unicode.Scalar) -> Int? {
        c.value >= 0x30 && c.value <= 0x39 ? Int(c.value - 0x30) : nil
    }

    private static func offset(_ seconds: Int64, _ tz: TimeZone) -> Int {
        tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
    }

    /// CPython `local_to_seconds` (fold=0): solve local(u) == wall for u.
    private static func localToSeconds(_ t: Int64, _ tz: TimeZone) -> Int64 {
        func local(_ u: Int64) -> Int64 { u + Int64(offset(u, tz)) }
        let maxFold: Int64 = 24 * 3600
        let a = local(t) - t
        let u1 = t - a
        let t1 = local(u1)
        let b: Int64
        if t1 == t {
            let u2 = u1 - maxFold                                  // fold=0: look earlier
            let bb = local(u2) - u2
            if a == bb { return u1 }
            b = bb
        } else {
            b = t1 - u1
        }
        let u2 = t - b
        if local(u2) == t { return u2 }
        if t1 == t { return u1 }
        return max(u1, u2)                                          // in the gap (fold=0)
    }

    private static func pad2(_ v: Int) -> String { v < 10 ? "0" + String(v) : String(v) }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    private static func daysIn(_ m: Int, _ y: Int) -> Int {
        [31, isLeap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's algorithm).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = Int64(m <= 2 ? y0 - 1 : y0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = Int64(m > 2 ? m - 3 : m + 9)
        let doy = (153 * mp + 2) / 5 + Int64(d) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Broken-down wall-clock fields of a local "seconds since 1970" value.
    private struct Civil {
        var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0
        var weekday = 0                                             // 0 = Sunday (tm_wday)

        init(local: Int64) {
            var days = local / 86400
            var rem = local % 86400
            if rem < 0 { rem += 86400; days -= 1 }
            hour = Int(rem / 3600)
            minute = Int(rem % 3600 / 60)
            second = Int(rem % 60)
            weekday = Int(((days % 7) + 7 + 4) % 7)                 // 1970-01-01 was a Thursday
            let z = days + 719468
            let era = (z >= 0 ? z : z - 146096) / 146097
            let doe = z - era * 146097
            let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            day = Int(doy - (153 * mp + 2) / 5 + 1)
            month = Int(mp < 10 ? mp + 3 : mp - 9)
            year = Int(yoe + era * 400) + (month <= 2 ? 1 : 0)
        }
    }
}

public enum PyMath {
    /// Python `round(x, ndigits)` for floats: correctly rounded from the exact binary value
    /// (round(2.675, 2) == 2.67, round(0.0125, 3) == 0.013), ties-to-even, keeps -0.0; NaN
    /// and ±inf round to themselves. Mirrors CPython's `double_round`: round the exact decimal
    /// expansion, then parse "<digits>e<-ndigits>" back with a correctly rounded strtod.
    /// Where Python raises OverflowError (a result beyond Double.greatestFiniteMagnitude),
    /// this returns ±infinity.
    public static func round(_ x: Double, _ ndigits: Int) -> Double {
        guard x.isFinite else { return x }
        if ndigits > 323 { return x }                               // NDIGITS_MAX
        if ndigits < -308 { return 0.0 * x }                        // NDIGITS_MIN: ±0.0
        if x == 0 { return x }
        let (digits, scale) = exactDecimal(Swift.abs(x))            // |x| = digits × 10^-scale
        if ndigits >= scale { return x }                            // nothing to round away
        let drop = scale - ndigits
        var kept: [UInt8]
        let roundUp: Bool
        if drop > digits.count {
            kept = []
            roundUp = false                                         // below 0.1 of a unit
        } else {
            kept = Array(digits[..<(digits.count - drop)])
            let tail = digits[(digits.count - drop)...]
            let first = tail.first!
            if first != 5 {
                roundUp = first > 5
            } else if tail.dropFirst().contains(where: { $0 != 0 }) {
                roundUp = true
            } else {
                roundUp = (kept.last ?? 0) % 2 == 1                 // exact tie: to even
            }
        }
        if roundUp {
            var k = kept.count - 1
            while k >= 0 && kept[k] == 9 { kept[k] = 0; k -= 1 }
            if k >= 0 { kept[k] += 1 } else { kept.insert(1, at: 0) }
        }
        let body = kept.isEmpty ? "0" : String(decoding: kept.map { $0 + 0x30 }, as: UTF8.self)
        return Double((x < 0 ? "-" : "") + body + "e" + String(-ndigits))!
    }

    /// Python `round(x)` for floats: nearest integer, ties to even. Precondition: finite and
    /// within Int (Python raises on non-finite values and has unbounded ints).
    public static func round(_ x: Double) -> Int {
        let r = x.rounded(.toNearestOrEven)
        precondition(r.isFinite && r >= -0x1p63 && r < 0x1p63, "PyMath.round: \(x) out of Int range")
        return Int(r)
    }

    /// The exact decimal expansion of a positive finite double: decimal digits (0…9, no
    /// leading zeros) and a scale with x == digits × 10^-scale.
    static func exactDecimal(_ x: Double) -> ([UInt8], Int) {
        var m = x.significandBitPattern
        var e = Int(x.exponentBitPattern)
        if e == 0 { e = 1 } else { m |= 1 << 52 }                   // subnormal / normal
        e -= 1075                                                   // x = m × 2^e
        var n = BigUInt(m)
        var scale = 0
        if e >= 0 {
            n.shiftLeft(e)
        } else {
            // m / 2^k == m × 5^k / 10^k
            var k = -e
            scale = k
            while k >= 13 { n.multiply(by: 1_220_703_125); k -= 13 }  // 5^13
            var p: UInt32 = 1
            for _ in 0..<k { p *= 5 }
            n.multiply(by: p)
        }
        return (n.decimalDigits(), scale)
    }

    /// Minimal unsigned bignum: just enough for exact double → decimal.
    struct BigUInt {
        var limbs: [UInt32]                                         // little-endian

        init(_ v: UInt64) { limbs = [UInt32(truncatingIfNeeded: v), UInt32(v >> 32)] }

        mutating func multiply(by f: UInt32) {
            var carry: UInt64 = 0
            for k in limbs.indices {
                let p = UInt64(limbs[k]) * UInt64(f) + carry
                limbs[k] = UInt32(truncatingIfNeeded: p)
                carry = p >> 32
            }
            if carry != 0 { limbs.append(UInt32(carry)) }
        }

        mutating func shiftLeft(_ bits: Int) {
            let words = bits / 32, rem = bits % 32
            if rem != 0 {
                var carry: UInt32 = 0
                for k in limbs.indices {
                    let v = limbs[k]
                    limbs[k] = v << rem | carry
                    carry = v >> (32 - rem)
                }
                if carry != 0 { limbs.append(carry) }
            }
            limbs.insert(contentsOf: repeatElement(0, count: words), at: 0)
        }

        func decimalDigits() -> [UInt8] {
            var n = limbs
            while n.last == 0 { n.removeLast() }
            var chunks: [UInt32] = []                               // base 10^9, least first
            while !n.isEmpty {
                var rem: UInt64 = 0
                for k in n.indices.reversed() {
                    let cur = rem << 32 | UInt64(n[k])
                    n[k] = UInt32(cur / 1_000_000_000)
                    rem = cur % 1_000_000_000
                }
                chunks.append(UInt32(rem))
                while n.last == 0 { n.removeLast() }
            }
            guard let top = chunks.popLast() else { return [0] }
            var out = String(top).utf8.map { $0 - 0x30 }
            for c in chunks.reversed() {
                let s = String(c)
                out += Array(repeating: 0, count: 9 - s.count) + s.utf8.map { $0 - 0x30 }
            }
            return out
        }
    }
}
