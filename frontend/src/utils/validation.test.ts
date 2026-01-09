/**
 * Tests for validation utilities
 */

import { describe, it, expect } from 'vitest';
import {
  parseTimeInput,
  formatTimeForInput,
  isPartialHexColor,
  isCompleteHexColor,
  normalizeHexColor,
  validateTimeRange,
  parsePositiveInt,
} from './validation';

describe('parseTimeInput', () => {
  describe('plain seconds', () => {
    it('parses whole seconds', () => {
      expect(parseTimeInput('45')).toBe(45);
      expect(parseTimeInput('0')).toBe(0);
      expect(parseTimeInput('120')).toBe(120);
    });

    it('parses decimal seconds', () => {
      expect(parseTimeInput('45.5')).toBe(45.5);
      expect(parseTimeInput('0.001')).toBe(0.001);
      expect(parseTimeInput('120.789')).toBe(120.789);
    });

    it('handles whitespace', () => {
      expect(parseTimeInput('  45.5  ')).toBe(45.5);
      expect(parseTimeInput('\t30\n')).toBe(30);
    });

    it('rejects negative values', () => {
      expect(parseTimeInput('-5')).toBeNull();
      expect(parseTimeInput('-0.5')).toBeNull();
    });
  });

  describe('MM:SS format', () => {
    it('parses minutes and seconds', () => {
      expect(parseTimeInput('1:23')).toBe(83);
      expect(parseTimeInput('0:45')).toBe(45);
      expect(parseTimeInput('10:00')).toBe(600);
    });

    it('parses with milliseconds', () => {
      expect(parseTimeInput('1:23.45')).toBe(83.45);
      expect(parseTimeInput('0:00.5')).toBe(0.5);
      expect(parseTimeInput('2:30.123')).toBe(150.123);
    });

    it('handles large minute values', () => {
      expect(parseTimeInput('90:00')).toBe(5400);
      expect(parseTimeInput('120:30')).toBe(7230);
    });
  });

  describe('HH:MM:SS format', () => {
    it('parses hours, minutes and seconds', () => {
      expect(parseTimeInput('1:02:03')).toBe(3723);
      expect(parseTimeInput('0:01:30')).toBe(90);
      expect(parseTimeInput('2:00:00')).toBe(7200);
    });

    it('parses with milliseconds', () => {
      expect(parseTimeInput('1:02:03.5')).toBe(3723.5);
      expect(parseTimeInput('0:00:00.001')).toBe(0.001);
    });
  });

  describe('invalid inputs', () => {
    it('returns null for empty string', () => {
      expect(parseTimeInput('')).toBeNull();
      expect(parseTimeInput('   ')).toBeNull();
    });

    it('returns null for invalid formats', () => {
      expect(parseTimeInput('abc')).toBeNull();
      expect(parseTimeInput('1:2:3:4')).toBeNull();
      expect(parseTimeInput('1:')).toBeNull();
      expect(parseTimeInput(':30')).toBeNull();
    });

    it('returns null for NaN values', () => {
      expect(parseTimeInput('NaN')).toBeNull();
      expect(parseTimeInput('Infinity')).toBeNull();
    });
  });
});

describe('formatTimeForInput', () => {
  it('formats seconds under 1 minute', () => {
    expect(formatTimeForInput(45)).toBe('0:45.000');
    expect(formatTimeForInput(0)).toBe('0:00.000');
    expect(formatTimeForInput(59.999)).toBe('0:59.999');
  });

  it('formats minutes and seconds', () => {
    expect(formatTimeForInput(83.456)).toBe('1:23.456');
    expect(formatTimeForInput(600)).toBe('10:00.000');
    expect(formatTimeForInput(150.5)).toBe('2:30.500');
  });

  it('formats hours', () => {
    expect(formatTimeForInput(3723.5)).toBe('1:02:03.500');
    expect(formatTimeForInput(7200)).toBe('2:00:00.000');
  });

  it('respects precision parameter', () => {
    expect(formatTimeForInput(45.5, 1)).toBe('0:45.5');
    expect(formatTimeForInput(45.5, 0)).toBe('0:46'); // rounds
    expect(formatTimeForInput(45.123456, 2)).toBe('0:45.12');
  });

  it('handles negative values', () => {
    expect(formatTimeForInput(-5)).toBe('-0:05.000');
    expect(formatTimeForInput(-3723.5)).toBe('-1:02:03.500');
  });
});

describe('isPartialHexColor', () => {
  it('accepts empty string (valid during typing)', () => {
    expect(isPartialHexColor('')).toBe(true);
  });

  it('accepts # alone', () => {
    expect(isPartialHexColor('#')).toBe(true);
  });

  it('accepts partial hex values', () => {
    expect(isPartialHexColor('#f')).toBe(true);
    expect(isPartialHexColor('#ff')).toBe(true);
    expect(isPartialHexColor('#ff0')).toBe(true);
    expect(isPartialHexColor('#ff00')).toBe(true);
    expect(isPartialHexColor('#ff00f')).toBe(true);
    expect(isPartialHexColor('#ff00ff')).toBe(true);
  });

  it('accepts without # prefix', () => {
    expect(isPartialHexColor('ff00ff')).toBe(true);
    expect(isPartialHexColor('abc')).toBe(true);
  });

  it('is case insensitive', () => {
    expect(isPartialHexColor('#FF00FF')).toBe(true);
    expect(isPartialHexColor('#Ff00fF')).toBe(true);
  });

  it('rejects invalid characters', () => {
    expect(isPartialHexColor('#gg0000')).toBe(false);
    expect(isPartialHexColor('#xyz')).toBe(false);
    expect(isPartialHexColor('hello')).toBe(false);
  });

  it('rejects too long values', () => {
    expect(isPartialHexColor('#ff00ff0')).toBe(false);
    expect(isPartialHexColor('ff00ff00')).toBe(false);
  });
});

describe('isCompleteHexColor', () => {
  it('accepts valid 6-digit hex', () => {
    expect(isCompleteHexColor('#ff00ff')).toBe(true);
    expect(isCompleteHexColor('#000000')).toBe(true);
    expect(isCompleteHexColor('#ffffff')).toBe(true);
    expect(isCompleteHexColor('#123abc')).toBe(true);
  });

  it('accepts without # prefix', () => {
    expect(isCompleteHexColor('ff00ff')).toBe(true);
    expect(isCompleteHexColor('000000')).toBe(true);
  });

  it('is case insensitive', () => {
    expect(isCompleteHexColor('#FF00FF')).toBe(true);
    expect(isCompleteHexColor('#Ff00fF')).toBe(true);
  });

  it('rejects incomplete hex', () => {
    expect(isCompleteHexColor('')).toBe(false);
    expect(isCompleteHexColor('#')).toBe(false);
    expect(isCompleteHexColor('#ff')).toBe(false);
    expect(isCompleteHexColor('#ff00f')).toBe(false);
  });

  it('rejects too long hex', () => {
    expect(isCompleteHexColor('#ff00ff0')).toBe(false);
  });

  it('rejects invalid characters', () => {
    expect(isCompleteHexColor('#gg0000')).toBe(false);
  });
});

describe('normalizeHexColor', () => {
  it('adds # prefix if missing', () => {
    expect(normalizeHexColor('ff00ff')).toBe('#ff00ff');
  });

  it('lowercases the result', () => {
    expect(normalizeHexColor('#FF00FF')).toBe('#ff00ff');
    expect(normalizeHexColor('AABBCC')).toBe('#aabbcc');
  });

  it('returns null for invalid colors', () => {
    expect(normalizeHexColor('')).toBeNull();
    expect(normalizeHexColor('#ff')).toBeNull();
    expect(normalizeHexColor('invalid')).toBeNull();
  });
});

describe('validateTimeRange', () => {
  it('accepts valid range', () => {
    const result = validateTimeRange(10, 20);
    expect(result).toEqual({ valid: true, start: 10, end: 20 });
  });

  it('auto-swaps if end < start', () => {
    const result = validateTimeRange(20, 10);
    expect(result).toEqual({ valid: true, start: 10, end: 20 });
  });

  it('rejects zero-length range', () => {
    const result = validateTimeRange(10, 10);
    expect(result).toEqual({ valid: false, error: 'Selection must have a length' });
  });

  it('rejects range below minimum length', () => {
    const result = validateTimeRange(10, 10.005);
    expect(result).toEqual({ valid: false, error: 'Selection must have a length' });
  });

  it('accepts range at exactly minimum length', () => {
    const result = validateTimeRange(10, 10.01);
    expect(result).toEqual({ valid: true, start: 10, end: 10.01 });
  });

  it('respects custom minimum length', () => {
    const result = validateTimeRange(10, 10.5, 1);
    expect(result).toEqual({ valid: false, error: 'Selection must have a length' });

    const result2 = validateTimeRange(10, 11, 1);
    expect(result2).toEqual({ valid: true, start: 10, end: 11 });
  });
});

describe('parsePositiveInt', () => {
  it('parses valid positive integers', () => {
    expect(parsePositiveInt('1')).toBe(1);
    expect(parsePositiveInt('5')).toBe(5);
    expect(parsePositiveInt('100')).toBe(100);
  });

  it('handles whitespace', () => {
    expect(parsePositiveInt('  5  ')).toBe(5);
  });

  it('rejects zero by default', () => {
    expect(parsePositiveInt('0')).toBeNull();
  });

  it('respects custom minimum', () => {
    expect(parsePositiveInt('0', 0)).toBe(0);
    expect(parsePositiveInt('5', 10)).toBeNull();
    expect(parsePositiveInt('10', 10)).toBe(10);
  });

  it('rejects negative numbers', () => {
    expect(parsePositiveInt('-1')).toBeNull();
    expect(parsePositiveInt('-5')).toBeNull();
  });

  it('rejects floats', () => {
    expect(parsePositiveInt('1.5')).toBeNull();
    expect(parsePositiveInt('5.0')).toBeNull();
  });

  it('rejects invalid input', () => {
    expect(parsePositiveInt('')).toBeNull();
    expect(parsePositiveInt('abc')).toBeNull();
    expect(parsePositiveInt('1a')).toBeNull();
  });
});
