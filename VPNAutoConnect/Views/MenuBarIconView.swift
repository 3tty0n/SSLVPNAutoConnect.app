import SwiftUI

struct MenuBarIconView: View {
    let status: VPNStatus

    var body: some View {
        Image(systemName: status.menuBarSymbol)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
    }
}
