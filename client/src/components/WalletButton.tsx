import { Button } from "./Button";
import { Value } from "./Value";
import { formatUnits } from "../domain/amounts";
import { shortenAddress, type WalletState } from "../web3/wallet";

type Props = {
  state: WalletState;
  onConnect: () => void;
  onSwitchChain: () => void;
  /** tUSDC balance, shown beside the address. */
  collateral?: bigint;
  /** Testnet faucet. Belongs with the wallet, not in the trading flow. */
  onFaucet?: () => void;
};

/**
 * Compact wallet control. §6.1: identicon, shortened address, and a small
 * network state — balances belong in its popover, not the global header.
 *
 * A wrong network is a page-level state (§6.3 handles the alert), so this
 * surfaces the switch action without pretending the app is usable.
 */
export function WalletButton({ state, onConnect, onSwitchChain, collateral, onFaucet }: Props) {
  if (state.status === "unavailable") {
    return <span className="dm-wallet dm-wallet-note">No wallet detected</span>;
  }

  if (state.status === "disconnected") {
    return (
      <span className="dm-wallet">
        <Button variant="secondary" onClick={onConnect}>
          Connect wallet
        </Button>
      </span>
    );
  }

  if (state.wrongChain) {
    return (
      <span className="dm-wallet">
        <Button variant="secondary" onClick={onSwitchChain}>
          Switch network
        </Button>
      </span>
    );
  }

  return (
    <span className="dm-wallet">
      {collateral === undefined ? null : (
        <span className="dm-wallet-network">
          <Value>{formatUnits(collateral, 6)}</Value> tUSDC
        </span>
      )}
      {onFaucet === undefined ? null : (
        <Button variant="tertiary" onClick={onFaucet}>
          Get tUSDC
        </Button>
      )}
      <span className="dm-wallet-account" title={state.account}>
        <span className="dm-wallet-dot" aria-hidden="true" />
        <span>{shortenAddress(state.account)}</span>
        <span className="dm-wallet-network">Shannon</span>
      </span>
    </span>
  );
}
