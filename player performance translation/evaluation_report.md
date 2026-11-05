# Player performance translation: Phase 1

## What this version establishes

The held-out test contains 1905 player periods, including 286 transfers and only 7 verified trades. Aggregate transfer results and verified-trade results must be read separately.

Verified-trade performance against carrying forward old-team averages:

- minutes: carry-forward MAE 1.100; translator 1.552 (worse).
- usg: carry-forward MAE 1.818; translator 1.206 (better).
- ts: carry-forward MAE 1.281; translator 3.130 (worse).
- ast: carry-forward MAE 3.646; translator 4.481 (worse).

This is an experimental predictive baseline. Broad transfer improvements do not establish reliable trade-specific performance or a causal team-change effect. A complete transaction history and better contemporaneous roster/injury information are needed before trade-impact integration. The examples below include failures as well as successes.

## Run and reuse

Install `data.table` and `glmnet`, then run from the repository root:

```sh
Rscript "player performance translation/player_translation_evaluation.R"
```

In RStudio, source that file and call `result <- run_player_translation()`. The result keeps observations and predictions in memory. `predict_player_translation(model, newdata)` accepts pre-period features and `transfer`; outcomes are not required.

For a hypothetical destination, build `newdata <- result$data$make_scenario(player_id, destination_team_id, cutoff)` and call `predict_player_translation(result$model, newdata)`. The cutoff is an R `Date` or ISO date string. It must be later than the saved model's training labels. The scenario builder does not require any future appearances or outcomes.

Only `player_translation_model.rds` and this report are saved. No intermediate datasets, prediction CSVs or plots are exported.

## Observation and timing contract

- Windows: 40 played appearances; stayer target stride: 40. Targets can cross seasons, but cannot cross another team change.
- Minutes means minutes per played appearance. USG%, TS% and AST% use aggregate window totals, in percentage points. USG and AST are box-score estimates, not exact on-court NBA measures.
- Each transfer has one prediction before its first destination appearance, requiring a full old-team history and a full same-destination target. Stayer targets are nonoverlapping within each player/team episode.
- Verified moves use the transaction day as cutoff, with all same-day games excluded. Other transfers use the start of the last old-team game day: conservative, but often much earlier than the real move. Their mechanism and exact date remain unknown.
- Both team snapshots contain only games before the cutoff (last 40 team games, at least 20). Roster proxies use those games and activity in their last 10 games, excluding the focal player.
- Player history, trends, age and prior-season BPM are historical inputs. Names are used only for reporting. No current-season completed BRef statistics, target dates, player IDs or realized post-move role enter the models.

## Chronological development and sample counts

Train labels end before 2018-07-01. Validation predictions start on/after that date and their labels finish before 2021-07-01. Final test predictions start on/after 2021-07-01.

| Split | Periods | Stayers | Transfers | Verified_trades |
| --- | --- | --- | --- | --- |
| train | 3511 | 2862 | 649 | 6 |
| validation | 855 | 690 | 165 | 2 |
| development | 4649 | 3767 | 882 | 8 |
| test | 1905 | 1619 | 286 | 7 |

568 boundary-crossing periods are purged from the original tuning splits. Final development refits use every label completed before the test start. Test outcomes never select hyperparameters.
Model B uses 326 transfer residuals for tuning fits and 559 for final fitting, each from an earlier-year Model A fit. 6 of the final residuals are verified trades.
Detected team changes: 3560. Eligible complete transfer windows: 1246. Verified registry entries: 16; matched movement entries: 16.

Candidate exclusions (first failed requirement; also includes stayer candidates):

| Reason | Count |
| --- | --- |
| insufficient_player_history | 1461 |
| incomplete_target | 853 |
| insufficient_team_history | 0 |
| undefined_target_or_history | 0 |

## Models and tuning

Model A fits all eligible periods using player performance, older-window trends and current-team context. Model B predicts residuals for movers using player history, destination context and destination-minus-origin differences. Stayers receive zero adjustment. A player-only adjustment is trained as the destination-context ablation.
Four separate standardized ridge regressions keep each target interpretable and allow separate shrinkage. A joint-output model is deferred: the outcomes have different noise and units, and the small transfer sample does not support a more complex shared model yet.
All imputation and scaling are fitted on training rows. Lambda is selected by validation MAE. Historical residual folds tune their own baseline lambda inside an earlier chronological inner split, never using later validation or test labels. Model B additionally compares verified-trade weights of 1 and 2 and adjustment scales of 0, 0.5 and 1, using the same validation movers. Zero scale is a valid result. Final fits use only pre-test labels.

The A tuning MAE uses all validation periods; adjustment tuning MAE uses validation transfers only.

| stage | target | lambda | trade_weight | scale | validation_mae |
| --- | --- | --- | --- | --- | --- |
| A | minutes | 0.01 | 1 | 1.0 | 3.036 |
| A | usg | 0.01 | 1 | 1.0 | 1.856 |
| A | ts | 0.01 | 1 | 1.0 | 3.192 |
| A | ast | 0.01 | 1 | 1.0 | 2.582 |
| adjustment | minutes | 0.01 | 1 | 0.0 | 3.659 |
| adjustment | usg | 1.00 | 1 | 1.0 | 2.435 |
| adjustment | ts | 1.00 | 2 | 0.5 | 3.257 |
| adjustment | ast | 10.00 | 2 | 1.0 | 2.923 |
| no_destination | minutes | 0.01 | 1 | 0.0 | 3.659 |
| no_destination | usg | 10.00 | 2 | 1.0 | 2.472 |
| no_destination | ts | 1.00 | 2 | 1.0 | 3.215 |
| no_destination | ast | 100.00 | 2 | 1.0 | 2.990 |

## Held-out accuracy

Units: minutes for `minutes`; percentage points for `usg`, `ts` and `ast`. Carry forward repeats the previous window. No destination is Model A plus a player-only mover adjustment. These are fixed-model tests, without retuning on test performance.

### MAE

| Cohort | Statistic | N | Carry forward | Model A | Model A + B | No destination |
| --- | --- | --- | --- | --- | --- | --- |
| All | minutes | 1905 | 3.292 | 3.137 | 3.137 | 3.137 |
| All | usg | 1905 | 1.968 | 1.873 | 1.834 | 1.854 |
| All | ts | 1905 | 3.826 | 3.340 | 3.336 | 3.347 |
| All | ast | 1905 | 2.723 | 2.605 | 2.595 | 2.606 |
| Stayers | minutes | 1619 | 3.082 | 2.969 | 2.969 | 2.969 |
| Stayers | usg | 1619 | 1.803 | 1.726 | 1.726 | 1.726 |
| Stayers | ts | 1619 | 3.741 | 3.272 | 3.272 | 3.272 |
| Stayers | ast | 1619 | 2.545 | 2.450 | 2.450 | 2.450 |
| Transfers | minutes | 286 | 4.481 | 4.092 | 4.092 | 4.092 |
| Transfers | usg | 286 | 2.904 | 2.705 | 2.445 | 2.579 |
| Transfers | ts | 286 | 4.309 | 3.731 | 3.702 | 3.776 |
| Transfers | ast | 286 | 3.732 | 3.483 | 3.412 | 3.492 |
| Verified_trades | minutes | 7 | 1.100 | 1.552 | 1.552 | 1.552 |
| Verified_trades | usg | 7 | 1.818 | 1.453 | 1.206 | 1.188 |
| Verified_trades | ts | 7 | 1.281 | 2.645 | 3.130 | 3.713 |
| Verified_trades | ast | 7 | 3.646 | 3.961 | 4.481 | 4.249 |

### RMSE

| Cohort | Statistic | N | Carry forward | Model A | Model A + B | No destination |
| --- | --- | --- | --- | --- | --- | --- |
| All | minutes | 1905 | 4.481 | 4.085 | 4.085 | 4.085 |
| All | usg | 1905 | 2.562 | 2.418 | 2.367 | 2.392 |
| All | ts | 1905 | 4.954 | 4.265 | 4.252 | 4.261 |
| All | ast | 1905 | 3.626 | 3.456 | 3.436 | 3.459 |
| Stayers | minutes | 1619 | 4.167 | 3.840 | 3.840 | 3.840 |
| Stayers | usg | 1619 | 2.303 | 2.193 | 2.193 | 2.193 |
| Stayers | ts | 1619 | 4.796 | 4.153 | 4.153 | 4.153 |
| Stayers | ast | 1619 | 3.350 | 3.238 | 3.238 | 3.238 |
| Transfers | minutes | 286 | 5.951 | 5.263 | 5.263 | 5.263 |
| Transfers | usg | 286 | 3.703 | 3.420 | 3.177 | 3.297 |
| Transfers | ts | 286 | 5.765 | 4.849 | 4.773 | 4.826 |
| Transfers | ast | 286 | 4.905 | 4.495 | 4.392 | 4.511 |
| Verified_trades | minutes | 7 | 1.394 | 1.876 | 1.876 | 1.876 |
| Verified_trades | usg | 7 | 2.115 | 1.699 | 1.583 | 1.457 |
| Verified_trades | ts | 7 | 1.828 | 3.185 | 3.667 | 4.099 |
| Verified_trades | ast | 7 | 4.096 | 4.904 | 5.538 | 5.309 |

### Does destination context help?

- minutes: destination context does not change transfer MAE by 0.000 minutes.
- usg: destination context improves transfer MAE by 0.134 percentage points.
- ts: destination context improves transfer MAE by 0.074 percentage points.
- ast: destination context improves transfer MAE by 0.079 percentage points.

Positive improvement below means lower MAE for the full translator. Intervals use 1,000 paired bootstrap samples clustered by player. They are descriptive, do not account for all shared team/trade shocks, and do not establish a causal team effect.

| statistic | compared_with | improvement | lower | upper | players |
| --- | --- | --- | --- | --- | --- |
| minutes | no_change | 0.389 | 0.123 | 0.626 | 220 |
| minutes | no_destination | 0.000 | 0.000 | 0.000 | 220 |
| usg | no_change | 0.459 | 0.304 | 0.602 | 220 |
| usg | no_destination | 0.134 | 0.057 | 0.213 | 220 |
| ts | no_change | 0.607 | 0.288 | 0.908 | 220 |
| ts | no_destination | 0.074 | 0.010 | 0.139 | 220 |
| ast | no_change | 0.319 | 0.142 | 0.506 | 220 |
| ast | no_destination | 0.079 | 0.012 | 0.152 | 220 |

## Historical trade examples

All eligible verified trades in the test split are shown, not a selection of favorable results. Each statistic is **carry forward / Model A / Model A+B / actual**. Names link to the dated trade sources; game outcomes come from the existing CSVs.

| Trade | Cutoff | Move | Target_end | minutes | usg | ts | ast |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [CJ McCollum](https://www.nba.com/news/blazers-pelicans-cj-mccollum-trade) | 2022-02-08 | POR to NOP | 2022-11-15 | 35.28 / 32.70 / 32.70 / 34.56 | 26.51 / 26.05 / 24.82 / 27.95 | 54.50 / 55.08 / 54.64 / 54.58 | 21.66 / 21.76 / 20.61 / 27.55 |
| [Domantas Sabonis](https://www.nba.com/news/pacers-agree-to-trade-domantas-sabonis-to-kings) | 2022-02-08 | IND to SAC | 2022-12-11 | 34.04 / 32.87 / 32.87 / 33.05 | 22.37 / 22.55 / 20.98 / 21.76 | 64.81 / 60.93 / 60.70 / 64.03 | 24.32 / 24.27 / 23.27 / 28.22 |
| [Tyrese Haliburton](https://www.nba.com/news/pacers-agree-to-trade-domantas-sabonis-to-kings) | 2022-02-08 | SAC to IND | 2022-11-18 | 34.89 / 33.07 / 33.07 / 35.39 | 18.48 / 20.33 / 20.75 / 21.20 | 58.44 / 56.18 / 55.72 / 62.58 | 33.75 / 29.89 / 29.11 / 39.68 |
| [James Harden](https://www.nba.com/news/2021-22-nba-trade-tracker) | 2022-02-10 | BKN to PHI | 2022-12-27 | 37.37 / 35.14 / 35.14 / 37.96 | 28.78 / 28.30 / 26.79 / 25.67 | 58.39 / 58.92 / 57.43 / 59.78 | 40.25 / 39.81 / 38.27 / 42.88 |
| [Kyrie Irving](https://www.nba.com/news/nets-kyrie-irving-trade-dallas-mavericks) | 2023-02-05 | BKN to DAL | 2024-01-05 | 36.95 / 35.42 / 35.42 / 34.84 | 30.29 / 30.20 / 28.18 / 27.64 | 60.37 / 58.53 / 57.54 / 61.00 | 22.83 / 24.60 / 23.18 / 25.45 |
| [Kevin Durant](https://www.nba.com/news/suns-nets-kevin-durant-trade) | 2023-02-09 | BKN to PHX | 2024-01-14 | 36.08 / 33.53 / 33.53 / 36.23 | 32.11 / 31.21 / 29.83 / 29.93 | 66.84 / 62.48 / 61.29 / 65.03 | 25.52 / 25.99 / 25.35 / 25.29 |
| [Pascal Siakam](https://www.nba.com/pacers/news/pacers-secure-another-star-in-siakam) | 2024-01-17 | TOR to IND | 2024-04-12 | 34.60 / 32.36 / 32.36 / 31.95 | 25.42 / 25.55 / 23.12 / 25.43 | 59.97 / 57.21 / 57.74 / 59.84 | 21.24 / 20.49 / 18.87 / 16.92 |

## Where errors change

Cells show **carry-forward MAE / translator MAE**. The larger-role grouping uses realized next-period usage strictly for diagnosis; it is not an input feature. The 28% destination threshold uses the pre-cutoff roster proxy.

| Situation | N | minutes | usg | ts | ast |
| --- | --- | --- | --- | --- | --- |
| Higher realized usage (+5pp) | 21 | 4.11 / 3.76 | 6.93 / 6.52 | 4.12 / 3.37 | 5.45 / 5.24 |
| Other usage outcomes | 265 | 4.51 / 4.12 | 2.58 / 2.12 | 4.32 / 3.73 | 3.60 / 3.27 |
| Destination has a 28%+ usage player | 229 | 4.47 / 4.19 | 3.04 / 2.50 | 4.35 / 3.86 | 3.77 / 3.34 |
| Destination without a 28%+ usage player | 57 | 4.53 / 3.72 | 2.38 / 2.22 | 4.14 / 3.06 | 3.57 / 3.69 |

The larger-role group is harder to predict; compare its usage errors with the other-outcomes group. In the individual trade examples, compare assist predictions with the realized expanded playmaking roles. These are diagnostic comparisons, not reasons to retune on this test set.

## Interpretable coefficients

Three largest absolute fitted effects per target and stage, for a one-training-standard-deviation feature change. Units are target units; associations are conditional on correlated features, not causal effects. Zero adjustment scale gives zero effects.

| Stage | Statistic | Feature | Effect_per_SD |
| --- | --- | --- | --- |
| baseline | minutes | past_minutes | 5.492 |
| baseline | minutes | age | -0.941 |
| baseline | minutes | current_win_rate | 0.572 |
| baseline | usg | past_usg | 2.332 |
| baseline | usg | past_pts_per36 | 2.000 |
| baseline | usg | current_available_plays | 0.739 |
| baseline | ts | past_ts | 2.361 |
| baseline | ts | trend_ts | -0.844 |
| baseline | ts | past_free_throw_rate | 0.556 |
| baseline | ast | past_ast | 8.108 |
| baseline | ast | trend_ast | -0.780 |
| baseline | ast | height | -0.633 |
| adjustment | minutes | past_minutes | 0.000 |
| adjustment | minutes | past_usg | 0.000 |
| adjustment | minutes | past_ts | 0.000 |
| adjustment | usg | trend_usg | -0.211 |
| adjustment | usg | delta_pace | -0.196 |
| adjustment | usg | delta_high_usage_minutes_share | -0.180 |
| adjustment | ts | past_minutes | -0.127 |
| adjustment | ts | trend_ts | -0.124 |
| adjustment | ts | delta_pace | 0.113 |
| adjustment | ast | delta_ortg | -0.104 |
| adjustment | ast | delta_win_rate | -0.100 |
| adjustment | ast | trend_ast | -0.090 |

## Limits before trade-model integration

- A complete 40-appearance target selects players who remain active and stay on the destination team long enough. This is survivorship conditioning, not an availability, injury, DNP or unconditional 40-team-game forecast. Excluded short stays and unknown move dates limit generalization.
- The verified-trade list is a small, nonrepresentative set of sourced examples. Other moves mix actual trades, free agency, waivers and other transfers. They are not silently counted as trades. Trade-only errors and trade weighting need a comprehensive dated transaction source before being treated as representative.
- Team changes are detected from played games; intervening teams with no appearance cannot be identified. Contract dates, injury status, playoff games, actual positions (the source position column is empty), confirmed depth charts and exact on-court possessions are unavailable.
- Height bands proxy positional competition. Recent rotations can still contain players departing in the same deal and cannot anticipate additional signings or coaching changes. Available minutes/plays are historical proxies, not guaranteed vacancies or a fully reconstructed post-trade roster.
- Team B adjustments are predictive residual corrections among observed movers, not identified causal effects of a hypothetical trade. Conditional destination input assumes the proposed destination is known.
- Windows can span offseasons, and older histories may be stale. All features remain before the cutoff; strict past dates do not remove selection bias or guarantee roster information was complete.
- The saved model is the pre-test research fit, not a production refit through the latest season. The coefficients stay fixed across the test years, so regime changes and aging patterns can affect later-year accuracy.
- Results describe the frozen local data snapshot. Re-downloaded historical sources may change. The artifact stores input hashes, settings, selected parameters and fitting dates; it contains no intermediate datasets.

## Checks completed

- PASS: Window formulas and undefined-denominator handling
- PASS: Every feature date strictly precedes its prediction cutoff
- PASS: All training targets mature before the test period; yearly residual folds are chronological
- PASS: Prediction works with all future labels removed; fitting features use an explicit allowlist
- PASS: Team-change adjustment is exactly zero for stayers
- PASS: Imputation uses training medians; test values do not alter preprocessing
- PASS: All held-out predictions are finite
- PASS: The scenario API reproduces a held-out trade without requiring its future appearances
- PASS: Saved model reloads with identical held-out predictions

## References

- [Box-score percentage formulas](https://sportsdata.io/help/basketball-formula-reference-guide)
- [glmnet documentation](https://glmnet.stanford.edu/articles/glmnet.html)
- Trade verification links are embedded in `verified_translation_trades()` and in the examples above.
