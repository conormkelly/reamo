/**
 * ChordColumn Component
 * Individual vertical chord column with inversion segments and bass notes
 * Top-to-bottom: Oct, 2nd, 1st, Root, then bass notes (R, 5, 8)
 * Supports vertical swipe to arpeggiate between inversions
 */

import { useState, useCallback, useMemo, useRef, type ReactElement, type PointerEvent } from 'react';
import type { Chord } from '@/lib/music-theory';
import { semitoneFromNoteName, generateInversions } from '@/lib/music-theory';

/** Velocity range for X-position mapping */
const MIN_VELOCITY = 30;
const MAX_VELOCITY = 127;

/** Bass note intervals from root */
const BASS_INTERVALS = {
  root: 0,
  fifth: 7,
  octave: 12,
};

/** Inversion labels (4 segments like Logic: Root, 1st, 2nd, Octave Root) */
const INVERSION_LABELS = ['Root', '1st', '2nd', 'Oct'];

/** Fixed velocity for bass buttons (too small for X-position mapping) */
const BASS_FIXED_VELOCITY = 100;

export interface ChordColumnProps {
  /** Chord data with MIDI notes and display info */
  chord: Chord;
  /** Base octave for the chord (bass will be one octave below) */
  bassOctave: number;
  /** Callback when chord notes should sound (includes chord for tracking) */
  onNoteOn: (notes: number[], velocity: number, chord: Chord) => void;
  /** Callback when chord notes should stop */
  onNoteOff: (notes: number[]) => void;
  /** Callback for single bass note on */
  onBassNoteOn: (note: number, velocity: number) => void;
  /** Callback for single bass note off */
  onBassNoteOff: (note: number) => void;
  /** Minimum velocity (left edge) - default 30 */
  minVelocity?: number;
  /** Maximum velocity (right edge) - default 127 */
  maxVelocity?: number;
  className?: string;
  style?: React.CSSProperties;
}

/** Color mappings by chord quality */
const QUALITY_COLORS: Record<string, string> = {
  major: 'bg-blue-700',
  minor: 'bg-purple-700',
  diminished: 'bg-red-800',
  augmented: 'bg-orange-700',
  major7: 'bg-blue-600',
  minor7: 'bg-purple-600',
  dominant7: 'bg-amber-700',
  diminished7: 'bg-red-700',
  half_diminished7: 'bg-rose-800',
};

/**
 * Calculate velocity from X position within element
 */
function calculateVelocityFromX(
  clientX: number,
  rect: DOMRect,
  minVel: number,
  maxVel: number
): number {
  const relativeX = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
  const velocity = Math.round(minVel + relativeX * (maxVel - minVel));
  return Math.max(1, Math.min(127, velocity));
}

interface BassButtonProps {
  label: string;
  midiNote: number;
  onNoteOn: (note: number, velocity: number) => void;
  onNoteOff: (note: number) => void;
}

function BassButton({
  label,
  midiNote,
  onNoteOn,
  onNoteOff,
}: BassButtonProps): ReactElement {
  const [isActive, setIsActive] = useState(false);

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      e.stopPropagation();

      const target = e.currentTarget as HTMLElement;
      target.setPointerCapture(e.pointerId);
      setIsActive(true);
      // Bass buttons use fixed velocity (too small for X-position mapping)
      onNoteOn(midiNote, BASS_FIXED_VELOCITY);
    },
    [midiNote, onNoteOn]
  );

  const handlePointerUp = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
      setIsActive(false);
      onNoteOff(midiNote);
    },
    [midiNote, onNoteOff]
  );

  const handlePointerCancel = useCallback(
    (e: PointerEvent) => {
      (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
      setIsActive(false);
      onNoteOff(midiNote);
    },
    [midiNote, onNoteOff]
  );

  return (
    <button
      type="button"
      className={`
        flex-1 flex items-center justify-center
        text-xs font-medium text-white
        select-none touch-none
        transition-all duration-75
        bg-amber-900/80
        ${isActive ? 'brightness-125' : 'hover:brightness-110'}
      `}
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
      aria-label={`Bass ${label}`}
    >
      {label}
    </button>
  );
}

/** Visual-only inversion segment (pointer events handled by container) */
interface InversionSegmentDisplayProps {
  label: string;
  bgColor: string;
  isFirst: boolean;
  isLast: boolean;
  isActive: boolean;
  /** Chord name to display on top segment */
  chordName?: string;
  /** Roman numeral to display on top segment */
  romanNumeral?: string;
}

function InversionSegmentDisplay({
  label,
  bgColor,
  isFirst,
  isLast,
  isActive,
  chordName,
  romanNumeral,
}: InversionSegmentDisplayProps): ReactElement {
  return (
    <div
      className={`
        relative flex-1 flex items-center justify-center
        text-white font-medium
        select-none touch-none
        transition-all duration-75
        ${bgColor}
        ${isFirst ? 'rounded-t-lg' : ''}
        ${isLast ? 'rounded-b-lg' : ''}
        ${isActive ? 'brightness-125' : ''}
      `}
    >
      {/* Top segment shows chord name + roman numeral instead of inversion label */}
      {isFirst && chordName ? (
        <div className="flex flex-col items-center leading-tight">
          <span className="text-sm font-bold">{chordName}</span>
          <span className="text-[10px] opacity-70">{romanNumeral}</span>
        </div>
      ) : (
        <span className="text-xs opacity-70">{label}</span>
      )}

      {/* Velocity gradient hint */}
      <div
        className={`absolute inset-0 pointer-events-none opacity-20 ${isFirst ? 'rounded-t-lg' : ''} ${isLast ? 'rounded-b-lg' : ''}`}
        style={{
          background: 'linear-gradient(to right, rgba(0,0,0,0.3), rgba(255,255,255,0.1))',
        }}
      />
    </div>
  );
}

export function ChordColumn({
  chord,
  bassOctave,
  onNoteOn,
  onNoteOff,
  onBassNoteOn,
  onBassNoteOff,
  minVelocity = MIN_VELOCITY,
  maxVelocity = MAX_VELOCITY,
  className = '',
  style,
}: ChordColumnProps): ReactElement {
  const containerRef = useRef<HTMLDivElement>(null);
  const currentNotesRef = useRef<number[]>([]);
  const activeSegmentRef = useRef<number | null>(null);
  const [activeSegment, setActiveSegment] = useState<number | null>(null);

  // Generate inversions for this chord (root, 1st, 2nd, octave root)
  // Like Logic: 4 segments with the 4th being root position +12 semitones
  const inversions = useMemo(() => {
    const baseInversions = generateInversions(chord.midiNotes, 2); // [root, 1st, 2nd]
    // Add octave root (root position transposed up 12 semitones)
    const octaveRoot = chord.midiNotes.map((n) => n + 12);
    return [...baseInversions, octaveRoot];
  }, [chord.midiNotes]);

  // Calculate bass notes for this chord's root
  const bassNotes = useMemo(() => {
    const rootSemitone = semitoneFromNoteName(chord.root);
    const bassRoot = rootSemitone + bassOctave * 12 + 12; // +12 for MIDI offset (C0 = 12)
    return {
      root: bassRoot + BASS_INTERVALS.root,
      fifth: bassRoot + BASS_INTERVALS.fifth,
      octave: bassRoot + BASS_INTERVALS.octave,
    };
  }, [chord.root, bassOctave]);

  const bgColor = QUALITY_COLORS[chord.quality] || 'bg-gray-700';

  /**
   * Calculate which inversion segment the pointer is over based on Y position
   * Returns the inversion index (0 = Root, 1 = 1st, 2 = 2nd, 3 = Oct)
   * Segments are displayed top-to-bottom: Oct(3), 2nd(2), 1st(1), Root(0)
   */
  const getSegmentFromY = useCallback(
    (clientY: number): number => {
      if (!containerRef.current) return 0;
      const rect = containerRef.current.getBoundingClientRect();
      const relativeY = (clientY - rect.top) / rect.height;
      // Clamp to [0, 1)
      const clamped = Math.max(0, Math.min(0.9999, relativeY));
      // Visual index: 0=top (Oct), 1, 2, 3=bottom (Root)
      const visualIndex = Math.floor(clamped * inversions.length);
      // Convert to inversion index (reverse: top = highest index)
      return inversions.length - 1 - visualIndex;
    },
    [inversions.length]
  );

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      e.stopPropagation();

      const target = containerRef.current;
      if (!target) return;

      const rect = target.getBoundingClientRect();
      const velocity = calculateVelocityFromX(e.clientX, rect, minVelocity, maxVelocity);
      const segmentIndex = getSegmentFromY(e.clientY);
      const notes = inversions[segmentIndex];

      target.setPointerCapture(e.pointerId);
      activeSegmentRef.current = segmentIndex;
      currentNotesRef.current = notes;
      setActiveSegment(segmentIndex);
      onNoteOn(notes, velocity, chord);
    },
    [chord, inversions, getSegmentFromY, minVelocity, maxVelocity, onNoteOn]
  );

  const handlePointerMove = useCallback(
    (e: PointerEvent) => {
      // Only handle if we have an active segment (finger is down)
      if (activeSegmentRef.current === null) return;
      if (!containerRef.current) return;

      const rect = containerRef.current.getBoundingClientRect();
      const newSegmentIndex = getSegmentFromY(e.clientY);

      // If moved to a different segment, switch notes (arpeggio)
      if (newSegmentIndex !== activeSegmentRef.current) {
        const velocity = calculateVelocityFromX(e.clientX, rect, minVelocity, maxVelocity);
        const oldNotes = currentNotesRef.current;
        const newNotes = inversions[newSegmentIndex];

        // Note off old, note on new
        onNoteOff(oldNotes);
        onNoteOn(newNotes, velocity, chord);

        activeSegmentRef.current = newSegmentIndex;
        currentNotesRef.current = newNotes;
        setActiveSegment(newSegmentIndex);
      }
    },
    [chord, inversions, getSegmentFromY, minVelocity, maxVelocity, onNoteOn, onNoteOff]
  );

  const handlePointerUp = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      if (containerRef.current) {
        containerRef.current.releasePointerCapture(e.pointerId);
      }
      onNoteOff(currentNotesRef.current);
      currentNotesRef.current = [];
      activeSegmentRef.current = null;
      setActiveSegment(null);
    },
    [onNoteOff]
  );

  const handlePointerCancel = useCallback(
    (e: PointerEvent) => {
      if (containerRef.current) {
        containerRef.current.releasePointerCapture(e.pointerId);
      }
      onNoteOff(currentNotesRef.current);
      currentNotesRef.current = [];
      activeSegmentRef.current = null;
      setActiveSegment(null);
    },
    [onNoteOff]
  );

  // Display order: Oct at top (idx 0), Root at bottom (idx 3)
  // inversions array: [Root=0, 1st=1, 2nd=2, Oct=3]
  // Reversed for display: [Oct=3, 2nd=2, 1st=1, Root=0]
  const displayOrder = useMemo(() => {
    return inversions.map((_, idx) => idx).reverse();
  }, [inversions]);

  return (
    <div className={`flex flex-col gap-1 ${className}`} style={style}>
      {/* Inversion segments container - handles all pointer events for swipe */}
      {/* flex-[4] for 4 inversion segments, bass gets flex-[3] for 3 segments = equal heights */}
      <div
        ref={containerRef}
        className="flex-[4] flex flex-col gap-px overflow-hidden touch-none rounded-lg"
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerCancel}
      >
        {displayOrder.map((inversionIndex, visualIdx) => (
          <InversionSegmentDisplay
            key={inversionIndex}
            label={INVERSION_LABELS[inversionIndex]}
            bgColor={bgColor}
            isFirst={visualIdx === 0}
            isLast={visualIdx === displayOrder.length - 1}
            isActive={activeSegment === inversionIndex}
            chordName={visualIdx === 0 ? chord.displayName : undefined}
            romanNumeral={visualIdx === 0 ? chord.romanNumeral : undefined}
          />
        ))}
      </div>

      {/* Bass buttons column - flex-[3] for 3 segments to match inversion segment heights */}
      <div className="flex-[3] flex flex-col gap-px rounded-lg overflow-hidden">
        <BassButton
          label="R"
          midiNote={bassNotes.root}
          onNoteOn={onBassNoteOn}
          onNoteOff={onBassNoteOff}
        />
        <BassButton
          label="5"
          midiNote={bassNotes.fifth}
          onNoteOn={onBassNoteOn}
          onNoteOff={onBassNoteOff}
        />
        <BassButton
          label="8"
          midiNote={bassNotes.octave}
          onNoteOn={onBassNoteOn}
          onNoteOff={onBassNoteOff}
        />
      </div>
    </div>
  );
}
