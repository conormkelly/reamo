# SMPTE Timecode Implementation for REAPER Remote Control

**Drop-frame timecode for 59.94fps skips 4 frames per minute**, following the same pattern as 29.97fps but doubled. 23.976fps has no drop-frame standard—it's mathematically impossible due to fractional frame drift. REAPER supports preset frame rates of 23.976, 24, 25, 29.97 (DF/NDF), 30, and 75fps, with high frame rates like 59.94 and 60fps available only through manual entry. For implementation, the `smpte-timecode` npm package provides a well-tested reference based on Andrew Duncan's authoritative algorithm.

## REAPER's frame rate support and API behavior

REAPER's `TimeMap_curFrameRate(proj, &dropframe)` returns two values: the frame rate as a float (e.g., 29.97, 24.0) and a boolean indicating drop-frame status. The preset dropdown includes **23.976, 24, 25, 29.97 DF, 29.97 NDF, 30, and 75fps** (the last for CD frame marking). Notably, high frame rates like 50, 59.94, and 60fps are not in the standard dropdown but can be manually entered in the project settings field.

This has an important implementation consequence: when REAPER returns 59.94 or 60fps, the user has manually configured this rate. Your implementation should handle these rates even though they're not preset options.

REAPER displays negative timecode with a **negative sign prefix**. Ten seconds before project time zero displays as `-01:59:50:00`, representing "hour -1, position 59:50:00 into that hour." This differs from Pro Tools (24-hour wraparound showing `23:59:50:00`) and Nuendo (which prohibits negative timecode entirely). For strict REAPER compatibility, implement negative handling by computing the absolute value timecode and prepending a minus sign.

## The drop-frame algorithm explained

Drop-frame timecode exists because 29.97fps and 59.94fps don't divide evenly into real time. At 30fps, exactly 108,000 frames equal one hour. At 29.97fps, one hour contains only **107,892 frames**—a deficit of 108 frames per hour. Drop-frame "skips" frame numbers (not actual frames) to keep timecode synchronized with wall-clock time.

For **29.97fps drop-frame**, frames 0 and 1 are skipped at the start of every minute except minutes divisible by 10. This drops 2 frames × 9 minutes = 18 frames per 10-minute block, or 108 frames per hour—exactly compensating for the deficit.

For **59.94fps drop-frame**, frames 0, 1, 2, and 3 are skipped at the start of every minute except minutes divisible by 10. This drops 4 frames × 9 minutes = 36 frames per 10-minute block, maintaining synchronization at double the frame rate.

**23.976fps cannot have drop-frame timecode**. The math shows why: over 10 minutes, 23.976fps produces a deficit of 14.4 frames—a fractional value that never resolves to an integer. All authoritative sources confirm this: 23.976 material uses standard 24fps timecode notation (frames 0-23) and simply drifts from real time. After one hour, 23.976 NDF timecode reads approximately 3.6 seconds slow.

## Complete implementation

```javascript
/**
 * Convert seconds to SMPTE timecode string
 * Based on Andrew Duncan's algorithm (andrewduncan.net/timecodes/)
 * 
 * @param {number} seconds - Time position in seconds (can be negative)
 * @param {number} frameRate - Frame rate (23.976, 24, 25, 29.97, 30, 59.94, 60)
 * @param {boolean} dropFrame - Whether to use drop-frame timecode
 * @returns {string} SMPTE timecode in format HH:MM:SS:FF or HH:MM:SS;FF for drop-frame
 */
function secondsToSMPTE(seconds, frameRate, dropFrame) {
    // Handle negative timecode (REAPER-style)
    const isNegative = seconds < 0;
    seconds = Math.abs(seconds);
    
    // Round frame rate to get nominal rate (30 for 29.97, 60 for 59.94, etc.)
    const nominalRate = Math.round(frameRate);
    
    // Calculate total frame count from seconds
    let totalFrames = Math.floor(seconds * frameRate);
    
    // Drop-frame is only valid for 29.97 and 59.94
    const isValidDropFrame = dropFrame && 
        (Math.abs(frameRate - 29.97) < 0.1 || Math.abs(frameRate - 59.94) < 0.1);
    
    if (isValidDropFrame) {
        // Number of frames to drop per minute (2 for 29.97, 4 for 59.94)
        const dropFrames = Math.round(frameRate * 0.066666);
        
        // Frames per 10-minute block (17,982 for 29.97, 35,964 for 59.94)
        const framesPer10Min = Math.round(frameRate * 60 * 10);
        
        // Frames per minute after drops (1,798 for 29.97, 3,596 for 59.94)
        const framesPerMinute = (nominalRate * 60) - dropFrames;
        
        // Calculate adjustment for drop-frame
        // D = number of complete 10-minute blocks
        const D = Math.floor(totalFrames / framesPer10Min);
        // M = remaining frames after complete 10-minute blocks
        const M = totalFrames % framesPer10Min;
        
        // Add back the "dropped" frame numbers
        if (M > dropFrames) {
            totalFrames += (dropFrames * 9 * D) + 
                          (dropFrames * Math.floor((M - dropFrames) / framesPerMinute));
        } else {
            totalFrames += dropFrames * 9 * D;
        }
    }
    
    // Convert frame count to timecode components
    const frames = totalFrames % nominalRate;
    const totalSeconds = Math.floor(totalFrames / nominalRate);
    const secs = totalSeconds % 60;
    const totalMinutes = Math.floor(totalSeconds / 60);
    const mins = totalMinutes % 60;
    const hours = Math.floor(totalMinutes / 60) % 24; // 24-hour rollover
    
    // Format with appropriate separator (; for drop-frame, : for non-drop)
    const separator = isValidDropFrame ? ';' : ':';
    const prefix = isNegative ? '-' : '';
    
    return `${prefix}${pad(hours)}:${pad(mins)}:${pad(secs)}${separator}${pad(frames)}`;
}

/**
 * Convert SMPTE timecode string to seconds
 * @param {string} timecode - SMPTE timecode (HH:MM:SS:FF or HH:MM:SS;FF)
 * @param {number} frameRate - Frame rate
 * @returns {number} Time in seconds
 */
function SMPTEToSeconds(timecode, frameRate) {
    const isNegative = timecode.startsWith('-');
    timecode = timecode.replace(/^-/, '');
    
    // Detect drop-frame from semicolon separator
    const dropFrame = timecode.includes(';');
    const parts = timecode.split(/[:;]/);
    
    const hours = parseInt(parts[0], 10);
    const mins = parseInt(parts[1], 10);
    const secs = parseInt(parts[2], 10);
    const frames = parseInt(parts[3], 10);
    
    const nominalRate = Math.round(frameRate);
    
    // Calculate frame number
    let totalFrames = (hours * 3600 + mins * 60 + secs) * nominalRate + frames;
    
    // Adjust for drop-frame
    if (dropFrame && (Math.abs(frameRate - 29.97) < 0.1 || Math.abs(frameRate - 59.94) < 0.1)) {
        const dropFrames = Math.round(frameRate * 0.066666);
        const totalMinutes = hours * 60 + mins;
        
        // Subtract the dropped frame numbers
        totalFrames -= dropFrames * (totalMinutes - Math.floor(totalMinutes / 10));
    }
    
    const seconds = totalFrames / frameRate;
    return isNegative ? -seconds : seconds;
}

function pad(num) {
    return num.toString().padStart(2, '0');
}
```

## Critical test vectors for validation

The following test cases come from authoritative sources including Andrew Duncan's timecode reference, the `smpte-timecode` npm library, and verified broadcast engineering documentation.

### 29.97fps drop-frame boundary cases

| Seconds | Frame Count | Expected Timecode | Notes |
|---------|-------------|-------------------|-------|
| 0 | 0 | 00:00:00;00 | First frame |
| 59.9666... | 1799 | 00:00:59;29 | Last frame before first skip |
| 60.0333... | 1800 | 00:01:00;02 | **First skip boundary** (;00 and ;01 skipped) |
| 119.9666... | 3597 | 00:01:59;29 | Before minute 2 skip |
| 120.0333... | 3598 | 00:02:00;02 | After minute 2 skip |
| 599.9333... | 17981 | 00:09:59;29 | Before 10-minute mark |
| 600.0 | 17982 | **00:10:00;00** | **No skip** (10th minute) |
| 3600.0 | 107892 | 01:00:00;00 | One hour mark |
| 36000.0 | 1078920 | 10:00:00;00 | Ten hours |

### 59.94fps drop-frame boundary cases

| Frame Count | Expected Timecode | Notes |
|-------------|-------------------|-------|
| 3599 | 00:00:59;59 | Last frame before first skip |
| 3600 | **00:01:00;04** | **First skip** (;00, ;01, ;02, ;03 skipped) |
| 35964 | 00:10:00;00 | 10-minute mark (no skip) |
| 215784 | 01:00:00;00 | One hour |

### Non-drop frame test cases

| Frame Rate | Frame Count | Expected Timecode |
|------------|-------------|-------------------|
| 24fps | 0 | 00:00:00:00 |
| 24fps | 1511 | 00:01:02:23 |
| 24fps | 86400 | 01:00:00:00 |
| 25fps | 15000 | 00:10:00:00 |
| 25fps | 90000 | 01:00:00:00 |
| 30fps | 18000 | 00:10:00:00 |
| 30fps | 108000 | 01:00:00:00 |
| 60fps | 36000 | 00:10:00:00 |
| 60fps | 216000 | 01:00:00:00 |

### Invalid drop-frame timecodes to reject or round

Your parser should handle these invalid inputs gracefully:

- `00:01:00;00` at 29.97 DF → round to `00:01:00;02`
- `00:01:00;01` at 29.97 DF → round to `00:01:00;02`
- `00:01:00;00` through `00:01:00;03` at 59.94 DF → round to `00:01:00;04`
- `00:10:00;00` at 29.97 DF → **valid** (10th minute, no skip)

## Key mathematical constants

These constants are essential for verification and testing:

| Frame Rate | Frames per 10 min | Frames per Hour | Frames Dropped per Min |
|------------|-------------------|-----------------|------------------------|
| 29.97 DF | **17,982** | **107,892** | 2 |
| 29.97 NDF | 18,000 | 108,000 | 0 |
| 59.94 DF | **35,964** | **215,784** | 4 |
| 59.94 NDF | 36,000 | 216,000 | 0 |
| 24/23.976 | 14,400 | 86,400 | 0 |
| 25 | 15,000 | 90,000 | 0 |
| 30 | 18,000 | 108,000 | 0 |
| 60 | 36,000 | 216,000 | 0 |

The exact NTSC rate is **30000/1001** (≈29.97002997), not exactly 29.97. Over 24 hours, this causes approximately 2.59 frames of accumulated drift, which broadcast facilities correct through periodic "jam sync" operations.

## Recommended libraries and references

The **`smpte-timecode`** npm package (~8,000 weekly downloads) provides the most battle-tested JavaScript implementation. It's maintained by LTN Global Communications, handles all frame rates including 59.94 DF, and is based on Andrew Duncan's authoritative algorithm. For TypeScript projects, **`@spiretechnology/js-timecode`** offers native TypeScript support with comprehensive test coverage.

Key reference sources:

- **Andrew Duncan's timecode page** (andrewduncan.net/timecodes/) — The definitive mathematical reference used by nearly all implementations
- **David Heidelberger's drop-frame article** — Clear code examples validated by the Kdenlive project
- **FFmpeg libavutil/timecode.c** — Reference C implementation in production video software

## REAPER-specific considerations

Your implementation should account for these REAPER behaviors:

1. **Negative timecode**: REAPER displays `-01:59:50:00` for 10 seconds before zero. Implement this by computing absolute-value timecode and prepending a minus sign, not by wrapping at 24 hours.

2. **Custom frame rates**: REAPER accepts any manually-entered frame rate. Consider validating that drop-frame is only enabled for rates close to 29.97 or 59.94.

3. **Frame numbering**: REAPER uses 0-based frame numbers (0-29 for 30fps), matching SMPTE standards after historical bug fixes.

4. **Separator convention**: Use semicolon (`;`) for drop-frame timecode and colon (`:`) for non-drop-frame. This matches REAPER's display and allows automatic drop-frame detection when parsing.

## Edge cases and implementation notes

**Fractional frames**: When converting seconds to frames, use `Math.floor(seconds * frameRate)` to get the current frame. Mid-frame times belong to the frame they're within, not the next frame.

**24-hour rollover**: Standard SMPTE timecode wraps at 24 hours. Frame 2,589,408 at 29.97 DF equals `00:00:00;00` (rolled over). Implement with `hours % 24`.

**23.976fps drift**: After one hour at 23.976 NDF, timecode reads `00:59:56:10`—approximately 3.6 seconds slow relative to wall-clock time. This is expected behavior, not a bug.

**High frame rates**: For 50fps and 59.94fps, MTC (MIDI Timecode) uses half-rate transmission (25fps or 29.97fps respectively) since the 1980s-era MTC standard doesn't support rates above 30fps.
