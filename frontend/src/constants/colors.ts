/**
 * Shared color constants for the REAmo frontend.
 * These complement the CSS design tokens in index.css (@theme block).
 */

// Marker preset colors (standardized on Tailwind -500 variants)
export const MARKER_COLORS = [
  '#dc2626', // red-600 (default)
  '#ea580c', // orange-500
  '#eab308', // yellow-500
  '#22c55e', // green-500
  '#06b6d4', // cyan-500
  '#3b82f6', // blue-500
  '#8b5cf6', // purple-500
  '#ec4899', // pink-500
] as const;

export const DEFAULT_MARKER_COLOR = MARKER_COLORS[0];

// Item preset colors (vibrant/pastel palette for media items)
export const ITEM_COLORS = [
  '#FF6B6B', '#FFE66D', '#4ECDC4', '#45B7D1',
  '#96CEB4', '#FFEAA7', '#DDA0DD', '#98D8C8',
  '#F7DC6F', '#BB8FCE', '#85C1E9', '#F8B500',
] as const;

// Default colors matching REAPER's native defaults
export const DEFAULT_ITEM_COLOR = '#646464';
export const DEFAULT_REGION_COLOR = '#688585';

// RGB versions for contexts requiring rgb() format
export const DEFAULT_ITEM_COLOR_RGB = 'rgb(100, 100, 100)';
export const DEFAULT_REGION_COLOR_RGB = 'rgb(104, 133, 133)';

// Track preset colors (REAPER-style colors for track strips)
export const TRACK_COLORS = [
  '#FF6B6B', // Red
  '#FF8E53', // Orange
  '#FFD93D', // Yellow
  '#6BCB77', // Green
  '#4D96FF', // Blue
  '#9B59B6', // Purple
  '#E91E8C', // Pink
  '#00D9FF', // Cyan
  '#A0522D', // Brown
  '#708090', // Slate
] as const;

export const DEFAULT_TRACK_COLOR = '#808080'; // Neutral gray
