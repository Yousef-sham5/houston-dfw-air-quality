# U.S. Criteria Air Pollutants, 2021–2025: An EPA AQS Statistical Analysis in R

A reproducible R pipeline that cleans, explores and models five years of daily EPA Air Quality System (AQS) data for PM2.5, ozone, NO₂, SO₂ and CO: 8.9 million raw daily records, 5.56 million after cleaning, analyzed with R, the tidyverse and R Markdown.

**Status:** Phase 1 of 5 (import and cleaning) is complete. Phase 2 (exploratory analysis) is next.

## Research question

How do ambient pollutant levels, trends and NAAQS compliance near the Houston Ship Channel (Harris County), an industrial corridor of refineries and chemical plants, compare with Dallas–Fort Worth (Dallas and Tarrant counties), a large metro area used as the control? Comparing the two helps separate an industrial signal from ordinary urban pollution, framed as emissions monitoring and regulatory compliance.

## Methods at a glance

| Phase | Techniques | Status |
|---|---|---|
| 1. Import and cleaning | FRM/FEM method validation, EPA 75% completeness rule, ideal-gas unit conversion, event labeling | Done |
| 2. Exploratory analysis | Summary statistics, seasonal and diurnal profiles, site comparisons, NAAQS exceedance screening | Planned |
| 3. Distributions | Log-normal and gamma fits, Q-Q plots, extreme-value tails, design values | Planned |
| 4. Trends and regression | Mann-Kendall and Theil-Sen trends, seasonal decomposition, multiple regression, residual diagnostics | Planned |
| 5. Report | R Markdown report (PDF and HTML) on GitHub Pages | Planned |

## Data quality highlights

- 8,930,992 raw rows cleaned to 5,557,574 (37.8% removed, nearly all duplicate summaries of the same monitor-day).
- Every method validated against EPA's FRM/FEM table; 313,057 raw T640/T640X PM2.5 rows removed in favor of EPA-corrected and firmware-corrected data.
- EPA's 75% completeness rule applied, with federal ozone-season thresholds; 8 verified events labeled.
- Named assertions check every step, and the saved checkpoint reloads identically, with a data dictionary and MD5 manifest.

## Engineering angle

Gas concentrations are converted from ppb and ppm to µg/m³ with the ideal gas law (molar volume RT/P = 24.465 L/mol at 25 °C and 1 atm), compliance is screened against the NAAQS regulatory framework, and later phases compare traffic and industrial source signatures.

## Tech stack

R (`dplyr`, `tidyr`, `ggplot2`, `trend`, `fitdistrplus`), R Markdown, Git and GitHub Pages.

## Reproduce

**Data:** Daily summary files from the [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html), produced by the U.S. Environmental Protection Agency and in the public domain.

1. Download each pollutant-year zip from **Daily Data** for parameter codes 88101 (PM2.5), 44201 (ozone), 42602 (NO₂), 42401 (SO₂) and 42101 (CO), 2021–2025, and unzip all 25 into `data/raw/` with EPA's file names.
2. Install R and RStudio (`dplyr` 1.2.0 or later, `tidyr` 1.3.0 or later). In **Tools → Global Options → General**, turn off restoring and saving `.RData`.
3. Run `R/0_setup.R` once, restart R, then source `R/1a_import_clean.R` (several minutes) and `R/1b_event_checks.R`.

## Repository structure

```text
EPA AQS Project/
├── data/
│   ├── raw/          # 25 AQS daily files (not tracked)
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
│   └── utils.R             # log_step(), region_lookup, event_medians()
├── report/           # R Markdown report (Phase 5)
├── figures/
├── docs/             # GitHub Pages output and methodology
│   └── phase1_methodology.md
├── EPA AQS Project.Rproj
└── README.md
```

## Limitations

- **Changing network:** from 2021 to 2025, PM2.5 rows grew 23.6% while SO₂ and CO rows fell about 18%, so trends use sites with data in all five years.
- **Simplified exceedances:** daily values are compared directly with the current standards (including the 9.0 µg/m³ annual PM2.5 standard set in February 2024) across all years, which differs from EPA's official design values.
- **T640 corrections:** 1,941 site-days in 2024–2025 were lost, and EPA's correction remains under review (a 2026 request for correction from Georgia EPD reports residual bias at some sites).
- **Coverage:** monitors are not placed randomly, and Houston (coastal) and Dallas–Fort Worth (inland) weather is not matched.

## Author

Yousef Shamsaldeen · [LinkedIn](https://www.linkedin.com/in/yshamsaldeen/)
