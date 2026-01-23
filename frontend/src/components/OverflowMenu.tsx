/**
 * OverflowMenu - Header controls overflow menu using BottomSheet
 *
 * Used for progressive disclosure of header controls on narrow viewports.
 * When the header becomes too crowded, secondary controls collapse into this menu.
 *
 * @see docs/architecture/UX_GUIDELINES.md §8 (Header Overflow Pattern)
 */

import { useState, type ReactNode } from 'react';
import { MoreVertical } from 'lucide-react';
import { BottomSheet } from './Modal/BottomSheet';

export interface OverflowMenuItem {
  /** Unique identifier for the menu item */
  id: string;
  /** Display label */
  label: string;
  /** Optional icon to show before the label */
  icon?: ReactNode;
  /** Called when the item is selected */
  onSelect: () => void;
  /** Whether the item is currently active/selected (for toggle items) */
  isActive?: boolean;
}

export interface OverflowMenuProps {
  /** Menu items to display */
  items: OverflowMenuItem[];
  /** Accessible label for the menu button */
  ariaLabel?: string;
  /** Additional className for the trigger button */
  className?: string;
}

/**
 * Overflow menu component that displays items in a bottom sheet.
 * Returns null if there are no items to display.
 *
 * @example
 * <OverflowMenu
 *   items={[
 *     { id: 'settings', label: 'Settings', icon: <Settings />, onSelect: openSettings },
 *     { id: 'help', label: 'Help', onSelect: openHelp },
 *   ]}
 * />
 */
export function OverflowMenu({
  items,
  ariaLabel = 'More options',
  className = '',
}: OverflowMenuProps) {
  const [isOpen, setIsOpen] = useState(false);

  // Don't render if no items
  if (items.length === 0) return null;

  return (
    <>
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className={`p-2 rounded-lg hover:bg-bg-hover transition-colors ${className}`}
        aria-label={ariaLabel}
        aria-haspopup="menu"
        aria-expanded={isOpen}
      >
        <MoreVertical className="w-5 h-5" />
      </button>

      <BottomSheet
        isOpen={isOpen}
        onClose={() => setIsOpen(false)}
        ariaLabel="Menu options"
      >
        <nav className="flex flex-col pb-4" role="menu">
          {items.map((item) => (
            <button
              key={item.id}
              type="button"
              role="menuitem"
              onClick={() => {
                item.onSelect();
                setIsOpen(false);
              }}
              className={`flex items-center gap-3 px-4 py-3 hover:bg-bg-hover transition-colors text-left ${
                item.isActive ? 'bg-bg-surface text-accent-primary' : 'text-text-primary'
              }`}
            >
              {item.icon && (
                <span className="w-5 h-5 flex items-center justify-center shrink-0">
                  {item.icon}
                </span>
              )}
              <span className="text-base">{item.label}</span>
            </button>
          ))}
        </nav>
      </BottomSheet>
    </>
  );
}

export default OverflowMenu;
