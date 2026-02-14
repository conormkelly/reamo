# Lyrics/chord display and practice mode features for REAmo

Singer-songwriters, cover bands, and worship teams consistently prioritize **instant transposition**, **reliable multi-device sync**, and **stage-ready visibility** when choosing chord/lyric display software. The worship band market alone represents over **$200 million** in presentation software spending, with 74% of US churches using digital display systems. REAmo's REAPER-native architecture offers a significant competitive advantage—using tracks, markers, and regions instead of external databases—if it implements the core UX patterns users love while avoiding the subscription fatigue and reliability issues plaguing competitors like OnSong.

## OnSong dominates but frustrates with subscriptions and crashes

OnSong remains the worship band standard with over 10 years of market presence, yet user sentiment has soured since its 2024 shift from one-time purchase ($29.99) to mandatory subscription ($59.99/year Premium). The app's killer feature—**instant transpose with a slider**—still "blows people away," but Trustpilot reviews average just **2.6/5 stars**, with complaints clustered around crashes during live performance: "OnSong crashed twice on stage and left egg on my face. There won't be a third time."

**BandHelper** differentiates through collaboration-first design with automatic cloud sync across all band members, web interface editing, and cross-platform support (iOS, Android, Mac, web). Users praise developer responsiveness but criticize the steep learning curve and frustrating autoscroll: "I hate the scrolling features. I spend tons of time to get lyrics to scroll correctly." **ForScore** succeeds with musicians by offering a one-time $24.99 purchase with optional $14.99/year Pro subscription—explicitly promising never to paywall existing features.

The karaoke space reveals two dominant approaches: **word-by-word highlighting** (progressive color wipe as each word is sung) and **line-by-line highlighting** (current line highlighted, next line visible below). Professional systems like KaraFun use wipe-color progression (inactive → progress → highlighted) with progress bars during instrumental sections. Smule's pitch guide overlay and tap-to-jump-to-lyric features are highly requested for practice scenarios.

| App | Model | Price | Key Strength | Primary Pain Point |
|-----|-------|-------|--------------|-------------------|
| OnSong | Subscription | $59.99/year | Instant transpose, pedal support | Crashes, subscription backlash |
| BandHelper | Subscription | $32/year (Pro) | Multi-device sync, developer support | Steep learning curve |
| ForScore | One-time + optional sub | $24.99 | Reliability, PDF annotations | No chord chart editing |
| SongBook | One-time | ~$15 | No subscription, cross-platform | Limited advanced features |
| LivePrompter | Free | $0 | Full-featured teleprompter | Less polished UI |

**UX recommendations**: Implement transpose slider as primary interaction (not buried in menus). Support ChordPro inline chord rendering with chords positioned above specific syllables. Offer both line-level and word-level highlighting modes. Display both current and next line/section consistently.

**Priority**: High for transpose/capo calculation (essential), Medium for karaoke-style word highlighting (nice-to-have for practice mode).

## ChordPro is the universal format with a simple core

The ChordPro format, now at version 6 and maintained by Johan Vromans under the **Artistic License 2.0** (fully open source), has become the de facto standard. The essential subset that virtually all apps support is remarkably simple: chords in `[brackets]` inline with lyrics, directives in `{curly braces}` for metadata and sections.

**Core metadata tags** every app should support: `{title}` / `{t:}`, `{artist}` / `{a:}`, `{key}`, `{capo}`, `{tempo}`, and section markers `{start_of_chorus}` / `{soc}`, `{start_of_verse}` / `{sov}`. The format elegantly handles key changes—because chords are inline with lyrics, transposition preserves alignment automatically.

```
{title: Amazing Grace}
{artist: Traditional}
{key: G}
{tempo: 72}

{start_of_verse}
A[G]mazing [G7]grace, how [C]sweet the [G]sound
That [G]saved a [Em]wretch like [D]me
{end_of_verse}
```

**Critical parsing consideration**: Apps should use "relaxed" chord recognition mode, accepting anything that looks like a chord rather than only pre-defined chord names. Unknown directives prefixed with `x_` should be silently preserved (not warnings), enabling app-specific extensions like OnSong's `{midi-index}` or SongbookPro's `{textcolor}`.

**JavaScript libraries** for implementation include ChordSheetJS (395+ GitHub stars), which parses ChordPro, Ultimate Guitar format, and chords-over-words format—converting between all three. The library outputs HTML directly or can be used for custom rendering.

**UX recommendations**: Support import from ChordPro, Ultimate Guitar format, and plain text with chords above lyrics. Store unknown metadata/directives and preserve them on export. Display key and capo prominently—guitarists specifically request automatic capo chord calculations.

**Priority**: High for ChordPro parsing (essential for any chord display), Medium for Ultimate Guitar import (large user-created database).

## Worship bands need Planning Center integration and CCLI compliance

The worship band market is substantial: the church presentation software segment alone is valued at **$218-283 million (2024-2026)** with projected growth to **$636 million by 2035** at 9.1% CAGR. Over **5.1 million churches globally** use digital displays, with **74% of US churches** (approximately 280,000) using digital presentation systems.

**Planning Center Online** has become the de facto standard for worship planning—its Services module manages setlists, song libraries, and team scheduling. The API (available at developer.planning.center) uses JSON API 1.0 specification with OAuth for third-party apps. Key integration points: import songs from Services, sync setlists, push chord charts and keys to musician devices.

**CCLI SongSelect** provides legal access to **230,000+ worship songs** with ChordPro-formatted chord charts (Premium tier), transposable in any key. Integration requires OAuth login with CCLI Profile credentials; apps must display copyright notices *with* the song during performance (not just at the end). Activity requirement: integrations disable after 60 days of inactivity.

Worship leaders specifically need:

- **Multiple keys per song** for different vocalists (rotating worship leaders are common)
- **Real-time "spontaneous worship" access** to entire library, not just planned setlist
- **Song usage tracking** for CCLI reporting requirements
- **Copyright notice generation** automatically formatted per CCLI requirements

**Gap in current solutions**: "The only limitation is that musicians can't transpose keys on the fly unless an admin goes into the back end" (Planning Center Music Stand complaint). OnSong is iOS-only despite years of promising Android. Cover bands need last-minute request handling: "I've watched the lead singer make setlist changes between sets and send to the band" (BandHelper user).

**UX recommendations**: For worship market penetration, Planning Center Services API integration is near-mandatory. Store CCLI numbers and auto-generate copyright notices. Support per-vocalist key presets stored with each song.

**Priority**: High for Planning Center integration (market expectation), Medium for CCLI SongSelect (legal song access), Low for ProPresenter integration (presentation software uses separate workflow).

## Practice mode should follow Anytune's Step-It-Up pattern

**Anytune** consistently earns top recommendations across musician forums for practice features. Its "Step-It-Up Trainer" implementation represents the gold standard: configure starting tempo, ending tempo, number of steps, repeats per step, and end action—the app automatically increases tempo after each loop iteration. Users describe it as a "game changer" that "moves everything out of your way."

**Tempo adjustment UX patterns** that work best combine multiple input methods:

- **Large slider** for quick rough adjustment
- **Preset buttons** (25%, 50%, 75%, 100%, 125%) for common speeds
- **+/- fine adjustment buttons** (+1 BPM or +1%) for precision
- **Tap tempo** for discovering unknown BPM
- **Display both** BPM value AND percentage relative to original

**Loop controls**: A-B loop points should be settable during playback via tap (not pause-and-scrub). Anytune's waveform shows loop portion in different color (orange). Critical UX detail: "Use the waveform to help position sliders in a valley for smoother loop"—visual guidance for loop point selection. **Loop delay/lead-in** (1-bar countdown before restart) is essential for musicians preparing to play.

**Gradual tempo increase** implementations follow this pattern:

```
Start: 60 BPM → End: 120 BPM
Steps: 6 (60→70→80→90→100→110→120)
Repeats per step: 4 loops
End action: Hold at final tempo / Loop back / Stop
```

**Pitch shifting** independent of tempo is standard; range should be ±12 semitones minimum (1 octave each direction), with cents adjustment (1/100th semitone) for fine-tuning to match oddly-tuned recordings.

**UX recommendations**: Implement Step-It-Up style configurable speed trainer with visible progress indicator. Show waveform for loop point selection with visual valleys. Include loop lead-in countdown. Save all settings (tempo, pitch, loops, EQ) per song/region.

**Priority**: High for A-B looping with visual waveform (core practice feature), High for gradual tempo increase (musicians consistently request), Medium for pitch-independent tempo (useful but secondary).

## Sync precision of 50ms is adequate for most display scenarios

**LRC format** (standard since 1998) provides the simplest timing approach: `[mm:ss.xx]` timestamps at centisecond (10ms) precision for line-level timing. **Enhanced LRC** adds word-level timing using angle brackets: `<00:00.16> the <00:00.82> truth`. For REAmo's REAPER-native approach, timing can derive directly from markers and regions.

**Human perception thresholds** for audio-visual synchronization:

- Detectable delay: **~20ms** in controlled conditions
- Acceptable tolerance: **-60ms to +40ms** (EBU R37 standard)
- Noticeable desync: **>50-100ms**
- Unusable: **>250ms**

For lyric display specifically, **line-level timing with ~50ms precision** is adequate for singalong/teleprompter use. Word-level karaoke highlighting benefits from 10-30ms precision at word boundaries.

**Latency compensation** is critical: Bluetooth headphones add 40-300ms delay, USB audio devices up to 200ms. Implementation must use **audio clock** (not wall clock) for timing, with user-adjustable global offset. The LRC `[offset:+/-ms]` tag provides this.

**Scrolling best practices**:

- Keep current line at consistent vertical position (typically 1/3 from top)
- Show 2-4 upcoming lines visible
- Use ease-in/ease-out for smooth visual experience
- Pause/slow during instrumental breaks (section-aware scrolling, not just duration-based)

**UX recommendations**: Derive timing from REAPER markers/regions—this is REAmo's competitive advantage over external LRC files. Implement global latency offset adjustment. Use anticipatory scrolling (begin scroll slightly before timestamp).

**Priority**: High for marker-based section display (REAPER-native approach), Medium for word-level highlighting (optional enhancement), Low for LRC import/export (external format compatibility).

## Stage displays need 4.5:1 contrast and 36-48pt fonts minimum

**Visibility requirements** for stage use are demanding: font sizes of **36-48 points** minimum, line spacing of 1.5-2.0, and contrast ratios of **4.5:1 minimum** (WCAG AA standard) or 7:1 (AAA) for optimal readability under varied lighting. Professional stage prompters like Stageprompter use 22" or 32" screens specifically because iPad "tiny screens" struggle under stage lights.

**Dark mode** is essential—white/light text on black/dark background works best under stage lighting. Red-on-black (night vision mode) exists in specialized astronomy applications but is uncommon in music apps.

**Multi-device sync** approaches vary:

- **OnSong Connect**: Leader device acts as web server on local WiFi; tested with 24 devices simultaneously
- **BandHelper**: Cloud-based account sync across iOS, Android, Mac, web
- **SongBook "Play Together"**: Bluetooth/WiFi peer-to-peer where any device can control others

**Orientation preferences** vary by instrument and context—support both landscape (two-column layouts) and portrait (traditional reading). Auto-switch to multi-column when content fits on screen.

**UX recommendations**: Default to high-contrast dark mode. Implement minimum 36pt font with easy adjustment. Support local network leader/follower sync (more reliable than cloud for live performance). Show "next song" preview in setlist view.

**Priority**: High for dark mode and large fonts (stage essential), High for local network sync (reliability critical for live use), Medium for multi-column auto-layout (convenience feature).

## Pricing should follow forScore's hybrid model

The competitive landscape reveals strong **subscription fatigue** in the musician market. Ultimate Guitar's aggressive upselling earned it **1.2-1.9 star ratings** across review sites with BBB complaints about unauthorized charges. OnSong's subscription transition generated significant backlash from users who "bought the app 10+ years ago."

**ForScore's model** earns the most positive sentiment: full app for **$24.99 one-time purchase** with optional **$14.99/year Pro subscription** for power features. The developer explicitly states: "Subscriptions make people uneasy, and we understand that... we won't paywall existing features."

| Feature Category | Typically Free/One-Time | Typically Premium/Subscription |
|-----------------|------------------------|-------------------------------|
| Basic viewing | ✓ | |
| Manual page turning | ✓ | |
| Limited song library | ✓ | |
| Multi-device sync | | ✓ |
| Cloud storage | | ✓ |
| MIDI automation | | ✓ |
| Advanced annotations | | ✓ |
| Backing tracks | | ✓ |

**UX recommendations**: Consider one-time purchase for core functionality (lyrics/chords, basic practice mode) with optional subscription for cloud sync, multi-device features, and MIDI automation. Never lock user's own data behind subscription—this generates the most negative sentiment.

**Priority**: High for pricing model decision (affects market positioning), Medium for feature tier planning.

## Avoid these critical anti-patterns from competitor failures

Research across Trustpilot, App Store reviews, and musician forums reveals consistent failure patterns:

**Stage reliability failures**: OnSong crashes during live performance are the most damaging complaint. "OnSong crashed twice on stage and left egg on my face. There won't be a third time." Any chord display app must be **bulletproof during playback**.

**Autoscroll without intelligence**: Duration-based scrolling fails because it doesn't account for intros, outros, or instrumental breaks. Users report spending "tons of time to get lyrics to scroll correctly" in BandHelper. Section-aware scrolling that pauses for instrumentals is essential.

**Word processor import failures**: "You cannot just type a song sheet on a word processor and import it into OnSong and use it; you have to correct every song sheet you import." Users expect copy-paste from any source to "just work."

**Proprietary data lock-in**: "If I delete the app I would lose 832 songs I had meticulously edited" (GuitarTapp user). Users resent when their own data becomes inaccessible. Always support ChordPro export.

**Feature creep**: "Has way too much unneeded functionality... For those of us wanting a simple page turner, there has to be simpler alternatives." Core features must remain accessible despite advanced options.

**Hidden customer support**: "There is absolutely NO PHONE SUPPORT at all... there is no excuse for not having a person you can speak to" and "THERE IS NOWHERE ON THEIR WEBSITE TO ACTUALLY CONTACT SUPPORT!"

**Key anti-patterns to avoid in REAmo**:

- Crashes or freezes during playback (career-ending for live use)
- Autoscroll without section/marker awareness
- Requiring ChordPro formatting for copy-pasted text
- Subscription that locks access to user's own songs
- Aggressive upgrade prompts that interrupt workflow
- Changes/updates that remove features users depend on

## Conclusion and implementation priorities

REAmo's REAPER-native architecture—using tracks, items, markers, and regions—offers genuine competitive advantages over database-dependent competitors. Lyrics and chords stored in item notes with timing derived from markers enables section-aware scrolling, visual waveform navigation, and seamless integration with REAPER's existing looping and tempo features.

**High priority features** for initial implementation:

1. ChordPro parsing and display with transpose slider
2. Dark mode with 36-48pt fonts for stage visibility  
3. A-B looping with visual waveform and loop lead-in
4. Gradual tempo increase (Step-It-Up trainer pattern)
5. Local network multi-device sync (leader/follower model)
6. Section-aware scrolling using REAPER markers

**Medium priority features** for subsequent releases:

1. Planning Center Services API integration
2. Word-level karaoke highlighting
3. CCLI SongSelect import with copyright notice generation
4. Ultimate Guitar format import
5. User-adjustable latency offset

**Strategic positioning**: Target the underserved cross-platform market (OnSong is iOS-only) with a one-time purchase model. Emphasize REAPER integration as the differentiator—no other solution offers native DAW timeline sync with chord/lyric display. The worship band market offers the largest addressable segment, but serving cover bands and singer-songwriters broadens the appeal and reduces dependence on church-specific integrations.
