/**
 * TimeDisplay - Seconds display with decisecond precision
 * Uses refs for 60fps direct DOM updates via useTransportAnimation
 */

import { useRef, type ReactElement } from 'react';
import { useTransportAnimation } from '../../../hooks';
import { formatTime } from '../../../utils';

interface TimeDisplayProps {
  scale: number;
}

export function TimeDisplay({ scale }: TimeDisplayProps): ReactElement {
  const timeRef = useRef<HTMLSpanElement>(null);

  // Subscribe to 60fps animation updates for time display (seconds)
  useTransportAnimation((state) => {
    if (timeRef.current) {
      timeRef.current.textContent = formatTime(state.position, { precision: 1, showSign: false });
    }
  }, []);

  return (
    <div
      className="text-center font-mono text-text-tertiary"
      style={{
        fontSize: `calc(clamp(1.5rem, 12cqh, 6rem) * ${scale})`,
        lineHeight: 1.2,
      }}
    >
      <span ref={timeRef}>0:00.0</span>
    </div>
  );
}
