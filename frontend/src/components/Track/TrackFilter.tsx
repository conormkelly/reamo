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
  /** Hide the inline count display (useful when count is shown elsewhere) */
  hideCount?: boolean;
}

export function TrackFilter({
  value,
  onChange,
  className = '',
  placeholder = 'Filter tracks...',
  matchCount,
  totalCount,
  hideCount = false,
}: TrackFilterProps): ReactElement {
  const handleChange = (e: ChangeEvent<HTMLInputElement>) => {
    onChange(e.target.value);
  };

  const handleClear = () => {
    onChange('');
  };

  // Show count if totalCount is provided and not explicitly hidden
  const showCount = !hideCount && totalCount !== undefined && totalCount > 0;
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
        className="absolute left-3 top-1/2 -translate-y-1/2 text-text-muted"
      />
      <input
        type="text"
        value={value}
        onChange={handleChange}
        placeholder={placeholder}
        className={`w-full pl-9 py-2 bg-bg-surface border border-border-subtle rounded text-base text-text-primary placeholder-text-muted focus:outline-none focus:border-border-default ${
          value ? 'pr-16' : showCount ? 'pr-12' : 'pr-8'
        }`}
      />
      {/* Track count indicator */}
      {showCount && (
        <span
          className={`absolute top-1/2 -translate-y-1/2 text-text-muted text-sm font-mono ${
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
          className="absolute right-2 top-1/2 -translate-y-1/2 text-text-muted hover:text-text-tertiary"
          title="Clear filter"
        >
          <X size={16} />
        </button>
      )}
    </div>
  );
}
