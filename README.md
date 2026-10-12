# U.S. Criteria Air Pollutants, 2021–2025: An EPA AQS Statistical Analysis in R

This project uses R to clean, explore and model five years of daily air quality data from the EPA's Air Quality System (AQS) for PM2.5, ozone, NO₂, SO₂ and CO. The raw download holds 8.9 million daily records, and 5.56 million remain after cleaning. The analysis is written in R with the tidyverse and reported in R Markdown.

**Status:** Phase 1 is nearly complete. The daily import and cleaning (1a, 1b) and the case-study site selection (1c) are done. The hourly import (1d) is in progress: all 15 hourly files have been read and filtered down to the 16 case-study monitors (661,545 hourly rows), and the values have been inspected. Cleaning rules, validation against the daily data and the saved checkpoint come next, followed by exploratory analysis in Phase 2.

## Research question

How do pollutant levels, trends and NAAQS compliance near the Houston Ship Channel, a corridor of refineries and chemical plants in east Harris County, compare with the rest of Harris County and with Dallas–Fort Worth (Dallas and Tarrant counties), a large metro area under the same state regulator? The within-Houston comparison holds the weather constant and the Dallas–Fort Worth comparison adds a second large Texas metro, so together they help separate an industrial signal from ordinary urban pollution, framed as an emissions monitoring and regulatory compliance question.

## Methods at a glance

| Phase | Techniques | Status |
|---|---|---|
| 1a, 1b. Import and cleaning (daily) | Method checks against EPA's FRM/FEM list, EPA's 75% completeness rule, ideal-gas unit conversion, event labels | Done |
| 1c. Case-study site selection | Five-year monitors in Harris, Dallas and Tarrant counties, split into Ship Channel, other Houston and Dallas–Fort Worth groups, with collocated ozone and NO₂ sites ranked by completeness (one per county in Dallas–Fort Worth): 16 monitors at 9 sites | Done |
| 1d. Hourly import and cleaning | Hourly ozone, NO₂ and SO₂ for the case-study sites, read from the zips in 1-million-row chunks and filtered one file at a time, with every row count checked against EPA's file list. Cleaning and validation against the daily data are still to come | In progress |
| 2. Exploratory analysis | Summary statistics, seasonal and daily (diurnal) profiles, site comparisons, NAAQS exceedance screening | Planned |
| 3. Distributions | Log-normal and gamma fits, Q-Q plots, extreme-value tails, design values | Planned |
| 4. Trends and regression | Mann-Kendall and Theil-Sen trends, seasonal decomposition, multiple regression, residual diagnostics | Planned |
| 5. Report | R Markdown report (PDF and HTML) on GitHub Pages | Planned |

## Data quality highlights

- Cleaning took 8,930,992 raw rows down to 5,557,574. Most of the 37.8% removed were repeat summaries of the same monitor-day.
- Every monitoring method is checked against EPA's FRM/FEM table, and 313,057 raw T640/T640X PM2.5 rows were dropped because EPA's corrected and firmware-corrected versions replace them.
- EPA's 75% completeness rule is applied using the federal ozone-season lengths, and 8 verified events are labeled.
- Named assertions check each step. The saved checkpoint reloads identically and comes with a data dictionary and an MD5 manifest.

## Engineering angle

Gas readings are converted from ppb and ppm to µg/m³ with the ideal gas law, using a molar volume of RT/P = 24.465 L/mol at 25 °C and 1 atm. Compliance is screened against the NAAQS, and later phases compare traffic and industrial source signatures.

## Tech stack

R (`dplyr`, `tidyr`, `ggplot2`, `trend`, `fitdistrplus`), R Markdown, Git and GitHub Pages.

## Reproduce

**Data:** daily summary files and hourly files from the [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html). The data come from the U.S. Environmental Protection Agency and are in the public domain.

1. Under **Daily Data**, download the 2021–2025 zips for parameter codes 88101 (PM2.5), 44201 (ozone), 42602 (NO₂), 42401 (SO₂) and 42101 (CO). Unzip all 25 into `data/raw/daily/` and keep EPA's file names.
2. Under **Hourly Data → Criteria Gases**, download the 2021–2025 zips for 44201 (ozone), 42602 (NO₂) and 42401 (SO₂) into `data/raw/hourly/` and leave them zipped. The 15 files total 572 MiB zipped and 17.5 GiB unzipped. The files used here are the versions EPA's file list dates 2026-06-25, downloaded on 2026-10-12.
3. Install R and RStudio with `dplyr` 1.2.0 or later and `tidyr` 1.3.0 or later. Under **Tools → Global Options → General**, turn off restoring and saving `.RData`.
4. Run `R/0_setup.R` once and restart R. Then source `R/1a_import_clean.R`, which takes several minutes, followed by `R/1b_event_checks.R`, `R/1c_site_selection.R` and `R/1d_hourly_import_clean.R`. The last script is in progress and currently runs through reading, filtering and inspecting the hourly data.

## Repository structure (so far)

<details>
<summary>Show folder layout</summary>

```text
EPA AQS Project/
├── data/
│   ├── raw/                # not tracked
│   │   ├── daily/          # 25 AQS daily CSVs
│   │   └── hourly/         # 15 AQS hourly zips
│   ├── hourly_filtered/    # not tracked: case-study rows from each hourly zip
│   ├── reference/
│   │   ├── methods_all.csv
│   │   ├── events.csv
│   │   ├── case_study_candidates.csv  # every eligible case-study monitor
│   │   └── case_study_sites.csv       # the picked monitors
│   └── processed/
│       ├── aqs_long_clean.rds         # cleaned daily data: 5,557,574 rows × 23 columns
│       ├── sites.rds                  # 2,038 sites: names, coordinates, CBSA
│       ├── site_coverage.rds          # years active per pollutant and site
│       ├── cleaning_log.rds           # rows removed at each step
│       ├── hourly_raw_row_counts.csv  # rows in each of the 15 hourly zips
│       ├── data_dictionary.csv        # every saved column: type and meaning
│       └── checkpoint_manifest.csv    # rows, size and MD5 checksum per file
├── R/
│   ├── 0_setup.R                 # installs or upgrades required packages
│   ├── 1a_import_clean.R         # daily import, cleaning and validation
│   ├── 1b_event_checks.R         # verifies events.csv against the data
│   ├── 1c_site_selection.R       # picks the case-study sites
│   ├── 1d_hourly_import_clean.R  # in progress: hourly import for the case-study sites
│   └── utils.R                   # log_step(), region_lookup, event_medians()
├── report/                 # R Markdown report (Phase 5)
├── figures/
│   └── case_study_sites.png      # map of the case-study monitors
├── docs/                   # GitHub Pages output and methodology
│   └── methodology.md
├── EPA AQS Project.Rproj
└── README.md
```

</details>

## Limitations

- **Changing network:** Between 2021 and 2025, PM2.5 rows grew 23.6% and SO₂ and CO rows fell about 18%, so trend analyses use only sites with data in all five years.
- **Simplified exceedances:** Daily values are compared directly with today's standards in every year, including the 9.0 µg/m³ annual PM2.5 standard set in February 2024. EPA's official design values use a different calculation.
- **T640 corrections:** 1,941 site-days in 2024–2025 had no corrected version and no other PM2.5 reading, so they were lost. EPA's correction is still under review, and a 2026 request for correction from Georgia EPD reports leftover bias at some sites.
- **Coverage:** Monitors aren't placed at random, and the weather in coastal Houston and inland Dallas–Fort Worth isn't matched. The Ship Channel versus other Houston comparison is there to offset this, since both groups share the same weather.

## Author

Yousef Shamsaldeen | [LinkedIn](https://www.linkedin.com/in/yshamsaldeen/)
