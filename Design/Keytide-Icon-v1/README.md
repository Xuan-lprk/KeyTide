# Keytide · 键潮 — icon assets

The macOS product and main project are now named Keytide. Bundle identifier and helper identity are unchanged; repository and update links now use Xuan-lprk/KeyTide. Trademark and product-name availability have not been cleared.

## Integrated Composer source — 2026-11-09

`Keytide.icon` is the user-saved and approved Composer artwork, referenced directly by the main App target. Debug and Release use `ASSETCATALOG_COMPILER_APPICON_NAME = Keytide`. Edit this package in Composer for future changes; there is no second production copy. The original generated PNGs below are retained as historical concept inputs, not the production icon source.

Debug build passed. The compiled App Info.plist selects Keytide for CFBundleIconFile and CFBundleIconName; Xcode generated Keytide.icns for compatibility. Its extracted PNG was visually checked against the approved composition. Older macOS runtime appearance and Dock cache refresh were not tested. MenuIcon now uses the separate vector template described below. Build evidence: `build/IconIntegration/build.log`, preview: `build/IconIntegration/compiled-icon.png`.

The following sections document the earlier concept stage; their warnings apply to the loose PNG files, not a request to overwrite the user-saved Composer package.

## Icon Composer handoff

Create a Mac icon with a 1024×1024 canvas. Use a full-bleed dark navy background fill in Composer. Import 01-keycap.png as the middle group and 02-usage-emblem.png above it. Align both asset canvases to the same center and scale to the document canvas; preserve transparent margins. The supplied generated PNGs may have a different pixel dimension: inspect dimensions and use Composer placement controls rather than assuming a pixel-perfect 1024px export.

Keep the keycap relatively opaque for legibility. Apply Liquid Glass/refraction/shadow in Composer, not in the raster background. Preview default, dark, clear and tinted appearances, and small Dock sizes. These are raster concept layers, not an editable vector master or a finished .icon package. AI edge quality and exact layer alignment require Composer review before replacing the shipping icon.

Sources:
- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer

## Generation

Built-in image_gen, transparent_background=true. No CLI/API key used.

Prompt 01 (successful retry requested):
Use case: logo-brand. A single foreground layer for Apple Icon Composer: one front-facing mechanical keycap with completely blank face, centered occupying 72 percent of square canvas. Cool ivory-blue opaque fill, broad clean rounded bevel, minimal geometric color planes. True transparent background, ample margins. Crisp edges. No letter or symbol, no shadow, no glow, no enclosing app-icon background or rounded-square tile, no glass highlights. 1024x1024 canvas. This is the base keycap layer, separate chart emblem will be placed above it in Icon Composer.

Prompt 02:
Use case: logo-brand. Asset type: separate foreground emblem PNG layer for Apple Icon Composer, 1024x1024 square transparent canvas. Draw ONLY three solid azure blue rounded vertical bars forming an ascending usage histogram, centered as a compact emblem within the central 34% width and 30% height. Bottoms aligned at y=640 of the 1024 square, bars from left to right heights approximately 120,210,300 px; each width 80px with 28px gaps, corner radius 20px. Flat opaque blue shapes with crisp edges. True alpha around shapes. This will sit on a separate pale keyboard keycap layer. No keycap, no background, no outer app icon shape, no shadows or glass effects, no text, no watermark. All glass effects will be applied later in Icon Composer.

## Current validation

The first two generated PNGs are 1254×1254 with alpha, not the requested 1024×1024. They are candidate artwork to place on a 1024×1024 Composer canvas, not shipping app-icon output. The original keycap has visible edge speckles and is retained as an initial concept; a cleaned revision is requested separately. Do not ship the original keycap as a finished mask.

Cleanup prompt (built-in edit, transparent background):
Use case: precise-object-edit. Clean this keycap layer for a production app icon. Preserve central blank pale blue keycap geometry and position. Remove ALL stray white/cyan/blue speckles, fringe, fuzz and fragments outside the exact smooth keycap silhouette. Outside the single continuous keycap contour must be 100% transparent. Edge smooth antialiasing only one pixel, no fuzzy glow, no shadow. Simplify face lighting into a clean uniform pale ice blue surface and restrained bevel. Output same square canvas, transparent background. No new symbols.

## Handoff status — 2026-11-09

Both cleanup edit attempts failed with HTTP 502 / upstream EOF. No cleaned revision was produced. The files above are **concept-only**, with visible edge artifacts; do not replace the production icon with them. Final silhouette cleanup, layer alignment and Icon Composer appearance review remain outstanding. The built-in tool was used throughout; no paid CLI fallback was invoked.

Suggested Composer stack (back to front):
1. Native full-bleed navy background fill (suggested starting color #101D32).
2. `01-keycap.png`: pale keycap body, relatively opaque.
3. `02-usage-emblem.png`: ascending blue usage bars, separate material group.

The original concept assets are historical inputs; the approved Keytide.icon package is now integrated.

## Menu bar template

`generate-menu-icon.swift` generates the 18pt vector master at `Keytide/Assets.xcassets/MenuIcon.imageset/KeytideMenu.pdf`. The asset uses template rendering and preserves its vector representation. Source paths use a tapered keycap outline and three ascending solid bars, with no background or glass effects. Legacy smiley PNGs are retained in `LegacyMenuIcon/`, outside the production asset catalog.
