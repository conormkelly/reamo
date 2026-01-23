/**
 * QuickFilterDropdown - Dropdown to filter tracks by state
 * Filters: Muted, Soloed, Armed, Selected, With Sends
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { Filter, X } from 'lucide-react';
import { QUICK_FILTERS, type BuiltinBankId } from './BankSelector';
import type { SkeletonTrack } from '../../core/WebSocketTypes';

export interface QuickFilterDropdownProps {
  /** Currently selected filter ID (null = no filter) */
  selectedFilterId: BuiltinBankId | null;
  /** Track skeleton for computing filter counts */
  skeleton: SkeletonTrack[];
  /** Callback when filter selection changes */
  onFilterChange: (filterId: BuiltinBankId | null) => void;
  className?: string;
}

/** Count tracks matching a filter (excludes master at index 0) */
function countTracksForFilter(skeleton: SkeletonTrack[], filterId: BuiltinBankId): number {
  const userTracks = skeleton.slice(1);
  switch (filterId) {
    case 'builtin:muted':
      return userTracks.filter((t) => t.m === true).length;
    case 'builtin:soloed':
      return userTracks.filter((t) => t.sl !== null && t.sl !== 0).length;
    case 'builtin:armed':
      return userTracks.filter((t) => t.r === true).length;
    case 'builtin:selected':
      return userTracks.filter((t) => t.sel === true).length;
    case 'builtin:with-sends':
      return userTracks.filter((t) => t.sc > 0).length;
    case 'builtin:clipped':
      return userTracks.filter((t) => t.cl === true).length;
    case 'builtin:with-items':
      return userTracks.filter((t) => t.ic > 0).length;
    default:
      return 0;
  }
}

export function QuickFilterDropdown({
  selectedFilterId,
  skeleton,
  onFilterChange,
  className = '',
}: QuickFilterDropdownProps): ReactElement {
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  // Close dropdown when clicking outside
  useEffect(() => {
    if (!isOpen) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [isOpen]);

  // Check if filter is a quick filter (not folders bank)
  const isQuickFilter = selectedFilterId !== null && selectedFilterId !== 'builtin:folders';
  const selectedFilter = isQuickFilter
    ? QUICK_FILTERS.find((f) => f.id === selectedFilterId)
    : null;

  const handleFilterSelect = (filterId: BuiltinBankId) => {
    onFilterChange(filterId);
    setIsOpen(false);
  };

  const handleClearFilter = (e: React.MouseEvent) => {
    e.stopPropagation();
    onFilterChange(null);
  };

  return (
    <div ref={dropdownRef} className={`relative ${className}`}>
      {/* Filter button - compact: just icon, or icon + X when active */}
      <div className="flex items-center">
        <button
          onClick={() => setIsOpen(!isOpen)}
          className={`p-2 rounded-l transition-colors ${
            isQuickFilter
              ? 'bg-sends-muted/20 text-sends-muted'
              : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
          } ${isQuickFilter ? '' : 'rounded-r'}`}
          title={isQuickFilter ? `Filter: ${selectedFilter?.name}` : 'Quick filters'}
        >
          <Filter size={18} />
        </button>
        {isQuickFilter && (
          <button
            onClick={handleClearFilter}
            className="p-2 rounded-r bg-sends-muted/20 text-sends-muted hover:bg-sends-muted/30 transition-colors"
            title="Clear filter"
          >
            <X size={18} />
          </button>
        )}
      </div>

      {/* Dropdown menu */}
      {isOpen && (
        <div className="absolute right-0 top-full mt-1 w-48 bg-bg-elevated border border-border-subtle rounded-lg shadow-lg z-dropdown overflow-hidden">
          <div className="py-1">
            {QUICK_FILTERS.map((filter) => {
              const count = countTracksForFilter(skeleton, filter.id);
              const isSelected = selectedFilterId === filter.id;

              return (
                <button
                  key={filter.id}
                  onClick={() => handleFilterSelect(filter.id)}
                  className={`w-full flex items-center justify-between px-3 py-2 text-sm transition-colors ${
                    isSelected
                      ? 'bg-sends-muted/20 text-sends-muted'
                      : 'text-text-primary hover:bg-bg-surface'
                  }`}
                >
                  <span>{filter.name}</span>
                  <span className={`text-xs ${isSelected ? 'text-sends-muted' : 'text-text-muted'}`}>
                    {count}
                  </span>
                </button>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
