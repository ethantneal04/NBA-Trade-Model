# Run from the project root:
# Rscript "player performance translation/role_change_evaluation.R"
# In RStudio: source this file, then result <- run_role_change().
# The two final outputs are a model RDS and this phase's Markdown report.
# Comparisons, cross-fitted predictions and diagnostic tables stay in memory.
.role_eval_sources <- Filter(Negate(is.null),lapply(sys.frames(),function(f) f$ofile))
.role_eval_args <- grep('^--file=',commandArgs(FALSE),value=TRUE)
.role_eval_dir <- if(length(.role_eval_sources)) dirname(tail(.role_eval_sources,1L)[[1L]]) else
  if(length(.role_eval_args)) dirname(sub('^--file=','',.role_eval_args[1L])) else 'player performance translation'
source(file.path(.role_eval_dir,'player_translation_evaluation.R'),encoding='UTF-8')
source(file.path(.role_eval_dir,'role_change_model.R'),encoding='UTF-8')

role_change_scores <- function(data,predictions,config) {
  groups <- list(All=rep(TRUE,nrow(data)),Trades=data$verified_trade,Stayers=!data$transfer,
    Signings=data$transfer_type=='confirmed_signing',
    Other_transfers=data$transfer & !data$verified_trade & data$transfer_type!='confirmed_signing')
  rows <- list(); tails <- list()
  for(group in names(groups)) for(target in c('minutes','usg','ast')) {
    use <- which(groups[[group]]); if(!length(use)) next
    actual <- data[[paste0('change_',target)]][use]
    actual_class <- role_change_class(actual,config$direction_threshold[[target]])
    for(method in names(predictions)) {
      prediction <- predictions[[method]][use,target]; error <- prediction-actual
      predicted_class <- role_change_class(prediction,config$direction_threshold[[target]])
      recall <- tapply(predicted_class==actual_class,actual_class,mean)
      large <- abs(actual)>=5
      rows[[length(rows)+1L]] <- data.frame(cohort=group,target=target,n=length(use),method=method,
        mae=mean(abs(error)),rmse=sqrt(mean(error^2)),bias=mean(error),
        direction_accuracy=mean(predicted_class==actual_class),balanced_recall=mean(recall,na.rm=TRUE),
        large_mae=if(any(large)) mean(abs(error[large])) else NA_real_)
      if(group!='Trades') next
      for(direction in c('increase','decrease')) {
        tail <- if(direction=='increase') which(actual>=5) else which(actual<= -5)
        if(!length(tail)) next
        tails[[length(tails)+1L]] <- data.frame(target=target,direction=direction,n=length(tail),method=method,
          actual_change=mean(actual[tail]),predicted_change=mean(prediction[tail]),
          mae=mean(abs(error[tail])),bias=mean(error[tail]),
          sign_accuracy=mean(sign(prediction[tail])==sign(actual[tail])),
          direction_accuracy=mean(predicted_class[tail]==actual_class[tail]))
      }
    }
  }
  list(overall=do.call(rbind,rows),tails=do.call(rbind,tails))
}

# Resample whole transaction packages so two players from one deal do not
# pretend to be independent evidence. Positive values favor the new role model.
role_change_intervals <- function(data,predictions,seed,draws=1000L) {
  set.seed(seed); use <- which(data$verified_trade); rows <- list()
  for(target in c('minutes','usg','ast')) for(reference in c('matched_phase2','direct_ols','player_ridge')) {
    actual <- data[[paste0('change_',target)]][use]
    gain <- abs(predictions[[reference]][use,target]-actual)-abs(predictions$selected[use,target]-actual)
    groups <- split(gain,data$trade_group[use]); sums <- vapply(groups,sum,numeric(1)); sizes <- lengths(groups)
    boot <- replicate(draws,{
      sampled <- sample.int(length(groups),length(groups),replace=TRUE)
      sum(sums[sampled])/sum(sizes[sampled])
    })
    bounds <- stats::quantile(boot,c(.025,.975),names=FALSE)
    rows[[length(rows)+1L]] <- data.frame(target=target,reference=reference,mae_gain=mean(gain),
      lower=bounds[1L],upper=bounds[2L],trade_groups=length(groups))
  }
  do.call(rbind,rows)
}

role_change_examples <- function(data,predictions) {
  # Named in advance for familiar trade cases; never choose examples by error.
  ids <- c(203081,201950,1627783,1629029,202710,203076,1626157,1628969)
  eligible <- which(data$verified_trade & data$player_id%in%ids)
  eligible <- eligible[!duplicated(data$player_id[eligible])]
  rows <- list()
  for(i in eligible) for(target in c('minutes','usg','ast')) {
    rows[[length(rows)+1L]] <- data.frame(player=data$player_name[i],date=as.character(data$cutoff[i]),
      route=paste(data$origin_team[i],data$destination_team[i],sep=' to '),target=target,
      prior=data[[paste0('past_',target)]][i],actual_change=data[[paste0('change_',target)]][i],
      phase2_change=predictions$matched_phase2[i,target],direct_change=predictions$direct_ols[i,target],
      selected_change=predictions$selected[i,target])
  }
  if(length(rows)) do.call(rbind,rows) else data.frame(Note='No prespecified example meets this test split.')
}

write_role_change_report <- function(result,path) {
  config <- result$config; data <- result$bundle$observations; test <- result$test
  roles <- result$role_scores$overall; tails <- result$role_scores$tails
  trade <- roles[roles$cohort=='Trades',]
  primary <- c('carry','frozen_phase2','matched_phase2','direct_ols','player_ridge','opportunity_ridge',
    'mixture_soft','mixture_hard','selected')
  compact <- function(scores,methods,measures=c('mae')) {
    out <- unique(scores[c('cohort','target','n')])
    for(method in methods) for(measure in measures) {
      values <- scores[scores$method==method,]
      out[[paste(method,measure,sep='_')]] <- values[[measure]][match(paste(out$cohort,out$target),paste(values$cohort,values$target))]
    }
    out
  }
  counts <- data.frame(split=c('Training','Validation','Development refit','Test'),
    periods=c(length(result$role$train_rows),length(result$role$validation_rows),
      length(result$role$development_rows),nrow(test)),
    trades=c(sum(data$verified_trade[result$role$train_rows]),length(result$role$validation_rows),
      sum(data$verified_trade[result$role$development_rows]),sum(test$verified_trade)))
  # The role model validates on trades only; the counts table says so explicitly.
  counts$periods[2L] <- sum(data$cutoff>=config$validation_start & data$target_end<config$test_start)
  role_summary <- result$role$selection[c('target','family','lambda','trade_weight','mae')]
  names(role_summary)[5L] <- 'validation_mae'
  comparison <- trade[trade$method%in%primary,c('target','method','n','mae','rmse','bias','direction_accuracy','balanced_recall','large_mae')]
  performance <- result$performance_scores; performance$target <- performance$statistic
  downstream <- performance[performance$cohort=='Trades',]
  best_changes <- vapply(c('minutes','usg','ast'),function(target) {
    old <- trade$mae[trade$target==target & trade$method=='matched_phase2']
    new <- trade$mae[trade$target==target & trade$method=='selected']
    sprintf('%s %.3f -> %.3f',target,old,new)
  },character(1))
  conclusion <- paste0('Selected role MAE versus the matched Phase 2 translator: ',paste(best_changes,collapse='; '),'.')
  supported <- result$intervals$target[result$intervals$reference=='matched_phase2' & result$intervals$lower>0]
  evidence <- paste0('Targets with a transaction-bootstrap MAE gain interval wholly above zero versus matched Phase 2: ',
    if(length(supported)) paste(supported,collapse=', ') else 'none',
    '. The selected models remain experimental; these results do not justify replacing the existing translator.')
  increases <- tails[tails$method=='selected' & tails$direction=='increase',]
  magnitude <- paste0('Large increases remain substantially underestimated: ',paste(sprintf('%s actual %+.2f, predicted %+.2f',
    increases$target,increases$actual_change,increases$predicted_change),collapse='; '),
    '. These are averages within the retrospectively selected increase groups, not individual forecasts.')
  downstream_changes <- vapply(c('minutes','usg','ts','ast'),function(target) {
    control <- downstream$mae[downstream$target==target & downstream$method=='stack_control']
    chosen <- downstream$mae[downstream$target==target & downstream$method=='stack_selected']
    sprintf('%s %+.3f',target,control-chosen)
  },character(1))
  augmented_targets <- result$performance$selection$target[result$performance$selection$chosen=='augmented']
  integration <- paste0('Validation selected role augmentation for ',
    if(length(augmented_targets)) paste(augmented_targets,collapse=', ') else 'no targets',
    '. Test MAE gains versus the same-row control (positive is better): ',paste(downstream_changes,collapse='; '),'.')
  ablation <- result$ablations$tuning
  full_validation <- result$role$tuning[result$role$tuning$family=='opportunity_ridge',]
  ablation$validation_mae_gain_from_group <- ablation$validation_mae-full_validation$mae[match(ablation$target,full_validation$target)]
  full_test <- trade[trade$method=='opportunity_ridge',]
  reduced_test <- trade[trade$method%in%ablation$group,]
  ablation$test_mae_gain_from_group <- reduced_test$mae[match(paste(ablation$target,ablation$group),
    paste(reduced_test$target,reduced_test$method))]-full_test$mae[match(ablation$target,full_test$target)]
  consistent <- ablation[ablation$validation_mae_gain_from_group>0 & ablation$test_mae_gain_from_group>0,]
  harmful <- ablation[ablation$validation_mae_gain_from_group<0 & ablation$test_mae_gain_from_group<0,]
  feature_evidence <- paste0('Removal tests showing a gain from retaining the group in both validation and test: ',
    if(nrow(consistent)) paste(paste(consistent$target,consistent$group,sep=' / '),collapse='; ') else 'none',
    '. Removing the group improves MAE in both splits for: ',
    if(nrow(harmful)) paste(paste(harmful$target,harmful$group,sep=' / '),collapse='; ') else 'none',
    '. The table gives the effect sizes; matching signs alone do not establish reliable gains. These ablations are diagnostics and do not reselect the final model after test results are available.')
  class_selection <- if(any(grepl('mixture',role_summary$family)))
    'At least one target selected a two-stage model on validation; check the test comparisons before assigning it practical value.' else
    'No target selected a two-stage model: validation did not justify the extra classification stage under the 1% simplicity rule.'
  lines <- c('# Phase 3: opportunity and role change evaluation','',conclusion,'',evidence,'',integration,'',
    '## Data and timing','',
    sprintf('Each observation predicts the next 15 positive-minute appearances. Game coverage ends %s. Training labels finish before %s; validation trades start on that date and finish before %s. Final refits use only labels mature before %s. Test cutoffs start on %s.',
      result$bundle$data_last,config$validation_start,config$test_start,config$test_start,config$test_start),'',
    translation_markdown_table(counts),'',
    sprintf('The test includes %s genuine trades in %s transaction packages involving %s players. Validation model selection uses genuine trades only. Cross-boundary immature labels are purged; player target windows do not overlap.',
      sum(test$verified_trade),length(unique(test$trade_group[test$verified_trade])),length(unique(test$player_id[test$verified_trade]))),'',
    '**Holdout limitation:** Phase 2 already examined games through April 2026. The later July 2024 split is chronological and excluded from this phase\'s tuning, but it is not newly collected, untouched evidence. The 15-game choice also comes from Phase 2. Claims need a future season or another genuinely unseen dataset. The frozen Phase 2 benchmark was trained through June 2023; the matched benchmark reruns its unchanged architecture using this phase\'s split and lambda grid.','',
    '## Models and validation selection','',
    'All models predict next-period minus previous-period minutes, USG% and AST%. Percentages are percentage points and box-score estimates. Training weights are 0.1 for stayers, 1 for other transfers, and 1, 2 or 4 for verified trades, selected on validation MAE. The direct OLS baseline fixes the trade weight at 1.','',
    'The player baseline uses prior roles, trends, age, height, prior-season BPM and known team change. Opportunity ridge adds the existing reconstructed roster, team context and trade package features plus available-role gaps, positive/negative vacancy terms, high-usage competitors and established creators. Positions are approximated with height bands because reliable position labels are unavailable. All roster statistics precede the cutoff; known same-day trade participants are applied without using their later performance.','',
    'The two-stage alternatives fit a three-class ridge classifier and class-specific magnitude regressions. Soft predictions average the three conditional changes; hard predictions use the most likely class. A change of at least +3 is an increase and at most -3 a decrease; the middle class is stable. Each target uses the simplest family within 1% of the best validation MAE. No test metric determines selection.','',
    translation_markdown_table(role_summary),'',
    translation_markdown_table(result$role$tuning[c('target','family','lambda','trade_weight','mae','large_mae','direction_accuracy')]),'',
    '## Genuine-trade results','',
    'MAE is also the absolute error in the projected level, since every change prediction uses the same prior-period baseline. Lower MAE/RMSE is better; bias is predicted minus actual. Direction accuracy includes stable cases; balanced recall gives each observed class equal weight. Accuracy and recall are fractions from 0 to 1.','',
    translation_markdown_table(compact(trade,primary)),'',
    translation_markdown_table(comparison),'',
    'Paired 95% bootstrap intervals resample whole transaction packages. Positive MAE gain favors the selected role model; an interval crossing zero does not establish improvement. These intervals are conditional on this reused historical test and the fitted models.','',
    translation_markdown_table(result$intervals),'',
    '## Large changes','',
    'These groups are selected retrospectively by actual changes of at least five minutes or percentage points. They reveal missed role changes, but noisy 15-game outcomes and selection on realized extremes make group-average shrinkage inevitable. Sign accuracy is a weaker measure than correctly exceeding the three-unit direction threshold.','',
    magnitude,'',
    translation_markdown_table(tails[tails$method%in%c('matched_phase2','direct_ols','selected'),]),'',
    '## Opportunity features and classification','',
    'Player ridge versus opportunity ridge is the predictive ablation for the opportunity feature bundle, with identical splits, weights and lambda grids. Their validation/test MAEs below measure the bundle, not causal effects or individual feature importance. Two-stage alternatives are retained only where validation justifies their added complexity.','',
    class_selection,'',
    translation_markdown_table(compact(trade,c('player_ridge','opportunity_ridge','mixture_soft','mixture_hard'),c('mae','large_mae'))),'',
    'Additional ablations drop the new role features, trade-package/vacancy features, or destination competition measures from the full opportunity ridge. Each reduced model retunes on the same validation trades and refits on the same development observations. Remaining correlated features can substitute for the removed group, so a small change means limited incremental evidence, not proof that the underlying concept is irrelevant.','',
    'Positive values below mean retaining the removed group reduced MAE; negative values favor the reduced model. Consistent validation and test gains are stronger evidence than an isolated improvement.','',
    translation_markdown_table(ablation[c('target','group','validation_mae_gain_from_group','test_mae_gain_from_group')]),'',
    feature_evidence,'',
    'Inspect the validation table alongside this test table: improvements confined to one split or one target are weak evidence. Correlated vacancy, team context and competition features cannot be assigned independent credit from ridge coefficients.','',
    '## Downstream translator experiment','',
    'The Phase 2 scripts, fitted artifact and report are preserved. A separate experimental residual model receives predicted changes in minutes, USG% and AST% as three additional inputs. Both its no-role control and its augmented version use exactly the same eligible transfer rows. Baseline forecasts and role predictions for those rows are generated in annual, strictly past-only folds; each fold tunes using earlier labels. Actual role outcomes are never substituted for role inputs.','',
    'Control and augmented models tune on trade validation MAE with out-of-time baseline and role predictions. Each target selects augmentation only if it improves validation MAE by more than 1%; otherwise the control is saved. At test time both receive the same final baseline. Stayers retain that baseline without a transfer adjustment. This comparison isolates added role predictions from changes in training-row coverage.','',
    translation_markdown_table(result$performance$selection),'',
    translation_markdown_table(compact(downstream,c('carry','frozen_phase2','matched_phase2','stack_control','augmented','stack_selected'))),'',
    translation_markdown_table(downstream[downstream$method%in%c('matched_phase2','stack_control','augmented','stack_selected'),
      c('target','method','mae','rmse','bias')]),'',
    '## Other observations','',
    'Stayers, confirmed signings and remaining transfers are scored separately; their results do not choose the trade model.','',
    translation_markdown_table(compact(roles[roles$cohort%in%c('Stayers','Signings','Other_transfers'),],
      c('carry','matched_phase2','selected'))),'',
    '## Historical examples','',
    'Examples use prespecified familiar players with eligible trades in this test period, taking their earliest eligible test trade. All change columns compare the same previous and next 15 appearances.','',
    translation_markdown_table(result$examples),'',
    '## Reproducibility and limits','',
    paste0('- ',result$checks),'',
    'Run `Rscript "player performance translation/role_change_evaluation.R"` from the repository root. Required packages are data.table, glmnet and jsonlite. The script reads existing collected CSV/JSON files, builds shared features in memory, then writes only `role_change_model.rds` and this report. It does not rerun collection.','',
    'For inference, source `role_change_model.R`, read the new RDS artifact, obtain a cutoff-safe feature row with `build_translation_data(...)$make_scenario(...)`, and call `predict_role_change(artifact$role, row)` or `predict_role_augmented_translation(artifact, row)`. Supply a known destination and only transaction participants known at that date. The artifact is trained before July 2024 and is an evaluation model, not a current-roster forecast.','',
    'Completing 15 appearances with one destination is required, so short stays, injuries, benchings and cuts are underrepresented. Zero-minute games are excluded, and roster reconstruction has incomplete signing/waiver coverage. Vacated roles are opportunity proxies, not promises of playing time. Minutes have no imposed upper cap; USG/AST forecasts are bounded to 0-100. No lineup, coaching intent, injury availability or depth-chart data is available.','',
    'Keep the broader trade-impact model unchanged. Before promotion, require consistent gains over the matched translator and the same-row downstream control on genuinely new data, inspect the remaining large-change errors, and add reliable availability/depth-chart information if it becomes available. Avoid choosing a more aggressive model merely because it predicts larger changes.','',
    sprintf('R: %s; glmnet: %s; seed: %s. Fold audits and all comparison predictions are returned in memory by `run_role_change()`.',
      R.version.string,as.character(utils::packageVersion('glmnet')),config$seed))
  writeLines(lines,path,useBytes=TRUE)
}

run_role_change <- function(config=role_change_config(),inputs=NULL,bundle=NULL) {
  set.seed(config$seed)
  preserved <- file.path(TRANSLATION_DIR,c('player_translation_model.R','player_translation_evaluation.R',
    'player_translation_model.rds','evaluation_report.md'))
  original_hashes <- tools::md5sum(preserved)
  frozen <- readRDS(file.path(TRANSLATION_DIR,'player_translation_model.rds'))
  if(is.null(bundle)) bundle <- build_translation_data(config,inputs=inputs)
  stopifnot(identical(bundle$config,config))
  data <- bundle$observations
  targets <- c('minutes','usg','ast'); features <- translation_feature_names()
  stopifnot(all(data$feature_max_date<data$cutoff),all(data$target_games==15L),
    !any(grepl('^(next_|change_|target_)',unlist(features[c('role_simple','role_opportunity','downstream_role')]))))
  for(target in targets) stopifnot(isTRUE(all.equal(data[[paste0('change_',target)]],
    data[[paste0('next_',target)]]-data[[paste0('past_',target)]],tolerance=1e-12)))
  message('Fitting direct role changes and opportunity alternatives')
  role <- fit_role_change(data,config)
  message('Refitting the unchanged Phase 2 architecture on the matched chronological split')
  matched <- fit_player_translation(bundle)
  message('Generating past-only role predictions for downstream training')
  role_oof <- role_change_crossfit(data,config)
  baseline_oof <- translation_crossfit(data,config,features$baseline)
  performance <- fit_role_downstream(bundle,role_oof,baseline_oof,matched)
  ablations <- fit_role_ablations(data,config)
  # Nothing below this line can change a fitted model or its selected settings.
  test <- data[data$cutoff>=config$test_start,]
  stopifnot(role$latest_training_label<min(test$cutoff),performance$latest_training_label<min(test$cutoff))
  frozen_pred <- predict_player_translation(frozen,test)$final
  matched_pred <- predict_player_translation(matched,test)$final
  past <- as.matrix(test[paste0('past_',targets)]); colnames(past) <- targets
  role_predictions <- list(carry=past*0,frozen_phase2=frozen_pred[,targets,drop=FALSE]-past,
    matched_phase2=matched_pred[,targets,drop=FALSE]-past)
  for(method in c(names(role$candidates),'selected'))
    role_predictions[[method]] <- predict_role_change(role,test,method)$delta
  for(group in names(ablations$fits)) {
    prediction <- past*0
    for(target in targets) prediction[,target] <- role_bounded_delta(
      predict_translation_ridge(ablations$fits[[group]][[target]],test)[,1L],test,target)
    role_predictions[[group]] <- prediction
  }
  artifact <- list(version='phase-3-role-and-experimental-translator',config=config,role=role,performance=performance,
    input_hashes=bundle$input_files,preserved_phase2_hashes=original_hashes,
    software=list(R=R.version.string,glmnet=as.character(utils::packageVersion('glmnet'))))
  carry <- as.matrix(test[paste0('past_',matched$targets)]); colnames(carry) <- matched$targets
  performance_predictions <- list(carry=carry,frozen_phase2=frozen_pred,matched_phase2=matched_pred,
    stack_control=predict_role_augmented_translation(artifact,test,'control')$performance,
    augmented=predict_role_augmented_translation(artifact,test,'augmented')$performance,
    stack_selected=predict_role_augmented_translation(artifact,test)$performance)
  role_scores <- role_change_scores(test,role_predictions,config)
  performance_scores <- translation_metrics(test,performance_predictions)
  intervals <- role_change_intervals(test,role_predictions,config$seed)
  examples <- role_change_examples(test,role_predictions)
  stopifnot(all(vapply(c(role_predictions,performance_predictions),function(x) all(is.finite(x)),logical(1))))
  for(audit in list(role_oof$audit,baseline_oof$audit))
    stopifnot(nrow(audit)>0L,all(audit$latest_training_label<audit$earliest_prediction))
  outcome_free <- test[,!grepl('^(next_|change_|target_)',names(test)),drop=FALSE]
  stopifnot(identical(predict_role_change(role,outcome_free)$delta,role_predictions$selected),
    identical(predict_role_augmented_translation(artifact,outcome_free)$performance,performance_predictions$stack_selected))
  for(method in names(role$candidates)) stopifnot(isTRUE(all.equal(
    predict_role_change(role,test[1L,],method)$delta,role_predictions[[method]][1L,,drop=FALSE],check.attributes=FALSE)))
  artifact$role$candidates <- NULL; artifact$performance$candidates <- NULL
  for(component in c('role','performance')) {
    artifact[[component]]$row_counts <- vapply(artifact[[component]][c('train_rows','validation_rows','development_rows')],length,integer(1))
    artifact[[component]][c('train_rows','validation_rows','development_rows')] <- NULL
  }
  # Save the selected fits and their audit summaries, without training rows,
  # alternative fits, out-of-time prediction matrices or diagnostic tables.
  path <- file.path(TRANSLATION_DIR,'role_change_model.rds')
  saveRDS(artifact,path,compress='xz')
  restored <- readRDS(path)
  stopifnot(identical(predict_role_change(restored$role,test)$delta,role_predictions$selected),
    identical(predict_role_augmented_translation(restored,test)$performance,performance_predictions$stack_selected),
    identical(original_hashes,tools::md5sum(preserved)))
  checks <- c('PASS: original Phase 2 model/evaluation scripts, fitted RDS and report are byte-for-byte unchanged.',
    'PASS: every feature precedes its cutoff; shared preprocessing rejects overlapping target windows and applies only known transaction participants.',
    'PASS: change labels equal next minus previous performance; predictor lists contain no future outcomes.',
    'PASS: role and baseline cross-fitting use only labels mature before each prediction fold; downstream control and augmentation share fitting rows.',
    'PASS: final models contain only pre-test labels; predictions are finite and identical with outcome columns removed.',
    'PASS: all role candidates support one-row inference; the final artifact reloads with identical selected role and downstream predictions.',
    'PASS: only the new final model artifact and Markdown report are exported; intermediate datasets and predictions remain in memory.')
  result <- list(config=config,bundle=bundle,test=test,role=role,matched=matched,performance=performance,
    artifact=artifact,role_oof=role_oof,baseline_oof=baseline_oof,role_predictions=role_predictions,
    performance_predictions=performance_predictions,role_scores=role_scores,performance_scores=performance_scores,
    intervals=intervals,examples=examples,checks=checks,ablations=ablations)
  write_role_change_report(result,file.path(TRANSLATION_DIR,'role_change_evaluation_report.md'))
  print(role$selection[c('target','family','mae')],row.names=FALSE)
  print(role_scores$overall[role_scores$overall$cohort=='Trades' & role_scores$overall$method%in%c('matched_phase2','selected'),],row.names=FALSE)
  message('Saved the Phase 3 model and report. The existing translator is preserved.')
  invisible(result)
}

if(sys.nframe()==0L) run_role_change()
