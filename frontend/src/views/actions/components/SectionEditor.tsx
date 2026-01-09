/**
 * SectionEditor - Modal for creating/editing/deleting sections
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { X, Trash2 } from 'lucide-react';
import { IconPicker } from '../../../components/Toolbar/IconPicker';
import { ColorPickerInput } from '../../../components/Toolbar/ColorPickerInput';
import { getIconComponent } from '../../../components/Toolbar/DynamicIcon';
import type { ActionsSection, SizeOption } from '../../../store/slices/actionsViewSlice';

// Default color (gray) - same as no-color state
const DEFAULT_SECTION_COLOR = '#374151';

interface SectionEditorProps {
  section: ActionsSection | null; // null = creating new
  onSave: (data: {
    name: string;
    icon?: string;
    color?: string;
    buttonSize?: SizeOption;
    buttonSpacing?: SizeOption;
  }) => void;
  onDelete?: () => void;
  onClose: () => void;
}

export function SectionEditor({
  section,
  onSave,
  onDelete,
  onClose,
}: SectionEditorProps): ReactElement {
  const [name, setName] = useState(section?.name ?? '');
  const [icon, setIcon] = useState<string | undefined>(section?.icon);
  const [color, setColor] = useState<string | undefined>(section?.color);
  const [buttonSize, setButtonSize] = useState<SizeOption>(section?.buttonSize ?? 'md');
  const [buttonSpacing, setButtonSpacing] = useState<SizeOption>(section?.buttonSpacing ?? 'md');
  const [showIconPicker, setShowIconPicker] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const isNew = section === null;

  // Reset confirm state after timeout
  useEffect(() => {
    if (confirmingDelete) {
      const timer = setTimeout(() => setConfirmingDelete(false), 3000);
      return () => clearTimeout(timer);
    }
  }, [confirmingDelete]);

  // Close on Escape
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (showIconPicker) {
          setShowIconPicker(false);
        } else {
          onClose();
        }
      }
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [onClose, showIconPicker]);

  const handleSave = useCallback(() => {
    const trimmed = name.trim();
    if (trimmed) {
      onSave({
        name: trimmed,
        icon,
        color,
        buttonSize,
        buttonSpacing,
      });
      onClose();
    }
  }, [name, icon, color, buttonSize, buttonSpacing, onSave, onClose]);

  const handleDelete = useCallback(() => {
    if (confirmingDelete) {
      onDelete?.();
      onClose();
    } else {
      setConfirmingDelete(true);
    }
  }, [confirmingDelete, onDelete, onClose]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Enter' && !showIconPicker) {
        handleSave();
      }
    },
    [handleSave, showIconPicker]
  );

  const IconComponent = icon ? getIconComponent(icon) : null;

  return (
    <div
      className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4"
      onClick={onClose}
    >
      <div
        className="bg-gray-800 rounded-lg w-full max-w-sm max-h-[90vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-gray-700 flex-shrink-0">
          <h2 className="text-lg font-semibold text-white">
            {isNew ? 'New Section' : 'Edit Section'}
          </h2>
          <button
            onClick={onClose}
            className="p-1 text-gray-400 hover:text-white rounded-lg hover:bg-gray-700 transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Form */}
        <div className="p-4 space-y-4 overflow-y-auto flex-1">
          {/* Section Name */}
          <div>
            <label className="block text-sm font-medium text-gray-300 mb-1">
              Section Name
            </label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="e.g., Transport, FX, Navigation"
              className="w-full px-3 py-2 bg-gray-900 border border-gray-600 rounded-lg text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none"
              autoFocus
            />
          </div>

          {/* Icon and Color row */}
          <div className="flex gap-4">
            {/* Icon Picker */}
            <div className="flex-1">
              <label className="block text-sm font-medium text-gray-300 mb-1">
                Icon (optional)
              </label>
              <button
                onClick={() => setShowIconPicker(true)}
                className="w-full px-3 py-2 bg-gray-900 border border-gray-600 rounded-lg text-left flex items-center gap-2 hover:border-gray-500 transition-colors"
              >
                {IconComponent ? (
                  <>
                    <IconComponent size={20} className="text-white" />
                    <span className="text-gray-300 truncate">{icon}</span>
                  </>
                ) : (
                  <span className="text-gray-500">None</span>
                )}
              </button>
              {icon && (
                <button
                  onClick={() => setIcon(undefined)}
                  className="mt-1 text-xs text-gray-500 hover:text-gray-400"
                >
                  Clear icon
                </button>
              )}
            </div>

            {/* Color Picker */}
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-1">
                Color
              </label>
              <ColorPickerInput
                label=""
                value={color || DEFAULT_SECTION_COLOR}
                defaultValue={DEFAULT_SECTION_COLOR}
                onChange={setColor}
              />
              {color && color !== DEFAULT_SECTION_COLOR && (
                <button
                  onClick={() => setColor(undefined)}
                  className="mt-1 text-xs text-gray-500 hover:text-gray-400"
                >
                  Clear
                </button>
              )}
            </div>
          </div>

          {/* Button Size and Spacing */}
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-1">
                Button Size
              </label>
              <div className="flex border border-gray-600 rounded-lg overflow-hidden">
                {(['sm', 'md', 'lg'] as SizeOption[]).map((size) => (
                  <button
                    key={size}
                    onClick={() => setButtonSize(size)}
                    className={`flex-1 py-1.5 text-sm transition-colors ${
                      buttonSize === size
                        ? 'bg-blue-600 text-white'
                        : 'bg-gray-700 text-gray-400 hover:bg-gray-600'
                    }`}
                  >
                    {size.toUpperCase()}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-1">
                Spacing
              </label>
              <div className="flex border border-gray-600 rounded-lg overflow-hidden">
                {(['sm', 'md', 'lg'] as SizeOption[]).map((size) => (
                  <button
                    key={size}
                    onClick={() => setButtonSpacing(size)}
                    className={`flex-1 py-1.5 text-sm transition-colors ${
                      buttonSpacing === size
                        ? 'bg-blue-600 text-white'
                        : 'bg-gray-700 text-gray-400 hover:bg-gray-600'
                    }`}
                  >
                    {size.toUpperCase()}
                  </button>
                ))}
              </div>
            </div>
          </div>

          {/* Preview */}
          {(icon || color) && (
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-1">
                Preview
              </label>
              <div
                className="bg-gray-900 rounded-lg p-3 flex items-center gap-2"
                style={{
                  borderLeft: color ? `4px solid ${color}` : undefined,
                }}
              >
                {IconComponent && (
                  <IconComponent
                    size={18}
                    style={{ color: color || '#9ca3af' }}
                  />
                )}
                <span className="font-medium text-white">
                  {name || 'Section Name'}
                </span>
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-4 border-t border-gray-700 flex-shrink-0">
          {/* Delete button (only for existing sections) */}
          {!isNew && onDelete && (
            <button
              onClick={handleDelete}
              className={`flex items-center gap-2 px-3 py-2 rounded-lg transition-colors ${
                confirmingDelete
                  ? 'bg-red-600 text-white'
                  : 'text-red-400 hover:text-red-300 hover:bg-gray-700'
              }`}
            >
              <Trash2 size={16} />
              <span>{confirmingDelete ? 'Confirm Delete' : 'Delete'}</span>
            </button>
          )}

          {/* Spacer if no delete */}
          {(isNew || !onDelete) && <div />}

          {/* Save/Cancel */}
          <div className="flex gap-2">
            <button
              onClick={onClose}
              className="px-4 py-2 text-gray-300 hover:text-white transition-colors"
            >
              Cancel
            </button>
            <button
              onClick={handleSave}
              disabled={!name.trim()}
              className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              {isNew ? 'Create' : 'Save'}
            </button>
          </div>
        </div>

        {/* Icon Picker Modal */}
        {showIconPicker && (
          <IconPicker
            value={icon}
            onChange={(selected: string) => {
              setIcon(selected);
              setShowIconPicker(false);
            }}
            onClose={() => setShowIconPicker(false)}
          />
        )}
      </div>
    </div>
  );
}
