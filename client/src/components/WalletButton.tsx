import { Button } from "./Button";
import { shortenAddress, type WalletState } from "../web3/wallet";

type Props = {
  state: WalletState;
  onConnect: () => void;
  onSwitchChain: () => void;
};

/**
 * Compact wallet control. §6.1: identicon, shortened address, and a small
 * network state — balances belong in its popover, not the global header.
 *
 * A wrong network is a page-level state (§6.3 handles the alert), so this
 * surfaces the switch action without pretending the app is usable.
 */
export function WalletButton({ state, onConnect, onSwitchChain }: Props) {
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
    <span className="dm-wallet dm-wallet-account" title={state.account}>
      <span className="dm-wallet-dot" aria-hidden="true" />
      <span>{shortenAddress(state.account)}</span>
      <span className="dm-wallet-network">Shannon</span>
    </span>
  );
}
