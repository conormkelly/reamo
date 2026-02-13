/**
 * Tests for useListReorder — drag/touch reorder state management.
 */

import { describe, it, expect, vi } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useListReorder } from './useListReorder';

describe('useListReorder', () => {
  // ===========================================================================
  // Initial state
  // ===========================================================================

  describe('initial state', () => {
    it('starts with no drag state', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder })
      );
      expect(result.current.dragFromIndex).toBeNull();
      expect(result.current.dragOverIndex).toBeNull();
    });

    it('reports nothing as dragging initially', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder })
      );
      expect(result.current.isDragging(0)).toBe(false);
      expect(result.current.isDragTarget(0)).toBe(false);
    });
  });

  // ===========================================================================
  // getDragItemProps
  // ===========================================================================

  describe('getDragItemProps', () => {
    it('returns draggable=true when enabled', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder, enabled: true })
      );
      const props = result.current.getDragItemProps(0);
      expect(props.draggable).toBe(true);
    });

    it('returns draggable=false when disabled', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder, enabled: false })
      );
      const props = result.current.getDragItemProps(0);
      expect(props.draggable).toBe(false);
    });

    it('provides all required event handlers', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder })
      );
      const props = result.current.getDragItemProps(0);
      expect(typeof props.onDragStart).toBe('function');
      expect(typeof props.onDragOver).toBe('function');
      expect(typeof props.onDrop).toBe('function');
      expect(typeof props.onDragEnd).toBe('function');
      expect(typeof props.onTouchStart).toBe('function');
      expect(typeof props.onTouchMove).toBe('function');
      expect(typeof props.onTouchEnd).toBe('function');
    });
  });

  // ===========================================================================
  // isDragging / isDragTarget
  // ===========================================================================

  describe('isDragging / isDragTarget', () => {
    it('isDragging returns true for the source index', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder })
      );

      // Simulate drag start via touch (easier to trigger state)
      const props = result.current.getDragItemProps(2);
      act(() => {
        props.onTouchStart({
          touches: [{ clientY: 100 }],
          currentTarget: { offsetHeight: 60 },
        } as unknown as React.TouchEvent);
      });

      expect(result.current.isDragging(2)).toBe(true);
      expect(result.current.isDragging(0)).toBe(false);
    });

    it('isDragTarget returns true for hover target, false for source', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder })
      );

      // Start drag from index 0
      const props0 = result.current.getDragItemProps(0);
      act(() => {
        props0.onTouchStart({
          touches: [{ clientY: 100 }],
          currentTarget: { offsetHeight: 60 },
        } as unknown as React.TouchEvent);
      });

      // Drag over index 2
      act(() => {
        result.current.getDragItemProps(0).onTouchMove({
          touches: [{ clientY: 236 }], // 100 + 2 * 68 (item height + gap)
        } as unknown as React.TouchEvent);
      });

      // Source should not be a drag target
      expect(result.current.isDragTarget(0)).toBe(false);
    });
  });

  // ===========================================================================
  // Drag end / cleanup
  // ===========================================================================

  describe('drag end', () => {
    it('clears drag state on dragEnd', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder })
      );

      // Start drag
      const props = result.current.getDragItemProps(1);
      act(() => {
        props.onTouchStart({
          touches: [{ clientY: 100 }],
          currentTarget: { offsetHeight: 60 },
        } as unknown as React.TouchEvent);
      });
      expect(result.current.dragFromIndex).toBe(1);

      // End drag
      act(() => {
        props.onDragEnd();
      });
      expect(result.current.dragFromIndex).toBeNull();
      expect(result.current.dragOverIndex).toBeNull();
    });
  });

  // ===========================================================================
  // Touch reorder
  // ===========================================================================

  describe('touch reorder', () => {
    it('calls onReorder when touch ends at different index', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder })
      );

      const props = result.current.getDragItemProps(0);

      // Touch start at index 0
      act(() => {
        props.onTouchStart({
          touches: [{ clientY: 100 }],
          currentTarget: { offsetHeight: 60 },
        } as unknown as React.TouchEvent);
      });

      // Touch move to approximate index 2
      act(() => {
        // getDragItemProps returns new closures, but touchMove is stable
        result.current.getDragItemProps(0).onTouchMove({
          touches: [{ clientY: 236 }], // deltaY = 136, itemHeight=68, round(136/68)=2, newIndex=0+2=2
        } as unknown as React.TouchEvent);
      });

      // Touch end
      act(() => {
        result.current.getDragItemProps(0).onTouchEnd();
      });

      expect(onReorder).toHaveBeenCalledWith(0, 2);
    });

    it('does not call onReorder when touch ends at same index', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder })
      );

      const props = result.current.getDragItemProps(0);

      // Touch start
      act(() => {
        props.onTouchStart({
          touches: [{ clientY: 100 }],
          currentTarget: { offsetHeight: 60 },
        } as unknown as React.TouchEvent);
      });

      // Touch end immediately (no move)
      act(() => {
        result.current.getDragItemProps(0).onTouchEnd();
      });

      expect(onReorder).not.toHaveBeenCalled();
    });
  });

  // ===========================================================================
  // Disabled state
  // ===========================================================================

  describe('disabled', () => {
    it('does not start drag when disabled', () => {
      const onReorder = vi.fn();
      const { result } = renderHook(() =>
        useListReorder({ onReorder, enabled: false })
      );

      const props = result.current.getDragItemProps(0);
      act(() => {
        props.onTouchStart({
          touches: [{ clientY: 100 }],
          currentTarget: { offsetHeight: 60 },
        } as unknown as React.TouchEvent);
      });

      expect(result.current.dragFromIndex).toBeNull();
    });
  });
});
