# Methodology

October 26, 2026 · Yousef Shamsaldeen

Phase 1 builds three cleaned datasets from EPA AQS files: daily data for five pollutants nationwide (`1a`, `1b`), hourly pollutants for 16 case-study monitors (`1c`, `1d`) and hourly weather for the 9 case-study sites (`1e`). Phase 2 explores them: the national daily picture (`2a`), the daily case study (`2b`) and, next, the hourly case study (`2c`). Every column is read with an explicit type, codes stay as text, and named assertions stop a script when an assumption fails.

## Daily data (1a, 1b)

The 25 daily files for 2021–2025 hold 8,930,992 rows: PM2.5 (88101, FRM/FEM monitors only), ozone (44201), NO₂ (42602), SO₂ (42401) and CO (42101). Cleaning removed **3,373,418 rows (37.8%)**, almost all repeat summaries of a monitor-day already in the data.

| Step | Rows removed | Reason |
|---|---|---|
| Drop non-US sites | 9,982 | Monitors in Mexico. Puerto Rico and the Virgin Islands stay in |
| One averaging time per pollutant | 2,956,079 | Repeat summaries of the same day at other averaging times |
| Validate method codes | 315,860 | Raw T640/T640X PM2.5 (313,057), ozone method 901 (2,776), blank codes (27) |
| Keep event-included values | 2,680 | Duplicate "Excluded" rows for event days |
| T640 firmware overlap | 338 | One monitor-day under two codes at 7 sites; the firmware value is kept |
| 75% completeness rule | 88,478 | Days with less than 75% of expected measurements |
| Outside method range | 1 | One SO₂ maximum of 2,732 ppb, above the analyzer's 1,500 ppb limit |

- **T640 PM2.5:** the corrected codes (736/738, 636/638) are kept and the raw codes (236/238) dropped. 1,941 site-days in 2024–2025 had no corrected value and no other PM2.5 reading, so they were lost.
- **Kept as reported:** collocated instruments (averaged per site-day in Phase 2) and negative or zero readings inside method limits. Gaps are flagged and never imputed. Incomplete days are dropped even when they exceed a standard, so exceedance counts run slightly low.
- **Daily metrics:** PM2.5 24-hour mean, ozone and CO maximum 8-hour, NO₂ and SO₂ maximum 1-hour. Gases are also stored in µg/m³ = ppb × MW / 24.465 (25 °C, 1 atm; MW 48.00 ozone, 46.01 NO₂, 64.06 SO₂, 28.01 CO), and original units are kept for NAAQS comparisons. Seasons are meteorological, with December in the following winter.

**Events:** `data/reference/events.csv` holds 22 events in 203 state or county rows: Winter Storm Uri, Hurricanes Ida and Beryl, the January 2025 Los Angeles fires, the March 2025 Plains dust storm and 17 smoke episodes. July 4–5 and January 1 are fireworks windows for PM2.5. No rows are removed: 32,024 instrument-days (0.58%) carry a label.

- **Inclusion rule:** a smoke, fire or dust row stays only if, on at least one of its days, the area's median PM2.5 is at least twice its baseline-week median and a site-day is above 35 µg/m³. `1b_event_checks.R` rechecks all 200 such rows. Every row cites a source.
- **Outages:** Uri, Ida and Beryl run from when monitors went offline until most returned.
- **Share of high days:** of 8,654 PM2.5 site-days above 35 µg/m³, 39.4% fall on an event day and 3.4% in a fireworks window (event share 4.9% in 2024, 67.6% in 2023).

**Site coverage:** `n_years_active` counts the years in which a site reaches 75% of its expected samples, using the seasonal ozone lengths in 40 CFR 58 Appendix D, Table D-3.

| Sites active in all five years | Ozone | PM2.5 | NO₂ | SO₂ | CO |
|---|---|---|---|---|---|
| National | 964 | 769 | 312 | 301 | 135 |
| Houston (Harris County) | 17 | 4 | 8 | 4 | 1 |
| Dallas–Fort Worth (Dallas and Tarrant) | 6 | 3 | 4 | 0 | 0 |

**Result:** 5,557,574 monitor-days in 23 columns. PM2.5 rows grew 24% while reporting SO₂ and CO sites fell 18% and 17%, so trend work uses five-year sites only.

## Hourly pollutants (1c, 1d)

Hourly ozone, NO₂ and SO₂ feed the daily profiles in Phase 2 and the NO₂–ozone lag in Phase 4. CO (few Texas monitors) and PM2.5 (hourly values from FEM monitors only) are left out.

**Site groups (1c):** a Harris County site is in the Ship Channel group when it lies within **7.5 km** of the 12 USACE land-cut channel sections from Morgan's Point to the Turning Basin (`data/reference/ship_channel.geojson`), measured on a flat map centred on 29.7° N. The cutoff falls between Deer Park #2 (6.94 km) and North Wayside (8.49 km), and no site lies within 0.5 km of it. Other Houston is every other Harris site except Seabrook Friendship Park, next to the Bayport Industrial District. Sites 7.5 to 15 km away form a transition band. Distances are in `data/reference/harris_site_channel_distance.csv`.

| Group | Sites with data (km to the channel) |
|---|---|
| Ship Channel | Lynchburg Ferry 0.35, Clinton 0.73, Pleasantville 2.05, Houston East 3.40, Finnigan Park 3.41, Baytown 3.79, Park Place 4.80, Channelview 5.65, Deer Park #2 6.94 |
| Other Houston, transition band | North Wayside 8.49, Harvard Street 10.28, Monroe 10.46, Baytown Garth 10.87, North Loop 11.71 |
| Other Houston, over 15 km | Aldine 16.85, Southwest Freeway 19.44, Bayland Park 20.67, Lang 21.19, Croquet 22.15, Westhollow 33.20, Northwest Harris County 48.88 |

An earlier grouping, the sites in TCEQ's 2024 Region 12 air toxics memo plus Park Place and Baytown Garth, is kept as a sensitivity check. It differs from the distance rule for Baytown, Baytown Garth and the two sites opened in November 2025.

**Hourly picks (1c):** Dallas–Fort Worth pools Dallas and Tarrant counties, one ozone nonattainment area. Every five-year SO₂ monitor is kept. For ozone and NO₂, sites measuring both are ranked by their less complete pollutant: the top two in each Houston group and the top one in each Dallas–Fort Worth county, with no near-road sites. Picks are in `data/reference/case_study_sites.csv` and mapped in `figures/phase1/case_study_sites.png`.

| Group | Ozone and NO₂ (share of days with data) | SO₂ |
|---|---|---|
| Houston Ship Channel | Deer Park #2 (97.3% / 97.6%), Houston East (95.8% / 97.8%) | Clinton (95.1%), Deer Park #2 (95.1%), Park Place (95.6%) |
| Other Houston | Harvard Street (95.5% / 94.7%), Bayland Park (89.8% / 91.6%) | Croquet (97.9%) |
| Dallas–Fort Worth | Dallas Redbird (93.9% / 86.5%), Grapevine Fairway (97.2% / 98.1%) | None |

**Import (1d):** the 15 hourly zips hold 79,402,201 rows (17.5 GiB unzipped). Each is read in 1-million-row chunks that keep only the 16 monitors, its row count must match EPA's file list, and the kept rows are cached per zip. The result is 661,545 rows, 94.3% of possible monitor-hours, with no duplicates and FRM or FEM methods only.

**Flags:** no hourly row is removed. `is_wildfire_flagged` marks the 142 ozone hours with EPA's `RT` qualifier; `event_name` marks Uri and Beryl; `below_mdl` marks readings below the detection limit, kept as reported; `is_complete_day` needs 18 of 24 hours (Appendices S and T) and `is_valid_ozone_day` 13 of 17 eight-hour means (Appendix U). Times are local standard time (UTC-6), so a 7–9 a.m. CDT rush hour appears as hours 6–8.

**Validation:** the hourly values rebuild all **27,747 daily maximums** in the daily table, with the hour of each. Ozone uses the 2015 rule: 17 eight-hour means starting at hours 7 to 23, each needing 6 of 8 hours, truncated to three decimals.

**Neighbour checks:** two monitors changed during the study. Each was compared hour by hour with a neighbour that did not, and the hours are marked with `is_post_relocation` and `is_post_method_change` and left unadjusted.

| Monitor | Change | Gap before (ppb) | Gap after (ppb) |
|---|---|---|---|
| Deer Park #2 ozone (vs Houston East) | Moved on 2025-05-30 | 1.58 to 4.43 | 5.02 |
| Deer Park #2 NO₂ (vs Houston East) | Moved on 2025-05-30 | −5.43 to −2.93 | −3.42 |
| Deer Park #2 SO₂ (vs Park Place) | Moved on 2025-05-30 | 0.10 to 0.19 | 0.18 |
| Harvard Street NO₂ (vs Bayland Park) | Method 099 to 186 on 2024-04-22 | 1.91 to 3.07 | 0.72 (2024), 2.24 (2025) |

Deer Park #2 shows no clear shift. Harvard Street read about 1.2–1.3 ppb low in its first months on the new method, with 12.7% of hours at exactly 0 ppb until 2024-11-30, consistent with a low baseline that was later corrected. The cause is not confirmed.

## Hourly weather (1e)

The 10 weather zips (95,477,439 rows) are read as in 1d, giving wind speed, wind direction and temperature for the 9 sites, one row per site and hour, joined to the pollutants on `site_id` and `datetime_utc`.

- **Harvard Street** has no wind sensor and its temperature starts in 2023, so it takes temperature from Bayland Park (about 13 km) and wind from Croquet (about 18 km). Its own temperature is kept in `own_temp_f`.
- **Calm hours:** `is_calm` marks wind below 0.5 m/s (EPA-454/R-99-005, section 6.2.3), 1.2% to 11.0% of hours by site. Calm hours stay out of direction sectors.
- **Direction** is where the wind blows from (section 2.2), in 12 sectors of 30°, with east-west and north-south components so averages work (section 6.2.2).
- **Sensor replacements:** five sites switched to sonic sensors in 2022–2024, and four then logged fewer calm hours than a neighbour. `is_sonic_temp` and `is_sonic_wind` mark the readings, and `weather_sensor_check.csv` holds the comparison. Wind is present for at least 98.4% of pollutant hours at most sites, about 90.5% at Deer Park #2, 82.5% at Grapevine and 68–71% at Bayland Park.

## National daily analysis (2a)

Collocated instruments are averaged per site and day (5,198,843 site-days). Levels, NAAQS values, profiles and weekend ratios use five-year sites. Exceedance rates use all sites, per 1,000 site-days. Event and fireworks days are their own class.

**Network (figure 2A.1):** reporting SO₂ sites fell 18.1% and CO sites 17.4% from 2021 to 2025. The FEM share of PM2.5 rose from 79.2% to 85.2%, and FEM reads a median 0.3 to 0.5 µg/m³ above FRM on the same site-day, so national PM2.5 can drift up from the instrument mix alone.

**NAAQS screening (figure 2A.2):** each site-year gets its standard's statistic (4th-highest ozone day, the 98th or 99th percentile day from Table 1 of Appendices N, S and T, the mean of quarterly means for annual PM2.5), rounded as the standard specifies. A three-year average gives a design-value screen.

| Share of five-year sites above the level | 2021 | 2022 | 2023 | 2024 | 2025 | Three-year screen |
|---|---|---|---|---|---|---|
| Ozone 8-hour | 23.4% | 19.8% | 42.7% | 25.8% | 16.4% | 22.8% to 24.1% |
| PM2.5 annual | 27.7% | 12.7% | 39.0% | 11.3% | 13.4% | 16.4% to 22.3% |
| PM2.5 24-hour | 11.2% | 3.6% | 8.2% | 4.4% | 7.8% | 2.9% to 5.9% |

**Exceedances (figures 2A.3 and 2A.4):** labelled events hold 39.9% of PM2.5 exceedance days (68.2% in 2023), and EPA's exceptional-event flag marks 14.4% of these. Houston and Dallas–Fort Worth rank 6th and 8th of 353 metro areas for ozone exceedance days.

**Seasons (figures 2A.5 and 2A.6):** NO₂ and CO peak in winter at about 1.7 times their lows, ozone in June and PM2.5 in July. Events made June 2023 the highest PM2.5 month (12.8 µg/m³, 10.6 without event days).

**Weekends (figure 2A.7):** April to October, ordinary days, with Memorial Day, Independence Day and Labor Day left out. The weekend-to-weekday ratio is 0.805 for NO₂ and 0.987 for ozone at the median site. Weekend ozone rises in Los Angeles (+5.0%), consistent with VOC-limited ozone, and falls in Houston (−4.0%) and Dallas–Fort Worth (−4.8%).

## Daily case study (2b)

**Sites (section 1, figure 2B.1):** the five-year sites in each group, from the checkpoint 2a saves. `case_study_site_inventory.csv` lists all 33 sites with coverage, method history, distance and role.

| Five-year sites | Ship Channel | Other Houston | Dallas–Fort Worth |
|---|---|---|---|
| PM2.5 | 3 | 1 | 3 |
| Ozone | 6 | 10 | 6 |
| NO₂ | 4 | 3 | 4 |
| SO₂ | 3 | 1 | 0 |

Every comparison is rerun under each check that applies:
- without the other Houston sites in the transition band
- with the memo-list groups
- with four-year sites added (PM2.5 and NO₂, near-road sites left out)
- without Deer Park #2 after its move
- without days after the Westhollow ozone, Park Place NO₂ and Harvard Street NO₂ method changes
- without near-road California Parkway North PM2.5
- without event and fireworks days
- only on days when at least half of each group's sites report

Groups hold 1 to 10 sites, so results describe these sites.

**Ozone (section 2, figure 2B.2):** Dallas–Fort Worth has the most exceedance days per site in every year (6.2 to 16.5) and the Ship Channel the fewest in 3 of 5, consistent with fresh NO using up ozone near its sources. Both Houston groups dip in July, and no exceedance falls on an event day.

**NO₂ (section 3, figure 2B.3):** the median site's yearly mean of daily peaks. The Ship Channel is highest in every year (19.3 to 20.3 ppb, against 17.2 to 19.4 for other Houston and 15.4 to 16.9 for Dallas–Fort Worth) under every check. NO₂ falls with distance from the channel: Spearman −0.54 (p = 0.22) for 7 sites, −0.72 (p = 0.02) with 3 four-year sites added. The highest 98th percentile is 55 ppb, against the 100 ppb standard.

**PM2.5 (section 4, figure 2B.4):** the annual value is the mean of quarterly means (Appendix N). Every group sits near 9.0 µg/m³, all seven sites were above it in 2023, and distance shows no pattern, consistent with regional PM2.5. Of 19 site-days above 35 µg/m³, 14 fall on five dates, including 2024-05-09 and 2024-05-27, which have no labelled cause.

**SO₂ (section 5, figure 2B.5):** read through spike days (daily peak of 5 ppb or more). Croquet, 22 km from the channel, has more spike days than the Ship Channel site average in every year, mostly in summer. 74% of its summer spike hours come with wind from the 210° and 240° sectors, which blow 20% of summer hours, consistent with a source to its southwest. One day tops 75 ppb (Clinton, 94 ppb, 2024-01-13).

**Events (section 6, figure 2B.6):** Uri and Beryl against the same dates in the other four years. During Beryl the Ship Channel averaged 20% of monitors reporting (none on July 8 to 10) while Dallas–Fort Worth kept 100%. Uri raised PM2.5 to 1.2 to 1.6 times normal and cut NO₂ to 0.59 to 0.85 times. During Beryl, Houston NO₂ ran about 2.8 times normal at the few sites still on, consistent with generators and disrupted traffic. SO₂ is left out of the level ratios because it sits near zero.

**Same-day differences (section 7, figure 2B.7):** each group's daily value is the mean of its reporting sites, and the difference between two groups on the same day cancels most shared weather. 95% ranges come from a moving-block bootstrap (1,000 resamples of 14-day blocks, seed 2026), because neighbouring days are correlated (lag-one 0.23 to 0.46). About 1,800 days per comparison.

| Same-day median (95% range) | Ship Channel minus other Houston | Houston minus Dallas–Fort Worth |
|---|---|---|
| NO₂ (ppb) | +1.15 (+0.81 to +1.41) | +1.77 (+1.26 to +2.26) |
| Ozone (ppb) | −0.97 (−1.11 to −0.77) | −4.00 (−4.87 to −3.27) |
| SO₂ (ppb) | +0.13 (+0.10 to +0.20) | No Dallas–Fort Worth site |
| PM2.5 (µg/m³) | −0.20 (−0.40 to −0.03) | +0.47 (+0.22 to +0.73) |

The Ship Channel's NO₂ lead holds in every year and is consistent with nearby NOx sources; its lower ozone is consistent with fresh NO using up ozone.

**Validation (section 8, figure 2B.8):** a run is the main site set or one check. Ship Channel minus other Houston keeps its sign with a range clear of zero in 8 of 8 runs for NO₂, 6 of 6 for SO₂, 6 of 7 for ozone (all but the memo-list groups) and 3 of 8 for PM2.5, so the PM2.5 gap does not hold up. Houston minus Dallas–Fort Worth holds in all 23 runs. With a second seed (2027) every range end moves less than 10% of its range's width, and the PM2.5 Ship Channel range reaches zero. `case_study_validation.csv` holds 18 observed / expected / passed checks.

## Saved files

All in `data/processed/`. Later scripts read the `.rds` files; the CSV records can be read on GitHub. `data_dictionary.csv` describes every saved column and `checkpoint_manifest.csv` lists the size and MD5 of each `.rds` file.

- **Daily:** `aqs_long_clean.rds` (5,557,574 rows, 45.7 MiB), `sites.rds`, `site_coverage.rds`, `cleaning_log.csv`, `daily_validation.csv`.
- **Hourly pollutants:** `hourly_case_study.rds` (661,545 rows), `hourly_cleaning_log.csv`, `hourly_validation.csv`, `hourly_monitor_summary.csv`, `hourly_raw_row_counts.csv`.
- **Hourly weather:** `hourly_weather.rds` (390,791 rows), `weather_cleaning_log.csv`, `weather_validation.csv`, `weather_site_summary.csv`, `weather_sensor_check.csv`, `weather_raw_row_counts.csv`.
- **Case-study checkpoint (2a, read by 2b):** `daily_case_study.rds` (109,365 site-days), `daily_case_study_instruments.rds`, `daily_case_study_months.rds`.
- **Case-study records (2b):** `case_study_site_inventory.csv`, a `site_years` and a `by_group` table per gas, `case_study_event_reporting.csv`, `case_study_event_levels.csv`, `case_study_paired_differences.csv`, `case_study_validation.csv`.

Figures are in `figures/phase1/` and `figures/phase2/`, numbered in figure order (`2a.01` to `2a.07`, `2b.01` to `2b.08`). They use Inter Tight, Inter and IBM Plex Mono, bundled in `fonts/` under the SIL Open Font Licence, at the report width of 6.5 inches.

## Known limits

- **SO₂ sits near zero.** 97.2–99.4% of hours at Croquet, Park Place and Clinton are below the 2 ppb detection limit, and Clinton's baseline drifts (negative days rose from 32% to 56%), so its spike count may run low. SO₂ is read through spikes and daily maximums.
- **No ozone rows on December 31** in the daily table, because EPA's yearly files cannot see January 1 (about 3,650 monitor-days nationally). The hourly table holds these days.
- **Deer Park #2** moved in 2025, and its NO₂ stepped up in 2024 for an unknown reason. EPA lists one coordinate pair for all five years, so the move cannot be seen in the site data.
- **Method changes:** Park Place and Harvard Street NO₂ read lower after their changes. 2b runs every comparison with and without those days, and `below_mdl` should be compared within one method.
- **Weather:** wind is missing for 474 days at Bayland Park, 314 at Grapevine and 161 at Deer Park #2 around sensor replacements, and Harvard Street's weather comes from neighbours.
- **Site groups:** distance to the channel water stands in for distance to the plants along it. Other Houston has one five-year PM2.5 site (Aldine), so PM2.5 group results lean on the four-year check.
- **Memory:** the daily import peaks at about 5.5 GB.

## Sources

Regulation text was read on Cornell's Legal Information Institute. The official version is the eCFR ([Part 50](https://www.ecfr.gov/current/title-40/chapter-I/subchapter-C/part-50), [Part 58](https://www.ecfr.gov/current/title-40/chapter-I/subchapter-C/part-58)).

| Source | Used for |
|---|---|
| [EPA AirData download page](https://aqs.epa.gov/aqsweb/airdata/download_files.html) | The 25 daily, 15 hourly pollutant and 10 hourly weather files, and `file_list.csv` with each file's row count |
| [EPA, Meteorological Monitoring Guidance for Regulatory Modeling Applications (EPA-454/R-99-005, 2000)](https://www.epa.gov/sites/production/files/2020-10/documents/mmgrma_0.pdf) | Wind direction as where the wind blows from (section 2.2), calm wind below 0.5 m/s (section 6.2.3, Table 5-2) and vector averaging (section 6.2.2) |
| [EPA AirData file formats](https://aqs.epa.gov/aqsweb/airdata/FileFormats.html) | File columns, and local times as local standard time |
| [AQS methods code table](https://aqs.epa.gov/aqsweb/documents/codetables/methods_all.html) | FRM and FEM designations and method ranges |
| [AQS qualifier code table](https://aqs.epa.gov/aqsweb/documents/codetables/qualifiers.html) | The meaning of `RT` |
| [EPA NAAQS table](https://www.epa.gov/criteria-air-pollutants/naaqs-table) | Standard levels |
| [AirNow hourly data fact sheet](https://docs.airnowapi.org/docs/HourlyDataFactSheet.pdf) | Negative hourly readings as instrument drift |
| [40 CFR 50, Appendix N](https://www.law.cornell.edu/cfr/text/40/appendix-N_to_part_50), Table 1 and section 4.3 | PM2.5: 98th percentile ranks, quarterly means and rounding |
| [40 CFR 50, Appendix S](https://www.law.cornell.edu/cfr/text/40/appendix-S_to_part_50), sections 3.2(b) and 4.2(c), Table 1 | NO₂: complete days, 98th percentile ranks and rounding |
| [40 CFR 50, Appendix T](https://www.law.cornell.edu/cfr/text/40/appendix-T_to_part_50), sections 3.1(b) and 4.1(c), Table 1 | SO₂: complete days, 99th percentile ranks and rounding |
| [40 CFR 50, Appendix U](https://www.law.cornell.edu/cfr/text/40/appendix-U_to_part_50), sections 3(b) to 3(e) | Ozone 8-hour means, valid days and truncation |
| [40 CFR 50.8](https://www.law.cornell.edu/cfr/text/40/50.8)(d) | CO rounding |
| [40 CFR 58, Appendix D](https://www.law.cornell.edu/cfr/text/40/appendix-D_to_part_58), Table D-3 | Ozone monitoring seasons by state |
| [U.S. Census Bureau regions and divisions](https://www2.census.gov/geo/pdfs/maps-data/maps/reference/us_regdiv.pdf) | The 13 states of the West region |
| [USACE National Channel Framework](https://services7.arcgis.com/n1YM8pTrFmm7L4hs/ArcGIS/rest/services/National_Channel_Framework/FeatureServer), ChannelArea layer, downloaded 2026-10-22 | The 12 land-cut sections of the Houston Ship Channel that set the site groups |
| [TCEQ Region 12 2024 monitoring memo](https://www.tceq.texas.gov/downloads/toxicology/monitoring/air-evaluations/2024/reg12.pdf) | The memo-list grouping kept as a sensitivity check |
| [TCEQ 2024 state-initiative network changes](https://www.tceq.texas.gov/downloads/air-quality/air-monitoring/network/historical/2024-si-monitoring-network-changes.pdf) | The Park Place SO₂ deactivation recommendation |
| [Texas 2017 Annual Monitoring Network Plan (EPA archive)](https://19january2021snapshot.epa.gov/sites/static/files/2017-09/documents/txplan2017.pdf) | The four near-road NO₂ sites |
| [TCEQ DFW monitoring site list](https://www.tceq.texas.gov/airquality/airmod/data/dfw8h2/dfw8h2_site.html) | The Dallas–Fort Worth sites |
| [TCEQ biennial report on ozone nonattainment areas](https://www.tceq.texas.gov/publications/sfr/tceq-biennial-report/biennial-report-to-the-86th-legislature-fy2017-fy2018/agency-activities-air-quality-fy2017-2018) | The Dallas–Fort Worth nonattainment area |
| [Bayport Industrial District (Wikipedia)](https://en.wikipedia.org/wiki/Bayport_Industrial_District) | The industrial complex near Seabrook (a general reference) |

Event sources and their links are in the `source` column of `data/reference/events.csv`.
