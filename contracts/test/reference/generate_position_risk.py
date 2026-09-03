#!/usr/bin/env python3
"""Generate independent integer reference vectors for DreamMargin risk math."""

from fractions import Fraction
import json
from pathlib import Path

BPS = 10_000
WAD = 10**18
YEAR = 365 * 24 * 60 * 60


def floor_fraction(value: Fraction) -> int:
    return value.numerator // value.denominator


def ceil_fraction(value: Fraction) -> int:
    return -(-value.numerator // value.denominator)


def walk(levels: list[tuple[int, int]], quantity: int, one: int, upward: bool) -> dict:
    remaining = quantity
    value = 0
    filled = 0
    for price, available in levels:
        take = min(remaining, available)
        term = Fraction(take * price, one)
        value += ceil_fraction(term) if upward else floor_fraction(term)
        filled += take
        remaining -= take
        if remaining == 0:
            break
    average = 0
    if filled:
        raw_average = Fraction(value * one, filled)
        average = ceil_fraction(raw_average) if upward else floor_fraction(raw_average)
    return {"value": value, "filled": filled, "average": average, "complete": remaining == 0}


def main() -> None:
    normalization = []
    for amount, source, destination in [
        (1, 18, 6),
        (10**12 - 1, 18, 6),
        (10**12, 18, 6),
        (1_234_567, 6, 18),
        (10**18, 18, 6),
    ]:
        if source <= destination:
            down = up = amount * 10 ** (destination - source)
        else:
            ratio = 10 ** (source - destination)
            down = amount // ratio
            up = -(-amount // ratio)
        normalization.append(
            {"amount": amount, "from": source, "to": destination, "down": down, "up": up}
        )

    debt = []
    for shares, index in [(1, WAD), (1, WAD + 1), (10**6, 1_075_000_000_000_000_000)]:
        assets_up = ceil_fraction(Fraction(shares * index, WAD))
        debt.append(
            {
                "shares": shares,
                "index": index,
                "assets_up": assets_up,
                "shares_down": (assets_up * WAD) // index,
            }
        )

    interest = []
    for index, rate, elapsed in [
        (WAD, 0, YEAR),
        (WAD, 50_000_000_000_000_000, 1),
        (WAD, 50_000_000_000_000_000, YEAR),
        (1_234_567_890_123_456_789, 2 * WAD, 10 * YEAR),
    ]:
        if rate == 0 or elapsed == 0:
            next_index = index
        else:
            time_rate = ceil_fraction(Fraction(rate * elapsed, YEAR))
            next_index = index + ceil_fraction(Fraction(index * time_rate, WAD))
        interest.append({"index": index, "rate": rate, "elapsed": elapsed, "next": next_index})

    vault = []
    for amount, supply, assets, virtual_shares, virtual_assets in [
        (1, 0, 0, 10**6, 1),
        (7, 11, 13, 1, 1),
        (10**18, 4 * 10**18, 5 * 10**18, 10**6, 1),
    ]:
        share_ratio = Fraction(amount * (supply + virtual_shares), assets + virtual_assets)
        asset_ratio = Fraction(amount * (assets + virtual_assets), supply + virtual_shares)
        vault.append(
            {
                "amount": amount,
                "supply": supply,
                "assets": assets,
                "virtual_shares": virtual_shares,
                "virtual_assets": virtual_assets,
                "shares_down": floor_fraction(share_ratio),
                "shares_up": ceil_fraction(share_ratio),
                "assets_down": floor_fraction(asset_ratio),
                "assets_up": ceil_fraction(asset_ratio),
            }
        )

    leverage = []
    for equity, leverage_bps in [(0, 10_000), (1, 15_000), (1_000_001, 20_000), (10**18, 50_000)]:
        target = floor_fraction(Fraction(equity * (leverage_bps - BPS), BPS))
        leverage.append({"equity": equity, "leverage_bps": leverage_bps, "target_debt": target})

    leveraged_execution = []
    for equity, leverage_bps, mark_price, limit_side_price in [
        (10_000_000, 20_000, 500_000, 500_000),
        (10_000_000, 20_000, 500_000, 600_000),
        (7_824_000, 12_500, 489_000, 551_000),
    ]:
        nominal = floor_fraction(Fraction(equity * (leverage_bps - BPS), BPS))
        if limit_side_price <= mark_price:
            target = nominal
        else:
            leverage_delta = leverage_bps - BPS
            discounted_equity = floor_fraction(Fraction(equity * leverage_delta, leverage_bps))
            discounted_mark = floor_fraction(Fraction(mark_price * leverage_delta, leverage_bps))
            adjusted = floor_fraction(
                Fraction(
                    discounted_equity * limit_side_price,
                    limit_side_price - discounted_mark,
                )
            )
            target = min(nominal, adjusted)
        leveraged_execution.append(
            {
                "equity": equity,
                "leverage_bps": leverage_bps,
                "mark_price": mark_price,
                "limit_side_price": limit_side_price,
                "target_debt": target,
            }
        )

    liquidation = []
    for debt_assets, bonus, price, available in [
        (1, 0, 600_000, 10**18),
        (1_000_000, 1_000, 600_000, 10**18),
        (1_000_001, 1_000, 333_333, 2_000_000),
    ]:
        with_bonus = ceil_fraction(Fraction(debt_assets * (BPS + bonus), BPS))
        seized = ceil_fraction(Fraction(with_bonus * 1_000_000, price))
        liquidation.append(
            {"debt": debt_assets, "bonus": bonus, "price": price, "available": available, "seized": min(seized, available)}
        )

    bids = [(600_000, 2_000_000), (550_000, 3_000_000), (500_000, 5_000_000)]
    asks = [(350_001, 2_000_000), (400_001, 3_000_000), (450_001, 5_000_000)]
    books = []
    for quantity in [0, 1, 2_000_000, 4_000_000, 11_000_000]:
        books.append(
            {
                "quantity": quantity,
                "bid": walk(bids, quantity, 1_000_000, False),
                "ask": walk(asks, quantity, 1_000_000, True),
            }
        )

    maintenance = []
    for remaining in [3_601, 3_600, 1_800, 1, 0]:
        current = 7_500 if remaining >= 3_600 else floor_fraction(Fraction(7_500 * remaining, 3_600))
        maintenance.append({"remaining": remaining, "current": current})

    payout = []
    for shares, numerator, denominator, fee in [
        (1_000_000, 1, 1, 0),
        (1_000_000, 1, 2, 0),
        (1_000_001, 1, 2, 125),
        (1, 1, 2, 9_999),
    ]:
        gross = floor_fraction(Fraction(shares * 1_000_000, 1_000_000))
        outcome = floor_fraction(Fraction(gross * numerator, denominator))
        net = floor_fraction(Fraction(outcome * (BPS - fee), BPS))
        payout.append(
            {"shares": shares, "numerator": numerator, "denominator": denominator, "fee": fee, "net": net}
        )

    output = {
        "normalization": normalization,
        "debt": debt,
        "interest": interest,
        "vault": vault,
        "leverage": leverage,
        "leveraged_execution": leveraged_execution,
        "liquidation": liquidation,
        "book_levels": {
            "bids": [{"price": p, "quantity": q} for p, q in bids],
            "asks": [{"price": p, "quantity": q} for p, q in asks],
        },
        "books": books,
        "maintenance": maintenance,
        "payout": payout,
    }
    target = Path(__file__).with_name("position-risk-vectors.json")
    target.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
