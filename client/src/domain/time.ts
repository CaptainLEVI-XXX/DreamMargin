/** Compact long-market duration, optionally retaining seconds for detail views. */
export function formatTimeLeft(seconds: bigint, includeSeconds = false): string {
  const totalMinutes = includeSeconds ? seconds / 60n : (seconds + 59n) / 60n;
  const days = totalMinutes / 1_440n;
  const hours = (totalMinutes % 1_440n) / 60n;
  const minutes = totalMinutes % 60n;
  const pad = (value: bigint) => String(value).padStart(2, "0");
  const base = `${days}d : ${pad(hours)}h : ${pad(minutes)}m`;
  return includeSeconds ? `${base} : ${pad(seconds % 60n)}s` : base;
}
