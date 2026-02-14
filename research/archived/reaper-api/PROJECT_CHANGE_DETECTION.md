# REAPER Project Change Detection

## The Problem

Detecting project changes in a REAPER extension to reset playlist engine state.

## Key Insight: Extension Dies with REAPER

When REAPER restarts, the extension restarts too. There's no prior state to compare against - we start fresh. This simplifies the detection logic significantly.

## What We Actually Need to Detect (While REAPER is Running)

| Scenario | Pointer | StateCount | Want Reset? |
|----------|---------|------------|-------------|
| Tab switch | differs | - | YES |
| Open file in same tab | same | decreases | YES |
| Save As | same | increases | NO |
| Normal editing | same | increases | NO |
| Undo/Redo | same | same/increases | NO |

## The Solution: Simple Two-Check Detection

```zig
pub fn projectChanged(self: *const State, other: *const State) bool {
    // Different pointer = different tab
    if (self.project_pointer != other.project_pointer) return true;

    // Same pointer but state count decreased = project replaced in this tab
    // (state count increases monotonically during editing, resets on project load)
    if (other.state_change_count < self.state_change_count) return true;

    return false;
}
```

## Why This Works

### `GetProjectStateChangeCount()` Behavior

- **Increments** on every edit, undo, redo, save, save-as
- **Resets to low value** when a different project is loaded into the tab

If the count *decreased*, the project was replaced. If it stayed same or increased, it's the same project session.

### `ReaProject*` Pointer Behavior

- Each project **tab** has a unique pointer
- Pointer persists when opening different file in same tab
- Different tabs have different pointers

## Frontend Implications

For frontend edit safety, **projectPath is the stable identity**:

```typescript
// When user starts editing
const editStartPath = currentProject.path;

// When user applies edit
if (currentProject.path === editStartPath) {
    // Safe to apply—same project
} else if (editStartPath === null || currentProject.path === null) {
    // Unsaved project involved—warn user
} else {
    // Different project—block or warn
}
```

The backend resets internal state when needed. The frontend just compares paths.

## Implementation

See `extension/src/project.zig`:

- `State.projectChanged()` - Two-check detection logic
- Tests covering tab switch, file replacement, Save As, and normal editing
