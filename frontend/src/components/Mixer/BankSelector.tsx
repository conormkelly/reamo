/**
 * BankSelector Component
 * Dropdown to select custom track banks with Add/Edit buttons.
 * "All Tracks" is the default bank and cannot be edited.
 */

import type { ReactElement } from 'react';
import { Plus, Pencil, Filter } from 'lucide-react';

export interface CustomBank {
  id: string;
  name: string;
  trackGuids: string[];
}

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
  /** Whether a filter is currently applied */
  isFiltered?: boolean;
  className?: string;
}

export function BankSelector({
  selectedBankId,
  banks,
  onBankChange,
  onAddBank,
  onEditBank,
  isFiltered = false,
  className = '',
}: BankSelectorProps): ReactElement {
  const isAllTracks = selectedBankId === null;

  return (
    <div className={`flex items-center gap-1 ${className}`}>
      {/* Filter indicator */}
      {isFiltered && <Filter size={14} className="text-amber-400" />}
      {/* Bank dropdown */}
      <select
        value={selectedBankId ?? ''}
        onChange={(e) => onBankChange(e.target.value || null)}
        className="bg-bg-elevated border border-border-subtle rounded px-2 py-1 text-sm text-text-primary focus:outline-none focus:ring-1 focus:ring-control-ring min-w-[120px]"
      >
        <option value="">All Tracks</option>
        {banks.map((bank) => (
          <option key={bank.id} value={bank.id}>
            {bank.name}
          </option>
        ))}
      </select>

      {/* Add bank button */}
      <button
        onClick={onAddBank}
        className="p-1.5 rounded bg-bg-elevated border border-border-subtle text-text-secondary hover:text-text-primary hover:bg-bg-surface transition-colors"
        title="Add new bank"
      >
        <Plus size={14} />
      </button>

      {/* Edit bank button - disabled for All Tracks */}
      <button
        onClick={() => selectedBankId && onEditBank(selectedBankId)}
        disabled={isAllTracks}
        className={`p-1.5 rounded bg-bg-elevated border border-border-subtle transition-colors ${
          isAllTracks
            ? 'text-text-disabled cursor-not-allowed opacity-50'
            : 'text-text-secondary hover:text-text-primary hover:bg-bg-surface'
        }`}
        title={isAllTracks ? 'Cannot edit All Tracks' : 'Edit bank'}
      >
        <Pencil size={14} />
      </button>
    </div>
  );
}
