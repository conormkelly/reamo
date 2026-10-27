/**
 * REAPER Provider Component
 * Wraps the app and manages the connection lifecycle
 */

import type { ReactNode, ReactElement } from 'react';
import {
  useReaperConnection,
  type UseReaperConnectionOptions,
} from '../hooks/useReaperConnection';
import { ReaperContext } from '../hooks/useReaper';

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
