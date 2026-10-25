/**
 * NotesView - notes longer than a phone can carry
 *
 * The server sends only the beginning of such notes, flagged truncated. The
 * phone must not offer to save them: the save would replace REAPER's notes
 * with that beginning.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { useReaperStore } from '../../store';

vi.hoisted(() => vi.resetModules());

const sendCommand = vi.fn();
const sendCommandAsync = vi.fn();
vi.mock('../../components/ReaperProvider', () => ({
  useReaper: () => ({ connected: true, sendCommand, sendCommandAsync }),
}));
vi.mock('../../components', () => ({
  ViewHeader: () => null,
  TextSizeControl: () => null,
  ViewLayout: ({ children, footer }: { children: React.ReactNode; footer?: React.ReactNode }) => (
    <div>
      {children}
      {footer}
    </div>
  ),
}));

const { NotesView } = await import('./NotesView');

describe('NotesView', () => {
  beforeEach(() => {
    sendCommand.mockReset();
    sendCommandAsync.mockReset();
    useReaperStore.setState({ serverNotes: null, serverHash: null, localNotes: '', hasExternalChange: false });
  });

  it('shows cut-off notes read-only, with no way to save over them', async () => {
    sendCommandAsync.mockResolvedValue({
      success: true,
      payload: { notes: 'Verse 1: la la', hash: '00', truncated: true },
    });
    render(<NotesView />);
    const editor = (await screen.findByDisplayValue('Verse 1: la la')) as HTMLTextAreaElement;
    expect(editor.readOnly).toBe(true);
    expect(screen.getByText(/only the beginning is shown/)).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Save' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('edits whole notes as before', async () => {
    sendCommandAsync.mockResolvedValue({ success: true, payload: { notes: 'Setlist', hash: '00' } });
    render(<NotesView />);
    const editor = (await screen.findByDisplayValue('Setlist')) as HTMLTextAreaElement;
    expect(editor.readOnly).toBe(false);
    expect(screen.queryByText(/only the beginning is shown/)).toBeNull();
  });
});
