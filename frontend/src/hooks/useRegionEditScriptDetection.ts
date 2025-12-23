/**
 * Region Edit Script Detection Hook
 *
 * LEGACY: With HTTP polling, a Lua script was needed for region editing.
 * With WebSocket, the extension handles everything directly.
 *
 * This is now a no-op that always reports the script as installed.
 */

import { useEffect } from 'react';
import { useReaperStore } from '../store';

export function useRegionEditScriptDetection() {
  const setLuaScriptInstalled = useReaperStore((s) => s.setLuaScriptInstalled);
  const setLuaScriptChecked = useReaperStore((s) => s.setLuaScriptChecked);

  useEffect(() => {
    // WebSocket extension handles region editing directly - no script needed
    setLuaScriptInstalled(true);
    setLuaScriptChecked(true);
  }, [setLuaScriptInstalled, setLuaScriptChecked]);

  return { luaScriptChecked: true };
}
