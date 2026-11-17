# NBA Trade Feasibility Checker — conservative V1

Drop the `trade_checker/` package and `tests/` folder into the root of `NBA-Trade-Model`.

## Purpose

An **explainable, rule-based filter** for simple 1-for-1 NBA trades, intended to precede the team's player-performance and net-rating models. This is **not** a complete NBA trade machine or league approval.

Implemented:
- Player owned by sending team; different teams and players.
- Externally verified trade window, signing moratorium (ordinary free agents; some Bird/Early Bird raises; rookies), verified extension/trade restrictions, player consent.
- 2026–27 salary-cap, first/second apron configuration.
- Two independently checked salary matching routes: standard and expanded traded player exceptions. The expanded route triggers first-apron restrictions.
- Existing first/second apron hard caps; ordinary roster maximum; flag roster-minimum exceptions for review.
- Strict tri-state output: `ELIGIBLE`, `INELIGIBLE`, `NEEDS_REVIEW`.

Not implemented (requires more modeling): actual team cap accounting, apron-specific post-trade adjustments, minimum contract exception, cap-room paths, pre-existing traded player exceptions, multiple salary-match groups, multi-player aggregation, sign-and-trade, trade kickers, poison-pill, base-year compensation, unguaranteed salary nuances, draft picks, cash, two-way players, all extension restrictions and non-CBA approval steps. **Do not mark underlying records verified unless these fields have been reviewed for the proposed trade.**

## Test

```bash
python -m pytest -q
```

## Example

```python
from datetime import date
from trade_checker import Contract, Team, Trade, check_trade

# FICTIONAL example records, NOT real NBA contracts or real payrolls.
a = Team("A", team_salary=175_000_000, apron_salary=175_000_000,
         roster_standard=15, salary_verified=True,
         roster_verified=True, hard_caps_verified=True)
b = Team("B", team_salary=175_000_000, apron_salary=175_000_000,
         roster_standard=15, salary_verified=True,
         roster_verified=True, hard_caps_verified=True)
x = Contract("X", "A", 10_000_000, 10_000_000, 10_000_000,
             signed_on=date(2025, 7, 1), signing_type="ordinary_fa",
             restricted_until=date(2025, 7, 1), consent_required=False, verified=True)
y = Contract("Y", "B", 15_000_000, 15_000_000, 15_000_000,
             signed_on=date(2025, 7, 1), signing_type="ordinary_fa",
             restricted_until=date(2025, 7, 1), consent_required=False, verified=True)
trade = Trade(date(2026, 11, 16), a, x, b, y, window_verified_open=True)
result = check_trade(trade)
print(result.as_dict())
```

`ELIGIBLE` means **passes only the rules this module implements on verified input facts**. It does not mean the NBA approved the transaction. For an automated generator, run the checker on candidate trades and retain `NEEDS_REVIEW` separately rather than treat them as valid.

## Data you still must source

The existing `data collection/datasets/` game and stint tables do not contain a verified contract ledger, current cap/apron salary totals, acquisition exceptions, consent, or transaction history. Obtain authoritative or vetted 2026–27 team and player contract snapshots, trade salaries, and league dates. Do not infer contract salary from player performance or game stats.

## Rule sources

- [2023 NBA–NBPA CBA](https://www.nbpa.com/cba), mainly Article VII §§2, 4, 6, 8.
- [Official CBA PDF](https://imgix.cosmicjs.com/25da5eb0-15eb-11ee-b5b3-fbd321202bdf-Final-2023-NBA-Collective-Bargaining-Agreement-6-28-23.pdf)
- [NBA 2026–27 cap announcement](https://www.nba.com/news/nba-salary-cap-2026-27-season)

## Next improvements

1. Build verified salary/roster/exception snapshot loader and cap/apron salary calculator.
2. Add minimum-salary and under-cap acquisitions and existing TPE ledgers.
3. Add comprehensive player moratoria, non-guarantees and trade bonus salary accounting.
4. Support multi-player aggregation, picks, cash and sign-and-trade.
5. Regression-test against real, dated NBA transactions and official trade rules.
