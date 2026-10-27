# U.S. Criteria Air Pollutants, 2021–2025: An EPA AQS Statistical Analysis in R

This project uses R to clean, explore and model five years of air quality data from the EPA's Air Quality System (AQS) for PM2.5, ozone, NO₂, SO₂ and CO. The national daily data hold 8.9 million records, 5.56 million after cleaning. Hourly pollutant and weather data cover 16 case-study monitors in Houston and Dallas–Fort Worth (661,545 monitor-hours).

**Status:** Phase 1 (import and cleaning) is complete. Phase 2 is under way: `2a` covers the national picture in seven figures, the daily Houston and Dallas–Fort Worth case study (`2b`) in eight, and the hourly case study (`2c`) in five so far: coverage, daily cycles, ozone and NO₂ together, and SO₂ spike hours. Wind and source directions are next.

## Research question

How do pollutant levels, trends and NAAQS compliance near the Houston Ship Channel, a corridor of refineries and chemical plants in east Harris County, compare with the rest of Harris County and with Dallas–Fort Worth (Dallas and Tarrant counties)? Ship Channel sites are the Harris County monitors within 7.5 km of the channel. The within-Houston comparison holds the weather constant, and Dallas–Fort Worth adds a second large Texas metro under the same state regulator. Together they help separate an industrial signal from ordinary urban pollution, framed as an emissions monitoring and regulatory compliance question.

## Methods at a glance

| Phase | Techniques | Status |
|---|---|---|
| 1. Import and cleaning | Daily data for 5 pollutants nationwide, then hourly pollutants and weather for 16 monitors at 9 Houston and Dallas–Fort Worth sites. Every file is checked against EPA's row counts, and suspect readings are flagged and kept | Done |
| 2. Exploratory analysis | National daily context and the daily case study done: NAAQS-form screening, exceedances and events, seasons, weekend effect, and same-day group differences rerun under every check. Hourly case study under way: daily cycles, weekend mornings, an Ox (ozone + NO₂) test and SO₂ spike timing with a plume test, all with bootstrap ranges | In progress |
| 3. Distributions | Log-normal and gamma fits, extreme-value tails, design values | Planned |
| 4. Trends and regression | Mann-Kendall and Theil-Sen trends, seasonal decomposition, multiple regression | Planned |
| 5. Report | R Markdown report (PDF and HTML) on GitHub Pages | Planned |

## Data quality highlights

- Cleaning took 8,930,992 raw rows down to 5,557,574. Most of the 37.8% removed were repeat summaries of the same monitor-day.
- Every monitoring method is checked against EPA's FRM/FEM table, and 313,057 raw T640/T640X PM2.5 rows were dropped because EPA's corrected and firmware-corrected versions replace them.
- EPA's 75% completeness rule is applied using the federal ozone-season lengths, and 22 source-checked events (storms, hurricanes, wildfire smoke and a dust storm) are labelled under one data rule that a script rechecks.
- Named assertions check each step. The saved checkpoint reloads identically and comes with a data dictionary and an MD5 manifest.
- The hourly data rebuild every daily maximum exactly: 27,747 of 27,747 monitor-days for ozone, NO₂ and SO₂, including the hour of each maximum. A site move, a method change and five weather-sensor replacements are each checked against neighbouring monitors and flagged.

## Early findings (Phase 2, national)

- **NAAQS screening:** in 2023, 42.7% of five-year ozone sites and 39.0% of annual PM2.5 sites were above the standard. Over three-year windows, about 23% of ozone sites are.
- **Events:** labelled smoke, dust and storm days hold 39.9% of PM2.5 exceedance days (68.2% in 2023) and 1.2% of ozone exceedance days. EPA's own event flag covers 14% of those PM2.5 days.
- **Seasons:** NO₂ and CO peak in winter, ozone in June and PM2.5 in July. Event days made June 2023 the highest PM2.5 month (median 12.8 µg/m³).
- **Weekends:** NO₂ is 20% lower at the median site and ozone 1.3% lower. Weekend ozone rises in Los Angeles (+5.0%), consistent with VOC-limited ozone, and falls in Houston (−4.0%) and Dallas–Fort Worth (−4.8%).
- **Houston and Dallas–Fort Worth:** 6th and 8th of 353 metro areas for ozone exceedance site-days, and 52nd and 89th of 359 for PM2.5. Site-days are summed over each metro's monitors, so larger networks rank higher.

## Early findings (Phase 2, daily case study)

Same-day differences between groups, with 95% ranges from a block bootstrap, each rerun under every site and day check that changes the comparison.

- **NO₂:** the Ship Channel runs 1.15 ppb above Houston other on the same day (95% range 0.81 to 1.41), in every year and under every check, consistent with nearby NOx sources. NO₂ falls with distance from the channel, most clearly once four-year sites are added (Spearman −0.72, p = 0.02).
- **Ozone:** the Ship Channel runs 0.97 ppb below Houston other, consistent with fresh NO using up ozone. The gap disappears under the older memo-list grouping. Houston runs 4.0 ppb below Dallas–Fort Worth.
- **SO₂:** the Ship Channel runs 0.13 ppb higher, well under the 2 ppb detection limit of most of its monitors, so read through spikes instead. Croquet, 22 km from the channel, spikes more often than the average Ship Channel site in every year, mostly in summer.
- **PM2.5:** no clear gap within Houston: ranges include zero in 3 of 6 runs, and the main range reaches zero with a second seed. This is consistent with PM2.5 spread over the region.

## Early findings (Phase 2, hourly case study)

Two ozone and NO₂ sites per group; for SO₂, three Ship Channel sites and Croquet. Ordinary hours only (valid days, no Uri, Beryl or wildfire hours), in local standard time.

- **Every hour:** Ship Channel NO₂ is higher and its ozone lower than Houston other at all 24 hours of the day, with 95% ranges clear of zero, under every check. Both gaps are widest late in the day: NO₂ +1.9 ppb at 17:00 and ozone −3.0 ppb at 16:00.
- **Why ozone is lower (Ox):** adding NO₂ back to ozone closes 52% of the Ship Channel's ozone gap over the year, all of it in winter, and 99% without Harvard Street, the Houston other site nearest the channel. That is consistent with fresh NO using up ozone near the channel.
- **Weekend mornings:** from April to October, 6 to 8 am NO₂ on weekends is 0.64 of the weekday level at the Ship Channel, against 0.58 in Houston other and 0.50 in Dallas–Fort Worth. That is consistent with more Ship Channel NO₂ from sources that run all week.
- **SO₂ spikes (an hour at 5 ppb or more):**
  - **Croquet:** 96% of its spike hours fall between 9 am and 6 pm, and its summer rate is 4 times any other season's. That is consistent with a raised plume mixed down by daytime heating.
  - **Every site:** spikes last a median of one hour, only 16 of 289 Ship Channel spike hours hit two sites at once, and spike rates drop far less on weekends than NO₂ does. That is consistent with local industrial plumes.
  - **Deer Park #2:** NO₂ runs 7.5 ppb higher on its spike hours (95% range 5.1 to 10.0), so the plumes also carry nitrogen oxides.

## Engineering angle

Gas readings are converted from ppb and ppm to µg/m³ with the ideal gas law, using a molar volume of RT/P = 24.465 L/mol at 25 °C and 1 atm. Compliance is screened against the NAAQS. The hourly case study compares traffic and industrial source signatures by timing (rush hours, weekends, daytime plumes), and the wind sections add source directions.

## Tech stack

R (`dplyr`, `tidyr`, `readr`, `lubridate`, `ggplot2`, `patchwork`; `trend` and `fitdistrplus` planned for Phases 3 and 4), R Markdown, Git and GitHub Pages.

## Reproduce

Data come from the [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html) (public domain; file versions dated 2026-06-25).

1. **Daily Data:** the 2021–2025 zips for 88101 (PM2.5), 44201 (ozone), 42602 (NO₂), 42401 (SO₂) and 42101 (CO), unzipped into `data/raw/daily/`.
2. **Hourly Data:** the 2021–2025 Criteria Gases zips for 44201, 42602 and 42401 into `data/raw/hourly/`, and the Meteorological `hourly_WIND` and `hourly_TEMP` zips into `data/raw/weather/`. Leave both zipped.
3. Open `EPA AQS Project.Rproj`, run `R/0_setup.R` once and restart R.
4. Source the scripts in order: `1a`, `1b`, `1c`, `1d`, `1e`, `2a`, `2b`, `2c`. The first runs of `1d` and `1e` take 10 to 15 minutes each; later runs reuse a cache.

Chart fonts are bundled in `fonts/`. To see them in RStudio's Plots pane, set Tools → Global Options → General → Graphics → Backend to AGG.

## Repository structure (so far)

<details>
<summary>Show folder layout</summary>

```text
EPA AQS Project/
├── data/
│   ├── raw/                # not tracked: daily CSVs, hourly and weather zips
│   ├── hourly_filtered/    # not tracked: cache of case-study rows from each hourly zip
│   ├── weather_filtered/   # not tracked: cache of case-study rows from each weather zip
│   ├── reference/          # method table, events, Ship Channel shape, site groups and picks
│   └── processed/          # checkpoints (.rds), data dictionary and manifest
│       ├── phase1/         # CSV records from 1a, 1d and 1e
│       ├── phase2/         # CSV records from 2b and 2c
│       ├── aqs_long_clean.rds
│       ├── sites.rds
│       ├── site_coverage.rds
│       ├── daily_case_study*.rds
│       ├── hourly_case_study.rds
│       ├── hourly_weather.rds
│       ├── data_dictionary.csv
│       └── checkpoint_manifest.csv
├── R/                      # scripts, run in order from 0 to 2c
│   ├── 0_setup.R
│   ├── 1a_import_clean.R
│   ├── 1b_event_checks.R
│   ├── 1c_site_selection.R
│   ├── 1d_hourly_import_clean.R
│   ├── 1e_weather_import_clean.R
│   ├── 2a_daily_eda.R
│   ├── 2b_daily_case_study.R
│   ├── 2c_hourly_eda.R
│   └── utils.R
├── figures/                # one folder per phase, files numbered in figure order
│   ├── phase1/             # case-study site map
│   └── phase2/             # 2a.01_ to 2a.07_ (national), 2b.01_ to 2b.08_ (daily case study), 2c.01_ to 2c.05_ (hourly)
├── fonts/                  # chart fonts and their licences
├── docs/                   # GitHub Pages output and methodology.md
├── EPA AQS Project.Rproj
├── LICENSE                 # MIT
└── README.md
```

</details>

## Limitations

- **Changing network:** from 2021 to 2025, PM2.5 rows grew 23.6% and SO₂ and CO rows fell about 18%, so trend analyses use only sites with data in all five years.
- **Screening values:** every year is judged against today's standards, including the 9.0 µg/m³ annual PM2.5 standard set in February 2024. These are screening values; EPA's official design values add data-handling rules not reproduced here.
- **Weather:** seasonal and weekend comparisons do not control for weather. Five years of data smooth it, but a weather bias cannot be ruled out.
- **T640 corrections:** 1,941 site-days in 2024–2025 had no corrected version and no other PM2.5 reading, so they were lost. EPA's correction is still under review.
- **Coverage:** monitors aren't placed at random, and coastal Houston and inland Dallas–Fort Worth have different weather. The Ship Channel against Houston other comparison offsets this, since both groups share the same weather.
- **Site groups:** distance to the channel stands in for distance to the plants along it. Results are rerun without sites 7.5 to 15 km away and with the earlier TCEQ memo grouping.
- **Hourly groups are small:** two ozone and NO₂ sites per group, so hourly results describe these sites. Without Harvard Street, Houston other is Bayland Park alone, and the Ox result moves from 52% to 99%.

## Author

Yousef Shamsaldeen | [LinkedIn](https://www.linkedin.com/in/yshamsaldeen/)
