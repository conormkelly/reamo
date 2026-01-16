/**
 * CreateTrackModal - Simple modal for creating new tracks
 *
 * Features:
 * - Optional track name (defaults to "Track N" auto-naming)
 * - Position selection: Start or End of project
 */

import { useState, useCallback, type ReactElement } from 'react';
import { Modal, ModalContent, ModalFooter } from '../Modal';
import { useReaper } from '../ReaperProvider';
import { track as trackCmd } from '../../core/WebSocketCommands';

export interface CreateTrackModalProps {
  isOpen: boolean;
  onClose: () => void;
}

type Position = 'end' | 'start';

export function CreateTrackModal({ isOpen, onClose }: CreateTrackModalProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const [name, setName] = useState('');
  const [position, setPosition] = useState<Position>('start');

  const handleCreate = useCallback(() => {
    // Position mapping:
    // - 'end' = omit afterTrackIdx (default: append at end)
    // - 'start' = afterTrackIdx: 0 (insert after master, becomes first user track)
    const afterTrackIdx = position === 'start' ? 0 : undefined;
    const trackName = name.trim() || undefined;

    sendCommand(trackCmd.create(trackName, afterTrackIdx));

    // Reset and close
    setName('');
    setPosition('start');
    onClose();
  }, [sendCommand, name, position, onClose]);

  const handleClose = useCallback(() => {
    setName('');
    setPosition('start');
    onClose();
  }, [onClose]);

  if (!isOpen) return null;

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Create Track" width="sm">
      <ModalContent>
        {/* Name input */}
        <div>
          <label htmlFor="track-name" className="block text-sm text-text-secondary mb-1">
            Name (optional)
          </label>
          <input
            id="track-name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Track N"
            className="w-full bg-bg-elevated border border-border-subtle rounded px-3 py-2 text-base text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-1 focus:ring-control-ring"
            autoFocus
          />
        </div>

        {/* Position radio buttons */}
        <div>
          <span className="block text-sm text-text-secondary mb-2">Position</span>
          <div className="space-y-2">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="position"
                value="start"
                checked={position === 'start'}
                onChange={() => setPosition('start')}
                className="accent-primary"
              />
              <span className="text-sm text-text-primary">Start of project</span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="position"
                value="end"
                checked={position === 'end'}
                onChange={() => setPosition('end')}
                className="accent-primary"
              />
              <span className="text-sm text-text-primary">End of project</span>
            </label>
          </div>
        </div>
      </ModalContent>
      <ModalFooter
        onCancel={handleClose}
        onConfirm={handleCreate}
        confirmText="Create"
      />
    </Modal>
  );
}
