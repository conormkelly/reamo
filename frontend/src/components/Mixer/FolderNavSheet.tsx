/**
 * FolderNavSheet - Bottom sheet for folder navigation
 * Shows breadcrumb, track list, and navigation options
 */

import { useState, useCallback, type ReactElement } from 'react';
import { Folder, FolderOpen, ChevronRight, X } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useFolderHierarchy } from '../../hooks/useFolderHierarchy';
import { useTrackSkeleton } from '../../hooks/useTrackSkeleton';

export interface FolderNavSheetProps {
  isOpen: boolean;
  onClose: () => void;
  /** Current folder path (array of GUIDs from root to current) */
  folderPath: string[];
  /** Callback when user navigates to a new path */
  onNavigate: (newPath: string[]) => void;
  /** Callback when a track is selected */
  onSelectTrack?: (trackIndex: number) => void;
}

/** Track item in the list */
interface TrackListItem {
  index: number;
  name: string;
  guid: string;
  isFolder: boolean;
  childCount?: number;
}

export function FolderNavSheet({
  isOpen,
  onClose,
  folderPath,
  onNavigate,
  onSelectTrack,
}: FolderNavSheetProps): ReactElement {
  const { hierarchy, getChildren, getPath, hasFolders } = useFolderHierarchy();
  const { skeleton } = useTrackSkeleton();
  const [showFoldersOnly, setShowFoldersOnly] = useState(true);

  // Get current folder info
  const currentFolderGuid = folderPath.length > 0 ? folderPath[folderPath.length - 1] : null;
  const pathNodes = currentFolderGuid ? getPath(currentFolderGuid) : [];
  const currentFolder = currentFolderGuid ? hierarchy.folderMap.get(currentFolderGuid) : null;

  // Get tracks to display
  const getTracksToDisplay = useCallback((): TrackListItem[] => {
    const childIndices = getChildren(currentFolderGuid);

    // At root level with no path, show root folders
    if (currentFolderGuid === null) {
      return hierarchy.rootFolders.map((f) => ({
        index: f.index,
        name: f.name,
        guid: f.guid,
        isFolder: true,
        childCount: f.childIndices.length,
      }));
    }

    // Inside a folder - show children
    const items: TrackListItem[] = [];
    for (const idx of childIndices) {
      const track = skeleton[idx];
      if (!track) continue;

      // fd === 1 means folder parent, fd < 0 is a regular track that closes a folder
      const isFolder = track.fd === 1;

      // Skip non-folders if showFoldersOnly is true
      if (showFoldersOnly && !isFolder) continue;

      const folderNode = isFolder ? hierarchy.folderMap.get(track.g) : null;

      items.push({
        index: idx,
        name: track.n || `Track ${idx}`,
        guid: track.g,
        isFolder,
        childCount: folderNode?.childIndices.length,
      });
    }

    return items;
  }, [currentFolderGuid, getChildren, hierarchy, skeleton, showFoldersOnly]);

  const tracks = getTracksToDisplay();

  // Navigate into a folder
  const handleFolderClick = useCallback((folderGuid: string) => {
    onNavigate([...folderPath, folderGuid]);
  }, [folderPath, onNavigate]);

  // Navigate to a specific breadcrumb level
  const handleBreadcrumbClick = useCallback((index: number) => {
    if (index < 0) {
      // "All Folders" clicked
      onNavigate([]);
    } else {
      // Navigate to specific level
      onNavigate(folderPath.slice(0, index + 1));
    }
  }, [folderPath, onNavigate]);

  // Handle track tap
  const handleTrackClick = useCallback((item: TrackListItem) => {
    if (item.isFolder) {
      handleFolderClick(item.guid);
    } else if (onSelectTrack) {
      onSelectTrack(item.index);
      onClose();
    }
  }, [handleFolderClick, onSelectTrack, onClose]);

  return (
    <BottomSheet isOpen={isOpen} onClose={onClose} ariaLabel="Folder navigation">
      <div className="flex flex-col max-h-[70vh]">
        {/* Header */}
        <div className="flex items-center justify-between px-4 pb-2">
          <h2 className="text-lg font-semibold text-text-primary">Folders</h2>
          <button
            onClick={onClose}
            className="p-2 -mr-2 text-text-muted hover:text-text-primary transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Breadcrumb */}
        <div className="flex items-center gap-1 px-4 py-2 bg-bg-surface/50 overflow-x-auto scrollbar-hide">
          <button
            onClick={() => handleBreadcrumbClick(-1)}
            className={`flex items-center gap-1 px-2 py-1 rounded-md transition-colors flex-shrink-0 ${
              folderPath.length === 0
                ? 'text-text-primary bg-bg-elevated'
                : 'text-text-secondary hover:text-text-primary hover:bg-bg-surface'
            }`}
          >
            <Folder size={14} />
            <span className="text-sm">All</span>
          </button>

          {pathNodes.map((node, idx) => (
            <div key={node.guid} className="flex items-center gap-1 flex-shrink-0">
              <ChevronRight size={14} className="text-text-muted" />
              <button
                onClick={() => handleBreadcrumbClick(idx)}
                className={`flex items-center gap-1 px-2 py-1 rounded-md transition-colors ${
                  idx === pathNodes.length - 1
                    ? 'text-text-primary bg-bg-elevated'
                    : 'text-text-secondary hover:text-text-primary hover:bg-bg-surface'
                }`}
              >
                {idx === pathNodes.length - 1 ? <FolderOpen size={14} /> : <Folder size={14} />}
                <span className="text-sm truncate max-w-[100px]">{node.name}</span>
              </button>
            </div>
          ))}
        </div>

        {/* Toggle - only show when inside a folder */}
        {currentFolderGuid && (
          <div className="flex items-center gap-3 px-4 py-2 border-b border-border-subtle">
            <span className="text-sm text-text-secondary">Show:</span>
            <div className="flex gap-1 bg-bg-surface rounded-lg p-0.5">
              <button
                onClick={() => setShowFoldersOnly(true)}
                className={`px-3 py-1 text-sm rounded-md transition-colors ${
                  showFoldersOnly
                    ? 'bg-bg-elevated text-text-primary'
                    : 'text-text-muted hover:text-text-secondary'
                }`}
              >
                Subfolders
              </button>
              <button
                onClick={() => setShowFoldersOnly(false)}
                className={`px-3 py-1 text-sm rounded-md transition-colors ${
                  !showFoldersOnly
                    ? 'bg-bg-elevated text-text-primary'
                    : 'text-text-muted hover:text-text-secondary'
                }`}
              >
                All tracks
              </button>
            </div>
          </div>
        )}

        {/* Track list */}
        <div className="flex-1 overflow-y-auto px-2 py-2 min-h-[200px]">
          {!hasFolders ? (
            <div className="text-center text-text-muted py-8">
              No folders in project
            </div>
          ) : tracks.length === 0 ? (
            <div className="text-center text-text-muted py-8">
              {showFoldersOnly ? 'No subfolders' : 'Empty folder'}
            </div>
          ) : (
            <div className="space-y-1">
              {tracks.map((item) => (
                <button
                  key={item.guid}
                  onClick={() => handleTrackClick(item)}
                  className="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg hover:bg-bg-surface transition-colors text-left"
                >
                  {item.isFolder ? (
                    <Folder size={18} className="text-text-secondary flex-shrink-0" />
                  ) : (
                    <div className="w-[18px] h-[18px] rounded bg-bg-elevated flex-shrink-0" />
                  )}
                  <span className="text-sm text-text-primary truncate flex-1">
                    {item.name}
                  </span>
                  {item.isFolder && item.childCount !== undefined && (
                    <span className="text-xs text-text-muted">
                      {item.childCount} items
                    </span>
                  )}
                  {item.isFolder && (
                    <ChevronRight size={16} className="text-text-muted flex-shrink-0" />
                  )}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Footer with current folder info */}
        {currentFolder && (
          <div className="px-4 py-2 border-t border-border-subtle text-xs text-text-muted">
            {currentFolder.childIndices.length} items in {currentFolder.name}
          </div>
        )}
      </div>
    </BottomSheet>
  );
}
