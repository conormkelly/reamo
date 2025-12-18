/**
 * Hook to detect if the Reamo_RegionEdit.lua script is installed
 * Checks for the script_installed ExtState flag periodically
 */

import { useEffect, useRef } from 'react';
import { useReaper } from '../components/ReaperProvider';
import { useReaperStore } from '../store';
import * as commands from '../core/CommandBuilder';

const SCRIPT_SECTION = 'Reamo';
const CHECK_INTERVAL = 5000; // Check every 5 seconds

export function useRegionEditScriptDetection() {
  const { send, connected } = useReaper();
  // Note: setLuaScriptInstalled is called by store's handleResponses when EXTSTATE response arrives
  const setLuaScriptChecked = useReaperStore((s) => s.setLuaScriptChecked);
  const luaScriptChecked = useReaperStore((s) => s.luaScriptChecked);

  const checkIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    if (!connected) {
      return;
    }

    // Check for script installation
    const checkScript = () => {
      // Request the ExtState value
      send(commands.getExtState(SCRIPT_SECTION, 'script_installed'));
    };

    // Initial check
    checkScript();

    // Set up periodic checking
    checkIntervalRef.current = setInterval(checkScript, CHECK_INTERVAL);

    // Mark as checked after a short delay (assuming response comes back)
    const checkTimeout = setTimeout(() => {
      setLuaScriptChecked(true);
    }, 1000);

    return () => {
      if (checkIntervalRef.current) {
        clearInterval(checkIntervalRef.current);
      }
      clearTimeout(checkTimeout);
    };
  }, [connected, send, setLuaScriptChecked]);

  // Handle ExtState responses in the store's handleResponses
  // For now, we'll set a simpler approach - check if we get a response

  return { luaScriptChecked };
}
