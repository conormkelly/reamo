/**
 * Custom Banks Hook
 * Manages user-defined track collections stored in ProjExtState.
 * Banks persist with the project file and survive Save As.
 *
 * @example
 * ```tsx
 * function BankManager() {
 *   const { banks, saveBank, deleteBank, loading } = useCustomBanks();
 *
 *   const handleCreate = async () => {
 *     await saveBank({ id: crypto.randomUUID(), name: 'Drums', trackGuids: [...] });
 *   };
 *
 *   return (
 *     <select>
 *       <option value="">All Tracks</option>
 *       {banks.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
 *     </select>
 *   );
 * }
 * ```
 */

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useReaper } from '../components/ReaperProvider';
import { extstate } from '../core/WebSocketCommands';
import type { CustomBank } from '../components/Mixer/BankSelector';

/** ProjExtState key for custom banks */
const EXTNAME = 'Reamo';
const KEY = 'CustomBanks';

export interface UseCustomBanksReturn {
  /** All custom banks for current project */
  banks: CustomBank[];
  /** Whether banks are currently loading */
  loading: boolean;
  /** Error message if load/save failed */
  error: string | null;
  /** Save or update a bank */
  saveBank: (bank: CustomBank) => Promise<void>;
  /** Delete a bank by ID */
  deleteBank: (bankId: string) => Promise<void>;
  /** Reload banks from project */
  reload: () => Promise<void>;
}

interface ExtStateResponse {
  success: boolean;
  payload?: {
    value?: string;
  };
  error?: string;
}

/**
 * Hook for managing custom track banks.
 * Banks are stored in ProjExtState so they travel with the project file.
 */
export function useCustomBanks(): UseCustomBanksReturn {
  const { sendCommandAsync, connected } = useReaper();

  const [banks, setBanks] = useState<CustomBank[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Load banks from ProjExtState
  const loadBanks = useCallback(async () => {
    if (!connected) return;

    setLoading(true);
    setError(null);

    try {
      const response = (await sendCommandAsync(
        extstate.projGet(EXTNAME, KEY)
      )) as ExtStateResponse;

      if (response.success && response.payload?.value) {
        try {
          const parsed = JSON.parse(response.payload.value) as CustomBank[];
          setBanks(Array.isArray(parsed) ? parsed : []);
        } catch {
          // Invalid JSON - start fresh
          setBanks([]);
        }
      } else {
        // No data stored yet
        setBanks([]);
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to load banks';
      setError(message);
      console.error('[useCustomBanks] Load error:', err);
    } finally {
      setLoading(false);
    }
  }, [connected, sendCommandAsync]);

  // Save banks to ProjExtState
  const saveBanksToProject = useCallback(
    async (newBanks: CustomBank[]) => {
      if (!connected) {
        setError('Not connected');
        return;
      }

      try {
        const value = JSON.stringify(newBanks);
        const response = (await sendCommandAsync(
          extstate.projSet(EXTNAME, KEY, value)
        )) as ExtStateResponse;

        if (!response.success) {
          throw new Error(response.error ?? 'Failed to save banks');
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : 'Failed to save banks';
        setError(message);
        console.error('[useCustomBanks] Save error:', err);
        throw err;
      }
    },
    [connected, sendCommandAsync]
  );

  // Save or update a single bank
  const saveBank = useCallback(
    async (bank: CustomBank) => {
      const existingIndex = banks.findIndex((b) => b.id === bank.id);
      const newBanks =
        existingIndex >= 0
          ? banks.map((b) => (b.id === bank.id ? bank : b))
          : [...banks, bank];

      await saveBanksToProject(newBanks);
      setBanks(newBanks);
    },
    [banks, saveBanksToProject]
  );

  // Delete a bank
  const deleteBank = useCallback(
    async (bankId: string) => {
      const newBanks = banks.filter((b) => b.id !== bankId);
      await saveBanksToProject(newBanks);
      setBanks(newBanks);
    },
    [banks, saveBanksToProject]
  );

  // Load on connect and when project changes
  useEffect(() => {
    if (connected) {
      loadBanks();
    }
  }, [connected, loadBanks]);

  return useMemo(
    () => ({
      banks,
      loading,
      error,
      saveBank,
      deleteBank,
      reload: loadBanks,
    }),
    [banks, loading, error, saveBank, deleteBank, loadBanks]
  );
}
