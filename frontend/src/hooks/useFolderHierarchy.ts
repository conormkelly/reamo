/**
 * Folder Hierarchy Hook
 * React hook for accessing computed folder hierarchy from track skeleton
 */

import { useMemo, useCallback } from 'react';
import { useReaperStore } from '../store';
import {
  buildFolderHierarchy,
  getChildIndices,
  getAncestorPath,
  getSiblingFolders,
  validateFolderPath,
  EMPTY_HIERARCHY,
  type FolderNode,
  type FolderHierarchy,
} from '../utils/folderHierarchy';

export interface UseFolderHierarchyReturn {
  /** Complete folder hierarchy */
  hierarchy: FolderHierarchy;

  /** Get child track indices for a folder (null = root level) */
  getChildren: (folderGuid: string | null) => number[];

  /** Get sibling folders at the same level */
  getSiblings: (folderGuid: string) => FolderNode[];

  /** Get ancestor path from root to folder (inclusive) */
  getPath: (folderGuid: string) => FolderNode[];

  /** Validate path and return longest valid prefix */
  validatePath: (folderPath: string[]) => string[];

  /** Check if project has any folders */
  hasFolders: boolean;
}

/**
 * Hook for accessing folder hierarchy computed from track skeleton
 */
export function useFolderHierarchy(): UseFolderHierarchyReturn {
  const skeleton = useReaperStore((state) => state.trackSkeleton);

  // Build hierarchy (memoized - only recomputes when skeleton changes)
  const hierarchy = useMemo(() => {
    if (!skeleton || skeleton.length === 0) return EMPTY_HIERARCHY;
    return buildFolderHierarchy(skeleton);
  }, [skeleton]);

  // Memoized helper functions
  const getChildren = useCallback(
    (folderGuid: string | null) => getChildIndices(hierarchy, folderGuid),
    [hierarchy]
  );

  const getSiblings = useCallback(
    (folderGuid: string) => getSiblingFolders(hierarchy, folderGuid),
    [hierarchy]
  );

  const getPath = useCallback(
    (folderGuid: string) => getAncestorPath(hierarchy, folderGuid),
    [hierarchy]
  );

  const validatePathFn = useCallback(
    (folderPath: string[]) => validateFolderPath(hierarchy, folderPath),
    [hierarchy]
  );

  const hasFolders = hierarchy.rootFolders.length > 0;

  return {
    hierarchy,
    getChildren,
    getSiblings,
    getPath,
    validatePath: validatePathFn,
    hasFolders,
  };
}
