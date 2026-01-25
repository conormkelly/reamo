/**
 * ViewLayout - Standard layout wrapper for all views
 *
 * This component establishes the CRITICAL flex pattern that prevents
 * content overflow and toolbar overlap issues:
 *
 *   flex-1 min-h-0 on scrollable content
 *
 * Without min-h-0, flex items default to min-height: auto, which
 * prevents content from shrinking below its natural size, causing overflow.
 *
 * @see docs/architecture/UX_GUIDELINES.md §2 (View Layout Template), §4 (Height Management)
 */

import { type ReactNode } from 'react';

export interface ViewLayoutProps {
  /** View header content (typically ViewHeader component) */
  header?: ReactNode;
  /** View footer content (info bars, toolbars) */
  footer?: ReactNode;
  /** Main content */
  children: ReactNode;
  /** Whether main content should scroll (default: true) */
  scrollable?: boolean;
  /** Additional className for the container */
  className?: string;
  /** data-view attribute for testing/styling hooks */
  viewId?: string;
}

/**
 * Standard view layout that guarantees proper flex behavior.
 *
 * CRITICAL PATTERN: flex-1 min-h-0 on scrollable content
 * This breaks the default min-height: auto behavior that causes overflow.
 *
 * @example
 * <ViewLayout
 *   viewId="timeline"
 *   header={<ViewHeader currentView="timeline">...</ViewHeader>}
 *   footer={<TimelineFooter />}
 * >
 *   <TimelineContent />
 * </ViewLayout>
 */
export function ViewLayout({
  header,
  footer,
  children,
  scrollable = true,
  className = '',
  viewId,
}: ViewLayoutProps) {
  return (
    <div
      className={`h-full flex flex-col ${className}`}
      data-view={viewId}
    >
      {/* View Header - fixed height, won't shrink */}
      {header && (
        <header className="shrink-0">
          {header}
        </header>
      )}

      {/* Main Content Area */}
      {/* flex-1 min-h-0 is MANDATORY - allows content to shrink below natural size */}
      <div className={`flex-1 min-h-0 ${scrollable ? 'overflow-y-auto overscroll-contain' : ''}`}>
        {children}
      </div>

      {/* View Footer - fixed height, won't shrink */}
      {footer && (
        <footer className="shrink-0">
          {footer}
        </footer>
      )}
    </div>
  );
}
