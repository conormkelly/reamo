/**
 * useItemNotes Hook Tests
 *
 * The item sheet may only offer its notes for editing once REAPER's notes
 * have arrived: saving replaces them, so an editor opened over notes that
 * failed to load would erase them.
 */

import { describe, it, expect, vi } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';
import { useItemNotes } from './useItemNotes';

type SendAsync = (command: string, params?: Record<string, unknown>) => Promise<unknown>;

function deferred() {
  let resolve!: (v: unknown) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<unknown>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe('useItemNotes', () => {
  it('asks REAPER for the notes of the item by its GUID', async () => {
    const sendAsync = vi.fn<SendAsync>().mockResolvedValue({ success: true, payload: { notes: '' } });
    renderHook(() => useItemNotes('{A}', true, true, sendAsync));
    await waitFor(() => expect(sendAsync).toHaveBeenCalledWith('item/getNotes', { itemGuid: '{A}' }));
  });

  it('is loaded with the notes REAPER sent', async () => {
    const sendAsync = vi.fn<SendAsync>().mockResolvedValue({ success: true, payload: { notes: 'double the chorus' } });
    const { result } = renderHook(() => useItemNotes('{A}', true, true, sendAsync));
    await waitFor(() => expect(result.current.status).toBe('loaded'));
    expect(result.current.notes).toBe('double the chorus');
  });

  it('fails, not loads empty notes, when REAPER answers with an error', async () => {
    const sendAsync = vi.fn<SendAsync>().mockResolvedValue({
      success: false,
      error: { code: 'NOTES_TOO_LARGE', message: 'Item notes exceed the response buffer' },
    });
    const { result } = renderHook(() => useItemNotes('{A}', true, true, sendAsync));
    await waitFor(() => expect(result.current.status).toBe('failed'));
  });

  it('fails, not loads empty notes, when the request times out', async () => {
    const sendAsync = vi.fn<SendAsync>().mockRejectedValue(new Error('timeout'));
    const { result } = renderHook(() => useItemNotes('{A}', true, true, sendAsync));
    await waitFor(() => expect(result.current.status).toBe('failed'));
  });

  it('ignores a late answer for the item that was selected before', async () => {
    const first = deferred();
    const sendAsync = vi.fn<SendAsync>()
      .mockReturnValueOnce(first.promise)
      .mockResolvedValueOnce({ success: true, payload: { notes: 'notes of B' } });
    const { result, rerender } = renderHook(({ guid }) => useItemNotes(guid, true, true, sendAsync), {
      initialProps: { guid: '{A}' },
    });
    rerender({ guid: '{B}' });
    await waitFor(() => expect(result.current.notes).toBe('notes of B'));
    await act(async () => first.resolve({ success: true, payload: { notes: 'notes of A' } }));
    expect(result.current.notes).toBe('notes of B');
  });

  it('loads on retry after a failure', async () => {
    const sendAsync = vi.fn<SendAsync>()
      .mockRejectedValueOnce(new Error('timeout'))
      .mockResolvedValueOnce({ success: true, payload: { notes: 'second try' } });
    const { result } = renderHook(() => useItemNotes('{A}', true, true, sendAsync));
    await waitFor(() => expect(result.current.status).toBe('failed'));
    act(() => result.current.retry());
    await waitFor(() => expect(result.current.status).toBe('loaded'));
    expect(result.current.notes).toBe('second try');
  });

  it('fetches again each time the sheet opens, so it never edits stale notes', async () => {
    const sendAsync = vi.fn<SendAsync>()
      .mockResolvedValueOnce({ success: true, payload: { notes: 'old' } })
      .mockResolvedValueOnce({ success: true, payload: { notes: 'changed in REAPER' } });
    const { result, rerender } = renderHook(({ open }) => useItemNotes('{A}', open, true, sendAsync), {
      initialProps: { open: true },
    });
    await waitFor(() => expect(result.current.notes).toBe('old'));
    rerender({ open: false });
    expect(result.current.status).toBe('idle');
    rerender({ open: true });
    await waitFor(() => expect(result.current.notes).toBe('changed in REAPER'));
  });

  it('does nothing while disconnected', () => {
    const sendAsync = vi.fn<SendAsync>();
    const { result } = renderHook(() => useItemNotes('{A}', true, false, sendAsync));
    expect(sendAsync).not.toHaveBeenCalled();
    expect(result.current.status).toBe('idle');
  });
});
