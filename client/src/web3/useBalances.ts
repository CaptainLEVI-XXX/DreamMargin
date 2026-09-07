import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { createReadClient } from "./client";
import { EMPTY_BALANCES, readBalances, type Balances } from "./tokens";

/**
 * Wallet balances for one market's outcome pair, refetchable after any write.
 *
 * `refresh` is what an intent's reconcile step calls: §12 requires
 * authoritative reads after a receipt rather than trusting submitted values.
 *
 * Results carry the account they belong to, so a disconnect or an account
 * switch renders empty without a synchronous setState cascading renders, and a
 * response for a previous account is never displayed against a new one.
 */
export function useBalances(account: Address | null, yesId: bigint, noId: bigint, pool: Address) {
  const key = `${account ?? "none"}|${yesId}|${noId}|${pool}`;
  const [entry, setEntry] = useState<{ key: string; balances: Balances }>({
    key,
    balances: EMPTY_BALANCES,
  });
  const [version, setVersion] = useState(0);

  const refresh = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    if (account === null) return;
    let cancelled = false;

    void readBalances(createReadClient(), account, yesId, noId, pool)
      .then((balances) => {
        if (!cancelled) setEntry({ key, balances });
      })
      .catch(() => {
        if (!cancelled) setEntry({ key, balances: EMPTY_BALANCES });
      });

    return () => {
      cancelled = true;
    };
  }, [key, account, yesId, noId, pool, version]);

  return { balances: entry.key === key ? entry.balances : EMPTY_BALANCES, refresh };
}
