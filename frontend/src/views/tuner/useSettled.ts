import { useEffect, useState } from 'react';

/**
 * `value` once it has held for `ms`: a value that changes back sooner is
 * never taken. For what a live region says, which a screen reader speaks
 * on every change.
 */
export function useSettled<T>(value: T, ms: number): T {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setSettled(value), ms);
    return () => clearTimeout(timer);
  }, [value, ms]);
  return settled;
}
