/**
 * SectionEditor - Modal for creating/editing/deleting sections
 *
 * Renders via portal to document.body to escape stacking contexts.
 */

import { useState, useEffect, useCallback, useRef, type ReactElement } from 'react';
import { createPortal } from 'react-dom';
import { X, Trash2 } from 'lucide-react';
import { LazyIconPicker } from '../../../components/Toolbar/LazyIconPicker';
import { ColorPickerInput } from '../../../components/Toolbar/ColorPickerInput';
import { DynamicIcon } from '../../../components/Toolbar/DynamicIcon';
import type { ActionsSection, SizeOption } from '../../../store/slices/actionsViewSlice';

// Default color (gray) - matches --color-bg-elevated token
const DEFAULT_SECTION_COLOR = '#374151'; // Keep hex for color picker

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

  // Timer ref for delete confirmation timeout (two-phase cleanup pattern)
  const confirmTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Reset confirm state after timeout
  useEffect(() => {
    // Clear any existing timer first
    if (confirmTimerRef.current) {
      clearTimeout(confirmTimerRef.current);
      confirmTimerRef.current = null;
    }

    if (confirmingDelete) {
      confirmTimerRef.current = setTimeout(() => {
        confirmTimerRef.current = null; // Self-clear on completion
        setConfirmingDelete(false);
      }, 3000);
    }

    // Cleanup on unmount or dependency change
    return () => {
      if (confirmTimerRef.current) {
        clearTimeout(confirmTimerRef.current);
        confirmTimerRef.current = null;
      }
    };
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

  // Portal to body to escape stacking contexts
  return createPortal(
    <div
      className="fixed inset-0 bg-black/60 flex items-center justify-center z-modal p-4"
      onClick={onClose}
    >
      <div
        className="bg-bg-surface rounded-lg w-full max-w-sm max-h-[90vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-modal border-b border-border-subtle flex-shrink-0">
          <h2 className="text-lg font-semibold text-text-primary">
            {isNew ? 'New Section' : 'Edit Section'}
          </h2>
          <button
            onClick={onClose}
            className="p-1 text-text-secondary hover:text-text-primary rounded-lg hover:bg-bg-elevated transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Form */}
        <div className="p-modal space-y-4 overflow-y-auto flex-1">
          {/* Section Name */}
          <div>
            <label className="block text-sm font-medium text-text-tertiary mb-1">
              Section Name
            </label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="e.g., Transport, FX, Navigation"
              className="w-full px-3 py-2 bg-bg-deep border border-border-default rounded-lg text-text-primary placeholder-text-muted focus:border-focus-border focus:outline-none"
              autoFocus
            />
          </div>

          {/* Icon and Color row */}
          <div className="flex gap-4">
            {/* Icon Picker */}
            <div className="flex-1">
              <label className="block text-sm font-medium text-text-tertiary mb-1">
                Icon (optional)
              </label>
              <button
                onClick={() => setShowIconPicker(true)}
                className="w-full px-3 py-2 bg-bg-deep border border-border-default rounded-lg text-left flex items-center gap-2 hover:border-bg-hover transition-colors"
              >
                {icon ? (
                  <>
                    <DynamicIcon name={icon} size={20} className="text-text-primary" />
                    <span className="text-text-tertiary truncate">{icon}</span>
                  </>
                ) : (
                  <span className="text-text-muted">None</span>
                )}
              </button>
              {icon && (
                <button
                  onClick={() => setIcon(undefined)}
                  className="mt-1 text-xs text-text-muted hover:text-text-secondary"
                >
                  Clear icon
                </button>
              )}
            </div>

            {/* Color Picker */}
            <div>
              <label className="block text-sm font-medium text-text-tertiary mb-1">
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
                  className="mt-1 text-xs text-text-muted hover:text-text-secondary"
                >
                  Clear
                </button>
              )}
            </div>
          </div>

          {/* Button Size and Spacing */}
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-text-tertiary mb-1">
                Button Size
              </label>
              <div className="flex border border-border-default rounded-lg overflow-hidden">
                {(['sm', 'md', 'lg'] as SizeOption[]).map((size) => (
                  <button
                    key={size}
                    onClick={() => setButtonSize(size)}
                    className={`flex-1 py-1.5 text-sm transition-colors ${
                      buttonSize === size
                        ? 'bg-primary text-text-on-primary'
                        : 'bg-bg-elevated text-text-secondary hover:bg-bg-hover'
                    }`}
                  >
                    {size.toUpperCase()}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <label className="block text-sm font-medium text-text-tertiary mb-1">
                Spacing
              </label>
              <div className="flex border border-border-default rounded-lg overflow-hidden">
                {(['sm', 'md', 'lg'] as SizeOption[]).map((size) => (
                  <button
                    key={size}
                    onClick={() => setButtonSpacing(size)}
                    className={`flex-1 py-1.5 text-sm transition-colors ${
                      buttonSpacing === size
                        ? 'bg-primary text-text-on-primary'
                        : 'bg-bg-elevated text-text-secondary hover:bg-bg-hover'
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
              <label className="block text-sm font-medium text-text-tertiary mb-1">
                Preview
              </label>
              <div
                className="bg-bg-deep rounded-lg p-3 flex items-center gap-2"
                style={{
                  borderLeft: color ? `4px solid ${color}` : undefined,
                }}
              >
                {icon && (
                  <DynamicIcon
                    name={icon}
                    size={18}
                    style={{ color: color || 'var(--color-text-secondary)' }}
                  />
                )}
                <span className="font-medium text-text-primary">
                  {name || 'Section Name'}
                </span>
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-modal border-t border-border-subtle flex-shrink-0">
          {/* Delete button (only for existing sections) */}
          {!isNew && onDelete && (
            <button
              onClick={handleDelete}
              className={`flex items-center gap-2 px-3 py-2 rounded-lg transition-colors ${
                confirmingDelete
                  ? 'bg-error-action text-text-on-error'
                  : 'text-delete-text hover:text-delete-text-hover hover:bg-bg-elevated'
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
              className="px-4 py-2 text-text-tertiary hover:text-text-primary transition-colors"
            >
              Cancel
            </button>
            <button
              onClick={handleSave}
              disabled={!name.trim()}
              className="px-4 py-2 bg-primary text-text-on-primary rounded-lg hover:bg-primary-hover disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              {isNew ? 'Create' : 'Save'}
            </button>
          </div>
        </div>

        {/* Icon Picker Modal */}
        {showIconPicker && (
          <LazyIconPicker
            value={icon}
            onChange={(selected: string) => {
              setIcon(selected);
              setShowIconPicker(false);
            }}
            onClose={() => setShowIconPicker(false)}
          />
        )}
      </div>
    </div>,
    document.body
  );
}
