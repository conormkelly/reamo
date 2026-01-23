/**
 * LazyIconPicker - Lazily-loaded wrapper for IconPicker
 *
 * The IconPicker imports all ~1900 Lucide icons. By lazy-loading it,
 * we defer this bundle until the user actually opens the icon picker.
 *
 * Loading fallback is portaled to document.body to escape stacking contexts.
 */

import { lazy, Suspense, type ComponentProps } from 'react';
import { createPortal } from 'react-dom';

const IconPicker = lazy(() =>
  import('./IconPicker').then((mod) => ({ default: mod.IconPicker }))
);

type IconPickerProps = ComponentProps<typeof IconPicker>;

/**
 * Loading fallback component - portaled to body
 */
function LoadingFallback() {
  return createPortal(
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-modal">
      <div className="bg-bg-surface rounded-lg p-8 text-text-secondary">
        Loading icons...
      </div>
    </div>,
    document.body
  );
}

/**
 * Lazy-loaded IconPicker with loading fallback.
 * Use this instead of IconPicker to reduce initial bundle size.
 */
export function LazyIconPicker(props: IconPickerProps) {
  return (
    <Suspense fallback={<LoadingFallback />}>
      <IconPicker {...props} />
    </Suspense>
  );
}
