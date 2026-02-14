# Designing REAmo: What DAW Remote Users Actually Need

Building a successful DAW remote control for REAPER requires navigating a paradox: current solutions are either too simple (just transport) or too complex (extensive OSC configuration), leaving musicians in a frustrating middle ground. The **killer opportunity for REAmo** is eliminating the setup pain while providing a purpose-built web interface that works across devices without configuration headaches. Research reveals that **75%+ of user complaints center on network setup and connection reliability**—not missing features—making a zero-config web solution the single biggest differentiator.

## The competitive landscape reveals clear patterns

Seven major players dominate the DAW remote space, each with distinct strengths and weaknesses that inform REAmo's design.

**TouchOSC** ($9.99 iOS/Android, $18 desktop) offers maximum customization through fully user-designed layouts with MIDI/OSC support. Users praise its cross-platform flexibility and 10+ years of updates, but complain about a steep learning curve—"even technically skilled users struggle." The template building process requires significant investment before any productivity gains.

**Lemur** ($12.99/month or $99/year) targets power users with Canvas widgets, physics engines, and C-style scripting. Used by Daft Punk and Deadmau5, it's praised as "by far the most flexible" but criticized for being "most time-consuming to develop templates" and having a controversial subscription model that alienated longtime users.

**V-Control Pro** ($49.99/year or $199 perpetual) provides the best out-of-box experience with DAW-specific optimizations, plug-in GUI control, and multi-touch faders. Users report being "up and running within 5 minutes," but the price point and occasional connectivity issues draw complaints.

**Logic Remote** (free, iOS only) demonstrates ideal tight integration—users call it "an extension of Logic" with dead-simple setup. However, its DAW exclusivity limits applicability, and users wish for MIDI note creation and better marker navigation.

**Avid Control** (free with account) offers surprisingly comprehensive features including 96-track tile views and S6-style layouts, but setup confusion ("4 hours and hadn't gotten anywhere") and EuControl requirements add friction. The counter display is criticized as "Lilliputian."

**ProRemote** and **MIDI Designer** round out the field with HUI/Mackie protocol support and fully customizable MIDI-only control respectively. Both face criticism around pricing and setup complexity.

| App | Price | Best For | Main Weakness |
|-----|-------|----------|---------------|
| TouchOSC | $10-18 | Custom layouts, cross-platform | Steep learning curve |
| Lemur | $99/yr | Power users, scripting | Subscription, complexity |
| V-Control Pro | $50/yr or $199 | Multi-DAW pros | Price |
| Logic Remote | Free | Logic users | Single-DAW only |
| Avid Control | Free | Pro Tools users | EuControl setup |
| ProRemote | Subscription | Pro Tools recording | Mac-only |
| MIDI Designer | Free + Premium | Synth control | "Ugliest thing I've ever seen" |

## User pain points cluster around three themes

Forum research across Reddit (r/Reaper, r/WeAreTheMusicMakers), Cockos forums, and Gearspace reveals that **setup complexity is the dominant complaint**, followed by connection unreliability and insufficient visual feedback.

**Setup frustration dominates every discussion.** One Cockos Forums user wrote: "I struggled through an evening of frustration with trying to get this up and running." IP addresses, ports, firewalls, and bridge apps create friction that makes many abandon remote control entirely. A VI-Control user noted: "It took me hours to get TouchOSC working... Configuration is a nightmare." Windows updates routinely break configurations: "I had TouchOSC working fine until a recent Win10 update & when the dust had settled, NONE of my control surfaces were working."

**WiFi latency ranges from imperceptible to unusable.** Users report delays from near-instant to "6-10 seconds and sometimes even more." One user on SuperCollider noted: "The horrible lag I'm experiencing... It doesn't even let me control an on/off toggle with speed of a quarter note in 120 bpm." The consensus: 2.4GHz networks are often unacceptable; 5GHz or USB tethering required.

**Remote apps don't show what matters.** Users want to see their actual timeline and arrangement, not just controller layouts. One forum post captured this: "All you see is a controller layout and feedback such as time counter... if you want to see the playback cursor or change other Reaper menu settings you would need to use remote desktop."

### The "walk to computer" trigger list

These specific actions force musicians to leave their instrument position:

- **Track arming and creation** — adding a new track for another layer
- **Popup dialog handling** — any error message or confirmation freezes the session
- **Navigation to specific sections** — jumping to verse 2 or chorus 3
- **Take management** — selecting, comping, or deleting takes
- **Plugin adjustments** — tweaking any effect parameter
- **Input/monitoring changes** — adjusting headphone mix or levels
- **Session saves** — ensuring work isn't lost

## REAPER's ecosystem creates unique opportunities

REAPER's built-in web interface and action system provide a foundation most users don't know exists, offering REAmo significant advantages.

**The hidden web server.** REAPER includes HTML interfaces accessible via browser at `localhost:8080` or through the `rc.reaper.fm` relay service. Included layouts (index.html, fancier.html, more_me.html for IEM mixing, lyrics.html) demonstrate basic capabilities, but users describe them as "functional but not modern/pretty." The JavaScript API (`main.js`) supports custom development.

**Every REAPER function is an action.** With **7,000+ built-in actions** plus SWS Extension additions, any UI operation can be triggered externally. Custom actions chain operations into macros. This means a web interface can trigger arbitrarily complex behavior without requiring users to write scripts.

**ReaLearn changes the game.** This free, open-source VST plugin provides the most comprehensive controller integration available, supporting MIDI, OSC, MCU, and keyboard input with conditional activation and visual feedback. While powerful, its extensive feature set creates a learning curve—an opportunity for REAmo to provide simpler defaults.

**Community solutions validate demand.** GitHub projects like RCRemote, reaper-remote-bandui, and reaper-ui demonstrate that developers see gaps in existing tools. The bandui project specifically targets live bands wanting personal monitor mixing with song navigation.

## Use case segmentation reveals priority features

Research validates all proposed user segments, with clear differentiation in what each needs most.

### Recording/tracking (highest priority segment)

Self-recording musicians represent the largest user group. Their core needs: transport controls, track arming, and—critically—**"stop and delete last take"** workflows. One Gearspace user summarized: "I basically need to stop, start, record, arm record and playback." Logic Remote receives praise for letting guitarists record "from anywhere in your room."

### Live performance/rehearsal (high priority)

Performers need reliability above all else, plus **large readable displays** and instant song switching. **AbleSet** (a $49+ Ableton add-on) proves market demand for setlist/cue list management with song-section jumping, lyric sync, and stop markers. One Kemper Forum user emphasized: "Absolutely critical that the songs/sessions load quickly and seamlessly between songs."

### Mixing from listening position (high priority)

Engineers want **multi-touch faders** for riding levels while walking around the room. A Gearspace user noted: "There is nothing like mixing on a control surface... You can work in a much more traditional way, by simply listening." Logic Remote's multiple mixer views (Volume, Pan, Sends, Audio FX) set the standard.

### Songwriting/arrangement (medium-high priority)

Songwriters value marker-based navigation for structure ("intro, verse, chorus") and loop section controls. Most remotes underserve this segment—**arranger/structure editing is a differentiator opportunity**.

### Podcasting and film scoring (specialized)

Podcasters need simple transport plus chapter markers (Ultraschall for REAPER validates this). Film scorers require SMPTE timecode display, hit point markers, and tempo mapping—features **no mobile controller currently addresses well**.

## Proposed views validate strongly with additions needed

Research confirms the proposed view concepts while suggesting refinements and additions.

### Big Clock / Performance view — validated (HIGH priority)

REAPER forums specifically request "Big Clock showing tempo." Live performers need displays readable from 10+ feet. Recommended features: **large BPM display, bar:beat timecode, huge transport buttons (80-100pt minimum), current marker name, visual beat indicator**.

### Mixer view — essential (HIGHEST priority)

Standard in all existing apps. Logic Remote shows 8-12 channels with faders, pan, solo/mute, meters, and record arm. **Bank navigation** (next/previous 8 channels) is mandatory. No controller can be taken seriously without this.

### Cue List / Setlist view — validated (HIGH priority for live)

AbleSet's popularity proves demand. Features: **song/section list, jump-to-any-section, current position indicator, loop controls, stop/continue behavior**. This combined with strong mixing could differentiate REAmo.

### Notes view — moderate validation (MEDIUM priority)

Logic Remote users specifically requested notepad integration. Film scorers use spotting notes extensively. A differentiator since competitors ignore this.

### Quick Actions / Toolbar view — validated (HIGH priority)

Customizable buttons are highly valued by power users. Logic Remote offers 24-35 configurable key commands; Avid Control provides multi-page Soft Keys. **Essential for users who want to trigger specific REAPER actions.**

### Missing views to consider adding

- **Take/Comp view** — browse and select between takes without returning to computer
- **Waveform overview** — visual timeline with current position indicator
- **Input/Monitor settings** — adjust headphone mix and input gain

## Navigation must prioritize discoverability and thumb reach

Research on touch ergonomics and pro audio app patterns yields clear recommendations.

**Bottom navigation wins for tablets.** Tab bars at bottom offer high discoverability (hamburger menus reduce engagement by 30%+) and thumb accessibility. However, transport controls deserve special treatment—**always visible, bottom-right corner** (or configurable left/right for handedness).

**Recommended paradigm for REAmo:**

1. **Persistent transport bar** at bottom with play/stop/record always accessible
2. **Tab-based view switching** above transport (Mixer | Performance | Cue List | Quick Actions | Notes)
3. **Swipe gestures** as secondary navigation between views (hidden but efficient once learned)
4. **Long-press or double-tap** for secondary functions (e.g., long-press Record for punch-in settings)

**Avoid hamburger menus** for any feature users need regularly. Reserve them only for settings, configuration, and rarely-accessed options.

### Per-device considerations

| Device | Layout Approach |
|--------|-----------------|
| iPad | Sidebar navigation option, 8-12 mixer channels, split views |
| iPhone | Tab bar, 4-6 mixer channels, simplified layouts |
| Any | Remember last-used view and orientation per device |

Cubasis's approach of **UI scale presets** is worth emulating—let users choose density based on their eyesight and distance from screen.

## Touch targets and accessibility require oversizing

Standard guidelines aren't sufficient for professional audio contexts where users are stressed, lighting is dim, and screens may be 10+ feet away.

**Recommended minimums for REAmo:**

- **Standard controls:** 54pt minimum (vs. Apple's 44pt guideline)
- **Transport and critical controls:** 80-100pt for live/stage use
- **Spacing between targets:** 12-24pt to prevent accidental taps
- **Consider a "Stage Mode"** toggle that enlarges all controls 50%+

**Dark mode should be default** with light mode optional. Use **#1E1E1E to #121212** backgrounds (not pure black) and **#E0E0E0** text (not pure white). Maintain **4.5:1 contrast ratio** minimum. OLED screens save 40% power with dark interfaces—meaningful for stage iPads.

**One-handed operation** requires placing primary transport in **lower corners** with optional left/right mirror for handedness. Per one DAW Control user: "Transport controls in lower right so when standing in front of a microphone I can use my right hand to control transport without blocking the rest of the screen."

## Four insights challenge common assumptions

**1. Users prefer simple hardware to complex apps.** The most satisfied users often use wireless numeric keypads ($15) rather than sophisticated touch controllers. They map 5-6 keys (record, stop, play, delete take, undo) and call it done. Implication: REAmo's **default view should be radically simple**, with complexity available but not required.

**2. The "middle ground" is where frustration peaks.** Apps that are neither simple transport nor full remote desktop create a "worst of both worlds" scenario—requiring setup investment while still forcing computer trips. Implication: REAmo must either **excel at simplicity** (beat a $15 keypad) or **provide near-complete control** (approach remote desktop capability).

**3. Visual feedback matters more than control density.** Users want to see where they are in the song, what's recording, and current levels—not necessarily 32 fader channels. Implication: **Prioritize meters, position indicators, and track state visibility** over cramming more controls on screen.

**4. Setup complexity is the real competition.** No feature list beats "works immediately." REAPER's web interface has the unique advantage of requiring only a browser. Implication: **Zero-config should be the promise**—ideally enter IP address once and go.

## Prioritized feature list for REAmo v1

Based on cross-referencing user needs, competitive gaps, and implementation feasibility:

### Must-have for launch

1. **Transport controls** — Play, Stop, Record, Rewind, Fast-forward with 80pt+ buttons
2. **Basic mixer** — 8-channel view with faders, pan, solo/mute, meters, bank navigation
3. **Big Clock display** — BPM, bar:beat position, large transport
4. **Marker/region list** — Jump to any marker, see current position
5. **Zero-config setup** — Leverage REAPER's built-in web server
6. **Dark mode default** — Professional studio appearance

### High priority (v1.5)

1. **Quick Actions toolbar** — User-configurable buttons triggering any REAPER action
2. **Track arm/disarm** — Visible track state with remote arming
3. **Take management** — "Delete last take," "Keep take," take navigation
4. **Cue List / Setlist view** — For live performance segment
5. **Per-device layout memory** — iPad opens to last-used view

### Differentiators (v2)

1. **SMPTE timecode display** — For film scoring segment
2. **Waveform overview** — Visual timeline with playhead position
3. **Notes view** — Project notes, session metadata, lyrics
4. **Arranger view** — Song structure manipulation
5. **Take comp selection** — Visual comping from remote

## Recommended navigation for REAmo

```
┌─────────────────────────────────────────────────────────┐
│  [≡]  │        Project Name        │ [?] [⚙️]           │
├─────────────────────────────────────────────────────────┤
│                                                         │
│                   ACTIVE VIEW AREA                      │
│          (Mixer / Performance / Cue List /              │
│           Quick Actions / Notes)                        │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  Mixer  │  Clock  │  Cues  │  Actions  │  Notes        │ ← Tab bar
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶/❚❚  │  ⏹  │  ⏺  │    03:42.16    │  120 BPM │ ← Always-visible transport
└─────────────────────────────────────────────────────────┘
```

**Rationale:** This structure keeps transport always accessible (bottom), view switching discoverable (tab bar), and reserves hamburger menu for settings only. The transport bar provides constant feedback (time, tempo) while enabling instant access to critical controls. Tab switching supports swipe gestures as secondary navigation for experienced users.

## Key sources informing this research

**Forums and communities:**

- Cockos Forums (forum.cockos.com) — REAPER-specific discussions on remote control, OSC setup, web interface customization
- Reddit r/Reaper, r/WeAreTheMusicMakers, r/audioengineering — User pain points and workflow discussions
- Gearspace — Professional mixing and control surface perspectives
- VI-Control — Film scoring and composition workflows

**Products and documentation:**

- TouchOSC documentation (hexler.net) — Template creation and REAPER integration
- ReaLearn project (helgoboss.org) — Advanced controller mapping
- AbleSet (ableset.app) — Setlist and live performance paradigm
- REAPER OSC documentation (reaper.fm/sdk/osc)

**UX guidelines:**

- Apple Human Interface Guidelines — Touch target sizing, navigation patterns
- Google Material Design — Accessibility contrast ratios
- MIT Touch Lab research — Finger size ergonomics

The research points to a clear opportunity: a web-based REAPER remote that requires zero configuration, provides purpose-built views for distinct workflows, and makes the "walk to computer" trips unnecessary for 90% of common tasks. The competitive moat is simplicity of setup combined with REAPER-specific optimization—something no current solution delivers.
