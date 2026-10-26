# Line distance (QField plugin)

Live distance from your GNSS position to a line, polygon or point, updated as you move.
Built for staking out and checking positions against a line: how far you are from it,
which side, where along it, and how far above or below its height.

*På svenska: live-avstånd från GNSS-positionen till en linje, polygon eller punkt, med
offset åt höger/vänster, avstånd längs linjen till A och B, kap/fyll mot linjens höjd,
GNSS-kvalitet och en precisionsvy för utsättning. Språk: engelska och svenska.*

## What it shows

**Lines and polygons**
- Perpendicular offset, with direction (right / left) or inside / outside for polygons.
- Distance along the line from A and to B. Values go negative, in red, when you are
  beyond the end of the line.
- Cut/Fill against the line's height (only when the line has Z values).
- The nearest segment is picked automatically as you move along the line. Tap the active
  line again to lock the segment you tap: the reference is then that segment, extended
  past both ends, like a single-segment line.
- Reverse the direction (A ↔ B) from the menu. Curved geometries are supported.

**Points and vertices**
- Tap a point feature, or use *Pick vertex* in the menu to target a vertex of any line,
  polygon or point layer.
- Shows distance, compass direction, east/north offsets and Cut/Fill.

**Precise view**
- A zooming dial for the last metres. Point targets: north up, target in the centre.
  Lines: cross-track view with the line running through the centre and ticks that scroll
  as you walk. The dot shows your position with a halo for the GNSS accuracy, and the
  view turns green when you are within the arrival tolerance.
- Settings: automatic (within a set distance), always, or off.

**Other**
- GNSS fix type and horizontal / vertical accuracy, and a clear marker when a height offset
  is active.
- Separate dashboard layouts for portrait and landscape.
- The plugin button can be moved (Settings → *Move button*); a long press while moving puts
  it back in the toolbar.
- Languages: English and Swedish (falls back to English).

## Using it

1. Tap the plugin button, then tap a line, polygon or point on the map.
2. Tap the button again to close the dashboard. Long-press it for the menu
   (pick, pick vertex, reverse, automatic segment, clear selection, settings).

Cut/Fill follows the usual convention: your GNSS height minus the target height.
Above the target is **Cut** (remove material), below is **Fill**.

## Installing

Plugin manager → *Install plugin from URL* → paste the download link of the zip in
`dist/` (or choose the zip locally), then enable the plugin.

## Notes

- Distances use the project CRS units (metres for geographic CRS); labels currently say
  `m`.
- Heights use QField's projected GNSS height, so geoid and antenna height are handled by
  QField. A height offset can be added in the settings.
- `geometry.js` is a plain module without QField dependencies and can be tested with node.
