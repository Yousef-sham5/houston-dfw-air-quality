# U.S. Criteria Air Pollutants, 2021–2025: An EPA AQS Statistical Analysis in R

This project uses R to clean, explore and model five years of air quality data from the EPA's Air Quality System (AQS) for PM2.5, ozone, NO₂, SO₂ and CO. The national daily data hold 8.9 million records, 5.56 million after cleaning. Hourly pollutant and weather data cover 16 case-study monitors in Houston and Dallas–Fort Worth (661,545 monitor-hours).

**Status:** Phases 1 (import and cleaning) and 2 (exploratory analysis) are complete, with 26 figures: 7 national (`2a`), 8 for the daily case study (`2b`) and 11 for the hourly case study (`2c`). Phase 3 (distributions) is next.

## Research question

How do pollutant levels, trends and NAAQS compliance near the Houston Ship Channel, a corridor of refineries and chemical plants in east Harris County, compare with the rest of Harris County and with Dallas–Fort Worth (Dallas and Tarrant counties)? Ship Channel sites are Harris County monitors within 7.5 km of the channel. Comparing within Houston holds the weather constant, and Dallas–Fort Worth adds a second large Texas metro under the same regulator, which helps separate an industrial signal from ordinary urban pollution.

## Methods at a glance

| Phase | Techniques | Status |
|---|---|---|
| 1. Import and cleaning | Daily data for 5 pollutants nationwide, then hourly pollutants and weather for 16 monitors at 9 Houston and Dallas–Fort Worth sites. Every file is checked against EPA's row counts, and suspect readings are flagged and kept | Done |
| 2. Exploratory analysis | National NAAQS screening, events, seasons and weekends; then same-day group differences, daily cycles, an Ox (ozone + NO₂) test, SO₂ spikes, calm air and pollution roses. Block-bootstrap ranges, every result rerun under every check | Done |
| 3. Distributions | Log-normal and gamma fits, extreme-value tails, design values | Planned |
| 4. Trends and regression | Mann-Kendall and Theil-Sen trends, seasonal decomposition, multiple regression | Planned |
| 5. Report | R Markdown report (PDF and HTML) on GitHub Pages | Planned |

## Data quality highlights

- Cleaning took 8,930,992 raw rows down to 5,557,574. Most of the 37.8% removed were repeat summaries of the same monitor-day.
- Every method is checked against EPA's FRM/FEM table; 313,057 raw T640/T640X PM2.5 rows were dropped because EPA's corrected versions replace them.
- EPA's 75% completeness rule uses the federal ozone-season lengths, and 22 source-checked events (storms, wildfire smoke, a dust storm) are labelled under one rule a script rechecks.
- Named assertions check each step, and every saved file is listed in a data dictionary, with an MD5 manifest for the checkpoints.
- The hourly data rebuild all 27,747 daily maximums exactly. A site move, a method change and five weather-sensor replacements are checked against neighbouring monitors and flagged.

## Early findings (Phase 2, national)

- **NAAQS screening:** in 2023, 42.7% of five-year ozone sites and 39.0% of annual PM2.5 sites were above the standard; over three-year windows, about 23% of ozone sites are.
- **Events:** labelled smoke, dust and storm days hold 39.9% of PM2.5 exceedance days (68.2% in 2023). EPA's own event flag covers 14% of those days.
- **Seasons:** NO₂ and CO peak in winter, ozone in June and PM2.5 in July; smoke made June 2023 the highest PM2.5 month.
- **Weekends:** NO₂ is 20% lower at the median site. Weekend ozone rises in Los Angeles (+5.0%), consistent with VOC-limited ozone, and falls in Houston (−4.0%) and Dallas–Fort Worth (−4.8%).
- **Houston and Dallas–Fort Worth** rank 6th and 8th of the 353 metros with an ozone exceedance, by exceedance site-days, a count that favours large networks.

## Early findings (Phase 2, daily case study)

Same-day differences between groups, with 95% block-bootstrap ranges, rerun under every check that changes them.

- **NO₂:** the Ship Channel runs 1.15 ppb above Houston other (95% range 0.81 to 1.41) in every year and under every check, consistent with nearby NOx sources. NO₂ falls with distance from the channel (Spearman −0.72, p = 0.02, with four-year sites; p = 0.08 without the farthest site).
- **Ozone:** the Ship Channel runs 0.97 ppb below Houston other, consistent with fresh NO using up ozone; the gap disappears under the older memo-list grouping. Houston runs 4.0 ppb below Dallas–Fort Worth.
- **SO₂:** the 0.13 ppb gap is far under the 2 ppb detection limit, so SO₂ is read through spikes instead.
- **PM2.5:** no clear gap within Houston (ranges include zero in 3 of 6 runs), consistent with regional PM2.5.

## Early findings (Phase 2, hourly case study)

Two ozone and NO₂ sites per group; for SO₂, three Ship Channel sites and Croquet. Ordinary hours only (valid days, no Uri, Beryl or wildfire hours).

- **Every hour:** Ship Channel NO₂ is higher and its ozone lower than Houston other at all 24 hours, with 95% ranges clear of zero. Both gaps are widest late in the day (NO₂ +1.9 ppb, ozone −3.0 ppb).
- **Why ozone is lower (Ox):** adding NO₂ back to ozone closes 52% of the Ship Channel's ozone gap over the year, all of it in winter, and 99% without Harvard Street, the Houston other site nearest the channel. That is consistent with fresh NO using up ozone.
- **Weekend mornings:** 6 to 8 am NO₂ falls 36% on weekends at the Ship Channel, against 42% in Houston other and 50% in Dallas–Fort Worth, consistent with more sources that run all week.
- **SO₂ spikes (an hour at 5 ppb or more):** 96% of Croquet's fall between 9 am and 6 pm, mostly in summer. Spikes last about an hour and seldom hit two sites at once, consistent with local plumes, and Deer Park #2 spike hours carry 7.5 ppb more NO₂ (5.1 to 10.0).
- **Calm air:** Houston is calm 4 to 6 times as often as Dallas–Fort Worth, mostly overnight. At the same hour and month, calm hours carry 3.0 to 6.8 ppb more NO₂ and 3.8 to 9.0 ppb less ozone at every site.
- **Wind directions:** NO₂ runs highest in east wind at all four Houston sites. Croquet's SO₂ spikes come from the southwest (75% of spikes from 11% of its hours), away from the channel; Park Place's come from the channel side (77% from 30%).
- **The rest of the ozone gap:** without Harvard Street, the Ox gap is −2.2 ppb in wind from the channel and about zero otherwise, consistent with ozone forming in channel air as it crosses Houston.
- **Checks:** all ten headline findings hold under every check that applies and with a second random seed (figure 2C.11).

## Engineering angle

Gas readings are converted to µg/m³ with the ideal gas law (RT/P = 24.465 L/mol at 25 °C and 1 atm), and compliance is screened against the NAAQS. The hourly case study separates traffic and industrial signatures by timing and wind direction, and uses the NO + O₃ → NO₂ + O₂ balance (Ox) to test why ozone is lower near the channel.

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
│       ├── phase2/         # CSV records from 2a, 2b and 2c
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
│   └── phase2/             # 2a.01_ to 2a.07_ (national), 2b.01_ to 2b.08_ (daily case study), 2c.01_ to 2c.11_ (hourly)
├── fonts/                  # chart fonts and their licences
├── docs/                   # GitHub Pages output and methodology.md
├── EPA AQS Project.Rproj
├── LICENSE                 # MIT
└── README.md
```

</details>

## Limitations

- **Changing network:** from 2021 to 2025, PM2.5 rows grew 23.6% and SO₂ and CO rows fell about 18%, so trend analyses use only sites with data in all five years.
- **Screening values:** every year is judged against today's standards, including the 9.0 µg/m³ annual PM2.5 standard set in 2024. EPA's official design values add rules not reproduced here.
- **Weather:** seasonal and weekend comparisons do not control for weather, so a weather bias cannot be ruled out.
- **T640 corrections:** 1,941 site-days in 2024–2025 had no corrected version and no other PM2.5 reading, so they were lost.
- **Coverage:** monitors aren't placed at random, and coastal Houston and inland Dallas–Fort Worth have different weather. Comparing within Houston offsets this.
- **Site groups:** distance to the channel stands in for distance to the plants along it. Results are rerun without sites 7.5 to 15 km away and with the earlier TCEQ memo grouping.
- **Hourly groups are small:** two ozone and NO₂ sites per group, so hourly results describe these sites. Without Harvard Street, Houston other is Bayland Park alone, and the Ox result moves from 52% to 99%.
- **Wind direction:** a direction points toward a source without proving it, since each wind direction also brings its own kind of air. Harvard Street has no wind sensor and uses Croquet's.

## Author

Yousef Shamsaldeen | [LinkedIn](https://www.linkedin.com/in/yshamsaldeen/)
