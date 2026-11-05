# NBA data preparation

NBA regular-season datasets for seasons ending in 2010 through 2026. The year
identifies the end of the season: 2010 means 2009-10.

## Project files

```text
6404_nba_data_processing/
  load_base_data_final.R
  datasets/
    nba_player_games_2010_2026.csv
    nba_team_games_2010_2026.csv
    nba_player_stints_2010_2026.csv
    nba_player_team_seasons_2010_2026.csv
```

| Dataset | Contents | Rows |
| --- | --- | ---: |
| Player games | Box scores, previous-40-appearance stats, bios and prior-season metrics | 429,172 |
| Team games | Team box scores, estimated ratings and previous-40-game stats | 40,696 |
| Player stints | Consecutive spells with a team and validated advanced statistics | 10,034 |
| Player-team seasons | Combined team-season records, including repeated spells with the same team | 10,025 |

The preprocessing script uses hoopR to obtain NBA schedules, box scores, player
profiles, Basketball Reference advanced statistics and player impact measures.
Player and team lookbacks exclude the current game. Completed-season advanced
statistics belong to the descriptive summary tables; game-level season metrics
come from the previous season.

## Get the data

Install [Git LFS](https://git-lfs.com/) before cloning, then run:

```powershell
git lfs install
git clone https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git
cd YOUR_REPOSITORY
git lfs pull
```

The player-games CSV uses Git LFS because it exceeds GitHub's regular Git file
size limit. The other three CSVs are stored in regular Git. With Git LFS installed,
the local player-games file is a normal CSV ready for analysis.

## Rebuild the datasets

Install R and these packages in an R session:

```r
install.packages(c("hoopR", "dplyr", "tibble"))
```

From the repository root, run:

```powershell
Rscript 6404_nba_data_processing/load_base_data_final.R
```

The script writes the four final CSVs beside the script in `datasets/` and keeps
downloaded inputs under `.nba_preprocessing_cache/sources/`. The cache is excluded
from Git. Its subfolders are `schedule`, `players`, `teams`, `player_profiles`,
`bref_advanced` and `player_impact`.

A fresh clone has no download cache, so rebuilding requires internet access and
available upstream sources. Rebuilding with the existing saved inputs was
validated to reproduce all four CSV files byte for byte after the script cleanup.
New downloads may differ if upstream data changes. The row counts above describe
the included snapshot.

## Upload this local repository to GitHub

Create an empty GitHub repository without adding a README, license or gitignore.
From this folder, replace the placeholder URL and run:

```powershell
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git
git push -u origin main
```

The first commit is already created. Git LFS uploads the large CSV during the
push. For subsequent changes:

```powershell
git add .
git commit -m "Describe your changes"
git push
```
