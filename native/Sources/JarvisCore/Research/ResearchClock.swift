import Foundation

// The dataset's clock (plan: M01b §3.2), adapted to M1's canonical `JarvisClock`
// (decision D-26): no parallel clock protocol. `SystemClock` in the app, `ManualClock` in
// tests; the time zone travels with it because the dataset's day is LOCAL
// (`time.strftime("%Y-%m-%d")`).

public struct ResearchClock: Sendable {
    public let clock: any JarvisClock
    public let timeZone: TimeZone

    public init(_ clock: any JarvisClock = SystemClock(), timeZone: TimeZone = .current) {
        self.clock = clock
        self.timeZone = timeZone
    }

    /// `time.time()`.
    public func now() -> Double { clock.now() }

    /// `time.strftime("%Y-%m-%d", time.localtime(ts))` — Python's research day.
    public func localDate(_ ts: Double) -> String {
        PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: ts), timeZone: timeZone)
    }

    /// `time.strftime("%z", time.localtime(ts))`: "+0100", "-0230" (libc: sign, then the
    /// offset in whole minutes as HHMM; seconds floored like `localtime(float)`).
    public func utcOffset(_ ts: Double) -> String {
        let seconds = ts.rounded(.down)
        var off = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: seconds))
        let sign = off < 0 ? "-" : "+"
        off = abs(off) / 60
        let hhmm = (off / 60) * 100 + off % 60
        let digits = String(hhmm)
        return sign + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// The research day right now.
    public func today() -> String { localDate(now()) }
}
