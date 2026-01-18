/**
 * Folder Hierarchy Utilities
 * Computes parent-child relationships from flat skeleton array
 */

import type { SkeletonTrack } from '../core/WebSocketTypes';

/** Folder node in computed hierarchy */
export interface FolderNode {
  guid: string;
  name: string;
  index: number;
  parentGuid: string | null;
  childFolders: FolderNode[];
  childIndices: number[]; // All direct children (tracks + folders)
}

/** Complete folder hierarchy */
export interface FolderHierarchy {
  rootFolders: FolderNode[];
  folderMap: Map<string, FolderNode>;
}

/** Empty hierarchy constant for stable reference */
export const EMPTY_HIERARCHY: FolderHierarchy = {
  rootFolders: [],
  folderMap: new Map(),
};

/**
 * Build folder hierarchy from flat skeleton array
 * Walks the skeleton tracking depth via fd values
 */
export function buildFolderHierarchy(skeleton: SkeletonTrack[]): FolderHierarchy {
  if (skeleton.length === 0) return EMPTY_HIERARCHY;

  const rootFolders: FolderNode[] = [];
  const folderMap = new Map<string, FolderNode>();
  const folderStack: FolderNode[] = []; // Stack of open folders

  // Skip master track (index 0), process user tracks
  for (let i = 1; i < skeleton.length; i++) {
    const track = skeleton[i];
    const fd = track.fd;

    // Determine parent folder BEFORE any closures
    const parentFolder = folderStack.length > 0 ? folderStack[folderStack.length - 1] : null;

    // Add this track as a child of current parent (including folder close tracks)
    if (parentFolder) {
      parentFolder.childIndices.push(i);
    }

    // Close folders AFTER adding to childIndices (fd < 0 means close |fd| folders)
    if (fd < 0) {
      const closures = Math.abs(fd);
      for (let j = 0; j < closures && folderStack.length > 0; j++) {
        folderStack.pop();
      }
    }

    // If this is a folder, create node and push to stack
    if (fd === 1) {
      const node: FolderNode = {
        guid: track.g,
        name: track.n,
        index: i,
        parentGuid: parentFolder?.guid ?? null,
        childFolders: [],
        childIndices: [],
      };

      folderMap.set(track.g, node);

      if (parentFolder) {
        parentFolder.childFolders.push(node);
      } else {
        rootFolders.push(node);
      }

      folderStack.push(node);
    }
  }

  return { rootFolders, folderMap };
}

/**
 * Get indices of direct children for a folder
 * Pass null to get root-level tracks (tracks not in any folder)
 */
export function getChildIndices(
  hierarchy: FolderHierarchy,
  folderGuid: string | null
): number[] {
  if (folderGuid === null) {
    // Root level - return indices of root folders
    return hierarchy.rootFolders.map((f) => f.index);
  }

  const folder = hierarchy.folderMap.get(folderGuid);
  return folder?.childIndices ?? [];
}

/**
 * Get ancestor path from root to the given folder (inclusive)
 */
export function getAncestorPath(
  hierarchy: FolderHierarchy,
  folderGuid: string
): FolderNode[] {
  const path: FolderNode[] = [];
  let current = hierarchy.folderMap.get(folderGuid);

  while (current) {
    path.unshift(current);
    current = current.parentGuid ? hierarchy.folderMap.get(current.parentGuid) : undefined;
  }

  return path;
}

/**
 * Get sibling folders at the same level
 */
export function getSiblingFolders(
  hierarchy: FolderHierarchy,
  folderGuid: string
): FolderNode[] {
  const folder = hierarchy.folderMap.get(folderGuid);
  if (!folder) return [];

  if (folder.parentGuid === null) {
    // Root level - siblings are other root folders
    return hierarchy.rootFolders;
  }

  const parent = hierarchy.folderMap.get(folder.parentGuid);
  return parent?.childFolders ?? [];
}

/**
 * Validate a folder path against current hierarchy
 * Returns the longest valid prefix of the path
 */
export function validateFolderPath(
  hierarchy: FolderHierarchy,
  folderPath: string[]
): string[] {
  const validPath: string[] = [];

  for (const guid of folderPath) {
    if (hierarchy.folderMap.has(guid)) {
      validPath.push(guid);
    } else {
      break; // Stop at first invalid folder
    }
  }

  return validPath;
}
