import SwiftUI

// FORK ADDITION: lets FerrostarSwiftUI compile at an iOS-15 deployment floor.
// Upstream Ferrostar declares iOS 16 and uses the iOS-16 `fontWeight(_:)` view modifier directly in
// its Dynamic Island / Live Activity widgets. This fork lowers the floor to iOS 15 so an iOS-15 app
// can link the package (Ferrostar itself is only ever invoked behind `@available(iOS 16, *)` at the
// call site). This shim keeps those widget views compiling; on iOS 15 it is a no-op, which is harmless
// because Live Activities / Dynamic Island are iOS-16.1+ and never render on iOS 15.
extension View {
    @ViewBuilder
    func compatFontWeight(_ weight: Font.Weight?) -> some View {
        if #available(iOS 16, *) {
            self.fontWeight(weight)
        } else {
            self
        }
    }
}
