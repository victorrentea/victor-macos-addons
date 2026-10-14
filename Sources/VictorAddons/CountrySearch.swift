import Foundation

/// What the Break timer's country dropdown matches a typed query against.
///
/// A name *contains* filter alone failed on the first real search: "UK" found
/// nothing, because the row says "United Kingdom". So each country also answers
/// to its **aliases** (abbreviations, the Romanian name, the native name), to the
/// **city of its timezone** ("London", "Zurich", "New York"), and — when nothing
/// matches literally — to the same words **typed with a slip** (Damerau-
/// Levenshtein, so "Germnay" and "Swizerland" still land).
///
/// Results come back in tiers — exact word, then prefix, then contains, then
/// fuzzy — each tier keeping `BreakCountry.all`'s alphabetical order, so "us"
/// puts the four USA rows above Australia/Austria/Russia.
enum CountrySearch {

    /// Extra names per ISO code. Keyed by ISO rather than per row, so every USA /
    /// Canada / Australia / Brazil zone answers to the same words.
    static let aliases: [String: [String]] = [
        "AE": ["UAE", "Emirates", "Emiratele Arabe Unite", "Dubai", "Abu Dhabi"],
        "AR": ["Argentina"],
        "AT": ["Österreich", "Austria"],
        "AU": ["Aussie", "Australia"],
        "BE": ["Belgia", "België", "Belgique"],
        "BR": ["Brasil", "Brazilia", "Rio"],
        "CA": ["Canada"],
        "CH": ["Swiss", "Elveția", "Schweiz", "Suisse", "Svizzera", "Geneva", "Bern"],
        "CN": ["PRC", "Beijing", "Peking"],
        "CY": ["Cipru"],
        "CZ": ["Czech Republic", "Cehia", "Česko", "Ceska"],
        "DE": ["Germania", "Deutschland", "Munich", "München", "Frankfurt"],
        "DK": ["Danemarca", "Danmark"],
        "EG": ["Egipt"],
        "ES": ["Spania", "España", "Barcelona"],
        "FI": ["Finlanda", "Suomi"],
        "FR": ["Franța"],
        "GB": ["UK", "U.K.", "GB", "Great Britain", "Britain", "England", "Scotland", "Wales",
               "Anglia", "Marea Britanie", "Regatul Unit", "Edinburgh", "Manchester"],
        "GR": ["Grecia", "Hellas", "Ellada"],
        "HK": ["HK"],
        "HR": ["Croația", "Hrvatska"],
        "HU": ["Ungaria", "Magyarország"],
        "IE": ["Irlanda", "Éire", "Eire"],
        "IL": ["Tel Aviv"],
        "IN": ["Bharat", "Bangalore", "Bengaluru", "Mumbai", "Delhi", "Pune", "Hyderabad"],
        "IS": ["Islanda"],
        "IT": ["Italia", "Milan", "Milano"],
        "JP": ["Japonia", "Nippon"],
        "KR": ["Korea", "Coreea de Sud"],
        "MX": ["México"],
        "NL": ["Holland", "Olanda", "Țările de Jos", "Nederland", "Dutch", "Rotterdam"],
        "NO": ["Norvegia", "Norge"],
        "PL": ["Polonia", "Polska", "Krakow", "Kraków"],
        "PT": ["Porto"],
        "RO": ["România", "Cluj", "Iasi", "Iași", "Timisoara", "Timișoara"],
        "RS": ["Serbia", "Srbija"],
        "RU": ["Rusia"],
        "SA": ["KSA", "Arabia Saudită"],
        "SE": ["Suedia", "Sverige"],
        "TR": ["Turcia", "Türkiye", "Turkiye"],
        "UA": ["Ucraina", "Kiev"],
        "US": ["US", "U.S.", "U.S.A.", "America", "United States", "SUA", "Statele Unite", "States",
               "San Francisco", "Seattle", "Boston"],
        "ZA": ["Africa de Sud", "RSA"],
    ]

    /// The countries matching `query`, best tier first. An empty query returns `all`.
    static func search(_ query: String, in countries: [BreakCountry] = BreakCountry.all) -> [BreakCountry] {
        let q = normalize(query)
        guard !q.isEmpty else { return countries }
        let scored = countries.compactMap { c in tier(of: c, for: q).map { (c, $0) } }
        // Stable sort by tier: `enumerated` index breaks ties in the input's order.
        return scored.enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map { $0.element.0 }
    }

    /// 0 = a whole term or word equals the query, 1 = starts with it, 2 = contains
    /// it, 3 = a typo away; nil = no match.
    static func tier(of country: BreakCountry, for q: String) -> Int? {
        let terms = searchTerms(of: country)
        let words = terms.flatMap { $0.split(separator: " ").map(String.init) }
        if q == normalize(country.iso) || terms.contains(q) || words.contains(q) { return 0 }
        if terms.contains(where: { $0.hasPrefix(q) }) || words.contains(where: { $0.hasPrefix(q) }) { return 1 }
        if terms.contains(where: { $0.contains(q) }) { return 2 }
        let budget = typoBudget(forLength: q.count)
        if budget > 0, (terms + words).contains(where: { prefixDistance(q, $0) <= budget }) { return 3 }
        return nil
    }

    /// Everything a country answers to, normalized: its row name (with and without
    /// the "(City)" suffix), its aliases, and its timezone's city.
    static func searchTerms(of c: BreakCountry) -> [String] {
        let city = c.tz.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
        let raw = [c.name, city] + (aliases[c.iso] ?? [])
        return Array(Set(raw.map(normalize).filter { !$0.isEmpty }))
    }

    /// Lowercase, no diacritics, punctuation dropped ("U.K." → "uk", "(Sydney)" →
    /// "sydney"), runs of spaces collapsed.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : (CharacterSet.whitespaces.contains($0) ? " " : nil) }
        return String(kept.compactMap { $0 }).split(separator: " ").joined(separator: " ")
    }

    /// How many slips a query of this length may carry. Short queries get none —
    /// at three letters one edit matches half the list.
    static func typoBudget(forLength n: Int) -> Int {
        n <= 3 ? 0 : (n <= 6 ? 1 : 2)
    }

    /// The smallest Damerau-Levenshtein (optimal string alignment) distance between
    /// `q` and any **prefix** of `term` — so a half-typed "swizer" is one edit from
    /// "switzerland", and a swapped pair ("germnay") costs one edit, not two.
    static func prefixDistance(_ q: String, _ term: String) -> Int {
        let a = Array(q), b = Array(term)
        let n = a.count, m = b.count
        guard n > 0 else { return 0 }
        guard m > 0 else { return n }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[n].min() ?? n
    }
}
