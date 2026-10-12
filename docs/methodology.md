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

## Hourly data for the case study (1c and 1d)

Hourly data are added for the case-study sites in two scripts of their own, so the daily pipeline stays as it is. `R/1c_site_selection.R` picks the sites, and `R/1d_hourly_import_clean.R` (in progress) reads the hourly files for those sites only.

### Scope

- **Pollutants:** ozone (44201), NO₂ (42602) and SO₂ (42401) for 2021–2025, which is 15 files.
- **Sites:** the Houston and Dallas–Fort Worth case-study sites, picked from the full-coverage list above by `R/1c_site_selection.R`.
- **CO is left out.** Texas has few CO monitors, its levels sit far below the NAAQS, NO₂ already captures the traffic signal, and NO₂ takes part directly in the ozone chemistry being tested.
- **PM2.5 is left out.** FRM monitors take 24-hour filter samples, so hourly PM2.5 would come only from FEM monitors (with the T640 corrections) and wouldn't match the daily method mix. The PM2.5 standards are 24-hour and annual, and hourly PM2.5 mostly reflects boundary-layer mixing, which makes it a weak source indicator.
- **No wind data** is used, so statements about sources are worded as "consistent with". A pollution rose is listed as future work.

### Uses

- **Diurnal profiles (Phase 2):** traffic and industrial signatures, Houston against Dallas–Fort Worth, and weekdays against weekends.
- **Ozone photochemistry (Phase 4):** the lag between NO₂ and ozone.
- **Comparisons:** the Ship Channel against the rest of Harris County, which shares the same weather on any given day, and both Houston groups against Dallas–Fort Worth. The within-Houston comparison can also be run as paired daily differences (Ship Channel minus other Houston on the same date), which cancels out day-to-day weather.

### Site selection (1c)

Candidates are monitors in Harris, Dallas and Tarrant counties with ozone, NO₂ or SO₂ data in all five years (`n_years_active` = 5). Each candidate site goes into one of three groups.

| Group | Sites | Role |
|---|---|---|
| Houston Ship Channel | 17 Harris County sites on the industrial east side: 15 from TCEQ's 2024 Region 12 monitoring memo (Clinton, Galena Park, Channelview, Deer Park #2, Lynchburg Ferry, Milby Park and others), plus Park Place and Baytown Garth | Industrial |
| Other Houston | Every other Harris County site, except Seabrook Friendship Park (excluded, see below) | Urban, same weather as the Ship Channel |
| Dallas–Fort Worth | Dallas and Tarrant county sites | Comparison metro |

- **Selection rules:** every full-coverage SO₂ monitor is kept, since there are only four and all are in Harris County. For ozone and NO₂, only sites that measure both are considered, because the NO₂–ozone lag needs both series from one place. Each site is scored by its less complete pollutant. The top two are kept in each Houston group, and the top one in each Dallas–Fort Worth county, so both Dallas and Tarrant counties are represented. Completeness only breaks ties between sites that all passed the five-year rule.
- **Park Place (48-201-0416)** was moved into the Ship Channel group. It is the closest other-Houston candidate to the Ship Channel monitors (6.4 km to the nearest one, by great-circle distance from `sites.rds` coordinates), against 9–53 km for the rest. TCEQ recommended deactivating its SO₂ monitor by December 31, 2025, so its SO₂ record ends with the study window.
- **Baytown Garth (48-201-1017)** was also moved into the Ship Channel group, since Baytown sits on the channel. It is ozone-only, so it isn't picked.
- **Seabrook Friendship Park (48-201-1050)** is excluded from both Houston groups. It is about 15 km from the nearest Ship Channel monitor, but roughly 5 km from the Bayport Industrial District, a complex of more than 60 chemical plants next to Seabrook and La Porte. Keeping it out leaves the other-Houston group free of nearby heavy industry. Its place goes to Houston Bayland Park in southwest Houston.
- **Houston North Loop (48-201-1052)**, the near-road site, was considered as a traffic reference but dropped: its NO₂ covers 4 of 5 years and it doesn't measure ozone or SO₂.
- **Outputs:** `data/reference/case_study_candidates.csv` (every eligible monitor), `data/reference/case_study_sites.csv` (the picks, each with a `selection_reason`) and `figures/case_study_sites.png` (a map of the picks).

**Final picks:** 16 monitors at 9 sites. Percentages are the share of the 1,826 study days with data.

| Group | Ozone and NO₂ | SO₂ |
|---|---|---|
| Houston Ship Channel | Houston Deer Park #2 (48-201-1039; 97.3% / 97.6%), Houston East (48-201-1034; 95.8% / 97.8%) | Clinton (48-201-1035; 95.1%), Houston Deer Park #2 (95.1%), Park Place (48-201-0416; 95.6%) |
| Other Houston | Houston Harvard Street (48-201-0417; 95.5% / 94.7%), Houston Bayland Park (48-201-0055; 89.8% / 91.6%) | Houston Croquet (48-201-0051; 97.9%) |
| Dallas–Fort Worth | Dallas Redbird Airport Executive (48-113-0087, Dallas County; 93.9% / 86.5%), Grapevine Fairway (48-439-3009, Tarrant County; 97.2% / 98.1%) | None |

- **Site types:** Houston Deer Park #2 is an NCore site, part of EPA's national multipollutant network. TCEQ set up Houston East downwind of the Ship Channel. Dallas Redbird sits at Dallas Executive Airport, and Grapevine Fairway is in Grapevine; both are regulatory sites running since 1999 and 2000.
- **No near-road sites:** Texas's 2017 network plan names four near-road NO₂ sites in these counties (Houston Southwest Freeway 48-201-1066, Houston North Loop 48-201-1052, Dallas LBJ Freeway 48-113-1067 and Fort Worth California Parkway North 48-439-1053). None of them is a pick, so every picked site measures area-wide air, which keeps the groups comparable.

Sources: [Bayport Industrial District (Wikipedia)](https://en.wikipedia.org/wiki/Bayport_Industrial_District), [Texas 2017 Annual Monitoring Network Plan (EPA archive)](https://19january2021snapshot.epa.gov/sites/static/files/2017-09/documents/txplan2017.pdf), [TCEQ DFW monitoring site list](https://www.tceq.texas.gov/airquality/airmod/data/dfw8h2/dfw8h2_site.html), [TCEQ 2024 state-initiative network changes](https://www.tceq.texas.gov/downloads/air-quality/air-monitoring/network/historical/2024-si-monitoring-network-changes.pdf).

- **Why Dallas–Fort Worth as a whole:** Dallas and Tarrant counties share one air basin and sit in the same nine-county ozone nonattainment area, and pooling them gives enough full-coverage monitors. The region is also an ozone nonattainment area, so it serves as a comparison metro and is not a pollution-free baseline.
- **Houston means Harris County.** Several Ship Channel monitors sit in other Harris County cities, such as Deer Park and Pasadena.
- **Deer Park #2 (48-201-1039)** moved from 4514 ½ Durant St to 4413 Glenwood Ave on May 30, 2025. It kept its AQS ID, so `sites.rds` holds the new coordinates, and the hourly data will be checked for a level shift at the move.

Sources: [TCEQ Region 12 2024 monitoring memo](https://www.tceq.texas.gov/downloads/toxicology/monitoring/air-evaluations/2024/reg12.pdf), [TCEQ biennial report on ozone nonattainment areas](https://www.tceq.texas.gov/publications/sfr/tceq-biennial-report/biennial-report-to-the-86th-legislature-fy2017-fy2018/agency-activities-air-quality-fy2017-2018).

### Files

The 15 zips (ozone, NO₂ and SO₂, 2021–2025) were downloaded from **Hourly Data → Criteria Gases** on 2026-10-12 and stay zipped in `data/raw/hourly/`. EPA's AirData file list (`file_list.csv`) dates them 2026-06-25 and gives each file's row count, which the import checks against; the CSVs inside the zips carry 2026-06-26 timestamps. The file list's sizes match the downloaded zips to within 1 KiB, and an earlier hand-recorded 2022 total (118,280 KiB) was a transcription error.

| Year | SO₂ (KiB) | NO₂ (KiB) | Ozone (KiB) | Total (KiB) |
|---|---|---|---|---|
| 2021 | 23,461 | 28,806 | 68,250 | 120,517 |
| 2022 | 22,648 | 28,961 | 66,938 | 118,547 |
| 2023 | 21,772 | 28,672 | 67,207 | 117,651 |
| 2024 | 20,341 | 28,375 | 66,905 | 115,621 |
| 2025 | 19,296 | 28,007 | 65,874 | 113,177 |

The zips total 585,513 KiB (572 MiB). Unzipped, the 15 CSVs total 18,781,706,906 bytes (17.5 GiB), and the largest, ozone 2021, is 1.95 GiB. EPA lists 16,427,897 rows for 2021 and 62,974,304 for 2022–2025, so the 15 files hold 79,402,201 rows in total. `R/1d_hourly_import_clean.R` counts the rows in every zip and stops if any count differs from the file list. All 15 counts match, and they are saved in `data/processed/hourly_raw_row_counts.csv`.

### Import approach (1d)

Reading everything at once would not fit on a 16 GB laptop, given that the 8.9 million daily rows already peaked at 1.42 GB. Each file is handled on its own, and the zips stay zipped:

1. Count the rows in each zip, 1 million lines at a time, and compare the counts with EPA's file list.
2. Read the header of each zip and confirm that all 15 files share EPA's 24 documented columns, in order.
3. Pass each zip to `readr::read_csv_chunked()` with explicit column types, parsing 16 of the 24 columns. Each 1-million-row chunk is cut to Texas rows first and then to the 16 case-study monitors, matched on site ID and parameter code.
4. Save the filtered rows, together with the number of rows read, to `data/hourly_filtered/` (not tracked) and free memory. A file that is already saved is skipped on the next run, so a crash part-way through loses at most one file.
5. Combine the 15 filtered files, confirm that the rows read equal the raw row counts, and inspect the values before any cleaning rule is set. Method codes are checked against EPA's methods table, as in `1a_import_clean.R`, and named assertions guard each step.
6. Still to come: cleaning, validation against the daily data, and saving `data/processed/hourly_case_study.rds` with gzip compression, with new rows in the data dictionary and manifest.

readr decompresses each zip to a temporary file while it reads and removes that copy afterwards, so the extra disk in use stays close to the size of one CSV (the largest is 1.95 GiB). One monitor's full record is 1,826 days × 24 hours = 43,824 rows, so the 16 picked monitors come to at most 701,184 rows.

### Results so far (sections 1–4)

Nothing has been removed from the hourly data yet. These counts come from the 15 filtered files.

- **Rows:** all 79,402,201 rows were read and 661,545 were kept (0.83%), which is 94.3% of the 701,184 possible monitor-hours: ozone 250,556, NO₂ 244,766 and SO₂ 166,223. The table takes about 85 MB in memory.
- **Monitors:** all 16 are present, each under one POC, with no duplicate hours. Houston Harvard Street starts on 2021-01-25 and Houston Bayland Park ozone on 2021-03-12. The other 13 monitors start on 2021-01-01, and all 16 run to 2025-12-31.
- **Missing values:** no kept row is missing a measurement or a detection limit. Hours without data are absent from EPA's files, which accounts for the 5.7% of monitor-hours not present.
- **Methods:** all seven method codes are FRM or FEM in EPA's methods table.
- **Detection limits:** readings below the method detection limit (MDL) are reported as measured, with zeros and negatives present and no pile-up at half the MDL, and no reading falls below the negative of its MDL. SO₂ is below its 2 ppb MDL in 97.2–99.4% of hours at Houston Croquet, Park Place and Clinton, and below a 0.2 ppb MDL in 64.9% of hours at Deer Park #2, so SO₂ diurnal profiles need to be read with the detection limit in mind.
- **Qualifiers:** the only qualifier is `RT`, EPA's request-exclusion code for U.S. wildfire smoke, on 142 ozone hours: 94 at Houston Bayland Park and 48 at Houston Harvard Street, on four dates in 2022 (June 20, September 13, September 21 and October 8).
- **High values:** one SO₂ hour is above the 75 ppb level of the 1-hour standard, 94 ppb at Clinton at 02:00 on 2024-01-13, and no NO₂ hour is above 100 ppb. This is a screening observation, since the standards are judged on three-year design values.
- **Deer Park #2:** the hourly files give the site one coordinate pair for all five years, so its May 30, 2025 move has to be checked in the measurements themselves.

### Settled

- **Time stamps:** EPA's file documentation states that `Date Local` and `Time Local` are in local standard time, so there is no daylight-saving shift. In summer, a 7–9 a.m. CDT rush hour appears as hours 6–8, and every diurnal plot will say so. An assertion that `Time GMT` minus `Time Local` is 6 hours passes on all 661,545 case-study rows, which confirms it.
- **Columns:** EPA documents 24 columns for the hourly files. That documentation dates from 2015, so the script checks the real header before setting column types. All 15 headers match the documented list.
- **Instruments:** each of the 16 monitors reports under a single POC, so there is no instrument to choose between.

### Still to decide

- How to treat the `RT` qualifier on 142 ozone hours: keep and label them, which would match the "Included" choice in the daily data, or drop them.
- How to handle readings below the detection limit and negative readings, which EPA's AirNow documentation attributes to instrument drift. Keeping them as reported would match the daily rule, with a note on the SO₂ detection limit wherever SO₂ profiles are shown.
- How to test for a level shift at Deer Park #2 around its May 30, 2025 move.
- An hour-level completeness rule: 75% of hours (18 of 24) for a valid day, as in 40 CFR 50.
- Cross-checks against the daily data: daily 1-hour maximums for NO₂ and SO₂, and daily maximum 8-hour ozone built from rolling 8-hour means with at least 6 valid hours, should match `first_max_value`.

Sources: [EPA AirData file formats](https://aqs.epa.gov/aqsweb/airdata/FileFormats.html), [40 CFR 50 Appendix S](https://www.law.cornell.edu/cfr/text/40/appendix-S_to_part_50), [AirNow hourly data fact sheet](https://docs.airnowapi.org/docs/HourlyDataFactSheet.pdf).
