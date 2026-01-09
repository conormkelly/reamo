/**
 * NotesView - Project notes editor
 * Mobile-first design with external change detection
 */

import { useEffect, useCallback, type ReactElement } from 'react';
import { useReaperStore, getNotesIsDirty, getNotesIsOverLimit, getNotesCanSave } from '../../store';
import { useReaper } from '../../components/ReaperProvider';
import { ViewHeader, TextSizeControl } from '../../components';
import { useUIPreferences } from '../../hooks';
import { projectNotes } from '../../core/WebSocketCommands';

const NOTES_LIMIT = 5000;
const COUNTER_SHOW_THRESHOLD = 0.75; // 75%
const COUNTER_WARNING_THRESHOLD = 0.9; // 90%

interface NotesResponse {
  success: boolean;
  payload?: {
    notes: string;
    hash: string;
  };
  error?: {
    code: string;
    message: string;
  };
}

export function NotesView(): ReactElement {
  // Use shared connection from context - do NOT call useReaperConnection() directly
  // as that creates a second WebSocket connection that disrupts connection state
  const { connected, sendCommand, sendCommandAsync } = useReaper();
  const { notesFontSize, setNotesFontSize } = useUIPreferences();

  // Notes state from store
  const serverNotes = useReaperStore((s) => s.serverNotes);
  const localNotes = useReaperStore((s) => s.localNotes);
  const hasExternalChange = useReaperStore((s) => s.hasExternalChange);
  const isLoading = useReaperStore((s) => s.isNotesLoading);
  const isSaving = useReaperStore((s) => s.isNotesSaving);
  const notesError = useReaperStore((s) => s.notesError);

  // Actions
  const setServerNotes = useReaperStore((s) => s.setServerNotes);
  const setLocalNotes = useReaperStore((s) => s.setLocalNotes);
  const setExternalChange = useReaperStore((s) => s.setExternalChange);
  const setNotesLoading = useReaperStore((s) => s.setNotesLoading);
  const setNotesSaving = useReaperStore((s) => s.setNotesSaving);
  const setNotesError = useReaperStore((s) => s.setNotesError);
  const discardLocalNotes = useReaperStore((s) => s.discardLocalNotes);

  // Derived state
  const isDirty = getNotesIsDirty({ localNotes, serverNotes });
  const isOverLimit = getNotesIsOverLimit({ localNotes }, NOTES_LIMIT);
  const canSave = getNotesCanSave({ localNotes, serverNotes, hasExternalChange }, NOTES_LIMIT);

  // Character counter display logic
  const charCount = localNotes.length;
  const charRatio = charCount / NOTES_LIMIT;
  const showCounter = charRatio >= COUNTER_SHOW_THRESHOLD;
  const overCount = charCount - NOTES_LIMIT;

  // Subscribe on mount when connected
  useEffect(() => {
    if (!connected) return;

    setNotesLoading(true);
    sendCommandAsync(projectNotes.subscribe())
      .then((response) => {
        const resp = response as NotesResponse;
        if (resp.success && resp.payload) {
          setServerNotes(resp.payload.notes, resp.payload.hash);
        } else if (resp.error) {
          setNotesError(resp.error.message);
        }
      })
      .catch((err) => {
        setNotesError(err.message || 'Failed to load notes');
      })
      .finally(() => {
        setNotesLoading(false);
      });

    // Cleanup: unsubscribe on unmount
    return () => {
      sendCommand(projectNotes.unsubscribe());
    };
  }, [connected, sendCommand, sendCommandAsync, setServerNotes, setNotesLoading, setNotesError]);

  // Handle save
  const handleSave = useCallback(() => {
    if (!canSave) return;

    setNotesSaving(true);
    setNotesError(null);

    sendCommandAsync(projectNotes.set(localNotes))
      .then((response) => {
        const resp = response as NotesResponse;
        if (resp.success && resp.payload) {
          setServerNotes(resp.payload.notes, resp.payload.hash);
        } else if (resp.error) {
          setNotesError(resp.error.message);
        }
      })
      .catch((err) => {
        setNotesError(err.message || 'Failed to save notes');
      })
      .finally(() => {
        setNotesSaving(false);
      });
  }, [canSave, localNotes, sendCommandAsync, setServerNotes, setNotesSaving, setNotesError]);

  // Handle reload (after external change)
  const handleReload = useCallback(() => {
    setNotesLoading(true);
    sendCommandAsync(projectNotes.get())
      .then((response) => {
        const resp = response as NotesResponse;
        if (resp.success && resp.payload) {
          setServerNotes(resp.payload.notes, resp.payload.hash);
        }
      })
      .catch((err) => {
        setNotesError(err.message || 'Failed to reload notes');
      })
      .finally(() => {
        setNotesLoading(false);
      });
  }, [sendCommandAsync, setServerNotes, setNotesLoading, setNotesError]);

  // Handle ignore (keep local changes despite external change)
  const handleIgnore = useCallback(() => {
    setExternalChange(false);
  }, [setExternalChange]);

  // Handle discard
  const handleDiscard = useCallback(() => {
    discardLocalNotes();
  }, [discardLocalNotes]);

  // Counter color based on threshold
  const getCounterColor = () => {
    if (isOverLimit) return 'text-counter-error';
    if (charRatio >= COUNTER_WARNING_THRESHOLD) return 'text-counter-warning';
    return 'text-text-secondary';
  };

  // Show loading state
  if (isLoading && serverNotes === null) {
    return (
      <div data-view="notes" className="h-full bg-bg-app text-text-primary p-3 flex flex-col">
        <ViewHeader currentView="notes" />
        <div className="flex-1 flex items-center justify-center">
          <p className="text-text-secondary">Loading notes...</p>
        </div>
      </div>
    );
  }

  return (
    <div data-view="notes" className="h-full bg-bg-app text-text-primary p-3 flex flex-col">
      <ViewHeader currentView="notes">
        <TextSizeControl value={notesFontSize} onChange={setNotesFontSize} />
      </ViewHeader>
      {/* Error display */}
      {notesError && (
        <div className="mb-4 p-3 bg-error-display-bg border border-error-display-border rounded-lg text-error-display-text">
          {notesError}
        </div>
      )}

      {/* Textarea */}
      <div className="flex-1 flex flex-col min-h-0">
        <textarea
          className={`flex-1 w-full bg-bg-deep border rounded-lg p-3 text-text-primary resize-none focus:outline-none focus:ring-2 focus:ring-focus-ring ${
            hasExternalChange ? 'border-external-border bg-bg-deep/50' : 'border-border-subtle'
          } ${isOverLimit ? 'border-counter-error' : ''}`}
          style={{ fontSize: notesFontSize }}
          placeholder="Add project notes here..."
          value={localNotes}
          onChange={(e) => setLocalNotes(e.target.value)}
          disabled={hasExternalChange}
          aria-describedby={showCounter ? 'notes-counter' : undefined}
        />

        {/* Character counter */}
        {showCounter && (
          <div
            id="notes-counter"
            role="status"
            className={`text-right text-sm mt-1 ${getCounterColor()}`}
          >
            {isOverLimit ? (
              <span>{overCount} characters over limit</span>
            ) : (
              <span>
                {charCount.toLocaleString()} / {NOTES_LIMIT.toLocaleString()}
              </span>
            )}
          </div>
        )}
      </div>

      {/* External change warning bar */}
      {hasExternalChange && (
        <div className="mt-4 p-3 bg-external-bar-bg border border-external-bar-border rounded-lg flex items-center justify-between gap-3">
          <span className="text-external-bar-text">Notes edited elsewhere</span>
          <div className="flex gap-2">
            <button
              onClick={handleReload}
              className="px-3 py-1.5 bg-external-btn hover:bg-external-btn-hover rounded text-text-primary text-sm font-medium"
            >
              Reload
            </button>
            <button
              onClick={handleIgnore}
              className="px-3 py-1.5 bg-bg-elevated hover:bg-bg-hover rounded text-text-primary text-sm font-medium"
            >
              Ignore
            </button>
          </div>
        </div>
      )}

      {/* Action buttons */}
      <div className="mt-4 flex gap-3">
        <button
          onClick={handleDiscard}
          disabled={!isDirty && !hasExternalChange}
          className={`flex-1 py-3 rounded-lg font-medium transition-colors ${
            isDirty || hasExternalChange
              ? 'bg-bg-surface hover:bg-bg-elevated text-text-primary'
              : 'bg-bg-deep text-text-disabled cursor-not-allowed'
          }`}
        >
          Discard
        </button>
        <button
          onClick={handleSave}
          disabled={!canSave || isSaving}
          className={`flex-1 py-3 rounded-lg font-medium transition-colors ${
            canSave && !isSaving
              ? 'bg-primary hover:bg-primary-hover text-text-on-primary'
              : 'bg-bg-deep text-text-disabled cursor-not-allowed'
          }`}
        >
          {isSaving ? 'Saving...' : 'Save'}
        </button>
      </div>
    </div>
  );
}
