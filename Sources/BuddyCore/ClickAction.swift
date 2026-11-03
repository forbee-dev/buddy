/// What a click on a buddy does.
public enum ClickAction: Equatable, Sendable {
    case none, openBubble, jump, jumpToParent

    public enum Kind: Sendable { case buddy, sleeping, mini }

    public static func decide(clickCount: Int, isDrag: Bool, kind: Kind) -> ClickAction {
        if isDrag { return .none }
        if clickCount < 2 { return .openBubble }
        switch kind {
        case .buddy: return .jump
        case .sleeping: return .none
        case .mini: return .jumpToParent
        }
    }
}
