import Foundation

/// A country the user can pick for the Break timer's **second** finish-time line.
/// The flag emoji is derived from the ISO-3166 alpha-2 code (so we never hand-type
/// flag glyphs), and the timer renders the break's finish time in `tz`'s live
/// offset — i.e. "the hour in that country" at the moment the break ends.
struct BreakCountry: Equatable {
    let name: String
    let iso: String     // ISO-3166 alpha-2, uppercase — drives the flag
    let tz: String      // IANA timezone identifier

    /// Two Unicode regional-indicator symbols → 🇵🇹, 🇷🇴, …
    var flag: String {
        iso.uppercased().unicodeScalars.compactMap { s in
            (65...90).contains(s.value) ? UnicodeScalar(0x1F1E6 + s.value - 65).map(String.init) : nil
        }.joined()
    }

    var timeZone: TimeZone { TimeZone(identifier: tz) ?? .current }
}

extension BreakCountry {
    /// The fallback / first-run selection (matches the static default we shipped).
    static let portugal = BreakCountry(name: "Portugal", iso: "PT", tz: "Europe/Lisbon")

    /// A broad global list spanning the major timezones, sorted alphabetically by
    /// name for the dropdown. Extend by adding a line here — no other change needed.
    static let all: [BreakCountry] = [
        BreakCountry(name: "Argentina", iso: "AR", tz: "America/Argentina/Buenos_Aires"),
        BreakCountry(name: "Australia (Perth)", iso: "AU", tz: "Australia/Perth"),
        BreakCountry(name: "Australia (Sydney)", iso: "AU", tz: "Australia/Sydney"),
        BreakCountry(name: "Austria", iso: "AT", tz: "Europe/Vienna"),
        BreakCountry(name: "Bangladesh", iso: "BD", tz: "Asia/Dhaka"),
        BreakCountry(name: "Belgium", iso: "BE", tz: "Europe/Brussels"),
        BreakCountry(name: "Brazil (São Paulo)", iso: "BR", tz: "America/Sao_Paulo"),
        BreakCountry(name: "Bulgaria", iso: "BG", tz: "Europe/Sofia"),
        BreakCountry(name: "Canada (Toronto)", iso: "CA", tz: "America/Toronto"),
        BreakCountry(name: "Canada (Vancouver)", iso: "CA", tz: "America/Vancouver"),
        BreakCountry(name: "Chile", iso: "CL", tz: "America/Santiago"),
        BreakCountry(name: "China", iso: "CN", tz: "Asia/Shanghai"),
        BreakCountry(name: "Colombia", iso: "CO", tz: "America/Bogota"),
        BreakCountry(name: "Croatia", iso: "HR", tz: "Europe/Zagreb"),
        BreakCountry(name: "Cyprus", iso: "CY", tz: "Asia/Nicosia"),
        BreakCountry(name: "Czechia", iso: "CZ", tz: "Europe/Prague"),
        BreakCountry(name: "Denmark", iso: "DK", tz: "Europe/Copenhagen"),
        BreakCountry(name: "Egypt", iso: "EG", tz: "Africa/Cairo"),
        BreakCountry(name: "Finland", iso: "FI", tz: "Europe/Helsinki"),
        BreakCountry(name: "France", iso: "FR", tz: "Europe/Paris"),
        BreakCountry(name: "Germany", iso: "DE", tz: "Europe/Berlin"),
        BreakCountry(name: "Ghana", iso: "GH", tz: "Africa/Accra"),
        BreakCountry(name: "Greece", iso: "GR", tz: "Europe/Athens"),
        BreakCountry(name: "Hong Kong", iso: "HK", tz: "Asia/Hong_Kong"),
        BreakCountry(name: "Hungary", iso: "HU", tz: "Europe/Budapest"),
        BreakCountry(name: "Iceland", iso: "IS", tz: "Atlantic/Reykjavik"),
        BreakCountry(name: "India", iso: "IN", tz: "Asia/Kolkata"),
        BreakCountry(name: "Indonesia (Jakarta)", iso: "ID", tz: "Asia/Jakarta"),
        BreakCountry(name: "Ireland", iso: "IE", tz: "Europe/Dublin"),
        BreakCountry(name: "Israel", iso: "IL", tz: "Asia/Jerusalem"),
        BreakCountry(name: "Italy", iso: "IT", tz: "Europe/Rome"),
        BreakCountry(name: "Japan", iso: "JP", tz: "Asia/Tokyo"),
        BreakCountry(name: "Kenya", iso: "KE", tz: "Africa/Nairobi"),
        BreakCountry(name: "Malaysia", iso: "MY", tz: "Asia/Kuala_Lumpur"),
        BreakCountry(name: "Mexico", iso: "MX", tz: "America/Mexico_City"),
        BreakCountry(name: "Morocco", iso: "MA", tz: "Africa/Casablanca"),
        BreakCountry(name: "Netherlands", iso: "NL", tz: "Europe/Amsterdam"),
        BreakCountry(name: "New Zealand", iso: "NZ", tz: "Pacific/Auckland"),
        BreakCountry(name: "Nigeria", iso: "NG", tz: "Africa/Lagos"),
        BreakCountry(name: "Norway", iso: "NO", tz: "Europe/Oslo"),
        BreakCountry(name: "Pakistan", iso: "PK", tz: "Asia/Karachi"),
        BreakCountry(name: "Peru", iso: "PE", tz: "America/Lima"),
        BreakCountry(name: "Philippines", iso: "PH", tz: "Asia/Manila"),
        BreakCountry(name: "Poland", iso: "PL", tz: "Europe/Warsaw"),
        BreakCountry.portugal,
        BreakCountry(name: "Romania", iso: "RO", tz: "Europe/Bucharest"),
        BreakCountry(name: "Russia (Moscow)", iso: "RU", tz: "Europe/Moscow"),
        BreakCountry(name: "Saudi Arabia", iso: "SA", tz: "Asia/Riyadh"),
        BreakCountry(name: "Serbia", iso: "RS", tz: "Europe/Belgrade"),
        BreakCountry(name: "Singapore", iso: "SG", tz: "Asia/Singapore"),
        BreakCountry(name: "South Africa", iso: "ZA", tz: "Africa/Johannesburg"),
        BreakCountry(name: "South Korea", iso: "KR", tz: "Asia/Seoul"),
        BreakCountry(name: "Spain", iso: "ES", tz: "Europe/Madrid"),
        BreakCountry(name: "Sweden", iso: "SE", tz: "Europe/Stockholm"),
        BreakCountry(name: "Switzerland", iso: "CH", tz: "Europe/Zurich"),
        BreakCountry(name: "Taiwan", iso: "TW", tz: "Asia/Taipei"),
        BreakCountry(name: "Thailand", iso: "TH", tz: "Asia/Bangkok"),
        BreakCountry(name: "Turkey", iso: "TR", tz: "Europe/Istanbul"),
        BreakCountry(name: "Ukraine", iso: "UA", tz: "Europe/Kyiv"),
        BreakCountry(name: "United Arab Emirates", iso: "AE", tz: "Asia/Dubai"),
        BreakCountry(name: "United Kingdom", iso: "GB", tz: "Europe/London"),
        BreakCountry(name: "USA (Chicago)", iso: "US", tz: "America/Chicago"),
        BreakCountry(name: "USA (Denver)", iso: "US", tz: "America/Denver"),
        BreakCountry(name: "USA (Los Angeles)", iso: "US", tz: "America/Los_Angeles"),
        BreakCountry(name: "USA (New York)", iso: "US", tz: "America/New_York"),
        BreakCountry(name: "Vietnam", iso: "VN", tz: "Asia/Ho_Chi_Minh"),
    ].sorted { $0.name < $1.name }

    // MARK: - Persistence (remember the last pick across launches)

    private static let kSelectedTZ = "BreakTimer.country.tz"

    /// The last-picked country, or Portugal on first run / unknown stored value.
    static func loadSelected() -> BreakCountry {
        let tz = UserDefaults.standard.string(forKey: kSelectedTZ)
        return all.first { $0.tz == tz } ?? portugal
    }

    func saveSelected() {
        UserDefaults.standard.set(tz, forKey: Self.kSelectedTZ)
    }
}
