/**
 * LazyIconPicker - Lazily-loaded wrapper for IconPicker
 *
 * The IconPicker imports all ~1900 Lucide icons. By lazy-loading it,
 * we defer this bundle until the user actually opens the icon picker.
 */

import { lazy, Suspense, type ComponentProps } from 'react';

const IconPicker = lazy(() =>
  import('./IconPicker').then((mod) => ({ default: mod.IconPicker }))
);

type IconPickerProps = ComponentProps<typeof IconPicker>;

/**
 * Lazy-loaded IconPicker with loading fallback.
 * Use this instead of IconPicker to reduce initial bundle size.
 */
export function LazyIconPicker(props: IconPickerProps) {
  return (
    <Suspense
      fallback={
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-modal">
          <div className="bg-bg-surface rounded-lg p-8 text-text-secondary">
            Loading icons...
          </div>
        </div>
      }
    >
      <IconPicker {...props} />
    </Suspense>
  );
}
