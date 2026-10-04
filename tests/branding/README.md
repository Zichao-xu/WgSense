# Brand appearance regression

Run `zsh tests/branding/check-appearance.sh <built WgSense.app> <output-directory>` after building the macOS app.

The check compiles the production `WgBrandIcon` component and loads the compiled application asset catalog through its bundle. SwiftUI `ImageRenderer` renders both light and dark environments at 16, 32, 64, 128, 256 and 512 points at 2×. It never starts WgSense, creates a daemon client, or changes system appearance.

The check verifies every image's size, nonempty artwork and transparent rounded corners. At 128 points it additionally verifies a light background with a black crossing plane in light mode, the inverse in dark mode, and the same red accent in both. Outputs include all twelve native renders, a comparison sheet, sampled color values, and a machine-readable check report.

This checks the shared in-app artwork and compiled assets. A Dock icon remains a separate app-icon asset and is not covered by the in-app appearance check. Full-page placement and live application appearance changes need a separate UI review.
