/**
 * The document and window listeners for one drag on a track control.
 *
 * A drag ends on mouseup, touchend or touchcancel. It also ends when the
 * window loses focus or the page is hidden: the release can then go to
 * another app or never come (Cmd/Alt-Tab, a phone locked mid-drag), and a
 * touch the browser cancels sends no touchend.
 *
 * @param onMove - called for each mouse or touch move during the drag
 * @param onEnd - called once for whichever end comes first; it should call
 *   the returned function
 * @returns a function that removes every listener this added
 */
export function listenToTrackDrag(
  onMove: (event: MouseEvent | TouchEvent) => void,
  onEnd: () => void
): () => void {
  const onVisibilityChange = () => {
    if (document.visibilityState === 'hidden') onEnd();
  };

  document.addEventListener('mousemove', onMove);
  document.addEventListener('mouseup', onEnd);
  document.addEventListener('touchmove', onMove, { passive: false });
  document.addEventListener('touchend', onEnd);
  document.addEventListener('touchcancel', onEnd);
  document.addEventListener('visibilitychange', onVisibilityChange);
  window.addEventListener('blur', onEnd);

  return () => {
    document.removeEventListener('mousemove', onMove);
    document.removeEventListener('mouseup', onEnd);
    document.removeEventListener('touchmove', onMove);
    document.removeEventListener('touchend', onEnd);
    document.removeEventListener('touchcancel', onEnd);
    document.removeEventListener('visibilitychange', onVisibilityChange);
    window.removeEventListener('blur', onEnd);
  };
}
