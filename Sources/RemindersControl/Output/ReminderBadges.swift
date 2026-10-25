/// Trailing one-liner badges: a rich link and/or an image attachment.
///
/// Human output only — JSON, CSV, table output and the EventKit fallback never carry them.
public struct ReminderBadges: Equatable {
    public var link: Bool
    public var image: Bool

    public init(link: Bool = false, image: Bool = false) {
        self.link = link
        self.image = image
    }

    public var isEmpty: Bool { !link && !image }

    /// Rich link first (it reads better next to tags), then the image marker.
    public var suffix: String { (link ? " 🔗" : "") + (image ? " 🌄" : "") }
}
