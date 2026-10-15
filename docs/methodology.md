# Phase 1 Methodology

October 15, 2026 · Yousef Shamsaldeen

Phase 1 builds three cleaned datasets from EPA AQS files: daily data for five pollutants nationwide (`1a`, `1b`), hourly pollutant data for 16 case-study monitors (`1c`, `1d`) and hourly weather for the 9 case-study sites (`1e`). Every column is read with an explicit type, codes stay as text so leading zeros survive, and named assertions stop a script when an assumption fails.

## Daily data (1a, 1b)

The input is 25 daily summary files for 2021–2025 with 8,930,992 rows: PM2.5 (88101, FRM/FEM monitors only), ozone (44201), NO₂ (42602), SO₂ (42401) and CO (42101). Cleaning removed **3,373,418 rows (37.8%)**, almost all of them repeat summaries of a monitor-day already in the data.

| Step | Rows removed | Reason |
|---|---|---|
| Drop non-US sites | 9,982 | Monitors in Mexico. Puerto Rico and the Virgin Islands stay in |
| One averaging time per pollutant | 2,956,079 | Repeat summaries of the same day at other averaging times |
| Validate method codes | 315,860 | Raw T640/T640X PM2.5 (313,057), ozone method 901 (2,776), blank codes (27) |
| Keep event-included values | 2,680 | Duplicate "Excluded" rows for event days |
| T640 firmware overlap | 338 | One monitor-day under two codes at 7 sites; the firmware value is kept |
| 75% completeness rule | 88,478 | Days with less than 75% of expected measurements |
| Outside method range | 1 | One SO₂ maximum of 2,732 ppb, above the analyzer's 1,500 ppb limit |

- **T640 PM2.5:** EPA-corrected (736/738) and firmware-corrected (636/638) values are kept and the raw codes (236/238) dropped. In 2024–2025, 1,941 site-days had no corrected version and no other PM2.5 reading, so they were lost.
- **Kept as reported:** collocated instruments (averaged per site-day in Phase 2) and negative or zero readings, which are instrument noise inside EPA's method limits (SO₂ has the most, at 16% of daily means). Gaps are flagged and never imputed.
- **Simplification:** incomplete days are dropped even when they already exceed a standard, so exceedance counts run slightly low.

| Pollutant | Averaging time | Daily metric | MW (g/mol) | Factor to µg/m³ |
|---|---|---|---|---|
| PM2.5 | 24-hour | Mean | n/a | 1 |
| Ozone | 8-hour running | Maximum 8-hour | 48.00 | 1,962.0 per ppm |
| NO₂ | 1-hour | Maximum 1-hour | 46.01 | 1.881 per ppb |
| SO₂ | 1-hour | Maximum 1-hour | 64.06 | 2.618 per ppb |
| CO | 8-hour | Maximum 8-hour | 28.01 | 1,144.9 per ppm |

Gases are also stored in µg/m³ = ppb × MW / Vm, with Vm = RT/P = 24.465 L/mol at 25 °C and 1 atm, and the original units are kept for NAAQS comparisons. Calendar columns come from `date_local`, and seasons are meteorological, with December counted toward the following winter.

**Events:** `data/reference/events.csv` labels monitor-days with eight events confirmed against agency sources (Winter Storm Uri, two July 2021 smoke episodes, Hurricane Ida, two June 2023 Canadian smoke episodes, Hurricane Beryl and the January 2025 Los Angeles fires), plus July 4 and New Year fireworks windows for PM2.5. No rows are removed. States and dates were set from the data (median PM2.5 at least double its baseline, or outages until most monitors returned), and `1b_event_checks.R` reruns these checks. During Uri, reporting NO₂ sites in Harris County fell from 12 to 1. During Beryl, Houston North Loop, the only CO site online, reached 2.9–4.7 times its prior median, a pattern consistent with generator use and traffic disruption.

**Site coverage:** `n_years_active` counts the years in which a site reaches 75% of its expected samples: 274 days for daily monitors, 92 for 1-in-3, 46 for 1-in-6, and 184 or 207 for seasonal ozone (40 CFR 58 Appendix D, Table D-3).

| Sites active in all five years | Ozone | PM2.5 | NO₂ | SO₂ | CO |
|---|---|---|---|---|---|
| National | 964 | 769 | 312 | 301 | 135 |
| Houston (Harris County) | 17 | 4 | 8 | 4 | 1 |
| Dallas–Fort Worth (Dallas and Tarrant) | 6 | 3 | 4 | 0 | 0 |

**Result:** 5,557,574 monitor-days, one row per instrument per day from 2021-01-01 to 2025-12-31, in 23 columns. The network changed over the five years (PM2.5 rows grew 24%, while reporting SO₂ and CO sites fell 18% and 17%), so trend work uses five-year sites only.

## Hourly pollutants for the case study (1c, 1d)

The hourly data cover ozone, NO₂ and SO₂ for 2021–2025 and serve the diurnal profiles in Phase 2 and the NO₂–ozone lag in Phase 4. CO is left out (few Texas monitors, levels far below the NAAQS), and so is PM2.5 (hourly values would come only from FEM monitors).

**Site selection (1c):** candidates are monitors in Harris, Dallas and Tarrant counties with data in all five years, in three groups. The Houston Ship Channel group holds 15 sites from TCEQ's 2024 Region 12 memo plus Park Place (6.4 km from the nearest Ship Channel monitor) and Baytown Garth. Other Houston is the rest of Harris County, except Seabrook Friendship Park, about 5 km from the Bayport Industrial District. Dallas–Fort Worth, the comparison metro, pools Dallas and Tarrant counties, which share one air basin and one ozone nonattainment area. Every five-year SO₂ monitor is kept. For ozone and NO₂, only sites measuring both count, ranked by their less complete pollutant: the top two in each Houston group and the top one in each Dallas–Fort Worth county. No near-road site is picked, and the site IDs are in `data/reference/case_study_sites.csv`.

| Group | Ozone and NO₂ (share of days with data) | SO₂ |
|---|---|---|
| Houston Ship Channel | Deer Park #2 (97.3% / 97.6%), Houston East (95.8% / 97.8%) | Clinton (95.1%), Deer Park #2 (95.1%), Park Place (95.6%) |
| Other Houston | Harvard Street (95.5% / 94.7%), Bayland Park (89.8% / 91.6%) | Croquet (97.9%) |
| Dallas–Fort Worth | Dallas Redbird (93.9% / 86.5%), Grapevine Fairway (97.2% / 98.1%) | None |

**Import (1d):** the 15 hourly zips hold 79,402,201 rows (572 MiB zipped, 17.5 GiB unzipped), too many to load at once on a 16 GB laptop. Each zip's rows are counted and matched to EPA's file list, its header is checked, and it is read in 1-million-row chunks that keep only the 16 monitors, with each file cached so a crash loses at most one. This keeps 661,545 rows, 94.3% of the possible monitor-hours, with no duplicate hours, no missing values and FRM or FEM methods only.

**Flags:** no hourly row is removed. Each rule adds a column, so later phases can keep or leave out the affected hours.

- `is_wildfire_flagged`: the 142 ozone hours carrying EPA's `RT` wildfire qualifier.
- `below_mdl`: readings below the detection limit, kept as reported. Half-limit substitution would make the 2 ppb SO₂ instruments average three to four times the 0.2 ppb one.
- `is_complete_day`: at least 18 of 24 hours (40 CFR 50 Appendices S and T). `is_valid_ozone_day`: at least 13 of the 17 eight-hour means (Appendix U).
- Times are local standard time at a fixed UTC-6, so a summer 7–9 a.m. CDT rush hour appears as hours 6–8. `datetime_utc` joins the weather data.

**Validation:** the hourly values rebuild all **27,747 daily maximums** in the daily table, with the hour of each (NO₂ 10,341, ozone 10,400, SO₂ 7,006). Ozone uses the 2015 rule: 17 eight-hour means starting at hours 7 to 23, each needing 6 of 8 hours, truncated to three decimals in ppm. The script stops on any mismatch.

**Neighbour checks:** two monitors changed during the study. Each was compared hour by hour with neighbours that did not change, and the gap was averaged by year. Nothing is adjusted, and `is_post_relocation` and `is_post_method_change` mark the hours.

| Monitor | Change | Gap before (ppb) | Gap after (ppb) |
|---|---|---|---|
| Deer Park #2 ozone (vs Houston East) | Moved on 2025-05-30 | 1.58 to 4.43 | 5.02 |
| Deer Park #2 NO₂ (vs Houston East) | Moved on 2025-05-30 | −5.43 to −2.93 | −3.42 |
| Deer Park #2 SO₂ (vs Park Place) | Moved on 2025-05-30 | 0.10 to 0.19 | 0.18 |
| Harvard Street NO₂ (vs Bayland Park) | Method 099 to 186 on 2024-04-22 | 1.91 to 3.07 | 0.72 (2024), 2.24 (2025) |
| Harvard Street NO₂ (vs Houston East) | Method 099 to 186 on 2024-04-22 | −2.36 to −1.82 | −3.70 (2024), −1.89 (2025) |

Deer Park #2 shows no clear shift; only ozone falls outside its range, by 0.6 ppb. Harvard Street read about 1.2–1.3 ppb low in its first months on the new method, with 12.7% of hours at exactly 0 ppb until 2024-11-30 against 0.6% afterwards. That pattern is consistent with a low baseline on the new analyzer that was later corrected, and the cause is not confirmed.

## Hourly weather for the case study (1e)

The 10 weather zips (`hourly_WIND` and `hourly_TEMP`, 2021–2025) hold 95,477,439 rows, all matching EPA's file list, and are read the same way as in 1d. That keeps 1,008,615 rows of resultant wind speed (knots), resultant wind direction and temperature (°F) for the 9 sites. No row is removed after that. The data are reshaped to one row per site and hour, with m/s and °C added, and join the pollutant table on `site_id` and `datetime_utc`.

- **Harvard Street** has no wind sensor, and its temperature starts on 2023-04-19. Its temperature comes from Bayland Park (about 13 km away) and its wind from Croquet (about 18 km), and every row names its source sites. Against Harvard Street's own sensor, Bayland Park averages −1.02 °F, with 83.7% of hours within 2 °F (r = 0.995). The site's own readings are kept in `own_temp_f`.
- **Calm hours:** `is_calm` marks wind below 0.5 m/s (EPA-454/R-99-005, section 6.2.3), from 1.2% of hours at Dallas Redbird to 11.0% at Croquet. Direction is unreliable in calm air, so these hours stay out of direction sectors, and they stay in the data because concentrations change in calm air.
- **Wind spike:** `is_wind_spike` flags an hour more than 20 knots above both neighbouring hours. Only one qualifies: 41.7 knots at Bayland Park on 2024-01-24, between 6.9 and 3.2 knots. The next largest jump at any site is 13.9 knots.
- **Direction:** 12 sectors of 30°, plus east-west and north-south components so mean directions average correctly (section 6.2.2).
- **Labels:** site group, region, events (Uri on 113 site-days, Beryl on 27) and 18-of-24-hour complete-day flags for wind and temperature.

**Sensor replacements:** five sites switched to the Met One AIO2 sonic sensor (method 069), compared with a neighbour that kept one sensor over the 365 days before and after. Croquet, Park Place and Dallas Redbird kept their older sensors. Nothing is adjusted, and `is_sonic_temp` and `is_sonic_wind` mark the readings.

| Site | Sonic temperature from | Sonic wind from | Days without wind | Calm-share change vs neighbour |
|---|---|---|---|---|
| Bayland Park | 2022-04-22 | 2023-08-09 | 474 | −2.0 points |
| Grapevine Fairway | 2022-08-31 | 2023-07-12 | 314 | −1.0 points |
| Deer Park #2 | 2023-02-22 | 2023-07-12 | 161 | −1.3 points |
| Clinton | 2023-06-16 | 2023-06-16 | 0 | +2.0 points |
| Houston East | 2024-01-09 | 2024-01-09 | 0 | −3.8 points |

Four of the five recorded fewer calm hours than their neighbour after switching, consistent with sonic sensors registering lighter winds. Temperature is present for 97.9–99.9% of pollutant hours. Wind is present for at least 98.4% at most sites, about 90.5% at Deer Park #2, about 82.5% at Grapevine and 67.8–71.4% at Bayland Park.

## Saved files

All in `data/processed/`. The `.rds` files are what later scripts read, and the CSV records can be read on GitHub.

- **Daily:** `aqs_long_clean.rds` (5,557,574 rows, 45.7 MiB), `sites.rds`, `site_coverage.rds`, `cleaning_log.csv`, `daily_validation.csv` (8 checks).
- **Hourly pollutants:** `hourly_case_study.rds` (661,545 rows × 30 columns), `hourly_cleaning_log.csv`, `hourly_validation.csv` (14 checks), `hourly_monitor_summary.csv`, `hourly_raw_row_counts.csv`.
- **Hourly weather:** `hourly_weather.rds` (390,791 rows × 34 columns), `weather_cleaning_log.csv`, `weather_validation.csv` (14 checks), `weather_site_summary.csv`, `weather_sensor_check.csv`, `weather_raw_row_counts.csv`.
- `data_dictionary.csv` describes every saved column, and `checkpoint_manifest.csv` lists the size and MD5 of each `.rds` file.

## Known limits

- **SO₂ sits near zero.** At Croquet, Park Place and Clinton, 97.2–99.4% of hours are below the 2 ppb detection limit, and Clinton's baseline drifts (64.6% negative hours in 2021, 89.5% in 2025). SO₂ is best read through spikes or daily maximums. An average daily pattern is reliable only at Deer Park #2.
- **The daily table has no ozone rows on December 31.** EPA's yearly files cannot see January 1, so the 75% rule drops that day (about 3,650 monitor-days nationally). The hourly table holds these days.
- **Deer Park #2** moved in 2025, and its NO₂ stepped up in 2024 for an unknown reason, to be examined in Phase 2.
- **Harvard Street NO₂ read low in 2024,** which pulls the other-Houston 2024 mean down by roughly 0.6 ppb. Group comparisons for 2024 should run with and without `is_post_method_change` hours. Its detection limit also rose from 2.7 to 5 ppb, so `below_mdl` should be compared within one method.
- **Weather:** wind is missing for 474 days at Bayland Park, 314 at Grapevine and 161 at Deer Park #2 around their sensor replacements. Harvard Street's weather comes from neighbours. Wind direction is taken as where the wind blows from, the usual convention, which EPA's documentation was not checked to confirm.
- **Memory:** the daily import peaks at roughly 5.5 GB, so it may be slow on a machine with 8 GB.

## Sources

Regulation text was read on Cornell's Legal Information Institute. The official version is the eCFR ([Part 50](https://www.ecfr.gov/current/title-40/chapter-I/subchapter-C/part-50), [Part 58](https://www.ecfr.gov/current/title-40/chapter-I/subchapter-C/part-58)).

| Source | Used for |
|---|---|
| [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html) | The 25 daily, 15 hourly pollutant and 10 hourly weather files, and `file_list.csv` with each file's row count |
| [EPA, Meteorological Monitoring Guidance for Regulatory Modeling Applications (EPA-454/R-99-005, 2000)](https://www.epa.gov/sites/production/files/2020-10/documents/mmgrma_0.pdf) | Calm wind below 0.5 m/s (section 6.2.3, Table 5-2) and vector averaging of wind direction (section 6.2.2) |
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
