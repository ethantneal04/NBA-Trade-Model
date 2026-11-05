# NBA data preparation, seasons ending 2010 through 2026.
# The year refers to the end of a season: 2010 means the 2009-10 season.
# Run with Rscript load_base_data_final.R, or source this file in RStudio.
# Install hoopR, dplyr and tibble before the first run.
#
# The four finished tables are written as CSVs in datasets beside this script.
# Downloads are kept in ../.nba_preprocessing_cache/sources so later runs can
# use the same inputs without downloading them again. Intermediate tables stay
# in memory. A fresh download can change results if a source has been updated.

suppressPackageStartupMessages({
  library(dplyr)
})
# Resolve paths from this file so running from the project root also works.
source_files <- lapply(sys.frames(), function(frame) frame$ofile)
source_files <- Filter(function(path) !is.null(path) && length(path) == 1L, source_files)
script_arg <- grep('^--file=', commandArgs(trailingOnly=FALSE), value=TRUE)
if (length(source_files)) {
  SCRIPT_DIR <- dirname(normalizePath(tail(source_files, 1L)[[1L]], mustWork=TRUE))
} else if (length(script_arg)) {
  SCRIPT_DIR <- dirname(normalizePath(sub('^--file=', '', script_arg[1L]), mustWork=TRUE))
} else {
  SCRIPT_DIR <- getwd()
  if (!file.exists(file.path(SCRIPT_DIR, 'load_base_data_final.R'))) {
    candidate <- file.path(SCRIPT_DIR, 'data collection')
    if (!file.exists(file.path(candidate, 'load_base_data_final.R')))
      stop('Source this file, use Rscript, or set the working directory to its folder.')
    SCRIPT_DIR <- candidate
  }
}
OUTPUT_ROOT <- file.path(SCRIPT_DIR, 'datasets')
CACHE_ROOT <- file.path(dirname(SCRIPT_DIR), '.nba_preprocessing_cache', 'sources')

# 1. Load and clean the game data
#
# Use the schedule's regular-season label to decide which games belong here.
# This includes NBA Cup games that count toward the regular season, but leaves
# out the Cup final. Checks below stop the run for missing games, duplicate keys
# or inconsistent scores.
START_END_YEAR <- 2010L
LAST_END_YEAR  <- 2026L
CACHE <- CACHE_ROOT
dir.create(CACHE, recursive=TRUE, showWarnings=FALSE)
REUSE_CACHE <- TRUE
# Change the year limits above to build a smaller set of seasons.
SEASONS <- seq.int(START_END_YEAR,LAST_END_YEAR)

fail <- function(df, y, msg) {
  if(nrow(df)) stop(msg, ' (season ', y, ')', call.=FALSE)
}
num <- function(x) suppressWarnings(as.numeric(as.character(x)))
# Source column names vary across seasons. Use the first known name, and stop
# when a required field is absent instead of quietly filling it with missing data.
val <- function(d, aliases, label, required=TRUE) {
  col <- intersect(aliases,names(d)); if(!length(col)) {
    if(required) stop('Missing ',label,'; columns available: ',paste(names(d),collapse=', '))
    return(rep(NA_real_,nrow(d)))
  }; num(d[[col[1]]])
}
# Minutes may arrive as a decimal or as minutes:seconds. Convert both to decimal
# minutes; flag unfamiliar text so a source format change is caught early.
parse_min <- function(x) {
 x <- trimws(as.character(x)); o<-rep(NA_real_,length(x))
 a<-grepl('^[0-9]+:[0-9]{2}(\\.[0-9]+)?$',x)
 o[a]<-num(sub(':.*','',x[a]))+num(sub('.*:','',x[a]))/60
 b<-grepl('^[0-9]+(\\.[0-9]+)?$',x);o[b]<-num(x[b])
 o[toupper(x) %in% c('','NA','DNP','N/A') | is.na(x)]<-NA_real_
 bad<-unique(x[!is.na(x)&nzchar(x)&is.na(o)&!toupper(x)%in%c('DNP','N/A')]);
 if(length(bad)) stop('Unrecognized minutes: ',paste(head(bad,10),collapse=', '))
 o
}
# Read the saved download when possible. The cache holds the original source
# tables, grouped into schedule, players and teams folders, so cleaning rules
# can be rerun without making another request.
load_cached <- function(y,kind) {
  cache_folder <- file.path(CACHE, kind)
  dir.create(cache_folder, recursive=TRUE, showWarnings=FALSE)
  fn<-file.path(cache_folder,sprintf('%s_%s.rds',kind,y))
  if(REUSE_CACHE&&file.exists(fn)) return(readRDS(fn))
  # These hoopR loaders use the starting year: season ending 2010 is passed as 2009.
  z<-switch(kind,
    schedule=hoopR::load_nba_stats_schedule(seasons=y-1L),
    players=hoopR::load_nba_stats_player_boxscores(seasons=y-1L),
    teams=hoopR::load_nba_stats_team_boxscores(seasons=y-1L))
  if(!is.data.frame(z)||!nrow(z)) stop('Empty ',kind,' response for ',y)
  saveRDS(z,fn);z
}
# Clean one season at a time, using the schedule to filter both box-score tables.
process_season <- function(y) {
 message('Collecting season ending ',y)
 s<-load_cached(y,'schedule'); p<-load_cached(y,'players'); t<-load_cached(y,'teams')
 needed_s<-c('season','game_id','season_type','game_date')
 if(length(setdiff(needed_s,names(s)))) stop('Schedule schema changed')
 schedule<-s %>% transmute(season=as.integer(season),game_id=as.character(game_id),game_date=as.Date(game_date),
       raw_season_type=tolower(trimws(as.character(season_type)))) %>% filter(season==y) %>% distinct()
 ambiguous<-schedule %>% count(season,game_id,name='n') %>% filter(n!=1)
 fail(ambiguous,y,'Conflicting schedule rows')

 regular<-schedule %>% filter(raw_season_type %in% c('regular-season','regular season'))
 if(!nrow(regular)) stop('No regular-season classifications in schedule ',y)
 # Season lengths vary, so check against the actual schedule rather than assuming
 # 82 games per team. The 2013 Celtics-Pacers cancellation is still listed in the
 # source schedule even though the game was never played.
 cancelled_games <- tibble::tibble(
   season = 2013L,
   game_id = "0021201214",
   reason = "Celtics-Pacers canceled April 16, 2013; not rescheduled"
 )

 # Remove the listed cancellation before checking for missing box scores.
 regular <- regular %>%
   anti_join(
     cancelled_games,
     by = c("season", "game_id")
   ) %>%
   select(season, game_id, game_date)
 if(length(setdiff(c('person_id','team_id','season','game_id','minutes'),names(p)))) stop('Player-game schema changed')
 players_raw <- p %>% transmute(
   player_id=as.integer(person_id),team_id=as.integer(team_id),game_id=as.character(game_id),season=as.integer(season),
   team_abbreviation=as.character(team_tricode), minutes=parse_min(minutes),
   pts=val(p,'points','points'),fgm=val(p,'field_goals_made','FGM'), fga=val(p,'field_goals_attempted','FGA'),
   fg3m=val(p,c('three_pointers_made','three_point_field_goals_made'),'3PM'),
   fg3a=val(p,c('three_pointers_attempted','three_point_field_goals_attempted'),'3PA'),
   ftm=val(p,'free_throws_made','FTM'),fta=val(p,'free_throws_attempted','FTA'),
   oreb=val(p,c('rebounds_offensive','offensive_rebounds'),'OREB'),
   dreb=val(p,c('rebounds_defensive','defensive_rebounds'),'DREB'),
   ast=val(p,'assists','AST'),tov=val(p,'turnovers','TOV'),
   stl=val(p,'steals','STL'),blk=val(p,'blocks','BLK'))
 raw_missing<-players_raw %>% filter(season==y) %>% anti_join(schedule,by=c('season','game_id'))
 fail(raw_missing %>% select(player_id,team_id,season,game_id) %>% distinct(),y,'Player box game not in schedule')
 players<-players_raw %>% inner_join(regular,by=c('season','game_id'),relationship='many-to-one')
 # Keep anyone with positive minutes, points or shot attempts. Dropping a scoring
 # row just because its minutes are missing would break the team score totals.
 players <- players %>%
   filter(
     (!is.na(minutes) & minutes > 0) |
       coalesce(pts, 0) > 0 |
       coalesce(fga, 0) > 0 |
       coalesce(fta, 0) > 0
   )
 duplicates<-players %>% count(player_id,season,game_id,name='n') %>% filter(n>1)
 fail(duplicates,y,'Duplicate player-game keys')
 missing_stats<-players %>% filter(if_any(c(pts,fgm,fga,fg3m,fg3a,ftm,fta,oreb,dreb,ast,tov,stl,blk),is.na))
 fail(missing_stats %>% select(player_id,team_id,season,game_id),y,'Played player has missing box stats')
 if(length(setdiff(c('team_id','season','game_id'),names(t)))) stop('Team-game schema changed')
 team_raw<-t %>% transmute(team_id=as.integer(team_id),season=as.integer(season),game_id=as.character(game_id),
      pts=val(t,'points','team PTS'),fgm=val(t,'field_goals_made','team FGM'),
      fga=val(t,'field_goals_attempted','team FGA'),
      fg3m=val(t,c('three_pointers_made','three_point_field_goals_made'),'team 3PM'),
      fg3a=val(t,c('three_pointers_attempted','three_point_field_goals_attempted'),'team 3PA'),
      ftm=val(t,'free_throws_made','team FTM'),fta=val(t,'free_throws_attempted','team FTA'),
      oreb=val(t,c('rebounds_offensive','offensive_rebounds'),'team OREB'),
      dreb=val(t,c('rebounds_defensive','defensive_rebounds'),'team DREB'),
      ast=val(t,'assists','team AST'),tov=val(t,'turnovers','team TOV'),
      stl=val(t,'steals','team STL',FALSE),blk=val(t,'blocks','team BLK',FALSE))

 # Discard placeholders before testing whether each game has two team records.
 team_raw <- team_raw %>%
   filter(!is.na(team_id), team_id != 0L, !is.na(pts))

 raw_tm_missing<-team_raw %>% filter(season==y) %>% anti_join(schedule,by=c('season','game_id'))
 fail(raw_tm_missing %>% select(season,game_id,team_id),y,'Team game not in schedule')

 # Every eligible game needs exactly two rows, representing two different teams.
 teams <- team_raw %>%
   inner_join(
     regular,
     by = c("season", "game_id"),
     relationship = "many-to-one"
   )

 team_counts <- teams %>%
   group_by(season, game_id) %>%
   summarise(
     team_rows = n(),
     distinct_teams = n_distinct(team_id),
     .groups = "drop"
   )

 missing_games <- regular %>%
   anti_join(team_counts, by = c("season", "game_id"))

 if (nrow(missing_games) || any(team_counts$team_rows != 2L | team_counts$distinct_teams != 2L)) {
   stop('Scheduled games do not have two valid teams (season ', y, ')', call.=FALSE)
 }

 opponents<-teams %>% select(season,game_id,opponent_id=team_id,opp_pts=pts,opp_fga=fga,
       opp_fg3a=fg3a,opp_fgm=fgm,opp_fg3m=fg3m,opp_fta=fta,opp_oreb=oreb,opp_dreb=dreb,opp_tov=tov)
 team_elapsed<-players %>% group_by(season,game_id,team_id) %>% summarise(game_elapsed_minutes=sum(minutes)/5,.groups='drop')
 teams<-teams %>% left_join(team_elapsed,by=c('season','game_id','team_id'),relationship='one-to-one')
 # Estimate possessions from shots, offensive rebounds, turnovers and free throws,
 # averaging the two teams' estimates. The 0.44 free-throw weight is an
 # approximation, so ratings and pace are labelled as estimates. Ratings use
 # points per 100 possessions; pace scales possessions to 48 elapsed minutes.
 teams<-teams %>% inner_join(opponents,by=c('season','game_id'),relationship='many-to-many') %>%
     filter(team_id!=opponent_id) %>% mutate(
     possessions_est=(fga-oreb+tov+0.44*fta + opp_fga-opp_oreb+opp_tov+0.44*opp_fta)/2,
     ortg_est=if_else(possessions_est>0,100*pts/possessions_est,NA_real_),
     drtg_est=if_else(possessions_est>0,100*opp_pts/possessions_est,NA_real_),
     netrtg_est=ortg_est-drtg_est,
     pace_est=if_else(game_elapsed_minutes>0,48*possessions_est/game_elapsed_minutes,NA_real_),
     win=as.integer(pts>opp_pts),
     # True shooting includes free throws; effective field-goal percentage gives
     # made threes extra weight. Undefined rates stay missing, rather than zero.
     ts=if_else(fga+0.44*fta>0,pts/(2*(fga+0.44*fta)),NA_real_),
     efg=if_else(fga>0,(fgm+0.5*fg3m)/fga,NA_real_),
     three_par=if_else(fga>0,fg3a/fga,NA_real_),
     ast_pct_proxy=if_else(fgm>0,ast/fgm,NA_real_),
     tov_pct_proxy=if_else(fga+0.44*fta+tov>0,tov/(fga+0.44*fta+tov),NA_real_),
     oreb_pct=if_else(oreb+opp_dreb>0,oreb/(oreb+opp_dreb),NA_real_),
     dreb_pct=if_else(dreb+opp_oreb>0,dreb/(dreb+opp_oreb),NA_real_),
     opp_efg=if_else(opp_fga>0,(opp_fgm+0.5*opp_fg3m)/opp_fga,NA_real_),
     opp_tov_pct_proxy=if_else(opp_fga+0.44*opp_fta+opp_tov>0,opp_tov/(opp_fga+0.44*opp_fta+opp_tov),NA_real_))
 # Each player row must belong to one of the two teams that actually played.
 pt_missing<-players %>% anti_join(teams %>% select(season,game_id,team_id),by=c('season','game_id','team_id'))
 fail(pt_missing %>% select(player_id,team_id,season,game_id),y,'Player-team ID absent from that game')
 score_mismatch<-teams %>% select(season,game_id,team_id,team_pts=pts) %>%
     left_join(players %>% group_by(season,game_id,team_id) %>% summarise(player_pts=sum(pts),.groups='drop'),
           by=c('season','game_id','team_id')) %>%
     mutate(diff=player_pts-team_pts) %>% filter(is.na(diff)|abs(diff)>1)
 # Compare the sum of player points with the team score. Allow a one-point
 # difference; larger gaps or missing totals stop the run.

 if(nrow(score_mismatch)) stop('Player and team point totals differ for ',y)
 message('PASS ',y,' | games=',nrow(regular),' player rows=',nrow(players))
 list(players=players, teams=teams)
}
season_data <- lapply(SEASONS, process_season)

cat('STEP 1 COMPLETE. All years processed. See ',normalizePath(CACHE_ROOT),'\n')

# 2. Build game histories and player stints
#
# Combine the cleaned seasons, check their keys, then calculate the previous
# 40 appearances for each player and previous 40 games for each team. The
# current game's stats are excluded from every prior40_ feature.
PLAYER_WINDOW <- 40L; TEAM_WINDOW <- 40L

div <- function(a,b) ifelse(!is.na(b)&b>0,a/b,NA_real_)
player <- bind_rows(lapply(season_data, function(d) d$players))
team <- bind_rows(lapply(season_data, function(d) d$teams))
rm(season_data)
# Retain unusual scoring rows in the main player table so points still add up.
# For the player lookback, an appearance requires positive minutes. A zero-minute
# row therefore contributes to descriptive totals but does not advance that window.
player <- player %>% mutate(
  valid_appearance = !is.na(minutes) & minutes > 0,
  anomalous_zero_minute_production = !valid_appearance & (
    coalesce(pts, 0) > 0 | coalesce(fga, 0) > 0 |
    coalesce(fta, 0) > 0
  )
)
# Use cumulative sums to get a window total without summing the same rows again.
# With offset = 1, the window ends at the previous appearance. Early careers have
# shorter histories, and the first appearance has no previous-game total. If any
# value inside a window is missing, its total is also missing.
rolling_sum <- function(x, n, offset=0L) {
 x<-as.numeric(x); i<-seq_along(x); hi<-i-offset; lo<-hi-n+1L
 cs<-c(0,cumsum(replace(x,is.na(x),0))); na_cs<-c(0,cumsum(is.na(x)))
 high<-pmax(0L,hi); low<-pmax(1L,lo)
 sums<-cs[high+1L]-cs[low]; nas<-na_cs[high+1L]-na_cs[low]
 ifelse(hi<1L | high<low | nas>0,NA_real_,sums)
}
# Calculate totals from earlier appearances, then derive shooting rates and
# per-36-minute stats from those totals. prior40_gp records how many earlier
# appearances were available, up to 40.
make_player <- function(d,n) {
 d<-d[order(d$game_date,d$game_id),,drop=FALSE];N<-nrow(d)
 for(f in c('pts','fgm','fga','fg3m','fg3a','ftm','fta','oreb','dreb','ast','tov','stl','blk','minutes')) {
   d[[paste0('prior',n,'_',f)]]<-rolling_sum(d[[f]],n,offset=1L)
 }
 d[[paste0('prior',n,'_gp')]]<-pmin(seq_len(N)-1L,n)
 d[[paste0('prior',n,'_ts')]]<-div(d[[paste0('prior',n,'_pts')]],2*(d[[paste0('prior',n,'_fga')]]+0.44*d[[paste0('prior',n,'_fta')]]))
 d[[paste0('prior',n,'_efg')]]<-div(d[[paste0('prior',n,'_fgm')]]+0.5*d[[paste0('prior',n,'_fg3m')]],d[[paste0('prior',n,'_fga')]])
 d[[paste0('prior',n,'_3par')]]<-div(d[[paste0('prior',n,'_fg3a')]],d[[paste0('prior',n,'_fga')]])
 d[[paste0('prior',n,'_ftr')]]<-div(d[[paste0('prior',n,'_fta')]],d[[paste0('prior',n,'_fga')]])
 d[[paste0('prior',n,'_pts_per36')]]<-36*div(d[[paste0('prior',n,'_pts')]],d[[paste0('prior',n,'_minutes')]])
 d[[paste0('prior',n,'_ast_per36')]]<-36*div(d[[paste0('prior',n,'_ast')]],d[[paste0('prior',n,'_minutes')]])
 d
}
# Group by player ID across all seasons and teams. A traded player's earlier
# games still belong to their history, including games with the previous team.
player_for_windows <- player %>% filter(valid_appearance)
# Convert to a plain data frame before splitting the rows into player histories.
player_window_input <- as.data.frame(player_for_windows)
player_split <- split(player_window_input, factor(player_window_input$player_id), drop=TRUE)
player_windows<-bind_rows(lapply(player_split,make_player,n=PLAYER_WINDOW)) %>% arrange(player_id,game_date,game_id)
stopifnot(nrow(player_windows) == nrow(player_for_windows))
rm(player_split)
# Team histories follow the franchise ID across seasons. Sum earlier games
# first, then calculate ratings and percentages from the combined totals.
make_team <- function(d,n) {
 d<-d[order(d$game_date,d$game_id),,drop=FALSE];N<-nrow(d)
 for(f in c('pts','opp_pts','fga','fgm','fg3m','fg3a','fta','oreb','dreb','ast','tov','opp_fga','opp_fgm','opp_fg3m','opp_fta','opp_oreb','opp_dreb','opp_tov','win','possessions_est'))
   d[[paste0('prior',n,'_',f)]]<-rolling_sum(d[[f]],n,offset=1L)
 d[[paste0('prior',n,'_gp')]]<-pmin(seq_len(N)-1L,n)
 x<-paste0('prior',n,'_')
 d[[paste0(x,'ortg_est')]]<-100*div(d[[paste0(x,'pts')]],d[[paste0(x,'possessions_est')]])
 d[[paste0(x,'drtg_est')]]<-100*div(d[[paste0(x,'opp_pts')]],d[[paste0(x,'possessions_est')]])
 d[[paste0(x,'netrtg_est')]]<-d[[paste0(x,'ortg_est')]]-d[[paste0(x,'drtg_est')]]
 d[[paste0(x,'efg')]]<-div(d[[paste0(x,'fgm')]]+0.5*d[[paste0(x,'fg3m')]],d[[paste0(x,'fga')]])
 d[[paste0(x,'oreb_pct')]]<-div(d[[paste0(x,'oreb')]],d[[paste0(x,'oreb')]]+d[[paste0(x,'opp_dreb')]])
 d[[paste0(x,'dreb_pct')]]<-div(d[[paste0(x,'dreb')]],d[[paste0(x,'dreb')]]+d[[paste0(x,'opp_oreb')]])
 d[[paste0(x,'tov_pct_proxy')]]<-div(d[[paste0(x,'tov')]],d[[paste0(x,'fga')]]+0.44*d[[paste0(x,'fta')]]+d[[paste0(x,'tov')]])
 d[[paste0(x,'opp_efg')]]<-div(d[[paste0(x,'opp_fgm')]]+0.5*d[[paste0(x,'opp_fg3m')]],d[[paste0(x,'opp_fga')]])
 d[[paste0(x,'opp_tov_pct_proxy')]]<-div(d[[paste0(x,'opp_tov')]],d[[paste0(x,'opp_fga')]]+0.44*d[[paste0(x,'opp_fta')]]+d[[paste0(x,'opp_tov')]])
 d[[paste0(x,'ts')]]<-div(d[[paste0(x,'pts')]],2*(d[[paste0(x,'fga')]]+0.44*d[[paste0(x,'fta')]]))
 d[[paste0(x,'three_par')]]<-div(d[[paste0(x,'fg3a')]],d[[paste0(x,'fga')]])
 d[[paste0(x,'win_pct')]]<-div(d[[paste0(x,'win')]],d[[paste0(x,'gp')]])
 d
}
team_window_input <- as.data.frame(team)
team_split <- split(team_window_input, factor(team_window_input$team_id), drop=TRUE)
team_windows <- bind_rows(lapply(team_split,make_team,n=TEAM_WINDOW)) %>% arrange(team_id,game_date,game_id)
rm(team_split, team_window_input, player_window_input)
stopifnot(nrow(team_windows) == nrow(team))
# The resulting table has one row per team per game, with its earlier-game stats.

# A stint is a consecutive stretch of recorded games with one team within a
# season. These dates describe box-score appearances, not contract dates. A player
# who goes from team A to B and back to A gets two separate stints with A.
stint_games<-player %>% arrange(player_id,season,game_date,game_id) %>%
 group_by(player_id,season) %>% mutate(stint_index=cumsum(team_id!=lag(team_id,default=first(team_id)))+1L) %>% ungroup()
player_stints<-stint_games %>% group_by(player_id,season,team_id,team_abbreviation,stint_index) %>%
 summarise(first_game=min(game_date),last_game=max(game_date),gp=sum(valid_appearance),
   across(c(minutes,pts,fgm,fga,fg3m,fg3a,ftm,fta,oreb,dreb,ast,tov,stl,blk),sum),.groups='drop') %>%
 mutate(ts=div(pts,2*(fga+0.44*fta)),efg=div(fgm+0.5*fg3m,fga),three_par=div(fg3a,fga),
  ftr=div(fta,fga),pts_per36=36*div(pts,minutes))
# The prior_ columns use earlier games or seasons. Current-game box scores and
# completed-season statistics describe outcomes and can reveal future information
# if used as inputs to a prediction made before that game.
cat('STEP 2 COMPLETE: ',nrow(player),' player-games; ',nrow(team),' team-games; ',nrow(player_stints),' stints.\n')

# 3. Add player information and advanced statistics
#
# Match NBA player IDs to profiles and Basketball Reference (BRef) names. Check
# team, games played and minutes before attaching BRef stats to a stint. Keep
# completed-season descriptions separate from the previous-season predictors.
BREF_WAIT_SECONDS <- 4
# Player profiles are required because they connect NBA IDs to names and bios.
# A failed BRef request leaves that season without BRef stats; stop if none of
# the seasons supplies any BRef data.

# Give each source its own folder, alongside the schedule and box-score caches.
enrichment_cache_file <- function(kind, y) {
 folder <- switch(kind, player_master='player_profiles',
                  bref_advanced='bref_advanced', impact='player_impact',
                  stop('Unknown enrichment source: ', kind))
 file.path(CACHE, folder, sprintf('%s_%s.rds', kind, y))
}
# Optional sources may fail without ending the whole run. Required profiles are
# checked by the caller. Save successful downloads only, so failures can be retried.
get_cached <- function(kind,y,fetch) {
 f <- enrichment_cache_file(kind, y)
 dir.create(dirname(f), recursive=TRUE, showWarnings=FALSE)
 if(file.exists(f)) return(readRDS(f))
 ans <- tryCatch(fetch(),error=function(e) e)
 if(inherits(ans, 'error') || !is.data.frame(ans) || !nrow(ans)) return(NULL)
 saveRDS(ans,f); ans
}
first_col <- function(d,candidates,default=NA) {
 hit <- intersect(candidates,names(d))
 if(length(hit)) return(d[[hit[[1]]]])
 rep(default,nrow(d))
}
as_num <- function(x) suppressWarnings(as.numeric(gsub(',','',as.character(x),fixed=TRUE)))
# Ignore accents, spaces and punctuation for the first name match. Ambiguous
# normalized names are removed later, before any statistics are joined.
norm_name <- function(x) {
 v <- iconv(as.character(x),to='ASCII//TRANSLIT',sub='')
 tolower(gsub('[^a-z0-9]','',v))
}
norm_team <- function(x) {
 # Translate BRef's alternate abbreviations into the ones used in our game data.
 x<-toupper(trimws(as.character(x)))
 dplyr::recode(x,'BRK'='BKN','CHO'='CHA','PHO'='PHX',.default=x)
}
norm_type <- function(x) tolower(gsub('[- ]','',trimws(as.character(x))))

# Use the player rows and stints already built above.
PG <- player
ST <- player_stints
# Load each season of NBA profiles using the starting year expected by hoopR.
profile_source <- list(); bref_source <- list()
for(y in SEASONS) {
 message('STEP 3: ',y,' player profile + BRef')
 pm <- get_cached('player_master',y,function() hoopR::load_nba_stats_leaguedash(seasons=y-1L,table='player_master'))
 if(is.null(pm)) stop('Missing player_master for ',y,'. Check the download and local cache.')
 if(!all(c('player_id','player_name','season') %in% names(pm))) stop('player_master schema changed for ',y)
 # Keep regular-season totals when the source also contains playoffs or other modes.
 if('season_type' %in% names(pm)) pm <- pm[norm_type(pm$season_type)=='regularseason',,drop=FALSE]
 if('per_mode' %in% names(pm)) {
   modes<-unique(na.omit(as.character(pm$per_mode)))
   if('Totals' %in% modes) pm<-pm[as.character(pm$per_mode)=='Totals',,drop=FALSE]
 }
 pm <- pm[as.integer(pm$season)==y,,drop=FALSE]
 profile_source[[as.character(y)]] <- data.frame(
  player_id=as.integer(pm$player_id),season=as.integer(pm$season),
  player_name=as.character(pm$player_name),
  age=as_num(first_col(pm,c('age'))),
  height_inches=as_num(first_col(pm,c('bio_player_height_inches'))),
  weight=as_num(first_col(pm,c('bio_player_weight'))),
  position=as.character(first_col(pm,c('bio_player_position','player_position','position','pos'))),
  stringsAsFactors=FALSE)
  # BRef takes the ending year. Pause before a new request to avoid making
  # requests too quickly; reading a saved download needs no delay.
  bref_file<-enrichment_cache_file('bref_advanced', y)
  if(!file.exists(bref_file)) Sys.sleep(BREF_WAIT_SECONDS)
  bref_source[[as.character(y)]] <- get_cached('bref_advanced',y,
    function() hoopR::bref_players_stats(season=y,table='advanced'))
}
P <- bind_rows(profile_source)

if(anyDuplicated(P[c('player_id','season')])) stop('Duplicate NBA profile keys')
# Use the game records to look up each team's abbreviation for that season.
# Team IDs remain the main identifier because abbreviations can change over time.
TEAMMAP <- PG %>% filter(!is.na(team_abbreviation),nzchar(team_abbreviation)) %>%
  distinct(season,team_id,team_abbreviation) %>% mutate(team_abbreviation=norm_team(team_abbreviation))
team_ambig <- TEAMMAP %>% count(season,team_id,name='n') %>% filter(n>1)

if(nrow(team_ambig)) stop('Multiple abbreviations for team ID in season')

# These name mappings handle spelling differences between NBA and BRef records.
# They identify the player only; they do not bypass the games-and-minutes checks.
# Team and season are also needed for shared names such as Chris Johnson and
# Tony Mitchell, where a name alone could refer to more than one NBA player.
verified_names <- tibble::tribble(
  ~player_id, ~bref_player,
  202694L, "Marcus Morris", 203493L, "Reggie Bullock",
  1630214L, "Xavier Tillman Sr.", 2427L, "Roger Mason",
  1628476L, "Derrick Walton", 2436L, "Ronald Murray",
  1630527L, "Brandon Boston Jr."
)
additional_names <- tibble::tribble(
  ~player_id, ~bref_player,
  201609L, "Goran Dragić", 202380L, "Hamady N'Diaye",
  202419L, "Chris Johnson", 203183L, "Tony Mitchell",
  203187L, "Chris Johnson", 203318L, "Glen Rice Jr.",
  203502L, "Tony Mitchell", 204054L, "Zoran Dragić",
  1626171L, "Bobby Portis", 1628475L, "Matt Williams",
  1628982L, "Melvin Frazier", 1629668L, "Zach Norvell",
  1631219L, "John Butler", 1631257L, "Jermaine Samuels",
  1641783L, "Tristan Da Silva", 1642383L, "Walter Clayton"
)
final_names <- tibble::tribble(
  ~player_id, ~bref_player,
  200817L, "Eugene Jeter", 202353L, "Tibor Pleiß",
  203106L, "Jeff Taylor", 203543L, "Vítor Luiz Faverani",
  1626205L, "Vince Hunter", 1628249L, "Mitch Creek",
  1629053L, "Vince Edwards", 1629244L, "Cameron Reynolds",
  1630286L, "Tre Scott", 1630562L, "Matthew Hurt",
  1630612L, "RJ Nembhard Jr.", 1641842L, "Ron Holland",
  1642380L, "Adama-Alpha Bal", 1642385L, "Cui Yongxi"
)
name_overrides <- dplyr::bind_rows(verified_names, additional_names, final_names) %>% distinct()

# An optional manual_bref_name_crosswalk.csv can be placed in the source cache.
# It needs season, team_abbreviation, bref_player and nba_player_id columns.
# The built-in mappings work without this file. Requiring a team prevents a
# shared name from being assigned to the wrong player.
manual_path <- file.path(CACHE_ROOT, 'manual_bref_name_crosswalk.csv')
manual_team <- if (file.exists(manual_path)) {
  tmp <- read.csv(manual_path, stringsAsFactors=FALSE, fileEncoding='UTF-8')
  required <- c('season','team_abbreviation','bref_player','nba_player_id')
  if (!all(required %in% names(tmp)))
    stop('Manual BRef crosswalk must have columns: ',paste(required,collapse=', '))
  tmp %>% transmute(season=as.integer(season),
    team_abbreviation=norm_team(team_abbreviation),
    bref_player=as.character(bref_player),player_id=as.integer(nba_player_id))
} else {
  tibble(season=integer(),team_abbreviation=character(),bref_player=character(),player_id=integer())
}

# Try profile names only when a normalized name identifies one player in that
# season. Remove ambiguous names from this default lookup.
xwalk <- P %>% mutate(name_key=norm_name(player_name)) %>% select(player_id,season,name_key)
name_collisions <- xwalk %>% count(season,name_key,name='n') %>% filter(n>1)

xwalk <- xwalk %>% anti_join(name_collisions,by=c('season','name_key'))

# Keep individual BRef team rows here. TOT and 2TM/3TM-style rows combine teams
# and cannot describe a player's production for one particular team.
BR <- bind_rows(lapply(names(bref_source),function(s) {
 b<-bref_source[[s]];if(is.null(b)) return(NULL)
 y<-as.integer(s)
 data.frame(season=y,bref_player=as.character(first_col(b,c('player'))),
   name_key=norm_name(first_col(b,c('player'))),
   team_abbreviation=norm_team(first_col(b,c('team','team_id'))),
   bref_gp=as_num(first_col(b,c('g'))),bref_minutes=as_num(first_col(b,c('mp'))),
   bref_position=as.character(first_col(b,c('pos'))),
   bref_per=as_num(first_col(b,c('per'))),
   bref_usg_pct=as_num(first_col(b,c('usg_pct'))),
   bref_obpm=as_num(first_col(b,c('obpm'))),bref_dbpm=as_num(first_col(b,c('dbpm'))),
   bref_bpm=as_num(first_col(b,c('bpm'))),bref_vorp=as_num(first_col(b,c('vorp'))),
   bref_ws48=as_num(first_col(b,c('ws_per_48'))),
   stringsAsFactors=FALSE)
}))
if(!nrow(BR)) stop('No BRef data retrieved. Check network access and local cache.')
BR <- BR %>% filter(!team_abbreviation %in% c('TOT',paste0(2:9,'TM')))
# Apply the spelling mappings only to team-seasons found in our stint table
# and to names actually present in BRef for that same team and season.
embedded_team <- ST %>%
  mutate(team_abbreviation=norm_team(team_abbreviation)) %>%
  distinct(player_id,season,team_abbreviation) %>%
  inner_join(name_overrides,by='player_id',relationship='many-to-many') %>%
  inner_join(BR %>% distinct(season,team_abbreviation,bref_player),
             by=c('season','team_abbreviation','bref_player')) %>%
  select(season,team_abbreviation,bref_player,player_id)
manual_team <- bind_rows(embedded_team,manual_team) %>% distinct()
invalid_ids <- manual_team %>% anti_join(P %>% distinct(player_id,season),by=c('player_id','season'))

if(nrow(invalid_ids)) stop('Manual mapping references an NBA ID absent from its season')
manual_conflicts <- manual_team %>%
  group_by(season,team_abbreviation,bref_player) %>%
  summarise(n_ids=n_distinct(player_id),.groups='drop') %>% filter(n_ids>1)

if(nrow(manual_conflicts)) stop('Conflicting BRef manual team mappings')

# Match the default name first, then prefer an exact manual team-and-season match.
BID <- BR %>%
  left_join(xwalk,by=c('season','name_key'),relationship='many-to-one') %>%
  left_join(manual_team %>% rename(manual_player_id=player_id),
            by=c('season','team_abbreviation','bref_player'),relationship='many-to-one') %>%
  mutate(player_id=coalesce(manual_player_id,player_id)) %>%
  select(-manual_player_id)

BID <- BID %>% filter(!is.na(player_id))

if(anyDuplicated(BID[c('player_id','season','team_abbreviation')])) stop('Duplicate BRef team rows')

# Count how many separate stints a player had with each team that season.
# One BRef team-season record cannot describe two separate visits to that team.
team_episodes <- ST %>% count(player_id,season,team_id,name='episode_count')
# Keep the abbreviation from the stint and compare it with the lookup under
# a different column name. This catches disagreements without creating duplicate
# abbreviation columns that would interfere with the BRef join.
ST0 <- ST %>%
  mutate(team_abbreviation = norm_team(team_abbreviation)) %>%
  left_join(TEAMMAP %>% rename(lookup_team_abbreviation = team_abbreviation),
            by = c('season','team_id'), relationship = 'many-to-one') %>%
  left_join(team_episodes,by=c('player_id','season','team_id'),relationship='many-to-one')
team_map_mismatches <- ST0 %>%
  filter(!is.na(lookup_team_abbreviation),
         !is.na(team_abbreviation),
         lookup_team_abbreviation != team_abbreviation) %>%
  distinct(season,player_id,team_id,stint_index,team_abbreviation,lookup_team_abbreviation)

if(nrow(team_map_mismatches)) stop('Stint/team lookup abbreviations disagree')
ST0 <- ST0 %>%
  mutate(team_abbreviation = coalesce(team_abbreviation,lookup_team_abbreviation)) %>%
  select(-lookup_team_abbreviation)
joined <- ST0 %>% left_join(
 BID %>% select(-name_key) %>% rename(bref_name=bref_player),
 by=c('player_id','season','team_abbreviation'),relationship='many-to-one')
# In these four source records BRef lists two more games, while the minutes
# agree. Subtract two only for the validation check. Keep the original bref_gp
# and an explicit exception flag so the source value and adjustment remain visible.
# Other records still use the usual one-game and minutes tolerances.
gp_exceptions <- tibble::tribble(
  ~player_id, ~season, ~team_abbreviation, ~gp_offset,
  203136L, 2014L, 'GSW', 2L,
  203928L, 2016L, 'PHX', 2L,
  1626246L, 2019L, 'LAC', 2L,
  1626246L, 2020L, 'DAL', 2L
)
joined <- joined %>%
  left_join(gp_exceptions,by=c('player_id','season','team_abbreviation'),
            relationship='many-to-one') %>%
  mutate(gp_offset=coalesce(gp_offset,0L),
    bref_gp_validation=bref_gp-gp_offset,
    bref_gp_diff=abs(gp-bref_gp),
    bref_gp_validation_diff=abs(gp-bref_gp_validation),
    bref_mp_diff=abs(minutes-bref_minutes),
    # Accept at most one game's difference and the larger of 10 minutes or 2%
    # of BRef minutes. Separate visits to the same team need combined validation.
    bref_valid=(!is.na(bref_gp)) & episode_count==1L &
      bref_gp_validation_diff<=1 & bref_mp_diff<=pmax(10,0.02*bref_minutes),
    bref_gp_exception_applied=gp_offset>0L & bref_valid)

# Combine repeated stints for the player-team-season table. For a player who
# returns to team A, BRef's A record covers both visits together. Compare its games
# and minutes with the combined totals before accepting the advanced stats.
TEAM_SEASON <- ST0 %>%
  group_by(player_id,season,team_id,team_abbreviation) %>%
  summarise(episode_count=n(),team_season_gp=sum(gp),
            team_season_minutes=sum(minutes),.groups='drop') %>%
  left_join(BID %>% select(-name_key) %>% rename(bref_name=bref_player),
            by=c('player_id','season','team_abbreviation'),
            relationship='many-to-one') %>%
  left_join(gp_exceptions,by=c('player_id','season','team_abbreviation'),
            relationship='many-to-one') %>%
  mutate(gp_offset=coalesce(gp_offset,0L),
    bref_gp_validation=bref_gp-gp_offset,
    team_season_gp_diff=abs(team_season_gp-bref_gp_validation),
    team_season_mp_diff=abs(team_season_minutes-bref_minutes),
    bref_team_season_valid=!is.na(bref_gp) & team_season_gp_diff<=1 &
      team_season_mp_diff<=pmax(10,0.02*bref_minutes))
metric_fields <- c('bref_per','bref_usg_pct','bref_obpm','bref_dbpm','bref_bpm','bref_vorp','bref_ws48')
for(f in metric_fields)
  TEAM_SEASON[[f]][is.na(TEAM_SEASON$bref_team_season_valid) |
                    !TEAM_SEASON$bref_team_season_valid] <- NA_real_

# Leave stint-level BRef stats missing when the same team has multiple stints.
# Their combined, validated metrics belong in the player-team-season table.

for(f in metric_fields)
  joined[[f]][is.na(joined$bref_valid)|!joined$bref_valid] <- NA_real_

# Build one previous-season BRef record per player. For traded players, use
# the all-team total row; otherwise accept a single team row. Shift the season
# forward by one when joining so a game's predictors use the completed prior
# season. The 2010 rows have no 2009 baseline in this collection.
BRALL <- bind_rows(lapply(names(bref_source),function(s){
 b<-bref_source[[s]];if(is.null(b))return(NULL)
 data.frame(season=as.integer(s),bref_player=as.character(first_col(b,'player')),
    name_key=norm_name(first_col(b,'player')),
    team=norm_team(first_col(b,c('team','team_id'))),
    obpm=as_num(first_col(b,'obpm')),dbpm=as_num(first_col(b,'dbpm')),
    bpm=as_num(first_col(b,'bpm')),vorp=as_num(first_col(b,'vorp')),
    ws48=as_num(first_col(b,'ws_per_48')),stringsAsFactors=FALSE)
}))
# A shared name needs a team-specific mapping. An all-team total has no team
# to distinguish players, so use a manual name-season mapping only when it points
# to exactly one NBA ID.
manual_unique <- manual_team %>%
  group_by(season,bref_player) %>%
  filter(n_distinct(player_id)==1L) %>%
  summarise(unique_manual_id=first(player_id),.groups='drop')
PR <- BRALL %>%
  left_join(xwalk,by=c('season','name_key'),relationship='many-to-one') %>%
  left_join(manual_team %>% rename(team_manual_id=player_id,
             team=team_abbreviation),by=c('season','team','bref_player'),relationship='many-to-one') %>%
  left_join(manual_unique,by=c('season','bref_player'),relationship='many-to-one') %>%
  mutate(player_id=coalesce(team_manual_id,unique_manual_id,player_id)) %>%
  select(-team_manual_id,-unique_manual_id,-bref_player) %>%
  filter(!is.na(player_id)) %>%
  group_by(player_id,season) %>%
  filter(if(any(team %in% c('TOT',paste0(2:9,'TM'))))
    team %in% c('TOT',paste0(2:9,'TM')) else n()==1L) %>%
  ungroup()

PR <- PR %>% group_by(player_id,season) %>% filter(n()==1L) %>% ungroup() %>%
 transmute(player_id,prior_season=season+1L,prior_bref_obpm=obpm,
  prior_bref_dbpm=dbpm,prior_bref_bpm=bpm,prior_bref_vorp=vorp,prior_bref_ws48=ws48)
# Load adjusted plus-minus and statistical plus-minus measures (RAPM/SPM).
# Shift them to the following season before using them as game predictors.
impact_rows <- list()
for (y in SEASONS) {
  imp <- get_cached('impact', y, function() hoopR::load_nba_player_impact(seasons=y))
  if (is.null(imp)) next
  if (!all(c('player_id','season') %in% names(imp))) next
  if ('season_type' %in% names(imp))
    imp <- imp[norm_type(imp$season_type)=='regularseason',,drop=FALSE]
  imp <- imp[as.integer(imp$season)==y,,drop=FALSE]
  impact_rows[[as.character(y)]] <- data.frame(
    player_id=as.integer(imp$player_id), season=as.integer(imp$season),
    impact_o_adj_rapm=as_num(first_col(imp,'o_adj_rapm')),
    impact_d_adj_rapm=as_num(first_col(imp,'d_adj_rapm')),
    impact_ospm=as_num(first_col(imp,'ospm')),
    impact_dspm=as_num(first_col(imp,'dspm')))
}
IM <- bind_rows(impact_rows)
if(nrow(IM)) {
  im_dups <- IM %>% count(player_id,season,name='n') %>% filter(n>1)

  if(nrow(im_dups)) stop('Duplicate player-season impact records')
  IM_PRIOR <- IM %>% mutate(season=season+1L) %>%
    rename(prior_impact_o_adj_rapm=impact_o_adj_rapm,
           prior_impact_d_adj_rapm=impact_d_adj_rapm,
           prior_impact_ospm=impact_ospm,prior_impact_dspm=impact_dspm)
} else {
  IM_PRIOR <- data.frame(player_id=integer(),season=integer(),
    prior_impact_o_adj_rapm=double(),prior_impact_d_adj_rapm=double(),
    prior_impact_ospm=double(),prior_impact_dspm=double())
}

# Join profiles, previous-season BRef stats and previous-season impact measures
# to the stints. Season-wide RAPM describes a player's whole season, so it cannot
# be treated as a measure of one team stint. The prior-season joins are suitable
# only for dates after that earlier season has finished.
ENRICHED <- joined %>% left_join(P %>% select(-player_name),by=c('player_id','season'),relationship='many-to-one') %>%
 left_join(PR,by=c('player_id','season'='prior_season'),relationship='many-to-one') %>%
 left_join(IM_PRIOR,by=c('player_id','season'),relationship='many-to-one')

# Add bios and previous-season metrics to player games. BRef statistics from
# the game's own completed season stay in the descriptive summary tables.
GAME_ENRICHED <- PG %>% left_join(P %>% select(player_id,season,age,height_inches,weight,position),
 by=c('player_id','season'),relationship='many-to-one') %>%
 left_join(PR,by=c('player_id','season'='prior_season'),relationship='many-to-one') %>%
 left_join(IM_PRIOR,by=c('player_id','season'),relationship='many-to-one')
# 4. Assemble the four final tables
#
# Player games contain box scores, player lookbacks, bios and prior-season metrics.
# Team games contain team box scores and team lookbacks. Stints describe consecutive
# spells with a team. Player-team-seasons combine repeated spells so BRef's
# team-season statistics can be represented at the level they actually describe.
FINAL <- OUTPUT_ROOT
dir.create(FINAL, recursive=TRUE, showWarnings=FALSE)

# Only positive-minute appearances have player windows. A left join adds those
# columns while keeping the unusual zero-minute rows in the main game table;
# those rows have missing lookback values.
player_window_columns <- grep(paste0('^prior', PLAYER_WINDOW, '_'),
                              names(player_windows), value=TRUE)
player_window_keys <- c('player_id','season','game_id')
PLAYER_GAMES_FINAL <- GAME_ENRICHED %>%
  left_join(player_windows %>%
              select(all_of(c(player_window_keys,player_window_columns))),
            by=player_window_keys, relationship='one-to-one')

# The team window table already includes both box scores and earlier-game features.
TEAM_GAMES_FINAL <- team_windows

# The enriched stint table already includes the descriptive stint totals.
PLAYER_STINTS_FINAL <- ENRICHED

# Add one player profile to each combined team-season row. Completed-season
# advanced statistics remain here rather than being attached to earlier game rows.
PLAYER_TEAM_SEASONS_FINAL <- TEAM_SEASON %>%
  left_join(P, by=c('player_id','season'), relationship='many-to-one')

# Check row counts and unique keys after the joins. An unexpected many-row
# match must stop the run instead of silently duplicating observations.
stopifnot(nrow(PLAYER_GAMES_FINAL)==nrow(player),
          nrow(TEAM_GAMES_FINAL)==nrow(team),
          nrow(PLAYER_STINTS_FINAL)==nrow(player_stints),
          nrow(PLAYER_TEAM_SEASONS_FINAL)==nrow(TEAM_SEASON),
          !anyDuplicated(PLAYER_GAMES_FINAL[player_window_keys]),
          !anyDuplicated(TEAM_GAMES_FINAL[c('team_id','season','game_id')]),
          !anyDuplicated(PLAYER_STINTS_FINAL[c('player_id','season','team_id','stint_index')]),
          !anyDuplicated(PLAYER_TEAM_SEASONS_FINAL[c('player_id','season','team_id')]))

# 5. Write the finished CSVs
#
# Blank CSV cells represent missing values. Keep row names out of the files so
# each column corresponds to a dataset field. Only these four tables are exported.
exports <- list(
  nba_player_games_2010_2026 = PLAYER_GAMES_FINAL,
  nba_team_games_2010_2026 = TEAM_GAMES_FINAL,
  nba_player_stints_2010_2026 = PLAYER_STINTS_FINAL,
  nba_player_team_seasons_2010_2026 = PLAYER_TEAM_SEASONS_FINAL
)
for (nm in names(exports)) {
  write.csv(exports[[nm]], file.path(FINAL, paste0(nm,'.csv')),
            row.names=FALSE, na='')
  cat('SAVED ', nm, ': ', nrow(exports[[nm]]), ' rows; ',
      ncol(exports[[nm]]), ' columns\n', sep='')
}
cat('FOUR-TABLE PIPELINE COMPLETE: ', normalizePath(FINAL), '\n')
