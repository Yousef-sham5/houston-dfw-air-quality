# Phase 1 Methodology

October 10, 2026 · Yousef Shamsaldeen

## Data

The input is EPA AQS daily summary data for 2021–2025: 25 files and 8,930,992 rows covering PM2.5 (88101, FRM/FEM monitors only), ozone (44201), NO₂ (42602), SO₂ (42401) and CO (42101). Every column is read with an explicit type, and codes are kept as text so leading zeros survive. Named assertions stop the script whenever an assumption fails. Each site gets a `site_id` such as "06-037-1103".

## Cleaning

Cleaning removed **3,373,418 rows (37.8%)**, and almost all of them were repeat summaries of a monitor-day already in the data.

| Step | Rows removed | Reason |
|---|---|---|
| Drop non-US sites | 9,982 | Monitors in Mexico near the border. Puerto Rico and the Virgin Islands stay in. |
| One averaging time per pollutant | 2,956,079 | Repeat summaries of the same day at other averaging times |
| Validate method codes | 315,860 | Raw T640/T640X PM2.5 (313,057), ozone method 901, which has no FRM/FEM designation (2,776), and blank codes (27) |
| Keep event-included values | 2,680 | Duplicate "Excluded" rows for event days. The "Included" values match the air people actually breathed. |
| T640 firmware overlap | 338 | The same monitor-day reported under both firmware and corrected codes at 7 sites. The firmware value is kept. |
| 75% completeness rule | 88,478 | Days with less than 75% of expected measurements (1.8–4.2% of gas rows, no PM2.5) |
| Outside method range | 1 | One SO₂ maximum of 2,732 ppb, above the analyzer's 1,500 ppb limit |

- **T640:** EPA went back and corrected older T640/T640X data (codes 736/738), and sites with updated firmware report corrected values directly (636/638). At the 7 overlap sites the corrected copy sits on its own POC, so overlaps are matched by site and day. The monitor models match at each site, which indicates one instrument reported twice. In 2024–2025, 2,561 raw site-days had no corrected version, and 1,941 of those had no other PM2.5 reading, so they were lost.
- **Checks:** No analysis values are missing, so nothing is imputed, and the units in EPA's methods table match the units in the data.
- **Collocated instruments** stay as separate rows and get averaged per site-day in Phase 2. Site-days with more than one instrument: PM2.5 256,111, ozone 51,667, NO₂ 14,907, CO 3,033 and SO₂ 1,017.
- **Simplification:** Incomplete days are dropped even when they already exceed a standard, so exceedance counts run slightly low.

## Averaging times and metrics

| Pollutant | Averaging time kept | Metric (`first_max_value` unless noted) |
|---|---|---|
| PM2.5 | 24-hour (filter and continuous) | Daily mean (`arithmetic_mean`) |
| Ozone | 8-hour running average | Daily maximum 8-hour |
| NO₂ | 1-hour | Daily maximum 1-hour |
| SO₂ | 1-hour (3-hour secondary standard dropped) | Daily maximum 1-hour |
| CO | 8-hour (1-hour dropped) | Daily maximum 8-hour |

Both CO standards are primary. The 8-hour one is the basis of the CO Air Quality Index.

## Negative values and gaps

Negative and zero readings come from instrument noise near zero, and they stay in. Removing them would push averages up, and every one falls inside EPA's method limits. SO₂ has the most, at 16% of daily means. For the Phase 3 distribution fits, a copy of the data sets these values to half the detection limit, and SO₂ and NO₂ are fitted on daily maximums.

Gaps in each instrument's record are flagged in their own table and left unfilled. Off-season gaps for seasonal ozone monitors (November 1 to March 31) are left out of the gap summary, though a few long ozone gaps remain from seasons that start or end outside that window.

## Unit conversion

Gas concentrations are also stored in µg/m³ (`mean_ugm3`, `max_ugm3`) so pollutants can be compared on one scale. The conversion is µg/m³ = ppb × MW / Vm, where Vm = RT/P = 24.465 L/mol at 25 °C and 1 atm. Ozone and CO are converted from ppm to ppb first, and the original units are kept for NAAQS comparisons.

| Pollutant | Original units | MW (g/mol) | Factor to µg/m³ |
|---|---|---|---|
| Ozone | ppm | 48.00 | 1,962.0 |
| NO₂ | ppb | 46.01 | 1.881 |
| SO₂ | ppb | 64.06 | 2.618 |
| CO | ppm | 28.01 | 1,144.9 |

## Derived columns

`year`, `month`, `year_month`, `day_of_year`, `season`, `season_year`, `day_of_week` and `is_weekend` are all built from `date_local`. Seasons are meteorological, with December counted toward the following winter, so the partial winters of 2021 and 2026 are left out of seasonal comparisons.

## Events

Agency `event_type` flags only cover events documented for compliance purposes, so `data/reference/events.csv` lists each event and gives matching monitor-days an `event_name` label. No rows are removed. Each event was first confirmed against agency sources, and its states and dates were then set from the data. A state is included when its median PM2.5 at least doubles its pre-event baseline, and outage events last until most monitors are back online. Fireworks windows (July 4–5 and January 1, PM2.5 only) apply to every state. No monitor-day falls in two events, and `1b_event_checks.R` reruns these checks from the saved checkpoint.

| Event | Dates | Area | Pollutants | Sources |
|---|---|---|---|---|
| Winter Storm Uri | Feb 11–23, 2021 | Texas | SO₂, CO, NO₂, PM2.5 | NWS, Texas Tribune |
| Wildfire smoke July 2021, episode 1 | Jul 19–21, 2021 | 12 Northeast and Mid-Atlantic states | PM2.5 | NASA, NYS DEC |
| Wildfire smoke July 2021, episode 2 | Jul 26–27, 2021 | CT, MA, NH, RI, VT, NY, NJ, DE | PM2.5 | CT DEEP, MassDEP |
| Hurricane Ida | Aug 29 to Sep 7, 2021 | Louisiana | All | NWS, EPA |
| Canadian smoke early June 2023 | Jun 6–8 (11 states); Jun 5–11 (OH, MI, VA, WV, NC) | Northeast, Mid-Atlantic, Great Lakes | PM2.5 | NOAA, EPA |
| Canadian smoke late June 2023 | Jun 27–30 (9 Midwest states); Jun 28 to Jul 2 (NY, PA) | Midwest, NY, PA | PM2.5, ozone | Michigan EGLE, NOAA ARL |
| Hurricane Beryl | Jul 8–14, 2024 | Harris County | All | NWS, DOE |
| LA Palisades and Eaton fires | Jan 8–11, 2025 | Los Angeles County | PM2.5 | CAL FIRE, South Coast AQMD |

- **Post-event baselines** were used for the LA fires, where winter stagnation had already raised the week before, and for July 2021 episode 2, whose pre-event week overlaps episode 1.
- **Excluded:** the East Palestine derailment (February 2023). Columbiana County, Ohio had no PM2.5 or CO monitors, since its only AQS monitor (SO₂) stopped reporting after 2021, and nearby counties showed no rise.
- **Unlabeled:** rises with no documented cause in the Northeast (June 11–12, 2023) and Ventura County (January 22, 2025).

## Site coverage

`n_years_active` (0 to 5) counts the years in which a site, on a single sampling schedule, reaches 75% of its expected samples. Each year is assessed as a whole: 274 days for daily monitors, 92 for 1-in-3 samplers and 46 for 1-in-6. Seasonal ozone monitors, which report no December or January data, need 184 days, which is 75% of the most common March–October season. Dallas and Tarrant counties need 207 because their season runs March–November (40 CFR 58 Appendix D, Table D-3; 40 CFR 50 Appendix U). Sites active in all five years: ozone 964 (973 under the earlier 161-day rule), PM2.5 769, NO₂ 312, SO₂ 301 and CO 135.

## Case study

The stricter ozone thresholds left the full-coverage counts unchanged. Houston (Harris County) has 17 sites for ozone, 8 for NO₂, 4 for PM2.5, 4 for SO₂ and 1 for CO. Dallas–Fort Worth (Dallas and Tarrant counties) has 6 for ozone, 4 for NO₂ and 3 for PM2.5, with none for SO₂ or CO. The two regions are compared on ozone, NO₂ and PM2.5, and SO₂ is analyzed for Houston only.

Early findings: Harris County's two largest monitoring outages both lined up with higher combustion pollutants. During Winter Storm Uri (Feb 15–17, 2021), reporting NO₂ sites fell from 12 to 1, and in the days after (Feb 19–23) county NO₂ ran 1.6–2.2 times its early-February median. During Hurricane Beryl (Jul 8–14, 2024), reporting sites fell from 20 to 3. No Harris County CO site reported on Jul 8–9, and on Jul 10–14 the only one online was Houston North Loop (48-201-1052, 822 North Loop, data published by TCEQ). Its CO reached 2.9–4.7 times its median for the previous three weeks (0.8 ppm) and was back to normal by Jul 15, a pattern consistent with generator use and traffic disruption. Its NO₂ and PM2.5 will be checked in Phase 2.

## Final dataset

The cleaned data hold **5,557,574 monitor-days**, one row per instrument per day from 2021-01-01 to 2025-12-31. Assertions confirm a unique key, no missing values outside `event_name`, every pollutant present in every year, and yearly counts that add up to the cleaning log's total. The data table keeps 23 of the 37 columns, and site details live in a separate `sites` table, which cut memory use from 1.42 GB to 867 MB (38.9%). The checkpoint is four gzip-compressed `.rds` files: `aqs_long_clean` (45.7 MiB), `sites` (2,038 rows), `site_coverage` (3,760 rows) and `cleaning_log`. They reload identically, and `data/processed/` also holds a data dictionary and an MD5 manifest.

| Pollutant | 2021 | 2022 | 2023 | 2024 | 2025 |
|---|---|---|---|---|---|
| PM2.5 | 326,440 | 342,016 | 363,893 | 392,940 | 403,384 |
| Ozone | 385,054 | 378,275 | 378,388 | 377,196 | 371,275 |
| NO₂ | 155,608 | 154,585 | 152,565 | 150,886 | 148,199 |
| SO₂ | 151,733 | 145,542 | 140,521 | 131,647 | 124,532 |
| CO | 84,426 | 80,759 | 77,032 | 71,273 | 69,405 |

The row counts track changes in the monitoring network. PM2.5 rows grew 24% as FEM rows rose 33% (258,676 to 343,688) and FRM rows fell 12%. Over the same period, reporting SO₂ sites fell 18% (454 to 372) and CO sites fell 17% (265 to 219).

## Next: hourly import and cleaning (1c)

The next step adds hourly data for the case study. It runs in its own script, `R/1c_hourly_import.R`, so the daily pipeline stays as it is.

### Scope

- **Pollutants:** ozone (44201), NO₂ (42602) and SO₂ (42401) for 2021–2025, which is 15 files.
- **Sites:** the Houston and Dallas–Fort Worth case-study sites, picked from the full-coverage list above.
- **CO is left out.** Texas has few CO monitors, its levels sit far below the NAAQS, NO₂ already captures the traffic signal, and NO₂ takes part directly in the ozone chemistry being tested.
- **PM2.5 is left out.** FRM monitors take 24-hour filter samples, so hourly PM2.5 would come only from FEM monitors (with the T640 corrections) and wouldn't match the daily method mix. The PM2.5 standards are 24-hour and annual, and hourly PM2.5 mostly reflects boundary-layer mixing, which makes it a weak source indicator.
- **No wind data** is used, so statements about sources are worded as "consistent with". A pollution rose is listed as future work.

### Uses

- **Diurnal profiles (Phase 2):** traffic and industrial signatures, Houston against Dallas–Fort Worth, and weekdays against weekends.
- **Ozone photochemistry (Phase 4):** the lag between NO₂ and ozone.

### Size and approach

EPA's AirData page (files dated 2026-06-25) lists 62,974,304 hourly rows for these three pollutants in 2022–2025 alone, or 454 MiB zipped. Read whole, that is far more than a 16 GB laptop can hold, given that the 8.9 million daily rows already peaked at 1.42 GB. Each file will be read with `readr::read_csv_chunked()`, keeping only the case-study sites from every chunk. One monitor's full record is 1,826 days × 24 hours = 43,824 rows, so even all 39 full-coverage case-study monitors come to about 1.7 million rows.

1. Pick the case-study sites by joining `site_coverage` to `sites` on `site_id`, favoring Ship Channel sites for Houston.
2. Download the 15 zips from **Hourly Data** on the AirData page into `data/raw/hourly/`, which is not tracked.
3. Import with explicit column types, apply the same FRM/FEM method check as `1a_import_clean.R`, reuse the pollutant and region lookups from `R/utils.R`, and add named assertions at each step.
4. Save `data/processed/hourly_case_study.rds` with gzip compression and add it to the data dictionary and manifest.

### Still to decide

- The final site list.
- Whether AQS `time_local` stays on local standard time all year, which matters for diurnal profiles.
- How to treat the hourly `qualifier` column.
- An hour-level completeness rule, such as 75% of hours (18 of 24) for a valid day.
- A cross-check: daily 1-hour maximums for NO₂ and SO₂ rebuilt from hourly values should match `first_max_value` in the daily data.