# Shared preprocessing reads existing game and transaction files.
# Percentages are percentage points. Windows count positive-minute appearances.
# Only the evaluation entry point writes the final model and Markdown report.

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
  window=40L, windows=c(15L,20L,30L,40L), team_window=40L, min_team_games=20L,
  validation_start=as.Date('2020-07-01'), test_start=as.Date('2023-07-01'),
  first_crossfit_year=2013L, lambda_grid=c(.001,.01,.1,1,10,100),
  trade_weights=c(1,2,4), adjustment_scales=c(0,.5,1), seed=6404L
)

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
    tov_per36=36 * translation_ratio(sum(d$tov), minutes),ast_per_game=mean(d$ast),
    three_share=translation_ratio(sum(d$fg3a), fga),
    free_throw_rate=translation_ratio(fta, fga))
}

translation_feature_names <- function() {
  player <- c(paste0('past_',c('minutes','usg','ts','ast','pts_per36','reb_per36',
    'tov_per36','ast_per_game','three_share','free_throw_rate')),paste0('trend_',c('minutes','usg','ts','ast')),
    'age','height','history_games','days_since_appearance','prior_bpm',
    'history_current_team_share','history_team_count')
  context <- c('pace','ortg','drtg','ts','assist_rate','win_rate','top_usage',
    'high_usage_minutes_share','same_size_minutes_share','available_minutes',
    'available_plays','top_assists','history_games','days_since_game')
  deal <- c('departing_minutes','arriving_minutes','net_minutes_open','net_plays_open',
    'net_assists_open','net_same_size_minutes','departing_high_usage','arriving_high_usage',
    'unknown_arrivals','partial_group','usage_gap','creation_gap',
    'usage_opportunity_interaction','minutes_opportunity_interaction','assist_opportunity_interaction')
  role <- c('known_team_change','minutes_room_gap','shots_room_gap','positive_minutes',
    'negative_minutes','positive_shots','negative_shots','positive_assists','negative_assists',
    'positive_position_minutes','negative_position_minutes','high_usage_competitors',
    'established_creators','usage_load_above_player','assist_load_above_player')
  list(player=player,context=context,
    baseline=c(player,paste0('current_',context)),
    adjustment=c(player,paste0('destination_',context),paste0('delta_',context),paste0('deal_',deal)),
    raw_destination=c(player,paste0('raw_destination_',context),paste0('raw_delta_',context)),
    no_destination=player,
    role_simple=c(paste0('past_',c('minutes','usg','ast')),paste0('trend_',c('minutes','usg','ast')),
      'age','height','prior_bpm','role_known_team_change'),
    role_opportunity=unique(c(player,paste0('current_',context),paste0('destination_',context),
      paste0('delta_',context),paste0('deal_',deal),paste0('role_',role))),
    downstream_role=paste0('predicted_role_change_',c('minutes','usg','ast')))
}

# Outcome classes are labels, never predictors. A three-point/minute boundary
# defines direction; the evaluations separately examine larger five-unit moves.
role_change_class <- function(change,threshold=3) {
  factor(ifelse(change>=threshold,'increase',ifelse(change<= -threshold,'decrease','stable')),
         levels=c('decrease','stable','increase'))
}

# Downstream callers must supply out-of-time predictions for fitting rows.
# This helper only appends predictions; it never substitutes actual role labels.
attach_role_predictions <- function(data,delta) {
  targets <- c('minutes','usg','ast')
  if (!is.matrix(delta)||nrow(delta)!=nrow(data)||!all(targets%in%colnames(delta)))
    stop('Supply an aligned matrix of predicted role changes.')
  for (target in targets) data[[paste0('predicted_role_change_',target)]] <- delta[,target]
  data
}

# Validate identity and grouping before looking at outcomes. Same-day multi-leg
# records are flagged, not ordered using the player's eventual destination.
validate_translation_trades <- function(raw, player_ids, team_ids, last_date) {
  required <- c('trade_date','nba_player_id','from_team_id','to_team_id',
                'team_match_status','source_team_id','trade_group','source_url')
  if (!all(required %in% names(raw))) stop('Trade CSV is missing required fields.')
  d <- as.data.frame(raw)
  d$record_id <- seq_len(nrow(d))
  d$player_id <- suppressWarnings(as.numeric(d$nba_player_id))
  d$origin <- suppressWarnings(as.numeric(d$from_team_id))
  d$destination <- suppressWarnings(as.numeric(d$to_team_id))
  d$date <- as.Date(substr(as.character(d$trade_date),1,10),format='%Y-%m-%d')
  d$season <- as.integer(format(d$date,'%Y'))+as.integer(format(d$date,'%m')>='07')
  d$group_id <- paste(d$date,d$trade_group,sep=':')
  reason <- rep('',nrow(d))
  flag <- function(bad,label) reason[which(bad & reason=='')] <<- label
  flag(is.na(d$player_id)|d$player_id<=0,'non_player_or_missing_id')
  flag(!is.finite(d$player_id)|d$player_id!=floor(d$player_id)|!d$player_id%in%player_ids,'unknown_player_id')
  flag(is.na(d$date),'invalid_date')
  flag(!d$origin%in%team_ids|!d$destination%in%team_ids|d$origin==d$destination,'invalid_team_route')
  flag(is.na(d$team_match_status)|d$team_match_status!='description_and_ids_agree'|
       is.na(d$source_team_id)|d$source_team_id!=d$destination,'source_direction_questionable')
  flag(duplicated(raw),'exact_duplicate')
  label_dates <- tapply(as.character(d$date),d$trade_group,function(x) length(unique(x)))
  flag(is.na(d$trade_group)|!nzchar(trimws(d$trade_group))|
       label_dates[d$trade_group]>1L,'questionable_group')
  day_key <- paste(d$player_id,d$date)
  day_counts <- table(day_key[reason==''])
  flag(unname(day_counts[day_key])>1L,'ambiguous_same_day_legs')
  d$validation_status <- ifelse(reason=='','valid',reason)
  d$after_game_coverage <- !is.na(d$date)&d$date>last_date
  # Asset rows still establish whether both sides of a group are represented.
  groups <- split(seq_len(nrow(d)),d$group_id)
  complete <- vapply(groups,function(i) {
    all(d$origin[i]%in%team_ids & d$destination[i]%in%team_ids) &&
      setequal(d$origin[i],d$destination[i]) &&
      all(d$validation_status[i]%in%c('valid','non_player_or_missing_id','exact_duplicate'))
  },logical(1))
  d$partial_group <- !unname(complete[d$group_id])
  d$game_match <- FALSE; d$match_status <- d$validation_status
  d$pre_games <- d$post_games <- NA_integer_
  d$followup_end <- NA_character_
  d
}

prepare_translation_inputs <- function(config=translation_config(),data_dir=NULL) {
  if (!requireNamespace('data.table',quietly=TRUE)) stop('Install data.table first.')
  if (is.null(data_dir)) data_dir <- file.path(dirname(TRANSLATION_DIR),'data collection','datasets')
  possible <- file.path(data_dir,c('nba_traded_players_2016_2026.csv','nba_traded_players.csv'))
  available <- possible[file.exists(possible)]
  if (!length(available)) stop('The NBA trade CSV is missing.')
  if (length(available)>1L && length(unique(unname(tools::md5sum(available))))>1L)
    stop('Two different trade CSVs exist; keep one authoritative snapshot.')
  files <- c(player_games=file.path(data_dir,'nba_player_games_2010_2026.csv'),
    team_games=file.path(data_dir,'nba_team_games_2010_2026.csv'),
    profiles=file.path(data_dir,'nba_player_team_seasons_2010_2026.csv'),trades=available[1L])
  fields <- c('player_id','team_id','game_id','season','team_abbreviation','game_date',
    'minutes','pts','fgm','fga','fg3a','fta','ast','tov','oreb','dreb','age','height_inches','prior_bref_bpm')
  p <- data.table::fread(files['player_games'],select=fields,colClasses=c(game_id='character'))
  t <- data.table::fread(files['team_games'],select=c('team_id','game_id','game_date',
    'game_elapsed_minutes','possessions_est','pts','opp_pts','fga','fta','tov','fgm','ast','win'),
    colClasses=c(game_id='character'))
  profiles <- data.table::fread(files['profiles'],select=c('player_id','player_name'))
  p[,game_date:=as.Date(game_date)]; t[,game_date:=as.Date(game_date)]
  p <- p[is.finite(minutes)&minutes>0]
  if (anyDuplicated(p[,.(player_id,game_id)])||anyDuplicated(t[,.(team_id,game_id)])) stop('Duplicate game keys.')
  index <- match(paste(p$team_id,p$game_id),paste(t$team_id,t$game_id))
  if (anyNA(index)) stop('Player games missing team context.')
  p[,`:=`(team_fga=t$fga[index],team_fta=t$fta[index],team_tov=t$tov[index],
            team_fgm=t$fgm[index],team_elapsed=t$game_elapsed_minutes[index])]
  data.table::setorder(p,player_id,game_date,game_id)
  p[,episode:=data.table::rleid(team_id),by=player_id]
  data.table::setorder(t,team_id,game_date,game_id)
  raw <- data.table::fread(files['trades'])
  audit <- validate_translation_trades(raw,unique(p$player_id),unique(t$team_id),max(t$game_date))
  signings <- data.frame(player_id=numeric(),destination=numeric(),date=as.Date(character()))
  json_path <- file.path(dirname(data_dir),'NBA_Player_Movement.json')
  if (file.exists(json_path)) {
    if (!requireNamespace('jsonlite',quietly=TRUE)) stop('Install jsonlite to read the supplied signing records.')
    source <- jsonlite::fromJSON(json_path)$NBA_Player_Movement$rows
    source <- source[tolower(source$Transaction_Type)=='signing' & source$PLAYER_ID>0,,drop=FALSE]
    signings <- unique(data.frame(player_id=source$PLAYER_ID,destination=source$TEAM_ID,
      date=as.Date(substr(source$TRANSACTION_DATE,1,10))))
    signings <- signings[!is.na(signings$date)&signings$destination%in%t$team_id,]
    files <- c(files,signings=json_path)
  }
  answer <- list(p=p,t=t,profiles=profiles,audit=audit,signings=signings,
    players=split(as.data.frame(p),p$player_id),teams=split(as.data.frame(t),t$team_id),
    team_players=split(p,p$team_id),snapshot_cache=new.env(parent=emptyenv()),
    input_files=setNames(unname(tools::md5sum(files)),names(files)),
    data_last=max(t$game_date),trade_path=available[1L])
  valid <- audit[audit$validation_status=='valid',]
  valid <- valid[order(valid$date,valid$record_id),]
  answer$ledger <- split(valid,valid$player_id)
  answer$signing_ledger <- split(signings[order(signings$date),],signings$player_id[order(signings$date)])
  all_player_dates <- audit[is.finite(audit$player_id)&audit$player_id>0&!is.na(audit$date),]
  answer$all_trade_dates <- split(all_player_dates$date,all_player_dates$player_id)
  uncertain <- all_player_dates[!all_player_dates$validation_status%in%c('valid','exact_duplicate'),]
  answer$uncertain_dates <- split(uncertain$date,uncertain$player_id)
  matched <- translation_trade_catalog(answer)
  answer$audit <- matched$audit; answer$catalog <- matched$catalog
  answer
}

# Use only events already known before the date. A later appearance can supersede
# an older trade or signing, which avoids treating a subsequent free agent as if
# they still belonged to the team from a years-old transaction.
translation_location <- function(inputs,id,cutoff) {
  key <- as.character(id); dates <- numeric(); teams <- numeric()
  p <- inputs$players[[key]]
  if (!is.null(p)) {
    i <- findInterval(as.numeric(cutoff)-1,as.numeric(p$game_date))
    if (i>0L) { dates <- c(dates,as.numeric(p$game_date[i])); teams <- c(teams,p$team_id[i]) }
  }
  for (ledger in list(inputs$ledger[[key]],inputs$signing_ledger[[key]])) {
    if (is.null(ledger)||!nrow(ledger)) next
    i <- findInterval(as.numeric(cutoff)-1,as.numeric(ledger$date))
    if (i>0L) { dates <- c(dates,as.numeric(ledger$date[i])); teams <- c(teams,ledger$destination[i]) }
  }
  if (!length(dates)) return(NA_real_)
  latest <- max(dates); locations <- unique(teams[dates==latest])
  questionable <- inputs$uncertain_dates[[key]]
  if (length(locations)!=1L || any(questionable<cutoff & as.numeric(questionable)>=latest)) return(NA_real_)
  locations[1L]
}

translation_trade_catalog <- function(inputs) {
  audit <- inputs$audit; out <- list()
  for (r in which(audit$validation_status=='valid')) {
    row <- audit[r,]; player <- inputs$players[[as.character(row$player_id)]]
    if (row$after_game_coverage) { audit$match_status[r] <- 'after_game_coverage'; next }
    if (is.null(player)) { audit$match_status[r] <- 'no_game_history'; next }
    pre <- findInterval(as.numeric(row$date)-1,as.numeric(player$game_date))
    audit$pre_games[r] <- pre
    if (!pre) { audit$match_status[r] <- 'no_pre_game_history'; next }
    known_team <- translation_location(inputs,row$player_id,row$date)
    if (is.na(known_team)||known_team!=row$origin) {
      audit$match_status[r] <- 'origin_not_confirmed_before_trade'; next
    }
    anchor <- which(player$game_date>=row$date & player$team_id==row$destination)[1L]
    dates <- inputs$all_trade_dates[[as.character(row$player_id)]]
    later <- dates[dates>row$date]
    next_trade <- if (length(later)) min(later) else as.Date('9999-01-01')
    if (is.na(anchor)||player$game_date[anchor]>=next_trade) {
      audit$match_status[r] <- 'no_destination_appearance_before_next_trade_or_end'; next
    }
    between <- player$game_date>row$date & player$game_date<player$game_date[anchor]
    if (any(between & player$team_id!=row$destination)) {
      audit$match_status[r] <- 'post_trade_team_conflict'; next
    }
    change <- which(seq_len(nrow(player))>anchor & player$team_id!=row$destination)[1L]
    stop_at <- if (is.na(change)) nrow(player) else change-1L
    why <- if (is.na(change)) 'data_end' else 'team_change'
    trade_end <- findInterval(as.numeric(next_trade)-1,as.numeric(player$game_date))
    if (trade_end<stop_at) { stop_at <- trade_end; why <- 'next_trade' }
    audit$game_match[r] <- TRUE
    audit$post_games[r] <- max(0L,stop_at-anchor+1L)
    audit$followup_end[r] <- why
    audit$match_status[r] <- if (player$team_id[pre]==row$origin) 'matched_direct' else 'matched_prior_trade_chain'
    out[[length(out)+1L]] <- data.frame(player_id=row$player_id,cutoff=row$date,
      origin=row$origin,destination=row$destination,anchor=anchor,stop_at=stop_at,
      transfer_type='verified_trade',record_id=r,group_id=row$group_id,
      followup_end=why,stringsAsFactors=FALSE)
  }
  catalog <- if (length(out)) do.call(rbind,out) else stop('No trades match the game history.')
  if (anyDuplicated(catalog[c('player_id','anchor')])) stop('Multiple trade records match one prediction anchor.')
  list(audit=audit,catalog=catalog)
}

translation_roster_context <- function(snapshot,roster,player_id,height) {
  roster <- roster[roster$player_id!=player_id,]
  band <- function(x) ifelse(x<=77,1L,ifelse(x<=81,2L,3L))
  same <- !is.na(roster$height)&is.finite(height)&band(roster$height)==band(height)
  c(snapshot$base,
    top_usage=if(nrow(roster)&&any(is.finite(roster$usg))) max(roster$usg,na.rm=TRUE) else NA_real_,
    high_usage_minutes_share=sum(roster$minutes[which(roster$usg>=25)])/snapshot$minutes,
    same_size_minutes_share=sum(roster$minutes[which(same)])/snapshot$minutes,
    available_minutes=snapshot$minutes-sum(roster$minutes),
    available_plays=1-sum(roster$plays)/snapshot$plays,
    top_assists=if(nrow(roster)) max(roster$assists) else NA_real_,
    history_games=snapshot$games,days_since_game=as.numeric(snapshot$cutoff-snapshot$last_date))
}

# Cache team summaries across the four window experiments. Only historical role
# estimates are carried across a trade, never a teammate's future performance.
translation_feature_engine <- function(inputs,config) {
  valid <- inputs$audit[inputs$audit$validation_status=='valid',]
  group_rows <- split(valid,valid$group_id)
  role_at <- function(id,cutoff) {
    p <- inputs$players[[as.character(id)]]
    if (is.null(p)) return(NULL)
    end <- findInterval(as.numeric(cutoff)-1,as.numeric(p$game_date))
    if (!end) return(NULL)
    h <- p[seq.int(max(1L,end-config$team_window+1L),end),]
    rates <- translation_window_stats(h)
    data.frame(player_id=id,minutes=mean(h$minutes),plays=mean(h$fga+.44*h$fta+h$tov),
      assists=mean(h$ast),usg=unname(rates['usg']),height=tail(h$height_inches,1L),last_date=max(h$game_date))
  }
  snapshot_at <- function(team,cutoff) {
    key <- paste(team,cutoff,config$team_window,config$min_team_games)
    if (exists(key,inputs$snapshot_cache,inherits=FALSE)) return(inputs$snapshot_cache[[key]])
    games <- inputs$teams[[as.character(team)]]
    if (is.null(games)) return(NULL)
    end <- findInterval(as.numeric(cutoff)-1,as.numeric(games$game_date))
    if (end<config$min_team_games) return(NULL)
    g <- games[seq.int(max(1L,end-config$team_window+1L),end),]
    ap <- inputs$team_players[[as.character(team)]]
    recent <- ap[game_id%in%g$game_id]
    active <- unique(recent[game_id%in%tail(g$game_id,10L),player_id])
    roster <- recent[player_id%in%active,.(minutes=sum(minutes)/nrow(g),
      plays=sum(fga+.44*fta+tov)/nrow(g),assists=sum(ast)/nrow(g),
      usg=100*translation_ratio(sum(fga+.44*fta+tov)*sum(team_elapsed),sum(minutes)*sum(team_fga+.44*team_fta+team_tov)),
      height=tail(height_inches,1L),last_date=max(game_date)),by=player_id]
    base <- c(pace=48*sum(g$possessions_est)/sum(g$game_elapsed_minutes),
      ortg=100*sum(g$pts)/sum(g$possessions_est),drtg=100*sum(g$opp_pts)/sum(g$possessions_est),
      ts=100*sum(g$pts)/(2*sum(g$fga+.44*g$fta)),
      assist_rate=100*sum(g$ast)/sum(g$fgm),win_rate=mean(g$win))
    answer <- list(base=base,roster=as.data.frame(roster),games=nrow(g),
      minutes=5*mean(g$game_elapsed_minutes),plays=mean(g$fga+.44*g$fta+g$tov),
      last_date=max(g$game_date),first_date=min(g$game_date),cutoff=cutoff)
    # Correct already-known departures and arrivals, but let later box scores
    # supersede an earlier transaction. Missing signing/waiver history remains a limit.
    adjusted <- answer$roster
    location <- vapply(adjusted$player_id,function(id) translation_location(inputs,id,cutoff),numeric(1))
    adjusted <- adjusted[is.na(location)|location==team,]
    arrivals <- valid$player_id[valid$destination==team & valid$date<cutoff & valid$date>=min(g$game_date)]
    arrivals <- c(arrivals,inputs$signings$player_id[inputs$signings$destination==team &
      inputs$signings$date<cutoff & inputs$signings$date>=min(g$game_date)])
    for (id in setdiff(unique(arrivals),adjusted$player_id)) {
      location <- translation_location(inputs,id,cutoff)
      if (!is.na(location)&&location==team) {
        role <- role_at(id,cutoff)
        if (!is.null(role)) adjusted <- rbind(adjusted,role)
      }
    }
    answer$known_roster <- adjusted
    inputs$snapshot_cache[[key]] <- answer
    answer
  }
  extract <- function(player,cutoff,origin,destination,group_id='',departing_ids=numeric(),arriving_ids=numeric()) {
    end <- findInterval(as.numeric(cutoff)-1,as.numeric(player$game_date))
    if (end<config$window) return(list(reason='insufficient_history'))
    previous <- player[seq.int(end-config$window+1L,end),]
    past <- translation_window_stats(previous)
    if (any(!is.finite(past[c('minutes','usg','ts','ast')]))) return(list(reason='undefined_prior_rates'))
    current <- snapshot_at(origin,cutoff); destination_snapshot <- snapshot_at(destination,cutoff)
    if (is.null(current)||is.null(destination_snapshot)) return(list(reason='insufficient_team_history'))
    last <- previous[nrow(previous),]; focal <- last$player_id
    raw <- destination_snapshot$roster
    roster <- destination_snapshot$known_roster
    group <- group_rows[[group_id]]
    partial <- 1
    if (!is.null(group)) {
      if (any(group$date!=cutoff)) stop('Transaction package is not dated at the cutoff.')
      departing_ids <- unique(c(departing_ids,group$player_id[group$origin==destination]))
      arriving_ids <- unique(c(arriving_ids,group$player_id[group$destination==destination]))
      partial <- as.integer(any(group$partial_group))
    }
    departing_ids <- setdiff(departing_ids,focal); arriving_ids <- setdiff(arriving_ids,focal)
    removed <- roster[roster$player_id%in%departing_ids,]
    roster <- roster[!roster$player_id%in%c(departing_ids,arriving_ids,focal),]
    added <- list(); unknown <- 0L
    for (id in arriving_ids) {
      role <- role_at(id,cutoff)
      if (is.null(role)) unknown <- unknown+1L else added[[length(added)+1L]] <- role
    }
    incoming <- if (length(added)) do.call(rbind,added) else roster[FALSE,]
    roster <- rbind(roster,incoming)
    current_context <- translation_roster_context(current,current$roster,focal,last$height_inches)
    raw_context <- translation_roster_context(destination_snapshot,raw,focal,last$height_inches)
    dest_context <- translation_roster_context(destination_snapshot,roster,focal,last$height_inches)
    older <- if (end>=2L*config$window)
      translation_window_stats(player[seq.int(end-2L*config$window+1L,end-config$window),])[c('minutes','usg','ts','ast')]
      else setNames(rep(NA_real_,4L),c('minutes','usg','ts','ast'))
    band <- function(x) ifelse(x<=77,1L,ifelse(x<=81,2L,3L))
    same <- function(r) if (!is.finite(last$height_inches)) 0 else
      sum(r$minutes[which(!is.na(r$height)&band(r$height)==band(last$height_inches))])
    net_minutes <- sum(removed$minutes)-sum(incoming$minutes)
    net_plays <- sum(removed$plays)-sum(incoming$plays)
    net_assists <- sum(removed$assists)-sum(incoming$assists)
    deal <- c(departing_minutes=sum(removed$minutes),arriving_minutes=sum(incoming$minutes),
      net_minutes_open=net_minutes,net_plays_open=net_plays,net_assists_open=net_assists,
      net_same_size_minutes=same(removed)-same(incoming),
      departing_high_usage=sum(removed$usg>=25,na.rm=TRUE),arriving_high_usage=sum(incoming$usg>=25,na.rm=TRUE),
      unknown_arrivals=unknown,partial_group=partial,
      usage_gap=unname(past['usg']-dest_context['top_usage']),
      creation_gap=mean(previous$ast)-unname(dest_context['top_assists']),
      usage_opportunity_interaction=net_plays*unname(past['usg'])/100,
      minutes_opportunity_interaction=net_minutes*unname(past['minutes'])/48,
      assist_opportunity_interaction=net_assists*unname(past['ast'])/100)
    role <- c(known_team_change=as.numeric(origin!=destination),
      minutes_room_gap=unname(dest_context['available_minutes']-past['minutes']),
      shots_room_gap=unname(dest_context['available_plays'])*destination_snapshot$plays-mean(previous$fga+.44*previous$fta+previous$tov),
      positive_minutes=max(0,net_minutes),negative_minutes=max(0,-net_minutes),
      positive_shots=max(0,net_plays),negative_shots=max(0,-net_plays),
      positive_assists=max(0,net_assists),negative_assists=max(0,-net_assists),
      positive_position_minutes=max(0,same(removed)-same(incoming)),
      negative_position_minutes=max(0,same(incoming)-same(removed)),
      high_usage_competitors=sum(roster$usg>=25,na.rm=TRUE),
      established_creators=sum(roster$assists>=4,na.rm=TRUE),
      usage_load_above_player=sum(roster$plays[which(roster$usg>past['usg'])])/destination_snapshot$plays,
      assist_load_above_player=translation_ratio(sum(roster$assists[which(roster$assists>past['ast_per_game'])]),sum(roster$assists)))
    f <- c(setNames(past,paste0('past_',names(past))),
      setNames(past[c('minutes','usg','ts','ast')]-older,paste0('trend_',c('minutes','usg','ts','ast'))),
      age=last$age,height=last$height_inches,history_games=end,
      days_since_appearance=as.numeric(cutoff-last$game_date),prior_bpm=last$prior_bref_bpm,
      history_current_team_share=mean(previous$team_id==origin),history_team_count=length(unique(previous$team_id)),
      setNames(current_context,paste0('current_',names(current_context))),
      setNames(raw_context,paste0('raw_destination_',names(raw_context))),
      setNames(raw_context-current_context,paste0('raw_delta_',names(raw_context))),
      setNames(dest_context,paste0('destination_',names(dest_context))),
      setNames(dest_context-current_context,paste0('delta_',names(dest_context))),
      setNames(deal,paste0('deal_',names(deal))),setNames(role,paste0('role_',names(role))))
    latest <- max(previous$game_date,current$last_date,destination_snapshot$last_date,
                  roster$last_date,raw$last_date,current$roster$last_date)
    if (latest>=cutoff) stop('A future game entered the features.')
    list(features=f,feature_max_date=latest,last=last,roster_ids=roster$player_id,
         departing_ids=departing_ids,arriving_ids=arriving_ids)
  }
  scenario <- function(player_id,destination_team_id,cutoff,trade_group=NULL,
                       departing_ids=numeric(),arriving_ids=numeric()) {
    cutoff <- as.Date(cutoff)
    player <- inputs$players[[as.character(player_id)]]
    if (is.null(player)||is.null(inputs$teams[[as.character(destination_team_id)]])) stop('Unknown player or team.')
    origin <- translation_location(inputs,player_id,cutoff)
    if (is.na(origin)) stop('Current team is uncertain at this date.')
    record <- valid[valid$player_id==player_id & valid$destination==destination_team_id & valid$date==cutoff,]
    if (is.null(trade_group)) trade_group <- if(nrow(record)==1L) record$group_id else ''
    if (nzchar(trade_group)&&!trade_group%in%names(group_rows)) {
      dated <- paste(cutoff,trade_group,sep=':')
      if (!dated%in%names(group_rows)) stop('Unknown transaction package.')
      trade_group <- dated
    }
    extracted <- extract(player,cutoff,origin,destination_team_id,trade_group,departing_ids,arriving_ids)
    if (!is.null(extracted$reason)) stop(extracted$reason)
    as.data.frame(c(list(player_id=player_id,cutoff=cutoff,feature_max_date=extracted$feature_max_date,
      transfer=origin!=destination_team_id),as.list(extracted$features)))
  }
  list(extract=extract,scenario=scenario)
}

build_translation_data <- function(config=translation_config(),data_dir=NULL,inputs=NULL) {
  if (config$window<2L||config$min_team_games>config$team_window) stop('Invalid window settings.')
  if (is.null(inputs)) inputs <- prepare_translation_inputs(config,data_dir)
  threads <- data.table::setDTthreads(1L)
  on.exit(data.table::setDTthreads(threads),add=TRUE)
  engine <- translation_feature_engine(inputs,config)
  catalog_by_player <- split(inputs$catalog,inputs$catalog$player_id)
  audit <- inputs$audit; audit$eligible <- FALSE
  audit$eligibility_reason <- audit$match_status
  rows <- partial_rows <- list(); movement_rows <- list()
  excluded <- c(insufficient_history=0L,incomplete_target=0L,undefined_prior_rates=0L,
                undefined_target_rates=0L,insufficient_team_history=0L,overlap_avoided=0L)
  targets <- c('minutes','usg','ts','ast')
  for (player in inputs$players) {
    id <- player$player_id[1L]; key <- as.character(id)
    events <- catalog_by_player[[key]]
    if (is.null(events)) events <- inputs$catalog[FALSE,]
    episodes <- split(seq_len(nrow(player)),player$episode)
    for (episode in episodes) {
      first <- episode[1L]
      if (first==1L||first%in%events$anchor) next
      origin <- player$team_id[first-1L]; destination <- player$team_id[first]
      old_date <- player$game_date[first-1L]; first_date <- player$game_date[first]
      related <- inputs$all_trade_dates[[key]]
      related <- any(related>=old_date & related<=first_date)
      signing <- inputs$signing_ledger[[key]]
      signing <- if (is.null(signing)) signing else signing[signing$destination==destination &
                   signing$date>=old_date & signing$date<=first_date,,drop=FALSE]
      type <- if (related) 'unresolved_trade_related' else if (!is.null(signing)&&nrow(signing))
        'confirmed_signing' else 'other_unclassified'
      cutoff <- if (type=='confirmed_signing') min(signing$date) else old_date
      stop_at <- tail(episode,1L); why <- if (stop_at<nrow(player)) 'team_change' else 'data_end'
      later <- inputs$all_trade_dates[[key]]
      later <- later[later>cutoff]
      if (length(later)) {
        limit <- findInterval(as.numeric(min(later))-1,as.numeric(player$game_date))
        if (limit<stop_at) { stop_at <- limit; why <- 'next_trade' }
      }
      events <- rbind(events,data.frame(player_id=id,cutoff=cutoff,origin=origin,destination=destination,
        anchor=first,stop_at=stop_at,transfer_type=type,record_id=NA_integer_,group_id='',followup_end=why))
    }
    events <- events[order(events$anchor,events$cutoff),]
    # Reserve transfer windows first; stayer blocks cannot share their outcomes.
    reserved_start <- events$anchor
    reserved_end <- pmin(events$stop_at,events$anchor+config$window-1L)
    candidates <- events
    for (episode in episodes) {
      if (length(episode)<2L*config$window) next
      anchors <- seq.int(episode[1L]+config$window,tail(episode,1L)-config$window+1L,by=config$window)
      for (anchor in anchors) {
        end <- anchor+config$window-1L
        if (any(anchor<=reserved_end & end>=reserved_start)) {
          excluded['overlap_avoided'] <- excluded['overlap_avoided']+1L; next
        }
        cutoff <- player$game_date[anchor]
        later <- inputs$all_trade_dates[[key]]; later <- later[later>=cutoff]
        if (length(later)&&min(later)<=player$game_date[end]) {
          excluded['overlap_avoided'] <- excluded['overlap_avoided']+1L; next
        }
        candidates <- rbind(candidates,data.frame(player_id=id,cutoff=cutoff,
          origin=player$team_id[anchor],destination=player$team_id[anchor],anchor=anchor,
          stop_at=tail(episode,1L),transfer_type='stayer',record_id=NA_integer_,group_id='',followup_end='episode_end'))
      }
    }
    for (j in seq_len(nrow(candidates))) {
      candidate <- candidates[j,]; trade <- candidate$transfer_type=='verified_trade'
      transfer <- candidate$transfer_type!='stayer'
      available <- max(0L,candidate$stop_at-candidate$anchor+1L)
      if (transfer) movement_rows[[length(movement_rows)+1L]] <- list(player_id=id,
        cutoff=candidate$cutoff,type=candidate$transfer_type,post_games=available,complete=available>=config$window)
      if (available<config$window && (!trade||available<5L)) {
        excluded['incomplete_target'] <- excluded['incomplete_target']+1L
        if (trade) audit$eligibility_reason[candidate$record_id] <- paste0('short_followup_',candidate$followup_end)
        next
      }
      extracted <- engine$extract(player,candidate$cutoff,candidate$origin,candidate$destination,candidate$group_id)
      if (!is.null(extracted$reason)) {
        excluded[extracted$reason] <- excluded[extracted$reason]+1L
        if (trade) audit$eligibility_reason[candidate$record_id] <- extracted$reason
        next
      }
      end <- min(candidate$stop_at,candidate$anchor+config$window-1L)
      future <- player[seq.int(candidate$anchor,end),]
      outcome <- translation_window_stats(future)[targets]
      if (any(!is.finite(outcome))) {
        excluded['undefined_target_rates'] <- excluded['undefined_target_rates']+1L
        if (trade) audit$eligibility_reason[candidate$record_id] <- 'undefined_target_rates'
        next
      }
      last <- extracted$last
      row <- c(list(player_id=id,cutoff=candidate$cutoff,feature_max_date=extracted$feature_max_date,
        target_start=min(future$game_date),target_end=max(future$game_date),target_games=nrow(future),
        target_start_season=future$season[1L],target_end_season=tail(future$season,1L),
        origin_team_id=candidate$origin,destination_team_id=candidate$destination,
        history_team_id=last$team_id,transfer=transfer,verified_trade=trade,
        transfer_type=candidate$transfer_type,record_id=candidate$record_id,
        trade_group=candidate$group_id,followup_end=candidate$followup_end),
        as.list(extracted$features),as.list(setNames(outcome,paste0('next_',targets))),
        as.list(setNames(as.numeric(outcome[c('minutes','usg','ast')])-extracted$features[paste0('past_',c('minutes','usg','ast'))],
                        paste0('change_',c('minutes','usg','ast')))))
      if (available<config$window) {
        partial_rows[[length(partial_rows)+1L]] <- row
        excluded['incomplete_target'] <- excluded['incomplete_target']+1L
        audit$eligibility_reason[candidate$record_id] <- paste0('short_followup_',candidate$followup_end)
      } else {
        rows[[length(rows)+1L]] <- row
        if (trade) {
          audit$eligible[candidate$record_id] <- TRUE
          audit$eligibility_reason[candidate$record_id] <- 'eligible'
        }
      }
    }
  }
  result <- as.data.frame(data.table::rbindlist(rows))
  partial <- if(length(partial_rows)) as.data.frame(data.table::rbindlist(partial_rows)) else result[FALSE,]
  names_by_id <- inputs$profiles[!duplicated(inputs$profiles$player_id),]
  decorate <- function(d) {
    d$player_name <- names_by_id$player_name[match(d$player_id,names_by_id$player_id)]
    abbreviations <- tapply(inputs$p$team_abbreviation,inputs$p$team_id,function(x) tail(x,1L))
    d$origin_team <- unname(abbreviations[as.character(d$origin_team_id)])
    d$destination_team <- unname(abbreviations[as.character(d$destination_team_id)])
    d <- d[order(d$cutoff,d$player_id,d$target_start),]; rownames(d) <- NULL
    d$observation_id <- seq_len(nrow(d)); d
  }
  result <- decorate(result); partial <- decorate(partial)
  if (!nrow(result)) stop('No eligible observations.')
  stopifnot(all(result$feature_max_date<result$cutoff),all(result$cutoff<=result$target_start),
            all(result$target_games==config$window),!anyDuplicated(result[c('player_id','target_start')]))
  for (p in split(result,result$player_id)) {
    p <- p[order(p$target_start),]
    if (nrow(p)>1L && any(p$target_start[-1L]<=head(p$target_end,-1L))) stop('Overlapping player target windows.')
  }
  list(observations=result,censored=partial,trade_audit=audit,
    movements=as.data.frame(data.table::rbindlist(movement_rows)),excluded=excluded,
    config=config,make_scenario=engine$scenario,input_files=inputs$input_files,
    data_last=inputs$data_last,trade_path=inputs$trade_path)
}
