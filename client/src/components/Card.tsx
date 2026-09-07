import type { ReactNode } from "react";

/**
 * A hairline line-drawing on the ground: transparent fill, 1px border, square
 * corners. frontend-spec §18.1 — no glass, gradient, floating fill, or shadow.
 */
export function Card({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section className="dm-card">
      {title === undefined ? null : <h2 className="dm-card-title">{title}</h2>}
      {children}
    </section>
  );
}
