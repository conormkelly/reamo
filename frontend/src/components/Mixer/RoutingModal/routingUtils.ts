/**
 * Routing utilities for RoutingModal
 * Shared constants and helper functions for send/receive/hardware routing controls.
 */

/** Mode display labels: 0=Post, 1=Pre-FX, 3=Post-FX */
export const MODE_LABELS: Record<number, string> = {
  0: 'Post',
  1: 'Pre-FX',
  3: 'Post-FX',
};

/** Cycle mode: 0 → 1 → 3 → 0 */
export function nextMode(mode: number): number {
  if (mode === 0) return 1;
  if (mode === 1) return 3;
  return 0;
}

/** Format pan value (-1 to 1) for display */
export function formatPan(pan: number): string {
  if (Math.abs(pan) < 0.01) return 'C';
  const pct = Math.round(Math.abs(pan) * 100);
  return pan < 0 ? `L${pct}` : `R${pct}`;
}

/**
 * Generate display name from destChannel encoding
 * Lower 10 bits = channel index, upper bits = number of channels
 */
export function formatHwOutputName(destChannel: number): string {
  const channelIdx = destChannel & 0x3ff;
  const numChans = (destChannel >> 10) & 0x3ff;
  const startCh = channelIdx + 1;
  // Mono if numChans is 0 or 1
  if (numChans <= 1) {
    return `HW Out ${startCh}`;
  }
  return `HW Out ${startCh}/${startCh + numChans - 1}`;
}

/** Color scheme type for routing faders */
export type RoutingColorScheme = 'send' | 'receive' | 'hardware';

/** Color classes for each routing type */
export const ROUTING_COLORS: Record<
  RoutingColorScheme,
  {
    mutedButton: string;
    unmutedButton: string;
    faderFill: string;
    faderHandle: string;
    ring: string;
    dbText: string;
    dbMuted: string;
    tabActive: string;
    tabInactive: string;
    tabDisabled: string;
  }
> = {
  send: {
    mutedButton: 'bg-sends-primary/20 text-sends-primary',
    unmutedButton: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated',
    faderFill: 'bg-sends-primary',
    faderHandle: 'bg-sends-light',
    ring: 'ring-sends-ring',
    dbText: 'text-sends-primary',
    dbMuted: 'text-sends-primary/50 line-through',
    tabActive: 'bg-sends-primary/20 text-sends-primary border border-sends-border',
    tabInactive: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated border border-border-subtle',
    tabDisabled: 'bg-bg-surface/50 text-text-muted border border-border-subtle cursor-not-allowed',
  },
  receive: {
    mutedButton: 'bg-receives-primary/20 text-receives-muted',
    unmutedButton: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated',
    faderFill: 'bg-receives-primary/50',
    faderHandle: 'bg-receives-light',
    ring: 'ring-receives-ring',
    dbText: 'text-receives-muted',
    dbMuted: 'text-receives-muted/50 line-through',
    tabActive: 'bg-receives-primary/20 text-receives-primary border border-receives-border',
    tabInactive: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated border border-border-subtle',
    tabDisabled: 'bg-bg-surface/50 text-text-muted border border-border-subtle cursor-not-allowed',
  },
  hardware: {
    mutedButton: 'bg-hardware-primary/20 text-hardware-muted',
    unmutedButton: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated',
    faderFill: 'bg-hardware-primary',
    faderHandle: 'bg-hardware-light',
    ring: 'ring-hardware-ring',
    dbText: 'text-hardware-muted',
    dbMuted: 'text-hardware-muted/50 line-through',
    tabActive: 'bg-hardware-primary/20 text-hardware-muted border border-hardware-border',
    tabInactive: 'bg-bg-surface text-text-secondary hover:bg-bg-elevated border border-border-subtle',
    tabDisabled: 'bg-bg-surface/50 text-text-muted border border-border-subtle cursor-not-allowed',
  },
};
