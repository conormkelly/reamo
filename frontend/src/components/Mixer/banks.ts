/**
 * Track bank definitions shared by the mixer and timeline: custom banks the
 * user creates, and the built-in banks and quick filters that select tracks
 * by state.
 */

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
  | 'builtin:with-sends'
  | 'builtin:clipped'
  | 'builtin:with-items';

/** Built-in bank definitions (read-only, always available) */
export const BUILTIN_BANKS: { id: BuiltinBankId; name: string }[] = [
  { id: 'builtin:folders', name: 'Folders' },
];

/** Quick filter options (shown in separate dropdown) */
export const QUICK_FILTERS: { id: BuiltinBankId; name: string; shortName: string }[] = [
  { id: 'builtin:muted', name: 'Muted', shortName: 'M' },
  { id: 'builtin:soloed', name: 'Soloed', shortName: 'S' },
  { id: 'builtin:armed', name: 'Armed', shortName: 'R' },
  { id: 'builtin:selected', name: 'Selected', shortName: 'Sel' },
  { id: 'builtin:with-sends', name: 'With Sends', shortName: 'Snd' },
  { id: 'builtin:clipped', name: 'Clipped', shortName: 'Clip' },
  { id: 'builtin:with-items', name: 'With Items', shortName: 'Itm' },
];

/** Check if a bank ID is a built-in bank */
export function isBuiltinBank(bankId: string | null): bankId is BuiltinBankId {
  return bankId !== null && bankId.startsWith('builtin:');
}

/** Quick filter IDs that are NOT shown in bank selector */
const QUICK_FILTER_IDS = new Set<string>(QUICK_FILTERS.map((f) => f.id));

/** Check if a bank ID is a quick filter (handled by QuickFilterDropdown, not BankSelector) */
export function isQuickFilter(bankId: string | null): boolean {
  return bankId !== null && QUICK_FILTER_IDS.has(bankId);
}
