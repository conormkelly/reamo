/**
 * MixerLockButton - Toggle lock for mixer controls
 * When locked, prevents accidental fader/knob changes.
 */

import type { ReactElement } from 'react';
import { Lock, Unlock } from 'lucide-react';
import { useReaperStore } from '../../store';

export function MixerLockButton(): ReactElement {
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const toggleMixerLock = useReaperStore((s) => s.toggleMixerLock);

  return (
    <button
      onClick={toggleMixerLock}
      aria-pressed={mixerLocked}
      className={`p-2 rounded transition-colors ${
        mixerLocked
          ? 'bg-warning text-text-primary'
          : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
      }`}
      title={mixerLocked ? 'Unlock mixer controls' : 'Lock mixer controls'}
    >
      {mixerLocked ? <Lock size={18} /> : <Unlock size={18} />}
    </button>
  );
}
