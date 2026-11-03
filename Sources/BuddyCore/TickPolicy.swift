/// How often the mascot loop runs. nil = no timer at all.
public enum TickPolicy {
    public static let motionHz = 30.0
    public static let tolerance = 0.2

    /// `idle`: nothing moves, waits impatiently, or shows a callout, bubble, or mini; the looping animations then run in
    /// the render server.
    public static func interval(mascots: Int, moving: Bool, fps: Double, paused: Bool, idle: Bool = false) -> Double? {
        guard mascots > 0, !paused, moving || !idle else { return nil }
        return 1 / (moving ? motionHz : max(1, fps))
    }
}
