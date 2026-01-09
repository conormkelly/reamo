/**
 * analyze-icons.ts
 *
 * Fetches all REAPER actions, tokenizes their names, and generates:
 * 1. commonIcons.ts - curated icon set for DAW control surfaces
 * 2. iconSearchIndex.ts - semantic search index for IconPicker
 *
 * Run: npx tsx scripts/analyze-icons.ts
 * Requires REAPER with REAmo extension running on localhost:9224
 */

import { WebSocket } from 'ws';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

// ES module equivalent of __dirname
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ============================================================================
// Configuration
// ============================================================================

const WS_PORT = 9224;
const WS_HOST = 'localhost';
const OUTPUT_DIR = path.join(__dirname, '..', 'src', 'icons');

// Stopwords to filter out (common words that don't help icon matching)
const STOPWORDS = new Set([
  // Articles & prepositions
  'a', 'an', 'the', 'to', 'of', 'in', 'on', 'at', 'for', 'by', 'with', 'from',
  'into', 'onto', 'as', 'or', 'and', 'but', 'if', 'then', 'than', 'so',
  // Pronouns
  'i', 'me', 'my', 'we', 'us', 'our', 'you', 'your', 'it', 'its', 'this', 'that',
  // Common verbs (too generic)
  'is', 'are', 'was', 'were', 'be', 'been', 'being', 'have', 'has', 'had',
  'do', 'does', 'did', 'will', 'would', 'could', 'should', 'can', 'may', 'might',
  'get', 'set', 'use', 'using', 'used',
  // REAPER-specific but unhelpful
  'reaper', 'sws', 'action', 'actions', 'command', 'commands', 'option', 'options',
  'setting', 'settings', 'preference', 'preferences', 'menu', 'dialog', 'window',
  'view', 'mode', 'state', 'current', 'new', 'open', 'close', 'show', 'hide',
  'enable', 'disable', 'enabled', 'disabled', 'toggle', 'switch',
  // Numbers and single chars
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
  // Common noise
  'all', 'any', 'each', 'every', 'no', 'not', 'only', 'other', 'same', 'some',
  'such', 'more', 'most', 'less', 'also', 'just', 'now', 'here', 'there',
  'when', 'where', 'which', 'who', 'what', 'how', 'why',
  // Technical noise
  'default', 'custom', 'user', 'global', 'local', 'auto', 'manual',
  'start', 'end', 'begin', 'finish', 'first', 'last', 'next', 'prev', 'previous',
  // Script prefixes and author names (not useful for icons)
  'br', 'xenakios', 'fng', 'aw', 'osc', 'js', 'mpl', 'cfillion', 'amagalma',
  'me2beats', 'nofish', 'schwa', 'gofer', 'lokasenna', 'edgemeal', 'spk77',
]);

// Synonym map: token → lucide icon names that represent it
// This is curated based on DAW concepts
const SYNONYMS: Record<string, string[]> = {
  // Transport
  play: ['Play', 'CirclePlay'],
  pause: ['Pause', 'CirclePause'],
  stop: ['Square', 'CircleStop'],
  record: ['Circle', 'Mic', 'Radio', 'Disc', 'CircleDot'],
  recording: ['Circle', 'Mic', 'Radio', 'Disc', 'CircleDot'],
  rec: ['Circle', 'Mic', 'Radio', 'Disc'],
  rewind: ['Rewind', 'SkipBack', 'ChevronsLeft'],
  forward: ['FastForward', 'SkipForward', 'ChevronsRight'],
  fast: ['FastForward', 'Zap'],
  skip: ['SkipBack', 'SkipForward'],
  seek: ['Navigation', 'Move'],
  goto: ['Navigation', 'CornerUpLeft', 'ArrowRight'],

  // Audio concepts
  volume: ['Volume', 'Volume1', 'Volume2', 'VolumeX', 'VolumeOff'],
  vol: ['Volume', 'Volume1', 'Volume2'],
  mute: ['VolumeX', 'VolumeOff', 'BellOff'],
  unmute: ['Volume2', 'Bell'],
  solo: ['Headphones', 'User', 'Star'],
  pan: ['ArrowLeftRight', 'MoveHorizontal', 'SlidersHorizontal'],
  gain: ['TrendingUp', 'Gauge', 'Volume2'],
  level: ['Activity', 'ChartBar', 'Gauge'],
  meter: ['Activity', 'ChartBar', 'Gauge', 'Signal'],
  peak: ['TrendingUp', 'Mountain', 'Activity'],
  clip: ['AlertTriangle', 'AlertOctagon', 'Scissors'],
  fade: ['Blend', 'Waves', 'TrendingDown'],
  crossfade: ['Blend', 'X', 'Waves'],

  // Track operations
  track: ['Layers', 'List', 'Rows2', 'Rows3'],
  tracks: ['Layers', 'List', 'LayoutList'],
  arm: ['Circle', 'Target', 'Crosshair'],
  armed: ['Circle', 'Target', 'CircleDot'],
  monitor: ['Headphones', 'Activity', 'Eye'],
  monitoring: ['Headphones', 'Activity', 'Eye'],
  input: ['ArrowDownToLine', 'Download', 'Mic'],
  output: ['ArrowUpFromLine', 'Upload', 'Speaker'],
  send: ['Send', 'ArrowUpRight', 'Share'],
  sends: ['Send', 'ArrowUpRight', 'Share'],
  receive: ['ArrowDownLeft', 'Download'],
  bus: ['GitBranch', 'Merge', 'Split'],
  folder: ['Folder', 'FolderOpen', 'FolderClosed'],
  group: ['Group', 'Users', 'Layers'],
  groups: ['Group', 'Users', 'Layers'],

  // Editing
  cut: ['Scissors'],
  copy: ['Copy', 'ClipboardCopy', 'Files'],
  paste: ['ClipboardPaste', 'Clipboard'],
  delete: ['Trash2', 'X', 'Eraser'],
  remove: ['Trash2', 'Minus', 'X'],
  undo: ['Undo2', 'RotateCcw'],
  redo: ['Redo2', 'RotateCw'],
  split: ['Scissors', 'Split', 'SplitSquareHorizontal'],
  trim: ['Crop', 'Scissors', 'Slice'],
  crop: ['Crop', 'Scissors'],
  glue: ['Link', 'Merge', 'Combine'],
  merge: ['Merge', 'GitMerge', 'Combine'],
  duplicate: ['Copy', 'CopyPlus', 'Files'],
  move: ['Move', 'MoveHorizontal', 'MoveVertical', 'GripVertical'],
  drag: ['GripVertical', 'Move', 'Hand'],
  select: ['MousePointer2', 'Square', 'SquareCheck'],
  selection: ['Square', 'RectangleHorizontal'],
  deselect: ['SquareX', 'Square'],
  stretch: ['ArrowLeftRight', 'Expand', 'MoveHorizontal'],
  quantize: ['Grid3x3', 'LayoutGrid', 'AlignCenter'],

  // Time/Navigation
  loop: ['Repeat', 'RefreshCw', 'RotateCcw', 'Repeat1'],
  repeat: ['Repeat', 'RefreshCw', 'Repeat1'],
  cycle: ['RefreshCw', 'RotateCw', 'Repeat'],
  marker: ['MapPin', 'Flag', 'Bookmark', 'Pin'],
  markers: ['MapPin', 'Flag', 'Bookmark'],
  region: ['RectangleHorizontal', 'Box', 'Square'],
  regions: ['RectangleHorizontal', 'Rows2', 'LayoutList'],
  tempo: ['Gauge', 'Timer', 'Clock', 'Activity'],
  bpm: ['Gauge', 'Timer', 'Activity'],
  time: ['Clock', 'Timer', 'Calendar'],
  timeline: ['Clock', 'LayoutList', 'Rows2'],
  position: ['Navigation', 'MapPin', 'Crosshair'],
  cursor: ['MousePointer2', 'Navigation', 'Type'],
  grid: ['Grid3x3', 'LayoutGrid', 'Grid2x2'],
  snap: ['Magnet', 'Grid3x3', 'AlignCenter'],
  zoom: ['ZoomIn', 'ZoomOut', 'Search'],
  scroll: ['MoveVertical', 'ChevronsUpDown', 'ArrowUpDown'],

  // Metronome/Click
  metronome: ['Timer', 'Clock', 'Bell', 'CircleDot'],
  click: ['Timer', 'Bell', 'MousePointer2'],
  count: ['ListOrdered', 'Hash', 'Binary'],

  // FX/Processing
  fx: ['Wand2', 'Sparkles', 'Settings2'],
  effect: ['Wand2', 'Sparkles', 'Settings2'],
  effects: ['Wand2', 'Sparkles', 'Settings2'],
  plugin: ['Plug', 'Package', 'Box'],
  plugins: ['Plug', 'Package', 'Boxes'],
  vst: ['Plug', 'Box', 'Package'],
  eq: ['SlidersHorizontal', 'Sliders', 'Activity'],
  compressor: ['ArrowDownUp', 'Minimize2', 'Shrink'],
  reverb: ['Waves', 'AudioWaveform', 'Sparkles'],
  delay: ['Clock', 'Timer', 'Repeat'],
  filter: ['Filter', 'Funnel', 'SlidersHorizontal'],
  bypass: ['CircleOff', 'XCircle', 'Ban'],

  // MIDI
  midi: ['Piano', 'Music', 'Keyboard'],
  note: ['Music', 'Music2', 'FileMusic'],
  notes: ['Music', 'Music2', 'ListMusic'],
  velocity: ['TrendingUp', 'Gauge', 'Activity'],
  pitch: ['TrendingUp', 'ArrowUpDown', 'Music'],
  channel: ['Layers', 'Radio', 'Cast'],
  cc: ['Sliders', 'SlidersHorizontal', 'Activity'],

  // File operations
  save: ['Save', 'Download', 'HardDrive'],
  load: ['Upload', 'FolderOpen', 'FileUp'],
  import: ['Download', 'FileDown', 'ArrowDownToLine'],
  export: ['Upload', 'FileUp', 'ArrowUpFromLine'],
  render: ['FileOutput', 'Film', 'FileAudio'],
  bounce: ['FileOutput', 'FileAudio', 'ArrowDownToLine'],
  file: ['File', 'FileAudio', 'FileText'],
  project: ['FolderKanban', 'LayoutDashboard', 'FileStack'],

  // Automation
  automation: ['Activity', 'TrendingUp', 'Pencil'],
  envelope: ['Activity', 'TrendingUp', 'Waves'],
  write: ['Pencil', 'Edit', 'PenTool'],
  read: ['Eye', 'BookOpen', 'FileText'],
  touch: ['Hand', 'Pointer', 'Pencil'],
  latch: ['Lock', 'Pin', 'Anchor'],

  // UI/View
  mixer: ['SlidersVertical', 'Sliders', 'LayoutDashboard'],
  arrange: ['LayoutList', 'Rows2', 'PanelLeft'],
  edit: ['Pencil', 'Edit', 'PenTool'],
  editor: ['Pencil', 'Edit', 'Code'],
  browser: ['FolderTree', 'Folders', 'Search'],
  console: ['Terminal', 'Code', 'FileText'],
  dock: ['PanelBottom', 'PanelLeft', 'PanelRight'],
  float: ['Maximize2', 'ExternalLink', 'PictureInPicture2'],
  fullscreen: ['Maximize', 'Fullscreen', 'Expand'],
  minimize: ['Minimize', 'Minimize2', 'ChevronDown'],
  maximize: ['Maximize', 'Maximize2', 'Expand'],

  // Audio hardware
  audio: ['AudioLines', 'Volume2', 'Speaker'],
  speaker: ['Speaker', 'Volume2', 'AudioLines'],
  microphone: ['Mic', 'MicVocal', 'Radio'],
  mic: ['Mic', 'MicVocal', 'Radio'],
  headphones: ['Headphones', 'Headset'],
  interface: ['Plug', 'Usb', 'Cable'],

  // Misc DAW
  sample: ['AudioWaveform', 'Waves', 'FileAudio'],
  waveform: ['AudioWaveform', 'Waves', 'Activity'],
  wave: ['AudioWaveform', 'Waves'],
  take: ['Layers', 'Copy', 'Files'],
  takes: ['Layers', 'Files', 'LayoutList'],
  item: ['RectangleHorizontal', 'Box', 'Square'],
  items: ['Rows2', 'LayoutList', 'Boxes'],
  pool: ['Database', 'Archive', 'Folder'],
  media: ['Film', 'Video', 'FileAudio'],
  video: ['Film', 'Video', 'Clapperboard'],

  // Actions
  insert: ['Plus', 'CirclePlus', 'FilePlus'],
  add: ['Plus', 'CirclePlus', 'FilePlus'],
  create: ['Plus', 'FilePlus', 'FolderPlus'],
  lock: ['Lock', 'LockKeyhole'],
  unlock: ['Unlock', 'LockKeyholeOpen'],
  freeze: ['Snowflake', 'Pause', 'Lock'],
  unfreeze: ['Sun', 'Play', 'Unlock'],
  normalize: ['TrendingUp', 'Maximize2', 'Activity'],
  reverse: ['FlipHorizontal', 'RotateCcw', 'ArrowLeftRight'],
  invert: ['FlipVertical', 'RefreshCw'],

  // High-frequency tokens from REAPER action analysis (added based on data)
  selected: ['SquareCheck', 'Check', 'CheckCircle'],
  preset: ['Bookmark', 'Save', 'FileText', 'Star'],
  lane: ['Rows2', 'Layers', 'LayoutList'],
  lanes: ['Rows2', 'Rows3', 'Layers'],
  stereo: ['Speaker', 'Volume2', 'AudioLines'],
  mono: ['Speaker', 'Volume1', 'Circle'],
  clear: ['X', 'Eraser', 'Trash2', 'XCircle'],
  preview: ['Eye', 'Play', 'Search'],
  transport: ['Play', 'Pause', 'Square', 'SkipForward'],
  master: ['Crown', 'Star', 'Home', 'Gauge'],
  color: ['Palette', 'Paintbrush', 'Circle'],
  restore: ['RotateCcw', 'History', 'Undo2'],
  nudge: ['MoveHorizontal', 'ArrowRight', 'ArrowLeft'],
  comp: ['Layers', 'Combine', 'GitMerge'],  // comping
  chain: ['Link', 'GitBranch', 'Workflow'],
  slot: ['Box', 'Square', 'Package'],
  properties: ['Settings', 'Sliders', 'Info'],
  active: ['CircleDot', 'Check', 'Power'],
  envelopes: ['Activity', 'TrendingUp', 'Waves'],
  channels: ['Layers', 'Rows2', 'LayoutList'],
  toolbar: ['Menu', 'LayoutDashboard', 'Grid3x3'],
  toolbars: ['Menu', 'LayoutDashboard', 'Grid3x3'],

  // Additional high-frequency tokens (round 2)
  mouse: ['MousePointer2', 'Pointer', 'Hand'],
  right: ['ArrowRight', 'ChevronRight', 'ChevronsRight'],
  left: ['ArrowLeft', 'ChevronLeft', 'ChevronsLeft'],
  up: ['ArrowUp', 'ChevronUp', 'ChevronsUp'],
  down: ['ArrowDown', 'ChevronDown', 'ChevronsDown'],
  points: ['CircleDot', 'Circle', 'Target'],
  point: ['CircleDot', 'Target', 'MapPin'],
  events: ['Calendar', 'Bell', 'Activity'],
  config: ['Settings', 'Cog', 'Sliders'],
  go: ['ArrowRight', 'Navigation', 'Play'],
  live: ['Radio', 'Activity', 'Antenna'],
  apply: ['Check', 'CheckCircle', 'Play'],
  tab: ['Columns2', 'LayoutList', 'PanelRight'],
  area: ['Square', 'Box', 'LayoutGrid'],
  locking: ['Lock', 'LockKeyhole'],
  notation: ['Music', 'FileMusic', 'Piano'],
  adjust: ['Sliders', 'SlidersHorizontal', 'Settings'],
  playing: ['Play', 'CirclePlay'],

  // Additional DAW terms (round 3 - from action search)
  ruler: ['Ruler', 'LayoutList', 'AlignLeft'],
  measure: ['Music', 'Clock', 'Hash'],
  fader: ['SlidersVertical', 'Sliders', 'Gauge'],
  playlist: ['ListMusic', 'List', 'LayoutList'],
  stem: ['GitBranch', 'Split', 'Layers'],
  cue: ['Flag', 'MapPin', 'Bell'],
  ripple: ['Waves', 'Activity', 'RefreshCw'],
  scrub: ['FastForward', 'Rewind', 'Navigation'],
  disarm: ['CircleOff', 'XCircle', 'Circle'],
  rms: ['Activity', 'ChartBar', 'Gauge'],
  wet: ['Droplet', 'Waves', 'Blend'],
  dry: ['Sun', 'Circle', 'Blend'],
  routing: ['GitBranch', 'Split', 'Share2'],
  scale: ['Music', 'SlidersVertical', 'TrendingUp'],
  phase: ['RefreshCw', 'RotateCw', 'FlipHorizontal'],
  bar: ['Music', 'Hash', 'LayoutList'],
  beat: ['Music', 'Timer', 'Activity'],
  threshold: ['Activity', 'TrendingUp', 'AlertTriangle'],
  chord: ['Music', 'Piano', 'Layers'],
  punch: ['Circle', 'CircleDot', 'Target'],
  jog: ['RotateCcw', 'RotateCw', 'RefreshCw'],
  polarity: ['FlipVertical', 'RefreshCw', 'ArrowUpDown'],
  consolidate: ['Combine', 'Merge', 'Layers'],
  collapse: ['ChevronDown', 'Minimize', 'Shrink'],
  vca: ['SlidersVertical', 'Sliders', 'Gauge'],
  heal: ['Heart', 'Sparkles', 'Wand2'],
  overdub: ['Layers', 'Circle', 'Plus'],
  window: ['AppWindow', 'Square', 'Maximize'],
  help: ['HelpCircle', 'CircleHelp', 'Info'],
  about: ['Info', 'HelpCircle', 'FileText'],
  manual: ['BookOpen', 'FileText', 'HelpCircle'],
  backup: ['HardDrive', 'Save', 'Archive'],
  batch: ['Layers', 'Files', 'LayoutList'],
  submix: ['GitBranch', 'Merge', 'Layers'],
  parent: ['FolderOpen', 'Folder', 'ChevronUp'],
  child: ['File', 'ChevronRight', 'CornerDownRight'],
  script: ['Code', 'Terminal', 'FileText'],
  extension: ['Plug', 'Package', 'Puzzle'],
  sync: ['RefreshCw', 'RotateCw', 'Link'],
  timecode: ['Clock', 'Timer', 'Hash'],
  offline: ['WifiOff', 'CloudOff', 'CircleOff'],
  online: ['Wifi', 'Cloud', 'CircleDot'],

  // Instruments
  guitar: ['Guitar', 'Music', 'Music2'],
  piano: ['Piano', 'KeyboardMusic', 'Music'],
  drums: ['Drum', 'Drumstick', 'Music'],
  drum: ['Drum', 'Drumstick', 'Circle'],
  bass: ['Guitar', 'Music', 'AudioWaveform'],
  synth: ['Piano', 'KeyboardMusic', 'Waves'],
  keys: ['Piano', 'KeyboardMusic', 'Music'],
  keyboard: ['KeyboardMusic', 'Piano', 'Keyboard'],
  strings: ['Guitar', 'Music', 'Waves'],

  // Voice/Vocals
  vocal: ['MicVocal', 'Mic', 'User'],
  vocals: ['MicVocal', 'Mic', 'User'],
  voice: ['MicVocal', 'Speech', 'Mic'],
  singer: ['MicVocal', 'User', 'Mic'],
  sing: ['MicVocal', 'Music', 'Mic'],
  speech: ['Speech', 'MicVocal', 'MessageSquare'],
  talk: ['Speech', 'MessageCircle', 'Mic'],
  person: ['User', 'PersonStanding', 'CircleUser'],

  // British/American spelling variants
  bin: ['Trash2', 'X', 'Eraser'],  // UK for trash
  rubbish: ['Trash2', 'X', 'Eraser'],  // UK for trash
  colour: ['Palette', 'Paintbrush', 'Circle'],  // UK for color
  favourite: ['Star', 'Heart', 'Bookmark'],  // UK for favorite
  favorite: ['Star', 'Heart', 'Bookmark'],
  centre: ['AlignCenter', 'Target', 'Crosshair'],  // UK for center
  center: ['AlignCenter', 'Target', 'Crosshair'],
  organise: ['LayoutList', 'Layers', 'Group'],  // UK for organize
  organize: ['LayoutList', 'Layers', 'Group'],
  normalise: ['TrendingUp', 'Maximize2', 'Activity'],  // UK for normalize
  analyse: ['Activity', 'Search', 'ChartBar'],  // UK for analyze
  analyze: ['Activity', 'Search', 'ChartBar'],
  maximise: ['Maximize', 'Maximize2', 'Expand'],  // UK for maximize
  minimise: ['Minimize', 'Minimize2', 'ChevronDown'],  // UK for minimize
  programme: ['Code', 'FileText', 'Terminal'],  // UK for program
  program: ['Code', 'FileText', 'Terminal'],
  catalogue: ['List', 'LayoutList', 'Database'],  // UK for catalog
  catalog: ['List', 'LayoutList', 'Database'],
  dialogue: ['MessageSquare', 'MessageCircle', 'AppWindow'],  // UK for dialog
  dialog: ['MessageSquare', 'MessageCircle', 'AppWindow'],
  grey: ['Palette', 'Circle'],  // UK for gray
  gray: ['Palette', 'Circle'],
  metre: ['Activity', 'ChartBar', 'Gauge'],  // UK for meter (measurement)
  // Infinity/endless concepts (very DAW-relevant: sustain, infinite loop, etc.)
  infinity: ['Infinity', 'Repeat', 'RefreshCw'],
  infinite: ['Infinity', 'Repeat', 'RefreshCw'],
  forever: ['Infinity', 'Repeat', 'RefreshCw'],
  endless: ['Infinity', 'Repeat', 'RefreshCw'],
  sustain: ['Infinity', 'Waves', 'Activity'],
  unlimited: ['Infinity', 'Expand', 'Maximize'],

  // Additional round 4 icons
  monitors: ['MonitorSpeaker', 'Speaker', 'Headphones'],
  nearfield: ['MonitorSpeaker', 'Speaker', 'Volume2'],
  speakers: ['MonitorSpeaker', 'Speaker', 'Volume2'],
  broadcast: ['RadioTower', 'Radio', 'Antenna'],
  tower: ['RadioTower', 'Antenna', 'Signal'],
  stream: ['RadioTower', 'Radio', 'Wifi'],
  streaming: ['RadioTower', 'Radio', 'Wifi'],
  transmit: ['RadioTower', 'Send', 'Antenna'],
  album: ['DiscAlbum', 'Disc', 'Music'],
  release: ['DiscAlbum', 'Disc', 'Upload'],
  launch: ['Rocket', 'Play', 'Zap'],
  boost: ['Rocket', 'TrendingUp', 'Zap'],
  rocket: ['Rocket', 'Zap', 'ArrowUp'],
  bolt: ['Bolt', 'Zap', 'Power'],
  lightning: ['Bolt', 'Zap', 'Sparkles'],
  electric: ['Bolt', 'Zap', 'Power'],
  energy: ['Bolt', 'Zap', 'Activity'],
};

// Icons that are commonly used in codebase (from plan analysis)
const CODEBASE_ICONS = [
  'ALargeSmall', 'Activity', 'AlertCircle', 'AlertTriangle', 'AlignCenter', 'AlignLeft', 'AlignRight',
  'ArrowLeftRight', 'AudioLines', 'Check', 'ChevronDown', 'ChevronLeft', 'ChevronRight', 'Circle',
  'CircleSmall', 'Clock', 'CopyPlus', 'Eye', 'EyeOff', 'Gauge', 'GripVertical', 'Headphones', 'Info',
  'Layers', 'ListOrdered', 'Loader2', 'Lock', 'MapPin', 'MapPinPlus', 'Menu', 'Minus', 'Move', 'Navigation',
  'Palette', 'Pause', 'Pencil', 'Play', 'Plus', 'RectangleHorizontal', 'Redo2', 'RefreshCw', 'Repeat',
  'RotateCcw', 'Save', 'Scissors', 'Search', 'SkipBack', 'SkipForward', 'Square', 'ToggleLeft',
  'ToggleRight', 'Trash2', 'Undo2', 'Unlink2', 'Unlock', 'Wifi', 'WifiOff', 'X', 'XCircle',
];

// Additional DAW-relevant icons to always include
const ADDITIONAL_DAW_ICONS = [
  // Transport & Playback
  'FastForward', 'Rewind', 'StepBack', 'StepForward', 'CirclePlay', 'CirclePause', 'CircleStop',
  'Repeat1', 'Shuffle', 'Volume', 'Volume1', 'Volume2', 'VolumeX', 'VolumeOff',
  // Audio & Music
  'Music', 'Music2', 'Music3', 'Music4', 'Mic', 'MicOff', 'MicVocal', 'AudioWaveform', 'Radio', 'Disc',
  'Disc2', 'Disc3', 'Speaker', 'Headset', 'Guitar', 'Drum', 'Drumstick', 'KeyboardMusic', 'Piano',
  // Voice & People
  'Speech', 'PersonStanding', 'CircleUser', 'User',
  // Recording & Monitoring
  'CircleDot', 'Target', 'Signal', 'SignalHigh', 'SignalMedium', 'SignalLow', 'Antenna', 'Waves',
  // Editing & Selection
  'Copy', 'ClipboardCopy', 'ClipboardPaste', 'Scissors', 'Merge', 'Group', 'Ungroup', 'Crop', 'Eraser',
  'PenTool', 'Wand2', 'History',
  // Navigation & Zoom
  'ZoomIn', 'ZoomOut', 'Maximize', 'Maximize2', 'Minimize', 'Minimize2', 'Expand', 'MoveHorizontal',
  'MoveVertical', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ChevronsLeft', 'ChevronsRight',
  'ChevronsUp', 'ChevronsDown', 'Home', 'CornerUpLeft',
  // Time & Markers
  'Timer', 'TimerOff', 'TimerReset', 'Bookmark', 'BookmarkPlus', 'Flag', 'FlagOff', 'Pin', 'PinOff',
  // Layout & Grid
  'Grid2x2', 'Grid3x3', 'LayoutGrid', 'LayoutList', 'LayoutDashboard', 'Columns2', 'Columns3',
  'Rows2', 'Rows3', 'PanelLeft', 'PanelRight', 'PanelBottom', 'SplitSquareHorizontal', 'SplitSquareVertical',
  // Settings & Preferences
  'Settings', 'Settings2', 'Cog', 'SlidersHorizontal', 'SlidersVertical', 'Sliders', 'Wrench', 'Filter',
  'ListFilter', 'SortAsc', 'SortDesc', 'ArrowUpDown', 'ArrowDownUp',
  // File & Project
  'File', 'FileAudio', 'FileMusic', 'FilePlus', 'FileMinus', 'FileX', 'Folder', 'FolderOpen',
  'FolderPlus', 'FolderMinus', 'Download', 'Upload', 'Archive',
  // Status & Feedback
  'CheckCircle', 'CheckCircle2', 'AlertOctagon', 'Bell', 'BellOff', 'BellRing', 'Power', 'PowerOff',
  'Zap', 'ZapOff', 'Sparkles', 'Star', 'StarOff', 'Heart', 'HeartOff', 'Infinity',
  // Misc Useful
  'Link', 'Link2', 'ExternalLink', 'Share', 'Share2', 'Send', 'MessageCircle', 'MessageSquare',
  'HelpCircle', 'CircleHelp', 'MoreHorizontal', 'MoreVertical', 'Grip', 'GripHorizontal',
  'Tag', 'Tags', 'Hash', 'AtSign', 'Command', 'Keyboard',
  // Additional round 4 (user-requested)
  'MonitorSpeaker', 'RadioTower', 'DiscAlbum', 'Rocket', 'Bolt',
];

// ============================================================================
// WebSocket Connection
// ============================================================================

interface ActionData {
  cmdId: number;
  sectionId: number;
  name: string;
  isToggle: number;
  namedId: string | null;
}

async function fetchSessionToken(): Promise<string | null> {
  try {
    const response = await fetch(`http://${WS_HOST}:8099/_/GET/EXTSTATE/Reamo/SessionToken`);
    const text = await response.text();
    const parts = text.trim().split('\t');
    if (parts.length >= 4 && parts[0] === 'EXTSTATE') {
      return parts[3] || null;
    }
    return null;
  } catch {
    console.log('Could not fetch token, will try without auth');
    return null;
  }
}

async function fetchActions(): Promise<ActionData[]> {
  const token = await fetchSessionToken();

  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://${WS_HOST}:${WS_PORT}/`);
    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error('Connection timeout'));
    }, 10000);

    ws.on('open', () => {
      // Send hello
      const hello = {
        type: 'hello',
        clientVersion: '1.0.0',
        protocolVersion: 1,
        ...(token && { token }),
      };
      ws.send(JSON.stringify(hello));
    });

    let receivedHello = false;

    ws.on('message', (data: Buffer) => {
      const msg = JSON.parse(data.toString());

      // Wait for hello response
      if (msg.type === 'hello' && msg.extensionVersion) {
        receivedHello = true;
        console.log(`Connected to REAmo extension v${msg.extensionVersion}`);

        // Send getActions command
        const cmd = {
          type: 'command',
          command: 'action/getActions',
          id: 'get-actions-1',
        };
        ws.send(JSON.stringify(cmd));
        return;
      }

      // Handle response
      if (msg.type === 'response' && msg.id === 'get-actions-1') {
        clearTimeout(timeout);
        ws.close();

        if (!msg.success) {
          reject(new Error(msg.error?.message || 'Failed to get actions'));
          return;
        }

        // Parse actions array: [[cmdId, sectionId, name, isToggle, namedId], ...]
        // payload IS the array directly (not payload.actions)
        const actions: ActionData[] = (msg.payload || []).map((row: unknown[]) => ({
          cmdId: row[0] as number,
          sectionId: row[1] as number,
          name: row[2] as string,
          isToggle: row[3] as number,
          namedId: row[4] as string | null,
        }));

        resolve(actions);
      }
    });

    ws.on('error', (err) => {
      clearTimeout(timeout);
      reject(err);
    });

    ws.on('close', () => {
      clearTimeout(timeout);
      if (!receivedHello) {
        reject(new Error('Connection closed before receiving hello'));
      }
    });
  });
}

// ============================================================================
// Tokenization
// ============================================================================

function tokenize(name: string): string[] {
  // Remove special characters, keep only letters and spaces
  const cleaned = name
    .replace(/[^a-zA-Z\s]/g, ' ')  // Replace non-letters with space
    .toLowerCase()
    .split(/\s+/)                   // Split on whitespace
    .filter(word => word.length > 1) // Remove single chars
    .filter(word => !STOPWORDS.has(word)); // Remove stopwords

  return cleaned;
}

function buildTokenFrequency(actions: ActionData[]): Map<string, number> {
  const freq = new Map<string, number>();

  for (const action of actions) {
    const tokens = tokenize(action.name);
    for (const token of tokens) {
      freq.set(token, (freq.get(token) || 0) + 1);
    }
  }

  return freq;
}

// ============================================================================
// Icon Matching
// ============================================================================

function matchTokensToIcons(tokenFreq: Map<string, number>): Map<string, string[]> {
  const tokenToIcons = new Map<string, string[]>();

  // Always include ALL synonyms in the search index
  // This ensures semantic search works even without REAPER connection
  for (const [token, icons] of Object.entries(SYNONYMS)) {
    tokenToIcons.set(token, icons);
  }

  // Log which tokens from REAPER actions matched our synonyms
  if (tokenFreq.size > 0) {
    const sortedTokens = [...tokenFreq.entries()]
      .sort((a, b) => b[1] - a[1]);

    let matchCount = 0;
    for (const [token] of sortedTokens) {
      if (SYNONYMS[token]) {
        matchCount++;
      }
    }
    console.log(`  ${matchCount} REAPER action tokens matched synonym definitions`);
  }

  return tokenToIcons;
}

function collectAllIcons(tokenToIcons: Map<string, string[]>): Set<string> {
  const icons = new Set<string>();

  // Add codebase icons (always included)
  for (const icon of CODEBASE_ICONS) {
    icons.add(icon);
  }

  // Add additional DAW icons
  for (const icon of ADDITIONAL_DAW_ICONS) {
    icons.add(icon);
  }

  // Add icons from synonym matches
  for (const iconList of tokenToIcons.values()) {
    for (const icon of iconList) {
      icons.add(icon);
    }
  }

  return icons;
}

// ============================================================================
// File Generation
// ============================================================================

function generateCommonIconsFile(icons: Set<string>): string {
  const sortedIcons = [...icons].sort();

  const imports = sortedIcons.join(',\n  ');
  const entries = sortedIcons.map(icon => `  ${icon},`).join('\n');

  return `/**
 * Common Icons for DAW Control Surfaces
 * Auto-generated by scripts/analyze-icons.ts
 *
 * This curated set covers:
 * - All icons currently used in the codebase
 * - DAW-specific icons (transport, mixing, editing)
 * - Icons matched from REAPER action names
 *
 * Total: ${sortedIcons.length} icons
 */

import {
  ${imports}
} from 'lucide-react';

export const commonIcons = {
${entries}
} as const;

export type CommonIconName = keyof typeof commonIcons;
`;
}

function generateIconSearchIndexFile(tokenToIcons: Map<string, string[]>): string {
  // Build reverse index: icon → tokens that reference it
  const iconToTokens = new Map<string, string[]>();
  for (const [token, icons] of tokenToIcons) {
    for (const icon of icons) {
      if (!iconToTokens.has(icon)) {
        iconToTokens.set(icon, []);
      }
      iconToTokens.get(icon)!.push(token);
    }
  }

  // Sort entries for deterministic output
  const sortedTokens = [...tokenToIcons.keys()].sort();

  const tokenEntries = sortedTokens
    .map(token => {
      const icons = tokenToIcons.get(token)!;
      return `  ${JSON.stringify(token)}: ${JSON.stringify(icons)},`;
    })
    .join('\n');

  return `/**
 * Icon Search Index for Semantic Search
 * Auto-generated by scripts/analyze-icons.ts
 *
 * Maps DAW-related keywords to relevant icon names.
 * Used by IconPicker for fuzzy/semantic search.
 *
 * Example: "record" → ["Circle", "Mic", "Radio", "Disc", "CircleDot"]
 */

/**
 * Token to icons mapping
 * Lowercase keyword → array of matching icon names
 */
export const tokenToIcons: Record<string, string[]> = {
${tokenEntries}
};

/**
 * Search for icons by keyword
 * Returns icons that match the query (case-insensitive)
 */
export function searchIcons(query: string): string[] {
  const q = query.toLowerCase().trim();
  if (!q) return [];

  const results = new Set<string>();

  // Exact token match
  if (tokenToIcons[q]) {
    for (const icon of tokenToIcons[q]) {
      results.add(icon);
    }
  }

  // Partial token match (starts with query)
  for (const [token, icons] of Object.entries(tokenToIcons)) {
    if (token.startsWith(q)) {
      for (const icon of icons) {
        results.add(icon);
      }
    }
  }

  return [...results];
}
`;
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  console.log('Fetching REAPER actions...');

  let actions: ActionData[];
  try {
    actions = await fetchActions();
    console.log(`Fetched ${actions.length} actions`);
  } catch (err) {
    console.error('Failed to fetch actions from REAPER:', err);
    console.log('\nMake sure REAPER is running with the REAmo extension loaded.');
    console.log('Falling back to synonym-based icon set only.\n');
    actions = [];
  }

  // Tokenize action names
  console.log('Tokenizing action names...');
  const tokenFreq = buildTokenFrequency(actions);

  // Log top 100 tokens in CSV format with coverage status
  console.log('\n=== TOP 100 TOKENS (CSV) ===');
  console.log('rank,token,frequency,covered');
  const top100Tokens = [...tokenFreq.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 100);
  let coveredCount = 0;
  for (let i = 0; i < top100Tokens.length; i++) {
    const [token, count] = top100Tokens[i];
    const covered = SYNONYMS[token] ? 'yes' : 'no';
    if (SYNONYMS[token]) coveredCount++;
    console.log(`${i + 1},${token},${count},${covered}`);
  }
  console.log(`\nCoverage: ${coveredCount}/${top100Tokens.length} (${Math.round(coveredCount / top100Tokens.length * 100)}%)`);
  console.log('=== END CSV ===\n');

  // Match tokens to icons
  console.log('\nMatching tokens to icons...');
  const tokenToIcons = matchTokensToIcons(tokenFreq);

  // Collect all icons
  const allIcons = collectAllIcons(tokenToIcons);
  console.log(`\nTotal icons in curated set: ${allIcons.size}`);

  // Ensure output directory exists
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  // Generate files
  const commonIconsContent = generateCommonIconsFile(allIcons);
  const searchIndexContent = generateIconSearchIndexFile(tokenToIcons);

  const commonIconsPath = path.join(OUTPUT_DIR, 'commonIcons.ts');
  const searchIndexPath = path.join(OUTPUT_DIR, 'iconSearchIndex.ts');

  fs.writeFileSync(commonIconsPath, commonIconsContent);
  fs.writeFileSync(searchIndexPath, searchIndexContent);

  console.log(`\nGenerated:`);
  console.log(`  ${commonIconsPath}`);
  console.log(`  ${searchIndexPath}`);

  console.log('\nDone!');
}

main().catch(console.error);
