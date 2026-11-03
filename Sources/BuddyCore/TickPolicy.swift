/// How often the mascot loop runs. nil = no timer at all.
public enum TickPolicy {
    public static let motionHz = 30.0
    public static let tolerance = 0.2

    /// `idle`: every buddy sleeps and nothing moves or shows a callout; the sleep loop then runs in the render server.
    public static func interval(mascots: Int, moving: Bool, fps: Double, paused: Bool, idle: Bool = false) -> Double? {
        guard mascots > 0, !paused, moving || !idle else { return nil }
        return 1 / (moving ? motionHz : max(1, fps))
    }
}
