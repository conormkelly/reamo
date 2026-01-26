# Logic Remote chord strips: A complete technical breakdown

Logic Remote's chord strips provide a powerful touch-based interface for playing chords and bass notes on iPad and iPhone, enabling musicians to control Logic Pro software instruments without traditional keyboard skills. The feature supports four touch instruments—Keyboard, Guitar, Bass, and Strings—each with distinct interaction patterns optimized for their sound characteristics.

## Layout displays 8-12 strips with 8 vertical segments each

Logic Remote displays **8 chord strips** on standard iPads and **12 chord strips** on iPad Pro (increased from 8 in version 1.3). Each strip is arranged **vertically** with the chord name displayed prominently (e.g., "Am", "F", "G7"). The strips are positioned horizontally across the screen, creating a row of touchable columns.

Each chord strip contains **8 segments divided into two functional zones**:
- **5 upper segments**: Play chords at different voicings/inversions (highest voicing at top, lowest at bottom)
- **3 lower segments**: Play bass notes—root note (top), fifth (middle), and root octave (bottom)

The chord strips display only **diatonic chords** based on the project's key signature. When working in F minor, for example, strips show Fm, G°, A♭, B♭m, Cm, D♭, and E♭. Different touch instruments have variations: Guitar strips show simulated strings for strumming, while Strings strips display instrument voice controls (violin 1, violin 2, viola, cello, double bass) that can be individually muted.

## Inversions are controlled entirely by tap position

Logic Remote uses a **position-based inversion system** rather than dedicated buttons or menus. The 5 upper segments of each chord strip correspond to different chord voicings from high to low register:

- **Top segment**: Highest voicing/inversion
- **Middle segments**: Intermediate inversions
- **Bottom segment**: Lowest voicing (typically root position in lowest register)

For Smart Strings specifically, Apple's documentation states: "Wherever in the chord strip you start the glide, that's the inversion or voicing of the chord that you'll hear, from high to low in the four regions."

**Slash chords and alternate bass notes** are handled through the custom chord editor. Users can specify an independent bass note using the **Bass wheel**, creating voicings like C/G or Am/E. The three lower segments then play this custom bass configuration. There is no real-time inversion switching via gestures—voicing changes require editing the chord strip configuration.

## Touch behavior follows note-on/note-off with instrument-specific gestures

**Core touch behavior** follows standard MIDI conventions:
- **Touch-down**: Triggers note-on immediately (chord sounds)
- **Touch-up**: Triggers note-off (chord releases)
- **Exception**: Smart Strings pizzicato mode plays on finger lift, not touch-down

**Keyboard chord strips** respond to simple taps—tap upper segments for chords, lower segments for bass, or both simultaneously for combined chord-and-bass voicings using multi-touch.

**Guitar/Bass chord strips** support more expressive gestures:
- Tap individual strings for single notes
- Swipe across strings to strum (direction affects strum direction)
- Tap the top of a strip for instant full-chord strum
- Touch and hold the fretboard area left of strips to mute strings

**Smart Strings chord strips** offer the most sophisticated control:
- Glide finger across strips for swelling, pressure-reactive dynamics
- Touch-hold with vertical swipes for sustained bowing
- Quick swipes trigger marcato bowing
- Simple taps play pizzicato (note triggers on release)

**Multi-touch is fully supported**—users can hold chord and bass segments simultaneously, play multiple strips at once, and combine gestures with string muting.

## Velocity sensitivity exists but has notable limitations

Logic Remote provides a **global Velocity Range slider** accessible via the Settings button. Users can:
- Drag the slider to shift the overall velocity range up or down
- Pinch with two fingers to expand or contract the velocity range

However, user reports consistently indicate that **chord strips have a compressed velocity range** compared to the standard keyboard. Forum discussions document keyboard velocity spanning roughly **10-120**, while chord strips operate within approximately **95-110**—a significantly narrower dynamic range. Apple has released multiple updates improving "velocity sensitivity response when playing Touch Instruments," though the limitation persists.

For Smart Strings, velocity/dynamics respond to **gesture speed and pressure** rather than tap intensity—swiping faster produces louder playback, slower swipes play softer. This bypass of the standard velocity system provides more expressive control for orchestral compositions.

## Scale and key selection follows the Logic Pro project

Chord strips **automatically synchronize with the project's key signature** set in Logic Pro's Signature Track. When you change the project key from C major to D minor, the chord strips update to display the seven diatonic chords in D minor. This integration was specifically fixed in early updates where "scale modes and chord strips" weren't properly updating to the current project key.

For scale-based playing beyond chord strips, Logic Remote offers a **Scale button** that switches the keyboard to show note bars locked to a specific scale. Available scales include standard options like Major, Minor, and various modes, though the complete list isn't exhaustively documented. Version 1.1 "adds more scale choices for Touch Instruments."

**Custom scales cannot be defined** within Logic Remote—users are limited to Apple's preset scales. However, the **Edit Chords feature** allows substantial customization:
1. Access via Settings → Edit Chords
2. Select the chord strip to modify
3. Use **Chord wheels** to set root note, chord quality (major, minor, 7th, dim, aug), and extensions (9th, 11th, 13th)
4. Use **Bass wheel** to specify alternate bass notes
5. Custom chords become available across all Touch Instruments in the project

## Arpeggiator integration transforms chord playback

The Keyboard Touch Instrument includes a built-in **arpeggiator** activated via the Arpeggiator button. When enabled, tapped chords play as arpeggiated sequences rather than simultaneous notes. The **Sustain control transforms into a Latch control**—touching or locking Latch keeps the current arpeggio playing continuously, while tapping a different chord strip transposes the running arpeggio.

Arpeggiator parameters—note order, octave range, pattern type—are adjusted in Logic Pro's Smart Controls area or directly in the Arpeggiator plug-in, not within Logic Remote itself. Sustain is automatically disabled when the arpeggiator is active.

**Notable omission**: Unlike GarageBand for iOS, Logic Remote **does not include an Autoplay feature**. GarageBand's Autoplay knob triggers rhythmic chord patterns automatically when a chord strip is tapped; Logic Remote requires manual playing or arpeggiator use for similar effects.

## Strumming simulation works through swipe gestures

Guitar and Bass chord strips simulate strumming through swipe gestures across the virtual strings. Swipe speed affects the strum timing—faster swipes produce quicker, more aggressive strums while slower swipes create gentler, rolled chord effects. The direction of the swipe influences the strum direction.

Smart Strings provide articulation control through gesture variation:
- Sustained finger glides with up/down movement for bowing
- Quick swipes for staccato/marcato effects
- Taps for pizzicato (plays on release)

All chord strip interactions are recorded as standard MIDI data in Logic Pro, allowing post-recording editing of voicings, velocities, and timing in the Piano Roll.

## Conclusion

Logic Remote's chord strips offer a sophisticated touch interface with **position-based inversion control** across 8 segments, **project-key synchronization**, and **instrument-specific gesture vocabularies**. The system excels at enabling non-keyboardists to input chord progressions quickly, particularly with Smart Strings' expressive dynamics. Key limitations include the compressed velocity range on chord strips (versus full keyboard), absence of GarageBand's Autoplay feature, and the inability to define custom scales. For maximum flexibility, users should leverage the Edit Chords feature to configure specific voicings and slash chords, and use Logic Pro's Arpeggiator plug-in for automated pattern generation.
