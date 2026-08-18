import SwiftUI
import WidgetKit

// TalariaWidgets — the widget-extension bundle. Today it carries only the
// bot-at-work Live Activity (lock screen card + Dynamic Island); home-screen
// widgets can join this bundle later.

@main
struct TalariaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BotWorkLiveActivity()
    }
}
