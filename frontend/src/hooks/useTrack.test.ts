/**
 * Tests for useTrack — derived state from track data + command builders.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useReaperStore } from '../store';
import { useTrack } from './useTrack';
import { TrackFlags } from '../core/types';
import type { Track } from '../core/types';

function makeTrack(overrides?: Partial<Track>): Track {
  return {
    index: 1,
    guid: '{TRACK-1}',
    name: 'Guitar',
    flags: 0,
    volume: 1, // 0dB
    pan: 0,
    lastMeterPeak: 0,
    lastMeterPos: 0,
    clipped: false,
    width: 0,
    panMode: 0,
    sendCount: 0,
    receiveCount: 0,
    hwOutCount: 0,
    fxCount: 0,
    color: 0,
    ...overrides,
  };
}

describe('useTrack', () => {
  beforeEach(() => {
    useReaperStore.setState({ tracks: {} });
  });

  // ===========================================================================
  // Null / missing track
  // ===========================================================================

  describe('missing track', () => {
    it('returns defaults when track does not exist', () => {
      const { result } = renderHook(() => useTrack(99));
      expect(result.current.exists).toBe(false);
      expect(result.current.track).toBeNull();
      expect(result.current.name).toBe('');
      expect(result.current.volumeDb).toBe('-inf dB');
      expect(result.current.faderPosition).toBe(0);
      expect(result.current.panDisplay).toBe('center');
      expect(result.current.isMuted).toBe(false);
      expect(result.current.isSoloed).toBe(false);
      expect(result.current.isRecordArmed).toBe(false);
      expect(result.current.recordMonitorState).toBe('off');
    });
  });

  // ===========================================================================
  // Derived state
  // ===========================================================================

  describe('derived state', () => {
    it('derives name and volume from track', () => {
      useReaperStore.setState({ tracks: { 1: makeTrack() } });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.exists).toBe(true);
      expect(result.current.name).toBe('Guitar');
      expect(result.current.volumeDb).toBe('0.00 dB');
    });

    it('derives pan display from track', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ pan: -0.5 }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.panDisplay).toBe('50%L');
    });

    it('derives mute flag', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ flags: TrackFlags.MUTED }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.isMuted).toBe(true);
      expect(result.current.isSoloed).toBe(false);
    });

    it('derives solo flag', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ flags: TrackFlags.SOLOED }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.isSoloed).toBe(true);
    });

    it('derives record arm flag', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ flags: TrackFlags.RECORD_ARMED }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.isRecordArmed).toBe(true);
    });

    it('derives record monitor state (on)', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ flags: TrackFlags.RECORD_MONITOR_ON }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.recordMonitorState).toBe('on');
    });

    it('derives record monitor state (auto)', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ flags: TrackFlags.RECORD_MONITOR_AUTO }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.recordMonitorState).toBe('auto');
    });

    it('derives FX disabled from flag', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ flags: TrackFlags.FX_DISABLED, fxCount: 3 }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.isFxDisabled).toBe(true);
      expect(result.current.fxCount).toBe(3);
    });

    it('derives color as hex', () => {
      // 0x01ff5500 = REAPER color for #ff5500
      useReaperStore.setState({
        tracks: { 1: makeTrack({ color: 0x01ff5500 }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.color).toBe('#ff5500');
    });

    it('returns null color when no custom color', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ color: 0 }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.color).toBeNull();
    });

    it('provides GUID', () => {
      useReaperStore.setState({ tracks: { 1: makeTrack() } });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.guid).toBe('{TRACK-1}');
    });

    it('provides recInput when present', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ recInput: 1024 }) },
      });
      const { result } = renderHook(() => useTrack(1));
      expect(result.current.recInput).toBe(1024);
    });
  });

  // ===========================================================================
  // Command builders
  // ===========================================================================

  describe('command builders', () => {
    it('toggleMute returns setMute command with GUID', () => {
      useReaperStore.setState({ tracks: { 1: makeTrack() } });
      const { result } = renderHook(() => useTrack(1));
      const cmd = result.current.toggleMute();
      expect(cmd.command).toBe('track/setMute');
      expect(cmd.params).toEqual({ trackGuid: '{TRACK-1}', mute: undefined });
    });

    it('toggleSolo returns setSolo command with GUID', () => {
      useReaperStore.setState({ tracks: { 1: makeTrack() } });
      const { result } = renderHook(() => useTrack(1));
      const cmd = result.current.toggleSolo();
      expect(cmd.command).toBe('track/setSolo');
      expect(cmd.params).toEqual({ trackGuid: '{TRACK-1}', solo: undefined });
    });

    it('toggleRecordArm returns setRecArm command', () => {
      useReaperStore.setState({ tracks: { 1: makeTrack() } });
      const { result } = renderHook(() => useTrack(1));
      const cmd = result.current.toggleRecordArm();
      expect(cmd.command).toBe('track/setRecArm');
      expect(cmd.params).toHaveProperty('trackGuid', '{TRACK-1}');
    });

    it('setVolume returns setVolume command with linear value', () => {
      useReaperStore.setState({ tracks: { 1: makeTrack() } });
      const { result } = renderHook(() => useTrack(1));
      const cmd = result.current.setVolume(0.5);
      expect(cmd.command).toBe('track/setVolume');
      expect(cmd.params).toEqual({ trackGuid: '{TRACK-1}', volume: 0.5 });
    });

    it('setFaderPosition converts position to volume', () => {
      useReaperStore.setState({ tracks: { 1: makeTrack() } });
      const { result } = renderHook(() => useTrack(1));
      const cmd = result.current.setFaderPosition(1.0);
      expect(cmd.command).toBe('track/setVolume');
      // faderToVolume(1.0) = 1^4 * 4 = 4
      expect(cmd.params).toEqual({ trackGuid: '{TRACK-1}', volume: 4 });
    });

    it('setPan returns setPan command', () => {
      useReaperStore.setState({ tracks: { 1: makeTrack() } });
      const { result } = renderHook(() => useTrack(1));
      const cmd = result.current.setPan(-0.5);
      expect(cmd.command).toBe('track/setPan');
      expect(cmd.params).toEqual({ trackGuid: '{TRACK-1}', pan: -0.5 });
    });

    it('uses trackIndex when GUID is unavailable', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ guid: undefined as unknown as string }) },
      });
      const { result } = renderHook(() => useTrack(1));
      const cmd = result.current.toggleMute();
      // When guid is undefined/falsy, command builder falls back to trackIdx
      expect(cmd.command).toBe('track/setMute');
      expect(cmd.params).toHaveProperty('trackIdx', 1);
    });
  });
});
