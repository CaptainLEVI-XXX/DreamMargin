import { describe, expect, it } from "vitest";
import { assertSingleAccentFill } from "./accentGuard";

function mount(html: string): HTMLElement {
  const host = document.createElement("div");
  host.innerHTML = html;
  return host;
}

describe("assertSingleAccentFill", () => {
  it("allows a view with no filled accent", () => {
    expect(() => assertSingleAccentFill(mount("<button>Repay</button>"))).not.toThrow();
  });

  it("allows exactly one filled accent", () => {
    const host = mount("<button data-accent-fill>Add 2x leverage</button>");
    expect(() => assertSingleAccentFill(host)).not.toThrow();
  });

  it("throws when two objects are filled", () => {
    const host = mount(
      "<button data-accent-fill>Buy</button><button data-accent-fill>Open</button>",
    );
    expect(() => assertSingleAccentFill(host)).toThrow(/one solid violet/i);
  });

  it("names the offending count", () => {
    const host = mount(
      "<a data-accent-fill>a</a><a data-accent-fill>b</a><a data-accent-fill>c</a>",
    );
    expect(() => assertSingleAccentFill(host)).toThrow(/3/);
  });
});
