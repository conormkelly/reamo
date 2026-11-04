/**
 * Routing drags address their track by the GUID locked at gesture start.
 *
 * The routing modal and the mixer's send faders follow a track index. If the
 * user inserts a track above mid-drag, that index names another track; the
 * drag's gesture/start, every volume or pan value and gesture/end must still
 * name the track the drag began on, by trackGuid.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/react';
import type { ReactElement } from 'react';

// Vitest 4.x: setup.ts pre-caches modules before vi.mock can intercept.
// resetModules forces re-evaluation so mocks apply to transitive imports.
vi.hoisted(() => vi.resetModules());

const mockSendCommand = vi.fn();

vi.mock('../../../hooks/useReaper', () => ({
  useReaper: vi.fn(() => ({ sendCommand: mockSendCommand, sendCommandAsync: vi.fn() })),
}));

/** Track GUIDs by index, as the track skeleton reports them right now. */
const guidAt: Record<number, string> = {};

vi.mock('../../../hooks/useTrack', () => ({
  useTrack: vi.fn((idx: number) => ({ guid: guidAt[idx] })),
}));

vi.mock('../../../hooks/useSends', () => ({
  useSends: vi.fn(() => ({
    getSendByDestination: (src: number, dest: number) =>
      src === 2 && dest === 5
        ? { srcTrackIdx: 2, destTrackIdx: 5, sendIndex: 0, volume: 0.5, pan: 0, muted: false, mode: 0 }
        : undefined,
  })),
}));

import { SendsTab } from './SendsTab';
import { ReceivesTab } from './ReceivesTab';
import { HardwareTab } from './HardwareTab';
import { SendFader } from '../SendFader';

const VOCALS = '{VOCALS}';
const GUITAR = '{GUITAR}';
const CLICK = '{CLICK}';

const route = { srcTrackIdx: 2, destTrackIdx: 5, sendIndex: 0, volume: 0.5, pan: 0, muted: false, mode: 0 };

/** Each routing control: how to render it at track index 2, and the element to drag. */
const cases: { name: string; render: () => ReactElement; handle: string; command: string }[] = [
  {
    name: 'send volume (routing modal)',
    render: () => <SendsTab trackIndex={2} trackGuid={GUITAR} sends={[{ ...route, destName: 'Bus' }]} trackNameLookup={{}} />,
    handle: 'Level - double-tap to reset to 0dB',
    command: 'send/setVolume',
  },
  {
    name: 'send pan (routing modal)',
    render: () => <SendsTab trackIndex={2} trackGuid={GUITAR} sends={[{ ...route, destName: 'Bus' }]} trackNameLookup={{}} />,
    handle: 'Pan - double-tap to center',
    command: 'send/setPan',
  },
  {
    name: 'receive volume',
    render: () => <ReceivesTab trackIndex={2} trackGuid={GUITAR} receives={[{ ...route, srcName: 'Keys' }]} trackNameLookup={{}} />,
    handle: 'Level - double-tap to reset to 0dB',
    command: 'receive/setVolume',
  },
  {
    name: 'receive pan',
    render: () => <ReceivesTab trackIndex={2} trackGuid={GUITAR} receives={[{ ...route, srcName: 'Keys' }]} trackNameLookup={{}} />,
    handle: 'Pan - double-tap to center',
    command: 'receive/setPan',
  },
  {
    name: 'hardware output volume',
    render: () => (
      <HardwareTab trackIndex={2} trackGuid={GUITAR} hwOutputs={[{ hwIdx: 0, destChannel: 0, volume: 0.5, pan: 0, muted: false, mode: 0 }]} hwOutCount={2} />
    ),
    handle: 'Level - double-tap to reset to 0dB',
    command: 'hw/setVolume',
  },
  {
    name: 'hardware output pan',
    render: () => (
      <HardwareTab trackIndex={2} trackGuid={GUITAR} hwOutputs={[{ hwIdx: 0, destChannel: 0, volume: 0.5, pan: 0, muted: false, mode: 0 }]} hwOutCount={2} />
    ),
    handle: 'Pan - double-tap to center',
    command: 'hw/setPan',
  },
  {
    name: 'mixer send fader',
    render: () => <SendFader trackIndex={2} destTrackIdx={5} />,
    handle: 'Send level - double-tap to reset to 0dB',
    command: 'send/setVolume',
  },
];

type Sent = { command: string; params?: Record<string, unknown> };
const sent = (): Sent[] => mockSendCommand.mock.calls.map(([cmd]) => cmd as Sent);

describe('routing drags while a track is inserted above', () => {
  let restoreRect: () => void;

  beforeEach(() => {
    vi.clearAllMocks();
    Object.assign(guidAt, { 1: VOCALS, 2: GUITAR });
    const original = Element.prototype.getBoundingClientRect;
    Element.prototype.getBoundingClientRect = () => ({ left: 0, top: 0, width: 200, height: 200, right: 200, bottom: 200, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
    restoreRect = () => {
      Element.prototype.getBoundingClientRect = original;
    };
  });

  afterEach(() => {
    restoreRect();
    cleanup();
  });

  it.each(cases)('$name: the gesture and every value name the track the drag began on', (c) => {
    const { rerender } = render(c.render());
    fireEvent.mouseDown(screen.getByTitle(c.handle), { clientX: 50, clientY: 50 });
    fireEvent.mouseMove(document, { clientX: 80, clientY: 40 });

    // The user inserts a track at the top: index 2 is now Vocals.
    Object.assign(guidAt, { 1: CLICK, 2: VOCALS, 3: GUITAR });
    rerender(c.render());
    fireEvent.mouseMove(document, { clientX: 120, clientY: 30 });
    fireEvent.mouseUp(document);

    const commands = sent();
    const values = commands.filter((cmd) => cmd.command === c.command);
    const gestures = commands.filter((cmd) => cmd.command.startsWith('gesture/'));
    expect(values.length).toBeGreaterThanOrEqual(3);
    for (const value of values) {
      expect(value.params).toMatchObject({ trackGuid: GUITAR });
      expect(value.params).not.toHaveProperty('trackIdx');
    }
    expect(gestures.map((g) => [g.command, g.params?.trackGuid])).toEqual([
      ['gesture/start', GUITAR],
      ['gesture/end', GUITAR],
    ]);
  });
});
