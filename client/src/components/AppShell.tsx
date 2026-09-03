import type { ReactNode } from "react";

export type Route = "markets" | "positions" | "earn";

const DESTINATIONS: ReadonlyArray<{ route: Route; label: string }> = [
  { route: "markets", label: "Markets" },
  { route: "positions", label: "Positions" },
  { route: "earn", label: "Earn" },
];

type Props = {
  route: Route;
  onNavigate: (route: Route) => void;
  children: ReactNode;
  /** Wallet control rendered at the end of the header. */
  wallet?: ReactNode;
};

/**
 * Desktop header plus mobile bottom navigation over the same three primary
 * tasks. frontend-spec §6.1 and §6.2. The wordmark is always lowercase and the
 * mark is white on the dark ground, never violet. No high-risk action such as
 * `Open` appears in global navigation.
 */
export function AppShell({ route, onNavigate, children, wallet }: Props) {
  const links = DESTINATIONS.map(({ route: target, label }) => (
    <a
      key={target}
      href={`/${target}`}
      aria-current={route === target ? "page" : undefined}
      onClick={(event) => {
        event.preventDefault();
        onNavigate(target);
      }}
    >
      {label}
    </a>
  ));

  return (
    <div className="dm-shell">
      <header className="dm-header">
        <span className="dm-lockup">
          <span className="dm-mark" aria-hidden="true">
            {"{d×}"}
          </span>
          <span className="dm-wordmark">dreammargin</span>
        </span>
        <nav className="dm-nav-desktop" aria-label="Primary">
          {links}
        </nav>
        <span className="dm-header-right">{wallet}</span>
      </header>

      <main className="dm-main">{children}</main>

      <nav className="dm-nav-mobile" aria-label="Primary mobile">
        {links}
      </nav>
    </div>
  );
}
