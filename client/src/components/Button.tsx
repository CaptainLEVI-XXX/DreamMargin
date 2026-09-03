import type { ButtonHTMLAttributes, ReactNode } from "react";
import { useId } from "react";

type Variant = "primary" | "secondary" | "tertiary";

type Props = Omit<ButtonHTMLAttributes<HTMLButtonElement>, "className"> & {
  variant: Variant;
  children: ReactNode;
  /**
   * Why the action is unavailable. frontend-spec §23 requires every disabled
   * action to explain itself, so this is mandatory whenever `disabled` is set.
   */
  disabledReason?: string;
};

/**
 * The one violet-filled object in a view is a primary button, which carries
 * `data-accent-fill` for the development guard. Secondary buttons are
 * transparent with a neutral border; tertiary buttons are text only.
 * frontend-spec §18.3.
 */
export function Button({ variant, children, disabled, disabledReason, ...rest }: Props) {
  const describedBy = useId();
  const showReason = disabled === true && disabledReason !== undefined;

  return (
    <>
      <button
        className={`dm-button dm-button-${variant}`}
        data-accent-fill={variant === "primary" ? "" : undefined}
        disabled={disabled}
        aria-describedby={showReason ? describedBy : undefined}
        {...rest}
      >
        {children}
      </button>
      {showReason ? (
        <span id={describedBy} className="dm-button-reason">
          {disabledReason}
        </span>
      ) : null}
    </>
  );
}
