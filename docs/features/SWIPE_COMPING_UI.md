# Swipe comping: frontend design notes

The swipe-comping frontend isn't built. The backend commands (`lanes/*`) and
the REAPER behaviour they rely on are in
[docs/architecture/SWIPE_COMPING.md](../architecture/SWIPE_COMPING.md); the
main frontend design (comp mode inside the Timeline, comp target vs play,
swipe and tap gestures) is tracked as planned work. These are the rules and
open issues not recorded there.

## Rules

- ▲/▼ source cycling needs a selected (tapped) comp segment, and the source takes time-aligned (same item positions).
- Tap in a gap over one long unsplit item fills the whole gap; when discrete items exist, their bounds win.
- The first swipe on a track with no comp lane creates one.
- A later swipe replaces an earlier one where they overlap.
- A new comp lane becomes the comp target automatically.
- Changing the comp target makes the new target the sticky top lane; the previous target moves to the source bank, and comps that aren't the target can be swiped from like any source.

## Open issues

- Segment visualisation and tap-to-switch need refinement.
- Keeping the app's segment state in sync with the actual REAPER items.
- Layout polish for the comp controls.
- Tap detection on an item for quick promote.
- A context menu on a comp segment: delete, change source (bounds are covered by segment resizing).
