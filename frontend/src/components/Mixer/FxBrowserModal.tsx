/**
 * FxBrowserModal - Browse and add FX plugins to a track
 *
 * Shows installed plugins with search and type filtering.
 * Tap a plugin to add it to the track.
 * Plugin list is cached (fetched once per session).
 */

import { useState, useMemo, useEffect, useCallback, type ReactElement } from 'react';
import { Search, X, Loader2 } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { fxPlugin, trackFx } from '../../core/WebSocketCommands';
import { getPluginType, getPluginTypeBadge, type PluginType, type FxPlugin } from '../../store/slices/fxBrowserSlice';

export interface FxBrowserModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when modal should close */
  onClose: () => void;
  /** Track GUID to add FX to */
  trackGuid: string;
  /** Track name for display */
  trackName: string;
}

/** Plugin type filter options */
const TYPE_FILTERS: Array<{ label: string; value: PluginType | 'All' }> = [
  { label: 'All', value: 'All' },
  { label: 'AU', value: 'AU' },
  { label: 'VST3', value: 'VST3' },
  { label: 'VST', value: 'VST2' },
  { label: 'JS', value: 'JS' },
];

/**
 * Single plugin row
 */
function PluginRow({
  name,
  type,
  onSelect,
}: {
  name: string;
  type: PluginType;
  onSelect: () => void;
}): ReactElement {
  const badge = getPluginTypeBadge(type);

  return (
    <button
      onClick={onSelect}
      className="w-full flex items-center gap-3 py-3 px-3 rounded-lg bg-bg-surface hover:bg-bg-elevated transition-colors text-left"
    >
      {/* Type badge */}
      {badge && (
        <div className="w-12 h-6 flex items-center justify-center rounded bg-bg-elevated text-text-secondary text-xs font-medium shrink-0">
          {badge}
        </div>
      )}

      {/* Plugin name */}
      <span className="text-sm text-text-primary truncate flex-1">{name}</span>
    </button>
  );
}

export function FxBrowserModal({
  isOpen,
  onClose,
  trackGuid,
  trackName,
}: FxBrowserModalProps): ReactElement {
  const { sendCommand, sendCommandAsync } = useReaper();

  // State from store
  const fxPluginList = useReaperStore((s) => s.fxPluginList);
  const fxPluginListLoading = useReaperStore((s) => s.fxPluginListLoading);
  const fxPluginListError = useReaperStore((s) => s.fxPluginListError);
  const setFxPluginListLoading = useReaperStore((s) => s.setFxPluginListLoading);
  const setFxPluginList = useReaperStore((s) => s.setFxPluginList);
  const setFxPluginListError = useReaperStore((s) => s.setFxPluginListError);

  // Local filter state
  const [search, setSearch] = useState('');
  const [typeFilter, setTypeFilter] = useState<PluginType | 'All'>('All');

  // Fetch plugin list on first open (if not already cached)
  useEffect(() => {
    if (!isOpen) return;
    if (fxPluginList !== null || fxPluginListLoading) return;

    const fetchPlugins = async () => {
      setFxPluginListLoading(true);
      try {
        const response = await sendCommandAsync(fxPlugin.getList());
        // Response format: { success: true, payload: [[name, ident], ...] }
        const resp = response as { success?: boolean; payload?: FxPlugin[] };
        if (resp?.success && Array.isArray(resp.payload)) {
          setFxPluginList(resp.payload);
        } else {
          setFxPluginListError('Invalid response format');
        }
      } catch (err) {
        setFxPluginListError(err instanceof Error ? err.message : 'Failed to fetch plugins');
      }
    };

    fetchPlugins();
  }, [isOpen, fxPluginList, fxPluginListLoading, sendCommandAsync, setFxPluginListLoading, setFxPluginList, setFxPluginListError]);

  // Filter plugins by search and type
  const filteredPlugins = useMemo(() => {
    if (!fxPluginList) return [];

    const searchLower = search.toLowerCase();
    return fxPluginList.filter(([name]) => {
      // Type filter - type prefix is in the display name (e.g., "AU: Plugin", "VST3: Plugin")
      if (typeFilter !== 'All' && getPluginType(name) !== typeFilter) {
        return false;
      }
      // Search filter (case-insensitive)
      if (searchLower && !name.toLowerCase().includes(searchLower)) {
        return false;
      }
      return true;
    });
  }, [fxPluginList, search, typeFilter]);

  // Handle plugin selection
  const handleSelectPlugin = useCallback(
    (ident: string) => {
      sendCommand(trackFx.add(trackGuid, ident));
      onClose();
    },
    [sendCommand, trackGuid, onClose]
  );

  // Clear search when modal opens (fresh each time)
  useEffect(() => {
    if (isOpen) {
      setSearch('');
      setTypeFilter('All');
    }
  }, [isOpen]);

  return (
    <BottomSheet
      isOpen={isOpen}
      onClose={onClose}
      ariaLabel={`Add FX to ${trackName}`}
    >
      <div className="px-4 pb-6">
        {/* Header */}
        <div className="text-center mb-3 pt-1">
          <h2 className="text-lg font-semibold text-text-primary truncate">
            Add FX: {trackName}
          </h2>
        </div>

        {/* Search input */}
        <div className="relative mb-3">
          <Search
            size={16}
            className="absolute left-3 top-1/2 -translate-y-1/2 text-text-muted"
          />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search plugins..."
            className="w-full pl-9 pr-9 py-2.5 bg-bg-surface rounded-lg text-base text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-accent/50"
          />
          {search && (
            <button
              onClick={() => setSearch('')}
              className="absolute right-3 top-1/2 -translate-y-1/2 text-text-muted hover:text-text-secondary"
            >
              <X size={16} />
            </button>
          )}
        </div>

        {/* Type filter tabs */}
        <div className="flex gap-1.5 mb-3 overflow-x-auto pb-1">
          {TYPE_FILTERS.map(({ label, value }) => (
            <button
              key={value}
              onClick={() => setTypeFilter(value)}
              className={`px-3 py-1.5 rounded-lg text-xs font-medium whitespace-nowrap transition-colors ${
                typeFilter === value
                  ? 'bg-accent text-text-on-accent'
                  : 'bg-bg-surface text-text-secondary hover:bg-bg-elevated'
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {/* Plugin list */}
        <div className="max-h-80 overflow-y-auto -mx-4 px-4">
          {/* Loading state */}
          {fxPluginListLoading && (
            <div className="py-8 flex flex-col items-center gap-2 text-text-muted">
              <Loader2 size={24} className="animate-spin" />
              <span className="text-sm">Loading plugins...</span>
            </div>
          )}

          {/* Error state */}
          {fxPluginListError && (
            <div className="py-8 text-center text-error-text text-sm">
              {fxPluginListError}
            </div>
          )}

          {/* Empty state */}
          {!fxPluginListLoading && !fxPluginListError && filteredPlugins.length === 0 && (
            <div className="py-8 text-center text-text-muted text-sm">
              {fxPluginList === null
                ? 'No plugins loaded'
                : search || typeFilter !== 'All'
                  ? 'No matching plugins'
                  : 'No plugins installed'}
            </div>
          )}

          {/* Plugin list */}
          {!fxPluginListLoading && filteredPlugins.length > 0 && (
            <div className="space-y-1.5">
              {filteredPlugins.map(([name, ident]) => (
                <PluginRow
                  key={ident}
                  name={name}
                  type={getPluginType(name)}
                  onSelect={() => handleSelectPlugin(ident)}
                />
              ))}
            </div>
          )}
        </div>

        {/* Footer with count */}
        {!fxPluginListLoading && fxPluginList && (
          <div className="mt-3 pt-3 border-t border-border-subtle">
            <div className="text-xs text-text-muted text-center">
              {filteredPlugins.length === fxPluginList.length
                ? `${fxPluginList.length} plugins`
                : `${filteredPlugins.length} of ${fxPluginList.length} plugins`}
            </div>
          </div>
        )}
      </div>
    </BottomSheet>
  );
}
