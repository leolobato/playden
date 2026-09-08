# Playden icon

`playden-flat.svg` is the editable source for the macOS app icon. It uses the
app's orange (`#F0863A`) and charcoal (`#0E0D0C`), with transparent outer corners
and a play triangle cut out of the portal. `playden-mark.svg` is the standalone
mark without the charcoal tile.

The app consumes the PNG sizes checked into
`App/Resources/Assets.xcassets/AppIcon.appiconset`. After editing the source SVG,
regenerate them from the repository root:

```sh
zsh scripts/generate-app-icon.sh
```

Regeneration requires ImageMagick (`brew install imagemagick`); normal app builds
use the checked-in PNGs and do not require it. Xcode compiles the asset catalog
into the app's icon resources.
