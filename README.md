# NBA Trade Model

## Data

NBA regular-season data for seasons ending in 2010 through 2026, collected from
NBA and Basketball Reference sources using `hoopR`. The year refers to the end
of the season: 2010 means 2009-10.

| Dataset | Contents | Rows |
| --- | --- | ---: |
| Player games | Box scores, previous-40-appearance stats, bios and prior-season metrics | 429,172 |
| Team games | Team box scores, estimated ratings and previous-40-game stats | 40,696 |
| Player stints | Consecutive spells with a team and validated advanced statistics | 10,034 |
| Player-team seasons | Combined team-season records, including repeated spells with the same team | 10,025 |

### Get the data

The finished CSVs are in [`data collection/datasets/`](data%20collection/datasets/).

To generate the CSVs yourself, open R or RStudio with this project folder as your
working directory:

1. Install the required packages once:

   ```r
   install.packages(c("hoopR", "dplyr", "tibble"))
   ```

2. Run the preprocessing script:

   ```r
   source("data collection/load_base_data_final.R", encoding = "UTF-8")
   ```

The script saves all four CSVs in `data collection/datasets/`. The first
run needs internet access; later runs reuse the downloaded source cache.
