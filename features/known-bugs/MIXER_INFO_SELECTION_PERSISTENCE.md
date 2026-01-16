# Mixer Info Bar Selection Persistence

## Issue

When a track is selected for info display in MixerView (indicated by blue bar at bottom of track strip), navigating to a different bank causes the TrackInfoBar to collapse if the selected track is no longer visible.

## Expected Behavior

The info bar selection should persist in memory. When navigating banks:
- If selected track is in current bank: show info bar for that track
- If selected track is NOT in current bank: keep info bar visible showing the selected track's info (or show "Track X (not in view)" indicator)

## Current Behavior

Info bar collapses when selected track is paged out of view.

## Affected Components

- `frontend/src/views/mixer/MixerView.tsx` - `infoSelectedTrackIdx` state
- `frontend/src/components/Mixer/TrackInfoBar.tsx`

## Notes

- "Selected" here refers to the UI selection for info display (blue bar), NOT REAPER's native track selection
- Selection is already persisted to localStorage (`reamo-mixer-info-selected`), so it survives page refresh
- The issue is that we don't subscribe to the selected track's data when it's outside the current bank

## Potential Fix

When `infoSelectedTrackIdx` is set and not in `displayTrackIndices`, include its GUID in the subscription so we have data to display in the info bar.
