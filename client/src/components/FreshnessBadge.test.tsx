import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { FreshnessBadge } from "./FreshnessBadge";
import { freshnessOf } from "../domain/freshness";
import type { OracleSnapshot } from "../web3/reads";

const fresh: OracleSnapshot = {
  mark: 605_000n,
  updatedSecondsAgo: 18,
  stale: false,
  cardinality: 12,
  maxObservations: 16,
};

/** The oracle state actually read from Shannon: 2 of 16, long past staleAfter. */
const liveStale: OracleSnapshot = {
  mark: null,
  updatedSecondsAgo: 61_580,
  stale: true,
  cardinality: 2,
  maxObservations: 16,
  reason: "Risk data is stale",
};

describe("freshnessOf", () => {
  it("calls a recent observation live", () => {
    expect(freshnessOf(fresh)).toBe("live");
  });

  it("calls an older but valid observation delayed", () => {
    expect(freshnessOf({ ...fresh, updatedSecondsAgo: 120 })).toBe("delayed");
  });

  it("calls a past-window observation stale", () => {
    expect(freshnessOf(liveStale)).toBe("stale");
  });

  it("distinguishes an immature ring from a stale one", () => {
    expect(freshnessOf({ ...fresh, mark: null })).toBe("building");
  });
});

describe("FreshnessBadge", () => {
  it("states the age rather than showing an unlabelled dot", () => {
    render(<FreshnessBadge snapshot={fresh} />);
    expect(screen.getByText("18s ago")).toBeVisible();
    expect(screen.getByText("Live")).toBeVisible();
  });

  it("shows ring maturity so a keeper gap is visible", () => {
    render(<FreshnessBadge snapshot={liveStale} />);
    expect(screen.getByText("2/16")).toBeVisible();
  });

  it("reports staleness in words, not colour alone", () => {
    render(<FreshnessBadge snapshot={liveStale} />);
    expect(screen.getByText("Risk data stale")).toBeVisible();
    expect(screen.getByText("Risk data is stale")).toBeVisible();
  });

  it("renders a long age in hours rather than raw seconds", () => {
    render(<FreshnessBadge snapshot={liveStale} />);
    expect(screen.getByText("17h ago")).toBeVisible();
  });

  it("offers no refresh action, because one click cannot clear staleness", () => {
    render(<FreshnessBadge snapshot={liveStale} />);
    expect(screen.queryByRole("button")).toBeNull();
  });
});
