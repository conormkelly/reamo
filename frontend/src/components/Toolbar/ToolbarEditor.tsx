/**
 * ToolbarEditor - Modal for adding/editing toolbar buttons
 */

import { useState, useEffect, useCallback } from 'react';
import { X, Trash2 } from 'lucide-react';
import { IconPicker } from './IconPicker';
import { ColorPickerInput } from './ColorPickerInput';
import type { ToolbarAction } from '../../store/slices/toolbarSlice';

interface ToolbarEditorProps {
  action: ToolbarAction | null;
  isNew: boolean;
  onClose: () => void;
  onSave: (action: ToolbarAction) => void;
  onDelete: (id: string) => void;
}

type ActionType = 'reaper_action' | 'reaper_action_name' | 'midi_cc' | 'midi_pc';

// Generate a simple unique ID
function generateId(): string {
  return `tb_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}

// Default values
const DEFAULT_BG_COLOR = '#374151';
const DEFAULT_TEXT_COLOR = '#FFFFFF';
const DEFAULT_ICON_COLOR = '#000000';

export function ToolbarEditor({
  action,
  isNew,
  onClose,
  onSave,
  onDelete,
}: ToolbarEditorProps) {
  // Form state
  const [label, setLabel] = useState('');
  const [icon, setIcon] = useState<string | undefined>(undefined);
  const [iconColor, setIconColor] = useState(DEFAULT_ICON_COLOR);
  const [textColor, setTextColor] = useState(DEFAULT_TEXT_COLOR);
  const [backgroundColor, setBackgroundColor] = useState(DEFAULT_BG_COLOR);
  const [actionType, setActionType] = useState<ActionType>('reaper_action');

  // Action-specific state
  const [commandId, setCommandId] = useState('');
  const [actionName, setActionName] = useState('');
  const [cc, setCc] = useState('');
  const [ccValue, setCcValue] = useState('127');
  const [program, setProgram] = useState('');
  const [channel, setChannel] = useState('0');

  const [showIconPicker, setShowIconPicker] = useState(false);

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
          setCommandId(String(action.commandId));
          break;
        case 'reaper_action_name':
          setActionName(action.name);
          break;
        case 'midi_cc':
          setCc(String(action.cc));
          setCcValue(String(action.value));
          setChannel(String(action.channel));
          break;
        case 'midi_pc':
          setProgram(String(action.program));
          setChannel(String(action.channel));
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
        if (!commandId) return;
        newAction = {
          ...base,
          type: 'reaper_action',
          commandId: parseInt(commandId, 10),
        };
        break;
      case 'reaper_action_name':
        if (!actionName) return;
        newAction = {
          ...base,
          type: 'reaper_action_name',
          name: actionName,
        };
        break;
      case 'midi_cc':
        if (!cc) return;
        newAction = {
          ...base,
          type: 'midi_cc',
          cc: parseInt(cc, 10),
          value: parseInt(ccValue, 10) || 127,
          channel: parseInt(channel, 10) || 0,
        };
        break;
      case 'midi_pc':
        if (!program) return;
        newAction = {
          ...base,
          type: 'midi_pc',
          program: parseInt(program, 10),
          channel: parseInt(channel, 10) || 0,
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
    commandId,
    actionName,
    cc,
    ccValue,
    program,
    channel,
    onSave,
  ]);

  const handleDelete = useCallback(() => {
    if (action && window.confirm('Delete this toolbar button?')) {
      onDelete(action.id);
    }
  }, [action, onDelete]);

  const isValid = (() => {
    if (!label.trim()) return false;
    switch (actionType) {
      case 'reaper_action':
        return !!commandId && !isNaN(parseInt(commandId, 10));
      case 'reaper_action_name':
        return !!actionName.trim();
      case 'midi_cc':
        return !!cc && !isNaN(parseInt(cc, 10));
      case 'midi_pc':
        return !!program && !isNaN(parseInt(program, 10));
    }
  })();

  return (
    <div
      className="fixed inset-0 bg-black/60 flex items-center justify-center z-50"
      onClick={onClose}
    >
      <div
        className="bg-gray-800 rounded-lg shadow-xl w-96 max-w-[95vw] max-h-[90vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-gray-700">
          <h2 className="text-lg font-medium">
            {isNew ? 'Add Toolbar Button' : 'Edit Toolbar Button'}
          </h2>
          <button
            onClick={onClose}
            className="p-1 hover:bg-gray-700 rounded transition-colors"
          >
            <X size={20} />
          </button>
        </div>

        {/* Content */}
        <div className="p-4 space-y-4">
          {/* Label */}
          <div>
            <label className="block text-sm text-gray-400 mb-1">Label</label>
            <input
              type="text"
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              className="w-full px-3 py-2 bg-gray-900 border border-gray-600 rounded text-white"
              placeholder="Button label"
              autoFocus
            />
          </div>

          {/* Icon */}
          <div>
            <label className="block text-sm text-gray-400 mb-1">Icon</label>
            <div className="flex gap-2">
              <button
                onClick={() => setShowIconPicker(true)}
                className="flex-1 px-3 py-2 bg-gray-900 border border-gray-600 rounded text-left text-gray-300 hover:border-gray-500"
              >
                {icon || 'Select icon...'}
              </button>
              {icon && (
                <button
                  onClick={() => setIcon(undefined)}
                  className="px-3 py-2 bg-gray-700 hover:bg-gray-600 rounded text-gray-300"
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
            <label className="block text-sm text-gray-400 mb-2">Type</label>
            <div className="grid grid-cols-2 gap-2">
              {[
                { value: 'reaper_action', label: 'REAPER Action' },
                { value: 'reaper_action_name', label: 'Action by Name' },
                { value: 'midi_cc', label: 'MIDI CC' },
                { value: 'midi_pc', label: 'MIDI PC' },
              ].map((opt) => (
                <button
                  key={opt.value}
                  onClick={() => setActionType(opt.value as ActionType)}
                  className={`px-3 py-2 rounded text-sm transition-colors ${
                    actionType === opt.value
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                  }`}
                >
                  {opt.label}
                </button>
              ))}
            </div>
          </div>

          {/* Action-specific fields */}
          <div className="p-3 bg-gray-900 rounded border border-gray-700">
            {actionType === 'reaper_action' && (
              <div>
                <label className="block text-sm text-gray-400 mb-1">
                  Command ID
                </label>
                <input
                  type="number"
                  value={commandId}
                  onChange={(e) => setCommandId(e.target.value)}
                  className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-white"
                  placeholder="e.g., 40364 (metronome)"
                />
                <p className="text-xs text-gray-500 mt-1">
                  Find IDs in REAPER: Actions → Show action list
                </p>
              </div>
            )}

            {actionType === 'reaper_action_name' && (
              <div>
                <label className="block text-sm text-gray-400 mb-1">
                  Action Name
                </label>
                <input
                  type="text"
                  value={actionName}
                  onChange={(e) => setActionName(e.target.value)}
                  className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-white font-mono text-sm"
                  placeholder="_SWS_SAVESEL"
                />
                <p className="text-xs text-gray-500 mt-1">
                  SWS/script action identifiers start with _
                </p>
              </div>
            )}

            {actionType === 'midi_cc' && (
              <div className="space-y-3">
                <div className="grid grid-cols-3 gap-2">
                  <div>
                    <label className="block text-sm text-gray-400 mb-1">CC#</label>
                    <input
                      type="number"
                      min="0"
                      max="127"
                      value={cc}
                      onChange={(e) => setCc(e.target.value)}
                      className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-white"
                      placeholder="0-127"
                    />
                  </div>
                  <div>
                    <label className="block text-sm text-gray-400 mb-1">Value</label>
                    <input
                      type="number"
                      min="0"
                      max="127"
                      value={ccValue}
                      onChange={(e) => setCcValue(e.target.value)}
                      className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-white"
                      placeholder="0-127"
                    />
                  </div>
                  <div>
                    <label className="block text-sm text-gray-400 mb-1">Channel</label>
                    <input
                      type="number"
                      min="0"
                      max="15"
                      value={channel}
                      onChange={(e) => setChannel(e.target.value)}
                      className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-white"
                      placeholder="0-15"
                    />
                  </div>
                </div>
                <p className="text-xs text-gray-500">
                  Send to record-armed/monitored tracks
                </p>
              </div>
            )}

            {actionType === 'midi_pc' && (
              <div className="space-y-3">
                <div className="grid grid-cols-2 gap-2">
                  <div>
                    <label className="block text-sm text-gray-400 mb-1">Program</label>
                    <input
                      type="number"
                      min="0"
                      max="127"
                      value={program}
                      onChange={(e) => setProgram(e.target.value)}
                      className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-white"
                      placeholder="0-127"
                    />
                  </div>
                  <div>
                    <label className="block text-sm text-gray-400 mb-1">Channel</label>
                    <input
                      type="number"
                      min="0"
                      max="15"
                      value={channel}
                      onChange={(e) => setChannel(e.target.value)}
                      className="w-full px-3 py-2 bg-gray-800 border border-gray-600 rounded text-white"
                      placeholder="0-15"
                    />
                  </div>
                </div>
                <p className="text-xs text-gray-500">
                  Program change for preset switching
                </p>
              </div>
            )}
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-4 border-t border-gray-700">
          <div>
            {!isNew && (
              <button
                onClick={handleDelete}
                className="px-3 py-2 text-red-400 hover:text-red-300 hover:bg-red-900/20 rounded transition-colors flex items-center gap-1"
              >
                <Trash2 size={16} />
                Delete
              </button>
            )}
          </div>
          <div className="flex gap-2">
            <button
              onClick={onClose}
              className="px-4 py-2 bg-gray-700 hover:bg-gray-600 rounded transition-colors"
            >
              Cancel
            </button>
            <button
              onClick={handleSave}
              disabled={!isValid}
              className={`px-4 py-2 rounded transition-colors ${
                isValid
                  ? 'bg-blue-600 hover:bg-blue-500 text-white'
                  : 'bg-gray-700 text-gray-500 cursor-not-allowed'
              }`}
            >
              {isNew ? 'Add' : 'Save'}
            </button>
          </div>
        </div>

        {/* Icon Picker Modal */}
        {showIconPicker && (
          <IconPicker
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
