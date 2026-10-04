import SwiftUI

/// Both brand placements follow the containing view's light/dark appearance.
/// The app/Dock icon is not an appearance-aware source for in-app artwork.
struct WgBrandIcon: View {
    var bundle: Bundle = .main

    var body: some View {
        Image("BrandIcon", bundle: bundle)
            .resizable()
            .interpolation(.high)
            .accessibilityHidden(true)
    }
}
