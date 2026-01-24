/**
 * SecondaryPanelTab - Individual tab button with optional badge
 *
 * Features:
 * - 40x40px touch target (WCAG 2.5.5 compliant)
 * - Active/inactive visual states
 * - Optional badge: dot (boolean indicator) or number (count)
 * - Accessible with ARIA attributes
 */

import type { LucideIcon } from 'lucide-react';

export interface SecondaryPanelTabProps {
  /** Lucide icon component */
  icon: LucideIcon;
  /** Accessibility label */
  label: string;
  /** Whether this tab is currently selected */
  isActive: boolean;
  /** Badge indicator: 'dot' for boolean, number for count, null/undefined for none */
  badge?: 'dot' | number | null;
  /** Click handler */
  onClick: () => void;
  /** Tab ID for ARIA */
  tabId: string;
  /** Panel ID this tab controls */
  panelId: string;
}

export function SecondaryPanelTab({
  icon: Icon,
  label,
  isActive,
  badge,
  onClick,
  tabId,
  panelId,
}: SecondaryPanelTabProps) {
  const hasBadge = badge === 'dot' || (typeof badge === 'number' && badge > 0);
  const badgeCount = typeof badge === 'number' ? badge : null;

  return (
    <button
      id={tabId}
      role="tab"
      aria-selected={isActive}
      aria-controls={panelId}
      aria-label={label}
      onClick={onClick}
      className={`
        relative w-10 h-10 rounded-lg flex items-center justify-center
        transition-colors duration-150
        ${isActive
          ? 'bg-primary text-on-primary'
          : 'text-text-tertiary hover:bg-bg-hover hover:text-text-secondary'
        }
      `}
    >
      <Icon size={20} />

      {/* Badge indicator */}
      {hasBadge && (
        badgeCount !== null ? (
          // Number badge
          <span className="absolute -top-1 -right-1 min-w-[18px] h-[18px] px-1 bg-warning text-bg-deep text-xs font-bold rounded-full flex items-center justify-center">
            {badgeCount > 9 ? '9+' : badgeCount}
          </span>
        ) : (
          // Dot badge
          <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 bg-warning rounded-full border border-bg-app" />
        )
      )}
    </button>
  );
}
