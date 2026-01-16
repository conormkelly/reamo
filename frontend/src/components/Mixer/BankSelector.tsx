/**
 * BankSelector Component
 * Dropdown to select track banks (built-in + custom) with Add/Edit buttons.
 * "All Tracks" is the default bank and cannot be edited.
 * Built-in banks filter by track state (muted, soloed, armed, etc.)
 */

import { useMemo, type ReactElement } from 'react';
import { Plus, Pencil, Filter } from 'lucide-react';
import type { SkeletonTrack } from '../../core/WebSocketTypes';

/** Bank type: 'smart' auto-matches by pattern, 'custom' uses manual track selection */
export type BankType = 'smart' | 'custom';

export interface CustomBank {
  id: string;
  name: string;
  type: BankType;
  /** Smart bank: pattern to match track names (case-insensitive substring) */
  pattern?: string;
  /** Custom bank: manually selected track GUIDs */
  trackGuids: string[];
}

/** Built-in bank types for filtering by track state */
export type BuiltinBankId =
  | 'builtin:muted'
  | 'builtin:soloed'
  | 'builtin:armed'
  | 'builtin:selected'
  | 'builtin:folders'
  | 'builtin:with-sends';

/** Built-in bank definitions (read-only, always available) */
export const BUILTIN_BANKS: { id: BuiltinBankId; name: string }[] = [
  { id: 'builtin:muted', name: 'Muted' },
  { id: 'builtin:soloed', name: 'Soloed' },
  { id: 'builtin:armed', name: 'Armed' },
  { id: 'builtin:selected', name: 'Selected' },
  { id: 'builtin:folders', name: 'Folders' },
  { id: 'builtin:with-sends', name: 'With Sends' },
];

/** Check if a bank ID is a built-in bank */
export function isBuiltinBank(bankId: string | null): bankId is BuiltinBankId {
  return bankId !== null && bankId.startsWith('builtin:');
}

/** Count tracks matching a built-in bank filter (excludes master at index 0) */
function countTracksForBank(skeleton: SkeletonTrack[], bankId: BuiltinBankId): number {
  // Skip master track (first element)
  const userTracks = skeleton.slice(1);
  switch (bankId) {
    case 'builtin:muted':
      return userTracks.filter((t) => t.m === true).length;
    case 'builtin:soloed':
      return userTracks.filter((t) => t.sl !== null && t.sl !== 0).length;
    case 'builtin:armed':
      return userTracks.filter((t) => t.r === true).length;
    case 'builtin:selected':
      return userTracks.filter((t) => t.sel === true).length;
    case 'builtin:folders':
      return userTracks.filter((t) => t.fd === 1).length;
    case 'builtin:with-sends':
      return userTracks.filter((t) => t.sc > 0).length;
    default:
      return 0;
  }
}

export interface BankSelectorProps {
  /** Currently selected bank ID (null = All Tracks) */
  selectedBankId: string | null;
  /** Available custom banks */
  banks: CustomBank[];
  /** Track skeleton for computing built-in bank counts */
  skeleton: SkeletonTrack[];
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
  skeleton,
  onBankChange,
  onAddBank,
  onEditBank,
  isFiltered = false,
  className = '',
}: BankSelectorProps): ReactElement {
  const isAllTracks = selectedBankId === null;
  const isBuiltin = isBuiltinBank(selectedBankId);
  const canEdit = !isAllTracks && !isBuiltin;

  // Compute counts for each built-in bank (memoized to avoid recompute on every render)
  const builtinCounts = useMemo(() => {
    const counts: Record<BuiltinBankId, number> = {} as Record<BuiltinBankId, number>;
    for (const bank of BUILTIN_BANKS) {
      counts[bank.id] = countTracksForBank(skeleton, bank.id);
    }
    return counts;
  }, [skeleton]);

  return (
    <div className={`flex items-center gap-1 ${className}`}>
      {/* Filter indicator */}
      {isFiltered && <Filter size={14} className="text-sends-muted" />}
      {/* Bank dropdown */}
      <select
        value={selectedBankId ?? ''}
        onChange={(e) => onBankChange(e.target.value || null)}
        className="bg-bg-elevated border border-border-subtle rounded px-3 py-2 text-sm text-text-primary focus:outline-none focus:ring-1 focus:ring-control-ring min-w-[120px]"
      >
        <option value="">All Tracks</option>

        {/* Built-in banks with counts */}
        <optgroup label="Built-in">
          {BUILTIN_BANKS.map((bank) => (
            <option key={bank.id} value={bank.id}>
              {bank.name} ({builtinCounts[bank.id]})
            </option>
          ))}
        </optgroup>

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

      {/* Edit bank button - disabled for All Tracks and built-in banks */}
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
    </div>
  );
}
