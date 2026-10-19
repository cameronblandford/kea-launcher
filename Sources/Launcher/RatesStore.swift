import Foundation
import LauncherCore

/// Daily exchange rates from frankfurter.app (ECB data), cached at ~/.launcher/rates.json.
final class RatesStore {
    private(set) var rates: CurrencyRates?
    private let url = Paths.root.appendingPathComponent("rates.json")

    init() {
        if let data = try? Data(contentsOf: url), let r = try? CurrencyRates(data: data) { rates = r }
    }

    func refreshIfStale() {
        let today = ISO8601DateFormatter.dateOnly.string(from: Date())
        if let r = rates, r.date >= today { return }
        guard let endpoint = URL(string: "https://api.frankfurter.app/latest?from=USD") else { return }
        URLSession.shared.dataTask(with: endpoint) { [weak self] data, _, error in
            guard let self, let data, error == nil, var r = try? CurrencyRates(data: data) else {
                Log.write("rates fetch failed: \(error.map(String.init(describing:)) ?? "bad data")")
                return
            }
            // Stamp with the fetch date so we only fetch once a day, even when ECB skips weekends.
            r.date = today
            try? r.encoded().write(to: self.url, options: .atomic)
            DispatchQueue.main.async { self.rates = r }
        }.resume()
    }
}

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
