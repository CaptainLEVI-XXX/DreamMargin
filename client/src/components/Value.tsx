import type { ReactNode } from "react";

/**
 * A financial value. Uses JetBrains Mono with tabular figures so a refreshing
 * quote never changes layout width. frontend-spec §18.2 and §4.10.
 */
export function Value({ children }: { children: ReactNode }) {
  return <span className="dm-value">{children}</span>;
}
