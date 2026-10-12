# U.S. Criteria Air Pollutants, 2021–2025: An EPA AQS Statistical Analysis in R

This project uses R to clean, explore and model five years of daily air quality data from the EPA's Air Quality System (AQS) for PM2.5, ozone, NO₂, SO₂ and CO. The raw download holds 8.9 million daily records, and 5.56 million remain after cleaning. The analysis is written in R with the tidyverse and reported in R Markdown.

**Status:** Phase 1, the daily import and cleaning, is complete. Next up is the hourly import for the case-study sites, followed by exploratory analysis in Phase 2.

## Research question

How do pollutant levels, trends and NAAQS compliance near the Houston Ship Channel in Harris County, a corridor of refineries and chemical plants, compare with Dallas–Fort Worth (Dallas and Tarrant counties), a large metro area that serves as the control? Comparing the two helps separate an industrial signal from ordinary urban pollution, and the project treats it as an emissions monitoring and regulatory compliance question.

## Methods at a glance

| Phase | Techniques | Status |
|---|---|---|
| 1a, 1b. Import and cleaning (daily) | Method checks against EPA's FRM/FEM list, EPA's 75% completeness rule, ideal-gas unit conversion, event labels | Done |
| 1c. Hourly import and cleaning | Hourly ozone, NO₂ and SO₂ for the Houston and Dallas–Fort Worth sites, filtered while reading | Next |
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

**Data:** daily summary files from the [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html). The data come from the U.S. Environmental Protection Agency and are in the public domain.

1. Under **Daily Data**, download the 2021–2025 zips for parameter codes 88101 (PM2.5), 44201 (ozone), 42602 (NO₂), 42401 (SO₂) and 42101 (CO). Unzip all 25 into `data/raw/` and keep EPA's file names.
2. Install R and RStudio with `dplyr` 1.2.0 or later and `tidyr` 1.3.0 or later. Under **Tools → Global Options → General**, turn off restoring and saving `.RData`.
3. Run `R/0_setup.R` once and restart R. Then source `R/1a_import_clean.R`, which takes several minutes, followed by `R/1b_event_checks.R`.

## Repository structure (so far)

<details>
<summary>Show folder layout</summary>

```text
EPA AQS Project/
├── data/
│   ├── raw/          # 25 AQS daily files (not tracked)
│   │   └── hourly/   # 15 AQS hourly files (next, not tracked)
│   ├── reference/    # methods_all.csv, events.csv
│   └── processed/
│       ├── aqs_long_clean.rds       # cleaned data: 5,557,574 rows × 23 columns
│       ├── sites.rds                # 2,038 sites: names, coordinates, CBSA
│       ├── site_coverage.rds        # years active per pollutant and site
│       ├── cleaning_log.rds         # rows removed at each step
│       ├── data_dictionary.csv      # every saved column: type and meaning
│       └── checkpoint_manifest.csv  # rows, size and MD5 checksum per file
├── R/
│   ├── 0_setup.R           # installs or upgrades required packages
│   ├── 1a_import_clean.R   # Phase 1: import, cleaning and validation
│   ├── 1b_event_checks.R   # Phase 1: verifies events.csv against the data
│   ├── 1c_hourly_import.R  # next: hourly import for the case-study sites
│   └── utils.R             # log_step(), region_lookup, event_medians()
├── report/           # R Markdown report (Phase 5)
├── figures/
├── docs/             # GitHub Pages output and methodology
│   └── phase1_methodology.md
├── EPA AQS Project.Rproj
└── README.md
```

</details>

## Limitations

- **Changing network:** Between 2021 and 2025, PM2.5 rows grew 23.6% and SO₂ and CO rows fell about 18%, so trend analyses use only sites with data in all five years.
- **Simplified exceedances:** Daily values are compared directly with today's standards in every year, including the 9.0 µg/m³ annual PM2.5 standard set in February 2024. EPA's official design values use a different calculation.
- **T640 corrections:** 1,941 site-days in 2024–2025 had no corrected version and no other PM2.5 reading, so they were lost. EPA's correction is still under review, and a 2026 request for correction from Georgia EPD reports leftover bias at some sites.
- **Coverage:** Monitors aren't placed at random, and the weather in coastal Houston and inland Dallas–Fort Worth isn't matched.

## Author

Yousef Shamsaldeen | [LinkedIn](https://www.linkedin.com/in/yshamsaldeen/)
