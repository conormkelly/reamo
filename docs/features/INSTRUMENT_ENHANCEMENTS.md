# Instruments: design notes

Decisions and findings for planned instrument work that aren't recorded
anywhere else. The planned features themselves (pad editing, trigger modes,
note repeat, scale lock, glissando, chord banks, velocity) are tracked as
planned work, not here.

## Decisions

- **MIDI channel:** one channel per instrument. MPE is deferred.
- **One-shot drum length:** 200ms by default (tempo-synced lengths are an option on top).

## Open question

- What chord strips are for: a quick songwriting tool, a live performance instrument, or a learning aid. It decides how far custom banks and variations go.

## Competitor findings (unverified survey of iOS/Android apps and forums)

- Chord apps that also do custom chords: Suggester, ChordPad, ChordPolyPad, Navichord, Scaler 2.
- Navichord: 256 chords (16×16) laid out on a Tonnetz, auto names, theme colours. Scaler 2 colours chords by harmonic distance.
- Transpose: Scaler 2 uses semitone +/- with an optional padlock that forces notes into the new scale.
- Inversions are a dropdown or +/- per chord. Chord Prism uses the black keys as real-time chord modifiers.
- Piano keys on touch apps are typically 8-15mm wide.
- Reported pain points besides latency: MIDI mapping that doesn't persist, iOS system gestures (3-finger) interrupting play, fiddly small controls, poor discoverability.
