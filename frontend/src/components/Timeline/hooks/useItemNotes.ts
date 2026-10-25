/**
 * useItemNotes - Fetch an item's notes from REAPER for the item sheet.
 *
 * Saving notes replaces them, so the sheet may only edit notes REAPER has
 * actually sent: 'failed' is distinct from loaded-and-empty, and a caller
 * offers editing only when status is 'loaded'. Notes are fetched each time
 * the sheet opens (they may have changed in REAPER since), and an answer
 * for an item that is no longer the one shown is dropped.
 */

import { useState, useEffect, useCallback } from 'react';
import { item as itemCmd } from '../../../core/WebSocketCommands';

export type ItemNotesStatus = 'idle' | 'loading' | 'loaded' | 'failed';

export interface UseItemNotesReturn {
  status: ItemNotesStatus;
  /** REAPER's notes; meaningful only when status is 'loaded' */
  notes: string;
  /** Fetch again (after a failure) */
  retry: () => void;
  /** Record notes this client just saved, so they show without a refetch */
  markSaved: (notes: string) => void;
}

type SendAsync = (command: string, params?: Record<string, unknown>) => Promise<unknown>;

export function useItemNotes(
  itemGuid: string | null,
  active: boolean,
  connected: boolean,
  sendAsync: SendAsync
): UseItemNotesReturn {
  const [status, setStatus] = useState<ItemNotesStatus>('idle');
  const [notes, setNotes] = useState('');
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    setStatus('idle');
    setNotes('');
    if (!active || !connected || !itemGuid) return;

    let current = true;
    setStatus('loading');
    const cmd = itemCmd.getNotes(itemGuid);
    sendAsync(cmd.command, cmd.params)
      .then((response) => {
        if (!current) return;
        const resp = response as { success?: boolean; payload?: { notes?: unknown } } | undefined;
        if (resp?.success && typeof resp.payload?.notes === 'string') {
          setNotes(resp.payload.notes);
          setStatus('loaded');
        } else {
          setStatus('failed');
        }
      })
      .catch(() => {
        if (current) setStatus('failed');
      });
    return () => {
      current = false;
    };
  }, [itemGuid, active, connected, sendAsync, attempt]);

  const retry = useCallback(() => setAttempt((n) => n + 1), []);
  const markSaved = useCallback((saved: string) => setNotes(saved), []);

  return { status, notes, retry, markSaved };
}
