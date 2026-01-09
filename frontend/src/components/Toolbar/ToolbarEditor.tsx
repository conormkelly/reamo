/**
 * ToolbarEditor - Modal for adding/editing toolbar buttons
 */

import { useState, useEffect, useCallback, useMemo } from 'react';
import { X, Trash2, ToggleLeft } from 'lucide-react';
import { LazyIconPicker } from './LazyIconPicker';
import { ColorPickerInput } from './ColorPickerInput';
import { ActionSearch, getStableActionId } from './ActionSearch';
import { getIconComponent } from './DynamicIcon';
import type { ToolbarAction } from '../../store/slices/toolbarSlice';
import { useReaperStore, type ReaperAction } from '../../store';
import { getSectionName } from '../../core/constants';

interface ToolbarEditorProps {
  action: ToolbarAction | null;
  isNew: boolean;
  onClose: () => void;
  onSave: (action: ToolbarAction) => void;
  onDelete: (id: string) => void;
  /** Custom title for the modal (e.g., "Action Button"). Defaults to "Toolbar Button". */
  editorTitle?: string;
}

type ActionType = 'reaper_action' | 'midi_cc' | 'midi_pc';

// Generate a simple unique ID
function generateId(): string {
  return `tb_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}

// Default values (match CSS tokens)
const DEFAULT_BG_COLOR = '#374151'; // Keep hex for color picker initial values
const DEFAULT_TEXT_COLOR = '#FFFFFF';
const DEFAULT_ICON_COLOR = '#FFFFFF';

export function ToolbarEditor({
  action,
  isNew,
  onClose,
  onSave,
  onDelete,
  editorTitle = 'Toolbar Button',
}: ToolbarEditorProps) {
  // Form state
  const [label, setLabel] = useState('');
  const [icon, setIcon] = useState<string | undefined>(undefined);
  const [iconColor, setIconColor] = useState(DEFAULT_ICON_COLOR);
  const [textColor, setTextColor] = useState(DEFAULT_TEXT_COLOR);
  const [backgroundColor, setBackgroundColor] = useState(DEFAULT_BG_COLOR);
  const [actionType, setActionType] = useState<ActionType>('reaper_action');

  // Action-specific state
  const [actionId, setActionId] = useState(''); // "40001" (native) or "_SWS_SAVESEL" (SWS/script)
  const [cc, setCc] = useState('');
  const [ccValue, setCcValue] = useState('127');
  const [program, setProgram] = useState('');
  const [channel, setChannel] = useState('1'); // Display as 1-16, convert to 0-15 on save

  const [showIconPicker, setShowIconPicker] = useState(false);
  const [showActionSearch, setShowActionSearch] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  // Get action cache for looking up action details
  const actionCache = useReaperStore((s) => s.actionCache);

  // Look up current action in cache for display
  const currentActionFromCache = useMemo(() => {
    if (!actionId) return null;
    return actionCache.find((a) => getStableActionId(a) === actionId) ?? null;
  }, [actionCache, actionId]);

  // Initialize form from existing action
  useEffect(() => {
    if (action) {
      setLabel(action.label);
      setIcon(action.icon);
      setIconColor(action.iconColor || DEFAULT_ICON_COLOR);
      setTextColor(action.textColor || DEFAULT_TEXT_COLOR);
      setBackgroundColor(action.backgroundColor || DEFAULT_BG_COLOR);
      setActionType(action.type);

      switch (action.type) {
        case 'reaper_action':
          setActionId(action.actionId);
          break;
        case 'midi_cc':
          setCc(String(action.cc));
          setCcValue(String(action.value));
          setChannel(String(action.channel + 1)); // Convert 0-15 to 1-16 for display
          break;
        case 'midi_pc':
          setProgram(String(action.program));
          setChannel(String(action.channel + 1)); // Convert 0-15 to 1-16 for display
          break;
      }
    }
  }, [action]);

  // Close on Escape
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [onClose]);

  const handleSave = useCallback(() => {
    if (!label.trim()) return;

    const base = {
      id: action?.id || generateId(),
      label: label.trim(),
      icon,
      iconColor: iconColor !== DEFAULT_ICON_COLOR ? iconColor : undefined,
      textColor: textColor !== DEFAULT_TEXT_COLOR ? textColor : undefined,
      backgroundColor: backgroundColor !== DEFAULT_BG_COLOR ? backgroundColor : undefined,
    };

    let newAction: ToolbarAction;

    switch (actionType) {
      case 'reaper_action':
        if (!actionId) return;
        newAction = {
          ...base,
          type: 'reaper_action',
          actionId: actionId.trim(),
          sectionId: 0, // Default to main section for now
        };
        break;
      case 'midi_cc':
        if (!cc) return;
        newAction = {
          ...base,
          type: 'midi_cc',
          cc: parseInt(cc, 10),
          value: parseInt(ccValue, 10) || 127,
          channel: (parseInt(channel, 10) || 1) - 1, // Convert 1-16 to 0-15
        };
        break;
      case 'midi_pc':
        if (!program) return;
        newAction = {
          ...base,
          type: 'midi_pc',
          program: parseInt(program, 10),
          channel: (parseInt(channel, 10) || 1) - 1, // Convert 1-16 to 0-15
        };
        break;
    }

    onSave(newAction);
  }, [
    action,
    label,
    icon,
    iconColor,
    textColor,
    backgroundColor,
    actionType,
    actionId,
    cc,
    ccValue,
    program,
    channel,
    onSave,
  ]);

  const handleDeleteClick = useCallback(() => {
    if (!action) return;
    if (confirmingDelete) {
      onDelete(action.id);
    } else {
      setConfirmingDelete(true);
      // Auto-reset after 3 seconds
      setTimeout(() => setConfirmingDelete(false), 3000);
    }
  }, [action, confirmingDelete, onDelete]);

  // Handle action selection from ActionSearch
  const handleActionSelect = useCallback((selectedAction: ReaperAction) => {
    const stableId = getStableActionId(selectedAction);
    setActionId(stableId);
    // Auto-populate label if empty
    if (!label.trim()) {
      setLabel(selectedAction.name);
    }
    setShowActionSearch(false);
  }, [label]);

  // Validation helpers
  const isValidMidiValue = (val: string, min = 0, max = 127) => {
    const num = parseInt(val, 10);
    return !isNaN(num) && num >= min && num <= max;
  };

  const isValid = (() => {
    if (!label.trim()) return false;
    switch (actionType) {
      case 'reaper_action':
        // Valid if: numeric ID (e.g., "40001") or named ID (e.g., "_SWS_SAVESEL")
        return !!actionId.trim() && (actionId.startsWith('_') || !isNaN(parseInt(actionId, 10)));
      case 'midi_cc':
        return (
          isValidMidiValue(cc) &&
          isValidMidiValue(ccValue) &&
          isValidMidiValue(channel, 1, 16)
        );
      case 'midi_pc':
        return isValidMidiValue(program) && isValidMidiValue(channel, 1, 16);
    }
  })();

  return (
    <div
      className="fixed inset-0 bg-black/60 flex items-center justify-center z-50"
      onClick={onClose}
    >
      <div
        className="bg-bg-surface rounded-lg shadow-xl w-96 max-w-[95vw] max-h-[90vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-border-subtle">
          <h2 className="text-lg font-medium">
            {isNew ? `Add ${editorTitle}` : `Edit ${editorTitle}`}
          </h2>
          <button
            onClick={onClose}
            className="p-1 hover:bg-bg-elevated rounded transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-4">
          {/* Label */}
          <div>
            <label className="block text-sm text-text-secondary mb-1">Label</label>
            <input
              type="text"
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              className="w-full px-3 py-2 bg-bg-deep border border-border-default rounded text-text-primary"
              placeholder="Button label"
              autoFocus
            />
          </div>

          {/* Icon */}
          <div>
            <label className="block text-sm text-text-secondary mb-1">Icon</label>
            <div className="flex gap-2">
              <button
                onClick={() => setShowIconPicker(true)}
                className="flex-1 px-3 py-2 bg-bg-deep border border-border-default rounded text-left text-text-tertiary hover:border-bg-hover flex items-center gap-2"
              >
                {icon ? (
                  <>
                    {(() => {
                      const IconComponent = getIconComponent(icon);
                      return IconComponent ? <IconComponent size={18} /> : null;
                    })()}
                    <span className="font-mono text-sm">{icon}</span>
                  </>
                ) : (
                  'Select icon...'
                )}
              </button>
              {icon && (
                <button
                  onClick={() => setIcon(undefined)}
                  className="px-3 py-2 bg-bg-elevated hover:bg-bg-hover rounded text-text-tertiary"
                >
                  Clear
                </button>
              )}
            </div>
          </div>

          {/* Colors */}
          <div className="grid grid-cols-3 gap-3">
            <ColorPickerInput
              label="Icon"
              value={iconColor}
              onChange={setIconColor}
              defaultValue={DEFAULT_ICON_COLOR}
            />
            <ColorPickerInput
              label="Text"
              value={textColor}
              onChange={setTextColor}
              defaultValue={DEFAULT_TEXT_COLOR}
            />
            <ColorPickerInput
              label="Background"
              value={backgroundColor}
              onChange={setBackgroundColor}
              defaultValue={DEFAULT_BG_COLOR}
            />
          </div>

          {/* Action Type */}
          <div>
            <label className="block text-sm text-text-secondary mb-2">Type</label>
            <div className="grid grid-cols-3 gap-2">
              {[
                { value: 'reaper_action', label: 'Action' },
                { value: 'midi_cc', label: 'MIDI CC' },
                { value: 'midi_pc', label: 'MIDI PC' },
              ].map((opt) => (
                <button
                  key={opt.value}
                  onClick={() => setActionType(opt.value as ActionType)}
                  className={`px-3 py-2 rounded text-sm transition-colors ${
                    actionType === opt.value
                      ? 'bg-primary text-text-primary'
                      : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                  }`}
                >
                  {opt.label}
                </button>
              ))}
            </div>
          </div>

          {/* Action-specific fields */}
          <div className="p-3 bg-bg-deep rounded border border-border-subtle">
            {actionType === 'reaper_action' && (
              <div>
                <label className="block text-sm text-text-secondary mb-1">
                  Action
                </label>
                {showActionSearch ? (
                  <div className="space-y-2">
                    <ActionSearch
                      onSelect={handleActionSelect}
                      selectedActionId={actionId}
                      maxHeight={300}
                    />
                    <button
                      onClick={() => setShowActionSearch(false)}
                      className="w-full px-3 py-2 bg-bg-elevated hover:bg-bg-hover rounded text-sm text-text-tertiary transition-colors"
                    >
                      Cancel
                    </button>
                  </div>
                ) : actionId && currentActionFromCache ? (
                  <div className="p-3 bg-bg-surface border border-border-default rounded">
                    <div className="flex items-center gap-2 mb-1">
                      {currentActionFromCache.isToggle && (
                        <ToggleLeft size={14} className="text-text-secondary flex-shrink-0" />
                      )}
                      <span className="text-sm text-text-primary truncate flex-1">
                        {currentActionFromCache.name}
                      </span>
                      {currentActionFromCache.sectionId !== 0 && (
                        <span className="px-1.5 py-0.5 text-xs bg-bg-elevated text-text-tertiary rounded flex-shrink-0">
                          {getSectionName(currentActionFromCache.sectionId)}
                        </span>
                      )}
                    </div>
                    <div className="text-xs text-text-muted font-mono mb-2">
                      {actionId}
                    </div>
                    <button
                      onClick={() => setShowActionSearch(true)}
                      className="w-full px-3 py-1.5 bg-bg-elevated hover:bg-bg-hover rounded text-sm text-text-tertiary transition-colors"
                    >
                      Change Action
                    </button>
                  </div>
                ) : actionId ? (
                  // Action ID set but not found in cache (manual entry or cache not loaded)
                  <div className="p-3 bg-bg-surface border border-border-default rounded">
                    <div className="text-sm text-text-tertiary mb-1">
                      Action ID: <span className="font-mono">{actionId}</span>
                    </div>
                    <div className="text-xs text-warning mb-2">
                      Not found in action cache
                    </div>
                    <button
                      onClick={() => setShowActionSearch(true)}
                      className="w-full px-3 py-1.5 bg-bg-elevated hover:bg-bg-hover rounded text-sm text-text-tertiary transition-colors"
                    >
                      Search Actions
                    </button>
                  </div>
                ) : (
                  // No action selected yet
                  <button
                    onClick={() => setShowActionSearch(true)}
                    className="w-full px-3 py-2 bg-bg-surface border border-border-default border-dashed rounded text-text-secondary hover:border-bg-hover hover:text-text-tertiary transition-colors"
                  >
                    Search and Select Action...
                  </button>
                )}
              </div>
            )}

            {actionType === 'midi_cc' && (
              <div className="space-y-3">
                <div className="grid grid-cols-3 gap-2">
                  <div>
                    <label className="block text-sm text-text-secondary mb-1">CC#</label>
                    <input
                      type="number"
                      min="0"
                      max="127"
                      value={cc}
                      onChange={(e) => setCc(e.target.value)}
                      className="w-full px-3 py-2 bg-bg-surface border border-border-default rounded text-text-primary"
                      placeholder="0-127"
                    />
                  </div>
                  <div>
                    <label className="block text-sm text-text-secondary mb-1">Value</label>
                    <input
                      type="number"
                      min="0"
                      max="127"
                      value={ccValue}
                      onChange={(e) => setCcValue(e.target.value)}
                      className="w-full px-3 py-2 bg-bg-surface border border-border-default rounded text-text-primary"
                      placeholder="0-127"
                    />
                  </div>
                  <div>
                    <label className="block text-sm text-text-secondary mb-1">Channel</label>
                    <input
                      type="number"
                      min="1"
                      max="16"
                      value={channel}
                      onChange={(e) => setChannel(e.target.value)}
                      className="w-full px-3 py-2 bg-bg-surface border border-border-default rounded text-text-primary"
                      placeholder="1-16"
                    />
                  </div>
                </div>
              </div>
            )}

            {actionType === 'midi_pc' && (
              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-2">
                  <div>
                    <label className="block text-sm text-text-secondary mb-1">Program</label>
                    <input
                      type="number"
                      min="0"
                      max="127"
                      value={program}
                      onChange={(e) => setProgram(e.target.value)}
                      className="w-full px-3 py-2 bg-bg-surface border border-border-default rounded text-text-primary"
                      placeholder="0-127"
                    />
                  </div>
                  <div>
                    <label className="block text-sm text-text-secondary mb-1">Channel</label>
                    <input
                      type="number"
                      min="1"
                      max="16"
                      value={channel}
                      onChange={(e) => setChannel(e.target.value)}
                      className="w-full px-3 py-2 bg-bg-surface border border-border-default rounded text-text-primary"
                      placeholder="1-16"
                    />
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-4 border-t border-border-subtle">
          <div>
            {!isNew && (
              <button
                onClick={handleDeleteClick}
                className={`px-3 py-2 rounded transition-colors flex items-center gap-1 ${
                  confirmingDelete
                    ? 'bg-error-action text-text-primary hover:bg-error'
                    : 'text-delete-text hover:text-delete-text-hover hover:bg-delete-dim-bg'
                }`}
              >
                <Trash2 size={16} />
                {confirmingDelete ? 'Confirm?' : 'Delete'}
              </button>
            )}
          </div>
          <div className="flex gap-2">
            <button
              onClick={onClose}
              className="px-4 py-2 bg-bg-elevated hover:bg-bg-hover rounded transition-colors"
            >
              Cancel
            </button>
            <button
              onClick={handleSave}
              disabled={!isValid}
              className={`px-4 py-2 rounded transition-colors ${
                isValid
                  ? 'bg-primary hover:bg-primary-hover text-text-primary'
                  : 'bg-bg-elevated text-text-muted cursor-not-allowed'
              }`}
            >
              {isNew ? 'Add' : 'Save'}
            </button>
          </div>
        </div>

        {/* Icon Picker Modal */}
        {showIconPicker && (
          <LazyIconPicker
            value={icon}
            onChange={(name) => {
              setIcon(name);
              setShowIconPicker(false);
            }}
            onClose={() => setShowIconPicker(false)}
          />
        )}
      </div>
    </div>
  );
}
