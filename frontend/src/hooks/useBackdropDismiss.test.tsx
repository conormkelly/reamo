/**
 * Tests for useBackdropDismiss — a dialog closes only for a tap that both
 * starts and ends on its backdrop.
 */

import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent, screen } from '@testing-library/react';
import { useBackdropDismiss } from './useBackdropDismiss';

function Dialog({ onClose, enabled }: { onClose: () => void; enabled?: boolean }) {
  const backdrop = useBackdropDismiss(onClose, enabled);
  return (
    <div data-testid="backdrop" {...backdrop}>
      <div data-testid="panel">
        <button>Select icon...</button>
      </div>
    </div>
  );
}

describe('useBackdropDismiss', () => {
  it('closes for a tap that starts and ends on the backdrop', () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} />);
    const backdrop = screen.getByTestId('backdrop');

    fireEvent.pointerDown(backdrop);
    fireEvent.click(backdrop);

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('stays open when a tap inside the dialog is delivered to the backdrop (iOS keyboard closing shifts the page)', () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} />);

    fireEvent.pointerDown(screen.getByText('Select icon...'));
    fireEvent.click(screen.getByTestId('backdrop'));

    expect(onClose).not.toHaveBeenCalled();
  });

  it('stays open when a press on the backdrop is released inside the dialog', () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} />);

    fireEvent.pointerDown(screen.getByTestId('backdrop'));
    fireEvent.click(screen.getByTestId('panel'));

    expect(onClose).not.toHaveBeenCalled();
  });

  it('stays open when the browser cancels a press on the backdrop (it became a scroll)', () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} />);
    const backdrop = screen.getByTestId('backdrop');

    fireEvent.pointerDown(backdrop);
    fireEvent.pointerCancel(backdrop);
    fireEvent.click(backdrop);

    expect(onClose).not.toHaveBeenCalled();
  });

  it('a backdrop tap after an ignored one still closes', () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} />);
    const backdrop = screen.getByTestId('backdrop');

    fireEvent.pointerDown(screen.getByText('Select icon...'));
    fireEvent.click(backdrop);
    fireEvent.pointerDown(backdrop);
    fireEvent.click(backdrop);

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('never closes when disabled', () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} enabled={false} />);
    const backdrop = screen.getByTestId('backdrop');

    fireEvent.pointerDown(backdrop);
    fireEvent.click(backdrop);

    expect(onClose).not.toHaveBeenCalled();
  });
});
