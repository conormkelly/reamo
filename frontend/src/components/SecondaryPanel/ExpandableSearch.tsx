/**
 * ExpandableSearch - Collapsible search input for space-constrained headers
 *
 * Shows a search icon that expands into a text input on tap.
 * Collapses back to icon when empty and blurred.
 * Shows a badge dot when collapsed but has active filter text.
 */

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { Search, X } from 'lucide-react';

export interface ExpandableSearchProps {
  /** Current search value */
  value: string;
  /** Called when value changes */
  onChange: (value: string) => void;
  /** Placeholder text when expanded */
  placeholder?: string;
  /** Called when expanded state changes */
  onExpandedChange?: (expanded: boolean) => void;
  /** Additional CSS classes */
  className?: string;
}

export function ExpandableSearch({
  value,
  onChange,
  placeholder = 'Filter...',
  onExpandedChange,
  className = '',
}: ExpandableSearchProps): ReactElement {
  const [isExpanded, setIsExpanded] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  // Auto-focus when expanding
  useEffect(() => {
    if (isExpanded && inputRef.current) {
      inputRef.current.focus();
    }
  }, [isExpanded]);

  // Notify parent of expanded state changes
  useEffect(() => {
    onExpandedChange?.(isExpanded);
  }, [isExpanded, onExpandedChange]);

  // Handle icon click - expand and focus
  const handleIconClick = useCallback(() => {
    setIsExpanded(true);
  }, []);

  // Handle blur - always collapse to restore bank nav controls
  const handleBlur = useCallback(() => {
    setIsExpanded(false);
  }, []);

  // Handle clear - clear value and collapse
  const handleClear = useCallback(() => {
    onChange('');
    setIsExpanded(false);
  }, [onChange]);

  // Handle key down - Escape to clear and collapse
  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      onChange('');
      setIsExpanded(false);
    }
  }, [onChange]);

  const hasValue = value.trim().length > 0;

  // Collapsed state - just the icon with optional badge
  if (!isExpanded) {
    return (
      <button
        onClick={handleIconClick}
        className={`relative w-10 h-10 flex items-center justify-center rounded-lg transition-colors ${
          hasValue
            ? 'bg-primary text-on-primary'
            : 'text-text-muted hover:text-text-primary hover:bg-bg-hover'
        } ${className}`}
        aria-label={hasValue ? `Filter active: ${value}` : 'Open search filter'}
        title={hasValue ? `Filter: "${value}"` : 'Search / Filter'}
      >
        <Search size={20} />
        {/* Badge dot when has value */}
        {hasValue && (
          <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 bg-warning rounded-full border-2 border-bg-app" />
        )}
      </button>
    );
  }

  // Expanded state - text input with clear button
  return (
    <div className={`flex items-center gap-1 max-w-[50%] ml-1 ${className}`}>
      <div className="relative w-full min-w-0">
        <Search
          size={16}
          className="absolute left-2 top-1/2 -translate-y-1/2 text-text-muted pointer-events-none"
        />
        <input
          ref={inputRef}
          type="text"
          name="mediaTrackFilter"
          id="mediaTrackFilter"
          autoComplete="off"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onBlur={handleBlur}
          onKeyDown={handleKeyDown}
          placeholder={placeholder}
          className="w-full h-9 pl-8 pr-8 rounded-lg bg-bg-surface border border-border-subtle text-base text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-control-ring"
        />
        {hasValue && (
          <button
            onMouseDown={(e) => {
              e.preventDefault(); // Prevent blur before click
              handleClear();
            }}
            className="absolute right-2 top-1/2 -translate-y-1/2 text-text-muted hover:text-text-primary"
            aria-label="Clear search"
          >
            <X size={16} />
          </button>
        )}
      </div>
    </div>
  );
}
