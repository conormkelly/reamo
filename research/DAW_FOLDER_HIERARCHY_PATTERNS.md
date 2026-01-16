# Mobile DAW controller folder hierarchy patterns for REAmo

**The most effective approach for displaying folder hierarchy in a mobile REAPER mixer combines color-coded grouping with "folder spill" functionality and subtle spacing variations.** Most existing mobile DAW controllers fail at folder visualization—only Avid Control provides robust support—creating an opportunity for REAmo to differentiate itself. Critically, REAPER's native OSC protocol doesn't expose `folder_depth` values, but the web interface API does via `trackflags`, making this the recommended path for implementation.

## Existing controllers mostly ignore folder hierarchy

Research across four major mobile DAW controllers reveals that **folder/group hierarchy visualization is largely absent or limited**. Logic Remote displays Track Stacks but cannot expand/collapse them independently—users report frustration that "all I see are the stack titles... and I see no way to expand the folder." Cubase iC Pro mirrors desktop Cubase's limitation where folder tracks never appear in the MixConsole view, only in the Project Overview. TouchDAW, operating as a Mackie Control emulator, inherits MCU protocol's complete lack of folder support.

**Avid Control stands alone** with comprehensive folder handling. It offers "Folder Spill"—tap a folder track and its children spread across available faders instantly. Users can open, close, and navigate Folder Tracks directly from the app with dedicated folder icons that toggle open/closed states. The implementation uses color banding to visually distinguish folder tracks and supports Pro Tools' eight-level nesting hierarchy. This "spill" paradigm has become the most requested feature in user forums across all DAW controller discussions.

The common denominator across all controllers: **track color coding appears universal**, serving as the primary visual differentiator between groups even when explicit hierarchy visualization is absent.

## Users overwhelmingly want collapse/expand and "spill" functionality

Forum discussions across Gearspace, REAPER forums, Steinberg forums, and Reddit reveal clear user priorities. The **primary desire is collapsing folders to reduce track count on limited mobile screens**. Users cite Ableton Live's behavior favorably: "If I collapse a Group track, it collapses in Mackie Control as well"—they want this sync across all DAWs.

**VCA/Folder "Spill" ranks second in priority.** Steinberg EUCON users describe it as "a very important thing," wanting to select a folder track and immediately see children across faders. Avid Control's implementation draws explicit praise: "Not only can you spill out VCA Masters, you can also open, close, and spill out Folder Tracks directly from the app."

Key user complaints reveal design anti-patterns to avoid:

- Controllers "don't properly represent child/parent folder relationships"—MCU protocol lacks this capability entirely
- Folder tracks "get in the way" when expanded, pushing relevant tracks off-screen
- Can't visually distinguish which tracks belong to which folder on the controller
- Tedious banking through many tracks without quick navigation to folders
- DAW/controller sync issues causing "years of irritation" among users

**Whether folder tracks should be visible** generates debate. Arguments for hiding: reduce clutter, speed navigation, focus on "real" audio tracks. Arguments for showing: folders serve as submix controls with volume/pan, enable quick solo/mute of entire sections. The emerging best practice is a **hybrid approach**: show folders as interactive tiles that expand to reveal children on demand.

## Effective UX patterns for horizontal hierarchy display

For REAmo's horizontal track layout, several established patterns balance space efficiency with hierarchy communication.

**Color-coded edge strips** offer the highest impact with minimal space consumption. Assign distinct colors to each parent folder; children inherit lighter shades of the parent color. This works effectively for **2-3 nesting levels** before colors become indistinguishable. Combined with track colors already used in REAPER projects, this creates intuitive visual grouping.

**Spacing variation** costs zero additional space while communicating structure. Use tighter spacing between tracks within the same folder and larger gaps between folder groups. Research from Material Design confirms this as an effective grouping mechanism, though it has **low discoverability**—users may not consciously notice the pattern.

**Inline parent headers** within the horizontal scroll provide clear hierarchy signposting. Render folder tracks visually distinct (larger, different background, folder icon) from child tracks. Include collapse/expand chevrons. This follows carousel UX patterns where category headers appear inline with scrollable content.

**Connecting top rails**—thin colored lines spanning grouped children along the top edge—provide clear visual grouping without consuming vertical space. This adapts tree-view "guides" to horizontal layouts. Trade-off: adds visual complexity in dense mixes.

**Breadcrumb context bars** work well when users "zoom into" a folder. Display "All Tracks > Drums > Kick Mics" as a floating header showing current context. Include tappable segments for quick navigation up the hierarchy. Apple's HIG notes that mobile apps using Miller Columns show "one column at a time"—this translates to showing one folder's children while maintaining parent context.

| Pattern | Space Usage | Discoverability | Visual Clutter | Depth Support |
|---------|-------------|-----------------|----------------|---------------|
| Color strips | Low | Medium | Low | 2-3 levels |
| Spacing | None | Low | None | 1-2 levels |
| Connecting rails | Medium | High | Medium | 2-3 levels |
| Inline headers | Medium | High | Low | Unlimited |
| Breadcrumbs | Medium | High | Low | Unlimited |

## Folder tracks deserve visibility with smart default behavior

The research suggests **folder tracks should be visible by default but distinctively styled**, not hidden. Folder tracks serve dual purposes in REAPER: organizational containers AND submix buses with volume/pan for level control. Hiding them removes critical mixing functionality.

Avid Control's configurable approach works well: users can filter channel types and choose whether the parent folder track appears when "spilled." This lets mixers who want minimal clutter hide folders while others retain submix control.

**Recommended default for REAmo**: Show folder tracks with distinctive visual treatment (folder icon, different background saturation, or top-edge color indicator). Provide a settings toggle to hide folders for users who prefer maximum track density. When a folder is collapsed, show only the parent; when expanded, show children with clear visual grouping to the parent.

## Interaction patterns should prioritize "spill" and quick collapse

Based on user feedback and Avid Control's successful implementation:

- **Tap folder track** → Toggle expand/collapse (show/hide children)
- **Long-press folder** → Context menu with "Solo All," "Mute All," "Select All Children," "Scroll to Parent"
- **Swipe folder left** → Quick collapse gesture (discoverable but not primary)
- **Double-tap folder** → "Spill" mode—temporarily replace visible tracks with folder children only

The "spill" paradigm deserves special attention. Users describe it as essential for navigating large sessions: tap a folder, see only its children across all visible faders, tap again (or press back) to return. This mirrors iOS navigation patterns where tapping a category shows its contents while maintaining return context.

**Preserve state on collapse**: If a user expands nested items within a folder, then collapses the parent, preserve child expansion states. When reopening, restore the previous view rather than resetting to fully collapsed.

## REAPER's technical constraints require web interface approach

A critical finding: **REAPER's native OSC implementation does NOT expose folder hierarchy information**. The `Default.ReaperOSC` configuration file lacks patterns for folder depth, parent relationships, or folder open/close state. This explains why existing Open Stage Control and TouchOSC templates for REAPER lack folder visualization—the data simply isn't available via OSC.

However, **REAPER's web interface API does expose folder information** through the `trackflags` field in track responses:

```javascript
// Track response format:
// TRACK \t tracknumber \t trackname \t trackflags \t volume...
// trackflags bit 1 (value 1) = folder track
```

For complete hierarchy reconstruction, combine web API with ReaScript:

```lua
-- Full folder depth access via ReaScript
depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
-- 1 = folder start, 0 = normal, -N = closes N folders
parent = reaper.GetParentTrack(track)
```

**Recommended architecture for REAmo**: Use the web interface as the communication layer rather than pure OSC. Parse `trackflags` for folder identification, then query `I_FOLDERDEPTH` via ReaScript for complete hierarchy. This enables full folder visualization unavailable to OSC-only implementations.

Existing REAPER controller solutions work around OSC limitations through:

- **Mixer visibility following**: Configure to follow MCP visibility; collapse folders in REAPER to hide children
- **Control Surface Integrator (CSI)**: Offers dedicated "Folder Zone" mode where selecting a folder displays children on hardware faders
- **Naming conventions**: Prefix folder tracks with symbols (`▼ Drums`) for visual identification

## Synthesis and recommended implementation

For REAmo's folder hierarchy display, the research supports a layered approach:

**Visual grouping layer**: Apply color-coded left-edge strips inherited from folder track colors. Use spacing variations (tighter within groups, gaps between). Render folder tracks with folder icons and distinct backgrounds.

**Interaction layer**: Implement tap-to-toggle expand/collapse. Add "spill" mode on double-tap or via dedicated button. Support long-press for folder group actions (solo all, mute all). Preserve expansion state when collapsing parents.

**Navigation layer**: Display breadcrumb context when zoomed into a folder. Show track count badges on collapsed folders ("8 tracks"). Provide quick-scroll targets to jump to folder starts.

**Technical layer**: Use REAPER's web interface API for `trackflags` to identify folders. Query `I_FOLDERDEPTH` via ReaScript for complete hierarchy. Build the folder tree structure client-side from flat track list with depth values.

This combination would give REAmo significantly better folder handling than Logic Remote, Cubase iC Pro, or TouchDAW—potentially matching or exceeding Avid Control's capabilities while working specifically with REAPER's folder system.
