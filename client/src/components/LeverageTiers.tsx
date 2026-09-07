export type LeverageOption = {
  id: string;
  label: string;
};

type Props = {
  options: readonly LeverageOption[];
  selected: string;
  onSelect: (id: string) => void;
};

/**
 * Discrete cash-on-cash choices. Contract risk parameters are deliberately not
 * rendered here: each option describes the leverage the current quote delivers.
 *
 * The selected chip uses the violet outline and tint treatment, never a solid
 * fill: §18.3 reserves the one solid violet object for the primary action.
 */
export function LeverageTiers({ options, selected, onSelect }: Props) {
  return (
    <div className="dm-tiers" role="radiogroup" aria-label="Estimated leverage">
      {options.map((option) => (
        <button
          key={option.id}
          type="button"
          role="radio"
          aria-checked={option.id === selected}
          className="dm-tier"
          data-selected={option.id === selected ? "" : undefined}
          onClick={() => onSelect(option.id)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}
