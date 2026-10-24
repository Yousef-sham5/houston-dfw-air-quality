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

source(here("R", "utils.R")) # study_years, standard_time_zone, log_step(), region_lookup, hourly zip helpers, calendar, events, save helpers



# CONFIG ----
# The WIND files hold speed and direction, the TEMP files temperature
weather_codes <- tribble(
  ~variable,        ~parameter_code, ~file_type,
  "Wind speed",     61103L,          "WIND",
  "Wind direction", 61104L,          "WIND",
  "Temperature",    62101L,          "TEMP"
)

weather_dir <- here("data", "raw", "weather")

processed_dir <- here("data", "processed")

filtered_dir <- here("data", "weather_filtered")

# 1 knot is 1,852 m per hour
knots_to_ms <- 1852 / 3600

# EPA counts an hour as calm when the wind speed is below 0.5 m/s
calm_threshold_ms <- 0.5

# Spike: an hour more than 20 knots above both the hour before and the hour after
spike_threshold_kt <- 20

sector_width <- 30

# 75% of 24 hours, as in 1d
min_hours_per_day <- 18

# Harvard Street takes its temperature from Bayland Park and its wind from Croquet (section 9)
harvard_street_id <- "48-201-0417"

temp_source_id <- "48-201-0055"

wind_source_id <- "48-201-0051"

# Method code of the Met One AIO2 sonic sensor, which measures wind with ultrasound
sonic_method_code <- "069"



# 1. RAW FILES AND EPA ROW COUNTS ----
# The 10 zips the folder should hold: 2 file types x 5 years
expected_zips <- expand_grid(
  file_type = unique(weather_codes$file_type),
  year = study_years
) %>%
  mutate(file = str_c("hourly_", file_type, "_", year, ".zip"))

zip_paths <- weather_dir %>%
  list.files(pattern = "^hourly_(WIND|TEMP)_\\d{4}\\.zip$", full.names = TRUE)

stopifnot(
  "data/raw/weather holds exactly the 10 expected zips" =
    setequal(basename(zip_paths), expected_zips$file)
)

# Row counts from EPA's AirData file list (file_list.csv, files dated 2026-06-25). Section 3 counts every row
# while it reads each zip and checks the counts against this list
airdata_list_counts <- tribble(
  ~file_type, ~year, ~listed_rows,
  "WIND",     2021,  11807514,
  "WIND",     2022,  11262160,
  "WIND",     2023,  10796347,
  "WIND",     2024,  10795568,
  "WIND",     2025,  10597063,
  "TEMP",     2021,  8403537,
  "TEMP",     2022,  8504899,
  "TEMP",     2023,  8640474,
  "TEMP",     2024,  7792861,
  "TEMP",     2025,  6877016
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
  "All 10 files share one header" = n_distinct(header_strings) == 1,
  "Header matches EPA's 24 documented columns, in order" = identical(first_header, aqs_hourly_columns)
)

# Preview 5 rows as text, to see how values are written before setting column types
header_preview <- zip_paths[1] %>%
  read_first_lines(n = 6) %>%
  I() %>%
  read_csv(col_types = cols(.default = col_character()))

glimpse(header_preview)



# 3. FILTER TO THE CASE-STUDY SITES ----
# The 9 sites picked in 1c, each searched for all three codes
case_study_site_ids <- here("data", "reference", "case_study_sites.csv") %>%
  read_csv(col_types = cols_only(site_id = col_character())) %>%
  distinct(site_id)

weather_monitors <- case_study_site_ids %>%
  cross_join(select(weather_codes, parameter_code))

stopifnot(
  "9 case-study sites" = nrow(case_study_site_ids) == 9,
  "27 site and code pairs to look for" = nrow(weather_monitors) == 27
)

# Each zip is read in chunks and its case-study rows saved to data/weather_filtered (filter_case_study_zip() in
# utils.R). A rerun reuses the saved rows while the zip is unchanged
dir.create(filtered_dir, showWarnings = FALSE)

filtered_paths <- map_chr(zip_paths, \(zip_path) filter_case_study_zip(zip_path, filtered_dir, weather_monitors), .progress = TRUE)

filtered_files <- map(filtered_paths, read_rds)

filter_log <- tibble(
  file = basename(zip_paths),
  rows_read = map_dbl(filtered_files, "rows_read"),
  rows_kept = map_int(filtered_files, \(x) nrow(x$data))
)

print(filter_log, n = Inf)

# Every row in every file must have been read: rows read has to equal EPA's listed count
weather_row_counts <- filter_log %>%
  mutate(
    file_type = str_sub(file, 8, 11),
    year = as.integer(str_sub(file, 13, 16))
  ) %>%
  select(file, file_type, year, raw_rows = rows_read) %>%
  arrange(file_type, year)

row_count_check <- weather_row_counts %>%
  left_join(airdata_list_counts, by = c("file_type", "year"), relationship = "one-to-one") %>%
  mutate(difference = raw_rows - listed_rows)

print(row_count_check, n = Inf, width = Inf)

# A mismatch means a damaged download, or files EPA has since regenerated (check file_list.csv again)
stopifnot(
  "Every file has an EPA listed count" = !anyNA(row_count_check$listed_rows),
  "Rows read match EPA's file list" = all(row_count_check$difference == 0),
  "Every file kept some rows" = all(filter_log$rows_kept > 0)
)

weather_row_counts %>%
  group_by(file_type) %>%
  summarise(raw_rows = sum(raw_rows)) %>%
  print()

print(sum(weather_row_counts$raw_rows))

# Saved as a record of the rows in each raw file
write_csv(weather_row_counts, file.path(processed_dir, "weather_raw_row_counts.csv"))

weather_raw <- filtered_files %>%
  map("data") %>%
  list_rbind() %>%
  clean_names()

rm(filtered_files)
invisible(gc())

print(obj_size(weather_raw))

pairs_found <- weather_raw %>%
  distinct(site_id, parameter_code)

pairs_per_site <- pairs_found %>%
  count(site_id, name = "n_codes")

harvard_street_codes <- pairs_found %>%
  filter(site_id == harvard_street_id) %>%
  pull(parameter_code)

instrument_year_rows <- weather_raw %>%
  count(site_id, parameter_code, poc, year = year(date_local), name = "n_rows") %>%
  mutate(hours_in_year = if_else(leap_year(year), 8784L, 8760L))

stopifnot(
  "Only the 16 chosen columns were read, plus site_id" = ncol(weather_raw) == length(aqs_hourly_col_spec$cols) + 1,
  "All 9 case-study sites are in the weather data" = nrow(pairs_per_site) == 9,
  "Only case-study sites and the three weather codes were kept" =
    nrow(anti_join(pairs_found, weather_monitors, by = c("site_id", "parameter_code"))) == 0,
  "The 8 sites other than Harvard Street report all three codes" =
    all(pairs_per_site$n_codes[pairs_per_site$site_id != harvard_street_id] == 3),
  "Harvard Street reports temperature only" = identical(harvard_street_codes, 62101L),
  "No instrument has more rows in a year than hours" = all(instrument_year_rows$n_rows <= instrument_year_rows$hours_in_year)
)

weather_raw %>%
  count(site_id, parameter_code, poc, name = "n_rows") %>%
  print(n = Inf)

weather_cleaning_log <- tibble(
  step = c("Raw weather files", "Keep case-study sites"),
  rows = c(sum(weather_row_counts$raw_rows), nrow(weather_raw))
) %>%
  mutate(rows_removed = lag(rows) - rows)

print(weather_cleaning_log)



# 4. INSPECT VALUES ----
# Nothing is removed in this section. The counts below decide the rules in section 5
weather_raw <- weather_raw %>%
  left_join(select(weather_codes, variable, parameter_code), by = "parameter_code", relationship = "many-to-one")

stopifnot("Every row has a variable name" = !anyNA(weather_raw$variable))

# Missing values by column, then missing measurements by site and variable
missing_by_column <- weather_raw %>%
  summarise(across(everything(), \(x) sum(is.na(x)))) %>%
  pivot_longer(everything(), names_to = "column", values_to = "n_missing") %>%
  filter(n_missing > 0)

print(missing_by_column)

weather_raw %>%
  group_by(variable, site_id) %>%
  summarise(
    n_rows = n(),
    n_missing_value = sum(is.na(sample_measurement)),
    .groups = "drop"
  ) %>%
  print(n = Inf)

# Share of each year's hours present, by site and variable
weather_raw %>%
  count(site_id, variable, year = year(date_local), name = "n_hours") %>%
  mutate(hours_in_year = if_else(leap_year(year), 8784, 8760)) %>%
  mutate(pct_hours = round(100 * n_hours / hours_in_year, 1)) %>%
  pivot_wider(id_cols = c(site_id, variable), names_from = year, values_from = pct_hours) %>%
  print(n = Inf, width = Inf)

# Units: one per variable
expected_units <- tribble(
  ~variable,        ~expected_unit,
  "Wind speed",     "Knots",
  "Wind direction", "Degrees Compass",
  "Temperature",    "Degrees Fahrenheit"
)

unit_check <- weather_raw %>%
  distinct(variable, units_of_measure) %>%
  left_join(expected_units, by = "variable", relationship = "many-to-one")

print(unit_check)

stopifnot(
  "One unit per variable" = nrow(unit_check) == 3,
  "Units are knots, compass degrees and °F" = all(unit_check$units_of_measure == unit_check$expected_unit)
)

# Time zone: AQS local times skip daylight saving, so Texas is always 6 hours behind GMT (check in utils.R)
check_local_standard_time(weather_raw)

# Method codes against EPA's methods table, for each method's name, units and valid range
methods_ref <- read_methods_ref()

weather_methods <- weather_raw %>%
  count(variable, parameter_code, method_code, units_of_measure, name = "n_rows")

# A blank upper limit means EPA lists none for that method
method_limits <- methods_ref %>%
  semi_join(weather_methods, by = c("parameter_code", "method_code")) %>%
  mutate(
    federal_mdl = as.numeric(federal_mdl),
    min_value = as.numeric(min_value),
    max_value = as.numeric(max_value)
  ) %>%
  mutate(max_value = coalesce(max_value, Inf)) %>%
  group_by(parameter_code, method_code) %>%
  summarise(
    method_name = first(analysis_description),
    method_units = str_flatten(sort(unique(units)), collapse = "; "),
    federal_mdl = first(federal_mdl),
    method_min = min(min_value),
    method_max = max(max_value),
    .groups = "drop"
  )

method_check <- weather_methods %>%
  left_join(method_limits, by = c("parameter_code", "method_code"), relationship = "one-to-one")

print(method_check, n = Inf, width = Inf)

stopifnot(
  "Method codes are 3 characters" = all(str_length(weather_raw$method_code) == 3),
  "Every method code is in EPA's methods table" = !anyNA(method_check$method_name),
  "Method units match the data's units" = all(method_check$method_units == method_check$units_of_measure),
  "Every method has a lower limit" = !anyNA(method_check$method_min)
)

# Dates each site reports under each method. Two methods mean a sensor change (section 12)
method_history <- weather_raw %>%
  group_by(site_id, variable, method_code) %>%
  summarise(
    first_date = min(date_local),
    last_date = max(date_local),
    n_rows = n(),
    .groups = "drop"
  ) %>%
  arrange(site_id, variable, first_date)

print(method_history, n = Inf)

# Range, zeros and the method's limits for each site and variable
range_check <- weather_raw %>%
  left_join(
    select(method_limits, parameter_code, method_code, method_min, method_max),
    by = c("parameter_code", "method_code"),
    relationship = "many-to-one"
  ) %>%
  group_by(variable, site_id, method_code) %>%
  summarise(
    min_value = min(sample_measurement, na.rm = TRUE),
    max_value = max(sample_measurement, na.rm = TRUE),
    method_min = first(method_min),
    method_max = first(method_max),
    n_zero = sum(sample_measurement == 0, na.rm = TRUE),
    n_below_method_min = sum(sample_measurement < method_min, na.rm = TRUE),
    n_above_method_max = sum(sample_measurement > method_max, na.rm = TRUE),
    .groups = "drop"
  )

print(range_check, n = Inf, width = Inf)

# Detection limit (MDL) against the one EPA lists for the method, printed for the record only
weather_raw %>%
  distinct(variable, parameter_code, method_code, mdl) %>%
  left_join(
    select(method_limits, parameter_code, method_code, federal_mdl),
    by = c("parameter_code", "method_code"),
    relationship = "many-to-one"
  ) %>%
  mutate(matches_federal_mdl = abs(mdl - federal_mdl) < 1e-9) %>%
  print(n = Inf)

# Qualifier codes (flags agencies attach to readings), typed with aqs_qualifier_types (utils.R)
qualifier_counts <- weather_raw %>%
  filter(!is.na(qualifier)) %>%
  count(variable, qualifier, name = "n_rows") %>%
  left_join(aqs_qualifier_types, by = "qualifier", relationship = "many-to-one") %>%
  mutate(qualifier_type = replace_na(qualifier_type, "Not in lookup: check EPA table")) %>%
  arrange(variable, desc(n_rows))

print(qualifier_counts, n = Inf, width = Inf)

# Repeated hours for the same instrument (checked again when timestamps are built)
duplicate_hours <- weather_raw %>%
  count(site_id, parameter_code, poc, date_local, time_local) %>%
  filter(n > 1)

print(nrow(duplicate_hours))

# Coordinates over time, printed to 6 decimals. Deer Park #2's move does not show here because EPA lists one pair
site_locations <- weather_raw %>%
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



# 5. CHECK QUALIFIERS, FLAG CALM HOURS AND WIND SPIKES ----
# No rows are removed from here on. Each rule adds a flag, so later phases can keep or leave out these hours
qualifiers_present <- weather_raw %>%
  filter(!is.na(qualifier)) %>%
  distinct(qualifier) %>%
  pull(qualifier)

stopifnot(
  "No qualifier codes are present (any code would need its own rule)" = length(qualifiers_present) == 0,
  "No measurement is missing" = !anyNA(weather_raw$sample_measurement),
  "Every reading lies inside its method's range" =
    sum(range_check$n_below_method_min) == 0 && sum(range_check$n_above_method_max) == 0
)

# Calm: the vane cannot point reliably in very light wind, so later phases leave calm hours out of wind sectors.
# Spike: the next largest one-hour jump at any site is 13.9 knots. An hour beside a missing hour is not checked
wind_flags <- weather_raw %>%
  filter(variable == "Wind speed") %>%
  select(site_id, date_local, time_local, wind_speed_kt = sample_measurement) %>%
  mutate(is_calm = wind_speed_kt * knots_to_ms < calm_threshold_ms)

stopifnot(
  "One wind speed per site and hour" = !anyDuplicated(wind_flags[c("site_id", "date_local", "time_local")]),
  "At 0.1-knot resolution, the EPA rule flags the same hours as a 1-knot rule" =
    identical(wind_flags$is_calm, wind_flags$wind_speed_kt < 1)
)

wind_flags <- wind_flags %>%
  mutate(hour_start = ymd_hm(str_c(date_local, " ", time_local), tz = standard_time_zone)) %>%
  arrange(site_id, hour_start) %>%
  group_by(site_id) %>%
  mutate(previous_kt = if_else(lag(hour_start) == hour_start - hours(1), lag(wind_speed_kt), NA_real_)) %>%
  mutate(next_kt = if_else(lead(hour_start) == hour_start + hours(1), lead(wind_speed_kt), NA_real_)) %>%
  ungroup()

wind_flags <- wind_flags %>%
  mutate(jump_from_previous_kt = wind_speed_kt - previous_kt) %>%
  mutate(jump_to_next_kt = wind_speed_kt - next_kt) %>%
  mutate(is_wind_spike = jump_from_previous_kt > spike_threshold_kt & jump_to_next_kt > spike_threshold_kt) %>%
  mutate(is_wind_spike = coalesce(is_wind_spike, FALSE))

wind_flags %>%
  filter(is_wind_spike) %>%
  select(site_id, date_local, time_local, previous_kt, wind_speed_kt, next_kt) %>%
  print()

weather <- weather_raw %>%
  left_join(
    select(wind_flags, site_id, date_local, time_local, is_calm, is_wind_spike),
    by = c("site_id", "date_local", "time_local"),
    relationship = "many-to-one"
  )

# Wind flags stay NA on temperature rows
weather <- weather %>%
  mutate(is_calm = if_else(variable == "Temperature", NA, is_calm)) %>%
  mutate(is_wind_spike = if_else(variable == "Temperature", NA, is_wind_spike))

stopifnot(
  "The join added no rows" = nrow(weather) == nrow(weather_raw),
  "Every wind speed and direction row has a calm flag" =
    !anyNA(weather$is_calm[weather$variable != "Temperature"]),
  "Every wind speed and direction row has a spike flag" =
    !anyNA(weather$is_wind_spike[weather$variable != "Temperature"])
)

weather_cleaning_log <- weather_cleaning_log %>%
  log_step("Flag calm hours, none removed", weather)

weather_cleaning_log <- weather_cleaning_log %>%
  log_step("Flag one-hour wind spikes, none removed", weather)

weather %>%
  filter(variable == "Wind speed") %>%
  group_by(site_id) %>%
  summarise(
    n_hours = n(),
    n_calm = sum(is_calm),
    pct_calm = round(100 * n_calm / n_hours, 1),
    n_wind_spikes = sum(is_wind_spike),
    .groups = "drop"
  ) %>%
  print(n = Inf)

rm(wind_flags)



# 6. BUILD TIMESTAMPS AND CALENDAR COLUMNS ----
# Built as in 1d at the fixed UTC-6 of standard_time_zone (utils.R), so weather and pollutant hours line up
weather <- weather %>%
  mutate(datetime_local = ymd_hm(str_c(date_local, " ", time_local), tz = standard_time_zone))

# The UTC timestamp matches each weather hour to hourly_case_study.rds
weather <- weather %>%
  mutate(datetime_utc = ymd_hm(str_c(date_gmt, " ", time_gmt), tz = "UTC"))

weather <- weather %>%
  mutate(hour_local = hour(datetime_local))

duplicate_timestamps <- weather %>%
  count(variable, site_id, poc, datetime_local) %>%
  filter(n > 1)

stopifnot(
  "Every timestamp parses" = !anyNA(weather$datetime_local) && !anyNA(weather$datetime_utc),
  "Local standard time and UTC name the same instant" = all(weather$datetime_local == weather$datetime_utc),
  "Each timestamp falls on its local date" = all(as_date(weather$datetime_local) == weather$date_local),
  "Hours run from 0 to 23" = all(weather$hour_local %in% 0:23),
  "One row per site, variable and hour" = nrow(duplicate_timestamps) == 0
)

# Same calendar columns as 1a and 1d (utils.R)
weather <- weather %>%
  add_calendar_columns()



# 7. CONVERT UNITS ----
# Direction stays in degrees. The original values are kept beside the converted ones, as in 1d
fahrenheit_to_celsius <- function(temp_f) {
  (temp_f - 32) * 5 / 9
}

stopifnot(
  "Fahrenheit to Celsius matches fixed points (32 °F = 0 °C, 212 °F = 100 °C, -40 °F = -40 °C)" =
    isTRUE(all.equal(fahrenheit_to_celsius(c(32, 212, -40)), c(0, 100, -40))),
  "1 knot is 0.514444 m/s" = isTRUE(all.equal(knots_to_ms, 0.514444, tolerance = 1e-6))
)

weather <- weather %>%
  mutate(
    value_metric = case_when(
      variable == "Temperature" ~ fahrenheit_to_celsius(sample_measurement),
      variable == "Wind speed" ~ sample_measurement * knots_to_ms,
      variable == "Wind direction" ~ sample_measurement
    )
  )

stopifnot("Every row has a converted value" = !anyNA(weather$value_metric))

weather %>%
  group_by(variable) %>%
  summarise(
    original_unit = first(units_of_measure),
    min_original = min(sample_measurement),
    max_original = max(sample_measurement),
    min_converted = round(min(value_metric), 2),
    max_converted = round(max(value_metric), 2)
  ) %>%
  print()



# 8. RESHAPE TO ONE ROW PER SITE AND HOUR ----
# An hour missing a variable keeps NA for it, so no reading is dropped
hour_keys <- c("site_id", "datetime_local")

calendar_hours <- weather %>%
  distinct(site_id, datetime_local, datetime_utc, date_local, hour_local, day_of_week, is_weekend, season)

wind_speed_hours <- weather %>%
  filter(variable == "Wind speed") %>%
  select(
    all_of(hour_keys),
    wind_speed_kt = sample_measurement,
    wind_speed_ms = value_metric,
    wind_method_code = method_code,
    is_calm,
    is_wind_spike
  )

wind_direction_hours <- weather %>%
  filter(variable == "Wind direction") %>%
  select(all_of(hour_keys), wind_dir_deg = sample_measurement, direction_method_code = method_code)

temperature_hours <- weather %>%
  filter(variable == "Temperature") %>%
  select(all_of(hour_keys), temp_f = sample_measurement, temp_c = value_metric, temp_method_code = method_code)

weather_hourly <- calendar_hours %>%
  left_join(wind_speed_hours, by = hour_keys, relationship = "one-to-one") %>%
  left_join(wind_direction_hours, by = hour_keys, relationship = "one-to-one") %>%
  left_join(temperature_hours, by = hour_keys, relationship = "one-to-one")

readings_per_variable <- weather %>%
  count(variable)

readings_before <- set_names(readings_per_variable$n, readings_per_variable$variable)

readings_after <- c(
  "Wind speed" = sum(!is.na(weather_hourly$wind_speed_kt)),
  "Wind direction" = sum(!is.na(weather_hourly$wind_dir_deg)),
  "Temperature" = sum(!is.na(weather_hourly$temp_f))
)

stopifnot(
  "One row per site and hour" = !anyDuplicated(weather_hourly[hour_keys]),
  "Every reading of every variable is kept" = identical(readings_after[names(readings_before)], readings_before),
  "Speed and direction always arrive together" =
    all(is.na(weather_hourly$wind_speed_kt) == is.na(weather_hourly$wind_dir_deg)),
  "Speed and direction share one method in every hour" =
    all(weather_hourly$wind_method_code == weather_hourly$direction_method_code, na.rm = TRUE)
)

weather_hourly <- weather_hourly %>%
  select(-direction_method_code)

# Wind direction is the direction the wind blows from, in degrees clockwise from true north (EPA-454/R-99-005,
# section 2.2). Sectors are named by their centre, so sector 0 runs from 345° to 15° and holds 0° and 360°
weather_hourly <- weather_hourly %>%
  mutate(wind_sector = floor(((wind_dir_deg + sector_width / 2) %% 360) / sector_width) * sector_width)

# The wind split into east-west (u) and north-south (v) parts in m/s. Averaging the parts gives a correct mean
# direction near north, where 350° and 10° would average to 180° (EPA-454/R-99-005, section 6.2.2)
weather_hourly <- weather_hourly %>%
  mutate(wind_u_ms = -wind_speed_ms * sin(wind_dir_deg * pi / 180)) %>%
  mutate(wind_v_ms = -wind_speed_ms * cos(wind_dir_deg * pi / 180))

unit_vector_check <- tibble(speed = c(1, 1), direction = c(90, 0)) %>%
  mutate(u = -speed * sin(direction * pi / 180)) %>%
  mutate(v = -speed * cos(direction * pi / 180))

sectors_found <- na.omit(unique(weather_hourly$wind_sector))

stopifnot(
  "Sectors are the 12 centre angles 0 to 330" = setequal(sectors_found, seq(0, 330, by = sector_width)),
  "Every wind hour has a sector and both components" =
    all(is.na(weather_hourly$wind_dir_deg) == is.na(weather_hourly$wind_sector)) &&
    all(is.na(weather_hourly$wind_dir_deg) == is.na(weather_hourly$wind_u_ms)),
  "A wind from the east gives u = -1, v = 0" =
    isTRUE(all.equal(c(unit_vector_check$u[1], unit_vector_check$v[1]), c(-1, 0))),
  "A wind from the north gives u = 0, v = -1" =
    isTRUE(all.equal(c(unit_vector_check$u[2], unit_vector_check$v[2]), c(0, -1)))
)

# Reshaping combines rows, so the step has no removal count
weather_cleaning_log <- weather_cleaning_log %>%
  add_row(
    step = "Reshape to one row per site and hour, no reading removed",
    rows = nrow(weather_hourly),
    rows_removed = NA
  )

weather_hourly %>%
  group_by(site_id) %>%
  summarise(
    n_hours = n(),
    n_wind_hours = sum(!is.na(wind_speed_kt)),
    n_temp_hours = sum(!is.na(temp_f)),
    .groups = "drop"
  ) %>%
  print(n = Inf)

weather_hourly %>%
  filter(!is.na(wind_sector), !is_calm) %>%
  count(wind_sector, name = "n_hours") %>%
  mutate(pct_hours = round(100 * n_hours / sum(n_hours), 1)) %>%
  print(n = Inf)

rm(calendar_hours, wind_speed_hours, wind_direction_hours, temperature_hours, unit_vector_check)



# 9. FILL HOUSTON HARVARD STREET FROM ITS NEIGHBOURS ----
# Harvard Street has no wind sensor and its own temperature starts on 2023-04-19. All five years take temperature
# from Bayland Park (about 13 km) and wind from Croquet (about 18 km). own_temp_f and own_temp_c keep its own sensor
harvard_own_rows <- weather_hourly %>%
  filter(site_id == harvard_street_id)

stopifnot(
  "Harvard Street has no wind readings of its own" = all(is.na(harvard_own_rows$wind_speed_kt)),
  "Harvard Street's own temperature starts on 2023-04-19" =
    min(harvard_own_rows$date_local) == ymd("2023-04-19")
)

# The other 8 sites use their own sensors
own_site_rows <- weather_hourly %>%
  filter(site_id != harvard_street_id) %>%
  mutate(own_temp_f = temp_f) %>%
  mutate(own_temp_c = temp_c) %>%
  mutate(temp_source_site = if_else(is.na(temp_f), NA_character_, site_id)) %>%
  mutate(wind_source_site = if_else(is.na(wind_speed_kt), NA_character_, site_id))

calendar_columns <- c(
  "datetime_local", "datetime_utc", "date_local", "hour_local", "day_of_week", "is_weekend", "season"
)

temp_columns <- c("temp_f", "temp_c", "temp_method_code")

wind_columns <- c(
  "wind_speed_kt", "wind_speed_ms", "wind_method_code", "is_calm", "is_wind_spike",
  "wind_dir_deg", "wind_sector", "wind_u_ms", "wind_v_ms"
)

temp_from_source <- weather_hourly %>%
  filter(site_id == temp_source_id, !is.na(temp_f)) %>%
  select(all_of(calendar_columns), all_of(temp_columns))

wind_from_source <- weather_hourly %>%
  filter(site_id == wind_source_id, !is.na(wind_speed_kt)) %>%
  select(all_of(calendar_columns), all_of(wind_columns))

harvard_own_temp <- harvard_own_rows %>%
  select(all_of(calendar_columns), own_temp_f = temp_f, own_temp_c = temp_c)

# Harvard Street gets an hour wherever either source or its own sensor has a reading
harvard_hours <- bind_rows(
  select(temp_from_source, all_of(calendar_columns)),
  select(wind_from_source, all_of(calendar_columns)),
  select(harvard_own_temp, all_of(calendar_columns))
) %>%
  distinct()

harvard_filled <- harvard_hours %>%
  mutate(site_id = harvard_street_id) %>%
  left_join(
    select(temp_from_source, datetime_local, all_of(temp_columns)),
    by = "datetime_local",
    relationship = "one-to-one"
  ) %>%
  left_join(
    select(wind_from_source, datetime_local, all_of(wind_columns)),
    by = "datetime_local",
    relationship = "one-to-one"
  ) %>%
  left_join(
    select(harvard_own_temp, datetime_local, own_temp_f, own_temp_c),
    by = "datetime_local",
    relationship = "one-to-one"
  ) %>%
  mutate(temp_source_site = if_else(is.na(temp_f), NA_character_, temp_source_id)) %>%
  mutate(wind_source_site = if_else(is.na(wind_speed_kt), NA_character_, wind_source_id))

weather_hourly <- bind_rows(own_site_rows, harvard_filled) %>%
  arrange(site_id, datetime_local)

harvard_check <- weather_hourly %>%
  filter(site_id == harvard_street_id) %>%
  left_join(
    select(temp_from_source, datetime_local, source_temp_f = temp_f),
    by = "datetime_local",
    relationship = "one-to-one"
  ) %>%
  left_join(
    select(wind_from_source, datetime_local, source_speed_kt = wind_speed_kt, source_dir_deg = wind_dir_deg),
    by = "datetime_local",
    relationship = "one-to-one"
  )

stopifnot(
  "One row per site and hour" = !anyDuplicated(weather_hourly[hour_keys]),
  "The 8 other sites are unchanged" = nrow(own_site_rows) == sum(weather_hourly$site_id != harvard_street_id),
  "Harvard Street temperature equals Bayland Park in every hour" =
    identical(harvard_check$temp_f, harvard_check$source_temp_f),
  "Harvard Street wind equals Croquet in every hour" =
    identical(harvard_check$wind_speed_kt, harvard_check$source_speed_kt) &&
    identical(harvard_check$wind_dir_deg, harvard_check$source_dir_deg),
  "Every Harvard Street reading of its own is kept" =
    sum(!is.na(harvard_check$own_temp_f)) == nrow(harvard_own_rows),
  "Own temperature equals temperature at the 8 other sites" =
    identical(own_site_rows$own_temp_f, own_site_rows$temp_f),
  "The 8 other sites are their own source" =
    all(coalesce(own_site_rows$temp_source_site, own_site_rows$site_id) == own_site_rows$site_id) &&
    all(coalesce(own_site_rows$wind_source_site, own_site_rows$site_id) == own_site_rows$site_id),
  "Harvard Street's sources are Bayland Park (temperature) and Croquet (wind)" =
    all(harvard_check$temp_source_site %in% c(temp_source_id, NA)) &&
    all(harvard_check$wind_source_site %in% c(wind_source_id, NA))
)

# Bayland Park against Harvard Street's own sensor, from 2023-04-19
harvard_temp_comparison <- harvard_check %>%
  filter(!is.na(temp_f), !is.na(own_temp_f)) %>%
  summarise(
    paired_hours = n(),
    mean_gap_f = round(mean(temp_f - own_temp_f), 2),
    mean_abs_gap_f = round(mean(abs(temp_f - own_temp_f)), 2),
    pct_within_2f = round(100 * mean(abs(temp_f - own_temp_f) <= 2), 1),
    correlation = round(cor(temp_f, own_temp_f), 4)
  )

print(harvard_temp_comparison)

stopifnot(
  "Bayland Park temperature tracks Harvard Street's own sensor (r above 0.95)" =
    harvard_temp_comparison$correlation > 0.95
)

# Filling adds rows, so the step has no removal count
weather_cleaning_log <- weather_cleaning_log %>%
  add_row(
    step = "Fill Harvard Street from Bayland Park and Croquet, rows added",
    rows = nrow(weather_hourly),
    rows_removed = NA
  )

weather_hourly %>%
  filter(site_id == harvard_street_id) %>%
  summarise(
    n_hours = n(),
    n_temp_hours = sum(!is.na(temp_f)),
    n_wind_hours = sum(!is.na(wind_speed_kt)),
    n_own_temp_hours = sum(!is.na(own_temp_f)),
    first_date = min(date_local),
    last_date = max(date_local)
  ) %>%
  print(width = Inf)

print(weather_cleaning_log)

rm(
  harvard_own_rows, own_site_rows, temp_from_source, wind_from_source,
  harvard_own_temp, harvard_hours, harvard_filled, harvard_check
)



# 10. ADD SITE GROUP, REGION AND EVENT LABELS ----
site_groups <- here("data", "reference", "case_study_sites.csv") %>%
  read_csv(col_types = cols_only(
    site_id         = col_character(),
    site_group      = col_character(),
    local_site_name = col_character()
  )) %>%
  distinct()

stopifnot("One group and one name per case-study site" = nrow(site_groups) == 9 && !anyDuplicated(site_groups$site_id))

weather_hourly <- weather_hourly %>%
  left_join(site_groups, by = "site_id", relationship = "many-to-one")

weather_hourly <- weather_hourly %>%
  mutate(county_id = str_sub(site_id, 1, 6))

weather_hourly <- weather_hourly %>%
  left_join(region_lookup, by = "county_id", relationship = "many-to-one")

weather_hourly <- weather_hourly %>%
  select(-county_id)

stopifnot(
  "Every row has a site group, a site name and a region" =
    !anyNA(weather_hourly$site_group) && !anyNA(weather_hourly$local_site_name) && !anyNA(weather_hourly$region),
  "Three site groups" = n_distinct(weather_hourly$site_group) == 3
)

# Hourly pollutants measured at the case-study sites in 1d
hourly_pollutants <- here("data", "reference", "case_study_sites.csv") %>%
  read_csv(col_types = cols_only(pollutant = col_character())) %>%
  distinct(pollutant) %>%
  pull(pollutant)

stopifnot("Hourly pollutants found" = length(hourly_pollutants) > 0 && !anyNA(hourly_pollutants))

# Events as in 1a and 1d (read_events() in utils.R), kept when they list "all" or an hourly pollutant
events <- read_events()

event_windows <- events %>%
  split_event_pollutants()

hourly_events <- event_windows %>%
  filter(event_pollutant == "all" | event_pollutant %in% hourly_pollutants) %>%
  distinct(event_name, start_date, end_date, state_code, event_county)

dropped_windows <- event_windows %>%
  anti_join(hourly_events, by = c("event_name", "start_date", "end_date", "state_code", "event_county"))

stopifnot(
  "Every kept event row is in events.csv" = all(hourly_events$event_name %in% events$event_name),
  "No dropped event row lists all or an hourly pollutant" =
    !any(dropped_windows$event_pollutant == "all" | dropped_windows$event_pollutant %in% hourly_pollutants)
)

site_days <- weather_hourly %>%
  distinct(site_id, date_local) %>%
  mutate(state_code = str_sub(site_id, 1, 2)) %>%
  mutate(county_code = str_sub(site_id, 4, 6))

event_matches <- site_days %>%
  inner_join(hourly_events, by = join_by(state_code, between(date_local, start_date, end_date))) %>%
  filter(is.na(event_county) | county_code == event_county) %>%
  distinct(site_id, date_local, event_name)

multi_event_days <- event_matches %>%
  count(site_id, date_local) %>%
  filter(n > 1)

stopifnot("No site-day falls in two events" = nrow(multi_event_days) == 0)

weather_hourly <- weather_hourly %>%
  left_join(event_matches, by = c("site_id", "date_local"), relationship = "many-to-one")

weather_hourly %>%
  filter(!is.na(event_name)) %>%
  distinct(event_name, site_id, date_local) %>%
  count(event_name, name = "site_days") %>%
  print()

rm(site_days, event_windows, dropped_windows)



# 11. FLAG COMPLETE DAYS ----
# A day is complete with 18 of 24 hours, as in 1d, counted separately for temperature and wind
weather_hourly <- weather_hourly %>%
  add_count(site_id, date_local, wt = !is.na(temp_f), name = "n_temp_hours_day")

weather_hourly <- weather_hourly %>%
  add_count(site_id, date_local, wt = !is.na(wind_speed_kt), name = "n_wind_hours_day")

weather_hourly <- weather_hourly %>%
  mutate(is_complete_temp_day = n_temp_hours_day >= min_hours_per_day)

weather_hourly <- weather_hourly %>%
  mutate(is_complete_wind_day = n_wind_hours_day >= min_hours_per_day)

stopifnot(
  "No day has more than 24 hours of temperature" = all(weather_hourly$n_temp_hours_day <= 24),
  "No day has more than 24 hours of wind" = all(weather_hourly$n_wind_hours_day <= 24)
)

weather_cleaning_log <- weather_cleaning_log %>%
  log_step("Flag days with fewer than 18 hours of temperature or wind, none removed", weather_hourly)

weather_hourly %>%
  distinct(site_id, date_local, is_complete_temp_day, is_complete_wind_day) %>%
  group_by(site_id) %>%
  summarise(
    site_days = n(),
    complete_temp_days = sum(is_complete_temp_day),
    complete_wind_days = sum(is_complete_wind_day),
    .groups = "drop"
  ) %>%
  print(n = Inf)



# 12. CHECK THE SWITCH TO SONIC SENSORS ----
# Five sites replaced their older sensors with the sonic sensor in 2022-2024, which may change the share of calm hours.
# Each is compared with a nearby site that kept its old sensor, over 365 days either side. Nothing is adjusted
weather_hourly <- weather_hourly %>%
  mutate(is_sonic_temp = temp_method_code == sonic_method_code) %>%
  mutate(is_sonic_wind = wind_method_code == sonic_method_code)

weather_cleaning_log <- weather_cleaning_log %>%
  log_step("Flag hours measured by a sonic sensor, none removed", weather_hourly)

# Wind speed stands for both wind columns, which share one method (section 8)
sensor_periods <- method_history %>%
  filter(variable != "Wind direction") %>%
  mutate(sensor = if_else(variable == "Wind speed", "Wind", "Temperature")) %>%
  mutate(is_sonic = method_code == sonic_method_code)

sensor_switches <- sensor_periods %>%
  group_by(site_id, sensor) %>%
  summarise(
    n_old_methods = sum(!is_sonic),
    n_sonic_methods = sum(is_sonic),
    old_method_code = method_code[!is_sonic][1],
    last_old_date = last_date[!is_sonic][1],
    first_sonic_date = first_date[is_sonic][1],
    hours_old = sum(n_rows[!is_sonic]),
    hours_sonic = sum(n_rows[is_sonic]),
    .groups = "drop"
  )

stopifnot(
  "Each sensor has at most one older method and one sonic method" =
    all(sensor_switches$n_old_methods <= 1) && all(sensor_switches$n_sonic_methods <= 1),
  "A sonic sensor always starts after the older one stops" =
    all(sensor_switches$first_sonic_date > sensor_switches$last_old_date, na.rm = TRUE)
)

# One row per site and sensor
sensor_check <- expand_grid(site_id = site_groups$site_id, sensor = c("Temperature", "Wind")) %>%
  left_join(sensor_switches, by = c("site_id", "sensor"), relationship = "one-to-one") %>%
  mutate(
    sensor_history = case_when(
      n_old_methods == 1 & n_sonic_methods == 1 ~ "Switched to sonic",
      n_old_methods == 1 ~ "Older sensor throughout",
      n_sonic_methods == 1 ~ "Sonic only",
      .default = "No sensor"
    )
  ) %>%
  mutate(days_without_data = as.integer(first_sonic_date - last_old_date) - 1L) %>%
  mutate(hours_old = coalesce(hours_old, 0L)) %>%
  mutate(hours_sonic = coalesce(hours_sonic, 0L))

# Neighbours for the switched sites: the nearest case-study site in the same region that kept one sensor
sensor_neighbours <- tribble(
  ~site_id,      ~neighbour_id,
  "48-201-0055", "48-201-0051",
  "48-201-1034", "48-201-0416",
  "48-201-1035", "48-201-0416",
  "48-201-1039", "48-201-0416",
  "48-439-3009", "48-113-0087"
)

switched_sites <- sensor_check %>%
  filter(sensor_history == "Switched to sonic") %>%
  distinct(site_id)

neighbour_histories <- sensor_check %>%
  semi_join(sensor_neighbours, by = c("site_id" = "neighbour_id"))

stopifnot(
  "Every switched site has a neighbour" = setequal(switched_sites$site_id, sensor_neighbours$site_id),
  "Every neighbour kept its older sensors for all five years" =
    all(neighbour_histories$sensor_history == "Older sensor throughout")
)

# Only each site's own sensor readings, so Harvard Street's borrowed wind is left out
own_sensor_hours <- bind_rows(
  weather_hourly %>%
    filter(!is.na(own_temp_f)) %>%
    transmute(site_id, sensor = "Temperature", datetime_local, value = own_temp_f, is_calm = NA),
  weather_hourly %>%
    filter(!is.na(wind_speed_kt), wind_source_site == site_id) %>%
    transmute(site_id, sensor = "Wind", datetime_local, value = wind_speed_kt, is_calm)
)

switch_windows <- sensor_check %>%
  filter(sensor_history == "Switched to sonic") %>%
  inner_join(sensor_neighbours, by = "site_id", relationship = "many-to-one") %>%
  select(site_id, sensor, neighbour_id, last_old_date, first_sonic_date)

switch_pairs <- switch_windows %>%
  inner_join(
    rename(own_sensor_hours, site_value = value, site_calm = is_calm),
    by = c("site_id", "sensor"),
    relationship = "one-to-many"
  ) %>%
  mutate(date_local = as_date(datetime_local)) %>%
  mutate(
    period = case_when(
      date_local > last_old_date - 365 & date_local <= last_old_date ~ "before",
      date_local >= first_sonic_date & date_local < first_sonic_date + 365 ~ "after"
    )
  ) %>%
  filter(!is.na(period)) %>%
  inner_join(
    rename(own_sensor_hours, neighbour_id = site_id, neighbour_value = value, neighbour_calm = is_calm),
    by = c("neighbour_id", "sensor", "datetime_local"),
    relationship = "many-to-one"
  )

switch_comparison <- switch_pairs %>%
  group_by(site_id, sensor, period) %>%
  summarise(
    paired_hours = n(),
    mean_diff = round(mean(site_value - neighbour_value), 2),
    pct_calm_site = round(100 * mean(site_calm), 1),
    pct_calm_neighbour = round(100 * mean(neighbour_calm), 1),
    .groups = "drop"
  ) %>%
  pivot_wider(names_from = period, values_from = c(paired_hours, mean_diff, pct_calm_site, pct_calm_neighbour)) %>%
  mutate(diff_change = round(mean_diff_after - mean_diff_before, 2))

stopifnot(
  "Every switch has paired hours before and after" =
    nrow(switch_comparison) == nrow(switch_windows) &&
    all(switch_comparison$paired_hours_before > 0) && all(switch_comparison$paired_hours_after > 0)
)

weather_sensor_check <- sensor_check %>%
  left_join(select(site_groups, site_id, local_site_name), by = "site_id", relationship = "many-to-one") %>%
  left_join(sensor_neighbours, by = "site_id", relationship = "many-to-one") %>%
  left_join(switch_comparison, by = c("site_id", "sensor"), relationship = "one-to-one") %>%
  mutate(neighbour_id = if_else(sensor_history == "Switched to sonic", neighbour_id, NA_character_)) %>%
  mutate(diff_unit = case_when(is.na(neighbour_id) ~ NA_character_, sensor == "Wind" ~ "knots", .default = "°F")) %>%
  select(
    site_id, local_site_name, sensor, sensor_history, old_method_code, last_old_date, first_sonic_date,
    days_without_data, hours_old, hours_sonic, neighbour_id, diff_unit,
    paired_hours_before, paired_hours_after, mean_diff_before, mean_diff_after, diff_change,
    pct_calm_site_before, pct_calm_site_after, pct_calm_neighbour_before, pct_calm_neighbour_after
  ) %>%
  arrange(site_id, sensor)

stopifnot("One sensor-check row per site and sensor (9 x 2)" = nrow(weather_sensor_check) == 18)

print(weather_sensor_check, n = Inf, width = Inf)

rm(sensor_periods, sensor_switches, own_sensor_hours, switch_windows, switch_pairs, neighbour_histories)



# 13. VALIDATE ----
duplicate_site_hours <- weather_hourly %>%
  count(site_id, datetime_local) %>%
  filter(n > 1)

# Summer should be warmer than winter at every site
season_check <- weather_hourly %>%
  filter(!is.na(temp_f)) %>%
  group_by(site_id, season) %>%
  summarise(mean_temp_f = mean(temp_f), .groups = "drop") %>%
  pivot_wider(names_from = season, values_from = mean_temp_f) %>%
  mutate(summer_warmer = Summer > Winter)

print(season_check)

# Harvard Street against its sources, hour by hour, and every source reading used
harvard_source_check <- weather_hourly %>%
  filter(site_id == harvard_street_id) %>%
  left_join(
    weather_hourly %>%
      filter(site_id == temp_source_id) %>%
      select(datetime_local, source_temp_f = temp_f),
    by = "datetime_local",
    relationship = "one-to-one"
  ) %>%
  left_join(
    weather_hourly %>%
      filter(site_id == wind_source_id) %>%
      select(datetime_local, source_speed_kt = wind_speed_kt, source_dir_deg = wind_dir_deg),
    by = "datetime_local",
    relationship = "one-to-one"
  )

differs <- function(x, y) {
  coalesce(x != y, xor(is.na(x), is.na(y)))
}

harvard_temp_differences <- sum(differs(harvard_source_check$temp_f, harvard_source_check$source_temp_f))

harvard_wind_differences <- sum(
  differs(harvard_source_check$wind_speed_kt, harvard_source_check$source_speed_kt) |
    differs(harvard_source_check$wind_dir_deg, harvard_source_check$source_dir_deg)
)

source_temp_readings <- sum(!is.na(weather_hourly$temp_f[weather_hourly$site_id == temp_source_id]))

source_wind_readings <- sum(!is.na(weather_hourly$wind_speed_kt[weather_hourly$site_id == wind_source_id]))

harvard_temp_readings <- sum(!is.na(harvard_source_check$temp_f))

harvard_wind_readings <- sum(!is.na(harvard_source_check$wind_speed_kt))

source_readings_unused <- (source_temp_readings - harvard_temp_readings) + (source_wind_readings - harvard_wind_readings)

own_temp_differences <- weather_hourly %>%
  filter(site_id != harvard_street_id) %>%
  summarise(n = sum(differs(own_temp_f, temp_f))) %>%
  pull(n)

# Join to the hourly pollutant table on site and UTC hour, as later phases will
pollutant_hours <- read_rds(file.path(processed_dir, "hourly_case_study.rds")) %>%
  select(site_id, pollutant, datetime_utc, datetime_local)

weather_match <- pollutant_hours %>%
  left_join(
    select(weather_hourly, site_id, datetime_utc, weather_local = datetime_local, temp_f, wind_speed_kt),
    by = c("site_id", "datetime_utc"),
    relationship = "many-to-one"
  )

join_coverage <- weather_match %>%
  group_by(site_id, pollutant) %>%
  summarise(
    pollutant_hours = n(),
    pct_with_temp = round(100 * mean(!is.na(temp_f)), 1),
    pct_with_wind = round(100 * mean(!is.na(wind_speed_kt)), 1),
    .groups = "drop"
  )

print(join_coverage, n = Inf)

rows_read <- sum(filter_log$rows_read)

# The raw row counts are EPA's listed counts, which section 3 checked file by file
raw_rows <- sum(airdata_list_counts$listed_rows)

sites_in_table <- n_distinct(weather_hourly$site_id)

timestamp_differences <- sum(weather_hourly$datetime_local != weather_hourly$datetime_utc)

readings_out_of_range <- sum(range_check$n_below_method_min + range_check$n_above_method_max)

wind_parts_missing <- weather_hourly %>%
  filter(!is.na(wind_dir_deg)) %>%
  summarise(n = sum(is.na(wind_sector) | is.na(wind_u_ms) | is.na(wind_v_ms))) %>%
  pull(n)

calm_rule_differences <- sum(weather_hourly$is_calm != (weather_hourly$wind_speed_kt < 1), na.rm = TRUE)

sites_not_warmer_in_summer <- sum(!season_check$summer_warmer)

pollutant_sites_missing <- sum(!pollutant_hours$site_id %in% weather_hourly$site_id)

local_time_differences <- sum(weather_match$datetime_local != weather_match$weather_local, na.rm = TRUE)

weather_validation <- tribble(
  ~check,                                                               ~observed,                  ~expected,
  "Rows read from the 10 zips against their raw row counts",            rows_read,                  raw_rows,
  "Case-study sites in the table",                                      sites_in_table,             9,
  "Duplicate site-hours",                                               nrow(duplicate_site_hours), 0,
  "Timestamps that differ from EPA's GMT time",                         timestamp_differences,      0,
  "Readings outside their method's range",                              readings_out_of_range,      0,
  "Wind hours without a sector or u and v components",                  wind_parts_missing,         0,
  "Calm flags that differ from the 1-knot rule",                        calm_rule_differences,      0,
  "Harvard Street hours whose temperature differs from Bayland Park",   harvard_temp_differences,   0,
  "Harvard Street hours whose wind differs from Croquet",               harvard_wind_differences,   0,
  "Source readings not used for Harvard Street",                        source_readings_unused,     0,
  "Own temperatures that differ from temperature at the 8 other sites", own_temp_differences,       0,
  "Sites where summer is not warmer than winter",                       sites_not_warmer_in_summer, 0,
  "Pollutant hours at sites missing from the weather table",            pollutant_sites_missing,    0,
  "Matched hours whose local times disagree",                           local_time_differences,     0
) %>%
  mutate(observed = as.character(observed)) %>%
  mutate(expected = as.character(expected)) %>%
  mutate(passed = observed == expected)

print(weather_validation, n = Inf, width = Inf)

stopifnot("Every weather validation check passed" = all(weather_validation$passed))

rm(harvard_source_check, pollutant_hours, weather_match)
invisible(gc())



# 14. SUMMARISE EACH SITE ----
# One row per site: weather sources, completeness, longest gaps, sensors, calms and prevailing wind
study_start <- make_datetime(min(study_years), 1, 1, 0, tz = standard_time_zone)

study_end <- make_datetime(max(study_years), 12, 31, 23, tz = standard_time_zone)

n_study_hours <- as.numeric(difftime(study_end, study_start, units = "hours")) + 1

stopifnot("The study window holds 43,824 hours" = n_study_hours == 43824)

# Longest run of missing hours, including the study's start and end, and its first date
longest_gap <- function(hours_with_data) {
  hour_values <- c(as.numeric(study_start) - 3600, sort(as.numeric(hours_with_data)), as.numeric(study_end) + 3600)
  gap_hours <- diff(hour_values) / 3600 - 1
  longest <- which.max(gap_hours)
  gap_start <- as_date(as_datetime(hour_values[longest] + 3600, tz = standard_time_zone))
  tibble(
    gap_days = round(gap_hours[longest] / 24, 1),
    gap_start = if (gap_hours[longest] > 0) gap_start else as.Date(NA)
  )
}

temp_gaps <- weather_hourly %>%
  filter(!is.na(temp_f)) %>%
  summarise(longest_gap(datetime_local), .by = site_id) %>%
  rename(longest_temp_gap_days = gap_days, longest_temp_gap_start = gap_start)

wind_gaps <- weather_hourly %>%
  filter(!is.na(wind_speed_kt)) %>%
  summarise(longest_gap(datetime_local), .by = site_id) %>%
  rename(longest_wind_gap_days = gap_days, longest_wind_gap_start = gap_start)

# Prevailing wind: the most common sector among hours that are not calm
prevailing_wind <- weather_hourly %>%
  filter(!is.na(wind_sector), !is_calm) %>%
  count(site_id, wind_sector, name = "n_hours") %>%
  mutate(pct_hours = round(100 * n_hours / sum(n_hours), 1), .by = site_id) %>%
  slice_max(n_hours, n = 1, with_ties = FALSE, by = site_id) %>%
  select(site_id, prevailing_wind_sector = wind_sector, pct_prevailing_sector = pct_hours)

weather_site_summary <- weather_hourly %>%
  group_by(site_id, local_site_name, site_group, region) %>%
  summarise(
    temp_source_sites = str_flatten(sort(unique(na.omit(temp_source_site))), collapse = ", "),
    wind_source_sites = str_flatten(sort(unique(na.omit(wind_source_site))), collapse = ", "),
    first_date = min(date_local),
    last_date = max(date_local),
    n_hours = n(),
    pct_temp_hours = round(100 * sum(!is.na(temp_f)) / n_study_hours, 1),
    pct_wind_hours = round(100 * sum(!is.na(wind_speed_kt)) / n_study_hours, 1),
    pct_own_temp_hours = round(100 * sum(!is.na(own_temp_f)) / n_study_hours, 1),
    temp_method_codes = str_flatten(sort(unique(na.omit(temp_method_code))), collapse = ", "),
    wind_method_codes = str_flatten(sort(unique(na.omit(wind_method_code))), collapse = ", "),
    n_complete_temp_days = n_distinct(date_local[is_complete_temp_day]),
    n_complete_wind_days = n_distinct(date_local[is_complete_wind_day]),
    pct_calm = round(100 * mean(is_calm, na.rm = TRUE), 1),
    n_wind_spikes = sum(is_wind_spike, na.rm = TRUE),
    mean_temp_c = round(mean(temp_c, na.rm = TRUE), 2),
    min_temp_c = round(min(temp_c, na.rm = TRUE), 2),
    max_temp_c = round(max(temp_c, na.rm = TRUE), 2),
    mean_wind_speed_ms = round(mean(wind_speed_ms, na.rm = TRUE), 2),
    .groups = "drop"
  ) %>%
  left_join(temp_gaps, by = "site_id", relationship = "one-to-one") %>%
  left_join(wind_gaps, by = "site_id", relationship = "one-to-one") %>%
  left_join(prevailing_wind, by = "site_id", relationship = "one-to-one")

summary_has_na <- weather_site_summary %>%
  select(-longest_temp_gap_start, -longest_wind_gap_start) %>%
  anyNA()

stopifnot(
  "One summary row per site" = nrow(weather_site_summary) == 9,
  "No missing values apart from gap start dates" = !summary_has_na,
  "The summary counts every row" = sum(weather_site_summary$n_hours) == nrow(weather_hourly)
)

print(weather_site_summary, n = Inf, width = Inf)

rm(temp_gaps, wind_gaps, prevailing_wind)



# 15. SAVE CHECKPOINT ----
hourly_weather <- weather_hourly %>%
  select(
    site_id, local_site_name, site_group, region,
    datetime_local, datetime_utc, date_local, hour_local, day_of_week, is_weekend, season,
    temp_f, temp_c, own_temp_f, own_temp_c, temp_method_code, temp_source_site,
    wind_speed_kt, wind_speed_ms, wind_dir_deg, wind_sector, wind_u_ms, wind_v_ms, wind_method_code, wind_source_site,
    is_calm, is_wind_spike, is_sonic_temp, is_sonic_wind, event_name,
    n_temp_hours_day, is_complete_temp_day, n_wind_hours_day, is_complete_wind_day
  ) %>%
  arrange(site_id, datetime_local)

final_keys <- hourly_weather %>%
  count(site_id, datetime_local) %>%
  filter(n > 1)

# Only the site, time and day columns must be complete
required_columns_have_na <- hourly_weather %>%
  select(
    site_id, local_site_name, site_group, region,
    datetime_local, datetime_utc, date_local, hour_local, day_of_week, is_weekend, season,
    n_temp_hours_day, is_complete_temp_day, n_wind_hours_day, is_complete_wind_day
  ) %>%
  anyNA()

stopifnot(
  "Every working column is saved" = setequal(names(hourly_weather), names(weather_hourly)),
  "Row total matches the cleaning log" = nrow(hourly_weather) == last(weather_cleaning_log$rows),
  "One row per site and hour" = nrow(final_keys) == 0,
  "Site, time and day columns are never missing" = !required_columns_have_na,
  "All 9 case-study sites are saved" = n_distinct(hourly_weather$site_id) == 9,
  "Data stay inside the study years" = all(year(hourly_weather$date_local) %in% study_years)
)

# Row counts are stored as whole numbers, like the daily and hourly cleaning logs
stopifnot(
  "Cleaning log row counts are whole numbers" = all(weather_cleaning_log$rows == round(weather_cleaning_log$rows))
)

weather_cleaning_log <- weather_cleaning_log %>%
  mutate(rows = as.integer(rows))

weather_cleaning_log <- weather_cleaning_log %>%
  mutate(rows_removed = as.integer(rows_removed))

print(weather_cleaning_log)

# The hourly weather table is the checkpoint later phases read, saved as a compressed .rds
weather_checkpoint <- list(
  hourly_weather = hourly_weather
)

# Each file is reloaded and checked against the object in memory (save_checkpoints() in utils.R)
weather_checkpoint_paths <- save_checkpoints(weather_checkpoint, processed_dir)

# Records of the run that no later script reads are saved as CSV
weather_records <- list(
  weather_cleaning_log = weather_cleaning_log,
  weather_validation = weather_validation,
  weather_site_summary = weather_site_summary,
  weather_sensor_check = weather_sensor_check
)

save_records(weather_records, processed_dir)

saved_weather_tables <- c(weather_checkpoint, weather_records, list(weather_raw_row_counts = weather_row_counts))

weather_dictionary <- tribble(
  ~table,                   ~column,                     ~description,
  "hourly_weather",         "site_id",                   "AQS site ID: state-county-site; joins to hourly_case_study with datetime_utc",
  "hourly_weather",         "local_site_name",           "Site name given by the reporting agency",
  "hourly_weather",         "site_group",                "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "hourly_weather",         "region",                    "Houston or Dallas-Fort Worth",
  "hourly_weather",         "datetime_local",            "Start of the hour in local standard time (fixed UTC-6, no daylight saving)",
  "hourly_weather",         "datetime_utc",              "Start of the hour in UTC; with site_id, the key for joining to hourly_case_study",
  "hourly_weather",         "date_local",                "Date in local standard time",
  "hourly_weather",         "hour_local",                "Hour of the day, 0 to 23, in local standard time",
  "hourly_weather",         "day_of_week",               "Day of the week, ordered Mon to Sun",
  "hourly_weather",         "is_weekend",                "TRUE on Saturday and Sunday",
  "hourly_weather",         "season",                    "Meteorological season; winter is Dec to Feb",
  "hourly_weather",         "temp_f",                    "Outdoor temperature in °F as reported; at Harvard Street, Bayland Park's reading",
  "hourly_weather",         "temp_c",                    "Outdoor temperature in °C",
  "hourly_weather",         "own_temp_f",                "The site's own sensor in °F; at Harvard Street it starts on 2023-04-19",
  "hourly_weather",         "own_temp_c",                "Temperature from the site's own sensor in °C",
  "hourly_weather",         "temp_method_code",          "AQS method code of the sensor behind temp_f; 069 is the Met One AIO2 sonic sensor",
  "hourly_weather",         "temp_source_site",          "Site that gave temp_f (Bayland Park for Harvard Street); NA with no reading",
  "hourly_weather",         "wind_speed_kt",             "Resultant hourly wind speed in knots; at Harvard Street, Croquet's reading",
  "hourly_weather",         "wind_speed_ms",             "Wind speed in m/s (1 knot = 0.514444 m/s)",
  "hourly_weather",         "wind_dir_deg",              "Resultant wind direction: where the wind blows from, in degrees clockwise from true north",
  "hourly_weather",         "wind_sector",               "12 sectors of 30° by centre angle; sector 0 runs from 345° to 15° and holds 0° and 360°",
  "hourly_weather",         "wind_u_ms",                 "East-west part of the wind in m/s, positive when blowing toward the east",
  "hourly_weather",         "wind_v_ms",                 "North-south part of the wind in m/s, positive when blowing toward the north",
  "hourly_weather",         "wind_method_code",          "AQS method code behind the wind columns; 069 is the Met One AIO2 sonic sensor",
  "hourly_weather",         "wind_source_site",          "Site that gave the wind columns (Croquet for Harvard Street); NA with no reading",
  "hourly_weather",         "is_calm",                   "TRUE when wind speed is below 0.5 m/s (EPA-454/R-99-005, 6.2.3); direction is unreliable",
  "hourly_weather",         "is_wind_spike",             "TRUE when wind speed is more than 20 knots above both the hour before and the hour after",
  "hourly_weather",         "is_sonic_temp",             "TRUE when temp_f comes from a sonic sensor (method 069)",
  "hourly_weather",         "is_sonic_wind",             "TRUE when the wind columns come from a sonic sensor (method 069)",
  "hourly_weather",         "event_name",                "Event from events.csv that also labels the hourly pollutants (Uri or Beryl); NA when none applies",
  "hourly_weather",         "n_temp_hours_day",          "Hours with a temperature at the site on that day",
  "hourly_weather",         "is_complete_temp_day",      "TRUE when the day has a temperature in at least 18 of 24 hours",
  "hourly_weather",         "n_wind_hours_day",          "Hours with wind at the site on that day",
  "hourly_weather",         "is_complete_wind_day",      "TRUE when the day has wind in at least 18 of 24 hours",
  "weather_cleaning_log",   "step",                      "Import, cleaning or reshaping step",
  "weather_cleaning_log",   "rows",                      "Rows in the working table after the step",
  "weather_cleaning_log",   "rows_removed",              "Rows removed by the step; NA for steps that combine or add rows",
  "weather_validation",     "check",                     "Validation check run at the end of 1e_weather_import_clean.R",
  "weather_validation",     "observed",                  "Value found in the weather data, as text",
  "weather_validation",     "expected",                  "Value the check requires, as text",
  "weather_validation",     "passed",                    "TRUE when observed equals expected",
  "weather_site_summary",   "site_id",                   "AQS site ID",
  "weather_site_summary",   "local_site_name",           "Site name given by the reporting agency",
  "weather_site_summary",   "site_group",                "Case-study group",
  "weather_site_summary",   "region",                    "Houston or Dallas-Fort Worth",
  "weather_site_summary",   "temp_source_sites",         "Sites whose sensors gave the temperatures",
  "weather_site_summary",   "wind_source_sites",         "Sites whose sensors gave the wind",
  "weather_site_summary",   "first_date",                "First date with any weather reading",
  "weather_site_summary",   "last_date",                 "Last date with any weather reading",
  "weather_site_summary",   "n_hours",                   "Hours in the table",
  "weather_site_summary",   "pct_temp_hours",            "Hours with a temperature, as a share of the 43,824 study hours",
  "weather_site_summary",   "pct_wind_hours",            "Hours with wind, as a share of the 43,824 study hours",
  "weather_site_summary",   "pct_own_temp_hours",        "Hours with a temperature from the site's own sensor, as a share of the study hours",
  "weather_site_summary",   "temp_method_codes",         "AQS method codes behind the temperatures",
  "weather_site_summary",   "wind_method_codes",         "AQS method codes behind the wind",
  "weather_site_summary",   "n_complete_temp_days",      "Days with a temperature in at least 18 hours",
  "weather_site_summary",   "n_complete_wind_days",      "Days with wind in at least 18 hours",
  "weather_site_summary",   "pct_calm",                  "Share of wind hours that are calm (below 0.5 m/s)",
  "weather_site_summary",   "n_wind_spikes",             "Hours flagged as one-hour wind spikes",
  "weather_site_summary",   "mean_temp_c",               "Mean temperature in °C",
  "weather_site_summary",   "min_temp_c",                "Lowest temperature in °C",
  "weather_site_summary",   "max_temp_c",                "Highest temperature in °C",
  "weather_site_summary",   "mean_wind_speed_ms",        "Mean wind speed in m/s",
  "weather_site_summary",   "longest_temp_gap_days",     "Longest run without a temperature, in days, counting the start and end of the study",
  "weather_site_summary",   "longest_temp_gap_start",    "First date of that run; NA when there is no gap",
  "weather_site_summary",   "longest_wind_gap_days",     "Longest run without wind, in days, counting the start and end of the study",
  "weather_site_summary",   "longest_wind_gap_start",    "First date of that run; NA when there is no gap",
  "weather_site_summary",   "prevailing_wind_sector",    "Most common wind sector among hours that are not calm",
  "weather_site_summary",   "pct_prevailing_sector",     "Share of those hours in the prevailing sector",
  "weather_sensor_check",   "site_id",                   "AQS site ID",
  "weather_sensor_check",   "local_site_name",           "Site name given by the reporting agency",
  "weather_sensor_check",   "sensor",                    "Temperature or Wind (speed and direction share one sensor)",
  "weather_sensor_check",   "sensor_history",            "Switched to sonic, Older sensor throughout, Sonic only, or No sensor",
  "weather_sensor_check",   "old_method_code",           "AQS method code of the older sensor (020 wind, 040 temperature)",
  "weather_sensor_check",   "last_old_date",             "Last date on the older sensor",
  "weather_sensor_check",   "first_sonic_date",          "First date on the sonic sensor (method 069)",
  "weather_sensor_check",   "days_without_data",         "Whole days with no reading between the older and the sonic sensor",
  "weather_sensor_check",   "hours_old",                 "Hours measured by the older sensor",
  "weather_sensor_check",   "hours_sonic",               "Hours measured by the sonic sensor",
  "weather_sensor_check",   "neighbour_id",              "Site used for comparison, which kept one sensor all five years; switched sites only",
  "weather_sensor_check",   "diff_unit",                 "Unit of the differences: °F for temperature, knots for wind speed",
  "weather_sensor_check",   "paired_hours_before",       "Hours with readings at both sites in the 365 days before the switch",
  "weather_sensor_check",   "paired_hours_after",        "Hours with readings at both sites in the 365 days after the switch",
  "weather_sensor_check",   "mean_diff_before",          "Mean of site minus neighbour before the switch",
  "weather_sensor_check",   "mean_diff_after",           "Mean of site minus neighbour after the switch",
  "weather_sensor_check",   "diff_change",               "Change in the mean difference at the switch (after minus before)",
  "weather_sensor_check",   "pct_calm_site_before",      "Share of paired hours that were calm at the site before the switch (wind only)",
  "weather_sensor_check",   "pct_calm_site_after",       "Share of paired hours that were calm at the site after the switch (wind only)",
  "weather_sensor_check",   "pct_calm_neighbour_before", "Share of paired hours that were calm at the neighbour before the switch (wind only)",
  "weather_sensor_check",   "pct_calm_neighbour_after",  "Share of paired hours that were calm at the neighbour after the switch (wind only)",
  "weather_raw_row_counts", "file",                      "Weather zip file in data/raw/weather",
  "weather_raw_row_counts", "file_type",                 "WIND (speed and direction) or TEMP (temperature)",
  "weather_raw_row_counts", "year",                      "Year the file covers",
  "weather_raw_row_counts", "raw_rows",                  "Data rows in the file, header excluded; equal to the count in EPA's file list"
)

# Stops on a saved column without a description, or a description of a column that was not saved
weather_dictionary <- document_tables(saved_weather_tables, weather_dictionary)

# 1a and 1d add their own rows to both shared files, and only the weather rows are replaced here
replace_own_rows(weather_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

# File size and checksum of the checkpoint; GitHub rejects files over 100 MiB
weather_manifest <- manifest_rows(weather_checkpoint, weather_checkpoint_paths)

stopifnot("Every weather file is under GitHub's 100 MiB limit" = all(weather_manifest$under_github_limit))

checkpoint_manifest <- replace_own_rows(weather_manifest, manifest_path, key = "file", col_types = manifest_col_types)

print(checkpoint_manifest, width = Inf)
