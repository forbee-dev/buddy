/// How often the mascot loop runs (review P1). nil = no timer at all.
public enum TickPolicy {
    public static let motionHz = 30.0
    public static let tolerance = 0.2

    public static func interval(mascots: Int, moving: Bool, fps: Double, paused: Bool) -> Double? {
        guard mascots > 0, !paused else { return nil }
        return 1 / (moving ? motionHz : max(1, fps))
    }
}
