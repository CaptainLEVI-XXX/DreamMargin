/**
 * frontend-spec §18.3: violet may fill only one object per view — the primary
 * action, or the active leverage multiple when no action is present. Secondary
 * actions are transparent with a neutral border; tertiary actions are text only.
 *
 * Mark the single filled object with `data-accent-fill`. This guard runs in
 * development and in tests so a second filled object fails loudly rather than
 * surviving until a screenshot audit.
 */

const ACCENT_SELECTOR = "[data-accent-fill]";

/** Throw when a view contains more than one solid-violet object. */
export function assertSingleAccentFill(root: ParentNode = document): void {
  const filled = root.querySelectorAll(ACCENT_SELECTOR);
  if (filled.length > 1) {
    throw new Error(`only one solid violet object is allowed per view, found ${filled.length}`);
  }
}
