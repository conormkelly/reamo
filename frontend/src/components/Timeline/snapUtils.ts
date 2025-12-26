/**
 * Snap Utilities
 *
 * Time selection snapping logic for the timeline.
 */

export interface SnapTargets {
  regions: Array<{ start: number; end: number }>
  markers: Array<{ position: number }>
  playheadPosition?: number
}

/**
 * Find the nearest snap target to a given time.
 * Checks region boundaries, marker positions, and optionally the playhead.
 */
export function findNearestSnapTarget(time: number, targets: SnapTargets): number {
  let nearest = time
  let minDist = Infinity

  // Check region boundaries
  for (const region of targets.regions) {
    const startDist = Math.abs(region.start - time)
    const endDist = Math.abs(region.end - time)
    if (startDist < minDist) {
      minDist = startDist
      nearest = region.start
    }
    if (endDist < minDist) {
      minDist = endDist
      nearest = region.end
    }
  }

  // Check markers
  for (const marker of targets.markers) {
    const dist = Math.abs(marker.position - time)
    if (dist < minDist) {
      minDist = dist
      nearest = marker.position
    }
  }

  // Check playhead position
  if (targets.playheadPosition !== undefined) {
    const dist = Math.abs(targets.playheadPosition - time)
    if (dist < minDist) {
      nearest = targets.playheadPosition
    }
  }

  return nearest
}
