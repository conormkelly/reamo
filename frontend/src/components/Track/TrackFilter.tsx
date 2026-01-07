/**
 * Track Filter Component
 * Search input to filter tracks by name
 */

import type { ReactElement, ChangeEvent } from 'react';
import { Search, X } from 'lucide-react';

export interface TrackFilterProps {
  value: string;
  onChange: (value: string) => void;
  className?: string;
  placeholder?: string;
  /** Number of tracks matching the current filter (optional) */
  matchCount?: number;
  /** Total number of tracks (optional) */
  totalCount?: number;
}

export function TrackFilter({
  value,
  onChange,
  className = '',
  placeholder = 'Filter tracks...',
  matchCount,
  totalCount,
}: TrackFilterProps): ReactElement {
  const handleChange = (e: ChangeEvent<HTMLInputElement>) => {
    onChange(e.target.value);
  };

  const handleClear = () => {
    onChange('');
  };

  // Show count if totalCount is provided
  const showCount = totalCount !== undefined && totalCount > 0;
  // When filtering, show match/total; otherwise just show total
  const countText = showCount
    ? value.trim()
      ? `${matchCount ?? 0}/${totalCount}`
      : `${totalCount}`
    : '';

  return (
    <div className={`relative ${className}`}>
      <Search
        size={16}
        className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500"
      />
      <input
        type="text"
        value={value}
        onChange={handleChange}
        placeholder={placeholder}
        className={`w-full pl-9 py-2 bg-gray-800 border border-gray-700 rounded text-base text-white placeholder-gray-500 focus:outline-none focus:border-gray-500 ${
          value ? 'pr-16' : showCount ? 'pr-12' : 'pr-8'
        }`}
      />
      {/* Track count indicator */}
      {showCount && (
        <span
          className={`absolute top-1/2 -translate-y-1/2 text-gray-500 text-sm font-mono ${
            value ? 'right-8' : 'right-3'
          }`}
        >
          {countText}
        </span>
      )}
      {/* Clear button */}
      {value && (
        <button
          onClick={handleClear}
          className="absolute right-2 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-300"
          title="Clear filter"
        >
          <X size={16} />
        </button>
      )}
    </div>
  );
}
