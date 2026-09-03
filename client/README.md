# dreammargin client

Web client for the dreammargin protocol on the Somnia Shannon testnet.

## Commands

```sh
npm install
npm run dev          # local development server
npm run build        # production build
npm run typecheck    # TypeScript only
npm run lint         # ESLint
npm run format       # Prettier, writes in place
npm run test         # Vitest
```

Run the formatter, linter, type checker, tests, and production build before
requesting review.

## Conventions

All token amounts, prices, ratios, and debt are `bigint` in native units until
formatted for display. Never use floating-point numbers for money; use the
helpers in `src/domain/amounts.ts`. ESLint rejects `parseFloat` for this reason.

Presentational components accept already-normalized display models and never
recompute protocol risk.

Exactly one object per view may carry a solid violet fill. Mark it with
`data-accent-fill`; `src/dev/accentGuard.ts` fails when a second appears.

Risk is never signalled by colour alone. `RiskState` requires a label and an
icon alongside the colour band, so a colour-only risk display cannot be
constructed.

## Layout

```text
src/
  components/   presentational only
  domain/       pure bigint money and risk logic, no React
  dev/          development-time invariant guards
  styles/       brand tokens and base stylesheet
```
