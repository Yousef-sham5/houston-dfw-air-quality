# Phase 1 Methodology

October 10, 2026 · Yousef Shamsaldeen

## Data

EPA AQS daily summaries for 2021–2025 (25 files, 8,930,992 rows): PM2.5 (88101, FRM/FEM only), ozone (44201), NO₂ (42602), SO₂ (42401) and CO (42101). Columns are explicitly typed, codes stay as text to keep leading zeros, and named assertions stop the pipeline when an assumption fails. Sites are identified by `site_id` (e.g., "06-037-1103").

## Cleaning

**3,373,418 rows (37.8%) removed**, almost all duplicate summaries of the same monitor-day.

| Step | Rows removed | Reason |
|---|---|---|
| Drop non-US sites | 9,982 | Mexico border monitors (Puerto Rico and the Virgin Islands kept) |
| One averaging time per pollutant | 2,956,079 | Duplicate summaries at other averaging times |
| Validate method codes | 315,860 | Raw T640/T640X (313,057); ozone 901, no FRM/FEM designation (2,776); blank codes (27) |
| Keep event-included values | 2,680 | "Excluded" duplicates of event days; "Included" values describe the air actually breathed |
| T640 firmware overlap | 338 | Same monitor-day under firmware and corrected codes at 7 sites; firmware value kept |
| 75% completeness rule | 88,478 | Under 75% of expected measurements (1.8–4.2% of gas rows; no PM2.5) |
| Outside method range | 1 | SO₂ maximum of 2,732 ppb against a 1,500 ppb analyzer limit |

- **T640:** EPA retroactively corrected T640/T640X data (736/738); sites with updated firmware report corrected data directly (636/638). At the 7 overlap sites the corrected copy has its own POC, so overlaps are matched by site and day; matching monitor models indicate one instrument reported twice. In 2024–2025, 2,561 raw site-days had no corrected version, and 1,941 of them had no other PM2.5 reading and were lost.
- **Checks:** no missing analysis values (nothing imputed); method-table units match the data.
- **Collocated instruments** stay as separate rows and are averaged per site-day in Phase 2. Site-days with more than one: PM2.5 256,111; ozone 51,667; NO₂ 14,907; CO 3,033; SO₂ 1,017.
- **Simplification:** incomplete days are dropped even if they already exceed a standard, so exceedances are slightly undercounted.

## Averaging times and metrics

| Pollutant | Averaging time kept | Metric (`first_max_value` unless noted) |
|---|---|---|
| PM2.5 | 24-hour (filter and continuous) | Daily mean (`arithmetic_mean`) |
| Ozone | 8-hour running average | Daily maximum 8-hour |
| NO₂ | 1-hour | Daily maximum 1-hour |
| SO₂ | 1-hour (3-hour secondary standard dropped) | Daily maximum 1-hour |
| CO | 8-hour (1-hour dropped) | Daily maximum 8-hour |

Both CO standards are primary; the 8-hour standard is the basis of the CO Air Quality Index.

## Negative values and gaps

Negative and zero values come from instrument noise near zero and are kept: removing them would bias averages upward, and all fall within EPA's method limits. SO₂ has the most (16% of daily means). Phase 3 distribution fits will use a copy with these values set to half the detection limit, fitting SO₂ and NO₂ on daily maximums.

Gaps are flagged in a separate table, not filled. Seasonal ozone off-season gaps (November 1 to March 31) are left out of the gap summary; some long ozone gaps remain from seasons outside that window.

## Unit conversion

Gases are also stored in µg/m³ (`mean_ugm3`, `max_ugm3`) for cross-pollutant comparison: µg/m³ = ppb × MW / Vm, with Vm = RT/P = 24.465 L/mol at 25 °C and 1 atm; ozone and CO are converted from ppm to ppb first. Original units are kept for NAAQS comparisons.

| Pollutant | Original units | MW (g/mol) | Factor to µg/m³ |
|---|---|---|---|
| Ozone | ppm | 48.00 | 1,962.0 |
| NO₂ | ppb | 46.01 | 1.881 |
| SO₂ | ppb | 64.06 | 2.618 |
| CO | ppm | 28.01 | 1,144.9 |

## Derived columns

`year`, `month`, `year_month`, `day_of_year`, `season`, `season_year`, `day_of_week` and `is_weekend` come from `date_local`. Seasons are meteorological, with December counted in the following winter; the partial winters of 2021 and 2026 are excluded from seasonal comparisons.

## Events

Agency `event_type` flags cover only events documented for compliance, so `data/reference/events.csv` labels matching monitor-days with an `event_name` (no rows removed). Events were confirmed against agency sources, then states and dates were set from the data: a state is included when its median PM2.5 at least doubles its pre-event baseline, and outage events run until most monitors return. Fireworks windows (July 4–5 and January 1, PM2.5) cover every state. No monitor-day falls in two events, and `1b_event_checks.R` reruns the checks from the checkpoint.

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

- **Post-event baselines:** the LA fires (winter stagnation raised the pre-fire week) and July 2021 episode 2 (its pre-event week overlaps episode 1).
- **Excluded:** the East Palestine derailment (February 2023). Columbiana County, Ohio had no PM2.5 or CO monitors (its only AQS monitor, SO₂, stopped reporting after 2021), and nearby counties showed no rise.
- **Unlabeled:** undocumented rises in the Northeast (June 11–12, 2023) and Ventura County (January 22, 2025).

## Site coverage

`n_years_active` (0–5) counts the years in which a site's days on one sampling schedule reach 75% of expected samples, assessed per year: 274 days for daily monitors, 92 for 1-in-3 and 46 for 1-in-6. Seasonal ozone monitors (no December or January data) need 184 days, 75% of the most common March–October season, or 207 in Dallas and Tarrant counties, whose season runs March–November (40 CFR 58 Appendix D, Table D-3; 40 CFR 50 Appendix U). Sites active all five years: ozone 964 (973 under the earlier 161-day rule), PM2.5 769, NO₂ 312, SO₂ 301 and CO 135.

## Case study

Full-coverage sites, unchanged by the stricter ozone thresholds: Houston (Harris County) has 17 for ozone, 8 for NO₂, 4 for PM2.5, 4 for SO₂ and 1 for CO; Dallas–Fort Worth (Dallas and Tarrant counties) has 6, 4, 3 and none for SO₂ or CO. Ozone, NO₂ and PM2.5 are compared across regions; SO₂ is analyzed for Houston only.

Findings so far: Harris County's two largest monitoring outages, Uri (Feb 15–17, 2021; NO₂ sites fell from 12 to 1) and Beryl (Jul 8–14, 2024; sites fell from 20 to 3), both coincided with elevated combustion pollutants. After Uri (Feb 19–23), Harris County NO₂ was 1.6–2.2 times its early-February median. During Beryl, Houston North Loop (48-201-1052, 822 North Loop; data published by TCEQ), the only Harris County CO site reporting on Jul 10–14 (none reported on Jul 8–9), measured CO at 2.9–4.7 times its median of the previous three weeks (0.8 ppm), back to normal by Jul 15, consistent with generator use and traffic disruption. Check its NO₂ and PM2.5 in Phase 2.

## Final dataset

**5,557,574 monitor-days** (one row per instrument per day, 2021-01-01 to 2025-12-31). Assertions confirm a unique key, no missing values except `event_name`, every pollutant in every year, and yearly counts summing to the cleaning log's total. The data table keeps 23 of 37 columns; site details move to a `sites` table, cutting memory use from 1.42 GB to 867 MB (38.9%). The checkpoint is four gzip-compressed `.rds` files (`aqs_long_clean` 45.7 MiB; `sites`, 2,038 rows; `site_coverage`, 3,760 rows; `cleaning_log`), confirmed to reload identically, with a data dictionary and an MD5 manifest in `data/processed/`.

| Pollutant | 2021 | 2022 | 2023 | 2024 | 2025 |
|---|---|---|---|---|---|
| PM2.5 | 326,440 | 342,016 | 363,893 | 392,940 | 403,384 |
| Ozone | 385,054 | 378,275 | 378,388 | 377,196 | 371,275 |
| NO₂ | 155,608 | 154,585 | 152,565 | 150,886 | 148,199 |
| SO₂ | 151,733 | 145,542 | 140,521 | 131,647 | 124,532 |
| CO | 84,426 | 80,759 | 77,032 | 71,273 | 69,405 |

Row counts reflect network changes: PM2.5 rows grew 24% as FEM rows rose 33% (258,676 to 343,688) and FRM rows fell 12%, while reporting SO₂ and CO sites fell 18% (454 to 372) and 17% (265 to 219).
