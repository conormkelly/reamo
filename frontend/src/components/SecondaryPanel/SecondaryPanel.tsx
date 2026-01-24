/**
 * SecondaryPanel - Collapsible tabbed panel for secondary controls
 *
 * Consolidates info bars, toolbars, and navigation controls into a single
 * tabbed panel that can collapse to icons only, maximizing primary content area.
 *
 * Features:
 * - Collapsible: 44px collapsed (icons only), ~140px expanded
 * - Tabbed navigation with badge indicators
 * - Inline bank navigation in header (always visible)
 * - Expandable search in header (collapses to icon)
 * - Content kept mounted (hidden via CSS) to preserve state
 * - Per-view state persisted to localStorage
 * - Accessible with proper ARIA roles
 */

import { type ReactNode, useId, useEffect, useState, useCallback } from 'react';
import { ChevronUp, ChevronDown, ChevronLeft, ChevronRight, type LucideIcon } from 'lucide-react';
import { SecondaryPanelTab } from './SecondaryPanelTab';
import { ExpandableSearch } from './ExpandableSearch';
import { useReaperStore } from '../../store';

/** Height constants */
const COLLAPSED_HEIGHT = 44;
const EXPANDED_HEIGHT = 140;
const CONTENT_HEIGHT = EXPANDED_HEIGHT - COLLAPSED_HEIGHT; // 96px

export interface SecondaryPanelTabConfig {
  /** Unique tab identifier */
  id: string;
  /** Lucide icon component */
  icon: LucideIcon;
  /** Accessibility label */
  label: string;
  /** Badge indicator: 'dot' for boolean, number for count */
  badge?: 'dot' | number | null;
  /** Tab content (kept mounted, hidden when inactive) */
  content: ReactNode;
}

/** Bank navigation props for the header */
export interface BankNavProps {
  /** Display text like "7-8 / 12" */
  bankDisplay: string;
  /** Compact display (e.g., just "12") shown when search is expanded */
  compactDisplay?: string;
  /** Whether back button is enabled */
  canGoBack: boolean;
  /** Whether forward button is enabled */
  canGoForward: boolean;
  /** Called when back is pressed */
  onBack: () => void;
  /** Called when forward is pressed */
  onForward: () => void;
  /** Called when bank display is held (for showing track labels) */
  onHoldStart?: () => void;
  /** Called when hold ends */
  onHoldEnd?: () => void;
}

/** Search/filter props for the header */
export interface SearchProps {
  /** Current search value */
  value: string;
  /** Called when value changes */
  onChange: (value: string) => void;
  /** Placeholder text */
  placeholder?: string;
}

export interface SecondaryPanelProps {
  /** View identifier for state persistence */
  viewId: 'timeline' | 'mixer';
  /** Tab configurations */
  tabs: SecondaryPanelTabConfig[];
  /** Bank navigation in header (optional) */
  bankNav?: BankNavProps;
  /** Search/filter in header (optional) */
  search?: SearchProps;
  /** Additional CSS classes */
  className?: string;
}

export function SecondaryPanel({ viewId, tabs, bankNav, search, className = '' }: SecondaryPanelProps) {
  // Generate unique IDs for ARIA
  const baseId = useId();

  // Track search expanded state to hide nav arrows
  const [searchExpanded, setSearchExpanded] = useState(false);
  const handleSearchExpandedChange = useCallback((expanded: boolean) => {
    setSearchExpanded(expanded);
  }, []);

  // Get panel state from store
  const expanded = useReaperStore((s) => s.secondaryPanelExpanded[viewId]);
  const activeTab = useReaperStore((s) => s.secondaryPanelActiveTab[viewId]);
  const setExpanded = useReaperStore((s) => s.setSecondaryPanelExpanded);
  const setActiveTab = useReaperStore((s) => s.setSecondaryPanelActiveTab);
  const loadFromStorage = useReaperStore((s) => s.loadSecondaryPanelFromStorage);

  // Load persisted state on mount
  useEffect(() => {
    loadFromStorage();
  }, [loadFromStorage]);

  // Ensure activeTab is valid, fall back to first tab
  const validActiveTab = tabs.find((t) => t.id === activeTab)?.id ?? tabs[0]?.id ?? '';

  const handleToggleExpanded = () => {
    setExpanded(viewId, !expanded);
  };

  const handleTabClick = (tabId: string) => {
    if (tabId !== validActiveTab) {
      setActiveTab(viewId, tabId);
    }
    // If clicking current tab while collapsed, expand
    if (!expanded) {
      setExpanded(viewId, true);
    }
  };

  return (
    <div
      className={`border-t border-border-subtle bg-bg-app safe-area-bottom transition-[height] duration-200 ease-out ${className}`}
      style={{ height: expanded ? EXPANDED_HEIGHT : COLLAPSED_HEIGHT }}
    >
      {/* Tab bar - always visible */}
      <div
        role="tablist"
        aria-label={`${viewId} secondary panel tabs`}
        className="h-[44px] flex items-center px-2 pt-1 gap-1"
      >
        {/* Tab buttons */}
        {tabs.map((tab) => (
          <SecondaryPanelTab
            key={tab.id}
            tabId={`${baseId}-tab-${tab.id}`}
            panelId={`${baseId}-panel-${tab.id}`}
            icon={tab.icon}
            label={tab.label}
            isActive={tab.id === validActiveTab}
            badge={tab.badge}
            onClick={() => handleTabClick(tab.id)}
          />
        ))}

        {/* Search (expandable) */}
        {search && (
          <ExpandableSearch
            value={search.value}
            onChange={search.onChange}
            placeholder={search.placeholder}
            onExpandedChange={handleSearchExpandedChange}
          />
        )}

        {/* Spacer */}
        <div className="flex-1" />

        {/* Bank navigation (arrows hidden when search is expanded) */}
        {bankNav && (
          <div className="flex items-center gap-1">
            {!searchExpanded && (
              <button
                onClick={bankNav.onBack}
                disabled={!bankNav.canGoBack}
                className="w-9 h-9 flex items-center justify-center rounded-lg bg-bg-surface border border-border-subtle disabled:opacity-30 disabled:cursor-not-allowed hover:bg-bg-hover active:bg-bg-elevated transition-colors"
                aria-label="Previous bank"
              >
                <ChevronLeft size={18} />
              </button>
            )}
            <button
              onPointerDown={bankNav.onHoldStart}
              onPointerUp={bankNav.onHoldEnd}
              onPointerLeave={bankNav.onHoldEnd}
              onPointerCancel={bankNav.onHoldEnd}
              className="min-w-[48px] h-9 px-2 flex items-center justify-center rounded-lg bg-bg-surface border border-border-subtle text-xs font-mono text-text-secondary hover:bg-bg-hover active:bg-bg-elevated transition-colors"
              aria-label={`Bank ${bankNav.bankDisplay}`}
            >
              {searchExpanded && bankNav.compactDisplay ? bankNav.compactDisplay : bankNav.bankDisplay}
            </button>
            {!searchExpanded && (
              <button
                onClick={bankNav.onForward}
                disabled={!bankNav.canGoForward}
                className="w-9 h-9 flex items-center justify-center rounded-lg bg-bg-surface border border-border-subtle disabled:opacity-30 disabled:cursor-not-allowed hover:bg-bg-hover active:bg-bg-elevated transition-colors"
                aria-label="Next bank"
              >
                <ChevronRight size={18} />
              </button>
            )}
          </div>
        )}

        {/* Expand/Collapse button */}
        <button
          onClick={handleToggleExpanded}
          aria-expanded={expanded}
          aria-label={expanded ? 'Collapse panel' : 'Expand panel'}
          className="w-10 h-10 flex items-center justify-center text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-bg-hover"
        >
          {expanded ? <ChevronDown size={20} /> : <ChevronUp size={20} />}
        </button>
      </div>

      {/* Content area - all tabs mounted, visibility controlled via CSS */}
      <div
        className="overflow-hidden transition-opacity duration-150 ease-out"
        style={{
          height: CONTENT_HEIGHT,
          opacity: expanded ? 1 : 0,
          pointerEvents: expanded ? 'auto' : 'none',
        }}
      >
        {tabs.map((tab) => (
          <div
            key={tab.id}
            id={`${baseId}-panel-${tab.id}`}
            role="tabpanel"
            aria-labelledby={`${baseId}-tab-${tab.id}`}
            hidden={tab.id !== validActiveTab}
            className="h-full overflow-y-auto overscroll-contain pt-1 pb-2"
          >
            {tab.content}
          </div>
        ))}
      </div>
    </div>
  );
}
