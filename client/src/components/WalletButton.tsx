import { useState } from "react";
import { shortenAddress, type WalletState } from "../web3/wallet";

type Props = {
  state: WalletState;
  onConnect: () => void;
  onSwitchChain: () => void;
  onDisconnect?: () => void;
};

/**
 * Compact wallet identity control: shortened address, network, and disconnect.
 * Testnet funds remain separate header utilities so this menu has one job.
 *
 * A wrong network is a page-level state (§6.3 handles the alert), so this
 * surfaces the switch action without pretending the app is usable.
 */
export function WalletButton({ state, onConnect, onSwitchChain, onDisconnect }: Props) {
  const [open, setOpen] = useState(false);
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
    <span className="dm-wallet-menu">
      <button
        type="button"
        className="dm-wallet-account"
        title={state.account}
        aria-expanded={open}
        aria-haspopup="menu"
        onClick={() => setOpen((current) => !current)}
      >
        <span className="dm-wallet-dot" aria-hidden="true" />
        <span>{shortenAddress(state.account)}</span>
        <span className="dm-wallet-divider" aria-hidden="true" />
        <span className="dm-wallet-network">Shannon</span>
        <span className="dm-wallet-chevron" aria-hidden="true">
          ⌄
        </span>
      </button>
      {open ? (
        <span className="dm-wallet-popover" role="menu">
          <span className="dm-wallet-popover-label">Connected wallet</span>
          <span className="dm-wallet-popover-address">{shortenAddress(state.account)}</span>
          <span className="dm-wallet-popover-network">
            <small>Network</small>
            <span>Shannon</span>
          </span>
          {onDisconnect === undefined ? null : (
            <button
              type="button"
              className="dm-wallet-menu-action dm-wallet-disconnect"
              role="menuitem"
              onClick={() => {
                setOpen(false);
                onDisconnect();
              }}
            >
              Disconnect
            </button>
          )}
        </span>
      ) : null}
    </span>
  );
}
