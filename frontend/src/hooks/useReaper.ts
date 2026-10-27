/**
 * The REAPER connection context, and the hook components use to reach it.
 * ReaperProvider supplies the connection.
 */

import { createContext, useContext } from 'react';
import type { UseReaperConnectionReturn } from './useReaperConnection';

export const ReaperContext = createContext<UseReaperConnectionReturn | null>(null);

/**
 * Hook to access the REAPER connection from child components
 */
export function useReaper(): UseReaperConnectionReturn {
  const context = useContext(ReaperContext);
  if (!context) {
    throw new Error('useReaper must be used within a ReaperProvider');
  }
  return context;
}
