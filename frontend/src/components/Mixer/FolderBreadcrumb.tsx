/**
 * FolderBreadcrumb Component
 * Breadcrumb navigation for drilling into folder contents
 * Horizontally scrollable with gradient fades
 *
 * Dropdowns render via portal to document.body to escape stacking contexts.
 */

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { createPortal } from 'react-dom';
import { Folder, FolderOpen, ChevronRight, ChevronDown } from 'lucide-react';
import { usePortalPosition } from '../../hooks/usePortalPosition';
import { useFolderHierarchy } from '../../hooks/useFolderHierarchy';
import type { FolderNode } from '../../utils/folderHierarchy';

export interface FolderBreadcrumbProps {
  /** Current folder path (array of GUIDs from root to current) */
  folderPath: string[];
  /** Callback when user navigates to a new path */
  onNavigate: (newPath: string[]) => void;
  className?: string;
}

/** Single breadcrumb segment with dropdown */
interface BreadcrumbSegmentProps {
  folder: FolderNode | null; // null for "All Folders" root
  isLast: boolean;
  siblings: FolderNode[];
  onSelect: (folder: FolderNode | null) => void;
}

function BreadcrumbSegment({ folder, isLast, siblings, onSelect }: BreadcrumbSegmentProps): ReactElement {
  const [isOpen, setIsOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const { position } = usePortalPosition(triggerRef, isOpen, { placement: 'bottom-start', offset: 4 });

  // Close dropdown on outside click
  useEffect(() => {
    if (!isOpen) return;

    function handleClickOutside(e: MouseEvent) {
      const target = e.target as Node;
      const clickedTrigger = triggerRef.current?.contains(target);
      const clickedMenu = menuRef.current?.contains(target);
      if (!clickedTrigger && !clickedMenu) {
        setIsOpen(false);
      }
    }

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [isOpen]);

  const Icon = isLast ? FolderOpen : Folder;
  const label = folder?.name ?? 'All Folders';
  const hasDropdown = siblings.length > 1 || folder === null;

  return (
    <div className="relative flex-shrink-0">
      <button
        ref={triggerRef}
        onClick={() => hasDropdown && setIsOpen(!isOpen)}
        className={`
          flex items-center gap-1.5 px-2 py-1.5 rounded-md transition-colors min-h-[36px]
          ${isLast ? 'text-text-primary bg-bg-elevated' : 'text-text-secondary hover:text-text-primary hover:bg-bg-surface'}
          ${hasDropdown ? 'cursor-pointer' : 'cursor-default'}
        `}
        aria-expanded={hasDropdown ? isOpen : undefined}
        aria-haspopup={hasDropdown ? 'listbox' : undefined}
      >
        <Icon size={16} className="flex-shrink-0" />
        <span className="text-sm font-medium whitespace-nowrap">{label}</span>
        {hasDropdown && <ChevronDown size={14} className={`flex-shrink-0 transition-transform ${isOpen ? 'rotate-180' : ''}`} />}
      </button>

      {/* Dropdown menu - portaled to body */}
      {isOpen && createPortal(
        <div
          ref={menuRef}
          className="fixed min-w-[160px] max-w-[240px] bg-bg-surface rounded-lg shadow-xl border border-border-subtle py-1 z-dropdown"
          style={{ top: position.top, left: position.left }}
          role="listbox"
        >
          {folder === null ? (
            // Root dropdown: show all root folders
            siblings.map((f) => (
              <button
                key={f.guid}
                onClick={() => {
                  onSelect(f);
                  setIsOpen(false);
                }}
                className="w-full px-3 py-2 flex items-center gap-2 hover:bg-bg-elevated/50 transition-colors text-left"
                role="option"
              >
                <Folder size={14} className="flex-shrink-0 text-text-muted" />
                <span className="text-sm truncate">{f.name}</span>
              </button>
            ))
          ) : (
            // Sibling dropdown
            siblings.map((f) => (
              <button
                key={f.guid}
                onClick={() => {
                  onSelect(f);
                  setIsOpen(false);
                }}
                className={`
                  w-full px-3 py-2 flex items-center gap-2 hover:bg-bg-elevated/50 transition-colors text-left
                  ${f.guid === folder.guid ? 'bg-bg-elevated/30' : ''}
                `}
                role="option"
                aria-selected={f.guid === folder.guid}
              >
                <Folder size={14} className="flex-shrink-0 text-text-muted" />
                <span className="text-sm truncate">{f.name}</span>
                {f.guid === folder.guid && <span className="ml-auto text-xs text-text-muted">current</span>}
              </button>
            ))
          )}
        </div>,
        document.body
      )}
    </div>
  );
}

export function FolderBreadcrumb({ folderPath, onNavigate, className = '' }: FolderBreadcrumbProps): ReactElement {
  const { hierarchy, getSiblings, getPath } = useFolderHierarchy();
  const scrollRef = useRef<HTMLDivElement>(null);
  const [showLeftFade, setShowLeftFade] = useState(false);
  const [showRightFade, setShowRightFade] = useState(false);

  // Update fade indicators on scroll/resize
  const updateFades = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return;

    const { scrollLeft, scrollWidth, clientWidth } = el;
    setShowLeftFade(scrollLeft > 4);
    setShowRightFade(scrollLeft < scrollWidth - clientWidth - 4);
  }, []);

  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;

    updateFades();
    el.addEventListener('scroll', updateFades, { passive: true });
    window.addEventListener('resize', updateFades);

    return () => {
      el.removeEventListener('scroll', updateFades);
      window.removeEventListener('resize', updateFades);
    };
  }, [updateFades]);

  // Build breadcrumb segments from path
  const currentGuid = folderPath.length > 0 ? folderPath[folderPath.length - 1] : null;
  const pathNodes = currentGuid ? getPath(currentGuid) : [];

  // Handle selecting a folder from dropdown
  const handleSelectFolder = (depth: number, folder: FolderNode | null) => {
    if (folder === null) {
      // Clicked "All Folders" without selecting a subfolder - go to root
      onNavigate([]);
    } else {
      // Navigate to this folder
      // Build new path up to this depth, then add the selected folder
      const newPath = folderPath.slice(0, depth);
      newPath.push(folder.guid);
      onNavigate(newPath);
    }
  };

  return (
    <div className={`relative bg-bg-deep/50 border-b border-border-subtle ${className}`}>
      {/* Left fade */}
      {showLeftFade && (
        <div className="absolute left-0 top-0 bottom-0 w-6 bg-gradient-to-r from-bg-deep to-transparent pointer-events-none z-10" />
      )}

      {/* Scrollable breadcrumb container */}
      <div ref={scrollRef} className="flex items-center gap-1 px-2 py-1.5 overflow-x-auto scrollbar-hide">
        {/* Root segment: "All Folders" */}
        <BreadcrumbSegment
          folder={null}
          isLast={folderPath.length === 0}
          siblings={hierarchy.rootFolders}
          onSelect={(f) => handleSelectFolder(0, f)}
        />

        {/* Path segments */}
        {pathNodes.map((node, idx) => {
          const siblings = getSiblings(node.guid);
          const isLast = idx === pathNodes.length - 1;

          return (
            <div key={node.guid} className="flex items-center gap-1 flex-shrink-0">
              <ChevronRight size={14} className="text-text-muted flex-shrink-0" />
              <BreadcrumbSegment
                folder={node}
                isLast={isLast}
                siblings={siblings}
                onSelect={(f) => handleSelectFolder(idx + 1, f)}
              />
            </div>
          );
        })}
      </div>

      {/* Right fade */}
      {showRightFade && (
        <div className="absolute right-0 top-0 bottom-0 w-6 bg-gradient-to-l from-bg-deep to-transparent pointer-events-none z-10" />
      )}
    </div>
  );
}
