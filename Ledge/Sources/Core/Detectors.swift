import Foundation

/// Spots a quick side-to-side shake: 3 direction changes within `window` seconds.
struct ShakeDetector {
    var window = 0.5
    var turnsNeeded = 3
    var minTravel: CGFloat = 30          // points between turns; ignores jitter
    private var turns: [Double] = []
    private var direction = 0
    private var extreme: CGFloat = 0
    private var started = false

    mutating func reset() { self = ShakeDetector(window: window, turnsNeeded: turnsNeeded, minTravel: minTravel) }

    mutating func feed(x: CGFloat, t: Double) -> Bool {
        guard started else { started = true; extreme = x; return false }
        if direction == 0 {
            if abs(x - extreme) >= minTravel { direction = x > extreme ? 1 : -1; extreme = x }
            return false
        }
        if (x - extreme) * CGFloat(direction) > 0 { extreme = x; return false }     // still going the same way
        if abs(x - extreme) >= minTravel {                                         // went back far enough: a turn
            direction = -direction; extreme = x
            turns.append(t)
            turns.removeAll { t - $0 > window }
            if turns.count >= turnsNeeded { reset(); return true }
        }
        return false
    }
}

/// Fires once when the pointer has stayed at a screen edge for `hold` seconds.
struct EdgeHoldDetector {
    var hold = 0.4
    var zone: CGFloat = 4
    private var since: Double?
    private var current: ShelfEdge?
    private var fired = false

    mutating func reset() { since = nil; current = nil; fired = false }

    /// `allowed` nil means the feature is off.
    mutating func feed(x: CGFloat, minX: CGFloat, maxX: CGFloat, t: Double, allowed: ShelfEdge?) -> ShelfEdge? {
        let edge: ShelfEdge? = x <= minX + zone ? .left : (x >= maxX - zone ? .right : nil)
        guard let edge, edge == allowed else { reset(); return nil }
        if current != edge { current = edge; since = t; fired = false }
        if !fired, let since, t - since >= hold { fired = true; return edge }
        return nil
    }
}
