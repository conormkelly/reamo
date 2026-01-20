/**
 * UpdateBanner Component
 * Shown when a new version is available and the user has auto-update disabled.
 * Tapping the banner triggers a hard refresh to load the new version.
 */

import type { ReactElement } from 'react';
import { RefreshCw } from 'lucide-react';
import { hardRefresh } from '../utils/versionStorage';

export interface UpdateBannerProps {
  className?: string;
}

/**
 * Banner shown when PWA has stale content and a new version is available.
 * User can tap to trigger a hard refresh.
 */
export function UpdateBanner({ className = '' }: UpdateBannerProps): ReactElement {
  return (
    <button
      onClick={() => void hardRefresh()}
      data-testid="update-banner"
      role="status"
      aria-live="polite"
      aria-atomic="true"
      className={`w-full flex items-center justify-center gap-2 px-4 pt-[max(0.5rem,env(safe-area-inset-top))] pb-2 bg-primary/20 hover:bg-primary/30 active:bg-primary/40 transition-colors cursor-pointer ${className}`}
    >
      <RefreshCw size={16} className="text-primary" aria-hidden="true" />
      <span className="text-sm text-text-primary">
        New version available — tap to update
      </span>
    </button>
  );
}
