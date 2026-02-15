import { describe, it, expect } from 'vitest';
import { nextMode, formatPan, formatHwOutputName, MODE_LABELS } from './routingUtils';

describe('nextMode', () => {
  it('cycles 0 (Post) to 1 (Pre-FX)', () => {
    expect(nextMode(0)).toBe(1);
  });

  it('cycles 1 (Pre-FX) to 3 (Post-FX)', () => {
    expect(nextMode(1)).toBe(3);
  });

  it('cycles 3 (Post-FX) back to 0 (Post)', () => {
    expect(nextMode(3)).toBe(0);
  });

  it('returns 0 for unknown mode values', () => {
    expect(nextMode(2)).toBe(0);
    expect(nextMode(99)).toBe(0);
    expect(nextMode(-1)).toBe(0);
  });
});

describe('formatPan', () => {
  it('returns C for center (0)', () => {
    expect(formatPan(0)).toBe('C');
  });

  it('returns C for near-zero values (abs < 0.01)', () => {
    expect(formatPan(0.005)).toBe('C');
    expect(formatPan(-0.009)).toBe('C');
  });

  it('formats left pan as L with percentage', () => {
    expect(formatPan(-0.5)).toBe('L50');
    expect(formatPan(-1.0)).toBe('L100');
  });

  it('formats right pan as R with percentage', () => {
    expect(formatPan(0.5)).toBe('R50');
    expect(formatPan(1.0)).toBe('R100');
  });

  it('rounds percentage to nearest integer', () => {
    expect(formatPan(0.333)).toBe('R33');
    expect(formatPan(-0.666)).toBe('L67');
  });
});

describe('formatHwOutputName', () => {
  it('formats stereo pair from channel 0 as HW Out 1/2', () => {
    expect(formatHwOutputName(0)).toBe('HW Out 1/2');
  });

  it('formats stereo pair from channel 2 as HW Out 3/4', () => {
    expect(formatHwOutputName(2)).toBe('HW Out 3/4');
  });

  it('formats mono channel 0 (bit 10 set) as HW Out 1', () => {
    expect(formatHwOutputName(1024)).toBe('HW Out 1');
  });

  it('formats mono channel 1 (bit 10 set) as HW Out 2', () => {
    expect(formatHwOutputName(1025)).toBe('HW Out 2');
  });

  it('formats higher stereo pairs correctly', () => {
    expect(formatHwOutputName(6)).toBe('HW Out 7/8');
  });
});

describe('MODE_LABELS', () => {
  it('maps mode values to display labels', () => {
    expect(MODE_LABELS[0]).toBe('Post');
    expect(MODE_LABELS[1]).toBe('Pre-FX');
    expect(MODE_LABELS[3]).toBe('Post-FX');
  });
});
