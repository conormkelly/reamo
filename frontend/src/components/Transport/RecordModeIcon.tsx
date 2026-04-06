/**
 * RecordModeIcon - renders the appropriate icon for each record mode.
 */

import type { ReactElement, CSSProperties } from 'react';
import { Circle, RefreshCw } from 'lucide-react';
import type { RecordMode } from '../../core/types';

interface RecordModeIconProps {
  mode: RecordMode;
  size?: number;
  style?: CSSProperties;
}

export function RecordModeIcon({ mode, size = 20, style }: RecordModeIconProps): ReactElement {
  if (mode === 'selectedItems') {
    // Compact text icon for selected-items auto-punch
    const fontSize = Math.max(8, Math.round(size * 0.55));
    return (
      <span
        className="font-bold leading-none select-none"
        style={{ fontSize, ...style }}
        aria-hidden="true"
      >
        [O]
      </span>
    );
  }
  if (mode === 'timeSelection') {
    return <RefreshCw size={size} strokeWidth={2.5} style={style} />;
  }
  return <Circle size={size} fill="currentColor" style={style} />;
}
