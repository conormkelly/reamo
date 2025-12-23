/**
 * Marker Edit Script Detection Hook
 *
 * LEGACY: With HTTP polling, a Lua script was needed for marker editing.
 * With WebSocket, the extension handles everything directly.
 *
 * This is now a no-op that always reports the script as installed.
 */

import { useEffect } from 'react';
import { useReaperStore } from '../store';

export function useMarkerEditScriptDetection() {
  const setMarkerScriptInstalled = useReaperStore((s) => s.setMarkerScriptInstalled);
  const setMarkerScriptChecked = useReaperStore((s) => s.setMarkerScriptChecked);

  useEffect(() => {
    // WebSocket extension handles marker editing directly - no script needed
    setMarkerScriptInstalled(true);
    setMarkerScriptChecked(true);
  }, [setMarkerScriptInstalled, setMarkerScriptChecked]);

  return { markerScriptChecked: true };
}
