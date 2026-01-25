/**
 * IconPicker - Searchable grid of curated DAW icons
 *
 * Uses the curated icon set (292 icons) instead of all 1663 Lucide icons.
 * Supports semantic search via iconSearchIndex (e.g., "record" finds Circle, Mic, Disc).
 *
 * Renders via portal to document.body to escape stacking contexts.
 */

import { useState, useMemo, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import { commonIcons, type CommonIconName } from '../../icons/commonIcons';
import { searchIcons } from '../../icons/iconSearchIndex';

interface IconPickerProps {
  value?: string;
  onChange: (name: string) => void;
  onClose: () => void;
}

// Get all icon names from our curated set
const iconNames = Object.keys(commonIcons) as CommonIconName[];

// DAW-focused featured icons (shown first when no search)
const FEATURED_ICONS: CommonIconName[] = [
  // Transport
  'Play', 'Pause', 'Square', 'Circle', 'SkipBack', 'SkipForward',
  'Repeat', 'Repeat1', 'FastForward', 'Rewind',
  // Audio
  'Volume', 'Volume1', 'Volume2', 'VolumeX', 'VolumeOff',
  'Mic', 'MicOff', 'Headphones', 'Speaker', 'AudioLines', 'AudioWaveform',
  // Music
  'Music', 'Music2', 'Piano', 'Radio',
  // Editing
  'Scissors', 'Copy', 'ClipboardPaste', 'Trash2', 'Undo2', 'Redo2',
  // Navigation
  'ZoomIn', 'ZoomOut', 'Move', 'Navigation', 'Target',
  // Markers/Regions
  'MapPin', 'Flag', 'Bookmark', 'RectangleHorizontal',
  // Settings
  'Settings', 'Sliders', 'SlidersHorizontal', 'SlidersVertical',
  // Layout
  'Layers', 'Rows2', 'LayoutList', 'Grid3x3',
  // Common actions
  'Plus', 'Minus', 'Check', 'X', 'Save', 'RefreshCw',
  // Status
  'Eye', 'EyeOff', 'Lock', 'Unlock', 'Power',
];

// Convert PascalCase to kebab-case for display
function toKebabCase(str: string): string {
  return str
    .replace(/([a-z])([A-Z])/g, '$1-$2')
    .replace(/([A-Z])([A-Z][a-z])/g, '$1-$2')
    .toLowerCase();
}

export function IconPicker({ value, onChange, onClose }: IconPickerProps) {
  const [search, setSearch] = useState('');

  // Close on Escape
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [onClose]);

  // Filter icons based on search (supports semantic search)
  const filteredIcons = useMemo(() => {
    const searchLower = search.toLowerCase().trim();

    if (!searchLower) {
      // Show featured icons first, then others alphabetically
      const featured = FEATURED_ICONS.filter((name) => iconNames.includes(name));
      const others = iconNames
        .filter((name) => !FEATURED_ICONS.includes(name))
        .sort();
      return [...featured, ...others];
    }

    // Semantic search: "record" finds Circle, Mic, Disc, etc.
    const semanticMatches = searchIcons(searchLower);

    // Also do direct name matching
    const nameMatches = iconNames.filter((name) =>
      name.toLowerCase().includes(searchLower)
    );

    // Combine results, semantic matches first, deduplicated
    const combined = new Set<CommonIconName>();
    for (const name of semanticMatches) {
      if (iconNames.includes(name as CommonIconName)) {
        combined.add(name as CommonIconName);
      }
    }
    for (const name of nameMatches) {
      combined.add(name);
    }

    return [...combined];
  }, [search]);

  // Portal to body to escape stacking contexts
  return createPortal(
    <div
      className="fixed inset-0 bg-black/60 flex items-center justify-center z-modal"
      onClick={onClose}
    >
      <div
        className="bg-bg-surface rounded-lg shadow-xl w-[400px] max-w-[95vw] max-h-[80vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-modal border-b border-border-subtle">
          <h3 className="text-lg font-medium">Select Icon</h3>
          <button
            onClick={onClose}
            className="p-1 hover:bg-bg-elevated rounded transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Search */}
        <div className="p-modal border-b border-border-subtle">
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full px-3 py-2 bg-bg-deep border border-border-default rounded text-text-primary"
            placeholder="record, marker, guitar..."
            autoFocus
          />
        </div>

        {/* Icon Grid */}
        <div className="flex-1 overflow-y-auto p-modal">
          <div className="grid grid-cols-8 gap-1">
            {filteredIcons.map((name) => {
              const IconComponent = commonIcons[name];
              if (!IconComponent) return null;

              const kebabName = toKebabCase(name);
              const isSelected = value === kebabName || value === name;

              return (
                <button
                  key={name}
                  onClick={() => onChange(kebabName)}
                  className={`p-2 rounded transition-colors flex items-center justify-center ${
                    isSelected
                      ? 'bg-primary text-text-on-primary ring-2 ring-control-ring'
                      : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                  }`}
                  title={kebabName}
                >
                  <IconComponent size={20} />
                </button>
              );
            })}
          </div>
          {filteredIcons.length === 0 && (
            <div className="text-center text-text-muted py-8">
              No icons found for "{search}"
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="p-modal border-t border-border-subtle text-center text-sm text-text-muted">
          {filteredIcons.length} icons
          {value && (
            <span className="ml-2">
              • Selected: <code className="text-text-secondary">{value}</code>
            </span>
          )}
        </div>
      </div>
    </div>,
    document.body
  );
}
