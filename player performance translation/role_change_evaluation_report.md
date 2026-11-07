# Phase 3: opportunity and role change evaluation

Selected role MAE versus the matched Phase 2 translator: minutes 4.158 -> 4.137; usg 2.651 -> 2.819; ast 3.418 -> 3.529.

Targets with a transaction-bootstrap MAE gain interval wholly above zero versus matched Phase 2: none. The selected models remain experimental; these results do not justify replacing the existing translator.

Validation selected role augmentation for no targets. Test MAE gains versus the same-row control (positive is better): minutes +0.000; usg +0.000; ts +0.000; ast +0.000.

## Data and timing

Each observation predicts the next 15 positive-minute appearances. Game coverage ends 2026-04-12. Training labels finish before 2021-07-01; validation trades start on that date and finish before 2024-07-01. Final refits use only labels mature before 2024-07-01. Test cutoffs start on 2024-07-01.

| split | periods | trades |
| --- | --- | --- |
| Training | 16677 | 375 |
| Validation | 4264 | 226 |
| Development refit | 21211 | 604 |
| Test | 2762 | 140 |

The test includes 140 genuine trades in 68 transaction packages involving 122 players. Validation model selection uses genuine trades only. Cross-boundary immature labels are purged; player target windows do not overlap.

**Holdout limitation:** Phase 2 already examined games through April 2026. The later July 2024 split is chronological and excluded from this phase's tuning, but it is not newly collected, untouched evidence. The 15-game choice also comes from Phase 2. Claims need a future season or another genuinely unseen dataset. The frozen Phase 2 benchmark was trained through June 2023; the matched benchmark reruns its unchanged architecture using this phase's split and lambda grid.

## Models and validation selection

All models predict next-period minus previous-period minutes, USG% and AST%. Percentages are percentage points and box-score estimates. Training weights are 0.1 for stayers, 1 for other transfers, and 1, 2 or 4 for verified trades, selected on validation MAE. The direct OLS baseline fixes the trade weight at 1.

The player baseline uses prior roles, trends, age, height, prior-season BPM and known team change. Opportunity ridge adds the existing reconstructed roster, team context and trade package features plus available-role gaps, positive/negative vacancy terms, high-usage competitors and established creators. Positions are approximated with height bands because reliable position labels are unavailable. All roster statistics precede the cutoff; known same-day trade participants are applied without using their later performance.

The two-stage alternatives fit a three-class ridge classifier and class-specific magnitude regressions. Soft predictions average the three conditional changes; hard predictions use the most likely class. A change of at least +3 is an increase and at most -3 a decrease; the middle class is stable. Each target uses the simplest family within 1% of the best validation MAE. No test metric determines selection.

| target | family | lambda | trade_weight | validation_mae |
| --- | --- | --- | --- | --- |
| minutes | opportunity_ridge | 0.1 | 4 | 4.568 |
| usg | direct_ols | NA | 1 | 2.686 |
| ast | opportunity_ridge | 0.1 | 1 | 3.624 |

| target | family | lambda | trade_weight | mae | large_mae | direction_accuracy |
| --- | --- | --- | --- | --- | --- | --- |
| minutes | direct_ols | NA | 1 | 5.091 | 7.553 | 0.429 |
| minutes | player_ridge | 0.10 | 4 | 4.998 | 7.689 | 0.451 |
| minutes | opportunity_ridge | 0.10 | 4 | 4.568 | 6.607 | 0.562 |
| minutes | mixture_soft | 0.01 | 2 | 4.536 | 6.383 | 0.593 |
| minutes | mixture_hard | 1.00 | 1 | 4.971 | 6.396 | 0.527 |
| usg | direct_ols | NA | 1 | 2.686 | 5.632 | 0.566 |
| usg | player_ridge | 0.01 | 2 | 2.685 | 5.574 | 0.562 |
| usg | opportunity_ridge | 0.10 | 1 | 2.681 | 5.444 | 0.558 |
| usg | mixture_soft | 0.10 | 4 | 2.694 | 5.348 | 0.558 |
| usg | mixture_hard | 1.00 | 4 | 2.909 | 6.451 | 0.584 |
| ast | direct_ols | NA | 1 | 3.701 | 6.211 | 0.504 |
| ast | player_ridge | 0.01 | 4 | 3.698 | 6.086 | 0.500 |
| ast | opportunity_ridge | 0.10 | 1 | 3.624 | 5.594 | 0.527 |
| ast | mixture_soft | 0.01 | 2 | 3.741 | 5.487 | 0.496 |
| ast | mixture_hard | 0.01 | 2 | 4.086 | 5.273 | 0.531 |

## Genuine-trade results

MAE is also the absolute error in the projected level, since every change prediction uses the same prior-period baseline. Lower MAE/RMSE is better; bias is predicted minus actual. Direction accuracy includes stable cases; balanced recall gives each observed class equal weight. Accuracy and recall are fractions from 0 to 1.

| cohort | target | n | carry_mae | frozen_phase2_mae | matched_phase2_mae | direct_ols_mae | player_ridge_mae | opportunity_ridge_mae | mixture_soft_mae | mixture_hard_mae | selected_mae |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Trades | minutes | 140 | 4.989 | 4.389 | 4.158 | 4.423 | 4.315 | 4.137 | 4.106 | 4.941 | 4.137 |
| Trades | usg | 140 | 3.410 | 2.771 | 2.651 | 2.819 | 2.795 | 2.636 | 2.555 | 3.146 | 2.819 |
| Trades | ast | 140 | 4.231 | 3.586 | 3.418 | 3.617 | 3.609 | 3.529 | 3.636 | 4.524 | 3.529 |

| target | method | n | mae | rmse | bias | direction_accuracy | balanced_recall | large_mae |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| minutes | carry | 140 | 4.989 | 6.590 | -0.994 | 0.393 | 0.333 | 9.487 |
| minutes | frozen_phase2 | 140 | 4.389 | 5.599 | -1.122 | 0.464 | 0.421 | 7.598 |
| minutes | matched_phase2 | 140 | 4.158 | 5.217 | -0.905 | 0.507 | 0.496 | 6.231 |
| minutes | direct_ols | 140 | 4.423 | 5.600 | -1.898 | 0.507 | 0.503 | 7.086 |
| minutes | player_ridge | 140 | 4.315 | 5.487 | -1.450 | 0.486 | 0.472 | 7.059 |
| minutes | opportunity_ridge | 140 | 4.137 | 5.274 | -0.578 | 0.521 | 0.507 | 6.119 |
| minutes | mixture_soft | 140 | 4.106 | 5.334 | -0.705 | 0.529 | 0.508 | 5.954 |
| minutes | mixture_hard | 140 | 4.941 | 6.198 | -0.933 | 0.450 | 0.413 | 6.846 |
| minutes | selected | 140 | 4.137 | 5.274 | -0.578 | 0.521 | 0.507 | 6.119 |
| usg | carry | 140 | 3.410 | 4.077 | 0.210 | 0.500 | 0.333 | 6.605 |
| usg | frozen_phase2 | 140 | 2.771 | 3.462 | -0.568 | 0.550 | 0.402 | 5.097 |
| usg | matched_phase2 | 140 | 2.651 | 3.435 | -0.817 | 0.579 | 0.469 | 4.538 |
| usg | direct_ols | 140 | 2.819 | 3.527 | -0.703 | 0.557 | 0.421 | 5.087 |
| usg | player_ridge | 140 | 2.795 | 3.506 | -0.663 | 0.550 | 0.416 | 5.008 |
| usg | opportunity_ridge | 140 | 2.636 | 3.351 | -0.323 | 0.579 | 0.444 | 4.879 |
| usg | mixture_soft | 140 | 2.555 | 3.315 | -0.424 | 0.593 | 0.462 | 4.622 |
| usg | mixture_hard | 140 | 3.146 | 3.806 | -0.184 | 0.521 | 0.358 | 5.920 |
| usg | selected | 140 | 2.819 | 3.527 | -0.703 | 0.557 | 0.421 | 5.087 |
| ast | carry | 140 | 4.231 | 5.502 | -0.059 | 0.436 | 0.333 | 8.326 |
| ast | frozen_phase2 | 140 | 3.586 | 4.784 | -1.001 | 0.536 | 0.474 | 6.488 |
| ast | matched_phase2 | 140 | 3.418 | 4.620 | -0.909 | 0.514 | 0.483 | 5.784 |
| ast | direct_ols | 140 | 3.617 | 4.834 | -0.799 | 0.507 | 0.445 | 6.514 |
| ast | player_ridge | 140 | 3.609 | 4.816 | -0.848 | 0.536 | 0.485 | 6.373 |
| ast | opportunity_ridge | 140 | 3.529 | 4.670 | -0.709 | 0.521 | 0.479 | 5.968 |
| ast | mixture_soft | 140 | 3.636 | 4.756 | -0.752 | 0.493 | 0.463 | 5.903 |
| ast | mixture_hard | 140 | 4.524 | 5.865 | -1.643 | 0.436 | 0.430 | 5.606 |
| ast | selected | 140 | 3.529 | 4.670 | -0.709 | 0.521 | 0.479 | 5.968 |

Paired 95% bootstrap intervals resample whole transaction packages. Positive MAE gain favors the selected role model; an interval crossing zero does not establish improvement. These intervals are conditional on this reused historical test and the fitted models.

| target | reference | mae_gain | lower | upper | trade_groups |
| --- | --- | --- | --- | --- | --- |
| minutes | matched_phase2 | 0.021 | -0.106 | 0.156 | 68 |
| minutes | direct_ols | 0.286 | -0.092 | 0.647 | 68 |
| minutes | player_ridge | 0.177 | -0.160 | 0.525 | 68 |
| usg | matched_phase2 | -0.168 | -0.293 | -0.038 | 68 |
| usg | direct_ols | 0.000 | 0.000 | 0.000 | 68 |
| usg | player_ridge | -0.023 | -0.039 | -0.007 | 68 |
| ast | matched_phase2 | -0.111 | -0.251 | 0.024 | 68 |
| ast | direct_ols | 0.088 | -0.194 | 0.375 | 68 |
| ast | player_ridge | 0.079 | -0.186 | 0.340 | 68 |

## Large changes

These groups are selected retrospectively by actual changes of at least five minutes or percentage points. They reveal missed role changes, but noisy 15-game outcomes and selection on realized extremes make group-average shrinkage inevitable. Sign accuracy is a weaker measure than correctly exceeding the three-unit direction threshold.

Large increases remain substantially underestimated: minutes actual +10.06, predicted +3.59; usg actual +6.97, predicted +0.49; ast actual +8.46, predicted +1.30. These are averages within the retrospectively selected increase groups, not individual forecasts.

| target | direction | n | method | actual_change | predicted_change | mae | bias | sign_accuracy | direction_accuracy |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| minutes | increase | 31 | matched_phase2 | 10.058 | 3.332 | 6.765 | -6.727 | 0.839 | 0.548 |
| minutes | decrease | 21 | matched_phase2 | -8.644 | -3.278 | 5.443 | 5.366 | 0.857 | 0.571 |
| minutes | increase | 31 | direct_ols | 10.058 | 1.751 | 8.308 | -8.308 | 0.677 | 0.323 |
| minutes | decrease | 21 | direct_ols | -8.644 | -3.362 | 5.282 | 5.282 | 0.952 | 0.619 |
| minutes | increase | 31 | selected | 10.058 | 3.591 | 6.522 | -6.468 | 0.871 | 0.613 |
| minutes | decrease | 21 | selected | -8.644 | -3.131 | 5.524 | 5.513 | 0.905 | 0.524 |
| usg | increase | 15 | matched_phase2 | 6.967 | 0.741 | 6.227 | -6.227 | 0.733 | 0.133 |
| usg | decrease | 17 | matched_phase2 | -6.285 | -3.237 | 3.048 | 3.048 | 0.882 | 0.647 |
| usg | increase | 15 | direct_ols | 6.967 | 0.489 | 6.478 | -6.478 | 0.667 | 0.067 |
| usg | decrease | 17 | direct_ols | -6.285 | -2.425 | 3.860 | 3.860 | 0.941 | 0.471 |
| usg | increase | 15 | selected | 6.967 | 0.489 | 6.478 | -6.478 | 0.667 | 0.067 |
| usg | decrease | 17 | selected | -6.285 | -2.425 | 3.860 | 3.860 | 0.941 | 0.471 |
| ast | increase | 24 | matched_phase2 | 8.461 | 1.265 | 7.196 | -7.196 | 0.792 | 0.250 |
| ast | decrease | 22 | matched_phase2 | -8.179 | -4.282 | 4.244 | 3.897 | 0.909 | 0.682 |
| ast | increase | 24 | direct_ols | 8.461 | 0.582 | 7.879 | -7.879 | 0.625 | 0.083 |
| ast | decrease | 22 | direct_ols | -8.179 | -3.171 | 5.025 | 5.008 | 0.909 | 0.545 |
| ast | increase | 24 | selected | 8.461 | 1.298 | 7.163 | -7.163 | 0.667 | 0.208 |
| ast | decrease | 22 | selected | -8.179 | -3.844 | 4.664 | 4.335 | 0.864 | 0.636 |

## Opportunity features and classification

Player ridge versus opportunity ridge is the predictive ablation for the opportunity feature bundle, with identical splits, weights and lambda grids. Their validation/test MAEs below measure the bundle, not causal effects or individual feature importance. Two-stage alternatives are retained only where validation justifies their added complexity.

No target selected a two-stage model: validation did not justify the extra classification stage under the 1% simplicity rule.

| cohort | target | n | player_ridge_mae | player_ridge_large_mae | opportunity_ridge_mae | opportunity_ridge_large_mae | mixture_soft_mae | mixture_soft_large_mae | mixture_hard_mae | mixture_hard_large_mae |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Trades | minutes | 140 | 4.315 | 7.059 | 4.137 | 6.119 | 4.106 | 5.954 | 4.941 | 6.846 |
| Trades | usg | 140 | 2.795 | 5.008 | 2.636 | 4.879 | 2.555 | 4.622 | 3.146 | 5.920 |
| Trades | ast | 140 | 3.609 | 6.373 | 3.529 | 5.968 | 3.636 | 5.903 | 4.524 | 5.606 |

Additional ablations drop the new role features, trade-package/vacancy features, or destination competition measures from the full opportunity ridge. Each reduced model retunes on the same validation trades and refits on the same development observations. Remaining correlated features can substitute for the removed group, so a small change means limited incremental evidence, not proof that the underlying concept is irrelevant.

Positive values below mean retaining the removed group reduced MAE; negative values favor the reduced model. Consistent validation and test gains are stronger evidence than an isolated improvement.

| target | group | validation_mae_gain_from_group | test_mae_gain_from_group |
| --- | --- | --- | --- |
| minutes | no_added_role | 0.038 | 0.038 |
| usg | no_added_role | -0.005 | 0.003 |
| ast | no_added_role | -0.011 | 0.023 |
| minutes | no_trade_vacancy | -0.023 | 0.066 |
| usg | no_trade_vacancy | -0.078 | 0.030 |
| ast | no_trade_vacancy | -0.108 | -0.085 |
| minutes | no_destination_competition | -0.027 | 0.048 |
| usg | no_destination_competition | 0.010 | 0.039 |
| ast | no_destination_competition | -0.011 | 0.027 |

Removal tests showing a gain from retaining the group in both validation and test: minutes / no_added_role; usg / no_destination_competition. Removing the group improves MAE in both splits for: ast / no_trade_vacancy. The table gives the effect sizes; matching signs alone do not establish reliable gains. These ablations are diagnostics and do not reselect the final model after test results are available.

Inspect the validation table alongside this test table: improvements confined to one split or one target are weak evidence. Correlated vacancy, team context and competition features cannot be assigned independent credit from ridge coefficients.

## Downstream translator experiment

The Phase 2 scripts, fitted artifact and report are preserved. A separate experimental residual model receives predicted changes in minutes, USG% and AST% as three additional inputs. Both its no-role control and its augmented version use exactly the same eligible transfer rows. Baseline forecasts and role predictions for those rows are generated in annual, strictly past-only folds; each fold tunes using earlier labels. Actual role outcomes are never substituted for role inputs.

Control and augmented models tune on trade validation MAE with out-of-time baseline and role predictions. Each target selects augmentation only if it improves validation MAE by more than 1%; otherwise the control is saved. At test time both receive the same final baseline. Stayers retain that baseline without a transfer adjustment. This comparison isolates added role predictions from changes in training-row coverage.

| target | chosen | control_mae | augmented_mae |
| --- | --- | --- | --- |
| minutes | control | 4.612 | 4.602 |
| usg | control | 2.609 | 2.618 |
| ts | control | 5.551 | 5.551 |
| ast | control | 3.538 | 3.539 |

| cohort | target | n | carry_mae | frozen_phase2_mae | matched_phase2_mae | stack_control_mae | augmented_mae | stack_selected_mae |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Trades | minutes | 140 | 4.989 | 4.389 | 4.158 | 4.156 | 4.160 | 4.156 |
| Trades | usg | 140 | 3.410 | 2.771 | 2.651 | 2.659 | 2.645 | 2.659 |
| Trades | ts | 140 | 7.180 | 5.459 | 5.450 | 5.450 | 5.450 | 5.450 |
| Trades | ast | 140 | 4.231 | 3.586 | 3.418 | 3.473 | 3.471 | 3.473 |

| target | method | mae | rmse | bias |
| --- | --- | --- | --- | --- |
| minutes | matched_phase2 | 4.158 | 5.217 | -0.905 |
| minutes | stack_control | 4.156 | 5.185 | -0.762 |
| minutes | augmented | 4.160 | 5.178 | -0.691 |
| minutes | stack_selected | 4.156 | 5.185 | -0.762 |
| usg | matched_phase2 | 2.651 | 3.435 | -0.817 |
| usg | stack_control | 2.659 | 3.410 | -0.770 |
| usg | augmented | 2.645 | 3.399 | -0.790 |
| usg | stack_selected | 2.659 | 3.410 | -0.770 |
| ts | matched_phase2 | 5.450 | 7.367 | -0.647 |
| ts | stack_control | 5.450 | 7.367 | -0.647 |
| ts | augmented | 5.450 | 7.367 | -0.647 |
| ts | stack_selected | 5.450 | 7.367 | -0.647 |
| ast | matched_phase2 | 3.418 | 4.620 | -0.909 |
| ast | stack_control | 3.473 | 4.647 | -0.851 |
| ast | augmented | 3.471 | 4.643 | -0.856 |
| ast | stack_selected | 3.473 | 4.647 | -0.851 |

## Other observations

Stayers, confirmed signings and remaining transfers are scored separately; their results do not choose the trade model.

| cohort | target | n | carry_mae | matched_phase2_mae | selected_mae |
| --- | --- | --- | --- | --- | --- |
| Stayers | minutes | 2501 | 3.211 | 3.078 | 3.178 |
| Stayers | usg | 2501 | 2.032 | 1.908 | 2.012 |
| Stayers | ast | 2501 | 3.235 | 2.911 | 2.972 |
| Signings | minutes | 114 | 5.851 | 4.887 | 4.768 |
| Signings | usg | 114 | 3.376 | 2.647 | 2.757 |
| Signings | ast | 114 | 4.366 | 3.853 | 3.777 |
| Other_transfers | minutes | 7 | 9.193 | 8.497 | 8.163 |
| Other_transfers | usg | 7 | 4.895 | 3.889 | 3.556 |
| Other_transfers | ast | 7 | 2.198 | 2.428 | 2.611 |

## Historical examples

Examples use prespecified familiar players with eligible trades in this test period, taking their earliest eligible test trade. All change columns compare the same previous and next 15 appearances.

| player | date | route | target | prior | actual_change | phase2_change | direct_change | selected_change |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Mikal Bridges | 2024-07-06 | BKN to NYK | minutes | 33.013 | 5.591 | -4.175 | -3.077 | -4.373 |
| Mikal Bridges | 2024-07-06 | BKN to NYK | usg | 20.362 | -1.842 | -0.197 | 0.556 | 0.556 |
| Mikal Bridges | 2024-07-06 | BKN to NYK | ast | 15.867 | -3.286 | -1.988 | 0.109 | -2.112 |
| Karl-Anthony Towns | 2024-10-02 | MIN to NYK | minutes | 30.957 | 2.430 | -1.773 | -1.512 | 0.446 |
| Karl-Anthony Towns | 2024-10-02 | MIN to NYK | usg | 27.658 | 1.567 | -3.282 | -1.743 | -1.743 |
| Karl-Anthony Towns | 2024-10-02 | MIN to NYK | ast | 14.869 | -0.343 | -2.405 | -0.745 | -1.371 |
| Anthony Davis | 2025-02-02 | LAL to DAL | minutes | 32.309 | -2.732 | -0.416 | -1.514 | -0.281 |
| Anthony Davis | 2025-02-02 | LAL to DAL | usg | 30.509 | -0.630 | -3.444 | -3.235 | -3.235 |
| Anthony Davis | 2025-02-02 | LAL to DAL | ast | 17.438 | 4.130 | -0.631 | -0.470 | 0.499 |
| Luka Dončić | 2025-02-02 | DAL to LAL | minutes | 34.927 | -0.377 | 2.735 | 0.428 | 3.728 |
| Luka Dončić | 2025-02-02 | DAL to LAL | usg | 31.964 | 3.856 | -1.170 | -0.811 | -0.811 |
| Luka Dončić | 2025-02-02 | DAL to LAL | ast | 36.040 | 3.132 | -3.981 | -2.560 | -3.996 |
| Jimmy Butler III | 2025-02-06 | MIA to GSW | minutes | 30.000 | 1.630 | 3.206 | -2.567 | 4.463 |
| Jimmy Butler III | 2025-02-06 | MIA to GSW | usg | 19.011 | 1.940 | 1.293 | 0.517 | 0.517 |
| Jimmy Butler III | 2025-02-06 | MIA to GSW | ast | 22.416 | 3.555 | -0.342 | -0.523 | 0.326 |
| Jrue Holiday | 2025-07-07 | BOS to POR | minutes | 32.178 | -1.617 | -1.546 | -5.900 | -0.707 |
| Jrue Holiday | 2025-07-07 | BOS to POR | usg | 15.348 | 6.698 | 0.203 | -0.321 | -0.321 |
| Jrue Holiday | 2025-07-07 | BOS to POR | ast | 18.904 | 16.105 | -1.646 | -2.548 | -1.318 |

## Reproducibility and limits

- PASS: original Phase 2 model/evaluation scripts, fitted RDS and report are byte-for-byte unchanged.
- PASS: every feature precedes its cutoff; shared preprocessing rejects overlapping target windows and applies only known transaction participants.
- PASS: change labels equal next minus previous performance; predictor lists contain no future outcomes.
- PASS: role and baseline cross-fitting use only labels mature before each prediction fold; downstream control and augmentation share fitting rows.
- PASS: final models contain only pre-test labels; predictions are finite and identical with outcome columns removed.
- PASS: all role candidates support one-row inference; the final artifact reloads with identical selected role and downstream predictions.
- PASS: only the new final model artifact and Markdown report are exported; intermediate datasets and predictions remain in memory.
- PASS: eight pre-change trade scenarios retain identical Phase 2 features and benchmark predictions.
- PASS: deliberately altering future focal-player, destination-team and roster box scores leaves a cutoff scenario unchanged, with a fresh snapshot cache.

Run `Rscript "player performance translation/role_change_evaluation.R"` from the repository root. Required packages are data.table, glmnet and jsonlite. The script reads existing collected CSV/JSON files, builds shared features in memory, then writes only `role_change_model.rds` and this report. It does not rerun collection.

For inference, source `role_change_model.R`, read the new RDS artifact, obtain a cutoff-safe feature row with `build_translation_data(...)$make_scenario(...)`, and call `predict_role_change(artifact$role, row)` or `predict_role_augmented_translation(artifact, row)`. Supply a known destination and only transaction participants known at that date. The artifact is trained before July 2024 and is an evaluation model, not a current-roster forecast.

Completing 15 appearances with one destination is required, so short stays, injuries, benchings and cuts are underrepresented. Zero-minute games are excluded, and roster reconstruction has incomplete signing/waiver coverage. Vacated roles are opportunity proxies, not promises of playing time. Minutes have no imposed upper cap; USG/AST forecasts are bounded to 0-100. No lineup, coaching intent, injury availability or depth-chart data is available.

Keep the broader trade-impact model unchanged. Before promotion, require consistent gains over the matched translator and the same-row downstream control on genuinely new data, inspect the remaining large-change errors, and add reliable availability/depth-chart information if it becomes available. Avoid choosing a more aggressive model merely because it predicts larger changes.

R: R version 4.4.1 (2024-06-14 ucrt); glmnet: 4.1.8; seed: 6404. Fold audits and all comparison predictions are returned in memory by `run_role_change()`.
