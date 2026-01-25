/**
 * ContextRail Component
 * Vertical context panel for landscape-constrained viewports (phones in landscape)
 *
 * Contains:
 * - Tab buttons for view-specific panels (Info, Toolbar)
 * - Search button (opens BottomSheet)
 * - Bank navigation (back/forward/display)
 * - Expand button to show content panel
 *
 * Mirrors SecondaryPanel behavior but in vertical orientation.
 * Placed on right side of screen, complementing NavRail on left.
 *
 * @see docs/architecture/RESPONSIVE_FRONTEND_FINAL.md
 */

import { type ReactElement, type ReactNode, useState, useCallback, useId } from 'react';
import { ChevronUp, ChevronDown, ChevronLeft, Search, type LucideIcon } from 'lucide-react';
import { ContextRailTab } from './ContextRailTab';
import { ContextRailPanel } from './ContextRailPanel';
import { BottomSheet } from '../Modal/BottomSheet';

// =============================================================================
// Types
// =============================================================================

export interface ContextRailTabConfig {
  /** Unique tab identifier */
  id: string;
  /** Lucide icon component */
  icon: LucideIcon;
  /** Accessibility label */
  label: string;
  /** Badge indicator: 'dot' for boolean, number for count */
  badge?: 'dot' | number | null;
  /** Tab content (shown in panel when expanded) */
  content: ReactNode;
}

/** Bank navigation props - same shape as SecondaryPanel's BankNavProps */
export interface ContextRailBankNavProps {
  /** Display text like "7-8 / 12" */
  bankDisplay: string;
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

/** Search/filter props */
export interface ContextRailSearchProps {
  /** Current search value */
  value: string;
  /** Called when value changes */
  onChange: (value: string) => void;
  /** Placeholder text */
  placeholder?: string;
}

export interface ContextRailProps {
  /** Tab configurations */
  tabs: ContextRailTabConfig[];
  /** Bank navigation (optional - hide if null) */
  bankNav?: ContextRailBankNavProps | null;
  /** Search/filter (optional - hide if null) */
  search?: ContextRailSearchProps | null;
  /** Additional CSS classes */
  className?: string;
}

// =============================================================================
// Component
// =============================================================================

export function ContextRail({
  tabs,
  bankNav,
  search,
  className = '',
}: ContextRailProps): ReactElement {
  const baseId = useId();

  // Active tab state
  const [activeTabId, setActiveTabId] = useState<string>(tabs[0]?.id ?? '');

  // Panel expanded state
  const [isPanelOpen, setIsPanelOpen] = useState(false);

  // Search sheet state
  const [isSearchOpen, setIsSearchOpen] = useState(false);

  // Get active tab config
  const activeTab = tabs.find((t) => t.id === activeTabId) ?? tabs[0];

  // Handle tab click - switch tab and open panel
  const handleTabClick = useCallback((tabId: string) => {
    if (tabId === activeTabId && isPanelOpen) {
      // Clicking active tab while open - close panel
      setIsPanelOpen(false);
    } else {
      // Switch to tab and ensure panel is open
      setActiveTabId(tabId);
      setIsPanelOpen(true);
    }
  }, [activeTabId, isPanelOpen]);

  // Handle panel close
  const handlePanelClose = useCallback(() => {
    setIsPanelOpen(false);
  }, []);

  // Handle expand button
  const handleExpandToggle = useCallback(() => {
    setIsPanelOpen((prev) => !prev);
  }, []);

  // Search handlers
  const handleSearchClick = useCallback(() => {
    setIsSearchOpen(true);
  }, []);

  const handleSearchClose = useCallback(() => {
    setIsSearchOpen(false);
  }, []);

  const hasSearchValue = search?.value && search.value.trim().length > 0;

  return (
    <aside
      className={`
        relative flex flex-col h-full shrink-0
        bg-bg-deep border-l border-border-muted
        context-rail-width safe-area-right safe-area-top safe-area-bottom
        ${className}
      `}
      aria-label="Context panel"
      data-testid="context-rail"
    >
      {/* Tab buttons - vertical stack */}
      <div
        role="tablist"
        aria-label="Panel tabs"
        className="shrink-0 flex flex-col items-center py-2 gap-1"
      >
        {tabs.map((tab) => (
          <ContextRailTab
            key={tab.id}
            tabId={`${baseId}-tab-${tab.id}`}
            panelId={`${baseId}-panel-${tab.id}`}
            icon={tab.icon}
            label={tab.label}
            isActive={tab.id === activeTabId && isPanelOpen}
            badge={tab.badge}
            onClick={() => handleTabClick(tab.id)}
          />
        ))}

        {/* Search button */}
        {search && (
          <button
            onClick={handleSearchClick}
            className={`
              relative w-14 h-11 rounded-lg flex items-center justify-center
              transition-colors duration-150
              ${hasSearchValue
                ? 'bg-primary text-text-on-primary'
                : 'text-text-tertiary hover:bg-bg-hover hover:text-text-secondary'
              }
            `}
            aria-label={hasSearchValue ? `Search filter active: ${search.value}` : 'Open search'}
            title={hasSearchValue ? `Filter: "${search.value}"` : 'Search / Filter'}
          >
            <Search size={20} />
            {hasSearchValue && (
              <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 bg-warning rounded-full border border-bg-app" />
            )}
          </button>
        )}
      </div>

      {/* Spacer */}
      <div className="flex-1" />

      {/* Bank navigation */}
      {bankNav && (
        <div className="shrink-0 flex flex-col items-center gap-1 py-2 border-t border-border-subtle">
          {/* Back button */}
          <button
            onClick={bankNav.onBack}
            disabled={!bankNav.canGoBack}
            className="w-11 h-9 flex items-center justify-center rounded-lg bg-bg-surface border border-border-subtle disabled:opacity-30 disabled:cursor-not-allowed hover:bg-bg-hover active:bg-bg-elevated transition-colors"
            aria-label="Previous bank"
            data-testid="context-rail-bank-back"
          >
            <ChevronUp size={18} />
          </button>

          {/* Bank display (holdable for track labels) */}
          <button
            onPointerDown={bankNav.onHoldStart}
            onPointerUp={bankNav.onHoldEnd}
            onPointerLeave={bankNav.onHoldEnd}
            onPointerCancel={bankNav.onHoldEnd}
            className="w-14 h-9 px-1 flex items-center justify-center rounded-lg bg-bg-surface border border-border-subtle text-xs font-mono text-text-secondary hover:bg-bg-hover active:bg-bg-elevated transition-colors"
            aria-label={`Bank ${bankNav.bankDisplay}`}
            data-testid="context-rail-bank-display"
          >
            {bankNav.bankDisplay}
          </button>

          {/* Forward button */}
          <button
            onClick={bankNav.onForward}
            disabled={!bankNav.canGoForward}
            className="w-11 h-9 flex items-center justify-center rounded-lg bg-bg-surface border border-border-subtle disabled:opacity-30 disabled:cursor-not-allowed hover:bg-bg-hover active:bg-bg-elevated transition-colors"
            aria-label="Next bank"
            data-testid="context-rail-bank-forward"
          >
            <ChevronDown size={18} />
          </button>
        </div>
      )}

      {/* Expand/Collapse button */}
      <div className="shrink-0 flex items-center justify-center py-2 border-t border-border-subtle">
        <button
          onClick={handleExpandToggle}
          aria-expanded={isPanelOpen}
          aria-label={isPanelOpen ? 'Collapse panel' : 'Expand panel'}
          className="w-11 h-11 flex items-center justify-center text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-bg-hover"
        >
          <ChevronLeft
            size={20}
            className={`transition-transform duration-150 ${isPanelOpen ? '' : 'rotate-180'}`}
          />
        </button>
      </div>

      {/* Overlay panel */}
      <ContextRailPanel
        isOpen={isPanelOpen}
        onClose={handlePanelClose}
        title={activeTab?.label ?? 'Panel'}
      >
        {activeTab?.content}
      </ContextRailPanel>

      {/* Search BottomSheet */}
      {search && (
        <BottomSheet
          isOpen={isSearchOpen}
          onClose={handleSearchClose}
          ariaLabel="Filter Tracks"
        >
          <div className="p-4">
            <h2 className="text-sm font-medium text-text-secondary mb-3">Filter Tracks</h2>
            <div className="relative">
              <Search
                size={18}
                className="absolute left-3 top-1/2 -translate-y-1/2 text-text-muted pointer-events-none"
              />
              <input
                type="text"
                name="contextRailSearch"
                id="contextRailSearch"
                autoComplete="off"
                autoFocus
                value={search.value}
                onChange={(e) => search.onChange(e.target.value)}
                placeholder={search.placeholder ?? 'Filter tracks...'}
                className="w-full h-12 pl-10 pr-4 rounded-lg bg-bg-surface border border-border-subtle text-base text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-control-ring"
              />
            </div>
            {hasSearchValue && (
              <button
                onClick={() => search.onChange('')}
                className="mt-3 w-full py-2 text-sm text-text-secondary hover:text-text-primary transition-colors"
              >
                Clear filter
              </button>
            )}
          </div>
        </BottomSheet>
      )}
    </aside>
  );
}
