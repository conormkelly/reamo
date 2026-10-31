/**
 * Layout stubs for jsdom, which lays nothing out.
 *
 * TanStack Virtual sizes its scroll element from clientWidth/clientHeight;
 * in jsdom both are 0, so a virtualized list renders no rows. Giving the
 * scroll element a size makes the virtualizer render rows, but not the ones
 * a browser would: each rendered row measures 0 px tall, so only the list's
 * gap separates them and far more fit (in FxParamModal's 320 px list, with
 * its 6 px gap, about 60 rows). Tests can rely on the first rows rendering,
 * not on which rows a scroll position shows.
 */

/**
 * Give elements matching `selector` a client size until the returned
 * function is called.
 *
 * @param selector - CSS selector of the scroll element(s)
 * @param size - Client width and height in px
 * @returns Restores jsdom's own clientWidth/clientHeight
 */
export function stubClientSize(selector: string, size: { width: number; height: number }): () => void {
  const proto = HTMLElement.prototype;
  const original = {
    width: Object.getOwnPropertyDescriptor(Element.prototype, 'clientWidth')!,
    height: Object.getOwnPropertyDescriptor(Element.prototype, 'clientHeight')!,
  };

  Object.defineProperty(proto, 'clientWidth', {
    configurable: true,
    get(this: HTMLElement) {
      return this.matches(selector) ? size.width : original.width.get!.call(this);
    },
  });
  Object.defineProperty(proto, 'clientHeight', {
    configurable: true,
    get(this: HTMLElement) {
      return this.matches(selector) ? size.height : original.height.get!.call(this);
    },
  });

  return () => {
    delete (proto as { clientWidth?: number }).clientWidth;
    delete (proto as { clientHeight?: number }).clientHeight;
  };
}
