/**
 * BarBeatDisplay - Large bar.beat.ticks display
 * Uses refs for 60fps direct DOM updates via useTransportSync
 */

import { useRef, type ReactElement } from 'react';
import { useTransportSync } from '../../../hooks';

interface BarBeatDisplayProps {
  scale: number;
}

export function BarBeatDisplay({ scale }: BarBeatDisplayProps): ReactElement {
  const beatsRef = useRef<HTMLSpanElement>(null);

  // Subscribe to transport sync for bar.beat.ticks (server-computed, clock-synchronized)
  useTransportSync((state) => {
    if (beatsRef.current) {
      beatsRef.current.textContent = state.barBeatTicks;
    }
  }, []);

  return (
    <div
      data-testid="beats-display"
      className="text-center font-mono font-bold tracking-tight text-text-primary"
      style={{
        fontSize: `calc(clamp(2.5rem, min(25cqh, 16cqw), 12rem) * ${scale})`,
        lineHeight: 1.1,
      }}
    >
      <span ref={beatsRef}>1.1.00</span>
    </div>
  );
}
