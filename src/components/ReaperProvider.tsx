/**
 * REAPER Provider Component
 * Wraps the app and manages the connection lifecycle
 */

import { type ReactNode, type ReactElement, createContext, useContext } from 'react';
import {
  useReaperConnection,
  type UseReaperConnectionOptions,
  type UseReaperConnectionReturn,
} from '../hooks/useReaperConnection';

// Context for the connection
const ReaperContext = createContext<UseReaperConnectionReturn | null>(null);

export interface ReaperProviderProps extends UseReaperConnectionOptions {
  children: ReactNode;
}

/**
 * Provider component that establishes the REAPER connection
 * Wrap your app with this to enable REAPER communication
 */
export function ReaperProvider({
  children,
  ...options
}: ReaperProviderProps): ReactElement {
  const connection = useReaperConnection(options);

  return (
    <ReaperContext.Provider value={connection}>
      {children}
    </ReaperContext.Provider>
  );
}

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
