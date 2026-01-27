// Root-level components (framework-level concerns)
export { ReaperProvider, useReaper, type ReaperProviderProps } from './ReaperProvider';
export { ErrorBoundary } from './ErrorBoundary';
export { ConnectionStatus, ConnectionBanner, type ConnectionStatusProps, type ConnectionBannerProps } from './ConnectionStatus';
export { NetworkStatsModal, type NetworkStatsModalProps } from './NetworkStatsModal';
export { UpdateBanner, type UpdateBannerProps } from './UpdateBanner';
export { MemoryWarningBar, type MemoryWarningBarProps } from './MemoryWarningBar';

// App chrome (Layout/)
export * from './Layout';

// Feature folders
export * from './Modal';
export * from './Transport';
export * from './Track';
export * from './Markers';
export * from './Actions';
export * from './Timeline';
export * from './Toolbar';
export * from './Mixer';
export * from './SecondaryPanel';
export * from './SideRail';
export * from './ContextRail';
export * from './Toast';
