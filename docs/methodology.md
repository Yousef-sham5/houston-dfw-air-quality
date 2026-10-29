# Methodology

October 28, 2026 · Yousef Shamsaldeen

**Phase 1** builds three cleaned datasets:
- national daily data (`1a`, `1b`)
- hourly pollutants for 16 case-study monitors (`1c`, `1d`)
- hourly weather for their 9 sites (`1e`)

**Phase 2** explores them in `2a` (national), `2b` (daily case study) and `2c` (hourly case study).

Every column is read with an explicit type, and named assertions stop a script when an assumption fails.

## Daily data (1a, 1b)

The 25 daily files for 2021–2025 cover PM2.5 (88101, FRM/FEM only), ozone (44201), NO₂ (42602), SO₂ (42401) and CO (42101). Cleaning took them from 8,930,992 rows to **5,557,574**. Almost all of the 37.8% removed were repeat summaries of a monitor-day.

| Step | Rows removed |
|---|---|
| One averaging time per pollutant | 2,956,079 |
| Method codes (raw T640/T640X PM2.5 replaced by EPA's corrected codes, ozone method 901, blanks) | 315,860 |
| 75% completeness rule | 88,478 |
| Non-US sites, duplicate event rows, T640 firmware overlap, one out-of-range SO₂ value | 13,001 |

- **Kept as reported:** negative readings within method limits. Gaps are never imputed.
- **Daily metrics:** PM2.5 uses the 24-hour mean, ozone and CO the maximum 8-hour value, and NO₂ and SO₂ the maximum 1-hour value.
- **Events:** `events.csv` labels 22 events (Uri, Ida, Beryl, the 2025 Los Angeles fires, a 2025 dust storm and 17 smoke episodes) in 203 state or county rows. Smoke and dust rows must pass a data rule that `1b` rechecks, and fireworks windows are labelled for PM2.5. Labels mark rows and never remove them.

| Sites active in all five years | Ozone | PM2.5 | NO₂ | SO₂ | CO |
|---|---|---|---|---|---|
| National | 964 | 769 | 312 | 301 | 135 |
| Houston (Harris County) | 17 | 4 | 8 | 4 | 1 |
| Dallas–Fort Worth (Dallas and Tarrant) | 6 | 3 | 4 | 0 | 0 |

The Harris County counts include Seabrook (ozone and NO₂), which no case-study group uses, so the groups below hold 16 ozone and 7 NO₂ sites.

## Hourly pollutants and weather (1c, 1d, 1e)

**Site groups:**
- **Ship Channel:** Harris County sites within **7.5 km** of the 12 USACE land-cut channel sections. The cutoff falls between Deer Park #2 (6.94 km) and North Wayside (8.49 km).
- **Houston other:** the rest of Harris County, except Seabrook, next to the Bayport industrial district.
- **Transition band:** Houston other sites 7.5 to 15 km away, left out in one check.
- **Memo-list grouping:** an older grouping from TCEQ's 2024 air toxics memo, kept as a second check.

**Hourly picks:**

| Group | Ozone and NO₂ | SO₂ |
|---|---|---|
| Ship Channel | Deer Park #2, Houston East | Clinton, Deer Park #2, Park Place |
| Houston other | Harvard Street, Bayland Park | Croquet |
| Dallas–Fort Worth | Dallas Redbird, Grapevine Fairway | None |

**Import:** the hourly zips (79.4 million rows) are read in chunks that keep only these monitors, giving 661,545 rows (94.3% of possible hours).
- **Validation:** the hourly values rebuild all 27,747 daily maximums exactly.
- **Time:** local standard time, so a 7–9 am summer rush hour shows as hours 6–8.
- **Flags:** wildfire hours, event hours, values below the detection limit and incomplete days are flagged, never removed.

**Monitor changes:** each was checked against an unchanged neighbour and flagged, not adjusted.
- **Deer Park #2** moved on 2025-05-30, with no clear shift.
- **Harvard Street NO₂** changed method on 2024-04-22. Its May to December gap to Bayland Park dropped from 1.91–3.07 ppb to 0.72 in 2024 and returned to 2.24 in 2025, consistent with a low baseline that was later corrected.

**Weather:** wind and temperature for the 9 sites, one row per site and hour.
- **Harvard Street** has no wind sensor, so it borrows Croquet's wind and Bayland Park's temperature.
- **Calm and direction:** calm is wind below 0.5 m/s (EPA-454/R-99-005), and directions are where the wind blows from, in 12 sectors.
- **Sensor switches:** five sites switched to sonic sensors in 2022–2024, and these hours are flagged.
- **Coverage:** wind covers at least 98% of pollutant hours at most sites, but about 90% at Deer Park #2, 82% at Grapevine and 68–71% at Bayland Park.

## National daily analysis (2a)

Collocated instruments are averaged per site-day (5,198,843 site-days). Levels and profiles use five-year sites, and exceedance rates use all sites.
- **Network:** reporting SO₂ and CO sites fell 18% and 17%. The FEM share of PM2.5 rose from 79% to 85%, and FEM reads 0.3 to 0.5 µg/m³ above FRM on the same site-day.
- **NAAQS screening:** each site-year gets its standard's statistic, rounded as the standard specifies. In 2023, 42.7% of ozone sites and 39.0% of annual PM2.5 sites were above the level. The three-year screen gives 22.8% to 24.1% for ozone.
- **Exceedances:** labelled events hold 39.9% of PM2.5 exceedance days (68.2% in 2023), and EPA's own event flag marks 14.4% of those. Houston and Dallas–Fort Worth rank 6th and 8th of the 353 metros with an ozone exceedance, by exceedance site-days, which favour metros with many monitors.
- **Seasons:** NO₂ and CO peak in winter at 1.7 to 1.8 times their lows, ozone in June and PM2.5 in July. Events made June 2023 the top PM2.5 month.
- **Weekends:** from April to October, with three holidays left out, the median weekend-to-weekday ratio is 0.805 for NO₂ and 0.987 for ozone.
- **Records:** the tables behind figures 2A.1 to 2A.7 are saved as `national_*.csv`, and every national number quoted here is in `national_headlines.csv`.

## Daily case study (2b)

Five-year sites: Ship Channel, Houston other and Dallas–Fort Worth hold 3, 1 and 3 for PM2.5; 6, 10 and 6 for ozone; and 4, 3 and 4 for NO₂. SO₂ has 3 Ship Channel sites and 1 in Houston other. Results describe these sites.

**Checks:** every comparison is rerun under each check that changes it:
- without the transition band
- with the memo-list groups
- with four-year sites added
- without Deer Park #2 after its move
- without days after method changes
- without the near-road PM2.5 site
- without event days
- on days when at least half of each group's sites report

**What it finds:**
- **Ozone:** Dallas–Fort Worth has the most exceedance days per site in every year. The Ship Channel has the fewest in 3 of 5 years.
- **NO₂:** the Ship Channel is highest in every year under every check, and NO₂ falls with distance from the channel (Spearman −0.72, p = 0.02, with four-year sites). It stays negative whichever site is left out, but without Northwest Harris County, the farthest site, p rises to 0.08.
- **PM2.5:** every group sits near the 9.0 µg/m³ annual level, consistent with regional PM2.5.
- **SO₂:** read through spike days (5 ppb or more). Croquet spikes more often than the average Ship Channel site in every year.
- **Events:** during Beryl, about 20% of Ship Channel monitors reported, against 100% in Dallas–Fort Worth.

**Same-day differences:** each group's daily value is the mean of its reporting sites, and taking the difference on the same day cancels most shared weather. 95% ranges come from resampling whole 14-day blocks of days (1,000 times), because nearby days are linked.

| Same-day median (95% range) | Ship Channel minus Houston other | Houston minus Dallas–Fort Worth |
|---|---|---|
| NO₂ (ppb) | +1.15 (+0.81 to +1.41) | +1.77 (+1.26 to +2.26) |
| Ozone (ppb) | −0.97 (−1.11 to −0.77) | −4.00 (−4.87 to −3.27) |
| SO₂ (ppb) | +0.13 (+0.10 to +0.20) | None |
| PM2.5 (µg/m³) | −0.20 (−0.40 to −0.03) | +0.47 (+0.22 to +0.73) |

**Validation:** a check that leaves a comparison unchanged is dropped, since its range would differ only by chance. The Ship Channel result keeps its sign, with its range clear of zero, in:

| Gas | Runs holding |
|---|---|
| NO₂ | 7 of 7 |
| SO₂ | 4 of 4 |
| Ozone | 6 of 7 (all but the memo-list groups) |
| PM2.5 | 3 of 6 |

Houston minus Dallas–Fort Worth holds in all 19 runs.
- **PM2.5:** the gap does not hold up, and its main range reaches zero with a second seed.
- **SO₂:** the gap is far below the 2 ppb detection limit, so it is too small to read as a real difference.

**Records:** every 2b number quoted here is in `case_study_daily_headlines.csv`, and the distance tests, with each NO₂ site left out in turn, are in `case_study_distance_gradients.csv`.

## Hourly case study (2c)

**Hour rules (section 1, figure 2C.1):**
- **Ordinary hours:** hours on a valid day, outside Uri, Beryl and wildfire flags. 98.2% of hours qualify.
- **Direction hours:** ordinary hours that also have a usable wind direction, from 56% of all hours at Bayland Park to 90%.
- **Same-hour reporting:** every group reports in the same hour in at least 95% of hours.

**Checks:** results are rerun without Harvard Street (the one hourly site in the transition band), without its NO₂ hours after the method change, and without Deer Park #2 after its move. Wind results are also rerun without hours on the new sonic wind sensors.

**Daily cycles (section 2, figures 2C.2 and 2C.3):** each site counts equally in its group, and gaps are taken in the same hour.
- **Peaks:** NO₂ peaks at 06:00 to 07:00 and ozone at 14:00 to 15:00.
- **Gaps:** Ship Channel NO₂ is higher and its ozone lower at **all 24 hours**, under every check. Both gaps are widest late in the day: NO₂ +1.9 ppb at 17:00 and ozone −3.0 ppb at 16:00.
- **Weekend mornings:** from April to October, 6 to 8 am NO₂ on weekends is 36% below weekdays at the Ship Channel, against 42% in Houston other and 50% in Dallas–Fort Worth. That is consistent with more Ship Channel NO₂ from sources that run all week.

**Ozone and NO₂ together (section 3, figure 2C.4):** NO + O₃ → NO₂ + O₂ swaps ozone for NO₂ one for one, so it leaves Ox (ozone + NO₂) unchanged. If the Ship Channel's lower ozone came only from this reaction, its Ox would match Houston other's.

| Ship Channel minus Houston other (ppb) | Ozone gap | Ox gap | Share of the ozone gap Ox closes |
|---|---|---|---|
| Main, all year | −1.90 | −0.91 (−1.24 to −0.58) | 52% |
| Without Harvard Street | −2.22 | −0.03 | 99% |
| Main, winter | −0.54 | +0.05 (−0.46 to +0.56) | All |

Ox closes at least half the gap under every check, consistent with fresh NO using up ozone near the channel. In summer and autumn, the gap left over rests largely on Harvard Street. The data have no NO, so Ox cannot be regressed on NOx.

**SO₂ spike hours (section 4, figure 2C.5):** a spike is an hour at 5 ppb or more, 2.5 times the usual 2 ppb detection limit. Rates are per 1,000 hours, per site.
- **Rates:** Croquet 5.4, Park Place 4.4, Deer Park #2 2.0 and Clinton 1.1.
- **Croquet:** 96% of its spike hours fall between 9 am and 6 pm, and its summer rate is 4 times any other season's. That is consistent with a raised plume mixed down by daytime heating.
- **Short and local:** spikes last a median of one hour, and only 16 of 289 Ship Channel spike hours hit two sites at once. That is consistent with separate local plumes.
- **Deer Park #2 plume test:** on its spike hours, NO₂ is 7.5 ppb above normal (+5.1 to +10.0), so the plumes also carry nitrogen oxides. At night ozone dips 3.4 ppb, but that range just reaches zero.

**Wind and calm air (section 5, figures 2C.6 and 2C.7):** wind statistics use the 8 sites with their own sensor, outside Uri and Beryl. Each calm hour is compared with windy hours at the same site, hour of day and month, so time of day and season cancel out.
- **Wind:** south or south-southeast is the most common direction at every site. Houston's summer wind comes from the south in 54% of hours; its winter wind splits between north (32%) and south (30%).
- **Calm:** 6.0% of hours at the Ship Channel, 8.9% in Houston other and 1.6% in Dallas–Fort Worth. In both Houston groups over half of the calm hours fall from midnight to 6 am.
- **Calm against windy:** calm hours carry 3.0 to 6.8 ppb more NO₂ and 3.8 to 9.0 ppb less ozone at every site, each range clear of zero. In every group at least 70% of the lost ozone shows up as NO₂, consistent with NO using up ozone in still air.
- **SO₂:** by day, spikes come most in calm or light wind (under 1.5 m/s) and never above 5 m/s.
- **Sensor check:** the new sonic sensors read fewer calm hours at three sites (Bayland Park 8.9% to 5.9%, Houston East 10.2% to 6.9%, Deer Park #2 6.8% to 5.6%). Every result holds without them. Bayland Park sits out this check, since its old sensor covers only about a year.

**Source directions (section 6, figures 2C.8 to 2C.10):** the directions in which the land-cut channel lies from each site come from the same USACE sections as the site groups.
- **NO₂:** at all four Houston NO₂ sites, NO₂ runs 1.4 to 1.6 times its usual level in wind from 60° to 90°.
- **SO₂:** 75% of Croquet's spike hours (68% to 82%) come from 195° to 255°, a direction that brings 11% of its hours and points away from the channel. 77% of Park Place's (68% to 86%) come from the channel side, which brings 30% of its hours.
- **Ox gap by wind:** one Houston wind per hour, the vector mean of the 6 Houston sensors. Wind from the channel covers 45° to 135°, where the channel lies from Bayland Park and Harvard Street.

| Ox gap, Ship Channel minus Houston other (ppb) | Wind from the channel | Other wind |
|---|---|---|
| Main | −1.47 (−2.07 to −0.94) | −0.59 (−0.93 to −0.28) |
| Without Harvard Street | −2.16 (−2.73 to −1.66) | +0.03 (−0.30 to +0.35) |

The gap left after section 3 appears in wind from the channel, consistent with ozone forming in channel air as it crosses Houston. A first split by compass quarter put north, not east, widest without Harvard Street, so the test uses the channel's own directions. Harvard Street has 2 to 3 ppb more Ox than Bayland Park in most south and west winds, so its extra Ox is not tied to the channel.

**Validation (section 7, figure 2C.11):** the 67 headline 95% ranges were redrawn with a second seed; none changed its verdict, and no end moved more than 9.1% of its range. All ten headline findings hold under every check that applies. The numbers the report quotes are saved in `case_study_hourly_headlines.csv`, and all 19 checks in `case_study_hourly_validation.csv` pass.

## Saved files

- **`data/processed/`:** the `.rds` checkpoints that later scripts read, `data_dictionary.csv` (every saved column) and `checkpoint_manifest.csv` (the size and MD5 of each checkpoint).
- **`data/processed/phase1/` and `phase2/`:** the CSV records from each script, readable on GitHub.
- **`figures/`:** every figure, numbered in order (`2a.01` to `2c.11`) and sized for a 6.5-inch report page.

## Known limits

- **SO₂ sits near zero:** 97% to 99% of hours at three of the four sites are below the detection limit, and Clinton's baseline drifts.
- **Small groups:** hourly ozone and NO₂ have two sites per group, and Houston other has one five-year PM2.5 site.
- **Distance as a proxy:** distance to the channel water stands in for distance to the plants along it.
- **Weather gaps:** wind is missing for 474 days at Bayland Park, 314 at Grapevine and 161 at Deer Park #2, and Harvard Street's weather is borrowed from neighbours.
- **Direction is a pointer:** each wind direction also brings its own kind of air (north wind often follows a cold front), so a direction points toward a source without proving it.
- **Two monitor changes:** Deer Park #2 moved in 2025, and Harvard Street NO₂ changed method. Both are flagged and checked, not adjusted.
- **No ozone on December 31** in the daily table, an EPA file artifact. The hourly table has these days.

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
