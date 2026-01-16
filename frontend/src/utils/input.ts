/**
 * Input selection utilities for REAPER I_RECINPUT encoding
 * Based on research/REC_INPUT_SELECTION.md bitfield specification
 *
 * Audio encoding (bit 12 NOT set):
 *   - Bits 0-9: Input channel index (0-indexed)
 *   - Bit 10 (1024): Stereo flag
 *   - Bit 11 (2048): Multichannel flag
 *   - Channel indices 512+ indicate ReaRoute
 *
 * MIDI encoding (bit 12 IS set):
 *   - Bits 0-4: Channel (0=all, 1-16=specific)
 *   - Bits 5-10: Device index (0-61=hardware, 62=VKB, 63=all inputs)
 */

import type { InputConfig } from '../core/types';
import { MidiDeviceIndex } from '../core/types';

// Bitfield constants
const MIDI_FLAG = 4096; // Bit 12
const STEREO_FLAG = 1024; // Bit 10
const MULTICHANNEL_FLAG = 2048; // Bit 11
const REAROUTE_OFFSET = 512;

/**
 * Check if raw I_RECINPUT value represents MIDI input
 */
export function isMidiInput(value: number): boolean {
  return (value & MIDI_FLAG) !== 0;
}

/**
 * Decode raw I_RECINPUT value to structured InputConfig
 */
export function decodeRecInput(value: number): InputConfig {
  if (value < 0) {
    return { type: 'none', raw: value };
  }

  if (value & MIDI_FLAG) {
    // MIDI input
    const channel = value & 0x1f; // bits 0-4
    const device = (value >> 5) & 0x3f; // bits 5-10
    return {
      type: 'midi',
      raw: value,
      channel,
      device,
      isVKB: device === MidiDeviceIndex.VIRTUAL_KEYBOARD,
      isAll: device === MidiDeviceIndex.ALL_INPUTS,
    };
  }

  // Audio input
  const channelIndex = value & 0x3ff; // bits 0-9
  const stereo = (value & STEREO_FLAG) !== 0;
  const multi = (value & MULTICHANNEL_FLAG) !== 0;
  const rearoute = channelIndex >= REAROUTE_OFFSET;

  return {
    type: 'audio',
    raw: value,
    channel: rearoute ? channelIndex - REAROUTE_OFFSET : channelIndex,
    stereo,
    multi,
    rearoute,
  };
}

/**
 * Encode audio input to raw I_RECINPUT value
 */
export function encodeAudioInput(
  channelIndex: number,
  stereo = false,
  multi = false,
  rearoute = false
): number {
  let value = channelIndex;
  if (rearoute) value += REAROUTE_OFFSET;
  if (multi) value += MULTICHANNEL_FLAG;
  else if (stereo) value += STEREO_FLAG;
  return value;
}

/**
 * Encode MIDI input to raw I_RECINPUT value
 */
export function encodeMidiInput(deviceIndex: number, channel = 0): number {
  return MIDI_FLAG + channel + (deviceIndex << 5);
}

/**
 * Format raw I_RECINPUT value to compact display label
 * Examples: "In 1/2", "In 3 (mono)", "MIDI All", "MIDI VKB", "No Input"
 */
export function formatInputLabel(recInput: number | undefined): string {
  if (recInput === undefined || recInput < 0) {
    return 'No Input';
  }

  const config = decodeRecInput(recInput);

  if (config.type === 'none') {
    return 'No Input';
  }

  if (config.type === 'midi') {
    // MIDI input
    let deviceLabel: string;
    if (config.isAll) {
      deviceLabel = 'All';
    } else if (config.isVKB) {
      deviceLabel = 'VKB';
    } else {
      deviceLabel = `Dev ${config.device}`;
    }

    const channelLabel = config.channel === 0 ? '' : ` Ch${config.channel}`;
    return `MIDI ${deviceLabel}${channelLabel}`;
  }

  // Audio input
  const channel = config.channel ?? 0;
  const prefix = config.rearoute ? 'RR ' : 'In ';

  if (config.multi) {
    return `${prefix}${channel + 1}+ (multi)`;
  }

  if (config.stereo) {
    // Stereo pair: show as "1/2", "3/4", etc.
    return `${prefix}${channel + 1}/${channel + 2}`;
  }

  // Mono
  return `${prefix}${channel + 1}`;
}

/**
 * Format MIDI device name for display in selector
 * Returns friendly name for special devices, otherwise the hardware name
 */
export function formatMidiDeviceName(
  deviceIndex: number,
  hardwareName?: string
): string {
  if (deviceIndex === MidiDeviceIndex.ALL_INPUTS) {
    return 'All MIDI Inputs';
  }
  if (deviceIndex === MidiDeviceIndex.VIRTUAL_KEYBOARD) {
    return 'Virtual MIDI Keyboard';
  }
  return hardwareName ?? `MIDI Device ${deviceIndex + 1}`;
}

/**
 * Format MIDI channel for display
 */
export function formatMidiChannel(channel: number): string {
  return channel === 0 ? 'All Channels' : `Channel ${channel}`;
}
