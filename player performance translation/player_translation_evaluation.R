# From the repository root:
#   install.packages(c('data.table', 'glmnet'))  # once, in R
#   Rscript "player performance translation/player_translation_evaluation.R"
# Or source this file in RStudio and call run_player_translation().
# Only the final fitted model and Markdown report are written to disk.

.evaluation_sources <- Filter(Negate(is.null), lapply(sys.frames(), function(f) f$ofile))
.evaluation_args <- grep('^--file=', commandArgs(FALSE), value=TRUE)
.evaluation_dir <- if (length(.evaluation_sources)) dirname(tail(.evaluation_sources,1L)[[1L]]) else
  if (length(.evaluation_args)) dirname(sub('^--file=', '', .evaluation_args[1L])) else 'player performance translation'
source(file.path(.evaluation_dir, 'player_translation_data.R'), encoding='UTF-8')
source(file.path(.evaluation_dir, 'player_translation_model.R'), encoding='UTF-8')

translation_metrics <- function(data, predictions) {
  methods <- c('no_change','baseline','final','no_destination')
  groups <- list(All=rep(TRUE,nrow(data)), Stayers=!data$transfer,
                 Transfers=data$transfer, Verified_trades=data$verified_trade)
  out <- list()
  for (group in names(groups)) for (target in c('minutes','usg','ts','ast')) {
    use <- which(groups[[group]])
    if (!length(use)) next
    actual <- data[[paste0('next_',target)]][use]
    for (method in methods) {
      error <- predictions[[method]][use,target]-actual
      out[[length(out)+1L]] <- data.frame(cohort=group, statistic=target, n=length(use),
        method=method, mae=mean(abs(error)), rmse=sqrt(mean(error^2)), bias=mean(error))
    }
  }
  do.call(rbind,out)
}

# Resample players rather than individual windows. A positive number means
# lower absolute error for the full translator. These are descriptive intervals.
translation_improvement_intervals <- function(data, predictions, seed, draws=1000L) {
  set.seed(seed); use <- which(data$transfer)
  out <- list()
  for (target in c('minutes','usg','ts','ast')) for (reference in c('no_change','no_destination')) {
    actual <- data[[paste0('next_',target)]][use]
    improvement <- abs(predictions[[reference]][use,target]-actual) -
                   abs(predictions$final[use,target]-actual)
    clusters <- split(improvement, data$player_id[use])
    sums <- vapply(clusters,sum,numeric(1)); sizes <- lengths(clusters)
    boot <- replicate(draws, {
      sample <- sample.int(length(clusters),length(clusters),replace=TRUE)
      sum(sums[sample])/sum(sizes[sample])
    })
    interval <- stats::quantile(boot,c(.025,.975),names=FALSE)
    out[[length(out)+1L]] <- data.frame(statistic=target, compared_with=reference,
      improvement=mean(improvement), lower=interval[1L], upper=interval[2L], players=length(clusters))
  }
  do.call(rbind,out)
}

translation_checks <- function(bundle, model, test, predictions) {
  fixture <- data.frame(minutes=rep(24,40), fga=10, fta=4, fgm=8, pts=25,
    tov=2, ast=5, oreb=1, dreb=3, fg3a=4,
    team_fga=80, team_fta=20, team_tov=12, team_fgm=40, team_elapsed=48)
  calculated <- translation_window_stats(fixture)
  expected <- c(minutes=24, usg=100*(10+.44*4+2)*48/(24*(80+.44*20+12)),
                ts=100*25/(2*(10+.44*4)), ast=100*5/(24/48*40-8))
  stopifnot(isTRUE(all.equal(calculated[names(expected)],expected,tolerance=1e-12)))
  zero_denominator <- fixture; zero_denominator$fgm <- 20
  stopifnot(is.na(translation_window_stats(zero_denominator)['ast']))
  # Actual future values and reporting fields must not be needed for prediction.
  features <- unique(c(translation_feature_names()$baseline,
                       translation_feature_names()$adjustment,
                       translation_feature_names()$no_destination,'transfer'))
  without_labels <- predict_player_translation(model,test[,features,drop=FALSE])
  stopifnot(identical(predictions$final,without_labels$final),
            all(bundle$observations$feature_max_date < bundle$observations$cutoff),
            model$latest_training_label < min(test$cutoff),
            model$latest_adjustment_label < min(test$cutoff),
            all(model$crossfit_audit$latest_training_label < model$crossfit_audit$earliest_prediction),
            !any(grepl('^(next_|target_)',model$baseline$minutes$features)),
            identical(predictions$final[!test$transfer,,drop=FALSE], predictions$baseline[!test$transfer,,drop=FALSE]),
            all(is.finite(predictions$final)))
  # Imputation uses stored training medians, even for an extreme held-out value.
  train_example <- data.frame(a=c(1,3,NA_real_),b=c(2,2,2))
  design <- translation_matrix(train_example,c('a','b'))
  held <- translation_matrix(data.frame(a=NA_real_,b=1e9),c('a','b'),design$medians)
  stopifnot(held$x[1,'a']==2, held$x[1,'a_missing']==1)
  # Reconstruct a held-out trade using the same public scenario function a
  # future hypothetical trade will use. It must match without asking for labels.
  sample <- which(test$verified_trade)[1L]
  scenario <- bundle$make_scenario(test$player_id[sample],test$destination_team_id[sample],test$cutoff[sample])
  scenario_features <- unique(c(translation_feature_names()$baseline,translation_feature_names()$adjustment))
  stopifnot(isTRUE(all.equal(as.numeric(scenario[1,scenario_features]),
                             as.numeric(test[sample,scenario_features]),tolerance=0)),
            isTRUE(all.equal(unname(predict_player_translation(model,scenario)$final[1,]),
                             unname(predictions$final[sample,]),tolerance=0)))
  c('Window formulas and undefined-denominator handling',
    'Every feature date strictly precedes its prediction cutoff',
    'All training targets mature before the test period; yearly residual folds are chronological',
    'Prediction works with all future labels removed; fitting features use an explicit allowlist',
    'Team-change adjustment is exactly zero for stayers',
    'Imputation uses training medians; test values do not alter preprocessing',
    'All held-out predictions are finite',
    'The scenario API reproduces a held-out trade without requiring its future appearances')
}

translation_markdown_table <- function(data, digits=3L) {
  formatted <- lapply(data,function(x) {
    if (is.numeric(x)) format(round(x,digits),trim=TRUE,scientific=FALSE) else as.character(x)
  })
  cells <- do.call(cbind,formatted)
  rows <- apply(cells,1L,function(x) paste0('| ',paste(gsub('|','/',x,fixed=TRUE),collapse=' | '),' |'))
  c(paste0('| ',paste(names(data),collapse=' | '),' |'),
    paste0('| ',paste(rep('---',ncol(data)),collapse=' | '),' |'),rows)
}

translation_score_table <- function(scores, measure) {
  rows <- unique(scores[c('cohort','statistic','n')])
  for (method in c('no_change','baseline','final','no_destination')) {
    selected <- scores[scores$method==method,]
    rows[[method]] <- selected[[measure]][match(paste(rows$cohort,rows$statistic),paste(selected$cohort,selected$statistic))]
  }
  names(rows) <- c('Cohort','Statistic','N','Carry forward','Model A','Model A + B','No destination')
  rows
}

write_translation_report <- function(bundle, model, test, predictions, scores, intervals, checks, output_path) {
  # Filled below: the report is generated from held-out results, not hand-picked
  # performance claims or a second tuning pass on the test set.
  config <- bundle$config
  split_names <- c('train','validation','development','test')
  counts <- do.call(rbind,lapply(split_names,function(name) {
    d <- bundle$observations[model$split_rows[[name]],]
    data.frame(Split=name,Periods=nrow(d),Stayers=sum(!d$transfer),
               Transfers=sum(d$transfer),Verified_trades=sum(d$verified_trade))
  }))
  diagnostics <- list()
  groups <- list('Higher realized usage (+5pp)'=test$transfer & test$next_usg-test$past_usg>=5,
    'Other usage outcomes'=test$transfer & test$next_usg-test$past_usg<5,
    'Destination has a 28%+ usage player'=test$transfer & test$destination_top_usage>=28,
    'Destination without a 28%+ usage player'=test$transfer & test$destination_top_usage<28)
  for (name in names(groups)) {
    use <- which(groups[[name]]); if (!length(use)) next
    row <- data.frame(Situation=name,N=length(use),check.names=FALSE)
    for (target in model$targets) {
      actual <- test[[paste0('next_',target)]][use]
      row[[target]] <- sprintf('%.2f / %.2f',mean(abs(predictions$no_change[use,target]-actual)),
                               mean(abs(predictions$final[use,target]-actual)))
    }
    diagnostics[[length(diagnostics)+1L]] <- row
  }
  examples <- list()
  for (i in which(test$verified_trade)) {
    row <- data.frame(Trade=paste0('[',test$player_name[i],'](',test$transaction_source[i],')'),
      Cutoff=as.character(test$cutoff[i]),Move=paste(test$origin_team[i],'to',test$destination_team[i]),
      Target_end=as.character(test$target_end[i]),check.names=FALSE)
    for (target in model$targets) row[[target]] <- sprintf('%.2f / %.2f / %.2f / %.2f',
      predictions$no_change[i,target],predictions$baseline[i,target],predictions$final[i,target],test[[paste0('next_',target)]][i])
    examples[[length(examples)+1L]] <- row
  }
  effects <- list()
  for (stage in c('baseline','adjustment')) for (target in model$targets) {
    fitted <- model[[stage]][[target]]
    coefficients <- as.matrix(stats::coef(fitted$fit,s=fitted$lambda))[-1,1]
    impact <- coefficients*fitted$x_sd*fitted$y_scale
    if (stage=='adjustment') impact <- impact*fitted$adjustment_scale
    use <- head(order(abs(impact),decreasing=TRUE),3L)
    effects[[length(effects)+1L]] <- data.frame(Stage=stage,Statistic=target,
      Feature=names(impact)[use],Effect_per_SD=unname(impact[use]))
  }
  purged <- nrow(bundle$observations)-length(unique(unlist(model$split_rows[c('train','validation','test')])))
  context_verdict <- vapply(model$targets,function(target) {
    subset <- scores[scores$cohort=='Transfers' & scores$statistic==target,]
    delta <- subset$mae[subset$method=='no_destination']-subset$mae[subset$method=='final']
    sprintf('- %s: destination context %s transfer MAE by %.3f %s.',target,
      if (delta>0) 'improves' else if (delta<0) 'worsens' else 'does not change',abs(delta),
      if (target=='minutes') 'minutes' else 'percentage points')
  },character(1))
  trade_verdict <- vapply(model$targets,function(target) {
    subset <- scores[scores$cohort=='Verified_trades' & scores$statistic==target,]
    if (!nrow(subset)) return(sprintf('- %s: no eligible verified test trades.',target))
    carry <- subset$mae[subset$method=='no_change']; final <- subset$mae[subset$method=='final']
    sprintf('- %s: carry-forward MAE %.3f; translator %.3f (%s).',target,carry,final,
      if (final<carry) 'better' else if (final>carry) 'worse' else 'unchanged')
  },character(1))
  lines <- c('# Player performance translation: Phase 1', '',
    '## What this version establishes','',
    sprintf('The held-out test contains %s player periods, including %s transfers and only %s verified trades. Aggregate transfer results and verified-trade results must be read separately.',nrow(test),sum(test$transfer),sum(test$verified_trade)),'',
    'Verified-trade performance against carrying forward old-team averages:','',trade_verdict,'',
    'This is an experimental predictive baseline. Broad transfer improvements do not establish reliable trade-specific performance or a causal team-change effect. A complete transaction history and better contemporaneous roster/injury information are needed before trade-impact integration. The examples below include failures as well as successes.','',
    '## Run and reuse', '',
    'Install `data.table` and `glmnet`, then run from the repository root:', '',
    '```sh','Rscript "player performance translation/player_translation_evaluation.R"','```','',
    'In RStudio, source that file and call `result <- run_player_translation()`. The result keeps observations and predictions in memory. `predict_player_translation(model, newdata)` accepts pre-period features and `transfer`; outcomes are not required.', '',
    'For a hypothetical destination, build `newdata <- result$data$make_scenario(player_id, destination_team_id, cutoff)` and call `predict_player_translation(result$model, newdata)`. The cutoff is an R `Date` or ISO date string. It must be later than the saved model\'s training labels. The scenario builder does not require any future appearances or outcomes.', '',
    'Only `player_translation_model.rds` and this report are saved. No intermediate datasets, prediction CSVs or plots are exported.', '',
    '## Observation and timing contract', '',
    sprintf('- Windows: %s played appearances; stayer target stride: %s. Targets can cross seasons, but cannot cross another team change.',config$window,config$stride),
    '- Minutes means minutes per played appearance. USG%, TS% and AST% use aggregate window totals, in percentage points. USG and AST are box-score estimates, not exact on-court NBA measures.',
    '- Each transfer has one prediction before its first destination appearance, requiring a full old-team history and a full same-destination target. Stayer targets are nonoverlapping within each player/team episode.',
    '- Verified moves use the transaction day as cutoff, with all same-day games excluded. Other transfers use the start of the last old-team game day: conservative, but often much earlier than the real move. Their mechanism and exact date remain unknown.',
    sprintf('- Both team snapshots contain only games before the cutoff (last %s team games, at least %s). Roster proxies use those games and activity in their last 10 games, excluding the focal player.',config$team_window,config$min_team_games),
    '- Player history, trends, age and prior-season BPM are historical inputs. Names are used only for reporting. No current-season completed BRef statistics, target dates, player IDs or realized post-move role enter the models.', '',
    '## Chronological development and sample counts','',
    sprintf('Train labels end before %s. Validation predictions start on/after that date and their labels finish before %s. Final test predictions start on/after %s.',config$validation_start,config$test_start,config$test_start),'',
    translation_markdown_table(counts), '',
    sprintf('%s boundary-crossing periods are purged from the original tuning splits. Final development refits use every label completed before the test start. Test outcomes never select hyperparameters.',purged),
    sprintf('Model B uses %s transfer residuals for tuning fits and %s for final fitting, each from an earlier-year Model A fit. %s of the final residuals are verified trades.',length(model$tuning_residual_rows),length(model$residual_rows),sum(bundle$observations$verified_trade[model$residual_rows])),
    sprintf('Detected team changes: %s. Eligible complete transfer windows: %s. Verified registry entries: %s; matched movement entries: %s.',nrow(bundle$movements),sum(bundle$movements$eligible),nrow(bundle$registry),sum(bundle$movements$verified_trade)), '',
    'Candidate exclusions (first failed requirement; also includes stayer candidates):','',
    translation_markdown_table(data.frame(Reason=names(bundle$excluded),Count=unname(bundle$excluded))), '',
    '## Models and tuning', '',
    'Model A fits all eligible periods using player performance, older-window trends and current-team context. Model B predicts residuals for movers using player history, destination context and destination-minus-origin differences. Stayers receive zero adjustment. A player-only adjustment is trained as the destination-context ablation.',
    'Four separate standardized ridge regressions keep each target interpretable and allow separate shrinkage. A joint-output model is deferred: the outcomes have different noise and units, and the small transfer sample does not support a more complex shared model yet.',
    'All imputation and scaling are fitted on training rows. Lambda is selected by validation MAE. Historical residual folds tune their own baseline lambda inside an earlier chronological inner split, never using later validation or test labels. Model B additionally compares verified-trade weights of 1 and 2 and adjustment scales of 0, 0.5 and 1, using the same validation movers. Zero scale is a valid result. Final fits use only pre-test labels.', '',
    'The A tuning MAE uses all validation periods; adjustment tuning MAE uses validation transfers only.', '',
    translation_markdown_table(model$tuning), '',
    '## Held-out accuracy', '',
    'Units: minutes for `minutes`; percentage points for `usg`, `ts` and `ast`. Carry forward repeats the previous window. No destination is Model A plus a player-only mover adjustment. These are fixed-model tests, without retuning on test performance.', '',
    '### MAE','',translation_markdown_table(translation_score_table(scores,'mae')),'',
    '### RMSE','',translation_markdown_table(translation_score_table(scores,'rmse')),'',
    '### Does destination context help?','',context_verdict,'',
    'Positive improvement below means lower MAE for the full translator. Intervals use 1,000 paired bootstrap samples clustered by player. They are descriptive, do not account for all shared team/trade shocks, and do not establish a causal team effect.','',
    translation_markdown_table(intervals),'',
    '## Historical trade examples','',
    'All eligible verified trades in the test split are shown, not a selection of favorable results. Each statistic is **carry forward / Model A / Model A+B / actual**. Names link to the dated trade sources; game outcomes come from the existing CSVs.', '',
    if (length(examples)) translation_markdown_table(do.call(rbind,examples),2L) else 'No verified trades met the held-out eligibility rules.', '',
    '## Where errors change','',
    'Cells show **carry-forward MAE / translator MAE**. The larger-role grouping uses realized next-period usage strictly for diagnosis; it is not an input feature. The 28% destination threshold uses the pre-cutoff roster proxy.', '',
    translation_markdown_table(do.call(rbind,diagnostics)), '',
    'The larger-role group is harder to predict; compare its usage errors with the other-outcomes group. In the individual trade examples, compare assist predictions with the realized expanded playmaking roles. These are diagnostic comparisons, not reasons to retune on this test set.', '',
    '## Interpretable coefficients','',
    'Three largest absolute fitted effects per target and stage, for a one-training-standard-deviation feature change. Units are target units; associations are conditional on correlated features, not causal effects. Zero adjustment scale gives zero effects.', '',
    translation_markdown_table(do.call(rbind,effects)),'',
    '## Limits before trade-model integration','',
    '- A complete 40-appearance target selects players who remain active and stay on the destination team long enough. This is survivorship conditioning, not an availability, injury, DNP or unconditional 40-team-game forecast. Excluded short stays and unknown move dates limit generalization.',
    '- The verified-trade list is a small, nonrepresentative set of sourced examples. Other moves mix actual trades, free agency, waivers and other transfers. They are not silently counted as trades. Trade-only errors and trade weighting need a comprehensive dated transaction source before being treated as representative.',
    '- Team changes are detected from played games; intervening teams with no appearance cannot be identified. Contract dates, injury status, playoff games, actual positions (the source position column is empty), confirmed depth charts and exact on-court possessions are unavailable.',
    '- Height bands proxy positional competition. Recent rotations can still contain players departing in the same deal and cannot anticipate additional signings or coaching changes. Available minutes/plays are historical proxies, not guaranteed vacancies or a fully reconstructed post-trade roster.',
    '- Team B adjustments are predictive residual corrections among observed movers, not identified causal effects of a hypothetical trade. Conditional destination input assumes the proposed destination is known.',
    '- Windows can span offseasons, and older histories may be stale. All features remain before the cutoff; strict past dates do not remove selection bias or guarantee roster information was complete.',
    '- The saved model is the pre-test research fit, not a production refit through the latest season. The coefficients stay fixed across the test years, so regime changes and aging patterns can affect later-year accuracy.',
    '- Results describe the frozen local data snapshot. Re-downloaded historical sources may change. The artifact stores input hashes, settings, selected parameters and fitting dates; it contains no intermediate datasets.', '',
    '## Checks completed','',paste0('- PASS: ',checks), '',
    '## References','',
    '- [Box-score percentage formulas](https://sportsdata.io/help/basketball-formula-reference-guide)',
    '- [glmnet documentation](https://glmnet.stanford.edu/articles/glmnet.html)',
    '- Trade verification links are embedded in `verified_translation_trades()` and in the examples above.'
  )
  writeLines(lines, output_path, useBytes=TRUE)
}

run_player_translation <- function(config=translation_config()) {
  message('Constructing player periods and pre-period team snapshots')
  bundle <- build_translation_data(config)
  message('Eligible periods: ',nrow(bundle$observations),'; transfers: ',sum(bundle$observations$transfer))
  model <- fit_player_translation(bundle)
  test <- bundle$observations[model$split_rows$test,]
  predictions <- predict_player_translation(model,test)
  predictions$no_change <- as.matrix(test[paste0('past_',model$targets)])
  colnames(predictions$no_change) <- model$targets
  scores <- translation_metrics(test,predictions)
  intervals <- translation_improvement_intervals(test,predictions,config$seed)
  checks <- translation_checks(bundle,model,test,predictions)
  artifact_path <- file.path(TRANSLATION_DIR,'player_translation_model.rds')
  report_path <- file.path(TRANSLATION_DIR,'evaluation_report.md')
  saveRDS(model,artifact_path,compress='xz')
  restored <- readRDS(artifact_path)
  stopifnot(identical(predict_player_translation(restored,test)$final,predictions$final))
  checks <- c(checks,'Saved model reloads with identical held-out predictions')
  write_translation_report(bundle,model,test,predictions,scores,intervals,checks,report_path)
  print(scores[scores$cohort=='Transfers',c('statistic','method','n','mae','rmse')],row.names=FALSE)
  message('Saved final model and report in ',TRANSLATION_DIR)
  invisible(list(model=model,data=bundle,predictions=predictions,metrics=scores,intervals=intervals))
}

if (sys.nframe()==0L) run_player_translation()
