# Timeline scroll behavior at project end: Research for REAmo

When a playhead in continuous scroll mode approaches the end of a project, a fundamental UX challenge emerges: the playhead can no longer maintain its fixed screen position because there's no more content to scroll. **Final Cut Pro documents the cleanest solution: scrolling simply stops when no more clip data exists**, transitioning the playhead from stationary to moving through the final portion of the timeline. This "stop scrolling, let playhead travel" pattern appears across most professional implementations, though none document explicit transition zones or gradual migrations.

The REAmo app should implement a hybrid approach: maintain fixed playhead scrolling until a transition threshold (approximately **15% of visible timeline width remaining**), then smoothly decelerate scrolling while allowing the playhead to drift rightward using ease-out timing. This provides the "soft landing" feel without the disorientation of variable scroll-to-audio speed ratios.

## How existing applications handle end-of-timeline

Research across 16+ applications reveals three dominant patterns for handling playhead behavior when approaching project end:

| Application | Scroll Mode Name | Fixed Playhead Position | End-of-Project Behavior | Visual Indicator |
|-------------|------------------|------------------------|------------------------|------------------|
| **Final Cut Pro** | Continuous Scrolling | Center | "Scrolling stops when no more clip data to scroll" | None documented |
| **Premiere Pro** | Smooth Scroll | Center | Maintains center until content ends, then transitions | None documented |
| **Pro Tools Ultimate** | Continuous Scrolling | Center | Continues with "grey blank space" beyond content | None |
| **Logic Pro** | Catch + Scroll in Play | Center | Continues into "dead area" past last content | None |
| **Cubase** | Stationary Cursor | Configurable | Not explicitly documented; likely similar to Pro Tools | None |
| **REAPER** | Continuous Scrolling | Configurable | "Play past end of project" preference (default ~2s) | None |
| **Ableton Live** | Follow | No fixed position (page scroll only) | Page jump behavior | Overview bar |
| **Studio One** | Autoscroll | No fixed position | Page scroll only (stationary cursor frequently requested) | None |
| **DaVinci Resolve** | Fixed Playhead (Cut page only) | Yes (Cut page) | Post-roll time setting controls playback past end | Playhead shadow |
| **Cubasis iOS** | Auto-Scroll | No (page scroll) | Page jump to end | None |
| **GarageBand iOS** | Catch Mode | Center (Mac); less documented iOS | "Playhead gradually works back to middle while staying visible" | None |
| **CapCut** | Follow Marker Line | Keeps marker visible | Timeline scrolls to maintain visibility | None |

**Critical finding**: No application documents a "gradual migration" transition zone or anticipatory slowdown. The industry standard is binary: either the view continues scrolling (showing empty space), or scrolling stops and the playhead travels through a static view.

## Standard terminology for scroll behaviors

The industry has settled on consistent terminology across major applications. **Continuous scrolling** (Apple, Avid) and **smooth scroll** (Adobe) describe the fixed-playhead mode where content moves beneath a stationary cursor. **Page scroll** universally describes the behavior where the playhead moves until hitting a screen edge, then the view "turns a page" to show the next section.

| Behavior Pattern | Primary Terms | Apps Using This Term |
|-----------------|---------------|---------------------|
| Playhead fixed, timeline scrolls | Continuous Scrolling, Smooth Scroll, Stationary Cursor | Final Cut Pro, Premiere Pro, Pro Tools, Cubase |
| View jumps when playhead reaches edge | Page Scroll | All major DAWs/NLEs |
| View follows playhead position | Catch Playhead, Follow, Auto-Scroll | Logic Pro, Ableton, Cubasis |
| No automatic scrolling | No Scroll, Static Timeline | Premiere Pro preference |

Apple's Human Interface Guidelines and Google Material Design provide no specific guidance for professional timeline editors—both focus on consumer media playback controls rather than editing workflows. However, Apple's own Final Cut Pro implementation (Option-Shift-S toggle) serves as the de facto iOS/macOS standard.

## Evaluation of proposed solutions

### Option A: Gradual migration (not recommended)

This approach would have the playhead drift from its 1/3 position toward the right edge as the project end approaches, maintaining a smooth visual transition.

**Pros**: Avoids abrupt behavioral change; visually elegant in theory; no empty space appears. **Cons**: No existing application implements this pattern—users would encounter unfamiliar behavior. Creates a perception mismatch where the audio continues at constant speed while the visual representation's movement changes. Implementing a proper migration curve requires knowing the project length in advance, which may change during editing.

**Research finding**: The academic paper "Data-Driven Interaction Techniques for Educational Video Navigation" explored non-linear scrubbing where cursor speed varies based on content density, but found this created user confusion. Dynamic speed relationships between input and visual feedback consistently test poorly.

### Option B: Hard stop with empty space (not recommended for primary use)

The playhead maintains its fixed position until physically impossible, then the view stops scrolling while the playhead moves through the final portion to the project end. Empty space appears on the right side of the screen.

**Pros**: Simple to implement; matches Pro Tools and Logic Pro behavior; predictable. **Cons**: "Empty space" appearance feels unpolished on a mobile-first interface; multiple forum users describe this as annoying ("dead area"); no visual warning before the transition occurs.

**Research finding**: Logic Pro users specifically asked "How do I get the playhead to stop at the end of the last track to prevent it from continuing to scroll into the 'dead' area?" indicating this behavior frustrates users.

### Option C: Anticipatory slowdown (recommended with modifications)

Scroll speed gradually decreases as the end approaches, creating a "soft landing" where the playhead naturally ends up at the right edge when the project completes.

**Pros**: Smooth, polished feel appropriate for touch interface; provides implicit visual feedback that end is approaching; no jarring transition. **Cons**: Creates speed mismatch between audio playback and visual timeline movement—potentially disorienting if too aggressive.

**Critical modification**: Research on scroll-linked animations indicates that linear easing feels most natural when motion is directly tied to content playback. The solution is to **combine deceleration with playhead migration** rather than pure scroll slowdown. As scrolling slows, the playhead position simultaneously drifts rightward, maintaining approximate visual-audio correspondence.

### Option D: Loop mode exception (yes, implement this)

When loop/repeat mode is enabled, the end-of-project problem largely disappears—the view should seamlessly transition back to the loop start.

**Implementation note**: Unity's Timeline system documents this well: pre-buffer the start position when approaching end, then execute a clean visual transition. Forum discussions about seamless looping highlight that 250ms+ visual hiccups are common if not properly pre-loaded.

## Primary recommendation: Hybrid deceleration with playhead drift

For REAmo's touch-optimized interface with 30Hz position updates, implement a hybrid of Options B and C:

**Phase 1: Normal scrolling** (0% to ~85% of approach to end)
- Playhead maintains fixed position at 1/3 from left edge
- Timeline scrolls smoothly at normal rate
- Standard behavior, no special handling

**Phase 2: Transition zone** (~85% to 100%)
- **Trigger**: When `remaining_scrollable_distance < (visible_width × 0.5)`
- **Duration**: Typically 1-3 seconds depending on zoom level
- **Behavior**: 
  - Scroll velocity multiplied by ease-out factor: `velocity × (remaining_percent²)`
  - Playhead position simultaneously drifts rightward from 1/3 toward final position
  - Result: Smooth deceleration with playhead arriving at actual end position naturally

**Phase 3: End hold** (project complete)
- Scrolling stops completely
- Playhead at actual project end position (right side of content)
- No empty space visible—view shows final section of project

**Rationale**: This approach provides the polished feel required for a touch interface while avoiding the disorientation of pure scroll slowdown. The simultaneous playhead drift maintains approximate audio-visual correspondence, preventing the "video slowing down" perception.

## Implementation specifications

### Transition zone calculations

```
// Thresholds (configurable)
PLAYHEAD_POSITION = 0.33        // Normal: 1/3 from left edge
TRANSITION_TRIGGER = 0.5        // Start transition when remaining scroll < 50% of visible width
MINIMUM_TRANSITION_TIME = 1.0   // Seconds - prevents jarring transition on short projects

// State variables
visible_width       // Current visible timeline width in time units
project_end         // End of last content in project
playhead_position   // Current playhead time
scroll_offset       // Current left edge of visible timeline

// Calculate remaining scrollable distance
remaining = project_end - (scroll_offset + visible_width × PLAYHEAD_POSITION)
threshold = visible_width × TRANSITION_TRIGGER

if (remaining < threshold) {
    // In transition zone
    progress = 1.0 - (remaining / threshold)  // 0.0 → 1.0 as approaching end
    
    // Apply ease-out curve: cubic deceleration
    eased_progress = 1.0 - pow(1.0 - progress, 3)
    
    // Calculate new playhead screen position (drifts from 0.33 toward right edge)
    target_playhead_screen_pos = PLAYHEAD_POSITION + (eased_progress × (1.0 - PLAYHEAD_POSITION - 0.05))
    
    // Interpolate scroll velocity (slows to ~20% of normal at end)
    scroll_velocity_multiplier = 0.2 + (0.8 × (1.0 - eased_progress))
}
```

### State machine definition

```
States:
    NORMAL_SCROLL       - Standard continuous scroll, playhead at 1/3 position
    TRANSITION          - Decelerating scroll, playhead drifting right
    END_HOLD            - At project end, static view
    LOOP_TRANSITION     - Preparing for seamless loop restart

Events:
    POSITION_UPDATE     - 30Hz playhead position update from REAPER
    LOOP_ENABLED        - User enables loop mode
    LOOP_DISABLED       - User disables loop mode
    PROJECT_END         - Playhead reaches end of content

Transitions:
    NORMAL_SCROLL + (remaining < threshold) → TRANSITION
    TRANSITION + PROJECT_END → END_HOLD
    TRANSITION + LOOP_ENABLED → LOOP_TRANSITION
    END_HOLD + (playhead moves backward) → NORMAL_SCROLL
    LOOP_TRANSITION + PROJECT_END → NORMAL_SCROLL (at loop start)
```

### Visual design for transitions

**Transition zone indicator** (subtle, optional): A very slight gradient or opacity change in the rightmost 10% of the timeline background, hinting that the project end is approaching. This should be barely perceptible—not a harsh visual boundary.

**End-of-project marker**: A thin vertical line (1-2pt) at the exact project end position, slightly more prominent than standard grid lines. Color should match the app's accent color at ~40% opacity.

**No empty space**: The view should never show timeline area beyond the project end. The transition algorithm ensures the view "lands" with the project end at the right edge of the screen.

### Frame rate and timing considerations

At 30Hz position updates:
- Each frame represents ~33ms
- Transition calculations should be time-based, not frame-based
- Use elapsed time since last update for velocity calculations
- Apply frame-rate-independent smoothing: `new_value = lerp(old_value, target, 1 - pow(smoothing, delta_time))`

**Recommended smoothing factor**: 0.85 for scroll position, 0.9 for playhead drift (slightly slower to feel more intentional)

## Phone versus tablet considerations

Research from IMG.LY's mobile video editor development indicates that phone and tablet interfaces require different timeline handling:

**Phone (small screen)**: The 1/3 playhead position may need adjustment to ~0.25 (further left) because less content is visible at any moment. Transition zones should trigger slightly earlier (60% of visible width remaining) to allow more gradual deceleration on the smaller display.

**Tablet (larger screen)**: Standard 1/3 position works well. More content visible means transitions can be more subtle. Consider allowing slightly later transition trigger (45% remaining).

**Recommendation**: Make the playhead position percentage and transition trigger configurable in the app's settings, with sensible defaults per device class. However, for V1 with no manual view control, a single behavior that works acceptably on both form factors is preferable to complexity.

## Accessibility requirements

**prefers-reduced-motion**: Must be respected. When enabled:
- Disable the smooth transition—use instant snap to end position
- Replace deceleration with binary behavior (scrolling → stopped)
- Maintain functional correctness without animation

**Implementation**:
```swift
// iOS/SwiftUI
@Environment(\.accessibilityReduceMotion) var reduceMotion

// Web
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
```

**Predictability**: For users with vestibular disorders, the gradual deceleration should feel predictable. Avoid any "bounce" or overshoot effects. The playhead should never move backward or change direction unexpectedly.

## Settings recommendations for V1

Given the constraint of no manual view control in V1, a single well-tuned behavior is superior to user configuration. However, consider exposing one preference:

**Scroll behavior at project end**:
- "Smooth landing" (default) — gradual deceleration with playhead drift
- "Stop scrolling" — abrupt stop, playhead travels through static view

This matches the industry pattern where all major applications offer scroll mode choices. Forum research consistently shows users are divided—some prefer smooth scroll, others prefer page scroll. Offering the single most impactful choice acknowledges this without overwhelming mobile users with options.

## Pseudocode: Complete scroll controller

```swift
class TimelineScrollController {
    // Configuration
    let normalPlayheadPosition: CGFloat = 0.33
    let transitionThreshold: CGFloat = 0.50
    let minimumTransitionDuration: TimeInterval = 1.0
    let endVelocityFactor: CGFloat = 0.20
    
    // State
    enum ScrollState { case normal, transition, endHold, loopTransition }
    var state: ScrollState = .normal
    var transitionProgress: CGFloat = 0.0
    
    // Receives 30Hz position updates
    func update(playheadTime: TimeInterval, 
                projectEnd: TimeInterval, 
                visibleDuration: TimeInterval,
                deltaTime: TimeInterval,
                isLooping: Bool) {
        
        // Calculate how much scrollable content remains
        let currentScrollPosition = playheadTime - (visibleDuration * normalPlayheadPosition)
        let maxScrollPosition = projectEnd - (visibleDuration * (1.0 - 0.05)) // 5% margin
        let remainingScroll = maxScrollPosition - currentScrollPosition
        let threshold = visibleDuration * transitionThreshold
        
        switch state {
        case .normal:
            if remainingScroll < threshold {
                state = .transition
                transitionProgress = 0.0
            }
            // Standard scroll: view follows playhead at fixed position
            renderPlayheadAtScreenPosition(normalPlayheadPosition)
            
        case .transition:
            // Calculate progress through transition (0→1)
            transitionProgress = 1.0 - (remainingScroll / threshold)
            transitionProgress = clamp(transitionProgress, 0.0, 1.0)
            
            // Apply ease-out curve (cubic)
            let easedProgress = 1.0 - pow(1.0 - transitionProgress, 3)
            
            // Drift playhead position rightward
            let targetPosition = normalPlayheadPosition + 
                (easedProgress * (0.95 - normalPlayheadPosition))
            
            // Apply scroll velocity reduction
            let velocityMultiplier = endVelocityFactor + 
                ((1.0 - endVelocityFactor) * (1.0 - easedProgress))
            
            renderPlayheadAtScreenPosition(targetPosition)
            applyScrollVelocityMultiplier(velocityMultiplier)
            
            // Check for end
            if playheadTime >= projectEnd {
                state = isLooping ? .loopTransition : .endHold
            }
            
        case .endHold:
            // Static view, playhead at project end
            renderPlayheadAtAbsoluteTime(projectEnd)
            if playheadTime < projectEnd - 0.1 { // Moved backward
                state = .normal
            }
            
        case .loopTransition:
            // Pre-buffer handled elsewhere; execute visual snap to start
            state = .normal
            transitionProgress = 0.0
        }
    }
    
    // Accessibility override
    func updateWithReducedMotion(playheadTime: TimeInterval, 
                                  projectEnd: TimeInterval,
                                  visibleDuration: TimeInterval) {
        let maxScrollPosition = projectEnd - (visibleDuration * 0.95)
        let currentPosition = playheadTime - (visibleDuration * normalPlayheadPosition)
        
        if currentPosition >= maxScrollPosition {
            // Instant snap to end view
            renderViewEndingAt(projectEnd)
            renderPlayheadAtAbsoluteTime(playheadTime)
        } else {
            // Standard fixed-position scroll
            renderPlayheadAtScreenPosition(normalPlayheadPosition)
        }
    }
}
```

## Key references and sources

**Official Documentation**
- Apple Final Cut Pro User Guide: "Scroll the Final Cut Pro for Mac timeline continuously during playback" — explicitly documents "scrolling will stop when there's no more available clip data"
- Adobe Premiere Pro Help: Timeline Playback Auto-Scrolling preferences (Edit > Preferences > Timeline)
- Steinberg Cubase Documentation: Auto-Scroll and Stationary Cursor mode descriptions
- REAPER Wiki: Continuous scrolling behavior and "Play past end of project" preference

**UX Research**
- "DRAGON: Direct manipulation for frame-accurate navigation" — 19-42% task completion improvement with direct manipulation
- "Data-Driven Interaction Techniques for Educational Video Navigation" (UIST 2014) — non-linear timeline scrubbing research
- IMG.LY: "Building a Mobile Video Editor" — comprehensive mobile timeline UX case study with gesture handling guidance

**Forum Discussions**
- Gearspace thread on Logic Pro "Catch Playhead" frustrations and user preferences
- PreSonus Community feature request for Studio One continuous scroll
- Cockos REAPER Forums on scroll behavior and the apostrophe (') resync shortcut
- Adobe Community discussion showing user preference split between smooth and page scroll

**Accessibility Standards**
- WCAG 2.1 Success Criterion 2.3.3: Animation from Interactions
- WCAG 2.1 Success Criterion 2.2.2: Pause, Stop, Hide
- prefers-reduced-motion CSS media query specification

**Technical Implementation**
- Chrome Scroll-Driven Animations API documentation (animation-timeline, animation-range)
- iOS scroll physics analysis: momentum decay factor of 0.95 per frame
- Unity Timeline documentation: Wrap Mode settings (Hold, Loop, None) and extrapolation behavior
