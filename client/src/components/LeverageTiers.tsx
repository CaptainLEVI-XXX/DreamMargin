import { formatMultiple, tiersFor } from "../domain/leverageTiers";

type Props = {
  maxLeverageBps: bigint;
  selected: bigint;
  onSelect: (leverageBps: bigint) => void;
};

/**
 * Discrete tier chips. FS-2 replaces §8.3's 1x-5x slider because the deployed
 * maximum is 2.0x, where a slider gives coarse control and invites fiddling.
 *
 * The selected chip uses the violet outline and tint treatment, never a solid
 * fill: §18.3 reserves the one solid violet object for the primary action.
 */
export function LeverageTiers({ maxLeverageBps, selected, onSelect }: Props) {
  const tiers = tiersFor(maxLeverageBps);

  return (
    <div className="dm-tiers" role="radiogroup" aria-label="Leverage">
      {tiers.map((tier) => (
        <button
          key={String(tier)}
          type="button"
          role="radio"
          aria-checked={tier === selected}
          className="dm-tier"
          data-selected={tier === selected ? "" : undefined}
          onClick={() => onSelect(tier)}
        >
          {formatMultiple(tier)}
        </button>
      ))}
    </div>
  );
}
