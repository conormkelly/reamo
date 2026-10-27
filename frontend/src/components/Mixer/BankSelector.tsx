/**
 * BankSelector Component
 * Dropdown to select track banks (built-in + custom) with Add/Edit buttons.
 * "All Tracks" is the default bank and cannot be edited.
 * Built-in banks filter by track state (muted, soloed, armed, etc.)
 */

import type { ReactElement } from 'react';
import { Plus, Pencil, FolderOpen } from 'lucide-react';
import { isBuiltinBank, isQuickFilter, type CustomBank } from './banks';

export interface BankSelectorProps {
  /** Currently selected bank ID (null = All Tracks) */
  selectedBankId: string | null;
  /** Available custom banks */
  banks: CustomBank[];
  /** Callback when bank selection changes */
  onBankChange: (bankId: string | null) => void;
  /** Callback to add a new bank */
  onAddBank: () => void;
  /** Callback to edit the selected bank */
  onEditBank: (bankId: string) => void;
  /** Callback when folder navigation button is clicked (shown when Folders bank is active) */
  onFolderNavClick?: () => void;
  className?: string;
}

export function BankSelector({
  selectedBankId,
  banks,
  onBankChange,
  onAddBank,
  onEditBank,
  onFolderNavClick,
  className = '',
}: BankSelectorProps): ReactElement {
  const isAllTracks = selectedBankId === null;
  const isBuiltin = isBuiltinBank(selectedBankId);
  const isQuickFilterActive = isQuickFilter(selectedBankId);
  const canEdit = !isAllTracks && !isBuiltin;

  // When a quick filter is active, show "All Tracks" in bank selector
  // (quick filters are controlled by QuickFilterDropdown, not this dropdown)
  const displayValue = isQuickFilterActive ? '' : (selectedBankId ?? '');

  return (
    <div className={`flex items-center gap-1 ${className}`}>
      {/* Bank dropdown */}
      <select
        value={displayValue}
        onChange={(e) => onBankChange(e.target.value || null)}
        className="bg-bg-elevated border border-border-subtle rounded px-3 py-2 text-sm text-text-primary focus:outline-none focus:ring-1 focus:ring-control-ring min-w-[120px]"
      >
        <option value="">All Tracks</option>
        <option value="builtin:folders">Folders</option>

        {/* Custom banks (only if any exist) */}
        {banks.length > 0 && (
          <optgroup label="Custom">
            {banks.map((bank) => (
              <option key={bank.id} value={bank.id}>
                {bank.name}
              </option>
            ))}
          </optgroup>
        )}
      </select>

      {/* Add bank button */}
      <button
        onClick={onAddBank}
        className="p-2 rounded bg-bg-elevated border border-border-subtle text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
        title="Add new bank"
      >
        <Plus size={18} />
      </button>

      {/* Edit/Folder button - shows folder icon for Folders bank, edit for custom banks */}
      {selectedBankId === 'builtin:folders' && onFolderNavClick ? (
        <button
          onClick={onFolderNavClick}
          className="p-2 rounded bg-bg-elevated border border-border-subtle text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
          title="Browse folders"
        >
          <FolderOpen size={18} />
        </button>
      ) : (
        <button
          onClick={() => selectedBankId && !isBuiltin && onEditBank(selectedBankId)}
          disabled={!canEdit}
          className={`p-2 rounded bg-bg-elevated border border-border-subtle transition-colors ${
            !canEdit
              ? 'text-text-disabled cursor-not-allowed opacity-50'
              : 'text-text-secondary hover:text-text-primary hover:bg-bg-surface'
          }`}
          title={isAllTracks ? 'Cannot edit All Tracks' : isBuiltin ? 'Built-in banks cannot be edited' : 'Edit bank'}
        >
          <Pencil size={18} />
        </button>
      )}
    </div>
  );
}
