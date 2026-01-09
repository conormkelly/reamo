/**
 * Tests for Modal component
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { Modal } from './Modal';

describe('Modal', () => {
  const defaultProps = {
    isOpen: true,
    onClose: vi.fn(),
    title: 'Test Modal',
    children: <div>Modal content</div>,
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    cleanup();
  });

  describe('rendering', () => {
    it('renders when isOpen is true', () => {
      render(<Modal {...defaultProps} />);
      expect(screen.getByText('Test Modal')).toBeInTheDocument();
      expect(screen.getByText('Modal content')).toBeInTheDocument();
    });

    it('does not render when isOpen is false', () => {
      render(<Modal {...defaultProps} isOpen={false} />);
      expect(screen.queryByText('Test Modal')).not.toBeInTheDocument();
    });

    it('renders close button by default', () => {
      render(<Modal {...defaultProps} />);
      expect(screen.getByLabelText('Close modal')).toBeInTheDocument();
    });

    it('hides close button when showCloseButton is false', () => {
      render(<Modal {...defaultProps} showCloseButton={false} />);
      expect(screen.queryByLabelText('Close modal')).not.toBeInTheDocument();
    });

    it('renders icon when provided', () => {
      render(<Modal {...defaultProps} icon={<span data-testid="test-icon">Icon</span>} />);
      expect(screen.getByTestId('test-icon')).toBeInTheDocument();
    });
  });

  describe('close button', () => {
    it('calls onClose when close button is clicked', () => {
      render(<Modal {...defaultProps} />);
      fireEvent.click(screen.getByLabelText('Close modal'));
      expect(defaultProps.onClose).toHaveBeenCalledTimes(1);
    });
  });

  describe('backdrop click', () => {
    it('calls onClose when backdrop is clicked', () => {
      render(<Modal {...defaultProps} />);
      // Click the backdrop (outer fixed div), not the inner dialog panel
      const backdrop = screen.getByTestId('modal-backdrop');
      fireEvent.click(backdrop);
      expect(defaultProps.onClose).toHaveBeenCalledTimes(1);
    });

    it('does not call onClose when modal content is clicked', () => {
      render(<Modal {...defaultProps} />);
      fireEvent.click(screen.getByText('Modal content'));
      expect(defaultProps.onClose).not.toHaveBeenCalled();
    });

    it('does not close on backdrop click when closeOnBackdrop is false', () => {
      render(<Modal {...defaultProps} closeOnBackdrop={false} />);
      const backdrop = screen.getByRole('dialog');
      fireEvent.click(backdrop);
      expect(defaultProps.onClose).not.toHaveBeenCalled();
    });
  });

  describe('escape key', () => {
    it('calls onClose when Escape key is pressed', () => {
      render(<Modal {...defaultProps} />);
      fireEvent.keyDown(document, { key: 'Escape' });
      expect(defaultProps.onClose).toHaveBeenCalledTimes(1);
    });

    it('does not call onClose for other keys', () => {
      render(<Modal {...defaultProps} />);
      fireEvent.keyDown(document, { key: 'Enter' });
      expect(defaultProps.onClose).not.toHaveBeenCalled();
    });

    it('does not close on Escape when closeOnEscape is false', () => {
      render(<Modal {...defaultProps} closeOnEscape={false} />);
      fireEvent.keyDown(document, { key: 'Escape' });
      expect(defaultProps.onClose).not.toHaveBeenCalled();
    });

    it('removes event listener when modal closes', () => {
      const { rerender } = render(<Modal {...defaultProps} />);
      rerender(<Modal {...defaultProps} isOpen={false} />);

      // Escape should not trigger anything after modal is closed
      fireEvent.keyDown(document, { key: 'Escape' });
      expect(defaultProps.onClose).not.toHaveBeenCalled();
    });
  });

  describe('width variants', () => {
    it('applies correct width class for sm', () => {
      render(<Modal {...defaultProps} width="sm" />);
      // The inner modal panel (not the backdrop)
      const modalPanel = screen.getByText('Modal content').closest('div[tabindex="-1"]');
      expect(modalPanel).toHaveClass('max-w-xs');
    });

    it('applies correct width class for md (default)', () => {
      render(<Modal {...defaultProps} />);
      const modalPanel = screen.getByText('Modal content').closest('div[tabindex="-1"]');
      expect(modalPanel).toHaveClass('max-w-sm');
    });

    it('applies correct width class for lg', () => {
      render(<Modal {...defaultProps} width="lg" />);
      const modalPanel = screen.getByText('Modal content').closest('div[tabindex="-1"]');
      expect(modalPanel).toHaveClass('max-w-md');
    });

    it('applies correct width class for xl', () => {
      render(<Modal {...defaultProps} width="xl" />);
      const modalPanel = screen.getByText('Modal content').closest('div[tabindex="-1"]');
      expect(modalPanel).toHaveClass('max-w-lg');
    });
  });

  describe('accessibility', () => {
    it('has role="dialog"', () => {
      render(<Modal {...defaultProps} />);
      expect(screen.getByRole('dialog')).toBeInTheDocument();
    });

    it('has aria-modal="true"', () => {
      render(<Modal {...defaultProps} />);
      expect(screen.getByRole('dialog')).toHaveAttribute('aria-modal', 'true');
    });

    it('has aria-labelledby pointing to title', () => {
      render(<Modal {...defaultProps} />);
      const dialog = screen.getByRole('dialog');
      expect(dialog).toHaveAttribute('aria-labelledby', 'modal-title');
      expect(screen.getByText('Test Modal')).toHaveAttribute('id', 'modal-title');
    });
  });
});
