# Phase 2: run from the repository root with
# Rscript "player performance translation/player_translation_evaluation.R"
# In RStudio, source this file and call result <- run_player_translation().
# Install data.table, glmnet and jsonlite once. Only the final RDS and report
# are written; all window experiments and predictions remain in memory.

.evaluation_sources <- Filter(Negate(is.null), lapply(sys.frames(), function(f) f$ofile))
.evaluation_args <- grep('^--file=', commandArgs(FALSE), value=TRUE)
.evaluation_dir <- if (length(.evaluation_sources)) dirname(tail(.evaluation_sources,1L)[[1L]]) else
  if (length(.evaluation_args)) dirname(sub('^--file=', '', .evaluation_args[1L])) else 'player performance translation'
source(file.path(.evaluation_dir, 'player_translation_data.R'), encoding='UTF-8')
source(file.path(.evaluation_dir, 'player_translation_model.R'), encoding='UTF-8')

translation_markdown_table <- function(data, digits=3L) {
  formatted <- lapply(data,function(x) {
    if (is.numeric(x)) format(round(x,digits),trim=TRUE,scientific=FALSE) else as.character(x)
  })
  cells <- do.call(cbind,formatted)
  rows <- apply(cells,1L,function(x) paste0('| ',paste(gsub('|','/',x,fixed=TRUE),collapse=' | '),' |'))
  c(paste0('| ',paste(names(data),collapse=' | '),' |'),
    paste0('| ',paste(rep('---',ncol(data)),collapse=' | '),' |'),rows)
}

translation_predictions <- function(model,data) {
  result <- predict_player_translation(model,data)
  result$no_change <- as.matrix(data[paste0('past_',model$targets)])
  colnames(result$no_change) <- model$targets
  result
}

translation_metrics <- function(data,predictions) {
  groups <- list(All=rep(TRUE,nrow(data)),Stayers=!data$transfer,
    Trades=data$verified_trade,Signings=data$transfer_type=='confirmed_signing',
    Other_transfers=data$transfer & !data$verified_trade & data$transfer_type!='confirmed_signing')
  rows <- list()
  for (group in names(groups)) for (target in c('minutes','usg','ts','ast')) {
    use <- which(groups[[group]])
    if (!length(use)) next
    actual <- data[[paste0('next_',target)]][use]
    for (method in names(predictions)) {
      error <- predictions[[method]][use,target]-actual
      rows[[length(rows)+1L]] <- data.frame(cohort=group,statistic=target,n=length(use),method=method,
        mae=mean(abs(error)),rmse=sqrt(mean(error^2)),bias=mean(error))
    }
  }
  do.call(rbind,rows)
}

translation_score_table <- function(scores,measure,cohorts=NULL) {
  if (!is.null(cohorts)) scores <- scores[scores$cohort%in%cohorts,]
  result <- unique(scores[c('cohort','statistic','n')])
  for (method in c('no_change','baseline','raw_destination','final','no_destination')) {
    selected <- scores[scores$method==method,]
    result[[method]] <- selected[[measure]][match(paste(result$cohort,result$statistic),paste(selected$cohort,selected$statistic))]
  }
  names(result) <- c('Cohort','Statistic','N','Carry','A','Raw context','Full A+B','No destination')
  result
}

translation_trade_intervals <- function(data,predictions,seed,draws=1000L) {
  set.seed(seed); use <- which(data$verified_trade); rows <- list()
  for (target in c('minutes','usg','ts','ast')) for (reference in c('no_change','raw_destination','no_destination')) {
    actual <- data[[paste0('next_',target)]][use]
    improvement <- abs(predictions[[reference]][use,target]-actual)-abs(predictions$final[use,target]-actual)
    groups <- split(improvement,data$trade_group[use])
    sums <- vapply(groups,sum,numeric(1)); sizes <- lengths(groups)
    boot <- replicate(draws,{
      i <- sample.int(length(groups),length(groups),replace=TRUE)
      sum(sums[i])/sum(sizes[i])
    })
    interval <- stats::quantile(boot,c(.025,.975),names=FALSE)
    rows[[length(rows)+1L]] <- data.frame(Statistic=target,Compared_with=reference,
      MAE_improvement=mean(improvement),Lower=interval[1L],Upper=interval[2L],Trade_groups=length(groups))
  }
  do.call(rbind,rows)
}

translation_checks <- function(inputs,bundle,model,test,predictions) {
  fixture <- data.frame(minutes=rep(24,40),fga=10,fta=4,fgm=8,pts=25,
    tov=2,ast=5,oreb=1,dreb=3,fg3a=4,team_fga=80,team_fta=20,team_tov=12,team_fgm=40,team_elapsed=48)
  expected <- c(minutes=24,usg=100*(10+.44*4+2)*48/(24*(80+.44*20+12)),
    ts=100*25/(2*(10+.44*4)),ast=100*5/(24/48*40-8))
  stopifnot(isTRUE(all.equal(translation_window_stats(fixture)[names(expected)],expected,tolerance=1e-12)))
  fixture$fgm <- 20
  stopifnot(is.na(translation_window_stats(fixture)['ast']))
  template <- inputs$audit[which(inputs$audit$validation_status=='valid')[1L],
    c('trade_date','nba_player_id','from_team_id','to_team_id','team_match_status','source_team_id','trade_group','source_url')]
  ids <- unique(inputs$p$player_id); teams <- unique(inputs$t$team_id)
  duplicate <- validate_translation_trades(rbind(template,template),ids,teams,inputs$data_last)
  stopifnot(duplicate$validation_status[2]=='exact_duplicate')
  invalid <- template; invalid$trade_date <- 'not-a-date'
  stopifnot(validate_translation_trades(invalid,ids,teams,inputs$data_last)$validation_status=='invalid_date')
  invalid <- template; invalid$nba_player_id <- 0
  stopifnot(validate_translation_trades(invalid,ids,teams,inputs$data_last)$validation_status=='non_player_or_missing_id')
  ambiguous <- rbind(template,template)
  ambiguous$trade_group <- c('fixture_one','fixture_two')
  ambiguous$from_team_id <- c(teams[1],teams[2]); ambiguous$to_team_id <- c(teams[2],teams[3])
  ambiguous$source_team_id <- ambiguous$to_team_id
  stopifnot(all(validate_translation_trades(ambiguous,ids,teams,inputs$data_last)$validation_status=='ambiguous_same_day_legs'))
  features <- unique(c(unlist(translation_feature_names()[c('baseline','adjustment','raw_destination','no_destination')]),'transfer'))
  without_outcomes <- predict_player_translation(model,test[,features,drop=FALSE])
  stopifnot(identical(without_outcomes$final,predictions$final),
    identical(predictions$final[!test$transfer,,drop=FALSE],predictions$baseline[!test$transfer,,drop=FALSE]),
    all(is.finite(predictions$final)),all(bundle$observations$feature_max_date<bundle$observations$cutoff),
    model$latest_training_label<min(test$cutoff),model$latest_adjustment_label<min(test$cutoff),
    all(model$crossfit_audit$latest_training_label<model$crossfit_audit$earliest_prediction),
    !any(grepl('^(next_|target_)',model$baseline$minutes$features)),
    all(bundle$observations$target_games==bundle$config$window))
  verified <- bundle$observations[bundle$observations$verified_trade,]
  source <- bundle$trade_audit[verified$record_id,]
  stopifnot(all(source$validation_status=='valid'),all(verified$player_id==source$player_id),
    all(verified$origin_team_id==source$origin),all(verified$destination_team_id==source$destination),
    all(verified$cutoff==source$date))
  sample <- which(test$verified_trade & test$deal_departing_minutes>0)[1L]
  if (is.na(sample)) sample <- which(test$verified_trade)[1L]
  scenario <- bundle$make_scenario(test$player_id[sample],test$destination_team_id[sample],test$cutoff[sample])
  stopifnot(isTRUE(all.equal(unname(predict_player_translation(model,scenario)$final[1,]),unname(predictions$final[sample,]),tolerance=0)))
  engine <- translation_feature_engine(inputs,bundle$config)
  trace <- engine$extract(inputs$players[[as.character(test$player_id[sample])]],test$cutoff[sample],
    test$origin_team_id[sample],test$destination_team_id[sample],test$trade_group[sample])
  stopifnot(!any(trace$departing_ids%in%trace$roster_ids),trace$feature_max_date<test$cutoff[sample])
  trained <- translation_matrix(data.frame(a=c(1,3,NA),b=c(2,2,2)),c('a','b'))
  held <- translation_matrix(data.frame(a=NA_real_,b=1e9),c('a','b'),trained$medians)
  stopifnot(held$x[1,'a']==2)
  c('Window formulas and undefined-rate handling',
    'Non-player assets, duplicate legs, invalid dates and ambiguous same-day transactions are flagged',
    'Origin, destination and transaction order are checked against known pre-trade events and game history',
    'All performance features, including incoming-player roles, precede the cutoff',
    'Known same-package departures are removed; the scenario API reproduces historical features',
    'Full targets have the configured length and do not overlap within a player',
    'Training, validation, yearly residual folds and final tests are chronological with mature labels',
    'Removing future outcomes leaves predictions unchanged; stayers receive zero adjustment',
    'Imputation uses training medians; all test predictions are finite')
}

write_translation_report <- function(results,selected,selection,common_validation,common_test,
                                     intervals,checks,censored_scores,path) {
  chosen <- results[[as.character(selected)]]; bundle <- chosen$bundle; model <- chosen$model
  data <- bundle$observations; test <- chosen$test; predictions <- chosen$predictions
  audit <- bundle$trade_audit; config <- model$config
  counts <- do.call(rbind,lapply(names(model$split_rows),function(name) {
    d <- data[model$split_rows[[name]],]
    data.frame(Split=name,Periods=nrow(d),Trades=sum(d$verified_trade),
      Signings=sum(d$transfer_type=='confirmed_signing'),Other_moves=sum(d$transfer & !d$verified_trade & d$transfer_type!='confirmed_signing'),Stayers=sum(!d$transfer))
  }))
  coverage <- do.call(rbind,lapply(sort(unique(audit$season[!is.na(audit$season)])),function(season) {
    a <- audit[audit$season==season & !is.na(audit$player_id)&audit$player_id>0,]
    row <- data.frame(Season_end=season,Player_records=nrow(a),Valid=sum(a$validation_status=='valid'),Game_matched=sum(a$game_match))
    for (w in names(results)) row[[paste0('Eligible_',w)]] <- sum(results[[w]]$bundle$trade_audit$eligible[a$record_id])
    row
  }))
  window_rows <- common_rows <- list()
  for (w in names(results)) {
    r <- results[[w]]; d <- r$test
    for (target in model$targets) {
      score <- r$scores[r$scores$cohort=='Trades' & r$scores$statistic==target,]
      take <- function(method,metric='mae') score[[metric]][score$method==method]
      window_rows[[length(window_rows)+1L]] <- data.frame(Window=as.integer(w),Statistic=target,
        Trade_N=sum(d$verified_trade),Carry_MAE=take('no_change'),A_MAE=take('baseline'),
        Raw_MAE=take('raw_destination'),Full_MAE=take('final'),No_dest_MAE=take('no_destination'),Full_RMSE=take('final','rmse'))
      use <- which(d$verified_trade & d$record_id%in%common_test)
      actual <- d[[paste0('next_',target)]][use]
      carry <- mean(abs(r$predictions$no_change[use,target]-actual))
      full <- mean(abs(r$predictions$final[use,target]-actual))
      common_rows[[length(common_rows)+1L]] <- data.frame(Window=as.integer(w),Statistic=target,
        N=length(use),Carry_MAE=carry,Full_MAE=full,Relative_MAE=full/carry)
    }
  }
  summary <- do.call(rbind,lapply(names(results),function(w) {
    b <- results[[w]]$bundle; d <- results[[w]]$test
    data.frame(Window=as.integer(w),All_periods=nrow(b$observations),Eligible_trades=sum(b$observations$verified_trade),
      Test_trades=sum(d$verified_trade),Test_players=length(unique(d$player_id[d$verified_trade])),
      Cross_season_targets=sum(d$verified_trade & d$target_start_season!=d$target_end_season),
      Matched_short_followup=sum(b$trade_audit$game_match & b$trade_audit$post_games<as.integer(w),na.rm=TRUE))
  }))
  roles <- list()
  for (target in c('minutes','usg','ast')) for (direction in c('up','down')) {
    change <- test[[paste0('next_',target)]]-test[[paste0('past_',target)]]
    use <- which(test$verified_trade & (if(direction=='up') change>=5 else change<=-5))
    if (!length(use)) next
    projected <- predictions$final[use,target]-test[[paste0('past_',target)]][use]
    roles[[length(roles)+1L]] <- data.frame(Statistic=target,Role_change=direction,N=length(use),
      Actual_delta=mean(change[use]),Predicted_delta=mean(projected),
      Carry_MAE=mean(abs(change[use])),Full_MAE=mean(abs(projected-change[use])),
      Bias=mean(projected-change[use]),Direction_accuracy=mean(sign(projected)==sign(change[use])))
  }
  situations <- list()
  groups <- list(Open_shot_opportunities=test$deal_net_plays_open>=5,
    Crowded_high_usage_roster=test$destination_top_usage>=28,
    Partial_transaction_group=test$deal_partial_group==1)
  for (name in names(groups)) {
    use <- which(test$verified_trade & groups[[name]]); if (!length(use)) next
    row <- data.frame(Situation=name,N=length(use))
    for (target in model$targets) row[[target]] <- sprintf('%.2f / %.2f',
      mean(abs(predictions$no_change[use,target]-test[[paste0('next_',target)]][use])),
      mean(abs(predictions$final[use,target]-test[[paste0('next_',target)]][use])))
    situations[[length(situations)+1L]] <- row
  }
  # Pick familiar, prespecified examples when eligible, then earliest remaining
  # test trades. Selection uses identity and date, never prediction error.
  preferred <- c(203081L,201950L,1627783L,1629029L,202710L,203076L,1626157L,1628969L)
  candidates <- which(test$verified_trade)
  priority <- match(test$player_id[candidates],preferred); priority[is.na(priority)] <- length(preferred)+1L
  ordered <- candidates[order(priority,test$cutoff[candidates],test$player_id[candidates])]
  example_ids <- head(ordered[!duplicated(test$player_id[ordered])],8L)
  examples <- do.call(rbind,lapply(example_ids,function(i) {
    row <- data.frame(Player=test$player_name[i],Date=as.character(test$cutoff[i]),
      Move=paste(test$origin_team[i],'to',test$destination_team[i]),
      Group=audit$trade_group[test$record_id[i]],Target_end=as.character(test$target_end[i]),check.names=FALSE)
    for (target in model$targets) row[[target]] <- sprintf('%.2f / %.2f / %.2f',
      predictions$no_change[i,target],predictions$final[i,target],test[[paste0('next_',target)]][i])
    row
  }))
  verdict <- vapply(model$targets,function(target) {
    s <- chosen$scores[chosen$scores$cohort=='Trades' & chosen$scores$statistic==target,]
    get <- function(method) s$mae[s$method==method]
    sprintf('- %s MAE: carry %.3f, A %.3f, raw context %.3f, full %.3f, no destination %.3f.',
      target,get('no_change'),get('baseline'),get('raw_destination'),get('final'),get('no_destination'))
  },character(1))
  incremental <- vapply(c('raw_destination','no_destination'),function(reference) {
    differences <- vapply(model$targets,function(target) {
      s <- chosen$scores[chosen$scores$cohort=='Trades' & chosen$scores$statistic==target,]
      s$mae[s$method==reference]-s$mae[s$method=='final']
    },numeric(1))
    sprintf('- Against %s: full context has lower MAE on %s targets, higher MAE on %s, and ties on %s.',
      reference,sum(differences>1e-9),sum(differences< -1e-9),sum(abs(differences)<=1e-9))
  },character(1))
  role_findings <- if(length(roles)) vapply(roles,function(row) {
    if(row$Role_change!='up') return('')
    sprintf('- Expanded %s roles: average actual increase %.2f, predicted increase %.2f across %s trades.',
      row$Statistic,row$Actual_delta,row$Predicted_delta,row$N)
  },character(1)) else character()
  role_findings <- role_findings[nzchar(role_findings)]
  match_table <- as.data.frame(table(audit$match_status)); names(match_table) <- c('Match_or_exclusion_status','Rows')
  eligibility <- as.data.frame(table(audit$eligibility_reason[audit$game_match]))
  names(eligibility) <- c('Selected_window_eligibility','Matched_player_trades')
  group_count <- length(unique(audit$group_id))
  partial_group_count <- length(unique(audit$group_id[audit$partial_group]))
  lines <- c('# Player performance translation: Phase 2','',
    '## Main result','',
    sprintf('Validation selected **%s-game windows**. The selected test has **%s genuine player-trade observations**, %s distinct transaction groups and %s players. Units below are minutes or percentage points.',
      selected,sum(test$verified_trade),length(unique(test$trade_group[test$verified_trade])),length(unique(test$player_id[test$verified_trade]))),'',verdict,'',
    incremental,'',
    'Carry-forward gains do not by themselves establish added value from the destination features. Read the raw-context and player-only comparisons together with the paired intervals. In particular, systematic underprediction of expanded roles is a remaining integration risk.','',
    'This is a predictive, conditional-on-playing backtest. Whether it improves enough for trade-model integration must be judged from the actual-trade errors and paired comparisons, not the larger stayer cohort. No model, weight or window is selected from test errors.','',
    '## Run and files','',
    'Install `data.table`, `glmnet`, and `jsonlite`, then run from the project root:','',
    '```sh','Rscript "player performance translation/player_translation_evaluation.R"','```','',
    'In RStudio, source the evaluation file and call `result <- run_player_translation()`. There are exactly three R scripts. Only the existing `player_translation_model.rds` and this report are generated; all observations, predictions, censoring diagnostics and other-window fits remain in memory.',
    sprintf('Trade input: `%s`. Its actual dates, rather than its filename, determine coverage. The optional supplied movement JSON supplies dated signing records; a signing is not automatically certified as unrestricted free agency.',basename(bundle$trade_path)),'',
    'For a proposal, construct `newdata <- result$selected$bundle$make_scenario(player_id, destination_team_id, cutoff, departing_ids=..., arriving_ids=...)`, then use `predict_player_translation(result$model, newdata)`. Historical packages are found automatically. Manually specified participants are assumptions about a proposed deal, not invented training outcomes. The saved model must predate the requested cutoff.','',
    '## Transaction validation and coverage','',
    sprintf('Source: %s rows; %s player rows involving %s players; %s non-player/missing-ID rows excluded. %s player rows pass identity, direction, duplicate and date/group checks. There are %s groups; %s have incomplete/uncertain package coverage.',
      nrow(audit),sum(is.finite(audit$player_id)&audit$player_id>0),length(unique(audit$player_id[is.finite(audit$player_id)&audit$player_id>0])),
      sum(audit$validation_status=='non_player_or_missing_id'),sum(audit$validation_status=='valid'),group_count,partial_group_count),
    sprintf('Game data ends %s. The feed starts %s and ends %s. Records after the game snapshot cannot yet provide post-trade labels.',bundle$data_last,min(audit$date,na.rm=TRUE),max(audit$date,na.rm=TRUE)),
    'Matching requires the NBA player ID, confirmed current origin at the trade date, destination appearances, and a consistent chronology. A known earlier trade can explain an intermediate team with no appearances. The final leg is predicted at its own date; its eventual destination is never projected backward to the first leg. Same-day multi-leg ordering is not guessed. Partial groups retain flags and only known participants are used.','',
    translation_markdown_table(match_table),'',
    'Coverage by NBA season ending year (July-June transaction convention). Later-season records outside the game snapshot remain visible:','',
    translation_markdown_table(coverage),'',
    'For the selected window, matched trade records are retained or excluded as follows:','',
    translation_markdown_table(eligibility),'',
    '## Windows, censoring and chronology','',
    'Each window uses W previous positive-minute appearances and the next W appearances with the destination. Histories may include an earlier team, with current-team share and team-count features. This avoids discarding rapid transfers solely for lacking W games with the last franchise. Actual trade dates, signing dates, or conservative last-old-game-day cutoffs are used; unknown changes remain unclassified.',
    'Targets cannot cross another known player trade or a different-team appearance. Stayer blocks have stride W, and blocks overlapping a transfer target are removed. Targets may cross offseasons; feature dates stay before the cutoff. Incomplete targets are not padded or treated as complete outcomes.','',
    translation_markdown_table(summary),'',
    sprintf('Train labels mature before %s. Validation cutoffs are on/after that date and all validation labels mature before %s. Final test cutoffs are on/after %s. Every model refits only pre-test labels; residual folds have their own earlier chronological tuning splits.',config$validation_start,config$test_start,config$test_start),'',
    translation_markdown_table(counts),'',
    sprintf('Window selection minimizes mean validation MAE divided by carry-forward MAE across the four targets on the same %s eligible validation trades. These are development scores, not test scores. Common-cohort selection still conditions on the longest window being observed.',length(common_validation)),'',
    translation_markdown_table(selection),'',
    'Shorter and longer targets are different forecasting questions and have different averaging noise. Neither raw MAE nor sample count alone identifies a universally best horizon. The tables below show both each window\'s own sample and a common test-trade cohort.','',
    '## Models and destination features','',
    'A is four interpretable ridge regressions trained on all eligible periods. B learns genuine out-of-time baseline errors among observed movers, with trade weights 1/2/4. B lambda, weight and scale 0/0.5/1 are tuned on actual validation trades. All preprocessing is fitted on the fitting rows. Zero adjustment remains a valid choice.',
    'Full B reconstructs the destination rotation from recent games and prior dated movements, removes same-package departures, and adds other arrivals using their pre-cutoff role estimates. It includes vacated minutes, shot/usage load, assists, height-band competition, remaining high-usage players, focal responsibility gaps and three simple opportunity interactions. No incoming player\'s post-trade statistics are used.',
    'Raw context is a separately tuned B using unadjusted historical destination context, without package features. No destination is a separately tuned player-only B. Both share A, samples, splits and tuning rules. Their paired comparison isolates the added destination information better than comparing Phase 1\'s seven curated trades with this larger cohort.',
    'Trade participants on the cutoff date are known conditions of the proposed/announced deal. This is not a forecast of which transaction will occur. Other same-day packages are not silently pooled. Height bands are proxies because position is empty in the source. Carried role estimates need not sum to a feasible 240-minute allocation.','',
    translation_markdown_table(model$tuning),'',
    '## Held-out performance','',
    '### Each window: genuine trades','',translation_markdown_table(do.call(rbind,window_rows)),'',
    sprintf('### Common test cohort (%s trades)',length(common_test)),'',
    translation_markdown_table(do.call(rbind,common_rows)),'',
    '### Selected model: MAE','',translation_markdown_table(translation_score_table(chosen$scores,'mae')),'',
    '### Selected model: RMSE','',translation_markdown_table(translation_score_table(chosen$scores,'rmse')),'',
    '### Does better destination context help?','',
    'Positive paired improvement favors Full A+B. Intervals use 1,000 bootstrap draws clustered by transaction group. Repeated-player dependence across separate transactions and unobserved team shocks are not fully covered; these are descriptive intervals, not causal confidence statements.','',
    translation_markdown_table(intervals),'',
    '## Expanded and reduced roles','',
    'Groups use realized changes of at least 5 minutes or percentage points strictly for diagnosis. Realized roles never become training features. Direction accuracy is the fraction whose predicted direction matches the actual direction.','',
    if(length(roles)) translation_markdown_table(do.call(rbind,roles)) else 'No roles met the diagnostic thresholds.','',
    role_findings,'',
    'Compare these increases with the direction accuracies: getting the sign right can still substantially miss the size of a new role. The role groups are retrospective diagnostics and are not used to refit or select models.','',
    'Pre-trade situations; cells are carry / full-model MAE:','',
    if(length(situations)) translation_markdown_table(do.call(rbind,situations)) else 'No qualifying situations.','',
    '### Short-follow-up sensitivity','',
    'These excluded trades have at least five observed destination appearances but fewer than W before another trade, team change or the data end. They never train or tune the model. Their available-period errors are a diagnostic of selection sensitivity, not accuracy on an unobserved full W-game target. Absences, waived players and zero-appearance outcomes are not invented.','',
    if(!is.null(censored_scores)) translation_markdown_table(censored_scores) else 'No held-out short-follow-up trades with defined rates.','',
    '## Documented historical examples','',
    'Each cell is **carry / full prediction / actual**. Examples are selected by prespecified player identities and chronology, never by whether the model succeeded. The group IDs and dates identify records in the supplied NBA transaction CSV/JSON; not all observed movers are called trades.','',
    translation_markdown_table(examples),'',
    '## Limits and next steps','',
    '- Completing W played appearances is still survivorship conditioning. The window comparison, full-feed exclusion counts and short-follow-up diagnostics expose this; they do not solve it. A complete roster/availability panel is needed for unconditional W-team-game forecasts.',
    '- The transaction feed is not independently proven exhaustive, particularly before July 2015, and the game snapshot ends before the feed. Same-day ambiguous legs, unmatched origins and incomplete packages stay flagged instead of being repaired using future outcomes. Signing-related moves are distinguished, but remaining unknown moves may include free agency or waivers.',
    '- Roster reconstruction lacks a complete dated contract, waiver, injury and confirmed-position history. Old rotation estimates and carried incoming roles can be stale, and shared minutes/usage must be reallocated in reality. Team pace and efficiency remain historical; no future team rating is assumed.',
    '- USG% and AST% are aggregate box-score estimates, not exact on-court possession/assist measures. Minutes are per played appearance and can include overtime. Hypothetical B corrections are predictive associations, not identified causal trade effects.',
    '- Phase 1 already examined some games used here. The later Phase 2 chronological holdout is kept out of this phase\'s tuning, but it is not a never-before-seen external data release. Freeze this specification for a genuinely future-season test before deployment.',
    '- Do not select another window or retune from the reported test table. Next steps are broader dated roster/injury coverage, prospective availability targets and a frozen forward test. Keep the ridge benchmark while testing whether role-opportunity features add stable value.','',
    '## Validation checks','',paste0('- PASS: ',checks),'',
    'Source and method references: [NBA player-movement feed](https://stats.nba.com/js/data/playermovement/NBA_Player_Movement.json), [box-score formulas](https://sportsdata.io/help/basketball-formula-reference-guide), [glmnet](https://glmnet.stanford.edu/articles/glmnet.html).'
  )
  writeLines(lines,path,useBytes=TRUE)
}

run_player_translation <- function(config=translation_config(),inputs=NULL) {
  if (!identical(sort(as.integer(config$windows)),c(15L,20L,30L,40L)))
    message('Using custom window experiments: ',paste(config$windows,collapse=', '))
  if (is.null(inputs)) inputs <- prepare_translation_inputs(config)
  results <- list()
  for (window in config$windows) {
    message('Building and fitting window ',window)
    settings <- config; settings$window <- as.integer(window)
    bundle <- build_translation_data(settings,inputs=inputs)
    message(nrow(bundle$observations),' periods; ',sum(bundle$observations$verified_trade),' eligible actual trades')
    model <- fit_player_translation(bundle)
    results[[as.character(window)]] <- list(bundle=bundle,model=model)
  }
  # Freeze window selection before calculating ANY Phase 2 test errors.
  common_validation <- Reduce(intersect,lapply(results,function(r) r$model$validation_trade_ids))
  if (length(common_validation)<10L) stop('Too few common validation trades to choose a window reliably.')
  selection <- do.call(rbind,lapply(names(results),function(w) {
    m <- results[[w]]$model; use <- match(common_validation,m$validation_trade_ids)
    actual <- m$validation_actual[use,,drop=FALSE]
    carry_error <- colMeans(abs(m$validation_predictions$no_change[use,,drop=FALSE]-actual))
    full_error <- colMeans(abs(m$validation_predictions$adjustment[use,,drop=FALSE]-actual))
    data.frame(Window=as.integer(w),Validation_trades=length(m$validation_trade_ids),
      Common_validation_trades=length(use),Mean_relative_MAE=mean(full_error/pmax(carry_error,1e-8)))
  }))
  selected <- selection$Window[which.min(selection$Mean_relative_MAE)]
  message('Window frozen from validation: ',selected)
  for (w in names(results)) {
    r <- results[[w]]
    r$test <- r$bundle$observations[r$model$split_rows$test,]
    stopifnot(r$model$latest_training_label<min(r$test$cutoff),
              r$model$latest_adjustment_label<min(r$test$cutoff))
    r$predictions <- translation_predictions(r$model,r$test)
    r$scores <- translation_metrics(r$test,r$predictions)
    results[[w]] <- r
  }
  common_test <- Reduce(intersect,lapply(results,function(r) r$test$record_id[r$test$verified_trade]))
  if (length(common_test)<10L) stop('Too few common test trades for the window comparison.')
  chosen <- results[[as.character(selected)]]
  intervals <- translation_trade_intervals(chosen$test,chosen$predictions,config$seed)
  checks <- translation_checks(inputs,chosen$bundle,chosen$model,chosen$test,chosen$predictions)
  short <- chosen$bundle$censored
  short <- short[short$cutoff>=config$test_start & short$verified_trade,,drop=FALSE]
  censored_scores <- NULL
  if (nrow(short)) {
    prediction <- translation_predictions(chosen$model,short)
    censored_scores <- do.call(rbind,lapply(chosen$model$targets,function(target) {
      actual <- short[[paste0('next_',target)]]
      data.frame(Statistic=target,N=nrow(short),Median_followup=median(short$target_games),
        Carry_MAE=mean(abs(prediction$no_change[,target]-actual)),
        Full_MAE=mean(abs(prediction$final[,target]-actual)))
    }))
  }
  # Intermediate validation targets and predictions must not enter the artifact.
  selected_model <- chosen$model
  selected_model$validation_predictions <- selected_model$validation_actual <- selected_model$validation_trade_ids <- NULL
  selected_model$window_selection <- list(criterion='common-trade validation relative MAE',
    common_trades=length(common_validation),scores=selection)
  artifact <- file.path(TRANSLATION_DIR,'player_translation_model.rds')
  saveRDS(selected_model,artifact,compress='xz')
  reloaded <- readRDS(artifact)
  stopifnot(identical(predict_player_translation(reloaded,chosen$test)$final,chosen$predictions$final))
  checks <- c(checks,'Window selected only on validation; saved artifact excludes intermediate predictions and reloads identically')
  results[[as.character(selected)]]$model <- selected_model
  write_translation_report(results,selected,selection,common_validation,common_test,intervals,checks,
    censored_scores,file.path(TRANSLATION_DIR,'evaluation_report.md'))
  print(selection,row.names=FALSE)
  print(translation_score_table(chosen$scores,'mae','Trades'),row.names=FALSE)
  message('Saved Phase 2 model and report; no intermediate outputs.')
  invisible(list(model=selected_model,selected=results[[as.character(selected)]],windows=results,
                 selection=selection,intervals=intervals,short_followup=censored_scores))
}

if (sys.nframe()==0L) run_player_translation()
