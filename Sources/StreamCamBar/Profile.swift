import Foundation

struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var values: [String: Int]
    /// Minutes since midnight to switch to this profile automatically; nil = manual only.
    var startMinutes: Int?
}

extension Profile {
    /// The profile whose start time most recently passed, wrapping to yesterday's last one.
    static func scheduled(in profiles: [Profile], at date: Date = Date()) -> Profile? {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let timed = profiles.filter { $0.startMinutes != nil }.sorted { $0.startMinutes! < $1.startMinutes! }
        return timed.last { $0.startMinutes! <= now } ?? timed.last
    }
}
