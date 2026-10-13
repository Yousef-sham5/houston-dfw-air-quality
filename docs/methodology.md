# Phase 1 Methodology

October 13, 2026 · Yousef Shamsaldeen

## Data

The input is EPA AQS daily summary data for 2021–2025: 25 files and 8,930,992 rows covering PM2.5 (88101, FRM/FEM monitors only), ozone (44201), NO₂ (42602), SO₂ (42401) and CO (42101). Every column is read with an explicit type, codes are kept as text so leading zeros survive, and named assertions stop the script whenever an assumption fails. Each site gets a `site_id` such as "06-037-1103".

## Cleaning

Cleaning removed **3,373,418 rows (37.8%)**, almost all of them repeat summaries of a monitor-day already in the data.

| Step | Rows removed | Reason |
|---|---|---|
| Drop non-US sites | 9,982 | Monitors in Mexico near the border. Puerto Rico and the Virgin Islands stay in. |
| One averaging time per pollutant | 2,956,079 | Repeat summaries of the same day at other averaging times |
| Validate method codes | 315,860 | Raw T640/T640X PM2.5 (313,057), ozone method 901 with no FRM/FEM designation (2,776), blank codes (27) |
| Keep event-included values | 2,680 | Duplicate "Excluded" rows for event days |
| T640 firmware overlap | 338 | The same monitor-day under both firmware and corrected codes at 7 sites. The firmware value is kept. |
| 75% completeness rule | 88,478 | Days with less than 75% of expected measurements |
| Outside method range | 1 | One SO₂ maximum of 2,732 ppb, above the analyzer's 1,500 ppb limit |

- **T640:** EPA corrected older T640/T640X data (codes 736/738), and sites with updated firmware report corrected values directly (636/638). The raw codes (236/238) are dropped. In 2024–2025, 1,941 site-days had no corrected version and no other PM2.5 reading, so they were lost.
- **Collocated instruments** stay as separate rows and are averaged per site-day in Phase 2.
- **Nothing is imputed.** No analysis value is missing, and gaps in each instrument's record are flagged in their own table and left unfilled.
- **Negative and zero readings stay in.** They are instrument noise near zero, every one falls inside EPA's method limits, and removing them would push averages up. SO₂ has the most, at 16% of daily means. The Phase 3 distribution fits use a copy with these values set to half the detection limit.
- **Simplification:** incomplete days are dropped even when they already exceed a standard, so exceedance counts run slightly low.

## Metrics and units

| Pollutant | Averaging time kept | Metric | MW (g/mol) | Factor to µg/m³ |
|---|---|---|---|---|
| PM2.5 | 24-hour | Daily mean (`arithmetic_mean`) | n/a | 1 |
| Ozone | 8-hour running average | Daily maximum 8-hour | 48.00 | 1,962.0 per ppm |
| NO₂ | 1-hour | Daily maximum 1-hour | 46.01 | 1.881 per ppb |
| SO₂ | 1-hour | Daily maximum 1-hour | 64.06 | 2.618 per ppb |
| CO | 8-hour | Daily maximum 8-hour | 28.01 | 1,144.9 per ppm |

The gas metrics come from `first_max_value`. Gases are also stored in µg/m³ (`mean_ugm3`, `max_ugm3`) so pollutants can be compared on one scale: µg/m³ = ppb × MW / Vm, where Vm = RT/P = 24.465 L/mol at 25 °C and 1 atm. The original units are kept for NAAQS comparisons.

Calendar columns (`year`, `month`, `year_month`, `day_of_year`, `season`, `season_year`, `day_of_week`, `is_weekend`) are built from `date_local`. Seasons are meteorological, with December counted toward the following winter, so the partial winters of 2021 and 2026 are left out of seasonal comparisons.

## Events

Agency `event_type` flags only cover events documented for compliance, so `data/reference/events.csv` lists each event and gives matching monitor-days an `event_name` label. No rows are removed. Each event was confirmed against agency sources, and its states and dates were then set from the data: a state is included when its median PM2.5 at least doubles its baseline, and outage events last until most monitors are back online. Fireworks windows (July 4–5 and January 1, PM2.5 only) apply to every state. No monitor-day falls in two events, and `1b_event_checks.R` reruns these checks from the saved checkpoint.

The file holds eight events: Winter Storm Uri (February 2021, Texas), two wildfire smoke episodes in July 2021 (Northeast and Mid-Atlantic), Hurricane Ida (2021, Louisiana), two Canadian smoke episodes in June 2023 (Northeast, Mid-Atlantic, Great Lakes and Midwest), Hurricane Beryl (July 2024, Harris County) and the Los Angeles Palisades and Eaton fires (January 2025). The dates, states, pollutants and sources of each are in `data/reference/events.csv`.

- **Excluded:** the East Palestine derailment (February 2023). Columbiana County, Ohio had no PM2.5 or CO monitors, and nearby counties showed no rise.
- **Unlabeled:** rises with no documented cause in the Northeast (June 11–12, 2023) and Ventura County (January 22, 2025).
- **Early case-study findings:** during Winter Storm Uri (Feb 15–17, 2021), reporting NO₂ sites in Harris County fell from 12 to 1, and on Feb 19–23 county NO₂ ran 1.6–2.2 times its early-February median. During Hurricane Beryl, reporting sites fell from 20 to 3. CO at Houston North Loop (48-201-1052), the only CO site online on Jul 10–14, reached 2.9–4.7 times its median for the previous three weeks (0.8 ppm), a pattern consistent with generator use and traffic disruption.

## Site coverage

`n_years_active` (0 to 5) counts the years in which a site reaches 75% of its expected samples: 274 days for daily monitors, 92 for 1-in-3 samplers and 46 for 1-in-6. Seasonal ozone monitors need 184 days (75% of the most common March–October season), and those in Dallas and Tarrant counties need 207 because their season runs March–November (40 CFR 58 Appendix D, Table D-3).

| Sites active in all five years | Ozone | PM2.5 | NO₂ | SO₂ | CO |
|---|---|---|---|---|---|
| National | 964 | 769 | 312 | 301 | 135 |
| Houston (Harris County) | 17 | 4 | 8 | 4 | 1 |
| Dallas–Fort Worth (Dallas and Tarrant counties) | 6 | 3 | 4 | 0 | 0 |

The two regions are compared on ozone, NO₂ and PM2.5, and SO₂ is analyzed for Houston only.

## Final dataset

The cleaned data hold **5,557,574 monitor-days**, one row per instrument per day from 2021-01-01 to 2025-12-31. Assertions confirm a unique key, no missing values outside `event_name`, and every pollutant present in every year. The table keeps 23 of the 37 columns, with site details in a separate `sites` table, which cut its size in memory from 1.42 GB to 867 MB.

| Pollutant | 2021 | 2022 | 2023 | 2024 | 2025 |
|---|---|---|---|---|---|
| PM2.5 | 326,440 | 342,016 | 363,893 | 392,940 | 403,384 |
| Ozone | 385,054 | 378,275 | 378,388 | 377,196 | 371,275 |
| NO₂ | 155,608 | 154,585 | 152,565 | 150,886 | 148,199 |
| SO₂ | 151,733 | 145,542 | 140,521 | 131,647 | 124,532 |
| CO | 84,426 | 80,759 | 77,032 | 71,273 | 69,405 |

The counts track changes in the monitoring network. PM2.5 rows grew 24% as FEM rows rose 33% and FRM rows fell 12%, while reporting SO₂ sites fell 18% (454 to 372) and CO sites 17% (265 to 219). Trend work therefore uses five-year sites only.

**Saved files:** three gzip-compressed `.rds` checkpoints that later scripts read, `aqs_long_clean` (45.7 MiB), `sites` (2,038 rows) and `site_coverage` (3,760 rows), which reload identically. Two CSV records can be read on GitHub: `cleaning_log.csv` and `daily_validation.csv` (the eight final checks). `data/processed/` also holds a data dictionary of every saved column and an MD5 manifest of the `.rds` files.

## Hourly data for the case study (1c and 1d)

Hourly data are added for the case-study sites in two scripts of their own, so the daily pipeline stays as it is. `R/1c_site_selection.R` picks the sites. `R/1d_hourly_import_clean.R` reads the hourly files for those sites, flags and labels them, and checks them against the daily data. The hourly data serve the diurnal profiles in Phase 2 and the NO₂–ozone lag in Phase 4.

### Scope

- **Included:** ozone (44201), NO₂ (42602) and SO₂ (42401) for 2021–2025, which is 15 files.
- **CO is left out.** Texas has few CO monitors, levels sit far below the NAAQS, and NO₂ already captures the traffic signal.
- **PM2.5 is left out.** FRM monitors take 24-hour filter samples, so hourly PM2.5 would come only from FEM monitors and would differ from the daily method mix.
- **Wind and temperature come later.** A separate script, `R/1e_weather_import_clean.R`, is planned to import hourly wind speed, wind direction and temperature for the case-study sites, which would allow a pollution rose. Statements about sources are worded as "consistent with".

### Site selection (1c)

Candidates are monitors in Harris, Dallas and Tarrant counties with ozone, NO₂ or SO₂ data in all five years. Each candidate site goes into one of three groups: Houston Ship Channel (17 Harris County sites on the industrial east side: 15 from TCEQ's 2024 Region 12 monitoring memo, plus Park Place and Baytown Garth), other Houston (every other Harris County site except Seabrook Friendship Park, under the same weather as the Ship Channel) and Dallas–Fort Worth (Dallas and Tarrant county sites, the comparison metro).

- **Selection rules:** every full-coverage SO₂ monitor is kept (there are four, all in Harris County). For ozone and NO₂, only sites that measure both are considered, because the NO₂–ozone lag needs both series from one place. Each site is scored by its less complete pollutant. The top two are kept in each Houston group and the top one in each Dallas–Fort Worth county.
- **Park Place (48-201-0416)** was moved into the Ship Channel group. It is 6.4 km from the nearest Ship Channel monitor, against 9–53 km for the other candidates. TCEQ recommended deactivating its SO₂ monitor by December 31, 2025.
- **Baytown Garth (48-201-1017)** was also moved into the Ship Channel group. It is ozone-only, so it is not a pick.
- **Seabrook Friendship Park (48-201-1050)** is excluded from both Houston groups, because it sits roughly 5 km from the Bayport Industrial District, a complex of more than 60 chemical plants.
- **Near-road sites:** none of the four near-road NO₂ sites in these counties is a pick, so every picked site measures area-wide air. Houston North Loop (48-201-1052) was considered as a traffic reference and dropped, since its NO₂ covers 4 of 5 years.
- **Dallas–Fort Worth as a whole:** Dallas and Tarrant counties share one air basin and one ozone nonattainment area, so the comparison is between two polluted metros.
- **Deer Park #2 (48-201-1039)** moved from 4514 ½ Durant St to 4413 Glenwood Ave on May 30, 2025 and kept its AQS ID. EPA's files list a single coordinate pair for the site in all five years.

**Final picks:** 16 monitors at 9 sites. Percentages are the share of the 1,826 study days with data.

| Group | Ozone and NO₂ | SO₂ |
|---|---|---|
| Houston Ship Channel | Houston Deer Park #2 (48-201-1039; 97.3% / 97.6%), Houston East (48-201-1034; 95.8% / 97.8%) | Clinton (48-201-1035; 95.1%), Houston Deer Park #2 (95.1%), Park Place (48-201-0416; 95.6%) |
| Other Houston | Houston Harvard Street (48-201-0417; 95.5% / 94.7%), Houston Bayland Park (48-201-0055; 89.8% / 91.6%) | Houston Croquet (48-201-0051; 97.9%) |
| Dallas–Fort Worth | Dallas Redbird Airport Executive (48-113-0087; 93.9% / 86.5%), Grapevine Fairway (48-439-3009; 97.2% / 98.1%) | None |

Outputs: `data/reference/case_study_candidates.csv`, `data/reference/case_study_sites.csv` (each pick with a `selection_reason`) and `figures/case_study_sites.png`.

### Import (1d)

The 15 zips were downloaded from **Hourly Data → Criteria Gases** on 2026-10-12 (EPA's file list dates them 2026-06-25) and stay zipped in `data/raw/hourly/`. They total 572 MiB zipped and 17.5 GiB unzipped, and hold 79,402,201 rows, about nine times the daily data. Reading them at once would not fit on a 16 GB laptop, so each file is handled on its own:

1. Count the rows in each zip, 1 million lines at a time, and stop if any count differs from EPA's file list. All 15 match (`hourly_raw_row_counts.csv`).
2. Confirm that all 15 files share EPA's 24 documented columns, in order.
3. Read each zip with `readr::read_csv_chunked()` and explicit column types, parsing 16 of the 24 columns. Each 1-million-row chunk is cut to Texas rows and then to the 16 case-study monitors.
4. Save the filtered rows to `data/hourly_filtered/` (not tracked). A file already saved is skipped on the next run, so a crash loses at most one file.
5. Combine the 15 filtered files, confirm that rows read equal the raw counts, and inspect the values before any rule is set.
6. Add flags, timestamps, units and labels without removing any row.
7. Rebuild the daily maximums from the hourly values and stop if any day fails to match the daily table.
8. Save the checkpoint, three CSV records, and new rows in the data dictionary and manifest.

**What the import found:**

- **Rows:** 661,545 kept of 79,402,201 read (0.83%): ozone 250,556, NO₂ 244,766 and SO₂ 166,223. That is 94.3% of the 701,184 possible monitor-hours (16 monitors × 1,826 days × 24 hours). Hours without data are absent from EPA's files.
- **Monitors:** all 16 are present, each under one POC, with no duplicate hours and no missing measurement or detection limit. Houston Harvard Street starts on 2021-01-25 and Houston Bayland Park ozone on 2021-03-12. The other 13 start on 2021-01-01.
- **Methods:** all seven method codes are FRM or FEM in EPA's methods table.
- **Qualifiers:** the only one is `RT`, EPA's request-exclusion code for U.S. wildfire smoke, on 142 ozone hours (94 at Houston Bayland Park and 48 at Houston Harvard Street) on four dates in 2022.
- **High values:** one SO₂ hour is above the 75 ppb level of the 1-hour standard, 94 ppb at Clinton at 02:00 on 2024-01-13, and no NO₂ hour is above 100 ppb. This is a screening observation, since the standards are judged on three-year design values.

### Cleaning rules

No hourly row is removed. Each rule adds a column, so later phases can keep or leave out the affected hours.

- **Wildfire hours are kept and labeled.** `is_wildfire_flagged` is true on the 142 `RT` hours, matching the daily data, where event-affected values were kept. The script stops if any other qualifier appears, since a new code would need its own rule.
- **Readings below the detection limit are kept as reported,** zeros and negatives included, and `below_mdl` marks them. Replacing them with half the limit was rejected: the SO₂ limit is 2 ppb at three sites and 0.2 ppb at Deer Park #2, so the three coarser sites would average about 1.0–1.1 ppb against 0.3 ppb, a gap produced by the instruments.
- **Time stamps are local standard time.** EPA's file documentation says so, and `datetime_local`, built at a fixed UTC-6, equals EPA's GMT time on every row. In summer, a 7–9 a.m. CDT rush hour appears as hours 6–8, and every diurnal plot will say so. `datetime_utc` is kept for joins with weather data.
- **Units and labels:** `value_ppb` puts the three gases on one scale, and `value_ugm3` uses the same conversion as the daily data. Each row carries its `site_group`, `region`, site name, calendar columns and `event_name` (Winter Storm Uri covers 124 monitor-days and Hurricane Beryl 48).
- **Complete days:** `is_complete_day` is true with at least 75% of the day's hours (18 of 24), the rule EPA sets for NO₂ and SO₂ (40 CFR 50 Appendix S, section 3.2(b), and Appendix T, section 3.1(b)). 540 monitor-days fall short (249 NO₂, 151 ozone, 140 SO₂), and their hours stay in.
- **Valid ozone days:** EPA judges an ozone day on its 8-hour means. `n_valid_8hr_means` counts the valid means among the 17 that start at hours 7 to 23, and `is_valid_ozone_day` is true with at least 13 of them (40 CFR 50 Appendix U, section 3(d)). Of 10,685 ozone monitor-days, 10,424 are valid by this rule, and the two flags disagree on 186 days.

### Validation against the daily data

The hourly values rebuild the daily maximum that the daily pipeline kept for the same monitor and day. All **27,747 daily values** are reproduced exactly, along with the hour of each maximum: NO₂ 10,341, ozone 10,400 and SO₂ 7,006.

For NO₂ and SO₂ the daily value is the highest 1-hour reading. For ozone it is the highest 8-hour mean under the 2015 standard: the 17 means that start at hours 7 to 23 count, each needs 6 of its 8 hours, and each is cut off at three decimals in ppm (40 CFR 50 Appendix U, section 3(b) to 3(d)). A simpler rolling mean over all 24 start hours matched 96% of days. The script stops if any value fails to match, and the 14 checks are saved in `hourly_validation.csv`.

### Deer Park #2 check

To test for a level shift after the May 30, 2025 move, each Deer Park #2 hour was paired with the same hour at a neighbor that did not move, and the gap was averaged over June to December of each year. Houston East is the neighbor for ozone and NO₂, and Park Place for SO₂.

| Pollutant | Gap in 2021–2024 (ppb) | Gap in 2025, after the move (ppb) | Outside the earlier range |
|---|---|---|---|
| Ozone | 1.58 to 4.43 | 5.02 | Yes, by 0.6 ppb |
| NO₂ | -5.43 to -2.93 | -3.42 | No |
| SO₂ | 0.10 to 0.19 | 0.18 | No |

There is no clear shift. Only ozone falls outside its earlier range, by a small margin, and seven months is a short period to judge. No data are adjusted, and `is_post_relocation` marks the hours after the move.

### Harvard Street NO₂ check

Houston Harvard Street is the only monitor that changed method. Method 099 (detection limit 2.7 ppb) reports until 2024-04-09 and method 186 (5 ppb) from 2024-04-22, both chemiluminescence FRM methods. Each Harvard Street hour was paired with the same hour at two neighbors that kept one method, and the gap was averaged over May to December of each year.

| Neighbor | Gap in 2021–2023 (ppb) | Gap in 2024 (ppb) | Gap in 2025 (ppb) |
|---|---|---|---|
| Houston Bayland Park | 1.91 to 3.07 | 0.72 | 2.24 |
| Houston East | -2.36 to -1.82 | -3.70 | -1.89 |

The new method left no lasting shift, since the 2025 gap is back inside the earlier range. The first months on it read low, by 1.2 to 1.3 ppb against the earlier range. Over those months the instrument reported many exact zeros and no negative values: 649 of 5,119 hours (12.7%) from 2024-04-22 to 2024-11-30 are exactly 0 ppb, against 56 of 8,989 (0.6%) from December 2024 on. This pattern is consistent with a low baseline on the new analyzer that was later corrected, and the cause is not confirmed. No data are adjusted, and `is_post_method_change` marks the 14,108 hours on the new method.

### Saved files

- `hourly_case_study.rds`: 661,545 rows and 30 columns, 6.8 MiB, one row per monitor and hour.
- `hourly_cleaning_log.csv`, `hourly_validation.csv` and `hourly_monitor_summary.csv`: the rows after each step, the 14 checks, and one row per monitor with its method, detection limit, coverage and daily values reproduced.

## Known limits

- **SO₂ sits near zero, and three instruments are too coarse for it.** At Houston Croquet, Park Place and Clinton, 97.2–99.4% of hours are below the 2 ppb detection limit (64.9% at Deer Park #2, with a 0.2 ppb limit). SO₂ is best read through its spikes: hours at 2 ppb or more number 256 at Clinton, 1,062 at Croquet, 1,150 at Park Place and 803 at Deer Park #2. An average daily pattern is reliable only at Deer Park #2.
- **The Clinton SO₂ baseline drifts.** Negative readings rose from 64.6% of hours in 2021 to 89.5% in 2025, so SO₂ trends should use spike counts or daily maximums.
- **The daily table has no ozone rows on December 31.** EPA's yearly files cannot see the January 1 hours, so that day has 11 or 12 of its 17 eight-hour means and the 75% rule drops it, about 3,650 monitor-days nationally. The hourly table holds those days, and `is_valid_ozone_day` marks them as valid.
- **Deer Park #2** moved during the study, so its last seven months come from a different address. Its NO₂ also stepped up in 2024, a year before the move (June to December means of 5.9, 6.1, 6.3, 8.4 and 7.3 ppb). The cause is not known and will be examined in Phase 2.
- **Houston Harvard Street NO₂ read low in 2024.** The other-Houston group has only two NO₂ sites, so its 2024 mean is pulled down by roughly 0.6 ppb. NO₂ comparisons between groups for 2024 should be run with and without the hours flagged `is_post_method_change`. The daily table holds the same months under `method_code` 186 (594 days from 2024-04-23). The higher detection limit also lifts the share of hours flagged `below_mdl` from 16.0% to 50.6%, so that flag should be compared within one method.
- **Memory:** the daily import needs roughly 5.5 GB at its peak, so it may be slow on a machine with 8 GB.

## Sources

Regulation text was read on Cornell's Legal Information Institute. The official version is the eCFR ([Part 50](https://www.ecfr.gov/current/title-40/chapter-I/subchapter-C/part-50), [Part 58](https://www.ecfr.gov/current/title-40/chapter-I/subchapter-C/part-58)).

| Source | Used for |
|---|---|
| [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html) | The 25 daily and 15 hourly files, and `file_list.csv` with each file's row count |
| [EPA AirData file formats](https://aqs.epa.gov/aqsweb/airdata/FileFormats.html) | File columns, and local times as local standard time |
| [AQS methods code table](https://aqs.epa.gov/aqsweb/documents/codetables/methods_all.html) | FRM and FEM designations and method ranges |
| [AQS qualifier code table](https://aqs.epa.gov/aqsweb/documents/codetables/qualifiers.html) | The meaning of `RT` |
| [EPA NAAQS table](https://www.epa.gov/criteria-air-pollutants/naaqs-table) | Standard levels |
| [AirNow hourly data fact sheet](https://docs.airnowapi.org/docs/HourlyDataFactSheet.pdf) | Negative hourly readings as instrument drift |
| [40 CFR 50, Appendix S](https://www.law.cornell.edu/cfr/text/40/appendix-S_to_part_50), section 3.2(b) | NO₂: a day needs 75% of its hourly values |
| [40 CFR 50, Appendix T](https://www.law.cornell.edu/cfr/text/40/appendix-T_to_part_50), section 3.1(b) | SO₂: a day needs 75% of its hourly values |
| [40 CFR 50, Appendix U](https://www.law.cornell.edu/cfr/text/40/appendix-U_to_part_50), sections 3(b) to 3(d) | Ozone 8-hour means and valid days |
| [40 CFR 58, Appendix D](https://www.law.cornell.edu/cfr/text/40/appendix-D_to_part_58), Table D-3 | Ozone monitoring seasons by state |
| [TCEQ Region 12 2024 monitoring memo](https://www.tceq.texas.gov/downloads/toxicology/monitoring/air-evaluations/2024/reg12.pdf) | The 15 Ship Channel sites |
| [TCEQ 2024 state-initiative network changes](https://www.tceq.texas.gov/downloads/air-quality/air-monitoring/network/historical/2024-si-monitoring-network-changes.pdf) | The Park Place SO₂ deactivation recommendation |
| [Texas 2017 Annual Monitoring Network Plan (EPA archive)](https://19january2021snapshot.epa.gov/sites/static/files/2017-09/documents/txplan2017.pdf) | The four near-road NO₂ sites |
| [TCEQ DFW monitoring site list](https://www.tceq.texas.gov/airquality/airmod/data/dfw8h2/dfw8h2_site.html) | The Dallas–Fort Worth sites |
| [TCEQ biennial report on ozone nonattainment areas](https://www.tceq.texas.gov/publications/sfr/tceq-biennial-report/biennial-report-to-the-86th-legislature-fy2017-fy2018/agency-activities-air-quality-fy2017-2018) | The Dallas–Fort Worth nonattainment area |
| [Bayport Industrial District (Wikipedia)](https://en.wikipedia.org/wiki/Bayport_Industrial_District) | The industrial complex near Seabrook (a general reference) |

Event sources and their links are in the `source` column of `data/reference/events.csv`.
