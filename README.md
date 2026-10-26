# U.S. Criteria Air Pollutants, 2021–2025: An EPA AQS Statistical Analysis in R

This project uses R to clean, explore and model five years of daily air quality data from the EPA's Air Quality System (AQS) for PM2.5, ozone, NO₂, SO₂ and CO. The raw download holds 8.9 million daily records, and 5.56 million remain after cleaning. The analysis is written in R with the tidyverse and reported in R Markdown.

**Status:** Phase 1 is complete as of October 24, 2026. The daily import and cleaning (1a, 1b), the case-study site selection (1c), the hourly import (1d) and the hourly weather import (1e) are finished. The hourly data for the 16 case-study monitors (661,545 rows) reproduce all 27,747 daily maximums in the daily table, and hourly wind and temperature for the 9 case-study sites (390,791 site-hours) are ready to pair with them. Phase 2 is under way: as of October 26, 2026, the daily script `2a` covers the national picture (network change, NAAQS screening, exceedances and events, seasonality and the weekend effect) in seven figures. The Houston and Dallas–Fort Worth case study is next.

## Research question

How do pollutant levels, trends and NAAQS compliance near the Houston Ship Channel, a corridor of refineries and chemical plants in east Harris County, compare with the rest of Harris County and with Dallas–Fort Worth (Dallas and Tarrant counties), a large metro area under the same state regulator? The within-Houston comparison holds the weather constant and the Dallas–Fort Worth comparison adds a second large Texas metro, so together they help separate an industrial signal from ordinary urban pollution, framed as an emissions monitoring and regulatory compliance question.

## Methods at a glance

| Phase | Techniques | Status |
|---|---|---|
| 1. Import and cleaning | Daily data for 5 pollutants nationwide, then hourly pollutants and weather for 16 monitors at 9 Houston and Dallas–Fort Worth sites. Every file is checked against EPA's row counts, and suspect readings are flagged and kept | Done |
| 2. Exploratory analysis | National daily context done: network change, NAAQS-form screening, exceedances and events, monthly profiles, weekend effect. Case study and hourly profiles next | In progress |
| 3. Distributions | Log-normal and gamma fits, extreme-value tails, design values | Planned |
| 4. Trends and regression | Mann-Kendall and Theil-Sen trends, seasonal decomposition, multiple regression | Planned |
| 5. Report | R Markdown report (PDF and HTML) on GitHub Pages | Planned |

## Data quality highlights

- Cleaning took 8,930,992 raw rows down to 5,557,574. Most of the 37.8% removed were repeat summaries of the same monitor-day.
- Every monitoring method is checked against EPA's FRM/FEM table, and 313,057 raw T640/T640X PM2.5 rows were dropped because EPA's corrected and firmware-corrected versions replace them.
- EPA's 75% completeness rule is applied using the federal ozone-season lengths, and 22 source-checked events (storms, hurricanes, wildfire smoke and a dust storm) are labeled under one data rule that a script rechecks.
- Named assertions check each step. The saved checkpoint reloads identically and comes with a data dictionary and an MD5 manifest.
- The hourly data rebuild every daily maximum exactly: 27,747 of 27,747 monitor-days for ozone, NO₂ and SO₂, including the hour of each maximum. A site move, a method change and five weather-sensor replacements are each checked against neighboring monitors and flagged.

## Early findings (Phase 2, national)

- **NAAQS screening:** in 2023, 42.7% of five-year ozone sites and 39.0% of annual PM2.5 sites were above the standard. Over three-year windows, about 23% of ozone sites are.
- **Events:** labeled smoke, dust and storm days hold 39.9% of PM2.5 exceedance days (68.2% in 2023) and 1.2% of ozone exceedance days. EPA's own event flag covers 14% of those PM2.5 days.
- **Seasons:** NO₂ and CO peak in winter, ozone in June and PM2.5 in July. Event days made June 2023 the highest PM2.5 month (median 12.8 µg/m³).
- **Weekends:** NO₂ is 20% lower at the median site and ozone 1.3% lower. Weekend ozone rises in Los Angeles (+5.0%), consistent with VOC-limited ozone, and falls in Houston (−4.0%) and Dallas–Fort Worth (−4.8%).
- **Houston and Dallas–Fort Worth:** 6th and 8th of 353 metro areas for ozone exceedance days, and 52nd and 89th of 359 for PM2.5.

## Engineering angle

Gas readings are converted from ppb and ppm to µg/m³ with the ideal gas law, using a molar volume of RT/P = 24.465 L/mol at 25 °C and 1 atm. Compliance is screened against the NAAQS, and later phases compare traffic and industrial source signatures.

## Tech stack

R (`dplyr`, `tidyr`, `ggplot2`, `patchwork`, `trend`, `fitdistrplus`), R Markdown, Git and GitHub Pages.

## Reproduce

**Data:** daily summary files, hourly pollutant files and hourly weather files from the [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html). The data come from the U.S. Environmental Protection Agency and are in the public domain.

1. Under **Daily Data**, download the 2021–2025 zips for parameter codes 88101 (PM2.5), 44201 (ozone), 42602 (NO₂), 42401 (SO₂) and 42101 (CO). Unzip all 25 into `data/raw/daily/` and keep EPA's file names.
2. Under **Hourly Data → Criteria Gases**, download the 2021–2025 zips for 44201 (ozone), 42602 (NO₂) and 42401 (SO₂) into `data/raw/hourly/` and leave them zipped. The 15 files total 572 MiB zipped and 17.5 GiB unzipped. The files used here are the versions EPA's file list dates 2026-06-25, downloaded on 2026-10-12.
3. Under **Hourly Data → Meteorological**, download the 2021–2025 `hourly_WIND` and `hourly_TEMP` zips into `data/raw/weather/` and leave them zipped. The 10 files total 723 MiB zipped and 21.9 GiB unzipped. EPA's file list dates them 2026-06-25, and they were downloaded on 2026-10-14.
4. Install R and RStudio, then open `EPA AQS Project.Rproj`. The project file turns off restoring and saving `.RData`.
5. Run `R/0_setup.R` once to install the packages, then restart R. Then source the scripts in order, since each reads what the one before it saved: `R/1a_import_clean.R` (several minutes), `R/1b_event_checks.R`, `R/1c_site_selection.R`, `R/1d_hourly_import_clean.R`, `R/1e_weather_import_clean.R` and `R/2a_daily_eda.R` (about 2 to 3 minutes, writes the `2a_*` figures). On their first run, `1d` and `1e` each take about 10 to 15 minutes to read their zips. They cache the case-study rows in `data/hourly_filtered/` and `data/weather_filtered/` with each zip's size and modification time, so later runs take under a minute while the zips are unchanged. Each script replaces only its own rows in the data dictionary and manifest, so any one script can be rerun on its own. Charts use Inter Tight for titles, Inter for text and IBM Plex Mono for numbers and labels, from the font files in `fonts/` (SIL Open Font Licence), so no font install is needed. To see the fonts in RStudio's Plots pane, set Tools → Global Options → General → Graphics → Backend to AGG.

## Repository structure (so far)

<details>
<summary>Show folder layout</summary>

```text
EPA AQS Project/
├── data/
│   ├── raw/                # not tracked
│   │   ├── daily/          # 25 AQS daily CSVs
│   │   ├── hourly/         # 15 AQS hourly zips
│   │   └── weather/        # 10 AQS hourly wind and temperature zips
│   ├── hourly_filtered/    # not tracked: case-study rows from each hourly zip
│   ├── weather_filtered/   # not tracked: case-study rows from each weather zip
│   ├── reference/
│   │   ├── methods_all.csv
│   │   ├── events.csv                 # 22 labeled events in 203 state or county rows
│   │   ├── case_study_candidates.csv  # every eligible case-study monitor
│   │   └── case_study_sites.csv       # the picked monitors
│   └── processed/
│       ├── aqs_long_clean.rds         # cleaned daily data: 5,557,574 rows × 23 columns
│       ├── sites.rds                  # 2,038 sites: names, coordinates, CBSA
│       ├── site_coverage.rds          # years active per pollutant and site
│       ├── cleaning_log.csv           # daily rows removed at each step
│       ├── daily_validation.csv       # final checks on the daily data
│       ├── hourly_case_study.rds      # hourly data: 661,545 rows × 30 columns
│       ├── hourly_cleaning_log.csv    # hourly rows after each step
│       ├── hourly_validation.csv      # checks against the daily data
│       ├── hourly_monitor_summary.csv # coverage and quality per monitor
│       ├── hourly_raw_row_counts.csv  # rows in each of the 15 hourly zips
│       ├── hourly_weather.rds         # hourly weather: 390,791 rows × 34 columns
│       ├── weather_cleaning_log.csv   # weather rows after each step
│       ├── weather_validation.csv     # final checks on the weather data
│       ├── weather_site_summary.csv   # coverage, gaps, calms and prevailing wind per site
│       ├── weather_sensor_check.csv   # sensor history and replacement checks per site
│       ├── weather_raw_row_counts.csv # rows in each of the 10 weather zips
│       ├── data_dictionary.csv        # every saved column: type and meaning
│       └── checkpoint_manifest.csv    # rows, size and MD5 checksum per .rds file
├── R/
│   ├── 0_setup.R                 # installs or upgrades required packages
│   ├── 1a_import_clean.R         # daily import, cleaning and validation
│   ├── 1b_event_checks.R         # verifies events.csv against the data
│   ├── 1c_site_selection.R       # picks the case-study sites
│   ├── 1d_hourly_import_clean.R  # hourly import, flags and validation
│   ├── 1e_weather_import_clean.R # hourly weather import, flags and validation
│   ├── 2a_daily_eda.R            # daily exploratory analysis (sections 1 to 6 done; case study next)
│   └── utils.R                   # shared helpers: study years, calendar, events, zip reading, saving, chart theme
├── fonts/                  # chart fonts (Inter, Inter Tight, IBM Plex Mono) and their licences
├── figures/
│   ├── case_study_sites.png      # map of the case-study monitors
│   ├── 2a_network.png            # how the national monitoring network changed
│   ├── 2a_naaqs_form.png         # sites against each air quality standard, by year
│   ├── 2a_exceedances.png        # exceedance days per 1,000, split by event days
│   ├── 2a_exceedance_metros.png  # top 10 metros by exceedance days for PM2.5 and ozone
│   ├── 2a_monthly_profile.png    # typical year per pollutant and each site's peak month
│   ├── 2a_monthly_series.png     # 60 monthly medians for PM2.5 and ozone, with and without event days
│   └── 2a_weekend.png            # weekend against weekday levels, NO2 against ozone, metros where ozone rises
├── docs/                   # GitHub Pages output and methodology
│   └── methodology.md
├── EPA AQS Project.Rproj
└── README.md
```

</details>

## Limitations

- **Changing network:** Between 2021 and 2025, PM2.5 rows grew 23.6% and SO₂ and CO rows fell about 18%, so trend analyses use only sites with data in all five years.
- **Screening values:** Every year is judged against today's standards, including the 9.0 µg/m³ annual PM2.5 standard set in February 2024. Each site-year uses its standard's statistic and rounding, and a three-year average gives a design-value screen. These are screening values: EPA's official design values add data-handling rules that are not reproduced here.
- **Weather:** Seasonal and weekend comparisons do not control for weather. Five years of data smooth it, but a weather bias cannot be ruled out.
- **T640 corrections:** 1,941 site-days in 2024–2025 had no corrected version and no other PM2.5 reading, so they were lost. EPA's correction is still under review, and a 2026 request for correction from Georgia EPD reports leftover bias at some sites.
- **Coverage:** Monitors aren't placed at random, and the weather in coastal Houston and inland Dallas–Fort Worth isn't matched. The Ship Channel versus other Houston comparison is there to offset this, since both groups share the same weather.

## Author

Yousef Shamsaldeen | [LinkedIn](https://www.linkedin.com/in/yshamsaldeen/)
