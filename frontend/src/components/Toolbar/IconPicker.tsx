/**
 * IconPicker - Searchable grid of Lucide icons
 */

import { useState, useMemo, useEffect } from 'react';
import { X, icons, type LucideIcon } from 'lucide-react';

interface IconPickerProps {
  value?: string;
  onChange: (name: string) => void;
  onClose: () => void;
}

// Get all icon names from lucide-react
const iconNames = Object.keys(icons);

// Audio/music related icons to show first
const FEATURED_ICONS = [
  'Play',
  'Pause',
  'Square',
  'Circle',
  'SkipBack',
  'SkipForward',
  'Repeat',
  'Repeat1',
  'Shuffle',
  'Volume',
  'Volume1',
  'Volume2',
  'VolumeX',
  'Mic',
  'Mic2',
  'MicOff',
  'Headphones',
  'Speaker',
  'Radio',
  'Music',
  'Music2',
  'Music3',
  'Music4',
  'AudioLines',
  'AudioWaveform',
  'Guitar',
  'Piano',
  'Drum',
  'ChevronLeft',
  'ChevronRight',
  'ChevronUp',
  'ChevronDown',
  'ArrowLeft',
  'ArrowRight',
  'Plus',
  'Minus',
  'Check',
  'X',
  'Power',
  'PowerOff',
  'Zap',
  'Save',
  'Download',
  'Upload',
  'Folder',
  'File',
  'FileAudio',
  'Settings',
  'Settings2',
  'Sliders',
  'SlidersHorizontal',
  'RotateCcw',
  'RotateCw',
  'Undo',
  'Undo2',
  'Redo',
  'Redo2',
  'Copy',
  'Scissors',
  'Trash',
  'Trash2',
  'Edit',
  'Edit2',
  'Edit3',
  'Pencil',
  'PenTool',
  'Layers',
  'Layers2',
  'Layers3',
  'Layout',
  'Grid',
  'List',
  'Clock',
  'Timer',
  'TimerOff',
  'Bookmark',
  'Star',
  'Heart',
  'Flag',
  'Tag',
  'Hash',
  'Link',
  'Link2',
  'Lock',
  'Unlock',
  'Eye',
  'EyeOff',
  'Search',
  'ZoomIn',
  'ZoomOut',
  'Maximize',
  'Minimize',
  'Move',
  'Hand',
  'Pointer',
  'Target',
  'Crosshair',
  'Focus',
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

  // Filter icons based on search
  const filteredIcons = useMemo(() => {
    const searchLower = search.toLowerCase();

    if (!searchLower) {
      // Show featured icons first, then others
      const featured = FEATURED_ICONS.filter((name) => iconNames.includes(name));
      const others = iconNames
        .filter((name) => !FEATURED_ICONS.includes(name))
        .slice(0, 100); // Limit to prevent performance issues
      return [...featured, ...others];
    }

    return iconNames
      .filter((name) => name.toLowerCase().includes(searchLower))
      .slice(0, 100);
  }, [search]);

  return (
    <div
      className="fixed inset-0 bg-black/60 flex items-center justify-center z-[60]"
      onClick={onClose}
    >
      <div
        className="bg-bg-surface rounded-lg shadow-xl w-[400px] max-w-[95vw] max-h-[80vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-border-subtle">
          <h3 className="text-lg font-medium">Select Icon</h3>
          <button
            onClick={onClose}
            className="p-1 hover:bg-bg-elevated rounded transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Search */}
        <div className="p-4 border-b border-border-subtle">
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full px-3 py-2 bg-bg-deep border border-border-default rounded text-text-primary"
            placeholder="Search icons..."
            autoFocus
          />
        </div>

        {/* Icon Grid */}
        <div className="flex-1 overflow-y-auto p-4">
          <div className="grid grid-cols-8 gap-1">
            {filteredIcons.map((name) => {
              const IconComponent = icons[name as keyof typeof icons] as LucideIcon;
              if (!IconComponent) return null;

              const kebabName = toKebabCase(name);
              const isSelected = value === kebabName || value === name;

              return (
                <button
                  key={name}
                  onClick={() => onChange(kebabName)}
                  className={`p-2 rounded transition-colors flex items-center justify-center ${
                    isSelected
                      ? 'bg-primary text-text-primary ring-2 ring-control-ring'
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
        <div className="p-4 border-t border-border-subtle text-center text-sm text-text-muted">
          {filteredIcons.length} icons
          {value && (
            <span className="ml-2">
              • Selected: <code className="text-text-secondary">{value}</code>
            </span>
          )}
        </div>
      </div>
    </div>
  );
}
