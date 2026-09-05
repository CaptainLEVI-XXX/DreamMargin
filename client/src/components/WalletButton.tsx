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
        <button type="button" className="dm-faucet" onClick={onConnect}>
          Connect wallet
        </button>
      </span>
    );
  }

  if (state.wrongChain) {
    return (
      <span className="dm-wallet">
        <button type="button" className="dm-faucet" onClick={onSwitchChain}>
          Switch network
        </button>
      </span>
    );
  }

  return (
    <span className="dm-wallet">
      {collateral === undefined ? null : (
        <span className="dm-wallet-balance">
          <Value>{formatUnits(collateral, 6, 2)}</Value>
          <small>tUSDC</small>
        </span>
      )}
      {onFaucet === undefined ? null : (
        <button type="button" className="dm-faucet" onClick={onFaucet}>
          Get tUSDC
        </button>
      )}
      <span className="dm-wallet-account" title={state.account}>
        <span className="dm-wallet-dot" aria-hidden="true" />
        <span>{shortenAddress(state.account)}</span>
        <span className="dm-wallet-network">Shannon</span>
      </span>
    </span>
  );
}
