# Phase 1 uses the existing CSVs; it does not rerun data collection.
# Install data.table and glmnet before running the evaluation script.
# A window is 40 positive-minute regular-season appearances, not 40 team games.
# All percentages below are in percentage points, on a 0-100 scale.

.translation_sources <- Filter(Negate(is.null), lapply(sys.frames(), function(f) f$ofile))
.translation_args <- grep('^--file=', commandArgs(FALSE), value=TRUE)
TRANSLATION_DIR <- if (length(.translation_sources)) {
  dirname(normalizePath(tail(.translation_sources, 1L)[[1L]]))
} else if (length(.translation_args)) {
  dirname(normalizePath(sub('^--file=', '', .translation_args[1L])))
} else if (file.exists('player_translation_data.R')) {
  normalizePath('.')
} else {
  normalizePath('player performance translation')
}

translation_config <- function() list(
  window=40L, stride=40L, team_window=40L, min_team_games=20L,
  validation_start=as.Date('2018-07-01'), test_start=as.Date('2021-07-01'),
  first_crossfit_year=2013L, lambda_grid=c(0.01, 0.1, 1, 10, 100),
  trade_weights=c(1, 2), adjustment_scales=c(0, 0.5, 1), seed=6404L
)

# This is a small, explicitly sourced trade registry, not a transaction database.
# Unknown moves are NEVER labelled trades or free-agent signings from timing alone.
# Dates are start-of-day cutoffs: games on the transaction date are excluded.
verified_translation_trades <- function() {
  registry <- data.frame(
    player_id=c(101108L, 201935L, 201567L, 200765L, 202710L, 202331L,
                201942L, 202695L, 202696L, 1630169L, 1627734L,
                203468L, 201935L, 202681L, 201142L, 1627783L),
    destination=c('LAC','HOU','CLE','DAL','MIN','OKC','SAS','TOR',
                  'CHI','IND','SAC','NOP','PHI','DAL','PHX','IND'),
    date=as.Date(c('2011-12-14','2012-10-27','2014-08-23','2014-12-18',
                   '2017-06-22','2017-07-06','2018-07-18','2018-07-18',
                   '2021-03-25','2022-02-08','2022-02-08',
                   '2022-02-08','2022-02-10','2023-02-05','2023-02-09',
                   '2024-01-17')),
    source=c(
      'https://www.nba.com/pelicans/news/hornets_clippers_trade_2011_12_14.html',
      'https://www.nba.com/rockets/news/blockbuster-deal-brings-james-harden-houston',
      'https://www.nba.com/cavaliers/news/features/kevin-love-trade-140823',
      'https://www.nba.com/mavs/mavs-acquire-four-time-all-star-rajon-rondo',
      'https://www.nba.com/timberwolves/trading-butler-wolves-win-2017-nba-draft-and-hopefully-more',
      'https://www.nba.com/news/paul-george-traded-oklahoma-city-thunder-official-release',
      rep('https://api-hub.nba.com/news/report-san-antonio-spurs-toronto-raptors-engaged-serious-talks-kawhi-leonard', 2),
      'https://www.nba.com/bulls/news/bulls-acquire-all-star-nikola-vucevic-and-al-farouq-aminu-trade-magic',
      rep('https://www.nba.com/news/pacers-agree-to-trade-domantas-sabonis-to-kings', 2),
      'https://www.nba.com/news/blazers-pelicans-cj-mccollum-trade',
      'https://www.nba.com/news/2021-22-nba-trade-tracker',
      'https://www.nba.com/news/nets-kyrie-irving-trade-dallas-mavericks',
      'https://www.nba.com/news/suns-nets-kevin-durant-trade',
      'https://www.nba.com/pacers/news/pacers-secure-another-star-in-siakam'
    ), stringsAsFactors=FALSE
  )
  registry
}

translation_ratio <- function(numerator, denominator) {
  ifelse(is.finite(denominator) & denominator > 0, numerator / denominator, NA_real_)
}

# USG and AST are box-score estimates. Exact on-court team possessions/FGM
# would require play-by-play or lineup data which this project does not contain.
# Formula reference: https://sportsdata.io/help/basketball-formula-reference-guide
translation_window_stats <- function(d) {
  minutes <- sum(d$minutes)
  fga <- sum(d$fga); fta <- sum(d$fta); fgm <- sum(d$fgm)
  plays <- fga + 0.44 * fta + sum(d$tov)
  team_plays <- sum(d$team_fga + 0.44 * d$team_fta + d$team_tov)
  elapsed <- sum(d$team_elapsed)
  c(minutes=minutes/nrow(d),
    usg=100 * translation_ratio(plays * elapsed, minutes * team_plays),
    ts=100 * translation_ratio(sum(d$pts), 2 * (fga + 0.44 * fta)),
    ast=100 * translation_ratio(sum(d$ast), minutes/elapsed * sum(d$team_fgm) - fgm),
    pts_per36=36 * translation_ratio(sum(d$pts), minutes),
    reb_per36=36 * translation_ratio(sum(d$oreb + d$dreb), minutes),
    tov_per36=36 * translation_ratio(sum(d$tov), minutes),
    three_share=translation_ratio(sum(d$fg3a), fga),
    free_throw_rate=translation_ratio(fta, fga))
}

translation_feature_names <- function() {
  stats <- c('minutes','usg','ts','ast','pts_per36','reb_per36','tov_per36',
             'three_share','free_throw_rate')
  player <- c(paste0('past_', stats), paste0('trend_', c('minutes','usg','ts','ast')),
              'age','height','history_games','days_since_appearance','prior_bpm')
  context <- c('pace','ortg','drtg','ts','assist_rate','win_rate',
               'top_usage','high_usage_minutes_share','same_size_minutes_share',
               'available_minutes','available_plays','history_games','days_since_game')
  list(player=player, context=context,
       baseline=c(player, paste0('current_', context)),
       adjustment=c(player, paste0('delta_', context), paste0('destination_', context)),
       no_destination=player)
}

# The context uses team games strictly before the cutoff, and roster activity
# visible in those games only. It is a rotation proxy, not an actual depth chart.
# Removing the focal player's production avoids counting them as their own rival.
translation_team_context <- function(snapshot, player_id, height) {
  d <- snapshot$games
  roster <- snapshot$roster[snapshot$roster$player_id != player_id, ]
  size_band <- function(x) ifelse(x <= 77, 1L, ifelse(x <= 81, 2L, 3L))
  same_size <- !is.na(roster$height) & is.finite(height) &
    size_band(roster$height) == size_band(height)
  team_minutes <- sum(d$game_elapsed_minutes) * 5
  team_plays <- sum(d$fga + 0.44 * d$fta + d$tov)
  c(pace=48 * translation_ratio(sum(d$possessions_est), sum(d$game_elapsed_minutes)),
    ortg=100 * translation_ratio(sum(d$pts), sum(d$possessions_est)),
    drtg=100 * translation_ratio(sum(d$opp_pts), sum(d$possessions_est)),
    ts=100 * translation_ratio(sum(d$pts), 2 * sum(d$fga + 0.44*d$fta)),
    assist_rate=100 * translation_ratio(sum(d$ast), sum(d$fgm)),
    win_rate=mean(d$win),
    top_usage=if (nrow(roster)) max(roster$usg, na.rm=TRUE) else NA_real_,
    high_usage_minutes_share=translation_ratio(sum(roster$minutes[which(roster$usg >= 25)]), team_minutes),
    same_size_minutes_share=translation_ratio(sum(roster$minutes[which(same_size)]), team_minutes),
    available_minutes=translation_ratio(team_minutes - sum(roster$minutes), nrow(d)),
    available_plays=1 - translation_ratio(sum(roster$plays), team_plays),
    history_games=nrow(d), days_since_game=as.numeric(snapshot$cutoff - max(d$game_date)))
}

build_translation_data <- function(config=translation_config(), data_dir=NULL) {
  if (!requireNamespace('data.table', quietly=TRUE)) stop('Install data.table first.')
  previous_threads <- data.table::setDTthreads(1L)
  on.exit(data.table::setDTthreads(previous_threads), add=TRUE)
  if (config$window < 2 || config$stride < config$window ||
      config$min_team_games > config$team_window) stop('Invalid window settings.')
  if (is.null(data_dir)) data_dir <- file.path(dirname(TRANSLATION_DIR), 'data collection', 'datasets')
  player_fields <- c('player_id','team_id','game_id','season','team_abbreviation',
                     'game_date','minutes','pts','fgm','fga','fg3a','fta','ast','tov',
                     'oreb','dreb','age','height_inches','prior_bref_bpm')
  p <- data.table::fread(file.path(data_dir, 'nba_player_games_2010_2026.csv'),
                        select=player_fields, colClasses=c(game_id='character'))
  t <- data.table::fread(file.path(data_dir, 'nba_team_games_2010_2026.csv'),
                        colClasses=c(game_id='character'))
  profiles <- data.table::fread(file.path(data_dir, 'nba_player_team_seasons_2010_2026.csv'),
                               select=c('player_id','player_name'))
  p[, game_date := as.Date(game_date)]; t[, game_date := as.Date(game_date)]
  p <- p[is.finite(minutes) & minutes > 0]
  if (anyDuplicated(p[, .(player_id, game_id)]) || anyDuplicated(t[, .(team_id, game_id)]))
    stop('Game keys are not unique.')
  index <- match(paste(p$team_id, p$game_id), paste(t$team_id, t$game_id))
  if (anyNA(index)) stop('Player games missing team context.')
  p[, `:=`(team_fga=t$fga[index], team_fta=t$fta[index], team_tov=t$tov[index],
            team_fgm=t$fgm[index], team_elapsed=t$game_elapsed_minutes[index])]
  data.table::setorder(p, player_id, game_date, game_id)
  p[, episode := data.table::rleid(team_id), by=player_id]
  data.table::setorder(t, team_id, game_date, game_id)
  player_rows <- split(as.data.frame(p), p$player_id)
  team_rows <- split(as.data.frame(t), t$team_id)
  team_player_rows <- split(p, p$team_id)
  registry <- verified_translation_trades()
  context_cache <- new.env(parent=emptyenv())
  get_snapshot <- function(team, cutoff) {
    key <- paste(team, cutoff)
    if (exists(key, context_cache, inherits=FALSE)) return(context_cache[[key]])
    games <- team_rows[[as.character(team)]]
    end <- findInterval(as.numeric(cutoff)-1, as.numeric(games$game_date))
    if (end < config$min_team_games) return(NULL)
    games <- games[seq.int(max(1L, end-config$team_window+1L), end), ]
    appearances <- team_player_rows[[as.character(team)]]
    recent <- appearances[game_id %in% games$game_id]
    active_ids <- unique(recent[game_id %in% tail(games$game_id, 10L), player_id])
    roster <- recent[player_id %in% active_ids,
      .(minutes=sum(minutes), plays=sum(fga + 0.44*fta + tov),
        usg=100 * translation_ratio(sum(fga + .44*fta + tov)*sum(team_elapsed),
                                    sum(minutes)*sum(team_fga + .44*team_fta + team_tov)),
        height=tail(height_inches, 1L)), by=player_id]
    answer <- list(games=games, roster=as.data.frame(roster), cutoff=cutoff)
    context_cache[[key]] <- answer
    answer
  }
  features_at <- function(player, history_end, origin, destination, cutoff) {
    previous <- player[seq.int(history_end-config$window+1L, history_end), ]
    current_snapshot <- get_snapshot(origin, cutoff)
    destination_snapshot <- if (origin==destination) current_snapshot else get_snapshot(destination,cutoff)
    if (is.null(current_snapshot) || is.null(destination_snapshot)) return(NULL)
    targets <- c('minutes','usg','ts','ast')
    past <- translation_window_stats(previous)
    older <- if (history_end >= config$window*2L)
      translation_window_stats(player[seq.int(history_end-2L*config$window+1L,history_end-config$window),])[targets]
      else setNames(rep(NA_real_,4L),targets)
    last <- previous[nrow(previous),]
    current <- translation_team_context(current_snapshot,last$player_id,last$height_inches)
    dest <- translation_team_context(destination_snapshot,last$player_id,last$height_inches)
    features <- c(setNames(past,paste0('past_',names(past))),
      setNames(past[targets]-older,paste0('trend_',targets)),
      age=last$age,height=last$height_inches,history_games=history_end,
      days_since_appearance=as.numeric(cutoff-last$game_date),prior_bpm=last$prior_bref_bpm,
      setNames(current,paste0('current_',names(current))),
      setNames(dest,paste0('destination_',names(dest))),
      setNames(dest-current,paste0('delta_',names(dest))))
    list(features=features,last=last,
      feature_max_date=max(previous$game_date,current_snapshot$games$game_date,destination_snapshot$games$game_date))
  }
  # This entry point constructs a hypothetical destination scenario without
  # looking for future appearances or requiring future outcomes to exist.
  make_scenario <- function(player_id,destination_team_id,cutoff) {
    cutoff <- as.Date(cutoff)
    player <- player_rows[[as.character(player_id)]]
    if (is.null(player) || is.null(team_rows[[as.character(destination_team_id)]]))
      stop('Unknown player or destination team ID.')
    history_end <- findInterval(as.numeric(cutoff)-1,as.numeric(player$game_date))
    if (history_end < config$window) stop('Not enough pre-cutoff player appearances.')
    origin <- player$team_id[history_end]
    if (any(tail(player$team_id[seq_len(history_end)],config$window) != origin))
      stop('The full prior window must be with the current team.')
    extracted <- features_at(player,history_end,origin,destination_team_id,cutoff)
    if (is.null(extracted)) stop('Not enough pre-cutoff team history.')
    if (any(!is.finite(extracted$features[paste0('past_',c('minutes','usg','ts','ast'))])))
      stop('Prior-window rates are undefined.')
    stopifnot(extracted$feature_max_date < cutoff)
    cbind(data.frame(player_id=player_id,cutoff=cutoff,feature_max_date=extracted$feature_max_date,
      transfer=origin!=destination_team_id),as.data.frame(as.list(extracted$features)))
  }
  observations <- list(); n <- 0L
  reasons <- c(insufficient_player_history=0L, incomplete_target=0L,
               insufficient_team_history=0L, undefined_target_or_history=0L)
  moves <- list(); move_n <- 0L
  targets <- c('minutes','usg','ts','ast')
  for (player in player_rows) {
    episodes <- split(seq_len(nrow(player)), player$episode)
    for (episode in episodes) {
      first <- episode[1L]
      is_move <- first > 1L
      # A transfer is evaluated once, at the start of its destination episode.
      # Stayer targets are nonoverlapping blocks within an uninterrupted episode.
      anchors <- if (length(episode) >= config$window*2L)
        seq.int(first + config$window, tail(episode,1L)-config$window+1L, by=config$stride) else integer()
      if (is_move) anchors <- c(first, anchors)
      matched <- registry[registry$player_id == player$player_id[1L] &
        registry$destination == player$team_abbreviation[first] &
        registry$date >= player$game_date[max(1L,first-1L)] &
        registry$date <= player$game_date[first], ]
      verified <- is_move && nrow(matched) == 1L
      if (is_move) {
        move_n <- move_n + 1L
        moves[[move_n]] <- data.frame(player_id=player$player_id[first], episode=player$episode[first],
          first_game=player$game_date[first], verified_trade=verified, eligible=FALSE)
      }
      for (anchor in anchors) {
        transfer <- is_move && anchor == first
        cutoff <- if (!transfer) player$game_date[anchor] else if (verified)
          matched$date[1L] else player$game_date[first-1L]
        history_end <- findInterval(as.numeric(cutoff)-1, as.numeric(player$game_date))
        origin <- if (transfer) player$team_id[first-1L] else player$team_id[anchor]
        destination <- player$team_id[anchor]
        if (history_end < config$window) {
          reasons['insufficient_player_history'] <- reasons['insufficient_player_history']+1L; next
        }
        previous <- player[seq.int(history_end-config$window+1L, history_end), ]
        if (any(previous$team_id != origin)) {
          reasons['insufficient_player_history'] <- reasons['insufficient_player_history']+1L; next
        }
        end <- anchor + config$window - 1L
        if (end > tail(episode,1L)) {
          reasons['incomplete_target'] <- reasons['incomplete_target']+1L; next
        }
        future <- player[seq.int(anchor, end), ]
        extracted <- features_at(player,history_end,origin,destination,cutoff)
        if (is.null(extracted)) {
          reasons['insufficient_team_history'] <- reasons['insufficient_team_history']+1L; next
        }
        outcome <- translation_window_stats(future)[targets]
        if (any(!is.finite(c(extracted$features[paste0('past_',targets)],outcome)))) {
          reasons['undefined_target_or_history'] <- reasons['undefined_target_or_history']+1L; next
        }
        last <- extracted$last
        n <- n+1L
        metadata <- data.frame(player_id=last$player_id, episode=player$episode[anchor],
          cutoff=cutoff, feature_max_date=extracted$feature_max_date,
          target_start=min(future$game_date), target_end=max(future$game_date),
          origin_team_id=origin, destination_team_id=destination,
          origin_team=last$team_abbreviation, destination_team=player$team_abbreviation[anchor],
          transfer=transfer, verified_trade=transfer && verified,
          transaction_source=if (transfer && verified) matched$source[1L] else '',
          stringsAsFactors=FALSE)
        observations[[n]] <- cbind(metadata, as.data.frame(as.list(extracted$features)),
                                  as.data.frame(as.list(setNames(outcome, paste0('next_', targets)))))
        if (transfer) moves[[move_n]]$eligible <- TRUE
      }
    }
  }
  result <- as.data.frame(data.table::rbindlist(observations))
  if (!nrow(result)) stop('No eligible player periods.')
  names_by_id <- unique(as.data.frame(profiles)[!duplicated(profiles$player_id), ])
  result$player_name <- names_by_id$player_name[match(result$player_id, names_by_id$player_id)]
  result$player_name[is.na(result$player_name)] <- as.character(result$player_id[is.na(result$player_name)])
  result <- result[order(result$cutoff, result$player_id, result$target_start), ]
  rownames(result) <- NULL
  result$observation_id <- seq_len(nrow(result))
  stopifnot(all(result$feature_max_date < result$cutoff),
            all(result$cutoff <= result$target_start),
            all(result$target_end >= result$target_start),
            !anyDuplicated(result[c('player_id','target_start')]))
  list(observations=result, movements=as.data.frame(data.table::rbindlist(moves)),
       excluded=reasons, registry=registry, config=config, make_scenario=make_scenario,
       input_files=setNames(unname(tools::md5sum(file.path(data_dir, c(
         'nba_player_games_2010_2026.csv','nba_team_games_2010_2026.csv',
         'nba_player_team_seasons_2010_2026.csv')))), c('player_games','team_games','profiles')))
}
