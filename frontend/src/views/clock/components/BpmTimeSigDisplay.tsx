/**
 * BpmTimeSigDisplay - BPM and time signature display
 */

import { type ReactElement } from 'react';
import { useReaperStore } from '../../../store';

interface BpmTimeSigDisplayProps {
  scale: number;
}

export function BpmTimeSigDisplay({ scale }: BpmTimeSigDisplayProps): ReactElement {
  const bpm = useReaperStore((state) => state.bpm);
  const timeSignatureNumerator = useReaperStore((state) => state.timeSignatureNumerator);
  const timeSignatureDenominator = useReaperStore((state) => state.timeSignatureDenominator);

  return (
    <div
      className="text-center font-bold text-text-secondary"
      style={{
        fontSize: `calc(clamp(1.25rem, 8cqh, 4rem) * ${scale})`,
        lineHeight: 1.2,
      }}
    >
      {Math.round(bpm ?? 120)} <span style={{ fontSize: '0.6em', verticalAlign: 'middle' }}>BPM</span>
      <span className="text-text-muted mx-2">|</span>
      {timeSignatureNumerator}/{timeSignatureDenominator}
    </div>
  );
}
