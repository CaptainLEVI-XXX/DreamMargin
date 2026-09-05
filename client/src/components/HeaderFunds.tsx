import { formatUnits } from "../domain/amounts";
import { Value } from "./Value";

type Props = {
  collateral: bigint;
  onFaucet: () => void;
};

/** Testnet funds are visible utilities, separate from wallet identity actions. */
export function HeaderFunds({ collateral, onFaucet }: Props) {
  return (
    <span className="dm-header-funds">
      <span className="dm-wallet-balance" aria-label="tUSDC balance">
        <Value>{formatUnits(collateral, 6, 2)}</Value>
        <small>tUSDC</small>
      </span>
      <button type="button" className="dm-faucet" onClick={onFaucet}>
        Faucet
      </button>
    </span>
  );
}
