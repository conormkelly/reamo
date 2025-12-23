/**
 * Region edit operations barrel export
 */

export {
  getMinRegionLength,
  snapToBeats,
  calculateResizeRipple,
  calculateMoveRipple,
  calculateCreateRipple,
  calculateDeleteRipple,
  type ResizeRippleParams,
  type MoveRippleParams,
  type CreateRippleParams,
  type CreateRippleResult,
  type DeleteRippleParams,
} from './rippleOperations';

export {
  calculateDragPreview,
  type DragPreviewState,
  type DragPreviewResult,
} from './dragPreview';
