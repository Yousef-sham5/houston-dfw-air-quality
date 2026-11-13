# Methodology

November 13, 2026 · Yousef Shamsaldeen

- **Phase 1** builds three cleaned datasets: national daily data (`1a`, `1b`), hourly pollutants for 16 case-study monitors (`1c`, `1d`) and hourly weather for their 9 sites (`1e`).
- **Phase 2** explores them in `2a` (national), `2b` (daily case study) and `2c` (hourly case study).
- **Phase 3** describes their distributions in `3_distributions`, works an ozone design value through EPA's rules and checks every result.
- **Phase 4** is the report, `R/5_report.Rmd`, knit to `5_report.pdf`.

Trends are not tested: five years is too short to separate a trend from year-to-year weather. Every column is read with an explicit type, and named assertions stop a script when an assumption fails.

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

| Hourly picks | Ozone and NO₂ | SO₂ |
|---|---|---|
| Ship Channel | Deer Park #2, Houston East | Clinton, Deer Park #2, Park Place |
| Houston other | Harvard Street, Bayland Park | Croquet |
| Dallas–Fort Worth | Dallas Redbird, Grapevine Fairway | None |

**Import:** chunked reads of the hourly zips (79.4 million rows) keep these monitors, giving 661,545 rows (94.3% of possible hours). The hourly values rebuild all 27,747 daily maximums exactly. Times stay in local standard time, so a 7–9 am summer rush hour shows as hours 6–8. Wildfire hours, event hours, values below the detection limit and incomplete days are flagged, never removed.

**Monitor changes** were checked against an unchanged neighbour and flagged, not adjusted. Deer Park #2 moved on 2025-05-30 with no clear shift. Harvard Street NO₂ changed method on 2024-04-22; its May to December gap to Bayland Park dropped from 1.91–3.07 ppb to 0.72 in 2024 and returned to 2.24 in 2025, consistent with a low baseline that was later corrected.

**Weather:** wind and temperature for the 9 sites, one row per site and hour.
- **Harvard Street** has no wind sensor, so it borrows Croquet's wind and Bayland Park's temperature.
- **Calm and direction:** calm is wind below 0.5 m/s (EPA-454/R-99-005), and directions are where the wind blows from, in 12 sectors.
- **Sensor switches:** five sites switched to sonic sensors in 2022–2024, and these hours are flagged.
- **Coverage:** wind covers at least 98% of pollutant hours at most sites, but about 90% at Deer Park #2, 82% at Grapevine and 68–71% at Bayland Park.

## National daily analysis (2a)

Collocated instruments are averaged per site-day (5,198,843 site-days). Levels use five-year sites, and exceedance rates all sites.
- **Network:** reporting SO₂ and CO sites fell 18% and 17%. The FEM share of PM2.5 rose from 79% to 85%, and FEM reads 0.3 to 0.5 µg/m³ above FRM on the same site-day.
- **NAAQS screening:** each site-year gets its standard's statistic, rounded as the standard specifies. In 2023, 42.7% of ozone sites and 39.0% of annual PM2.5 sites were above the level; the three-year screen gives 22.8% to 24.1% for ozone.
- **Exceedances:** labelled events hold 39.9% of PM2.5 exceedance days (68.2% in 2023), and EPA's own event flag marks 14.4% of those. Houston and Dallas–Fort Worth rank 6th and 8th of 353 metros with an ozone exceedance, by exceedance site-days, which favour large networks.
- **Seasons and weekends:** NO₂ and CO peak in winter at 1.7 to 1.8 times their lows, ozone in June and PM2.5 in July. From April to October, with three holidays left out, the median weekend-to-weekday ratio is 0.805 for NO₂ and 0.987 for ozone.
- **Records:** tables are saved as `national_*.csv`, and quoted numbers are in `national_headlines.csv`.

## Daily case study (2b)

Five-year sites: Ship Channel, Houston other and Dallas–Fort Worth hold 3, 1 and 3 for PM2.5; 6, 10 and 6 for ozone; and 4, 3 and 4 for NO₂. SO₂ has 3 Ship Channel sites and 1 in Houston other.

**Checks:** each comparison is rerun without the transition band, with the memo-list groups, with four-year sites added, without Deer Park #2 after its move, without days after method changes (Park Place and Harvard Street NO₂, Westhollow ozone), without the near-road PM2.5 site, without event days, and on days when at least half of each group's sites report. A check that leaves a comparison unchanged is dropped.

**What it finds:**
- **Ozone:** Dallas–Fort Worth has the most exceedance days per site in every year; the Ship Channel has the fewest in 3 of 5.
- **NO₂:** the Ship Channel is highest in every year under every check, and NO₂ falls with distance from the channel (Spearman −0.72, p = 0.02, with four-year sites). It stays negative whichever site is left out; without Northwest Harris County, the farthest, p is 0.08.
- **SO₂:** read through spike days (5 ppb or more). Croquet spikes more often than the average Ship Channel site in every year.
- **Events:** during Beryl, about 20% of Ship Channel monitors reported, against 100% in Dallas–Fort Worth.

**Same-day differences:** each group's daily value is the mean of its reporting sites, and same-day differences cancel most shared weather. 95% ranges come from 1,000 resamples of 14-day blocks, because nearby days are linked.

| Same-day median (95% range) | Ship Channel minus Houston other | Runs holding | Houston minus Dallas–Fort Worth |
|---|---|---|---|
| NO₂ (ppb) | +1.15 (+0.81 to +1.41) | 7 of 7 | +1.77 (+1.26 to +2.26) |
| Ozone (ppb) | −0.97 (−1.11 to −0.77) | 6 of 7 (all but memo-list) | −4.00 (−4.87 to −3.27) |
| SO₂ (ppb) | +0.13 (+0.10 to +0.20) | 4 of 4 | None |
| PM2.5 (µg/m³) | −0.20 (−0.40 to −0.03) | 3 of 6 | +0.47 (+0.22 to +0.73) |

Houston minus Dallas–Fort Worth holds in all 19 runs. The PM2.5 gap does not hold up, and the SO₂ gap is far below the 2 ppb detection limit. Quoted numbers are in `case_study_daily_headlines.csv`.

## Hourly case study (2c)

**Hours:** ordinary hours are on a valid day, outside Uri, Beryl and wildfire flags (98.2% of hours). Every group reports in the same hour in at least 95% of hours. Results are rerun without Harvard Street (the one hourly site in the transition band), without its NO₂ hours after the method change and without Deer Park #2 after its move; wind results also without hours on the new sonic sensors.

**Daily cycles (figures 2C.2 and 2C.3):** gaps are taken in the same hour, with each site counting equally in its group. NO₂ peaks at 06:00 to 07:00 and ozone at 14:00 to 15:00. Ship Channel NO₂ is higher and its ozone lower at **all 24 hours**, under every check, with both gaps widest late in the day (NO₂ +1.9 ppb at 17:00, ozone −3.0 ppb at 16:00). From April to October, 6 to 8 am weekend NO₂ is 36% below weekdays at the Ship Channel, against 42% in Houston other and 50% in Dallas–Fort Worth, consistent with more Ship Channel NO₂ from sources running all week.

**Ozone and NO₂ together (figure 2C.4):** NO + O₃ → NO₂ + O₂ swaps ozone for NO₂ one for one, so it leaves Ox (ozone + NO₂) unchanged. If the Ship Channel's lower ozone came only from this reaction, its Ox would match Houston other's.

| Ship Channel minus Houston other (ppb) | Ozone gap | Ox gap | Share of the ozone gap Ox closes |
|---|---|---|---|
| Main, all year | −1.90 | −0.91 (−1.24 to −0.58) | 52% |
| Without Harvard Street | −2.22 | −0.03 | 99% |
| Main, winter | −0.54 | +0.05 (−0.46 to +0.56) | All |

Ox closes at least half the gap under every check, consistent with fresh NO using up ozone near the channel. The data have no NO, so Ox cannot be regressed on NOx.

**SO₂ spike hours (figure 2C.5):** a spike is an hour at 5 ppb or more, 2.5 times the usual 2 ppb detection limit. Rates per 1,000 hours are 5.4 at Croquet, 4.4 at Park Place, 2.0 at Deer Park #2 and 1.1 at Clinton. 96% of Croquet's spike hours fall between 9 am and 6 pm, and its summer rate is 4 times any other season's, consistent with a raised plume mixed down by daytime heating. Spikes last a median of one hour, and 16 of 289 Ship Channel spike hours hit two sites at once, consistent with separate local plumes. On Deer Park #2 spike hours, NO₂ is 7.5 ppb above normal (+5.1 to +10.0).

**Wind and calm air (figures 2C.6 to 2C.8):** each calm hour is compared with windy hours at the same site, hour of day and month. Calm makes up 6.0% of hours at the Ship Channel, 8.9% in Houston other and 1.6% in Dallas–Fort Worth. Calm hours carry 3.0 to 6.8 ppb more NO₂ and 3.8 to 9.0 ppb less ozone at every site, each range clear of zero, and in every group at least 70% of the lost ozone shows up as NO₂. New sonic sensors read fewer calm hours at three sites, and every result holds without them.

**Source directions (figures 2C.9 to 2C.11):** channel directions come from the same USACE sections as the site groups. At all four Houston NO₂ sites, NO₂ runs 1.4 to 1.6 times its usual level in wind from 60° to 90°. 75% of Croquet's SO₂ spike hours (68% to 82%) come from 195° to 255°, a direction that brings 11% of its hours and points away from the channel; 77% of Park Place's (68% to 86%) come from the channel side, which brings 30% of its hours. For the Ox gap, each hour takes the vector mean of the 6 Houston sensors, and wind from the channel covers 45° to 135°.

| Ox gap, Ship Channel minus Houston other (ppb) | Wind from the channel | Other wind |
|---|---|---|
| Main | −1.47 (−2.07 to −0.94) | −0.59 (−0.93 to −0.28) |
| Without Harvard Street | −2.16 (−2.73 to −1.66) | +0.03 (−0.30 to +0.35) |

The gap left over appears in wind from the channel, consistent with ozone forming in channel air as it crosses Houston.

**Validation (figure 2C.12):** a second seed changed none of the 67 headline ranges' verdicts. All ten headline findings hold under every check that applies, and all 19 checks in `case_study_hourly_validation.csv` pass. Quoted numbers are in `case_study_hourly_headlines.csv`.

## Distributions (3_distributions)

**Fit table:** five-year sites give 4,016,891 site-days after collocated instruments are averaged. Values at or below zero take half the method's federal detection limit in a fitting copy. Sites with at least 25% of days at or below zero (52 SO₂, 3 CO, 1 NO₂) stay out, leaving 2,425. Fits use ordinary days.

**Shape (figures 3.1 to 3.4):** pooling mixes sites (SO₂'s pooled skew is 20.2 against 3.89 at the typical site), so each site's percentiles are compared with its own normal and lognormal curves. A lognormal is closer at 97% of PM2.5, 96% of SO₂ and 81% of CO sites, and a normal curve at 82% of ozone sites. NO₂ splits, at 61% lognormal.

**Fits (figures 3.5 and 3.6):** lognormal, gamma and Weibull curves are fitted per site on value / site mean and ranked by AIC (2k − 2 ln L). Every curve has k = 2, so the ranking rests on the likelihood alone. A normal curve is fitted beside them as a reference. `fitdistrplus` fits the main run, and a faster fit for checks and resamples must match it within 0.001 AIC.

| Ordinary days | Sites | Lognormal | Gamma | Weibull | Normal wins if allowed | AIC gap 10+ | Scaled gap 10+ | Winner holds |
|---|---|---|---|---|---|---|---|---|
| PM2.5 | 769 | 522 | 232 | 15 | 0 | 91.8% | 72.8% | 71.0% |
| Ozone | 964 | 22 | 421 | 521 | 525 | 87.7% | 36.1% | 52.0% |
| NO₂ | 311 | 66 | 125 | 120 | 13 | 87.8% | 63.3% | 61.0% |
| SO₂ | 249 | 188 | 53 | 8 | 0 | 96.4% | 79.5% | 78.0% |
| CO | 132 | 82 | 41 | 9 | 4 | 89.4% | 65.2% | 77.0% |

- **Certainty:** nearby days are linked. Effective days are n(1 − r) / (1 + r), where r is the correlation of logs on consecutive days, and the scaled gap is the AIC gap × effective days / n. A winner holds when it is kept in at least 90% of 100 two-week block resamples (100 random sites per pollutant, and every case-study site).
- **Censored checks:** a day below a limit counts only as somewhere below it. Censoring days at or below zero keeps the winner at 95.2% of SO₂ and 96.2% of CO sites; censoring every reading below the limit keeps it at 72.3% and 75.8%.
- **Deer Park #2 SO₂:** the main fit picks a lognormal whose P99 runs 49% high. With the 22.9% of days below the limit censored, a Weibull curve wins by an AIC gap of 24.2, consistent with the main win resting on the low readings.
- **PM2.5 monitors:** at 67 sites with at least 365 ordinary days each side, a lognormal wins 95.5% of fits on a T640 alone and 46.3% on other monitors. At 228 sites with no T640, split at the typical switch date (2023-02-18), it falls from 51.3% to 36.0%. That is consistent with an instrument effect whose cause is not confirmed.
- **Group spread:** the spread factor is exp(SD of logs), compared per site since winner labels are unstable. 95% ranges come from 1,000 resamples of the same 14-day date blocks at every site.

| Ozone spread factor (median) | Ship Channel | Houston other | Dallas–Fort Worth | Gaps to Dallas–Fort Worth (95% range) |
|---|---|---|---|---|
| Warm months | 1.47 | 1.46 | 1.34 | +0.134 (0.092 to 0.168), +0.125 (0.081 to 0.159) |
| Cool months | 1.46 | 1.46 | 1.46 | −0.003 (−0.115 to 0.103), 0.000 (−0.122 to 0.106) |

The warm-month gap is consistent with Houston swinging between cleaner Gulf air and stagnant days, which is not tested here.

**Tails (figures 3.7 to 3.9):** expected days = days measured × the curve's share above a level, compared with actual days on the days the curve was fitted to. A ratio above 1 is an overcount. This tests fit and forecasts nothing. Levels are the short-term limit under 2a's rounding and each site's own P98 and P99. Readings sit on a measurement grid, so a smooth curve is read half a step below the first counted value. Misses cancel in totals, so the typical site and the share within 25% (ratio 0.8 to 1.25) sit beside them, using sites with at least 10 actual days and 200 days.

| Top 1% of days | Actual days | Winner total | Lognormal total | Judged sites | Typical site (middle half) | Within 25% |
|---|---|---|---|---|---|---|
| PM2.5 | 12,121 | 0.80 | 1.29 | 678 | 0.76 (0.51 to 1.07) | 32.4% |
| Ozone | 13,793 | 1.10 | 3.38 | 906 | 0.97 (0.63 to 1.46) | 28.0% |
| NO₂ | 5,434 | 1.54 | 3.89 | 311 | 1.46 (0.93 to 2.05) | 22.8% |
| SO₂ | 4,346 | 1.24 | 1.82 | 248 | 1.02 (0.58 to 1.70) | 23.4% |
| CO | 1,657 | 1.07 | 1.90 | 104 | 0.90 (0.44 to 1.32) | 25.0% |

- **At the limit:** ozone has 20,252 ordinary days above it, and the winner's total is 1.00 against the lognormal's 2.17. PM2.5 has 3,798 ordinary days (winner 0.73) and 6,887 on all days (0.55). NO₂, SO₂ and CO rows are too thin to read.
- **Deer Park #2 SO₂:** expected / actual at P99 is 2.18 for the main lognormal and 1.06 for the censored Weibull (17 actual days).

| Warm-month ozone at the limit | Sites | Days above (95% range) | Gamma | Lognormal | Normal | Gamma at the top 1% |
|---|---|---|---|---|---|---|
| Ship Channel | 6 | 4.36% (3.11 to 5.86) | 1.06 (0.90 to 1.26) | 1.33 (1.11 to 1.59) | 0.70 (0.56 to 0.83) | 1.51 |
| Houston other | 10 | 4.38% (3.28 to 5.61) | 1.09 (0.95 to 1.21) | 1.34 (1.18 to 1.51) | 0.74 (0.62 to 0.85) | 1.69 |
| Dallas–Fort Worth | 6 | 5.55% (3.98 to 7.43) | 1.12 (0.97 to 1.32) | 1.33 (1.11 to 1.66) | 0.85 (0.74 to 0.97) | 1.66 |

Ranges use 2,000 resamples of the same 14-day date blocks, with every curve refitted. Gamma's warm ratio stays 1.06 to 1.14 under every check, and year-round it overcounts only in Dallas–Fort Worth (1.32).

**Design value:** Appendix U takes each year's 4th-highest daily maximum 8-hour ozone, averages three years and truncates to three decimals. The value is valid with valid days on 90% of the ozone season on average and 75% in each year, and always valid above 0.070 ppm. Seasons come from EPA's monitor list (all year in Houston, March to November in Dallas–Fort Worth), and every day counts, events included.

| Houston Aldine | 2023 | 2024 | 2025 | 2023–2025 |
|---|---|---|---|---|
| 4th-highest day (ppm) | 0.078 | 0.097 | 0.073 | 0.082, as in EPA's file |
| Completeness | 87% | 90% | 94% | 90% on average |

- **All 22 case-study ozone sites:** above 0.070 ppm for 2023–2025, from 0.071 (Houston Monroe) to 0.085 (Deer Park #2).
- **Against EPA:** the values match at 61 of 66 site-windows. Each miss is 0.001 ppm low and none changes pass or fail. `1a` drops days with under 75% of hours, while Appendix U keeps a day with 13 of its 17 daytime periods or a value above 0.070 ppm; adding the short days above 0.070 back from the raw files reproduces all 66 values.

**Validation (figure 3.10):** 12 claims the Phase 3 figures make are rerun under every check that applies, plus a second seed: all 88 pairs hold. All 20 checks in `distribution_validation.csv` pass, and the 49 numbers the report quotes are in `distribution_headlines.csv`. A separate base R recomputation, kept outside the repo, matched every saved fit and all 49 headlines.

## Report (5_report)

`R/5_report.Rmd` knits to `5_report.pdf` (28 pages) with LuaLaTeX. Every number is read at knit time from the four headline tables (139 rows) or from saved records, behind named assertions, so a changed result changes the text and a missing one stops the knit. Five figures sit in the text (2A.2, 2A.10, 1C.1, 2C.4, 3.6) and 12 in the appendix, beside the cleaning log, a code map and code excerpts read from the scripts. The verdicts: H1 (more NO₂ near the channel) is supported, H2 (less ozone from titration) is supported in part, and H3 (SO₂ from short local plumes) is supported.

## Saved files

- **`data/processed/`:** the `.rds` checkpoints, `data_dictionary.csv` (every saved column) and `checkpoint_manifest.csv` (size and MD5 of each checkpoint). CSV records sit in `phase1/`, `phase2/` and `phase3/`.
- **`data/distribution_cache/`:** not tracked. The slowest `3_distributions` steps reuse results saved here while their days, settings and code are unchanged; `rerun_cached_steps <- TRUE` recomputes them.
- **`figures/`:** every figure, numbered (`2a.01` to `3.10`) and sized for a 6.5-inch page, with lettered panels, a key and a short source note. Text sits at least 4 pt inside every panel frame (`edge_text()` in `utils.R`).

## Known limits

- **SO₂ sits near zero:** 97% to 99% of hours at three of the four sites are below the detection limit, and Clinton's baseline drifts.
- **Small groups:** hourly ozone and NO₂ have two sites per group, and Houston other has one five-year PM2.5 site.
- **Pointers, not proof:** distance to the channel water stands in for distance to the plants along it, and each wind direction brings its own kind of air.
- **Weather gaps:** wind is missing for up to 474 days in a row at Bayland Park, 314 at Grapevine and 161 at Deer Park #2.
- **Curves are relative:** a winner can still miss its tail, and a year-round curve blends two seasons. Tail tests say nothing about new days.
- **Detection limits:** the censored checks use method-wide federal limits, which can differ from a monitor's actual limit.
- **No ozone on December 31** in the daily table, an EPA file artifact. The hourly table has these days.
- **Short high days:** cleaning drops days under 75% of hours, so 5 of 66 case-study design values sit 0.001 ppm below EPA's.
- **Many comparisons:** dozens of ranges are reported without a multiple-comparison adjustment, so the results that hold under every check are the safest to cite.

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
| [EPA Air Quality Design Values](https://www.epa.gov/air-trends/air-quality-design-values), ozone file for 2023–2025 (posted 8 June 2026) | The official design values the worked ones are checked against |
| [AirNow hourly data fact sheet](https://docs.airnowapi.org/docs/HourlyDataFactSheet.pdf) | Negative hourly readings as instrument drift |
| [40 CFR 50, Appendix N](https://www.law.cornell.edu/cfr/text/40/appendix-N_to_part_50), Table 1 and section 4.3 | PM2.5: 98th percentile ranks, quarterly means and rounding |
| [40 CFR 50, Appendix S](https://www.law.cornell.edu/cfr/text/40/appendix-S_to_part_50), sections 3.2(b) and 4.2(c), Table 1 | NO₂: complete days, 98th percentile ranks and rounding |
| [40 CFR 50, Appendix T](https://www.law.cornell.edu/cfr/text/40/appendix-T_to_part_50), sections 3.1(b) and 4.1(c), Table 1 | SO₂: complete days, 99th percentile ranks and rounding |
| [40 CFR 50, Appendix U](https://www.law.cornell.edu/cfr/text/40/appendix-U_to_part_50), sections 3(b) to 3(e), 4(a) and 4(b) | Ozone 8-hour means, valid days, truncation and design value completeness |
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
