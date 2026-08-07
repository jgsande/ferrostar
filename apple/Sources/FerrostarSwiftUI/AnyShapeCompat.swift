import SwiftUI

// FORK ADDITION: an iOS-13+ type-erased `Shape`, replacing the iOS-16-only `AnyShape` so
// FerrostarSwiftUI compiles at an iOS-15 deployment floor. Behaviourally identical for this use
// (clip shape + border stroke on the current-road-name pill).
struct ErasedShape: Shape {
    // `@Sendable` because `Shape` inherits `Sendable`, so `ErasedShape` does too — an un-annotated
    // closure here is a warning today and an error in the Swift 6 language mode.
    private let makePath: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        makePath = { shape.path(in: $0) }
    }

    func path(in rect: CGRect) -> Path {
        makePath(rect)
    }
}
