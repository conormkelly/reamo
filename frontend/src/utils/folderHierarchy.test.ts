/**
 * Tests for folder hierarchy utilities
 */

import { describe, it, expect } from 'vitest';
import type { SkeletonTrack } from '../core/WebSocketTypes';
import {
  buildFolderHierarchy,
  getChildIndices,
  getAncestorPath,
  getSiblingFolders,
  validateFolderPath,
  EMPTY_HIERARCHY,
} from './folderHierarchy';

/** Helper to create a skeleton track */
function track(
  index: number,
  name: string,
  fd: number,
  guid?: string
): SkeletonTrack {
  return {
    n: name,
    g: guid ?? `guid-${index}`,
    m: false,
    sl: null,
    sel: false,
    r: false,
    fd,
    sc: 0,
    hc: 0,
    cl: false,
    ic: 0,
  };
}

describe('buildFolderHierarchy', () => {
  it('returns empty hierarchy for empty skeleton', () => {
    const result = buildFolderHierarchy([]);
    expect(result).toBe(EMPTY_HIERARCHY);
  });

  it('returns empty hierarchy for skeleton with only master track', () => {
    const skeleton = [track(0, 'MASTER', 0)];
    const result = buildFolderHierarchy(skeleton);
    expect(result.rootFolders).toHaveLength(0);
    expect(result.folderMap.size).toBe(0);
  });

  it('handles flat project with no folders', () => {
    const skeleton = [
      track(0, 'MASTER', 0),
      track(1, 'Track 1', 0),
      track(2, 'Track 2', 0),
      track(3, 'Track 3', 0),
    ];
    const result = buildFolderHierarchy(skeleton);
    expect(result.rootFolders).toHaveLength(0);
    expect(result.folderMap.size).toBe(0);
  });

  it('builds hierarchy for single folder', () => {
    const skeleton = [
      track(0, 'MASTER', 0),
      track(1, 'Drums', 1, 'drums-guid'),
      track(2, 'Kick', 0),
      track(3, 'Snare', 0),
      track(4, '', -1), // Folder close
    ];
    const result = buildFolderHierarchy(skeleton);

    expect(result.rootFolders).toHaveLength(1);
    expect(result.rootFolders[0].name).toBe('Drums');
    expect(result.rootFolders[0].guid).toBe('drums-guid');
    expect(result.rootFolders[0].childIndices).toEqual([2, 3, 4]);
    expect(result.folderMap.size).toBe(1);
  });

  it('builds hierarchy for multiple root folders', () => {
    const skeleton = [
      track(0, 'MASTER', 0),
      track(1, 'Drums', 1, 'drums-guid'),
      track(2, 'Kick', 0),
      track(3, '', -1),
      track(4, 'Guitars', 1, 'guitars-guid'),
      track(5, 'Lead', 0),
      track(6, '', -1),
    ];
    const result = buildFolderHierarchy(skeleton);

    expect(result.rootFolders).toHaveLength(2);
    expect(result.rootFolders[0].name).toBe('Drums');
    expect(result.rootFolders[1].name).toBe('Guitars');
    expect(result.folderMap.size).toBe(2);
  });

  it('builds hierarchy for nested folders', () => {
    const skeleton = [
      track(0, 'MASTER', 0),
      track(1, 'Drums', 1, 'drums-guid'),
      track(2, 'Kick', 1, 'kick-guid'), // Nested folder
      track(3, 'Kick In', 0),
      track(4, 'Kick Out', 0),
      track(5, '', -1), // Close Kick folder
      track(6, 'Snare', 0),
      track(7, '', -1), // Close Drums folder
    ];
    const result = buildFolderHierarchy(skeleton);

    expect(result.rootFolders).toHaveLength(1);
    expect(result.rootFolders[0].name).toBe('Drums');
    expect(result.rootFolders[0].childFolders).toHaveLength(1);
    expect(result.rootFolders[0].childFolders[0].name).toBe('Kick');
    expect(result.rootFolders[0].childFolders[0].parentGuid).toBe('drums-guid');

    const kickFolder = result.folderMap.get('kick-guid');
    expect(kickFolder?.childIndices).toEqual([3, 4, 5]);
  });

  it('handles deep nesting with multi-close', () => {
    const skeleton = [
      track(0, 'MASTER', 0),
      track(1, 'Level1', 1, 'l1-guid'),
      track(2, 'Level2', 1, 'l2-guid'),
      track(3, 'Level3', 1, 'l3-guid'),
      track(4, 'Deep Track', 0),
      track(5, '', -3), // Close all 3 levels at once
    ];
    const result = buildFolderHierarchy(skeleton);

    expect(result.rootFolders).toHaveLength(1);
    const l1 = result.folderMap.get('l1-guid');
    const l2 = result.folderMap.get('l2-guid');
    const l3 = result.folderMap.get('l3-guid');

    expect(l1?.childFolders[0].guid).toBe('l2-guid');
    expect(l2?.childFolders[0].guid).toBe('l3-guid');
    expect(l3?.childIndices).toEqual([4, 5]);
    expect(l3?.parentGuid).toBe('l2-guid');
    expect(l2?.parentGuid).toBe('l1-guid');
    expect(l1?.parentGuid).toBeNull();
  });
});

describe('getChildIndices', () => {
  const skeleton = [
    track(0, 'MASTER', 0),
    track(1, 'Drums', 1, 'drums-guid'),
    track(2, 'Kick', 0),
    track(3, 'Snare', 0),
    track(4, '', -1),
    track(5, 'Bass', 0), // Root level track
  ];
  const hierarchy = buildFolderHierarchy(skeleton);

  it('returns child indices for a folder', () => {
    const indices = getChildIndices(hierarchy, 'drums-guid');
    expect(indices).toEqual([2, 3, 4]);
  });

  it('returns root folder indices for null', () => {
    const indices = getChildIndices(hierarchy, null);
    expect(indices).toEqual([1]); // Only the Drums folder at root
  });

  it('returns empty array for unknown folder', () => {
    const indices = getChildIndices(hierarchy, 'unknown-guid');
    expect(indices).toEqual([]);
  });
});

describe('getAncestorPath', () => {
  const skeleton = [
    track(0, 'MASTER', 0),
    track(1, 'Drums', 1, 'drums-guid'),
    track(2, 'Kick', 1, 'kick-guid'),
    track(3, 'Samples', 1, 'samples-guid'),
    track(4, 'Sample 1', 0),
    track(5, '', -3),
  ];
  const hierarchy = buildFolderHierarchy(skeleton);

  it('returns path from root to folder', () => {
    const path = getAncestorPath(hierarchy, 'samples-guid');
    expect(path.map((n) => n.name)).toEqual(['Drums', 'Kick', 'Samples']);
  });

  it('returns single element for root folder', () => {
    const path = getAncestorPath(hierarchy, 'drums-guid');
    expect(path.map((n) => n.name)).toEqual(['Drums']);
  });

  it('returns empty array for unknown folder', () => {
    const path = getAncestorPath(hierarchy, 'unknown-guid');
    expect(path).toEqual([]);
  });
});

describe('getSiblingFolders', () => {
  const skeleton = [
    track(0, 'MASTER', 0),
    track(1, 'Drums', 1, 'drums-guid'),
    track(2, '', -1),
    track(3, 'Guitars', 1, 'guitars-guid'),
    track(4, '', -1),
    track(5, 'Vocals', 1, 'vocals-guid'),
    track(6, '', -1),
  ];
  const hierarchy = buildFolderHierarchy(skeleton);

  it('returns sibling folders at root level', () => {
    const siblings = getSiblingFolders(hierarchy, 'drums-guid');
    expect(siblings.map((n) => n.name)).toEqual(['Drums', 'Guitars', 'Vocals']);
  });

  it('returns sibling folders for nested folder', () => {
    const nestedSkeleton = [
      track(0, 'MASTER', 0),
      track(1, 'Parent', 1, 'parent-guid'),
      track(2, 'Child1', 1, 'child1-guid'),
      track(3, '', -1),
      track(4, 'Child2', 1, 'child2-guid'),
      track(5, '', -2),
    ];
    const nestedHierarchy = buildFolderHierarchy(nestedSkeleton);

    const siblings = getSiblingFolders(nestedHierarchy, 'child1-guid');
    expect(siblings.map((n) => n.name)).toEqual(['Child1', 'Child2']);
  });

  it('returns empty array for unknown folder', () => {
    const siblings = getSiblingFolders(hierarchy, 'unknown-guid');
    expect(siblings).toEqual([]);
  });
});

describe('validateFolderPath', () => {
  const skeleton = [
    track(0, 'MASTER', 0),
    track(1, 'Drums', 1, 'drums-guid'),
    track(2, 'Kick', 1, 'kick-guid'),
    track(3, '', -2),
  ];
  const hierarchy = buildFolderHierarchy(skeleton);

  it('returns valid path unchanged', () => {
    const path = ['drums-guid', 'kick-guid'];
    expect(validateFolderPath(hierarchy, path)).toEqual(path);
  });

  it('returns empty array for empty path', () => {
    expect(validateFolderPath(hierarchy, [])).toEqual([]);
  });

  it('truncates path at first invalid folder', () => {
    const path = ['drums-guid', 'invalid-guid', 'kick-guid'];
    expect(validateFolderPath(hierarchy, path)).toEqual(['drums-guid']);
  });

  it('returns empty for path starting with invalid folder', () => {
    const path = ['invalid-guid', 'drums-guid'];
    expect(validateFolderPath(hierarchy, path)).toEqual([]);
  });
});
