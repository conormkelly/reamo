/**
 * Version Storage Utility
 *
 * Stores extensionVersion and htmlMtime in localStorage after first successful WebSocket hello.
 * On subsequent page loads, compares stored version with server version to detect stale PWA cache.
 *
 * This solves iOS Safari's aggressive dual-layer caching which can serve stale HTML/JS
 * even after the extension has been updated.
 */

const VERSION_KEY = 'reamo_version';

interface StoredVersion {
  extensionVersion: string;
  htmlMtime: number;
  timestamp: number; // When this was stored (for debugging)
}

/**
 * Get the stored version from localStorage
 */
export function getStoredVersion(): StoredVersion | null {
  try {
    const stored = localStorage.getItem(VERSION_KEY);
    return stored ? JSON.parse(stored) : null;
  } catch {
    return null;
  }
}

/**
 * Store the current version in localStorage
 */
export function storeVersion(extensionVersion: string, htmlMtime: number): void {
  try {
    const data: StoredVersion = {
      extensionVersion,
      htmlMtime,
      timestamp: Date.now(),
    };
    localStorage.setItem(VERSION_KEY, JSON.stringify(data));
  } catch {
    // Ignore quota errors on iOS
  }
}

/**
 * Clear the stored version (useful for debugging)
 */
export function clearStoredVersion(): void {
  try {
    localStorage.removeItem(VERSION_KEY);
  } catch {
    // Ignore
  }
}

/**
 * Check if server version differs from stored version
 * @returns 'match' | 'mismatch' | 'first_load'
 */
export function checkVersionMismatch(
  serverExtensionVersion: string,
  serverHtmlMtime: number
): 'match' | 'mismatch' | 'first_load' {
  const stored = getStoredVersion();

  if (!stored) {
    return 'first_load';
  }

  // Check both version AND mtime - either changing indicates an update
  if (
    stored.extensionVersion !== serverExtensionVersion ||
    stored.htmlMtime !== serverHtmlMtime
  ) {
    return 'mismatch';
  }

  return 'match';
}

/**
 * Force a hard refresh that bypasses iOS Safari's dual-layer cache.
 *
 * - Clears Cache Storage API (future-proofing for service workers)
 * - Unregisters any service workers (future-proofing)
 * - Adds cache-busting query param to bypass memory cache
 * - Uses location.replace() for clean browser history
 */
export async function hardRefresh(): Promise<void> {
  // Clear Cache Storage API if available (future-proofing)
  if ('caches' in window) {
    const keys = await caches.keys();
    await Promise.all(keys.map((key) => caches.delete(key)));
  }

  // Unregister any service workers (future-proofing)
  if ('serviceWorker' in navigator) {
    const registrations = await navigator.serviceWorker.getRegistrations();
    await Promise.all(registrations.map((r) => r.unregister()));
  }

  // Add cache-busting query param to bypass iOS dual-layer cache
  // Using location.replace() prevents back-button returning to stale page
  const url = new URL(window.location.href);
  url.searchParams.set('_v', Date.now().toString());
  window.location.replace(url.toString());
}
