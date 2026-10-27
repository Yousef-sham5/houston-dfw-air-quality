# SETUP ----
library(dplyr)
library(readr)
library(tidyr)
library(stringr)
library(purrr)
library(janitor)
library(lubridate)
library(lobstr)
library(here)

source(here("R", "utils.R")) # study_years, log_step(), region_lookup, hourly zip helpers, calendar, events, save helpers



# CONFIG ----
hourly_codes <- c("44201", "42602", "42401")

hourly_dir <- here("data", "raw", "hourly")

processed_dir <- here("data", "processed")

# CSV records go to a folder per phase; checkpoints, the dictionary and the manifest stay in data/processed
records_dir <- file.path(processed_dir, "phase1")

dir.create(records_dir, recursive = TRUE, showWarnings = FALSE)

filtered_dir <- here("data", "hourly_filtered")



# 1. RAW FILES AND EPA ROW COUNTS ----
# The 15 zips the folder should hold: 3 pollutants x 5 years
expected_zips <- expand_grid(
  parameter_code = hourly_codes,
  year = study_years
) %>%
  mutate(file = str_c("hourly_", parameter_code, "_", year, ".zip"))

zip_paths <- hourly_dir %>%
  list.files(pattern = "^hourly_\\d{5}_\\d{4}\\.zip$", full.names = TRUE)

stopifnot(
  "data/raw/hourly holds exactly the 15 expected zips" =
    setequal(basename(zip_paths), expected_zips$file)
)

# Row counts from EPA's AirData file list (file_list.csv, files dated 2026-06-25). Section 3 counts every row
# while it reads each zip and checks the counts against this list
airdata_list_counts <- tribble(
  ~parameter_code, ~year, ~listed_rows,
  "44201",         2021,  9187353,
  "44201",         2022,  9022604,
  "44201",         2023,  9025194,
  "44201",         2024,  8995978,
  "44201",         2025,  8867266,
  "42401",         2021,  3577458,
  "42401",         2022,  3430869,
  "42401",         2023,  3315631,
  "42401",         2024,  3108105,
  "42401",         2025,  2940386,
  "42602",         2021,  3663086,
  "42602",         2022,  3640554,
  "42602",         2023,  3590973,
  "42602",         2024,  3547016,
  "42602",         2025,  3489728
)



# 2. CHECK FILE HEADERS ----
# aqs_hourly_columns (utils.R) holds the 24 columns EPA documents for hourly files (AirData file formats, section 6.2)
file_headers <- tibble(zip_path = zip_paths) %>%
  mutate(
    file = basename(zip_path),
    columns = map(zip_path, read_header)
  )

header_strings <- map_chr(file_headers$columns, \(x) str_flatten(x, "|"))

first_header <- file_headers$columns[[1]]

print(setdiff(aqs_hourly_columns, first_header))
print(setdiff(first_header, aqs_hourly_columns))

stopifnot(
  "All 15 files share one header" = n_distinct(header_strings) == 1,
  "Header matches EPA's 24 documented columns, in order" = identical(first_header, aqs_hourly_columns)
)

# Preview 5 rows as text, to see how values are written before setting column types
header_preview <- zip_paths[1] %>%
  read_first_lines(n = 6) %>%
  I() %>%
  read_csv(col_types = cols(.default = col_character()))

glimpse(header_preview)



# 3. FILTER TO THE CASE-STUDY MONITORS ----
# The 16 monitors picked in 1c, as site ID and parameter code
parameter_codes <- tribble(
  ~pollutant, ~parameter_code,
  "Ozone",    44201L,
  "NO2",      42602L,
  "SO2",      42401L
)

case_study_monitors <- here("data", "reference", "case_study_sites.csv") %>%
  read_csv(col_types = cols(.default = col_character())) %>%
  select(site_id, pollutant) %>%
  left_join(parameter_codes, by = "pollutant", relationship = "many-to-one")

stopifnot(
  "16 case-study monitors" = nrow(case_study_monitors) == 16,
  "Every monitor has a parameter code" = !anyNA(case_study_monitors$parameter_code)
)

# Each zip is read in 1-million-row chunks with the 16 columns in aqs_hourly_col_spec, and the case-study rows are
# saved to data/hourly_filtered with the number of rows read (filter_case_study_zip() in utils.R). A saved file is
# reused while its zip keeps the same size and modification time, so a rerun skips the full read
dir.create(filtered_dir, showWarnings = FALSE)

filtered_paths <- map_chr(zip_paths, \(zip_path) filter_case_study_zip(zip_path, filtered_dir, case_study_monitors), .progress = TRUE)

filtered_files <- map(filtered_paths, read_rds)

filter_log <- tibble(
  file = basename(zip_paths),
  rows_read = map_dbl(filtered_files, "rows_read"),
  rows_kept = map_int(filtered_files, \(x) nrow(x$data))
)

print(filter_log, n = Inf)

# Every row in every file must have been read: rows read has to equal EPA's listed count
hourly_row_counts <- filter_log %>%
  mutate(
    parameter_code = str_sub(file, 8, 12),
    year = as.integer(str_sub(file, 14, 17))
  ) %>%
  select(file, parameter_code, year, raw_rows = rows_read) %>%
  arrange(parameter_code, year)

row_count_check <- hourly_row_counts %>%
  left_join(airdata_list_counts, by = c("parameter_code", "year"), relationship = "one-to-one") %>%
  mutate(difference = raw_rows - listed_rows)

print(row_count_check, n = Inf, width = Inf)

# A mismatch means a damaged download, or files EPA has since regenerated (check file_list.csv again)
stopifnot(
  "Every file has an EPA listed count" = !anyNA(row_count_check$listed_rows),
  "Rows read match EPA's file list" = all(row_count_check$difference == 0),
  "Every file kept some rows" = all(filter_log$rows_kept > 0)
)

hourly_row_counts %>%
  group_by(year) %>%
  summarise(raw_rows = sum(raw_rows)) %>%
  print()

print(sum(hourly_row_counts$raw_rows))

# Saved as a record of the rows in each raw file
write_csv(hourly_row_counts, file.path(records_dir, "hourly_raw_row_counts.csv"))

hourly_raw <- filtered_files %>%
  map("data") %>%
  list_rbind() %>%
  clean_names()

rm(filtered_files)
invisible(gc())

print(obj_size(hourly_raw))

# All 16 monitors found, and no instrument has more rows in a year than there are hours
monitors_found <- hourly_raw %>%
  distinct(site_id, parameter_code)

instrument_year_rows <- hourly_raw %>%
  count(site_id, parameter_code, poc, year = year(date_local), name = "n_rows") %>%
  mutate(hours_in_year = if_else(leap_year(year), 8784L, 8760L))

stopifnot(
  "Only the 16 chosen columns were read, plus site_id" = ncol(hourly_raw) == length(aqs_hourly_col_spec$cols) + 1,
  "All 16 case-study monitors are in the hourly data" =
    nrow(semi_join(case_study_monitors, monitors_found, by = c("site_id", "parameter_code"))) == 16,
  "Only case-study monitors were kept" = nrow(monitors_found) == 16,
  "No instrument has more rows in a year than hours" = all(instrument_year_rows$n_rows <= instrument_year_rows$hours_in_year)
)

hourly_raw %>%
  count(site_id, parameter_code, poc, name = "n_rows") %>%
  print(n = Inf)

hourly_cleaning_log <- tibble(
  step = c("Raw hourly files", "Keep case-study monitors"),
  rows = c(sum(hourly_row_counts$raw_rows), nrow(hourly_raw))
) %>%
  mutate(rows_removed = lag(rows) - rows)

print(hourly_cleaning_log)



# 4. INSPECT VALUES ----
# Nothing is removed in this section. The counts below decide the cleaning rules in section 5
hourly_raw <- hourly_raw %>%
  left_join(parameter_codes, by = "parameter_code", relationship = "many-to-one")

stopifnot("Every row has a pollutant name" = !anyNA(hourly_raw$pollutant))

# Missing values by column, then missing measurements by monitor
missing_by_column <- hourly_raw %>%
  summarise(across(everything(), \(x) sum(is.na(x)))) %>%
  pivot_longer(everything(), names_to = "column", values_to = "n_missing") %>%
  filter(n_missing > 0)

print(missing_by_column)

hourly_raw %>%
  group_by(pollutant, site_id) %>%
  summarise(
    n_rows = n(),
    n_missing_value = sum(is.na(sample_measurement)),
    n_missing_mdl = sum(is.na(mdl)),
    .groups = "drop"
  ) %>%
  print(n = Inf)

# Units: one per pollutant, matching the daily data (ozone in ppm, NO2 and SO2 in ppb)
expected_units <- tribble(
  ~pollutant, ~expected_unit,
  "Ozone",    "Parts per million",
  "NO2",      "Parts per billion",
  "SO2",      "Parts per billion"
)

unit_check <- hourly_raw %>%
  distinct(pollutant, units_of_measure) %>%
  left_join(expected_units, by = "pollutant", relationship = "many-to-one")

print(unit_check)

stopifnot(
  "One unit per pollutant" = nrow(unit_check) == 3,
  "Units match the daily data" = all(unit_check$units_of_measure == unit_check$expected_unit)
)

# Time zone: AQS local times skip daylight saving, so Texas is always 6 hours behind GMT (check in utils.R)
check_local_standard_time(hourly_raw)

# Method detection limit (MDL): the values each monitor reports, and whether
# values below the MDL were replaced with MDL/2
mdl_by_monitor <- hourly_raw %>%
  group_by(pollutant, site_id) %>%
  summarise(
    units = first(units_of_measure),
    n_mdl_values = n_distinct(mdl, na.rm = TRUE),
    min_mdl = min(mdl, na.rm = TRUE),
    max_mdl = max(mdl, na.rm = TRUE),
    .groups = "drop"
  )

print(mdl_by_monitor, n = Inf)

mdl_check <- hourly_raw %>%
  filter(!is.na(sample_measurement), !is.na(mdl)) %>%
  mutate(
    half_mdl = mdl / 2,
    below_mdl = sample_measurement < mdl,
    at_half_mdl = abs(sample_measurement - half_mdl) < 1e-9
  ) %>%
  group_by(pollutant, site_id) %>%
  summarise(
    n_values = n(),
    n_below_mdl = sum(below_mdl),
    n_at_half_mdl = sum(at_half_mdl),
    n_md_qualifier = sum(qualifier %in% "MD"),
    pct_below_mdl = round(100 * n_below_mdl / n_values, 2),
    pct_at_half_mdl = round(100 * n_at_half_mdl / n_values, 2),
    .groups = "drop"
  )

print(mdl_check, n = Inf, width = Inf)

# The most common value below the MDL at each monitor. A large pile-up exactly at MDL/2
# means the agency substituted MDL/2; a spread of values means it reported raw readings
top_below_mdl_value <- hourly_raw %>%
  filter(sample_measurement < mdl) %>%
  count(pollutant, site_id, mdl, sample_measurement, name = "n_rows") %>%
  slice_max(n_rows, n = 1, with_ties = FALSE, by = c(pollutant, site_id)) %>%
  mutate(is_half_mdl = abs(sample_measurement - mdl / 2) < 1e-9)

print(top_below_mdl_value, n = Inf, width = Inf)

# Range, zeros and negatives. Values between -MDL and 0 are instrument noise around zero
value_check <- hourly_raw %>%
  filter(!is.na(sample_measurement)) %>%
  group_by(pollutant, site_id) %>%
  summarise(
    units = first(units_of_measure),
    min_value = min(sample_measurement),
    max_value = max(sample_measurement),
    n_zero = sum(sample_measurement == 0),
    n_negative = sum(sample_measurement < 0),
    n_below_minus_mdl = sum(sample_measurement < -mdl, na.rm = TRUE),
    .groups = "drop"
  )

print(value_check, n = Inf, width = Inf)

# Qualifiers, typed with EPA's AQS qualifier table (aqs_qualifier_types in utils.R). Any code outside the lookup
# is labelled so it can be looked up before a rule is set
qualifier_counts <- hourly_raw %>%
  filter(!is.na(qualifier)) %>%
  count(pollutant, qualifier, has_value = !is.na(sample_measurement), name = "n_rows") %>%
  left_join(aqs_qualifier_types, by = "qualifier", relationship = "many-to-one") %>%
  mutate(qualifier_type = replace_na(qualifier_type, "Not in lookup: check EPA table")) %>%
  arrange(pollutant, desc(n_rows))

print(qualifier_counts, n = Inf, width = Inf)

hourly_raw %>%
  group_by(pollutant, site_id) %>%
  summarise(
    n_rows = n(),
    n_qualified = sum(!is.na(qualifier)),
    pct_qualified = round(100 * n_qualified / n_rows, 2),
    .groups = "drop"
  ) %>%
  print(n = Inf)

# Method codes, checked against EPA's methods table as in 1a_import_clean.R
methods_ref <- read_methods_ref()

hourly_methods <- hourly_raw %>%
  count(pollutant, parameter_code, method_code, name = "n_rows")

method_types <- methods_ref %>%
  semi_join(hourly_methods, by = c("parameter_code", "method_code")) %>%
  distinct(parameter_code, method_code, method_type)

stopifnot(
  "Method codes are 3 characters" = all(str_length(hourly_raw$method_code) == 3),
  "One method type per method code" = !anyDuplicated(method_types[c("parameter_code", "method_code")])
)

method_check <- hourly_methods %>%
  left_join(method_types, by = c("parameter_code", "method_code"), relationship = "one-to-one")

print(method_check, n = Inf, width = Inf)

stopifnot("Every method code is in EPA's methods table" = !anyNA(method_check$method_type))

# Repeated hours for the same instrument (checked again when timestamps are built)
duplicate_hours <- hourly_raw %>%
  count(site_id, parameter_code, poc, date_local, time_local) %>%
  filter(n > 1)

print(nrow(duplicate_hours))

# Coordinates over time, printed to 6 decimals. Deer Park #2's move does not show here because EPA lists one pair
site_locations <- hourly_raw %>%
  group_by(site_id, latitude, longitude) %>%
  summarise(
    first_date = min(date_local),
    last_date = max(date_local),
    n_rows = n(),
    .groups = "drop"
  ) %>%
  arrange(site_id, first_date) %>%
  mutate(across(c(latitude, longitude), \(x) sprintf("%.6f", x)))

print(site_locations, n = Inf, width = Inf)



# 5. FLAG WILDFIRE AND BELOW-DETECTION-LIMIT HOURS ----
# No rows are removed from here on. Each rule adds a flag, so later phases can keep or leave out these hours
qualifiers_present <- hourly_raw %>%
  filter(!is.na(qualifier)) %>%
  distinct(qualifier) %>%
  pull(qualifier)

stopifnot(
  "RT is the only qualifier present (any other code needs its own rule)" = all(qualifiers_present == "RT"),
  "No measurement or detection limit is missing" =
    !anyNA(hourly_raw$sample_measurement) && !anyNA(hourly_raw$mdl),
  "No reading falls below the negative of its detection limit" =
    all(hourly_raw$sample_measurement >= -hourly_raw$mdl)
)

# RT marks hours the agency asked EPA to exclude for U.S. wildfire smoke
hourly <- hourly_raw %>%
  mutate(is_wildfire_flagged = qualifier %in% "RT")

hourly_cleaning_log <- hourly_cleaning_log %>%
  log_step("Flag wildfire (RT) hours, none removed", hourly)

# Readings below the MDL are kept as reported, zeros and negatives included
hourly <- hourly %>%
  mutate(below_mdl = sample_measurement < mdl)

hourly_cleaning_log <- hourly_cleaning_log %>%
  log_step("Flag readings below the detection limit, none removed", hourly)

hourly %>%
  group_by(pollutant, site_id) %>%
  summarise(
    n_hours = n(),
    n_wildfire_flagged = sum(is_wildfire_flagged),
    n_below_mdl = sum(below_mdl),
    pct_below_mdl = round(100 * n_below_mdl / n_hours, 2),
    .groups = "drop"
  ) %>%
  print(n = Inf)



# 6. BUILD TIMESTAMPS AND CALENDAR COLUMNS ----
# AQS local times skip daylight saving (section 4), so Texas is always UTC-6 (standard_time_zone in utils.R)
hourly <- hourly %>%
  mutate(datetime_local = ymd_hm(str_c(date_local, " ", time_local), tz = standard_time_zone))

# The UTC timestamp is kept for joins with data recorded in UTC, such as weather observations
hourly <- hourly %>%
  mutate(datetime_utc = ymd_hm(str_c(date_gmt, " ", time_gmt), tz = "UTC"))

hourly <- hourly %>%
  mutate(hour_local = hour(datetime_local))

duplicate_timestamps <- hourly %>%
  count(pollutant, site_id, poc, datetime_local) %>%
  filter(n > 1)

stopifnot(
  "Every timestamp parses" = !anyNA(hourly$datetime_local) && !anyNA(hourly$datetime_utc),
  "Local standard time and UTC name the same instant" = all(hourly$datetime_local == hourly$datetime_utc),
  "Each timestamp falls on its local date" = all(as_date(hourly$datetime_local) == hourly$date_local),
  "Hours run from 0 to 23" = all(hourly$hour_local %in% 0:23),
  "One row per monitor and hour" = nrow(duplicate_timestamps) == 0
)

# Weekday, weekend and season come from the same function as in 1a_import_clean.R (utils.R), so hourly and daily
# results group the same way
hourly <- hourly %>%
  add_calendar_columns()



# 7. CONVERT UNITS ----
# Ozone arrives in ppm, NO2 and SO2 in ppb. Values in ppb put the three gases on one scale, and
# µg/m³ uses the same ideal-gas molar volume as 1a_import_clean.R (25 °C and 1 atm, molar_volume in utils.R)
unit_factors <- tribble(
  ~pollutant, ~mw_g_mol, ~to_ppb,
  "Ozone",    48.00,     1000,
  "NO2",      46.01,     1,
  "SO2",      64.06,     1
) %>%
  mutate(ppb_to_ugm3 = mw_g_mol / molar_volume)

# Hand-calculated with Vm = 24.4654 L/mol, in µg/m³ per ppb: ozone, NO2, SO2
expected_ppb_to_ugm3 <- c(1.961954, 1.880615, 2.618391)

stopifnot(
  "Conversion factors match the hand calculation" =
    isTRUE(all.equal(unit_factors$ppb_to_ugm3, expected_ppb_to_ugm3, tolerance = 1e-6))
)

hourly <- hourly %>%
  left_join(unit_factors, by = "pollutant", relationship = "many-to-one")

hourly <- hourly %>%
  mutate(value_ppb = round(sample_measurement * to_ppb, 3))

hourly <- hourly %>%
  mutate(mdl_ppb = round(mdl * to_ppb, 3))

hourly <- hourly %>%
  mutate(value_ugm3 = value_ppb * ppb_to_ugm3)

hourly <- hourly %>%
  select(-mw_g_mol, -to_ppb, -ppb_to_ugm3)

stopifnot(
  "Every row has a value in ppb and µg/m³" = !anyNA(hourly$value_ppb) && !anyNA(hourly$value_ugm3),
  "NO2 and SO2 are unchanged in ppb" =
    all(hourly$value_ppb[hourly$pollutant != "Ozone"] == hourly$sample_measurement[hourly$pollutant != "Ozone"])
)

hourly %>%
  group_by(pollutant) %>%
  summarise(
    original_unit = first(units_of_measure),
    min_ppb = min(value_ppb),
    max_ppb = max(value_ppb),
    max_ugm3 = round(max(value_ugm3), 1)
  ) %>%
  print()



# 8. ADD SITE GROUP, REGION AND EVENT LABELS ----
site_groups <- here("data", "reference", "case_study_sites.csv") %>%
  read_csv(col_types = cols_only(
    site_id         = col_character(),
    pollutant       = col_character(),
    site_group      = col_character(),
    local_site_name = col_character()
  ))

hourly <- hourly %>%
  left_join(site_groups, by = c("site_id", "pollutant"), relationship = "many-to-one")

hourly <- hourly %>%
  mutate(county_id = str_sub(site_id, 1, 6))

hourly <- hourly %>%
  left_join(region_lookup, by = "county_id", relationship = "many-to-one")

stopifnot(
  "Every row has a site group, a site name and a region" =
    !anyNA(hourly$site_group) && !anyNA(hourly$local_site_name) && !anyNA(hourly$region),
  "Three site groups" = n_distinct(hourly$site_group) == 3
)

# Event windows from events.csv, read and checked as in 1a_import_clean.R (read_events() in utils.R) and matched
# the same way: on state and date, then on county (if given) and pollutant
event_windows <- read_events() %>%
  split_event_pollutants()

monitor_days <- hourly %>%
  distinct(pollutant, site_id, state_code, county_code, date_local)

event_matches <- monitor_days %>%
  inner_join(event_windows, by = join_by(state_code, between(date_local, start_date, end_date))) %>%
  filter(is.na(event_county) | county_code == event_county) %>%
  filter(event_pollutant == "all" | event_pollutant == pollutant) %>%
  distinct(pollutant, site_id, date_local, event_name)

multi_event_days <- event_matches %>%
  count(pollutant, site_id, date_local) %>%
  filter(n > 1)

stopifnot("No monitor-day falls in two events" = nrow(multi_event_days) == 0)

hourly <- hourly %>%
  left_join(event_matches, by = c("pollutant", "site_id", "date_local"), relationship = "many-to-one")

hourly %>%
  filter(!is.na(event_name)) %>%
  distinct(event_name, pollutant, site_id, date_local) %>%
  count(event_name, pollutant, name = "monitor_days") %>%
  print()



# 9. FLAG COMPLETE DAYS ----
# A day is complete with at least 75% of its hours (18 of 24). Hours on incomplete days stay in and are flagged
min_hours_per_day <- 18

hourly <- hourly %>%
  add_count(pollutant, site_id, date_local, name = "n_hours_day")

hourly <- hourly %>%
  mutate(is_complete_day = n_hours_day >= min_hours_per_day)

stopifnot("No day has more than 24 hours" = all(hourly$n_hours_day <= 24))

hourly_cleaning_log <- hourly_cleaning_log %>%
  log_step("Flag days with fewer than 18 hours, none removed", hourly)

hourly %>%
  distinct(pollutant, site_id, date_local, n_hours_day, is_complete_day) %>%
  group_by(pollutant) %>%
  summarise(
    monitor_days = n(),
    complete_days = sum(is_complete_day),
    incomplete_days = sum(!is_complete_day),
    hours_on_incomplete_days = sum(n_hours_day[!is_complete_day])
  ) %>%
  print()

# Ozone days follow EPA's rule (40 CFR 50 Appendix U, section 3), which uses 8-hour averages.
# Each hour from 7:00 to 23:00 starts one 8-hour window, so a day has 17 windows; the 23:00 window ends at
# 06:59 the next morning. A window counts if at least 6 of its 8 hours have data, and its average is
# truncated to 3 decimals in ppm (0.0708 becomes 0.070). A day is valid when at least 13 of its 17 windows count.
# Missing hours are first added as NA rows, so each row is one hour and lead() moves exactly one hour
study_hours <- seq(
  make_datetime(min(study_years), 1, 1, 0, tz = standard_time_zone),
  make_datetime(max(study_years), 12, 31, 23, tz = standard_time_zone),
  by = "1 hour"
)

ozone_grid <- hourly %>%
  filter(pollutant == "Ozone") %>%
  select(site_id, poc, datetime_local, ozone_ppm = sample_measurement) %>%
  group_by(site_id, poc) %>%
  complete(datetime_local = study_hours) %>%
  arrange(datetime_local, .by_group = TRUE)

ozone_8hr <- ozone_grid %>%
  mutate(n_valid_hours = reduce(map(0:7, \(k) lead(as.integer(!is.na(ozone_ppm)), k, default = 0L)), `+`)) %>%
  mutate(sum_8hr = reduce(map(0:7, \(k) lead(coalesce(ozone_ppm, 0), k, default = 0)), `+`)) %>%
  mutate(mean_8hr = if_else(n_valid_hours >= 6, sum_8hr / n_valid_hours, NA_real_)) %>%
  mutate(mean_8hr = floor(round(mean_8hr * 1000, 6)) / 1000) %>%
  ungroup()

min_valid_8hr_means <- 13

# One row per ozone monitor and day in the study window, including days with no data at all
ozone_day_validity <- ozone_8hr %>%
  mutate(date_local = as_date(datetime_local)) %>%
  mutate(begin_hour = hour(datetime_local)) %>%
  filter(begin_hour >= 7) %>%
  group_by(site_id, poc, date_local) %>%
  summarise(n_valid_8hr_means = sum(!is.na(mean_8hr)), .groups = "drop") %>%
  mutate(pollutant = "Ozone") %>%
  mutate(is_valid_ozone_day = n_valid_8hr_means >= min_valid_8hr_means)

# Both columns stay NA for NO2 and SO2, which are judged on the 18-hour rule above
hourly <- hourly %>%
  left_join(
    ozone_day_validity,
    by = c("pollutant", "site_id", "poc", "date_local"),
    relationship = "many-to-one"
  )

stopifnot(
  "No day has more than 17 valid 8-hour means" = all(ozone_day_validity$n_valid_8hr_means <= 17),
  "Every ozone hour has an 8-hour day flag" = !anyNA(hourly$is_valid_ozone_day[hourly$pollutant == "Ozone"]),
  "The 8-hour day flag is empty for NO2 and SO2" = all(is.na(hourly$is_valid_ozone_day[hourly$pollutant != "Ozone"])),
  "The join added no rows" = nrow(hourly) == last(hourly_cleaning_log$rows)
)

hourly_cleaning_log <- hourly_cleaning_log %>%
  log_step("Flag ozone days with fewer than 13 valid 8-hour means, none removed", hourly)

# Ozone monitor-days under each rule. The two flags agree on most days
hourly %>%
  filter(pollutant == "Ozone") %>%
  distinct(site_id, date_local, is_complete_day, is_valid_ozone_day) %>%
  count(is_complete_day, is_valid_ozone_day, name = "ozone_monitor_days") %>%
  print()



# 10. CHECK DEER PARK #2 FOR A LEVEL SHIFT AFTER ITS MOVE ----
# The site moved on 2025-05-30 and kept its AQS ID. Its hourly gap to a neighbour that did not move is
# averaged over June to December of each year. A 2025 gap outside the range of the earlier years would
# point to a shift. Nothing is adjusted: hours after the move are flagged
deer_park_id <- "48-201-1039"

relocation_date <- ymd("2025-05-30")

hourly <- hourly %>%
  mutate(is_post_relocation = site_id == deer_park_id & date_local >= relocation_date)

# Houston East measures ozone and NO2 in the same site group. Park Place stands in for SO2,
# because the Clinton SO2 baseline drifts downward over the five years
neighbour_sites <- tribble(
  ~pollutant, ~neighbour_id,
  "Ozone",    "48-201-1034",
  "NO2",      "48-201-1034",
  "SO2",      "48-201-0416"
)

deer_park_hours <- hourly %>%
  filter(site_id == deer_park_id) %>%
  select(pollutant, datetime_local, deer_park_ppb = value_ppb)

neighbour_hours <- hourly %>%
  semi_join(neighbour_sites, by = c("pollutant", "site_id" = "neighbour_id")) %>%
  select(pollutant, datetime_local, neighbour_ppb = value_ppb)

paired_hours <- deer_park_hours %>%
  inner_join(neighbour_hours, by = c("pollutant", "datetime_local"), relationship = "one-to-one") %>%
  filter(month(datetime_local) >= 6)

yearly_gap <- paired_hours %>%
  mutate(year = year(datetime_local)) %>%
  group_by(pollutant, year) %>%
  summarise(
    n_paired_hours = n(),
    deer_park_mean_ppb = mean(deer_park_ppb),
    neighbour_mean_ppb = mean(neighbour_ppb),
    mean_gap_ppb = mean(deer_park_ppb - neighbour_ppb),
    .groups = "drop"
  )

stopifnot(
  "Each pollutant has paired hours in all five years" =
    all(count(yearly_gap, pollutant)$n == length(study_years))
)

print(yearly_gap, n = Inf)

relocation_check <- yearly_gap %>%
  group_by(pollutant) %>%
  summarise(
    lowest_earlier_gap_ppb = min(mean_gap_ppb[year < year(relocation_date)]),
    highest_earlier_gap_ppb = max(mean_gap_ppb[year < year(relocation_date)]),
    gap_after_move_ppb = mean_gap_ppb[year == year(relocation_date)]
  ) %>%
  mutate(
    outside_earlier_range =
      gap_after_move_ppb < lowest_earlier_gap_ppb | gap_after_move_ppb > highest_earlier_gap_ppb
  )

print(relocation_check)

rm(deer_park_hours, neighbour_hours, paired_hours)



# 11. CHECK HARVARD STREET NO2 FOR A LEVEL SHIFT AFTER ITS METHOD CHANGE ----
# The monitor changed from method 099 to method 186 on 2024-04-22, and its detection limit rose from 2.7 to 5 ppb.
# Its hourly gap to two neighbours that kept one method is averaged over May to December of each year, the months
# the new method covers in both 2024 and 2025. Nothing is adjusted: hours on the new method are flagged
harvard_street_id <- "48-201-0417"

method_change_date <- ymd("2024-04-22")

monitors_with_two_methods <- hourly %>%
  distinct(pollutant, site_id, method_code) %>%
  count(pollutant, site_id, name = "n_methods") %>%
  filter(n_methods > 1)

harvard_methods <- hourly %>%
  filter(site_id == harvard_street_id, pollutant == "NO2") %>%
  group_by(method_code, mdl_ppb) %>%
  summarise(
    first_date = min(date_local),
    last_date = max(date_local),
    n_hours = n(),
    pct_below_mdl = round(100 * mean(below_mdl), 1),
    pct_zero = round(100 * mean(value_ppb == 0), 1),
    mean_ppb = round(mean(value_ppb), 2),
    .groups = "drop"
  ) %>%
  arrange(first_date)

print(harvard_methods, width = Inf)

stopifnot(
  "Harvard Street NO2 is the only monitor that changed method" =
    nrow(monitors_with_two_methods) == 1 &&
    monitors_with_two_methods$site_id == harvard_street_id &&
    monitors_with_two_methods$pollutant == "NO2",
  "Harvard Street NO2 reports under two methods" = nrow(harvard_methods) == 2,
  "The first method ends before the change date" = harvard_methods$last_date[1] < method_change_date,
  "The second method starts on the change date" = harvard_methods$first_date[2] == method_change_date
)

hourly <- hourly %>%
  mutate(is_post_method_change = site_id == harvard_street_id & pollutant == "NO2" & date_local >= method_change_date)

new_method_hours <- hourly %>%
  filter(site_id == harvard_street_id, pollutant == "NO2", method_code == harvard_methods$method_code[2])

stopifnot(
  "The flag marks exactly the hours on the new method" =
    sum(hourly$is_post_method_change) == nrow(new_method_hours) && all(new_method_hours$is_post_method_change)
)

# Houston Bayland Park is the other NO2 monitor in the same site group, and Houston East is a second neighbour.
# Both kept one method for all five years. Deer Park #2 is left out, because its own NO2 stepped up in 2024
method_neighbour_ids <- c("48-201-0055", "48-201-1034")

harvard_hours <- hourly %>%
  filter(site_id == harvard_street_id, pollutant == "NO2") %>%
  select(datetime_local, harvard_ppb = value_ppb)

method_neighbour_hours <- hourly %>%
  filter(site_id %in% method_neighbour_ids, pollutant == "NO2") %>%
  select(neighbour = local_site_name, datetime_local, neighbour_ppb = value_ppb)

method_paired_hours <- harvard_hours %>%
  inner_join(method_neighbour_hours, by = "datetime_local", relationship = "one-to-many") %>%
  filter(month(datetime_local) >= 5)

method_yearly_gap <- method_paired_hours %>%
  mutate(year = year(datetime_local)) %>%
  group_by(neighbour, year) %>%
  summarise(
    n_paired_hours = n(),
    harvard_mean_ppb = mean(harvard_ppb),
    neighbour_mean_ppb = mean(neighbour_ppb),
    mean_gap_ppb = mean(harvard_ppb - neighbour_ppb),
    .groups = "drop"
  )

stopifnot(
  "Each neighbour has paired hours in all five years" =
    all(count(method_yearly_gap, neighbour)$n == length(study_years))
)

print(method_yearly_gap, n = Inf)

# The change year and the year after are each compared with the range of the earlier years
method_change_check <- method_yearly_gap %>%
  group_by(neighbour) %>%
  summarise(
    lowest_earlier_gap_ppb = min(mean_gap_ppb[year < year(method_change_date)]),
    highest_earlier_gap_ppb = max(mean_gap_ppb[year < year(method_change_date)]),
    gap_change_year_ppb = mean_gap_ppb[year == year(method_change_date)],
    gap_next_year_ppb = mean_gap_ppb[year == year(method_change_date) + 1]
  ) %>%
  mutate(
    change_year_outside_earlier_range =
      gap_change_year_ppb < lowest_earlier_gap_ppb | gap_change_year_ppb > highest_earlier_gap_ppb
  ) %>%
  mutate(
    next_year_outside_earlier_range =
      gap_next_year_ppb < lowest_earlier_gap_ppb | gap_next_year_ppb > highest_earlier_gap_ppb
  )

print(method_change_check, width = Inf)

# Exact zeros and negatives by month on the new method. A pile-up at zero with no negatives points to a low baseline
hourly %>%
  filter(is_post_method_change) %>%
  group_by(month = floor_date(date_local, unit = "month")) %>%
  summarise(
    n_hours = n(),
    n_zero = sum(value_ppb == 0),
    n_negative = sum(value_ppb < 0),
    pct_zero = round(100 * n_zero / n_hours, 1)
  ) %>%
  print(n = Inf)

rm(harvard_hours, method_neighbour_hours, method_paired_hours, new_method_hours)



# 12. VALIDATE AGAINST THE DAILY DATA ----
# The hourly values should rebuild the daily maximum that 1a_import_clean.R kept for the same monitor and day
daily_values <- file.path(processed_dir, "aqs_long_clean.rds") %>%
  read_rds() %>%
  mutate(pollutant = as.character(pollutant)) %>%
  semi_join(case_study_monitors, by = c("site_id", "pollutant")) %>%
  select(
    pollutant, site_id, poc, date_local, first_max_value, first_max_hour,
    daily_event_name = event_name,
    daily_day_of_week = day_of_week,
    daily_is_weekend = is_weekend,
    daily_season = season
  )

invisible(gc())

stopifnot(
  "The daily table holds one row per monitor and day" =
    !anyDuplicated(daily_values[c("pollutant", "site_id", "poc", "date_local")])
)

# NO2 and SO2: the daily value is the highest 1-hour reading of the day
gas_daily_max <- hourly %>%
  filter(pollutant != "Ozone") %>%
  group_by(pollutant, site_id, poc, date_local) %>%
  summarise(
    hourly_max = max(sample_measurement),
    hourly_max_hour = hour_local[which.max(sample_measurement)],
    .groups = "drop"
  )

# Ozone: the daily value is the highest of the 8-hour means built in section 9 (start hours 7 to 23,
# 6 of 8 hours each, truncated to 3 decimals in ppm)
ozone_daily_max <- ozone_8hr %>%
  mutate(date_local = as_date(datetime_local)) %>%
  mutate(begin_hour = hour(datetime_local)) %>%
  filter(begin_hour >= 7, !is.na(mean_8hr)) %>%
  group_by(site_id, poc, date_local) %>%
  summarise(
    hourly_max = max(mean_8hr),
    hourly_max_hour = begin_hour[which.max(mean_8hr)],
    .groups = "drop"
  ) %>%
  mutate(pollutant = "Ozone")

daily_check <- daily_values %>%
  left_join(
    bind_rows(gas_daily_max, ozone_daily_max),
    by = c("pollutant", "site_id", "poc", "date_local"),
    relationship = "one-to-one"
  ) %>%
  mutate(max_matches = abs(first_max_value - hourly_max) < 1e-9) %>%
  mutate(hour_matches = first_max_hour == hourly_max_hour)

validation_summary <- daily_check %>%
  group_by(pollutant) %>%
  summarise(
    daily_days = n(),
    found_in_hourly = sum(!is.na(hourly_max)),
    max_matches = sum(max_matches, na.rm = TRUE),
    hour_matches = sum(hour_matches, na.rm = TRUE)
  ) %>%
  mutate(pct_max_matches = round(100 * max_matches / daily_days, 2))

print(validation_summary)

# Event labels and calendar columns should agree with the daily table on every shared monitor-day
label_check <- hourly %>%
  distinct(pollutant, site_id, date_local, event_name, day_of_week, is_weekend, season) %>%
  inner_join(
    distinct(daily_values, pollutant, site_id, date_local, daily_event_name, daily_day_of_week, daily_is_weekend, daily_season),
    by = c("pollutant", "site_id", "date_local"),
    relationship = "one-to-one"
  ) %>%
  mutate(event_matches = coalesce(event_name, "none") == coalesce(daily_event_name, "none")) %>%
  mutate(
    calendar_matches =
      as.character(day_of_week) == as.character(daily_day_of_week) &
      is_weekend == daily_is_weekend &
      as.character(season) == as.character(daily_season)
  )

# The ozone day flag against the daily table. Every ozone day the daily table kept should be a valid ozone day.
# The reverse fails only on December 31: EPA's yearly files cannot see the January 1 hours, so they report
# 11 or 12 of that day's 17 means, and the 75% rule in 1a_import_clean.R drops the day
daily_ozone_days <- daily_values %>%
  filter(pollutant == "Ozone") %>%
  distinct(site_id, poc, date_local) %>%
  mutate(in_daily_table = TRUE)

ozone_day_check <- hourly %>%
  filter(pollutant == "Ozone") %>%
  distinct(site_id, poc, date_local, is_valid_ozone_day) %>%
  left_join(daily_ozone_days, by = c("site_id", "poc", "date_local"), relationship = "one-to-one") %>%
  mutate(in_daily_table = coalesce(in_daily_table, FALSE)) %>%
  mutate(is_december_31 = month(date_local) == 12 & day(date_local) == 31)

daily_days_not_valid <- ozone_day_check %>%
  filter(in_daily_table, !is_valid_ozone_day)

valid_days_missing_from_daily <- ozone_day_check %>%
  filter(is_valid_ozone_day, !in_daily_table)

valid_days_missing_from_daily %>%
  count(is_december_31, name = "valid_ozone_days_missing_from_daily") %>%
  print()

stopifnot(
  "Every daily value has hourly data behind it" = !anyNA(daily_check$hourly_max),
  "The hourly data rebuild every daily maximum" = all(daily_check$max_matches),
  "The hourly data rebuild the hour of every daily maximum" = all(daily_check$hour_matches),
  "Event labels agree with the daily data" = all(label_check$event_matches),
  "Weekday, weekend and season agree with the daily data" = all(label_check$calendar_matches),
  "Every ozone day in the daily table is a valid ozone day" = nrow(daily_days_not_valid) == 0,
  "Valid ozone days missing from the daily table all fall on December 31" =
    all(valid_days_missing_from_daily$is_december_31)
)

# The same checks as a table, saved in section 14 as a record of what this run confirmed
max_checks <- validation_summary %>%
  transmute(
    check = str_c(pollutant, ": daily maximums rebuilt from the hourly values"),
    observed = as.character(max_matches),
    expected = as.character(daily_days)
  )

hour_checks <- validation_summary %>%
  transmute(
    check = str_c(pollutant, ": hours of the daily maximum rebuilt from the hourly values"),
    observed = as.character(hour_matches),
    expected = as.character(daily_days)
  )

other_checks <- tribble(
  ~check,                                                           ~observed,                                               ~expected,
  "Daily values with no hourly data behind them",                   as.character(sum(is.na(daily_check$hourly_max))),        "0",
  "Monitor-days whose event label differs from the daily data",     as.character(sum(!label_check$event_matches)),           "0",
  "Monitor-days whose calendar columns differ from the daily data", as.character(sum(!label_check$calendar_matches)),        "0",
  "Daily ozone values on days without 13 valid 8-hour means",       as.character(nrow(daily_days_not_valid)),                "0",
  "Valid ozone days missing from the daily table, December 31 aside", as.character(sum(!valid_days_missing_from_daily$is_december_31)), "0",
  "Timestamps that differ from EPA's GMT time",                     as.character(sum(hourly$datetime_local != hourly$datetime_utc)), "0",
  "Duplicate monitor-hours",                                        as.character(nrow(duplicate_timestamps)),                "0",
  "Case-study monitors in the table",                               as.character(nrow(distinct(hourly, pollutant, site_id))), as.character(nrow(case_study_monitors))
)

hourly_validation <- bind_rows(max_checks, hour_checks, other_checks) %>%
  mutate(passed = observed == expected)

stopifnot("Every hourly validation check passed" = all(hourly_validation$passed))

print(hourly_validation, n = Inf, width = Inf)

monitor_validation <- daily_check %>%
  group_by(pollutant, site_id) %>%
  summarise(
    n_daily_days = n(),
    n_daily_max_matched = sum(max_matches),
    .groups = "drop"
  )

rm(
  daily_values, gas_daily_max, ozone_grid, ozone_8hr, ozone_day_validity, ozone_daily_max, daily_check, label_check,
  daily_ozone_days, ozone_day_check, daily_days_not_valid, valid_days_missing_from_daily
)
invisible(gc())



# 13. SUMMARISE EACH MONITOR ----
# One row per monitor: what was measured, how complete it is and how much sits below the detection limit
n_study_hours <- length(study_hours)

hourly_monitor_summary <- hourly %>%
  group_by(pollutant, site_id, local_site_name, site_group, poc) %>%
  summarise(
    method_codes = str_flatten(sort(unique(method_code)), collapse = ", "),
    mdl_ppb_min = min(mdl_ppb),
    mdl_ppb_max = max(mdl_ppb),
    first_date = min(date_local),
    last_date = max(date_local),
    n_hours = n(),
    pct_hours_present = round(100 * n() / n_study_hours, 1),
    pct_below_mdl = round(100 * mean(below_mdl), 1),
    pct_negative = round(100 * mean(value_ppb < 0), 1),
    pct_negative_first_year = round(100 * mean(value_ppb[year(date_local) == min(study_years)] < 0), 1),
    pct_negative_last_year = round(100 * mean(value_ppb[year(date_local) == max(study_years)] < 0), 1),
    n_wildfire_hours = sum(is_wildfire_flagged),
    n_incomplete_days = n_distinct(date_local[!is_complete_day]),
    mean_ppb = round(mean(value_ppb), 3),
    max_ppb = max(value_ppb),
    .groups = "drop"
  )

hourly_monitor_summary <- hourly_monitor_summary %>%
  left_join(monitor_validation, by = c("pollutant", "site_id"), relationship = "one-to-one")

stopifnot(
  "One summary row per case-study monitor" = nrow(hourly_monitor_summary) == nrow(case_study_monitors),
  "No missing values in the monitor summary" = !anyNA(hourly_monitor_summary),
  "The summary counts every hour" = sum(hourly_monitor_summary$n_hours) == nrow(hourly)
)

print(hourly_monitor_summary, n = Inf, width = Inf)



# 14. SAVE CHECKPOINT ----
hourly_case_study <- hourly %>%
  select(
    site_id, local_site_name, site_group, region, pollutant, poc, method_code,
    datetime_local, datetime_utc, date_local, hour_local, day_of_week, is_weekend, season,
    sample_measurement, units_of_measure, mdl, value_ppb, mdl_ppb, value_ugm3,
    below_mdl, qualifier, is_wildfire_flagged, event_name,
    n_hours_day, is_complete_day, n_valid_8hr_means, is_valid_ozone_day, is_post_relocation, is_post_method_change
  ) %>%
  arrange(pollutant, site_id, datetime_local)

final_keys <- hourly_case_study %>%
  count(pollutant, site_id, datetime_local) %>%
  filter(n > 1)

# The two ozone-only columns are NA on NO2 and SO2 rows by design
final_na <- hourly_case_study %>%
  select(-qualifier, -event_name, -n_valid_8hr_means, -is_valid_ozone_day) %>%
  anyNA()

ozone_columns_have_na <- hourly_case_study %>%
  filter(pollutant == "Ozone") %>%
  select(n_valid_8hr_means, is_valid_ozone_day) %>%
  anyNA()

stopifnot(
  "Row total matches the cleaning log" = nrow(hourly_case_study) == last(hourly_cleaning_log$rows),
  "One row per pollutant, site and hour" = nrow(final_keys) == 0,
  "Only qualifier, event_name and the ozone-only columns may be missing" = !final_na,
  "The ozone-only columns are filled on every ozone row" = !ozone_columns_have_na,
  "All 16 case-study monitors are saved" = nrow(distinct(hourly_case_study, pollutant, site_id)) == 16,
  "Data stay inside the study years" = all(year(hourly_case_study$date_local) %in% study_years)
)

# Row counts are stored as whole numbers, like the daily cleaning log
stopifnot(
  "Cleaning log row counts are whole numbers" = all(hourly_cleaning_log$rows == round(hourly_cleaning_log$rows))
)

hourly_cleaning_log <- hourly_cleaning_log %>%
  mutate(rows = as.integer(rows))

hourly_cleaning_log <- hourly_cleaning_log %>%
  mutate(rows_removed = as.integer(rows_removed))

print(hourly_cleaning_log)

# The cleaned hourly table is the checkpoint later phases read, saved as a compressed .rds
hourly_checkpoint <- list(
  hourly_case_study = hourly_case_study
)

# Each file is reloaded and checked against the object in memory (save_checkpoints() in utils.R)
hourly_checkpoint_paths <- save_checkpoints(hourly_checkpoint, processed_dir)

# Records of the run that no later script reads are saved as CSV
hourly_records <- list(
  hourly_cleaning_log = hourly_cleaning_log,
  hourly_validation = hourly_validation,
  hourly_monitor_summary = hourly_monitor_summary
)

save_records(hourly_records, records_dir)

saved_hourly_tables <- c(hourly_checkpoint, hourly_records, list(hourly_raw_row_counts = hourly_row_counts))

hourly_dictionary <- tribble(
  ~table,                   ~column,                   ~description,
  "hourly_case_study",      "site_id",                 "AQS site ID: state-county-site; joins to sites and aqs_long_clean",
  "hourly_case_study",      "local_site_name",         "Site name given by the reporting agency",
  "hourly_case_study",      "site_group",              "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "hourly_case_study",      "region",                  "Houston or Dallas-Fort Worth",
  "hourly_case_study",      "pollutant",               "Ozone, NO2 or SO2",
  "hourly_case_study",      "poc",                     "Parameter occurrence code; one instrument per monitor in this table",
  "hourly_case_study",      "method_code",             "AQS method code; FRM or FEM methods only",
  "hourly_case_study",      "datetime_local",          "Start of the hour in local standard time (fixed UTC-6, no daylight saving)",
  "hourly_case_study",      "datetime_utc",            "Start of the hour in UTC; use it to join data recorded in UTC",
  "hourly_case_study",      "date_local",              "Sample date in local standard time",
  "hourly_case_study",      "hour_local",              "Hour of the day, 0 to 23, in local standard time",
  "hourly_case_study",      "day_of_week",             "Day of the week, ordered Mon to Sun",
  "hourly_case_study",      "is_weekend",              "TRUE on Saturday and Sunday",
  "hourly_case_study",      "season",                  "Meteorological season; winter is Dec to Feb",
  "hourly_case_study",      "sample_measurement",      "Hourly value in original units, as reported by EPA",
  "hourly_case_study",      "units_of_measure",        "Units of the original values: ppm for ozone, ppb for NO2 and SO2",
  "hourly_case_study",      "mdl",                     "Method detection limit in original units",
  "hourly_case_study",      "value_ppb",               "Hourly value in ppb; zeros and negatives kept as reported",
  "hourly_case_study",      "mdl_ppb",                 "Method detection limit in ppb",
  "hourly_case_study",      "value_ugm3",              "Hourly value in µg/m³, converted at 25 °C and 1 atm",
  "hourly_case_study",      "below_mdl",               "TRUE when the reading is below its method detection limit",
  "hourly_case_study",      "qualifier",               "AQS qualifier code; RT is a request to exclude for U.S. wildfire smoke; NA when none",
  "hourly_case_study",      "is_wildfire_flagged",     "TRUE when the hour carries the RT qualifier",
  "hourly_case_study",      "event_name",              "Event from events.csv covering the day; NA when no event applies",
  "hourly_case_study",      "n_hours_day",             "Hours with data for the monitor on that day",
  "hourly_case_study",      "is_complete_day",         "TRUE when the day has at least 18 of 24 hours",
  "hourly_case_study",      "n_valid_8hr_means",       "Ozone only: valid 8-hour means among the 17 that count toward the day; NA for NO2 and SO2",
  "hourly_case_study",      "is_valid_ozone_day",      "Ozone only: TRUE when the day has at least 13 of its 17 8-hour means (40 CFR 50 Appendix U); NA for NO2 and SO2",
  "hourly_case_study",      "is_post_relocation",      "TRUE for Houston Deer Park #2 hours on or after its move on 2025-05-30",
  "hourly_case_study",      "is_post_method_change",   "TRUE for Houston Harvard Street NO2 hours on or after 2024-04-22, when the monitor changed from method 099 to method 186",
  "hourly_cleaning_log",    "step",                    "Import or cleaning step",
  "hourly_cleaning_log",    "rows",                    "Rows remaining after the step",
  "hourly_cleaning_log",    "rows_removed",            "Rows removed by the step",
  "hourly_validation",      "check",                   "Validation check run at the end of 1d_hourly_import_clean.R",
  "hourly_validation",      "observed",                "Value found in the hourly data, as text",
  "hourly_validation",      "expected",                "Value the check requires, as text",
  "hourly_validation",      "passed",                  "TRUE when observed equals expected",
  "hourly_monitor_summary", "pollutant",               "Ozone, NO2 or SO2",
  "hourly_monitor_summary", "site_id",                 "AQS site ID",
  "hourly_monitor_summary", "local_site_name",         "Site name given by the reporting agency",
  "hourly_monitor_summary", "site_group",              "Case-study group",
  "hourly_monitor_summary", "poc",                     "Parameter occurrence code",
  "hourly_monitor_summary", "method_codes",            "AQS method codes used by the monitor during the study",
  "hourly_monitor_summary", "mdl_ppb_min",             "Lowest method detection limit reported, in ppb",
  "hourly_monitor_summary", "mdl_ppb_max",             "Highest method detection limit reported, in ppb",
  "hourly_monitor_summary", "first_date",              "First date with hourly data",
  "hourly_monitor_summary", "last_date",               "Last date with hourly data",
  "hourly_monitor_summary", "n_hours",                 "Hours with data",
  "hourly_monitor_summary", "pct_hours_present",       "Hours with data as a share of all hours in the study window",
  "hourly_monitor_summary", "pct_below_mdl",           "Share of hours below the method detection limit",
  "hourly_monitor_summary", "pct_negative",            "Share of hours with a negative reading",
  "hourly_monitor_summary", "pct_negative_first_year", "Share of negative readings in the first study year",
  "hourly_monitor_summary", "pct_negative_last_year",  "Share of negative readings in the last study year; a rise points to baseline drift",
  "hourly_monitor_summary", "n_wildfire_hours",        "Hours carrying the RT wildfire qualifier",
  "hourly_monitor_summary", "n_incomplete_days",       "Days with fewer than 18 hours of data",
  "hourly_monitor_summary", "mean_ppb",                "Mean of all hourly values, in ppb",
  "hourly_monitor_summary", "max_ppb",                 "Highest hourly value, in ppb",
  "hourly_monitor_summary", "n_daily_days",            "Days the monitor has in the cleaned daily table",
  "hourly_monitor_summary", "n_daily_max_matched",     "Days whose daily maximum was rebuilt exactly from the hourly values",
  "hourly_raw_row_counts",  "file",                    "Hourly zip file in data/raw/hourly",
  "hourly_raw_row_counts",  "parameter_code",          "AQS parameter code: 44201 ozone, 42602 NO2 or 42401 SO2",
  "hourly_raw_row_counts",  "year",                    "Year the file covers",
  "hourly_raw_row_counts",  "raw_rows",                "Data rows in the file, header excluded; equal to the count in EPA's file list"
)

# Stops on a saved column without a description, or a description of a column that was not saved
hourly_dictionary <- document_tables(saved_hourly_tables, hourly_dictionary)

# 1a and 1e add their own rows to both shared files, and only the hourly rows are replaced here
replace_own_rows(hourly_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

# File size and checksum of the checkpoint; GitHub rejects files over 100 MiB
hourly_manifest <- manifest_rows(hourly_checkpoint, hourly_checkpoint_paths)

stopifnot("Every hourly file is under GitHub's 100 MiB limit" = all(hourly_manifest$under_github_limit))

checkpoint_manifest <- replace_own_rows(hourly_manifest, manifest_path, key = "file", col_types = manifest_col_types)

print(checkpoint_manifest, width = Inf)
