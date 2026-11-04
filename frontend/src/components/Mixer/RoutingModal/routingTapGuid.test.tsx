/**
 * Routing taps name their track by GUID.
 *
 * A tap (double-tap reset, mute, mode, output destination) acts on the row
 * the user sees, with a value worked out from that row's state. Sent by
 * track index, a tap made just after a track was inserted above, before the
 * new track list arrives, would reach the track that moved into the index.
 * Each tap sends the GUID of the track shown, and no trackIdx.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent, waitFor } from '@testing-library/react';
import type { ReactElement } from 'react';

// Vitest 4.x: setup.ts pre-caches modules before vi.mock can intercept.
// resetModules forces re-evaluation so mocks apply to transitive imports.
vi.hoisted(() => vi.resetModules());

const mockSendCommand = vi.fn();
const mockSendCommandAsync = vi.fn();

vi.mock('../../../hooks/useReaper', () => ({
  useReaper: vi.fn(() => ({ sendCommand: mockSendCommand, sendCommandAsync: mockSendCommandAsync })),
}));

const GUITAR = '{GUITAR}';

vi.mock('../../../hooks/useTrack', () => ({
  useTrack: vi.fn((idx: number) => ({ guid: idx === 2 ? GUITAR : undefined })),
}));

const slot = { srcTrackIdx: 2, destTrackIdx: 5, sendIndex: 0, volume: 0.5, pan: 0.3, muted: false, mode: 0 };

vi.mock('../../../hooks/useSends', () => ({
  useSends: vi.fn(() => ({
    getSendByDestination: (src: number, dest: number) => (src === 2 && dest === 5 ? slot : undefined),
  })),
}));

import { SendsTab } from './SendsTab';
import { ReceivesTab } from './ReceivesTab';
import { HardwareTab } from './HardwareTab';
import { SendFader } from '../SendFader';
import { SendMuteButton } from '../SendMuteButton';
import { formatHwOutputName } from './routingUtils';

const sendsTab = () => <SendsTab trackIndex={2} trackGuid={GUITAR} sends={[{ ...slot, destName: 'Bus' }]} trackNameLookup={{}} />;
const receivesTab = () => <ReceivesTab trackIndex={2} trackGuid={GUITAR} receives={[{ ...slot, srcName: 'Keys' }]} trackNameLookup={{}} />;
const hwOutput = { hwIdx: 0, destChannel: 0, volume: 0.5, pan: 0.3, muted: false, mode: 0 };
const hardwareTab = () => <HardwareTab trackIndex={2} trackGuid={GUITAR} hwOutputs={[hwOutput]} hwOutCount={1} />;

type Sent = { command: string; params?: Record<string, unknown> };
const sent = (command: string): Sent[] =>
  mockSendCommand.mock.calls.map(([cmd]) => cmd as Sent).filter((cmd) => cmd.command === command);

/** The one `command` the tap sent: addressed by Guitar's GUID, not by index. */
function expectSentByGuid(command: string, value: Record<string, unknown>): void {
  const cmds = sent(command);
  expect(cmds).toHaveLength(1);
  expect(cmds[0].params).toMatchObject({ trackGuid: GUITAR, ...value });
  expect(cmds[0].params).not.toHaveProperty('trackIdx');
}

function doubleTap(title: string): void {
  const el = screen.getByTitle(title);
  fireEvent.mouseDown(el, { clientX: 10, clientY: 10 });
  fireEvent.mouseUp(document);
  mockSendCommand.mockClear(); // the first tap is a short drag; keep only the reset
  fireEvent.mouseDown(el, { clientX: 10, clientY: 10 });
}

const LEVEL = 'Level - double-tap to reset to 0dB';
const PAN = 'Pan - double-tap to center';

describe('routing taps', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockSendCommandAsync.mockImplementation(async (cmd: Sent) => {
      if (cmd.command === 'hw/listOutputs') {
        return { success: true, payload: { outputs: [{ destChan: 2, name: 'Out 3/4', stereo: true }] } };
      }
      if (cmd.command === 'hw/add') return { success: true, payload: { hwIdx: 1 } };
      return { success: true };
    });
  });

  afterEach(cleanup);

  const resets: { name: string; render: () => ReactElement; title: string; command: string; value: Record<string, unknown> }[] = [
    { name: 'send volume', render: sendsTab, title: LEVEL, command: 'send/setVolume', value: { volume: 1 } },
    { name: 'send pan', render: sendsTab, title: PAN, command: 'send/setPan', value: { pan: 0 } },
    { name: 'receive volume', render: receivesTab, title: LEVEL, command: 'receive/setVolume', value: { volume: 1 } },
    { name: 'receive pan', render: receivesTab, title: PAN, command: 'receive/setPan', value: { pan: 0 } },
    { name: 'hardware output volume', render: hardwareTab, title: LEVEL, command: 'hw/setVolume', value: { volume: 1 } },
    { name: 'hardware output pan', render: hardwareTab, title: PAN, command: 'hw/setPan', value: { pan: 0 } },
    {
      name: 'mixer send fader',
      render: () => <SendFader trackIndex={2} destTrackIdx={5} />,
      title: 'Send level - double-tap to reset to 0dB',
      command: 'send/setVolume',
      value: { volume: 1 },
    },
  ];

  it.each(resets)('$name: a double-tap reset names the track shown by GUID', (c) => {
    render(c.render());
    doubleTap(c.title);
    expectSentByGuid(c.command, c.value);
  });

  const toggles: { name: string; render: () => ReactElement; title: string; command: string; value: Record<string, unknown> }[] = [
    { name: 'send mute', render: sendsTab, title: 'Mute', command: 'send/setMute', value: { muted: 1 } },
    { name: 'send mode', render: sendsTab, title: 'Mode: Post - tap to cycle', command: 'send/setMode', value: {} },
    { name: 'receive mute', render: receivesTab, title: 'Mute', command: 'receive/setMute', value: { muted: 1 } },
    { name: 'receive mode', render: receivesTab, title: 'Mode: Post - tap to cycle', command: 'receive/setMode', value: {} },
    { name: 'hardware output mute', render: hardwareTab, title: 'Mute', command: 'hw/setMute', value: { muted: 1 } },
    { name: 'hardware output mode', render: hardwareTab, title: 'Mode: Post - tap to cycle', command: 'hw/setMode', value: {} },
    {
      name: 'mixer send mute',
      render: () => <SendMuteButton trackIndex={2} destTrackIdx={5} />,
      title: 'Mute send',
      command: 'send/setMute',
      value: { muted: 1 },
    },
  ];

  it.each(toggles)('$name: the tap names the track shown by GUID', (c) => {
    render(c.render());
    fireEvent.click(screen.getByTitle(c.title));
    expectSentByGuid(c.command, c.value);
  });

  it("changing a hardware output's destination names the track shown by GUID", async () => {
    render(hardwareTab());
    fireEvent.click(screen.getByTitle(`${formatHwOutputName(0)} - tap to change`));
    fireEvent.click(await screen.findByText('Out 3/4'));
    expectSentByGuid('hw/setDestChannel', { hwIdx: 0, destChannel: 2 });
  });

  it("a new hardware output's destination names the track it was added to by GUID", async () => {
    render(<HardwareTab trackIndex={2} trackGuid={GUITAR} hwOutputs={[]} hwOutCount={0} />);
    fireEvent.click(screen.getByText('+ Add Hardware Output'));
    fireEvent.click(await screen.findByText('Out 3/4'));
    await waitFor(() => expect(sent('hw/setDestChannel')).toHaveLength(1));
    expectSentByGuid('hw/setDestChannel', { hwIdx: 1, destChannel: 2 });
  });
});
