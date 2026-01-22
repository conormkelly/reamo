/**
 * useViewFooterConfig - Per-view footer visibility configuration
 *
 * Defines the recommended footer chrome visibility for each view, with
 * orientation-aware overrides for better space utilization.
 *
 * User preferences (from SettingsMenu) override these defaults.
 *
 * @see docs/architecture/UX_GUIDELINES.md §7 (Footer Chrome Strategy)
 */

import { useIsLandscape } from './useMediaQuery';

export type ViewId = 'timeline' | 'mixer' | 'clock' | 'playlist' | 'actions' | 'instruments' | 'notes';

export type TransportVariant = 'full' | 'compact';

export interface FooterConfig {
  /** Whether tab bar should be visible */
  showTabBar: boolean;
  /** Whether transport should be visible */
  showTransport: boolean;
  /** Transport variant when visible */
  transportVariant?: TransportVariant;
}

/**
 * Default footer configuration per view (portrait orientation)
 *
 * | View        | TabBar | Transport | Rationale                          |
 * |-------------|--------|-----------|-----------------------------------|
 * | timeline    | true   | true      | Core workflow needs both          |
 * | mixer       | true   | true      | Same                              |
 * | clock       | false  | true      | Immersive display mode            |
 * | instruments | false  | compact   | Maximum playing surface           |
 * | actions     | true   | false     | Button grid is primary            |
 * | playlist    | true   | true      | Standard navigation               |
 * | notes       | true   | true      | Standard navigation               |
 */
const VIEW_FOOTER_CONFIG: Record<ViewId, FooterConfig> = {
  timeline:    { showTabBar: true,  showTransport: true,  transportVariant: 'full' },
  mixer:       { showTabBar: true,  showTransport: true,  transportVariant: 'full' },
  clock:       { showTabBar: false, showTransport: true,  transportVariant: 'full' },
  instruments: { showTabBar: false, showTransport: true,  transportVariant: 'compact' },
  actions:     { showTabBar: true,  showTransport: false },
  playlist:    { showTabBar: true,  showTransport: true,  transportVariant: 'full' },
  notes:       { showTabBar: true,  showTransport: true,  transportVariant: 'full' },
};

/**
 * Landscape orientation overrides - more aggressive about hiding chrome
 * to maximize vertical space in constrained viewports.
 */
const LANDSCAPE_OVERRIDES: Partial<Record<ViewId, Partial<FooterConfig>>> = {
  instruments: { showTabBar: false, showTransport: false }, // Maximum playing surface
  clock:       { showTabBar: false, showTransport: false }, // Immersive
};

/**
 * Get the recommended footer configuration for a view
 *
 * @param viewId - The current view identifier
 * @returns FooterConfig with visibility settings
 *
 * @example
 * const footerConfig = useViewFooterConfig('instruments');
 * // In portrait: { showTabBar: false, showTransport: true, transportVariant: 'compact' }
 * // In landscape: { showTabBar: false, showTransport: false }
 */
export function useViewFooterConfig(viewId: ViewId): FooterConfig {
  const isLandscape = useIsLandscape();

  const baseConfig = VIEW_FOOTER_CONFIG[viewId];

  if (isLandscape && LANDSCAPE_OVERRIDES[viewId]) {
    return { ...baseConfig, ...LANDSCAPE_OVERRIDES[viewId] };
  }

  return baseConfig;
}

/**
 * Get the raw footer config without orientation awareness
 * (for use when building UI to display/edit settings)
 */
export function getViewFooterConfig(viewId: ViewId): FooterConfig {
  return VIEW_FOOTER_CONFIG[viewId];
}

/**
 * Get all view IDs that have a specific footer configuration
 */
export function getViewsWithConfig(
  predicate: (config: FooterConfig) => boolean
): ViewId[] {
  return (Object.keys(VIEW_FOOTER_CONFIG) as ViewId[]).filter(
    (viewId) => predicate(VIEW_FOOTER_CONFIG[viewId])
  );
}
