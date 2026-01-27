/**
 * Tests for pure region display helper functions
 *
 * These functions were extracted from regionEditSlice to allow components
 * to call them with explicit dependencies, satisfying ESLint exhaustive-deps.
 */

import { describe, it, expect } from 'vitest';
import { computeDisplayRegions, computeDragPreview } from './regionDisplayHelpers';
import type { Region } from '../../core/types';
import type { PendingChangesRecord } from './regionEditSlice.types';

describe('computeDisplayRegions', () => {
  const baseRegions: Region[] = [
    { id: 1, name: 'Verse', start: 0, end: 10 },
    { id: 2, name: 'Chorus', start: 10, end: 20 },
    { id: 3, name: 'Bridge', start: 20, end: 30 },
  ];

  it('returns regions unchanged when no pending changes', () => {
    const result = computeDisplayRegions(baseRegions, {});

    expect(result).toHaveLength(3);
    expect(result[0].name).toBe('Verse');
    expect(result[1].name).toBe('Chorus');
    expect(result[2].name).toBe('Bridge');
  });

  it('applies pending changes to existing regions', () => {
    const pendingChanges: PendingChangesRecord = {
      2: {
        originalIdx: 2,
        originalStart: 10,
        originalEnd: 20,
        newStart: 15,
        newEnd: 25,
        name: 'Modified Chorus',
      },
    };

    const result = computeDisplayRegions(baseRegions, pendingChanges);

    expect(result).toHaveLength(3);
    // Region 2 should have pending changes applied
    const modified = result.find((r) => r.id === 2);
    expect(modified?.start).toBe(15);
    expect(modified?.end).toBe(25);
    expect(modified?.name).toBe('Modified Chorus');
  });

  it('excludes deleted regions', () => {
    const pendingChanges: PendingChangesRecord = {
      2: {
        originalIdx: 2,
        originalStart: 10,
        originalEnd: 20,
        newStart: 10,
        newEnd: 20,
        name: 'Chorus',
        isDeleted: true,
      },
    };

    const result = computeDisplayRegions(baseRegions, pendingChanges);

    expect(result).toHaveLength(2);
    expect(result.find((r) => r.id === 2)).toBeUndefined();
  });

  it('includes new regions with negative keys', () => {
    const pendingChanges: PendingChangesRecord = {
      [-1]: {
        originalIdx: -1,
        originalStart: 30,
        originalEnd: 40,
        newStart: 30,
        newEnd: 40,
        name: 'New Section',
        isNew: true,
      },
    };

    const result = computeDisplayRegions(baseRegions, pendingChanges);

    expect(result).toHaveLength(4);
    const newRegion = result.find((r) => r.id === -1);
    expect(newRegion?.name).toBe('New Section');
    expect(newRegion?._isNew).toBe(true);
  });

  it('sorts regions by start time', () => {
    const pendingChanges: PendingChangesRecord = {
      1: {
        originalIdx: 1,
        originalStart: 0,
        originalEnd: 10,
        newStart: 25, // Move first region to middle
        newEnd: 30,
        name: 'Verse',
      },
    };

    const result = computeDisplayRegions(baseRegions, pendingChanges);

    // Should be sorted: Chorus (10-20), Bridge (20-25), Verse (25-30)
    expect(result[0].name).toBe('Chorus');
    expect(result[1].name).toBe('Bridge');
    expect(result[2].name).toBe('Verse');
  });
});

describe('computeDragPreview', () => {
  const baseRegions: Region[] = [
    { id: 1, name: 'Verse', start: 0, end: 10 },
    { id: 2, name: 'Chorus', start: 10, end: 20 },
    { id: 3, name: 'Bridge', start: 20, end: 30 },
  ];

  it('returns display regions when not dragging', () => {
    const result = computeDragPreview(
      baseRegions,
      {},
      { dragType: 'none', dragRegionId: null, dragStartTime: null, dragCurrentTime: null },
      120,
      4
    );

    expect(result.regions).toHaveLength(3);
    expect(result.insertionPoint).toBeNull();
    expect(result.resizeEdgePosition).toBeNull();
  });

  it('returns display regions when drag delta is negligible', () => {
    const result = computeDragPreview(
      baseRegions,
      {},
      { dragType: 'move', dragRegionId: 2, dragStartTime: 10, dragCurrentTime: 10.005 },
      120,
      4
    );

    // Delta < 0.01 should return unchanged
    expect(result.insertionPoint).toBeNull();
    expect(result.resizeEdgePosition).toBeNull();
  });

  it('computes resize preview with edge position', () => {
    const result = computeDragPreview(
      baseRegions,
      {},
      { dragType: 'resize-end', dragRegionId: 1, dragStartTime: 10, dragCurrentTime: 15 },
      120,
      4
    );

    // Should have computed preview regions
    expect(result.regions).toBeDefined();
    // Resize operations should set resizeEdgePosition
    expect(result.resizeEdgePosition).toBeDefined();
  });

  it('computes move preview with insertion point', () => {
    const result = computeDragPreview(
      baseRegions,
      {},
      { dragType: 'move', dragRegionId: 1, dragStartTime: 5, dragCurrentTime: 25 },
      120,
      4
    );

    // Move operations should set insertionPoint
    expect(result.insertionPoint).toBeDefined();
  });
});
