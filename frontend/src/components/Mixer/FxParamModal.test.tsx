/**
 * FxParamModal skeleton fetching: the parameter names are fetched with
 * trackFx/getParams when the modal opens, and again only when a
 * trackFxParams event reports a different skeleton (nameHash or paramCount).
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, act, waitFor, fireEvent } from '@testing-library/react';

// Vitest 4.x: setup.ts pre-caches modules before vi.mock can intercept.
// resetModules forces re-evaluation so mocks apply to transitive imports.
vi.hoisted(() => vi.resetModules());

const mockSendCommand = vi.fn();
const mockSendCommandAsync = vi.fn();

vi.mock('../../hooks/useReaper', () => ({
  useReaper: vi.fn(() => ({
    sendCommand: mockSendCommand,
    sendCommandAsync: mockSendCommandAsync,
  })),
}));

import { FxParamModal } from './FxParamModal';
import { useReaperStore } from '../../store';

const TRACK = '{TRACK-GUID-0001}';
const FX = '{FX-GUID-0001}';

/** The skeleton REAPER reports for the FX: names and their nameHash. */
let skeleton: { params: string[]; nameHash: number };

function getParamsCalls(): number {
  return mockSendCommandAsync.mock.calls.filter(
    ([cmd]) => (cmd as { command: string }).command === 'trackFx/getParams'
  ).length;
}

function sendEvent(nameHash: number, paramCount = skeleton.params.length): void {
  act(() => {
    useReaperStore.getState().handleFxParamsEvent({
      trackGuid: TRACK,
      fxGuid: FX,
      paramCount,
      nameHash,
      values: paramCount > 0 ? { '0': [0.5, '500 Hz'] } : {},
    });
  });
}

/** Let pending getParams responses resolve and the effects they trigger run. */
async function settle(): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

async function openModal(): Promise<void> {
  render(<FxParamModal isOpen onClose={() => {}} trackGuid={TRACK} fxGuid={FX} fxName="ReaEQ" />);
  await waitFor(() => expect(screen.getByText(skeleton.params[0])).toBeInTheDocument());
  await settle();
}

describe('FxParamModal skeleton fetching', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useReaperStore.getState().clearFxParamSubscription();
    useReaperStore.setState({ _fxParamSkeletonCache: new Map() });
    skeleton = { params: ['Freq', 'Gain', 'Q'], nameHash: 4503599627370495 };
    mockSendCommandAsync.mockImplementation(async (cmd: { command: string }) => {
      if (cmd.command !== 'trackFx/getParams') return { success: true };
      return {
        success: true,
        payload: {
          trackGuid: TRACK,
          fxGuid: FX,
          paramCount: skeleton.params.length,
          nameHash: skeleton.nameHash,
          params: [...skeleton.params],
        },
      };
    });
  });

  afterEach(() => {
    cleanup();
  });

  it('does not refetch the skeleton while events report the nameHash getParams returned', async () => {
    await openModal();
    expect(getParamsCalls()).toBe(1);

    for (let i = 0; i < 5; i++) {
      sendEvent(skeleton.nameHash);
      await settle();
    }

    expect(getParamsCalls()).toBe(1);
    expect(useReaperStore.getState().fxParamSkeletonLoading).toBe(false);
  });

  it('refetches the skeleton once when an event reports changed parameter names', async () => {
    await openModal();
    expect(getParamsCalls()).toBe(1);

    skeleton = { params: ['Freq', 'Gain', 'Bandwidth'], nameHash: 777 };
    sendEvent(777);
    await waitFor(() => expect(screen.getByText('Bandwidth')).toBeInTheDocument());
    await settle();
    expect(getParamsCalls()).toBe(2);

    // Later events with the new hash match the refetched skeleton.
    sendEvent(777);
    await settle();
    expect(getParamsCalls()).toBe(2);
  });

  it('shows a failed skeleton fetch without retrying it in a loop', async () => {
    mockSendCommandAsync.mockResolvedValue({ success: false, error: { code: 'FX_NOT_FOUND' } });
    render(<FxParamModal isOpen onClose={() => {}} trackGuid={TRACK} fxGuid={FX} fxName="ReaEQ" />);
    await settle();
    await settle();

    expect(getParamsCalls()).toBe(1);
    expect(useReaperStore.getState().fxParamSkeletonError).toBe('Invalid skeleton response');
  });

  it('fetches the skeleton again, once, when Retry is tapped after a failed first fetch', async () => {
    const respond = mockSendCommandAsync.getMockImplementation()!;
    mockSendCommandAsync.mockResolvedValueOnce({ success: false, error: { code: 'TIMEOUT' } });
    render(<FxParamModal isOpen onClose={() => {}} trackGuid={TRACK} fxGuid={FX} fxName="ReaEQ" />);
    await settle();
    expect(getParamsCalls()).toBe(1);
    mockSendCommandAsync.mockImplementation(respond);

    fireEvent.click(screen.getByRole('button', { name: 'Retry loading parameters' }));
    await waitFor(() => expect(screen.getByText('Freq')).toBeInTheDocument());
    await settle();

    expect(getParamsCalls()).toBe(2);
    expect(useReaperStore.getState().fxParamSkeletonError).toBeNull();
    expect(screen.queryByRole('button', { name: 'Retry loading parameters' })).not.toBeInTheDocument();
  });

  it('drops a getParams response for an FX the modal has since switched away from', async () => {
    const FX_B = '{FX-GUID-0002}';
    const pending = new Map<string, (names: string[]) => void>();
    mockSendCommandAsync.mockImplementation(
      (cmd: { command: string; params: { fxGuid: string } }) =>
        new Promise((resolve) => {
          if (cmd.command !== 'trackFx/getParams') return resolve({ success: true });
          const { fxGuid } = cmd.params;
          pending.set(fxGuid, (params) =>
            resolve({ success: true, payload: { trackGuid: TRACK, fxGuid, paramCount: params.length, nameHash: params.length, params } })
          );
        })
    );

    const { rerender } = render(
      <FxParamModal isOpen onClose={() => {}} trackGuid={TRACK} fxGuid={FX} fxName="ReaEQ" />
    );
    await settle();
    rerender(<FxParamModal isOpen onClose={() => {}} trackGuid={TRACK} fxGuid={FX_B} fxName="ReaComp" />);
    await settle();
    expect(pending.has(FX)).toBe(true);
    expect(pending.has(FX_B)).toBe(true);

    // FX A's answer arrives after the switch to FX B.
    await act(async () => pending.get(FX)!(['Freq', 'Gain', 'Q']));
    await settle();
    expect(screen.queryByText('Freq')).not.toBeInTheDocument();
    expect(useReaperStore.getState().fxParamSkeleton).toBeNull();
    expect(useReaperStore.getState().getCachedSkeleton(TRACK, FX_B)).toBeUndefined();

    await act(async () => pending.get(FX_B)!(['Threshold', 'Ratio']));
    await waitFor(() => expect(screen.getByText('Threshold')).toBeInTheDocument());
    expect(useReaperStore.getState().getCachedSkeleton(TRACK, FX_B)?.params).toEqual(['Threshold', 'Ratio']);
  });
});
