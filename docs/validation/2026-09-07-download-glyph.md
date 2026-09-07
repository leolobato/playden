# Download glyph and game actions — 2026-09-07

Applied the adopted `3b-library-download-glyph` treatment from the designer handoff:
full-color covers in Library and Home, a 30×30 bottom-right download mark for not-installed
games, 10 px insets, dark 80% circle, 1.5 px light border, and a 13 pt medium SF Symbol.
Queued/disconnected/broken states retain their badges and have no download mark. The mark
stays above the focused title gradient, with text space reserved to prevent overlap.

The game page's Favorite action now uses a 24 pt heart outline, becoming a filled accent heart
when selected. The 60 px button keeps its accessible Favorite/Favorited name and has an explicit
tooltip. Play uses an SF Symbol too. Unknown size placeholders no longer appear inside Install
or the tile subtitle; a known size is still shown.

`./scripts/build.sh` and deep/strict signature verification passed. Native captures were opened
and compared against both supplied screenshots:

```sh
BIGSCREEN_SNAPSHOT_DIR="$PWD/.build/download-glyph-ui" ./scripts/snapshot.sh \
  --snapshot-width 1280 \
  --snapshot-screens library-download-glyph,library-download-focused,game-unknown-size,game-favorite
```

All four captures succeeded. The grid shows both unmarked installed tiles and the marked
uninstalled Disco Elysium; the focused variant verifies title/glyph separation. Game captures
show Install without a trailing placeholder and the Favorite button in both visual states.
Snapshots use isolated fixtures and never change the live account's favorites.
