/**
 * Tests for timelineViewSlice - follow playhead state and auto-enable subscription
 *
 * The auto-enable on playback start is handled via store subscription rather than
 * React effects, which is the best practice pattern for zustand.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from '../index';

describe('timelineViewSlice', () => {
  beforeEach(() => {
    // Reset store to initial state
    useReaperStore.setState({
      followPlayhead: true,
      playState: 0,
      followPlayheadReEnable: 'on-playback',
    });
  });

  describe('setFollowPlayhead', () => {
    it('sets followPlayhead to true', () => {
      useReaperStore.getState().setFollowPlayhead(false);
      expect(useReaperStore.getState().followPlayhead).toBe(false);

      useReaperStore.getState().setFollowPlayhead(true);
      expect(useReaperStore.getState().followPlayhead).toBe(true);
    });

    it('sets followPlayhead to false', () => {
      useReaperStore.getState().setFollowPlayhead(false);
      expect(useReaperStore.getState().followPlayhead).toBe(false);
    });
  });

  describe('pauseFollowPlayhead', () => {
    it('disables followPlayhead when currently enabled', () => {
      useReaperStore.setState({ followPlayhead: true });
      useReaperStore.getState().pauseFollowPlayhead();
      expect(useReaperStore.getState().followPlayhead).toBe(false);
    });

    it('does nothing when already disabled', () => {
      useReaperStore.setState({ followPlayhead: false });
      useReaperStore.getState().pauseFollowPlayhead();
      expect(useReaperStore.getState().followPlayhead).toBe(false);
    });
  });

  describe('toggleFollowPlayhead', () => {
    it('toggles from true to false', () => {
      useReaperStore.setState({ followPlayhead: true });
      useReaperStore.getState().toggleFollowPlayhead();
      expect(useReaperStore.getState().followPlayhead).toBe(false);
    });

    it('toggles from false to true', () => {
      useReaperStore.setState({ followPlayhead: false });
      useReaperStore.getState().toggleFollowPlayhead();
      expect(useReaperStore.getState().followPlayhead).toBe(true);
    });
  });

  describe('auto-enable on playback start subscription', () => {
    it('enables followPlayhead when playback starts and preference is on-playback', () => {
      // Setup: follow disabled, preference allows auto-enable
      useReaperStore.setState({
        followPlayhead: false,
        followPlayheadReEnable: 'on-playback',
        playState: 0,
      });

      // Simulate playback start
      useReaperStore.setState({ playState: 1 });

      // Follow should be auto-enabled
      expect(useReaperStore.getState().followPlayhead).toBe(true);
    });

    it('does NOT enable followPlayhead when preference is explicit-only', () => {
      // Setup: follow disabled, preference requires explicit enable
      useReaperStore.setState({
        followPlayhead: false,
        followPlayheadReEnable: 'explicit-only',
        playState: 0,
      });

      // Simulate playback start
      useReaperStore.setState({ playState: 1 });

      // Follow should remain disabled
      expect(useReaperStore.getState().followPlayhead).toBe(false);
    });

    it('does NOT change followPlayhead when playback stops', () => {
      // Setup: following during playback
      useReaperStore.setState({
        followPlayhead: true,
        followPlayheadReEnable: 'on-playback',
        playState: 1,
      });

      // Simulate playback stop
      useReaperStore.setState({ playState: 0 });

      // Follow should remain as-is (true)
      expect(useReaperStore.getState().followPlayhead).toBe(true);
    });

    it('does NOT re-enable when already playing (no state transition)', () => {
      // Setup: follow disabled, already playing
      useReaperStore.setState({
        followPlayhead: false,
        followPlayheadReEnable: 'on-playback',
        playState: 1,
      });

      // User manually disables follow during playback, stays playing
      useReaperStore.getState().pauseFollowPlayhead();

      // Should stay disabled (no playback START transition)
      expect(useReaperStore.getState().followPlayhead).toBe(false);
    });
  });
});
