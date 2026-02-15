/**
 * HwChannelPicker - Inline output channel selection for hardware output routing.
 * Fetches available output channels from backend and displays stereo pairs + mono.
 */

import { useState, useEffect, useCallback, useMemo, type ReactElement } from 'react';
import { Loader2 } from 'lucide-react';
import { useReaper } from '../../ReaperProvider';
import { hw as hwCmd } from '../../../core/WebSocketCommands';

interface OutputChannel {
  destChan: number;  // I_DSTCHAN encoding
  name: string;      // Display name e.g. "Output 1 / Output 2"
  stereo: boolean;
}

interface ListOutputsResponse {
  success?: boolean;
  payload?: { outputs?: OutputChannel[] };
}

export interface HwChannelPickerProps {
  onSelect: (destChannel: number) => void;
  onCancel: () => void;
  prompt: string;
  currentDestChannel?: number;
}

export function HwChannelPicker({
  onSelect,
  onCancel,
  prompt,
  currentDestChannel,
}: HwChannelPickerProps): ReactElement {
  const { sendCommandAsync } = useReaper();
  const [outputs, setOutputs] = useState<OutputChannel[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchOutputs = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const res = (await sendCommandAsync(hwCmd.listOutputs())) as ListOutputsResponse;
      if (res.success && res.payload?.outputs) {
        setOutputs(res.payload.outputs);
      } else {
        setError('Failed to load output channels');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load outputs');
    } finally {
      setIsLoading(false);
    }
  }, [sendCommandAsync]);

  useEffect(() => {
    fetchOutputs();
  }, [fetchOutputs]);

  const stereoOutputs = useMemo(() => outputs.filter((o) => o.stereo), [outputs]);
  const monoOutputs = useMemo(() => outputs.filter((o) => !o.stereo), [outputs]);

  if (isLoading) {
    return (
      <div className="py-8 flex justify-center">
        <Loader2 size={24} className="animate-spin text-text-muted" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="py-8 text-center text-error-text text-sm">{error}</div>
    );
  }

  return (
    <div className="space-y-2">
      {/* Header */}
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium text-text-primary">{prompt}</span>
        <button
          onClick={onCancel}
          className="text-xs text-text-muted px-2 py-1 rounded hover:bg-bg-elevated"
        >
          Cancel
        </button>
      </div>

      {/* Output channel list */}
      <div className="max-h-64 overflow-y-auto space-y-0.5">
        {outputs.length === 0 && (
          <p className="text-center text-text-muted text-sm py-4">
            No output channels available
          </p>
        )}

        {/* Stereo pairs */}
        {stereoOutputs.length > 0 && (
          <>
            <p className="text-xs text-text-muted px-3 pt-1">Stereo</p>
            {stereoOutputs.map((output) => (
              <button
                key={`s-${output.destChan}`}
                onClick={() => onSelect(output.destChan)}
                className={`w-full text-left px-3 py-2.5 rounded-lg text-sm transition-colors ${
                  currentDestChannel === output.destChan
                    ? 'bg-hardware-primary/20 text-text-primary'
                    : 'hover:bg-bg-elevated active:bg-bg-surface text-text-primary'
                }`}
              >
                {output.name}
              </button>
            ))}
          </>
        )}

        {/* Mono outputs */}
        {monoOutputs.length > 0 && (
          <>
            <p className="text-xs text-text-muted px-3 pt-2">Mono</p>
            {monoOutputs.map((output) => (
              <button
                key={`m-${output.destChan}`}
                onClick={() => onSelect(output.destChan)}
                className={`w-full text-left px-3 py-2.5 rounded-lg text-sm transition-colors ${
                  currentDestChannel === output.destChan
                    ? 'bg-hardware-primary/20 text-text-primary'
                    : 'hover:bg-bg-elevated active:bg-bg-surface text-text-primary'
                }`}
              >
                {output.name}
              </button>
            ))}
          </>
        )}
      </div>
    </div>
  );
}
