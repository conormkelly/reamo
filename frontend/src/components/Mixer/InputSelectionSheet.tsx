/**
 * InputSelectionSheet - Select audio/MIDI input for a track
 * Opens via long-press on RecordArmButton.
 * Fetches available inputs on-demand via input/enumerate* commands.
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { Loader2, Check, X, ChevronDown } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useTrack } from '../../hooks/useTrack';
import { useReaper } from '../ReaperProvider';
import { input as inputCmd, track as trackCmd } from '../../core/WebSocketCommands';
import type { AudioInput, MidiDevice, InputConfig } from '../../core/types';
import { MidiDeviceIndex } from '../../core/types';
import {
  decodeRecInput,
  formatMidiDeviceName,
  formatMidiChannel,
} from '../../utils/input';

export interface InputSelectionSheetProps {
  isOpen: boolean;
  onClose: () => void;
  trackIndex: number;
  trackGuid: string;
}

type TabId = 'audio' | 'midi' | 'none';
type AudioMode = 'mono' | 'stereo';

/** Response from input/enumerateAudio */
interface EnumerateAudioResponse {
  success?: boolean;
  payload?: { inputs?: AudioInput[] };
  error?: { message?: string };
}

/** Response from input/enumerateMidi */
interface EnumerateMidiResponse {
  success?: boolean;
  payload?: { devices?: MidiDevice[] };
  error?: { message?: string };
}

export function InputSelectionSheet({
  isOpen,
  onClose,
  trackIndex,
  trackGuid,
}: InputSelectionSheetProps): ReactElement {
  const { sendCommandAsync } = useReaper();
  const { name: trackName, recInput } = useTrack(trackIndex);

  // UI state
  const [activeTab, setActiveTab] = useState<TabId>('audio');
  const [audioMode, setAudioMode] = useState<AudioMode>('mono');
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Cached input lists
  const [audioInputs, setAudioInputs] = useState<AudioInput[]>([]);
  const [midiDevices, setMidiDevices] = useState<MidiDevice[]>([]);

  // Current input config (decoded)
  const [currentInput, setCurrentInput] = useState<InputConfig | null>(null);

  // MIDI state: selected device (null = show device list, number = show channel picker)
  const [selectedMidiDevice, setSelectedMidiDevice] = useState<number | null>(null);
  const [selectedMidiChannel, setSelectedMidiChannel] = useState<number>(0);
  const [showChannelDropdown, setShowChannelDropdown] = useState(false);

  // Decode current input from track data
  useEffect(() => {
    if (recInput !== undefined) {
      const decoded = decodeRecInput(recInput);
      setCurrentInput(decoded);
      // Set initial tab and state based on current input type
      if (decoded.type === 'midi') {
        setActiveTab('midi');
        setSelectedMidiDevice(decoded.device ?? null);
        setSelectedMidiChannel(decoded.channel ?? 0);
      } else if (decoded.type === 'none') {
        setActiveTab('none');
      } else if (decoded.type === 'audio') {
        setActiveTab('audio');
        setAudioMode(decoded.stereo ? 'stereo' : 'mono');
      }
    } else {
      setCurrentInput(null);
    }
  }, [recInput]);

  // Fetch input lists when sheet opens
  const fetchInputLists = useCallback(async () => {
    setIsLoading(true);
    setError(null);

    try {
      const [audioRes, midiRes] = await Promise.all([
        sendCommandAsync(inputCmd.enumerateAudio()) as Promise<EnumerateAudioResponse>,
        sendCommandAsync(inputCmd.enumerateMidi()) as Promise<EnumerateMidiResponse>,
      ]);

      if (audioRes.success && audioRes.payload?.inputs) {
        setAudioInputs(audioRes.payload.inputs);
      }
      if (midiRes.success && midiRes.payload?.devices) {
        setMidiDevices(midiRes.payload.devices);
      }
    } catch (err) {
      console.error('[InputSelectionSheet] Failed to fetch inputs:', err);
      setError(err instanceof Error ? err.message : 'Failed to fetch input list');
    } finally {
      setIsLoading(false);
    }
  }, [sendCommandAsync]);

  useEffect(() => {
    if (isOpen) {
      fetchInputLists();
    } else {
      // Reset state when closing
      setSelectedMidiDevice(null);
      setShowChannelDropdown(false);
    }
  }, [isOpen, fetchInputLists]);

  // Set input to "No Input"
  const handleSetNoInput = useCallback(async () => {
    await sendCommandAsync(
      trackCmd.setInput({
        trackGuid,
        inputType: 'none',
      })
    );
    onClose();
  }, [sendCommandAsync, trackGuid, onClose]);

  // Set audio input
  const handleSetAudioInput = useCallback(
    async (channelIndex: number, stereo: boolean) => {
      await sendCommandAsync(
        trackCmd.setInput({
          trackGuid,
          inputType: 'audio',
          channel: channelIndex,
          stereo,
        })
      );
      onClose();
    },
    [sendCommandAsync, trackGuid, onClose]
  );

  // Set MIDI input
  const handleSetMidiInput = useCallback(
    async (deviceIndex: number, channel: number) => {
      await sendCommandAsync(
        trackCmd.setInput({
          trackGuid,
          inputType: 'midi',
          device: deviceIndex,
          channel,
        })
      );
      onClose();
    },
    [sendCommandAsync, trackGuid, onClose]
  );

  // Check if an audio option is currently selected
  const isAudioSelected = (channelIndex: number, stereo: boolean): boolean => {
    if (!currentInput || currentInput.type !== 'audio') return false;
    return (
      currentInput.channel === channelIndex &&
      currentInput.stereo === stereo &&
      !currentInput.rearoute
    );
  };

  // Build mono input options
  const monoOptions = audioInputs.map((input) => ({
    channelIndex: input.idx,
    label: input.name,
  }));

  // Build stereo input options (pairs of consecutive even/odd channels)
  const stereoOptions: { channelIndex: number; label: string }[] = [];
  for (let i = 0; i < audioInputs.length - 1; i += 2) {
    const left = audioInputs[i];
    const right = audioInputs[i + 1];
    if (left && right && left.idx % 2 === 0 && right.idx === left.idx + 1) {
      stereoOptions.push({
        channelIndex: left.idx,
        label: `${left.name} + ${right.name}`,
      });
    }
  }

  // Build MIDI device list - backend already includes special devices (62, 63)
  // Sort to put "All MIDI Inputs" (63) first, then "Virtual Keyboard" (62), then hardware
  const midiDeviceOptions: { idx: number; name: string }[] = midiDevices
    .map((d) => ({
      idx: d.idx,
      name: d.idx === MidiDeviceIndex.ALL_INPUTS || d.idx === MidiDeviceIndex.VIRTUAL_KEYBOARD
        ? formatMidiDeviceName(d.idx)
        : d.name,
    }))
    .sort((a, b) => {
      // All MIDI Inputs first
      if (a.idx === MidiDeviceIndex.ALL_INPUTS) return -1;
      if (b.idx === MidiDeviceIndex.ALL_INPUTS) return 1;
      // Virtual Keyboard second
      if (a.idx === MidiDeviceIndex.VIRTUAL_KEYBOARD) return -1;
      if (b.idx === MidiDeviceIndex.VIRTUAL_KEYBOARD) return 1;
      // Rest by index
      return a.idx - b.idx;
    });

  // MIDI channel options for dropdown
  const midiChannelOptions = [
    { value: 0, label: formatMidiChannel(0) },
    ...Array.from({ length: 16 }, (_, i) => ({
      value: i + 1,
      label: formatMidiChannel(i + 1),
    })),
  ];

  // Get display name for selected MIDI device
  const getSelectedDeviceName = (): string => {
    if (selectedMidiDevice === null) return '';
    return formatMidiDeviceName(
      selectedMidiDevice,
      midiDevices.find((d) => d.idx === selectedMidiDevice)?.name
    );
  };

  const tabClass = (tab: TabId) =>
    `flex-1 py-2 px-3 rounded-lg text-sm font-medium transition-colors border ${
      activeTab === tab
        ? 'bg-primary/20 text-primary border-primary/50'
        : 'bg-bg-surface text-text-secondary border-border-subtle hover:bg-bg-hover'
    }`;

  const audioModeClass = (mode: AudioMode) =>
    `flex-1 py-1.5 px-3 rounded text-xs font-medium transition-colors ${
      audioMode === mode
        ? 'bg-primary text-text-on-primary'
        : 'text-text-secondary hover:bg-bg-hover'
    }`;

  return (
    <BottomSheet
      isOpen={isOpen}
      onClose={onClose}
      ariaLabel={`Input selection for ${trackName || `Track ${trackIndex}`}`}
    >
      <div className="px-4 pb-8">
        {/* Header */}
        <div className="text-center mb-4 pt-1">
          <h2 className="text-lg font-semibold text-text-primary truncate">
            Input: {trackName || `Track ${trackIndex + 1}`}
          </h2>
        </div>

        {/* Top-level tabs: Audio / MIDI / None */}
        <div className="flex gap-2 mb-4" role="tablist">
          <button
            role="tab"
            aria-selected={activeTab === 'audio'}
            onClick={() => setActiveTab('audio')}
            className={tabClass('audio')}
          >
            Audio
          </button>
          <button
            role="tab"
            aria-selected={activeTab === 'midi'}
            onClick={() => setActiveTab('midi')}
            className={tabClass('midi')}
          >
            MIDI
          </button>
          <button
            role="tab"
            aria-selected={activeTab === 'none'}
            onClick={() => {
              setActiveTab('none');
              handleSetNoInput();
            }}
            className={tabClass('none')}
          >
            None
          </button>
        </div>

        {/* Loading state */}
        {isLoading && (
          <div className="py-8 flex justify-center">
            <Loader2 size={24} className="animate-spin text-text-muted" />
          </div>
        )}

        {/* Error state */}
        {error && !isLoading && (
          <div className="py-8 text-center text-error-text text-sm">{error}</div>
        )}

        {/* Audio tab content */}
        {!isLoading && !error && activeTab === 'audio' && (
          <div>
            {/* Mono/Stereo toggle */}
            <div className="flex gap-1 p-1 bg-bg-surface rounded-lg mb-3">
              <button
                onClick={() => setAudioMode('mono')}
                className={audioModeClass('mono')}
              >
                Mono
              </button>
              <button
                onClick={() => setAudioMode('stereo')}
                className={audioModeClass('stereo')}
              >
                Stereo
              </button>
            </div>

            {/* Scrollable input list */}
            <div className="max-h-64 overflow-y-auto -mx-4 px-4 space-y-1">
              {audioMode === 'mono' ? (
                monoOptions.length === 0 ? (
                  <div className="py-8 text-center text-text-muted text-sm">
                    No audio inputs available
                  </div>
                ) : (
                  monoOptions.map((opt) => (
                    <button
                      key={opt.channelIndex}
                      onClick={() => handleSetAudioInput(opt.channelIndex, false)}
                      className={`w-full flex items-center justify-between py-3 px-3 rounded-lg transition-colors ${
                        isAudioSelected(opt.channelIndex, false)
                          ? 'bg-accent/20 text-text-primary'
                          : 'bg-bg-surface text-text-secondary hover:bg-bg-hover'
                      }`}
                    >
                      <span className="text-sm">{opt.label}</span>
                      {isAudioSelected(opt.channelIndex, false) && (
                        <Check size={18} className="text-accent" />
                      )}
                    </button>
                  ))
                )
              ) : stereoOptions.length === 0 ? (
                <div className="py-8 text-center text-text-muted text-sm">
                  No stereo pairs available
                </div>
              ) : (
                stereoOptions.map((opt) => (
                  <button
                    key={opt.channelIndex}
                    onClick={() => handleSetAudioInput(opt.channelIndex, true)}
                    className={`w-full flex items-center justify-between py-3 px-3 rounded-lg transition-colors ${
                      isAudioSelected(opt.channelIndex, true)
                        ? 'bg-accent/20 text-text-primary'
                        : 'bg-bg-surface text-text-secondary hover:bg-bg-hover'
                    }`}
                  >
                    <span className="text-sm">{opt.label}</span>
                    {isAudioSelected(opt.channelIndex, true) && (
                      <Check size={18} className="text-accent" />
                    )}
                  </button>
                ))
              )}
            </div>
          </div>
        )}

        {/* MIDI tab content */}
        {!isLoading && !error && activeTab === 'midi' && (
          <div>
            {selectedMidiDevice === null ? (
              // Device selection list
              <div className="max-h-64 overflow-y-auto -mx-4 px-4 space-y-1">
                {midiDeviceOptions.map((device) => (
                  <button
                    key={device.idx}
                    onClick={() => {
                      setSelectedMidiDevice(device.idx);
                      // If current input matches this device, use its channel
                      if (currentInput?.type === 'midi' && currentInput.device === device.idx) {
                        setSelectedMidiChannel(currentInput.channel ?? 0);
                      } else {
                        setSelectedMidiChannel(0); // Default to "All Channels"
                      }
                    }}
                    className={`w-full flex items-center justify-between py-3 px-3 rounded-lg transition-colors ${
                      currentInput?.type === 'midi' && currentInput.device === device.idx
                        ? 'bg-accent/20 text-text-primary'
                        : 'bg-bg-surface text-text-secondary hover:bg-bg-hover'
                    }`}
                  >
                    <span className="text-sm">{device.name}</span>
                    {currentInput?.type === 'midi' && currentInput.device === device.idx && (
                      <Check size={18} className="text-accent" />
                    )}
                  </button>
                ))}
              </div>
            ) : (
              // Device selected - show collapsed device + channel picker
              <div className="space-y-3">
                {/* Selected device chip with X to clear */}
                <div className="flex items-center gap-2 p-3 bg-bg-surface rounded-lg">
                  <span className="flex-1 text-sm text-text-primary font-medium">
                    {getSelectedDeviceName()}
                  </span>
                  <button
                    onClick={() => setSelectedMidiDevice(null)}
                    className="p-1 rounded hover:bg-bg-hover text-text-muted hover:text-text-secondary"
                    aria-label="Change device"
                  >
                    <X size={16} />
                  </button>
                </div>

                {/* Channel dropdown */}
                <div className="relative">
                  <button
                    onClick={() => setShowChannelDropdown(!showChannelDropdown)}
                    className="w-full flex items-center justify-between py-3 px-3 bg-bg-surface rounded-lg text-sm"
                  >
                    <span className="text-text-muted">Channel:</span>
                    <span className="flex items-center gap-2 text-text-primary">
                      {formatMidiChannel(selectedMidiChannel)}
                      <ChevronDown size={16} className={`transition-transform ${showChannelDropdown ? 'rotate-180' : ''}`} />
                    </span>
                  </button>

                  {showChannelDropdown && (
                    <div className="absolute bottom-full left-0 right-0 mb-1 bg-bg-elevated border border-border-subtle rounded-lg shadow-lg z-10 max-h-48 overflow-y-auto">
                      {midiChannelOptions.map((opt) => (
                        <button
                          key={opt.value}
                          onClick={() => {
                            setSelectedMidiChannel(opt.value);
                            setShowChannelDropdown(false);
                          }}
                          className={`w-full flex items-center justify-between py-2 px-3 text-sm transition-colors ${
                            selectedMidiChannel === opt.value
                              ? 'bg-accent/20 text-text-primary'
                              : 'text-text-secondary hover:bg-bg-hover'
                          }`}
                        >
                          <span>{opt.label}</span>
                          {selectedMidiChannel === opt.value && (
                            <Check size={14} className="text-accent" />
                          )}
                        </button>
                      ))}
                    </div>
                  )}
                </div>

                {/* Apply button */}
                <button
                  onClick={() => handleSetMidiInput(selectedMidiDevice, selectedMidiChannel)}
                  className="w-full py-3 px-4 bg-primary text-text-on-primary rounded-lg text-sm font-medium hover:bg-primary/90 transition-colors"
                >
                  Apply
                </button>
              </div>
            )}
          </div>
        )}

        {/* None tab - just confirmation */}
        {!isLoading && !error && activeTab === 'none' && (
          <div className="py-8 text-center text-text-muted text-sm">
            No input selected
          </div>
        )}
      </div>
    </BottomSheet>
  );
}

export default InputSelectionSheet;
