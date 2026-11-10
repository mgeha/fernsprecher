import SwiftUI

/// `@State` is a macro in the macOS 27 SDK whose plugin (SwiftUIMacros) ships
/// only with Xcode, not with the Command Line Tools we build with. Going
/// through a typealias selects the classic `State` property wrapper instead.
typealias ViewState = SwiftUI.State
