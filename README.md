# U.S. Criteria Air Pollutants, 2021–2025: An EPA AQS Statistical Analysis in R

This project uses R to clean, explore and model five years of air quality data from the EPA's Air Quality System (AQS) for PM2.5, ozone, NO₂, SO₂ and CO. The national daily data hold 8.9 million records, 5.56 million after cleaning. Hourly pollutant and weather data cover 16 case-study monitors in Houston and Dallas–Fort Worth (661,545 monitor-hours).

**Status:** Complete. Phases 1 to 3 hold the analysis, and the 28-page report (`R/5_report.Rmd`, knit to `5_report.pdf`) presents it. Five years is too short to separate a trend from year-to-year weather, so the project does not test trends. 41 figures.

## Research question

How do pollutant levels and NAAQS compliance near the Houston Ship Channel, a corridor of refineries and chemical plants in east Harris County, compare with the rest of Harris County and with Dallas–Fort Worth (Dallas and Tarrant counties)? Ship Channel sites are Harris County monitors within 7.5 km of the channel. Comparing within Houston holds the weather constant, and Dallas–Fort Worth helps separate an industrial signal from general urban pollution.

## Methods at a glance

| Phase | Techniques | Status |
|---|---|---|
| 1. Import and cleaning | Daily data for 5 pollutants nationwide; hourly pollutants and weather for 16 monitors at 9 sites. Row counts checked against EPA's; suspect readings flagged and kept | Done |
| 2. Exploratory analysis | National NAAQS screening, events, seasons and weekends; same-day group differences, daily cycles, an Ox (ozone + NO₂) test, SO₂ spikes, calm air and pollution roses, with block-bootstrap ranges and every result rerun under every check | Done |
| 3. Distributions | Per-site lognormal, gamma and Weibull fits ranked by AIC, tail tests against actual days, and a worked ozone design value checked against EPA's file | Done |
| 4. Report | R Markdown PDF. Every number is read from the saved headline tables, and the knit stops if one is missing | Done |

## Data quality highlights

- Cleaning took 8,930,992 raw rows down to 5,557,574; most of the 37.8% removed were repeat summaries of the same monitor-day.
- Methods are checked against EPA's FRM/FEM table, and 313,057 raw T640/T640X PM2.5 rows gave way to corrected versions.
- The 75% completeness rule uses federal ozone-season lengths, and 22 source-checked events are labelled under one rule a script rechecks.
- Named assertions check each step; a dictionary lists every saved column, and a manifest holds checkpoint MD5s.
- The hourly data rebuild all 27,747 daily maximums exactly. A site move, a method change and five sensor replacements are checked against neighbours and flagged.

## Findings (Phase 2, national)

- **NAAQS screening:** in 2023, 42.7% of five-year ozone sites and 39.0% of annual PM2.5 sites were above the standard; over three-year windows, about 23% of ozone sites.
- **Events:** labelled smoke, dust and storm days hold 39.9% of PM2.5 exceedance days (68.2% in 2023), and EPA's own event flag covers 14% of them.
- **Weekends:** NO₂ is 20% lower at the median site. Weekend ozone rises in Los Angeles (+5.0%), consistent with VOC-limited ozone, and falls in Houston (−4.0%) and Dallas–Fort Worth (−4.8%).
- **Houston and Dallas–Fort Worth** rank 6th and 8th of 353 metros with an ozone exceedance, by exceedance site-days, a count that favours large networks.

## Findings (Phase 2, daily case study)

Same-day group differences with 95% block-bootstrap ranges, rerun under every check that changes them.

- **NO₂:** the Ship Channel runs 1.15 ppb above Houston other (0.81 to 1.41) in every year and under every check, consistent with nearby NOx sources. NO₂ falls with distance from the channel (Spearman −0.72, p = 0.02; p = 0.08 without the farthest site).
- **Ozone:** the Ship Channel runs 0.97 ppb below Houston other, consistent with fresh NO using up ozone; the gap disappears under the memo-list grouping. Houston runs 4.0 ppb below Dallas–Fort Worth.
- **SO₂ and PM2.5:** the 0.13 ppb SO₂ gap is far under the 2 ppb detection limit, so SO₂ is read through spikes instead. PM2.5 shows no clear gap within Houston (it holds in only 3 of 6 runs), consistent with regional PM2.5.

## Findings (Phase 2, hourly case study)

Two ozone and NO₂ sites per group; for SO₂, three Ship Channel sites and Croquet. Ordinary hours only.

- **Every hour:** Ship Channel NO₂ is higher and ozone lower than Houston other at all 24 hours, widest late in the day.
- **Why ozone is lower (Ox):** adding NO₂ back to ozone closes 52% of the Ship Channel's ozone gap over the year and 99% without Harvard Street, the Houston other site nearest the channel, consistent with fresh NO using up ozone.
- **SO₂ spikes (an hour at 5 ppb or more):** 96% of Croquet's fall between 9 am and 6 pm, mostly in summer. Spikes last about an hour and seldom hit two sites at once, consistent with local plumes. Deer Park #2 spikes carry 7.5 ppb more NO₂.
- **Calm air:** Houston is calm 4 to 6 times as often as Dallas–Fort Worth. Calm hours carry 3.0 to 6.8 ppb more NO₂ and 3.8 to 9.0 ppb less ozone than windy hours at the same hour and month.
- **Wind directions:** NO₂ runs highest in east wind at all four Houston sites. Croquet's SO₂ spikes come from the southwest (75% of spikes from 11% of its hours), away from the channel; Park Place's come from the channel side (77% from 30%).
- **The rest of the ozone gap:** without Harvard Street, the Ox gap is −2.2 ppb in wind from the channel and about zero otherwise, consistent with ozone forming in channel air as it crosses Houston.
- **Checks:** all ten headline findings hold under every check that applies and with a second random seed (figure 2C.12).

## Findings (Phase 3, distributions)

Curves are fitted per site on ordinary days at 2,425 five-year sites; design values use every day at the 22 case-study ozone sites. Causes are untested.

- **Which curve:** a lognormal wins at 188 of 249 SO₂ and 82 of 132 CO sites, consistent with pollutants diluted as they spread. A normal curve wins at 525 of 964 ozone sites if allowed, consistent with ozone forming in the air.
- **How sure:** linked days make AIC gaps overstate certainty. 87.7% of ozone sites have a gap of 10 or more, 36.1% after scaling, and 52.0% of 100 random sites keep their winner.
- **PM2.5 monitors:** at the same 67 sites, a lognormal wins 96% of fits on T640 monitors and 46% on others, consistent with an instrument effect.
- **Houston against Dallas–Fort Worth:** warm-month ozone swings wider in Houston (spread factor 1.47 and 1.46 against 1.34, gap ranges clear of zero). Cool months match at 1.46.
- **Deer Park #2 SO₂:** the lognormal's win leans on days below the detection limit (37 expected days above P99 against 17 actual); counting them only as "below the limit" gives a Weibull that expects 18.
- **Tails:** at the top 1% of days, the winner's total runs from 0.80 of actual (PM2.5) to 1.54 (NO₂), and it lands within 25% at only 23% to 32% of sites. At the ozone limit, the winner's total is 1.00 and the lognormal's 2.17.
- **Warm-month Texas ozone:** gamma counts days above the limit 6% to 12% high in all three groups, with 95% ranges that include 1, but overcounts the warm top 1% by 51% to 69%.
- **Ozone design values:** Houston Aldine's 2023–2025 value is (0.078 + 0.097 + 0.073) / 3, truncated to 0.082 ppm, the same as EPA's file. All 22 case-study ozone sites are above the 0.070 ppm standard (0.071 to 0.085). The method matches EPA at 61 of 66 site-windows; each miss is 0.001 ppm low, because cleaning drops short days that EPA keeps when they top 0.070.
- **Checks:** all 88 pairs of 12 figure findings and their checks hold, including a second random seed (figure 3.10), and all 20 validation checks pass.

## Conclusions

The report tests three hypotheses about the Ship Channel against Houston other.

- **H1, more NO₂ near the channel: supported.** Higher in every year, on the same days and at all 24 hours, under every check.
- **H2, less ozone because fresh NO uses it up: supported in part.** Adding NO₂ back closes 52% of the ozone gap, or 99% without Harvard Street. The rest sits in wind from the channel, consistent with ozone forming downwind.
- **H3, SO₂ from short local plumes: supported.** One-hour spikes over a background below the detection limit, from more than one direction.
- **Lower ozone is not cleaner air:** every case-study ozone site, Ship Channel sites included, is above the 0.070 ppm standard for 2023–2025.

## Engineering angle

Gas readings are converted to µg/m³ with the ideal gas law (RT/P = 24.465 L/mol at 25 °C and 1 atm). The Ox test rests on the NO + O₃ → NO₂ + O₂ balance.

## Tech stack

R (`dplyr`, `tidyr`, `readr`, `readxl`, `lubridate`, `ggplot2`, `patchwork`, `fitdistrplus`, `moments`, `kableExtra`), R Markdown with LuaLaTeX (TinyTeX), Git and GitHub.

## Reproduce

Data come from the [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html) (public domain; file versions dated 2026-06-25).

1. **Daily Data:** the 2021–2025 zips for 88101 (PM2.5), 44201 (ozone), 42602 (NO₂), 42401 (SO₂) and 42101 (CO), unzipped into `data/raw/daily/`.
2. **Hourly Data:** the 2021–2025 Criteria Gases zips for 44201, 42602 and 42401 into `data/raw/hourly/`, and the Meteorological `hourly_WIND` and `hourly_TEMP` zips into `data/raw/weather/`. Leave both zipped.
3. Open `EPA AQS Project.Rproj`, run `R/0_setup.R` once and restart R. `renv::restore()` gives the exact package versions (R 4.6.1).
4. Source the scripts in order: `1a`, `1b`, `1c`, `1d`, `1e`, `2a`, `2b`, `2c`, `3_distributions`. First runs of `1d`, `1e` and `3_distributions` are slow (up to about 45 minutes for `3_distributions`); later runs reuse saved results.
5. Knit `R/5_report.Rmd` in RStudio. `5_report.pdf` lands in the project root in under a minute.

The figures use Arial; RStudio's Plots pane needs its Graphics Backend set to AGG. The report's code excerpts use IBM Plex Mono, kept in `fonts/`.

## Repository structure

<details>
<summary>Show folder layout</summary>

```text
EPA AQS Project/
├── data/
│   ├── raw/                # not tracked
│   ├── hourly_filtered/    # not tracked: cached case-study rows
│   ├── weather_filtered/   # not tracked: cached case-study rows
│   ├── distribution_cache/ # not tracked: saved slow steps
│   ├── reference/          # method table, events, channel shape, site groups, EPA ozone design values
│   └── processed/          # checkpoints (.rds), data dictionary and manifest
│       ├── phase1/         # CSV records
│       ├── phase2/         # CSV records
│       └── phase3/         # CSV records
├── R/                      # scripts, run in order, utils.R and 5_report.Rmd
├── figures/                # numbered, one folder per phase
│   ├── phase1/             # case-study site maps, wide and narrow
│   ├── phase2/             # 2a.01_ to 2a.10_, 2b.01_ to 2b.08_, 2c.01_ to 2c.12_
│   └── phase3/             # 3.01_ to 3.10_
├── fonts/                  # report fonts and their licences
├── docs/                   # methodology.md
├── 5_report.pdf            # the report
├── renv.lock               # package versions used
└── README.md
```

</details>

## Limitations

- **Changing network:** from 2021 to 2025, PM2.5 rows grew 23.6% and SO₂ and CO rows fell about 18%, so levels use five-year sites only.
- **No trends:** changes between years are described but not tested.
- **Screening values:** every year is judged against today's standards, including 2024's 9.0 µg/m³ annual PM2.5 level. EPA's three-year design values are worked only for the 22 case-study ozone sites.
- **Weather and placement:** seasonal and weekend comparisons do not control for weather, monitors aren't placed at random, and coastal Houston and inland Dallas–Fort Worth have different weather.
- **T640 corrections:** some 2024–2025 site-days had no corrected version and no other PM2.5 reading, so they were lost.
- **Site groups:** distance to the channel stands in for distance to the plants along it. Results are rerun without sites 7.5 to 15 km away and with TCEQ's memo grouping.
- **Small hourly groups:** two ozone and NO₂ sites per group, so hourly results describe these sites.
- **Fitted curves and wind:** a curve can win and still miss the tail, and a wind direction points toward a source without proving it.
- **No NO or NOx data:** Ox shows how much of the ozone gap titration explains, but the rest cannot be split into local and regional parts.
- **Many comparisons:** dozens of ranges are reported without a multiple-comparison adjustment, so the results that hold under every check are the safest to cite.

## Author

Yousef Shamsaldeen | [LinkedIn](https://www.linkedin.com/in/yshamsaldeen/)
