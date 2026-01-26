# Mobile DAW toolbar UX: what users actually want

**Touch target sizes and customization complexity are the two battlegrounds where mobile DAW toolbars succeed or fail.** Forum research across REAPER, Reddit, KVR, and Gearspace reveals consistent user frustrations: buttons too small for reliable tapping, setup processes that require desktop software, and interfaces that feel like "desktop DAWs transplanted over" rather than touch-native designs. Users consistently praise apps that offer pre-configured templates with optional customization, generous touch targets, and color-coded organization that lets them find actions by visual scanning rather than reading labels.

The ideal REAmo toolbar should support **8-12 buttons visible at once** with minimum **44pt touch targets**, use horizontal swipe paging for overflow, and provide an in-app edit mode using long-press to initiate drag-and-drop reordering—no desktop editor required.

---

## Real users reveal consistent pain points

### Touch targets are universally too small

User complaints about button sizing dominate forum discussions. From the REAPER forums: *"the buttons are still extremely small for my taste"* and *"I found the double-wide text icons no longer sufficient to clearly label many actions...I wonder if it would be possible for you to have triple and quadruple wide text icons."* One Gearspace user noted they *"sometimes need the Apple Pencil to accurately press the record button"* in iOS DAW apps.

Sound On Sound's review of Avid Control identified a core issue: *"The Soft Keys in particular can be hard to target unless the iPad is right in front of you, and I shudder to think how they would look on an iPad mini."* Another reviewer noted the toolbar *"would benefit from having a few more vertical pixels"*—a polite way of saying buttons are too cramped.

### Setup complexity kills adoption

The single most frustrating aspect of customizable control apps is requiring desktop software for configuration. From the Loopy Pro Forum: *"For me Lemur is a no-go because I don't want to run to a PC every time I want to build a surface. Same for TouchOSC."* Users praised TouchOSC Mk2 specifically for making on-device editing possible: *"It looks like with the latest mk2 version of TouchOSC they've really worked on simplifying things."*

WiFi connectivity is the **#1 complaint** across all apps. Gearspace users describe needing to *"do a reboot, re-connect wifi song and dance before the app sees Logic."* A VI-Control user complained about Lemur: *"keeps losing connection...I've spent so much time programming my template...a whole year."*

### Desktop-transplant interfaces feel wrong

Users can immediately sense when an interface wasn't designed for touch. From KVR: *"Auria I find the GUI unpleasant to use. It is more like a regular DAW transplanted over instead of designed for the platform."* MusicRadar's Cubasis review noted piano roll editing *"isn't a particularly fluid experience and it left us crying out for a mouse and keyboard."*

The underlying issue is tactile feedback loss. From Gearspace: *"The one flaw with any touchscreen is that there's no tactile feedback. With a console, you can have fingers on each guitar and another on the lead vocal...Tablets leave you staring at a screen too much."*

---

## What delights users: speed, labels, and templates

### Logic Remote's key commands approach earns praise

Logic Remote's grid-based key commands view receives consistent positive feedback. Sound On Sound highlighted: *"Key Commands...You can replace any of the Key Commands, including the six fixed ones at the bottom, and organise them by colour, which is awesome."* Users appreciate that it works immediately without configuration: *"I ended up buying an iPad for Logic Remote when I realized I can get it for the same money I'd spend for a Faderport 8. I don't regret it at all."*

The **fixed bottom row** pattern—keeping 6 essential commands always visible while paging through others—emerged as a strongly positive design. One user noted Logic Remote is *"another tool in the tool kit, but a lot easier than mapping controller knobs and trying to remember which button does what."*

### Labels trump icons for complex actions

Users strongly prefer text labels over icon-only buttons for DAW actions. From a Blackmagic Design forum: *"I prefer text labels, as it takes me too long to learn hieroglyphs."* GitHub accessibility discussions noted: *"Research indicates that a combination of icons and texts yields the widest and greatest recognition speed possible, at the cost of space."*

From VI-Control discussing Lemur's strength: *"The labeling part is what really makes it useful for me. Right now I'm setting up a new template for Synchron Brass and I have **37 buttons and 9 sliders, all labeled**. There's no way I'd remember all of those details without Lemur."*

### Color coding enables visual scanning

Color organization consistently receives praise. REAPER forum users note: *"It's quicker and easier to see by colour and location than by text or icon."* Users want to **identify actions by visual pattern** rather than reading every label during time-sensitive recording sessions.

### Pre-built templates with customization options

The ideal approach: templates that work immediately but allow tweaking. Digital DJ Tips advises: *"If you're just starting out on Lemur, we recommend getting a mapping that works out of the box so you don't have to worry about learning the intricacies."* One Ableton Forum user complained TouchOSC is *"too light for my own use. There's too much messin' around for not enough awesome"*—highlighting the importance of substantial defaults.

---

## Design recommendations from community feedback

### Touch target sizing: respect the minimums, then add more

Official guidelines establish clear minimums: **Apple iOS requires 44×44pt** (~6.8mm), **Material Design recommends 48×48dp** (~9mm). MIT Touch Lab research shows the average fingertip is 8-10mm wide, meaning even these minimums allow for some error.

Steven Hoober's research adds crucial nuance: screen location matters. **Bottom targets need 46px padding** (users tap higher than intended), **top targets need 42px**, while center content can go as low as 27px. For a toolbar at screen edges, err toward larger targets.

Pro audio apps typically follow minimums but no larger. However, user complaints suggest this creates usability issues for production environments where users aren't staring at their tablets. **Recommendation: 48-54pt targets minimum**, with an option for a "dense mode" at 44pt for power users who accept the tradeoff.

### Information density versus accuracy: let users choose

Users are split between wanting more buttons visible versus wanting reliable tapping. The solution: offer layout modes.

- **Standard mode**: 44-48pt targets, 8-12 buttons visible, optimal for most users
- **Dense mode**: 36-40pt targets, 14-18 buttons visible, labeled as requiring more precision

This matches Cubasis 3's approach: *"The new UI scaling options. You can zoom in/out on various views...a combination of full-screen mode and three channel-zoom levels make for much easier operation."*

### Text labels are essential, icons supplementary

For a REAPER companion app, text labels are non-negotiable. REAPER has **thousands of actions** with non-obvious names—"SWS: Toggle show all envelopes for tracks" cannot be represented by an icon. Design for **icon + text** as default with icon-only as an optional dense mode.

From the REAPER forums regarding ambiguous icons: *"The point behind having ambiguous icons is so people can use them for macros and stuff as well."* This confirms users will need flexibility for custom actions.

---

## Slot system specification for REAmo toolbar

Based on user feedback and competitor analysis, here's a concrete specification:

### Button count and sizing

| Mode | Buttons Visible | Touch Target | Row Count | Use Case |
|------|----------------|--------------|-----------|----------|
| Standard | 8-12 | 48pt minimum | 2 rows × 4-6 cols | Most users, general use |
| Dense | 14-18 | 40pt minimum | 3 rows × 5-6 cols | Power users, larger screens |
| Compact | 6-8 | 54pt minimum | 1 row × 6-8 cols | iPhone, portrait mode |

**Fixed vs. configurable slots**: Follow Logic Remote's pattern—reserve **4-6 persistent slots** (bottom row) for transport/critical actions that remain visible across all pages. Pages above contain user-configurable actions.

### Uniform button sizing recommended

Users don't complain about uniform grids; they complain about text being cut off. **Use uniform button sizes** but allow text to wrap or truncate with ellipsis. Variable-width buttons based on text length create unpredictable layouts and prevent muscle memory formation.

From TouchOSC feedback: *"The downside I have noticed of this other app is that there's no snap to grid option, which makes exact button placement a bit tedious."* A consistent grid eliminates alignment frustration.

### Overflow handling: horizontal swipe paging

Three overflow patterns appear in successful apps:

1. **Horizontal swipe paging** (Logic Remote): Pages with dot indicators, swipe left/right
2. **Tab navigation** (Lemur, TouchOSC): Labeled tabs at edge of view
3. **Overflow menu** (Material Design): Three-dot menu hiding additional actions

**Recommendation: Horizontal swipe paging** with page indicators. This is the most natural touch gesture, doesn't sacrifice screen real estate to tabs, and matches iOS navigation patterns users already know.

Critical detail from TouchOSC: implement *"Double Tap option to prevent accidental page switches"*—single swipe navigates, but require intentional gesture to prevent frustration during rapid button tapping.

### Proposed slot system

```
┌─────────────────────────────────────────────────┐
│  Page indicator: ● ○ ○ ○                        │
├─────────────────────────────────────────────────┤
│ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐    │
│ │ Action │ │ Action │ │ Action │ │ Action │    │  ← Configurable
│ │   1    │ │   2    │ │   3    │ │   4    │    │    (pageable)
│ └────────┘ └────────┘ └────────┘ └────────┘    │
│ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐    │
│ │ Action │ │ Action │ │ Action │ │ Action │    │  ← Configurable
│ │   5    │ │   6    │ │   7    │ │   8    │    │    (pageable)
│ └────────┘ └────────┘ └────────┘ └────────┘    │
├─────────────────────────────────────────────────┤
│ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐    │
│ │◀ Prev  │ │ ● Rec  │ │ ▶ Play │ │ ■ Stop │    │  ← Fixed row
│ └────────┘ └────────┘ └────────┘ └────────┘    │    (always visible)
└─────────────────────────────────────────────────┘
```

---

## Edit mode UX: long-press, drag, done

### Entry patterns users find intuitive

Three edit mode patterns appear across successful apps:

| Pattern | Pros | Cons | Used By |
|---------|------|------|---------|
| **Long-press to drag** | Immediate, no mode switch | Not discoverable, conflicts with context menus | iOS Home Screen |
| **Explicit edit button** | Clear entry point, accessible | Extra step | Logic Remote, older iOS |
| **Drag handles visible** | Clear affordance, immediate | Takes space | Notion, web apps |

**Recommendation: Explicit edit button + long-press shortcut**. Provide an "Edit Toolbar" button in settings or via a dedicated icon, but also support long-press on any button to enter edit mode for power users. Logic Remote requires **two-finger tap** to trigger actions while in edit mode—adopt this to prevent accidental triggers during editing.

### In-app editing is mandatory

The single clearest user demand: **no desktop editor required**. From user feedback on Lemur and TouchOSC, requiring a computer for layout changes is a dealbreaker. REAmo must support:

- In-app button reordering (drag to new slot or swap positions)
- In-app action assignment (browse/search REAPER actions)
- In-app color and icon selection
- In-app page management (add, remove, reorder pages)

Export/import of configurations (JSON or similar) enables sharing without requiring it for basic customization.

### Time investment expectations

Users are willing to spend **5-15 minutes** on initial setup if the result is a personalized, efficient workflow. They are **not willing** to spend hours learning an editor or scripting language. From Digital DJ Tips: *"The first time [setup] may seem daunting at first because of all the steps you have to go through, but the great thing is you'll only have to do this once."*

Provide 3-5 pre-configured pages as starting points:

- **Recording** (arm, record, punch in/out, takes, markers)
- **Mixing** (solo, mute, bypass FX, routing)  
- **Editing** (split, glue, trim, nudge, quantize)
- **Navigation** (markers, regions, zoom, scroll)
- **Custom** (empty for user configuration)

---

## Anti-patterns to avoid

### Never require desktop software for basic configuration

From Loopy Pro Forum: *"For me Lemur is a no-go because I don't want to run to a PC every time I want to build a surface."* Avid Control requires EuControl desktop software for soft key configuration—users complain about this friction. **All configuration must be possible on-device.**

### Don't force users to choose between transport and actions

Avid Control forces toggling between Transport view and Soft Keys view—users cannot see both simultaneously. Sound On Sound noted this as a significant limitation. **Always keep transport controls visible** in a dedicated persistent section.

### Avoid cramped layouts that require stylus precision

Multiple users mentioned needing an Apple Pencil or stylus for accurate tapping in poorly-designed interfaces. If users need precision tools for a touch interface, the design has failed. **Test with actual fingers on actual devices.**

### Don't hide functionality in long-press-only gestures

While long-press is useful for power users, placing essential functionality exclusively behind long-press gestures frustrates users. From FL Studio Mobile documentation: *"Reading the manual is recommended, since there are a number of functions that rely on double-tapping, holding your finger on a button for a second...methods you may not stumble across."* **Essential actions need visible buttons or clear onboarding.**

### Avoid WiFi-only connectivity

Connectivity issues are the #1 complaint across all remote control apps. Users note that *"USB connects with no issues"* and appreciate wired options. **Support both WiFi/OSC and wired USB connections** where platform allows.

### Don't use variable button widths based on text

Variable-width buttons (where "SWS: Toggle show all envelopes" is wider than "Play") create chaotic layouts that prevent muscle memory. Users remember **position**, not labels, for fast operation. **Use uniform button sizes** with consistent text truncation.

### Avoid segmented controls in toolbars

Apple's iOS HIG explicitly advises against segmented controls in toolbars: *"Don't use a segmented control in a toolbar"*—they belong in navigation contexts. **Use dedicated buttons or tab bars** for mode switching, not toolbar segments.

---

## Conclusion: build for speed and confidence

The ideal REAmo toolbar serves users who are mid-session and need actions **fast**. They're not staring at their iPad—they're watching the artist in the booth, managing a take, or deep in a mixing decision. The toolbar should enable confident tapping without looking, finding actions by color and position, and customizing layout without abandoning REAPER.

**Key specifications for REAmo:**

- **8-12 buttons visible** in standard mode (48pt+ targets)
- **Fixed bottom row** for transport (4-6 slots, always visible)
- **Horizontal swipe paging** with dot indicators for overflow
- **Text + icon** as default, icon-only as optional dense mode
- **Long-press + explicit edit button** for customization
- **Pre-built workflow pages** with full in-app editing
- **Color coding** for visual organization

The patterns that delight users—Logic Remote's fixed row, Cubasis's "panels that stay out of your way," color-coded organization—all share a common thread: they respect that touch interfaces are for **triggering and navigating**, not fine manipulation. Build REAmo's toolbar for confident, eyes-free operation, and users will integrate it into their daily workflow.
