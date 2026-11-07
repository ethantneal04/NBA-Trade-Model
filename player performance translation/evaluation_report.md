# Player performance translation: Phase 2

## Main result

Validation selected **15-game windows**. The selected test has **212 genuine player-trade observations**, 105 distinct transaction groups and 173 players. Units below are minutes or percentage points.

- minutes MAE: carry 5.586, A 4.935, raw context 4.935, full 4.935, no destination 4.797.
- usg MAE: carry 3.393, A 2.940, raw context 2.823, full 2.811, no destination 2.776.
- ts MAE: carry 7.271, A 5.490, raw context 5.490, full 5.490, no destination 5.490.
- ast MAE: carry 4.343, A 3.831, raw context 3.807, full 3.655, no destination 3.708.

- Against raw_destination: full context has lower MAE on 2 targets, higher MAE on 0, and ties on 2.
- Against no_destination: full context has lower MAE on 1 targets, higher MAE on 2, and ties on 1.

Carry-forward gains do not by themselves establish added value from the destination features. Read the raw-context and player-only comparisons together with the paired intervals. In particular, systematic underprediction of expanded roles is a remaining integration risk.

This is a predictive, conditional-on-playing backtest. Whether it improves enough for trade-model integration must be judged from the actual-trade errors and paired comparisons, not the larger stayer cohort. No model, weight or window is selected from test errors.

## Run and files

Install `data.table`, `glmnet`, and `jsonlite`, then run from the project root:

```sh
Rscript "player performance translation/player_translation_evaluation.R"
```

In RStudio, source the evaluation file and call `result <- run_player_translation()`. There are exactly three R scripts. Only the existing `player_translation_model.rds` and this report are generated; all observations, predictions, censoring diagnostics and other-window fits remain in memory.
Trade input: `nba_traded_players_2016_2026.csv`. Its actual dates, rather than its filename, determine coverage. The optional supplied movement JSON supplies dated signing records; a signing is not automatically certified as unrestricted free agency.

For a proposal, construct `newdata <- result$selected$bundle$make_scenario(player_id, destination_team_id, cutoff, departing_ids=..., arriving_ids=...)`, then use `predict_player_translation(result$model, newdata)`. Historical packages are found automatically. Manually specified participants are assumptions about a proposed deal, not invented training outcomes. The saved model must predate the requested cutoff.

## Transaction validation and coverage

Source: 1812 rows; 1292 player rows involving 661 players; 520 non-player/missing-ID rows excluded. 1272 player rows pass identity, direction, duplicate and date/group checks. There are 503 groups; 115 have incomplete/uncertain package coverage.
Game data ends 2026-04-12. The feed starts 2015-07-09 and ends 2026-09-27. Records after the game snapshot cannot yet provide post-trade labels.
Matching requires the NBA player ID, confirmed current origin at the trade date, destination appearances, and a consistent chronology. A known earlier trade can explain an intermediate team with no appearances. The final leg is predicted at its own date; its eventual destination is never projected backward to the first leg. Same-day multi-leg ordering is not guessed. Partial groups retain flags and only known participants are used.

| Match_or_exclusion_status | Rows |
| --- | --- |
| after_game_coverage | 62 |
| ambiguous_same_day_legs | 20 |
| matched_direct | 835 |
| matched_prior_trade_chain | 38 |
| no_destination_appearance_before_next_trade_or_end | 321 |
| no_pre_game_history | 4 |
| non_player_or_missing_id | 520 |
| origin_not_confirmed_before_trade | 11 |
| post_trade_team_conflict | 1 |

Coverage by NBA season ending year (July-June transaction convention). Later-season records outside the game snapshot remain visible:

| Season_end | Player_records | Valid | Game_matched | Eligible_15 | Eligible_20 | Eligible_30 | Eligible_40 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2016 | 76 | 76 | 49 | 44 | 43 | 30 | 23 |
| 2017 | 92 | 88 | 70 | 62 | 60 | 48 | 45 |
| 2018 | 75 | 75 | 56 | 47 | 44 | 33 | 30 |
| 2019 | 127 | 123 | 90 | 76 | 66 | 53 | 47 |
| 2020 | 110 | 108 | 88 | 69 | 66 | 53 | 44 |
| 2021 | 140 | 140 | 94 | 80 | 69 | 52 | 42 |
| 2022 | 141 | 141 | 102 | 90 | 83 | 70 | 61 |
| 2023 | 111 | 111 | 80 | 71 | 67 | 55 | 52 |
| 2024 | 125 | 121 | 83 | 72 | 67 | 55 | 45 |
| 2025 | 122 | 120 | 82 | 73 | 68 | 51 | 46 |
| 2026 | 116 | 112 | 79 | 67 | 56 | 31 | 21 |
| 2027 | 57 | 57 | 0 | 0 | 0 | 0 | 0 |

For the selected window, matched trade records are retained or excluded as follows:

| Selected_window_eligibility | Matched_player_trades |
| --- | --- |
| eligible | 751 |
| insufficient_history | 5 |
| short_followup_data_end | 50 |
| short_followup_team_change | 66 |
| undefined_target_rates | 1 |

## Windows, censoring and chronology

Each window uses W previous positive-minute appearances and the next W appearances with the destination. Histories may include an earlier team, with current-team share and team-count features. This avoids discarding rapid transfers solely for lacking W games with the last franchise. Actual trade dates, signing dates, or conservative last-old-game-day cutoffs are used; unknown changes remain unclassified.
Targets cannot cross another known player trade or a different-team appearance. Stayer blocks have stride W, and blocks overlapping a transfer target are removed. Targets may cross offseasons; feature dates stay before the cutoff. Incomplete targets are not padded or treated as complete outcomes.

| Window | All_periods | Eligible_trades | Test_trades | Test_players | Cross_season_targets | Matched_short_followup |
| --- | --- | --- | --- | --- | --- | --- |
| 15 | 24275 | 751 | 212 | 173 | 6 | 120 |
| 20 | 17503 | 689 | 191 | 157 | 14 | 182 |
| 30 | 10485 | 531 | 137 | 120 | 28 | 337 |
| 40 | 7109 | 456 | 112 | 101 | 41 | 404 |

Train labels mature before 2020-07-01. Validation cutoffs are on/after that date and all validation labels mature before 2023-07-01. Final test cutoffs are on/after 2023-07-01. Every model refits only pre-test labels; residual folds have their own earlier chronological tuning splits.

| Split | Periods | Trades | Signings | Other_moves | Stayers |
| --- | --- | --- | --- | --- | --- |
| train | 15270 | 279 | 392 | 830 | 13769 |
| validation | 4120 | 227 | 200 | 22 | 3671 |
| development | 19678 | 525 | 602 | 854 | 17697 |
| test | 4301 | 212 | 188 | 11 | 3890 |

Window selection minimizes mean validation MAE divided by carry-forward MAE across the four targets on the same 121 eligible validation trades. These are development scores, not test scores. Common-cohort selection still conditions on the longest window being observed.

| Window | Validation_trades | Common_validation_trades | Mean_relative_MAE |
| --- | --- | --- | --- |
| 15 | 227 | 121 | 0.854 |
| 20 | 203 | 121 | 0.864 |
| 30 | 144 | 121 | 0.872 |
| 40 | 121 | 121 | 0.892 |

Shorter and longer targets are different forecasting questions and have different averaging noise. Neither raw MAE nor sample count alone identifies a universally best horizon. The tables below show both each window's own sample and a common test-trade cohort.

## Models and destination features

A is four interpretable ridge regressions trained on all eligible periods. B learns genuine out-of-time baseline errors among observed movers, with trade weights 1/2/4. B lambda, weight and scale 0/0.5/1 are tuned on actual validation trades. All preprocessing is fitted on the fitting rows. Zero adjustment remains a valid choice.
Full B reconstructs the destination rotation from recent games and prior dated movements, removes same-package departures, and adds other arrivals using their pre-cutoff role estimates. It includes vacated minutes, shot/usage load, assists, height-band competition, remaining high-usage players, focal responsibility gaps and three simple opportunity interactions. No incoming player's post-trade statistics are used.
Raw context is a separately tuned B using unadjusted historical destination context, without package features. No destination is a separately tuned player-only B. Both share A, samples, splits and tuning rules. Their paired comparison isolates the added destination information better than comparing Phase 1's seven curated trades with this larger cohort.
Trade participants on the cutoff date are known conditions of the proposed/announced deal. This is not a forecast of which transaction will occur. Other same-day packages are not silently pooled. Height bands are proxies because position is empty in the source. Carried role estimates need not sum to a feasible 240-minute allocation.

| stage | target | lambda | trade_weight | scale | validation_mae | cohort |
| --- | --- | --- | --- | --- | --- | --- |
| A | minutes | 0.001 | 1 | 1.0 | 3.198 | all_periods |
| A | usg | 0.010 | 1 | 1.0 | 1.995 | all_periods |
| A | ts | 0.010 | 1 | 1.0 | 5.052 | all_periods |
| A | ast | 0.001 | 1 | 1.0 | 2.917 | all_periods |
| adjustment | minutes | 0.001 | 1 | 0.0 | 4.438 | verified_trades |
| adjustment | usg | 10.000 | 4 | 1.0 | 2.698 | verified_trades |
| adjustment | ts | 0.001 | 1 | 0.0 | 5.542 | verified_trades |
| adjustment | ast | 10.000 | 4 | 1.0 | 3.963 | verified_trades |
| raw_destination | minutes | 0.001 | 1 | 0.0 | 4.438 | verified_trades |
| raw_destination | usg | 10.000 | 4 | 1.0 | 2.718 | verified_trades |
| raw_destination | ts | 0.001 | 1 | 0.0 | 5.542 | verified_trades |
| raw_destination | ast | 100.000 | 4 | 1.0 | 3.968 | verified_trades |
| no_destination | minutes | 0.001 | 4 | 0.5 | 4.311 | verified_trades |
| no_destination | usg | 1.000 | 4 | 1.0 | 2.586 | verified_trades |
| no_destination | ts | 0.001 | 1 | 0.0 | 5.542 | verified_trades |
| no_destination | ast | 0.010 | 1 | 0.5 | 3.891 | verified_trades |

## Held-out performance

### Each window: genuine trades

| Window | Statistic | Trade_N | Carry_MAE | A_MAE | Raw_MAE | Full_MAE | No_dest_MAE | Full_RMSE |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 15 | minutes | 212 | 5.586 | 4.935 | 4.935 | 4.935 | 4.797 | 6.308 |
| 15 | usg | 212 | 3.393 | 2.940 | 2.823 | 2.811 | 2.776 | 3.502 |
| 15 | ts | 212 | 7.271 | 5.490 | 5.490 | 5.490 | 5.490 | 7.206 |
| 15 | ast | 212 | 4.343 | 3.831 | 3.807 | 3.655 | 3.708 | 4.919 |
| 20 | minutes | 191 | 5.569 | 4.713 | 4.713 | 4.619 | 4.551 | 5.891 |
| 20 | usg | 191 | 3.250 | 2.894 | 2.829 | 2.828 | 2.717 | 3.575 |
| 20 | ts | 191 | 5.909 | 4.623 | 4.623 | 4.623 | 4.590 | 5.806 |
| 20 | ast | 191 | 4.071 | 3.589 | 3.400 | 3.398 | 3.424 | 4.563 |
| 30 | minutes | 137 | 4.988 | 4.482 | 4.482 | 4.424 | 4.470 | 5.676 |
| 30 | usg | 137 | 2.952 | 2.645 | 2.573 | 2.515 | 2.475 | 3.294 |
| 30 | ts | 137 | 4.420 | 3.478 | 3.481 | 3.480 | 3.510 | 4.373 |
| 30 | ast | 137 | 3.963 | 3.697 | 3.533 | 3.515 | 3.597 | 4.600 |
| 40 | minutes | 112 | 4.758 | 4.285 | 4.285 | 4.285 | 4.240 | 5.495 |
| 40 | usg | 112 | 2.813 | 2.660 | 2.563 | 2.573 | 2.582 | 3.389 |
| 40 | ts | 112 | 3.595 | 3.000 | 2.989 | 2.988 | 2.989 | 3.912 |
| 40 | ast | 112 | 3.955 | 3.815 | 3.743 | 3.726 | 3.904 | 4.798 |

### Common test cohort (112 trades)

| Window | Statistic | N | Carry_MAE | Full_MAE | Relative_MAE |
| --- | --- | --- | --- | --- | --- |
| 15 | minutes | 112 | 5.119 | 4.886 | 0.954 |
| 15 | usg | 112 | 3.432 | 2.810 | 0.819 |
| 15 | ts | 112 | 6.820 | 5.342 | 0.783 |
| 15 | ast | 112 | 4.272 | 3.594 | 0.841 |
| 20 | minutes | 112 | 5.156 | 4.614 | 0.895 |
| 20 | usg | 112 | 3.244 | 2.803 | 0.864 |
| 20 | ts | 112 | 5.467 | 4.467 | 0.817 |
| 20 | ast | 112 | 4.155 | 3.509 | 0.845 |
| 30 | minutes | 112 | 4.952 | 4.534 | 0.916 |
| 30 | usg | 112 | 2.861 | 2.465 | 0.862 |
| 30 | ts | 112 | 4.112 | 3.407 | 0.828 |
| 30 | ast | 112 | 3.979 | 3.601 | 0.905 |
| 40 | minutes | 112 | 4.758 | 4.285 | 0.901 |
| 40 | usg | 112 | 2.813 | 2.573 | 0.915 |
| 40 | ts | 112 | 3.595 | 2.988 | 0.831 |
| 40 | ast | 112 | 3.955 | 3.726 | 0.942 |

### Selected model: MAE

| Cohort | Statistic | N | Carry | A | Raw context | Full A+B | No destination |
| --- | --- | --- | --- | --- | --- | --- | --- |
| All | minutes | 4301 | 3.429 | 3.274 | 3.274 | 3.274 | 3.260 |
| All | usg | 4301 | 2.190 | 2.021 | 2.011 | 2.010 | 2.006 |
| All | ts | 4301 | 6.606 | 5.118 | 5.118 | 5.118 | 5.118 |
| All | ast | 4301 | 3.345 | 3.000 | 2.998 | 2.988 | 2.991 |
| Stayers | minutes | 3890 | 3.167 | 3.063 | 3.063 | 3.063 | 3.063 |
| Stayers | usg | 3890 | 2.063 | 1.926 | 1.926 | 1.926 | 1.926 |
| Stayers | ts | 3890 | 6.420 | 4.989 | 4.989 | 4.989 | 4.989 |
| Stayers | ast | 3890 | 3.234 | 2.907 | 2.907 | 2.907 | 2.907 |
| Trades | minutes | 212 | 5.586 | 4.935 | 4.935 | 4.935 | 4.797 |
| Trades | usg | 212 | 3.393 | 2.940 | 2.823 | 2.811 | 2.776 |
| Trades | ts | 212 | 7.271 | 5.490 | 5.490 | 5.490 | 5.490 |
| Trades | ast | 212 | 4.343 | 3.831 | 3.807 | 3.655 | 3.708 |
| Signings | minutes | 188 | 6.005 | 5.358 | 5.358 | 5.358 | 5.212 |
| Signings | usg | 188 | 3.366 | 2.886 | 2.781 | 2.769 | 2.739 |
| Signings | ts | 188 | 9.604 | 7.324 | 7.324 | 7.324 | 7.324 |
| Signings | ast | 188 | 4.495 | 3.974 | 3.955 | 3.884 | 3.917 |
| Other_transfers | minutes | 11 | 10.306 | 10.223 | 10.223 | 10.223 | 10.168 |
| Other_transfers | usg | 11 | 3.959 | 3.306 | 3.196 | 3.185 | 2.953 |
| Other_transfers | ts | 11 | 8.552 | 5.924 | 5.924 | 5.924 | 5.924 |
| Other_transfers | ast | 11 | 3.449 | 3.259 | 3.427 | 3.407 | 3.222 |

### Selected model: RMSE

| Cohort | Statistic | N | Carry | A | Raw context | Full A+B | No destination |
| --- | --- | --- | --- | --- | --- | --- | --- |
| All | minutes | 4301 | 4.720 | 4.367 | 4.367 | 4.367 | 4.349 |
| All | usg | 4301 | 2.857 | 2.607 | 2.593 | 2.591 | 2.590 |
| All | ts | 4301 | 8.801 | 6.790 | 6.790 | 6.790 | 6.790 |
| All | ast | 4301 | 4.456 | 4.002 | 4.002 | 3.984 | 3.990 |
| Stayers | minutes | 3890 | 4.303 | 4.048 | 4.048 | 4.048 | 4.048 |
| Stayers | usg | 3890 | 2.677 | 2.475 | 2.475 | 2.475 | 2.475 |
| Stayers | ts | 3890 | 8.538 | 6.583 | 6.583 | 6.583 | 6.583 |
| Stayers | ast | 3890 | 4.282 | 3.856 | 3.856 | 3.856 | 3.856 |
| Trades | minutes | 212 | 7.338 | 6.308 | 6.308 | 6.308 | 6.083 |
| Trades | usg | 212 | 4.101 | 3.610 | 3.508 | 3.502 | 3.512 |
| Trades | ts | 212 | 9.703 | 7.206 | 7.206 | 7.206 | 7.206 |
| Trades | ast | 212 | 5.720 | 5.125 | 5.113 | 4.919 | 4.998 |
| Signings | minutes | 188 | 7.589 | 6.663 | 6.663 | 6.663 | 6.636 |
| Signings | usg | 188 | 4.272 | 3.609 | 3.492 | 3.479 | 3.450 |
| Signings | ts | 188 | 12.286 | 9.774 | 9.774 | 9.774 | 9.774 |
| Signings | ast | 188 | 5.995 | 5.248 | 5.256 | 5.153 | 5.180 |
| Other_transfers | minutes | 11 | 11.919 | 11.685 | 11.685 | 11.685 | 11.618 |
| Other_transfers | usg | 11 | 4.578 | 3.977 | 3.944 | 3.935 | 3.735 |
| Other_transfers | ts | 11 | 10.408 | 8.171 | 8.171 | 8.171 | 8.171 |
| Other_transfers | ast | 11 | 5.978 | 5.112 | 5.252 | 5.284 | 5.036 |

### Does better destination context help?

Positive paired improvement favors Full A+B. Intervals use 1,000 bootstrap draws clustered by transaction group. Repeated-player dependence across separate transactions and unobserved team shocks are not fully covered; these are descriptive intervals, not causal confidence statements.

| Statistic | Compared_with | MAE_improvement | Lower | Upper | Trade_groups |
| --- | --- | --- | --- | --- | --- |
| minutes | no_change | 0.651 | 0.354 | 0.947 | 105 |
| minutes | raw_destination | 0.000 | 0.000 | 0.000 | 105 |
| minutes | no_destination | -0.138 | -0.255 | -0.029 | 105 |
| usg | no_change | 0.581 | 0.408 | 0.764 | 105 |
| usg | raw_destination | 0.012 | -0.008 | 0.030 | 105 |
| usg | no_destination | -0.035 | -0.128 | 0.047 | 105 |
| ts | no_change | 1.781 | 1.146 | 2.389 | 105 |
| ts | raw_destination | 0.000 | 0.000 | 0.000 | 105 |
| ts | no_destination | 0.000 | 0.000 | 0.000 | 105 |
| ast | no_change | 0.687 | 0.443 | 0.946 | 105 |
| ast | raw_destination | 0.152 | 0.064 | 0.238 | 105 |
| ast | no_destination | 0.052 | -0.030 | 0.144 | 105 |

## Expanded and reduced roles

Groups use realized changes of at least 5 minutes or percentage points strictly for diagnosis. Realized roles never become training features. Direction accuracy is the fraction whose predicted direction matches the actual direction.

| Statistic | Role_change | N | Actual_delta | Predicted_delta | Carry_MAE | Full_MAE | Bias | Direction_accuracy |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| minutes | up | 53 | 9.861 | 1.745 | 9.861 | 8.116 | -8.116 | 0.792 |
| minutes | down | 39 | -9.670 | -1.950 | 9.670 | 7.720 | 7.720 | 0.923 |
| usg | up | 23 | 6.661 | 0.495 | 6.661 | 6.166 | -6.166 | 0.739 |
| usg | down | 28 | -6.551 | -2.215 | 6.551 | 4.337 | 4.337 | 1.000 |
| ast | up | 33 | 8.940 | 0.631 | 8.940 | 8.308 | -8.308 | 0.576 |
| ast | down | 38 | -8.247 | -3.193 | 8.247 | 5.063 | 5.055 | 0.947 |

- Expanded minutes roles: average actual increase 9.86, predicted increase 1.74 across 53 trades.
- Expanded usg roles: average actual increase 6.66, predicted increase 0.50 across 23 trades.
- Expanded ast roles: average actual increase 8.94, predicted increase 0.63 across 33 trades.

Compare these increases with the direction accuracies: getting the sign right can still substantially miss the size of a new role. The role groups are retrospective diagnostics and are not used to refit or select models.

Pre-trade situations; cells are carry / full-model MAE:

| Situation | N | minutes | usg | ts | ast |
| --- | --- | --- | --- | --- | --- |
| Open_shot_opportunities | 91 | 4.72 / 4.27 | 3.74 / 2.94 | 6.25 / 4.89 | 4.83 / 4.14 |
| Crowded_high_usage_roster | 156 | 5.88 / 5.11 | 3.55 / 2.93 | 7.50 / 5.76 | 4.41 / 3.62 |
| Partial_transaction_group | 48 | 5.44 / 5.02 | 2.92 / 2.53 | 7.13 / 5.34 | 3.80 / 3.36 |

### Short-follow-up sensitivity

These excluded trades have at least five observed destination appearances but fewer than W before another trade, team change or the data end. They never train or tune the model. Their available-period errors are a diagnostic of selection sensitivity, not accuracy on an unobserved full W-game target. Absences, waived players and zero-appearance outcomes are not invented.

| Statistic | N | Median_followup | Carry_MAE | Full_MAE |
| --- | --- | --- | --- | --- |
| minutes | 22 | 8 | 5.454 | 5.811 |
| usg | 22 | 8 | 2.795 | 2.616 |
| ts | 22 | 8 | 10.788 | 9.975 |
| ast | 22 | 8 | 4.921 | 4.243 |

## Documented historical examples

Each cell is **carry / full prediction / actual**. Examples are selected by prespecified player identities and chronology, never by whether the model succeeded. The group IDs and dates identify records in the supplied NBA transaction CSV/JSON; not all observed movers are called trades.

| Player | Date | Move | Group | Target_end | minutes | usg | ts | ast |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Damian Lillard | 2023-09-27 | POR to MIL | Trade 2023018 | 2023-11-26 | 36.68 / 33.22 / 34.13 | 37.99 / 33.45 / 29.61 | 64.81 / 60.39 / 60.08 | 38.21 / 30.78 / 26.50 |
| Jrue Holiday | 2023-10-01 | POR to BOS | Trade 2023019 | 2023-11-22 | 31.47 / 26.41 / 34.58 | 23.35 / 22.10 / 17.86 | 60.02 / 57.41 / 51.24 | 33.72 / 29.10 / 19.20 |
| Pascal Siakam | 2024-01-17 | TOR to IND | Trade 2023027 | 2024-02-14 | 35.12 / 33.71 / 33.26 | 24.93 / 24.48 / 24.17 | 64.10 / 60.30 / 62.25 | 19.73 / 18.57 / 20.68 |
| Luka Dončić | 2025-02-02 | DAL to LAL | Trade 2024022 | 2025-03-17 | 34.93 / 36.37 / 34.55 | 31.96 / 31.64 / 35.82 | 62.13 / 61.47 / 54.74 | 36.04 / 33.75 / 39.17 |
| Jimmy Butler III | 2025-02-06 | MIA to GSW | Trade 2024031 | 2025-03-15 | 30.00 / 29.55 / 31.63 | 19.01 / 20.16 / 20.95 | 65.94 / 62.16 / 58.12 | 22.42 / 21.46 / 25.97 |
| Anthony Davis | 2025-02-02 | LAL to DAL | Trade 2024022 | 2025-11-28 | 32.31 / 32.74 / 29.58 | 30.51 / 28.65 / 29.88 | 60.23 / 60.82 / 54.46 | 17.44 / 17.45 / 21.57 |
| Karl-Anthony Towns | 2024-10-02 | MIN to NYK | Trade 2024014 | 2024-11-23 | 30.96 / 28.61 / 33.39 | 27.66 / 25.31 / 29.23 | 57.13 / 59.96 / 65.05 | 14.87 / 13.04 / 14.53 |
| Mikal Bridges | 2024-07-06 | BKN to NYK | Trade 2024008 | 2024-11-20 | 33.01 / 30.85 / 38.60 | 20.36 / 20.40 / 18.52 | 55.25 / 54.82 / 56.23 | 15.87 / 14.53 / 12.58 |

## Limits and next steps

- Completing W played appearances is still survivorship conditioning. The window comparison, full-feed exclusion counts and short-follow-up diagnostics expose this; they do not solve it. A complete roster/availability panel is needed for unconditional W-team-game forecasts.
- The transaction feed is not independently proven exhaustive, particularly before July 2015, and the game snapshot ends before the feed. Same-day ambiguous legs, unmatched origins and incomplete packages stay flagged instead of being repaired using future outcomes. Signing-related moves are distinguished, but remaining unknown moves may include free agency or waivers.
- Roster reconstruction lacks a complete dated contract, waiver, injury and confirmed-position history. Old rotation estimates and carried incoming roles can be stale, and shared minutes/usage must be reallocated in reality. Team pace and efficiency remain historical; no future team rating is assumed.
- USG% and AST% are aggregate box-score estimates, not exact on-court possession/assist measures. Minutes are per played appearance and can include overtime. Hypothetical B corrections are predictive associations, not identified causal trade effects.
- Phase 1 already examined some games used here. The later Phase 2 chronological holdout is kept out of this phase's tuning, but it is not a never-before-seen external data release. Freeze this specification for a genuinely future-season test before deployment.
- Do not select another window or retune from the reported test table. Next steps are broader dated roster/injury coverage, prospective availability targets and a frozen forward test. Keep the ridge benchmark while testing whether role-opportunity features add stable value.

## Validation checks

- PASS: Window formulas and undefined-rate handling
- PASS: Non-player assets, duplicate legs, invalid dates and ambiguous same-day transactions are flagged
- PASS: Origin, destination and transaction order are checked against known pre-trade events and game history
- PASS: All performance features, including incoming-player roles, precede the cutoff
- PASS: Known same-package departures are removed; the scenario API reproduces historical features
- PASS: Full targets have the configured length and do not overlap within a player
- PASS: Training, validation, yearly residual folds and final tests are chronological with mature labels
- PASS: Removing future outcomes leaves predictions unchanged; stayers receive zero adjustment
- PASS: Imputation uses training medians; all test predictions are finite
- PASS: Window selected only on validation; saved artifact excludes intermediate predictions and reloads identically

Source and method references: [NBA player-movement feed](https://stats.nba.com/js/data/playermovement/NBA_Player_Movement.json), [box-score formulas](https://sportsdata.io/help/basketball-formula-reference-guide), [glmnet](https://glmnet.stanford.edu/articles/glmnet.html).
