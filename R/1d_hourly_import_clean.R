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

source(here("R", "utils.R")) # log_step(), region_lookup



# CONFIG ----
study_years <- 2021:2025

hourly_codes <- c("44201", "42602", "42401")

hourly_dir <- here("data", "raw", "hourly")

processed_dir <- here("data", "processed")

filtered_dir <- here("data", "hourly_filtered")



# 1. RAW ROW COUNTS ----
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

# Count data rows in a zipped CSV, 1 million lines at a time to keep memory low (minus 1 for the header)
count_csv_rows <- function(zip_path) {
  n_lines <- 0
  read_lines_chunked(
    zip_path,
    SideEffectChunkCallback$new(\(lines, pos) n_lines <<- n_lines + length(lines)),
    chunk_size = 1e6
  )
  n_lines - 1
}

hourly_row_counts <- tibble(zip_path = zip_paths) %>%
  mutate(
    file = basename(zip_path),
    parameter_code = str_sub(file, 8, 12),
    year = as.integer(str_sub(file, 14, 17))
  ) %>%
  mutate(raw_rows = map_dbl(zip_path, count_csv_rows, .progress = TRUE)) %>%
  select(file, parameter_code, year, raw_rows) %>%
  arrange(parameter_code, year)

stopifnot(
  "Every file has rows" = all(hourly_row_counts$raw_rows > 0),
  "Row counts are whole numbers" = all(hourly_row_counts$raw_rows == round(hourly_row_counts$raw_rows))
)

# Row counts from EPA's AirData file list (file_list.csv, files dated 2026-06-25)
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

row_count_check <- hourly_row_counts %>%
  left_join(airdata_list_counts, by = c("parameter_code", "year"), relationship = "one-to-one") %>%
  mutate(difference = raw_rows - listed_rows)

print(row_count_check, n = Inf, width = Inf)

# A mismatch means a damaged download, or files EPA has since regenerated (check file_list.csv again)
stopifnot(
  "Every file has an EPA listed count" = !anyNA(row_count_check$listed_rows),
  "Row counts match EPA's file list" = all(row_count_check$difference == 0)
)

hourly_row_counts %>%
  group_by(year) %>%
  summarise(raw_rows = sum(raw_rows)) %>%
  print()

print(sum(hourly_row_counts$raw_rows))

# Saved to cross-check the rows read during the import
write_csv(hourly_row_counts, file.path(processed_dir, "hourly_raw_row_counts.csv"))



# 2. CHECK FILE HEADERS ----
# The 24 columns EPA documents for hourly files (AirData file formats, section 6.2)
documented_columns <- c(
  "State Code",
  "County Code",
  "Site Num",
  "Parameter Code",
  "POC",
  "Latitude",
  "Longitude",
  "Datum",
  "Parameter Name",
  "Date Local",
  "Time Local",
  "Date GMT",
  "Time GMT",
  "Sample Measurement",
  "Units of Measure",
  "MDL",
  "Uncertainty",
  "Qualifier",
  "Method Type",
  "Method Code",
  "Method Name",
  "State Name",
  "County Name",
  "Date of Last Change"
)

# Read the first lines of a zipped CSV without unzipping the whole file
read_first_lines <- function(zip_path, n) {
  csv_name <- str_replace(basename(zip_path), "\\.zip$", ".csv")
  con <- unz(zip_path, csv_name)
  on.exit(close(con))
  readLines(con, n = n)
}

read_header <- function(zip_path) {
  zip_path %>%
    read_first_lines(n = 1) %>%
    scan(text = ., what = "", sep = ",", quiet = TRUE)
}

file_headers <- tibble(zip_path = zip_paths) %>%
  mutate(
    file = basename(zip_path),
    columns = map(zip_path, read_header)
  )

header_strings <- map_chr(file_headers$columns, \(x) str_flatten(x, "|"))

first_header <- file_headers$columns[[1]]

print(setdiff(documented_columns, first_header))
print(setdiff(first_header, documented_columns))

stopifnot(
  "All 15 files share one header" = n_distinct(header_strings) == 1,
  "Header matches EPA's 24 documented columns, in order" = identical(first_header, documented_columns)
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

# Read only the 16 columns later steps use (8 of 24 are never parsed); codes stay text so leading zeros survive.
# Latitude, longitude and the GMT columns are needed for the relocation and time-zone checks
hourly_col_spec <- cols_only(
  `State Code`         = col_character(),
  `County Code`        = col_character(),
  `Site Num`           = col_character(),
  `Parameter Code`     = col_integer(),
  `POC`                = col_integer(),
  `Latitude`           = col_double(),
  `Longitude`          = col_double(),
  `Date Local`         = col_date(),
  `Time Local`         = col_character(),
  `Date GMT`           = col_date(),
  `Time GMT`           = col_character(),
  `Sample Measurement` = col_double(),
  `Units of Measure`   = col_character(),
  `MDL`                = col_double(),
  `Qualifier`          = col_character(),
  `Method Code`        = col_character()
)

# Drop non-Texas rows first (cheap text comparison) so site IDs are only built for Texas rows
keep_case_study_rows <- function(chunk) {
  chunk %>%
    filter(`State Code` == "48") %>%
    mutate(site_id = str_c(`State Code`, `County Code`, `Site Num`, sep = "-")) %>%
    semi_join(case_study_monitors, by = c("site_id", "Parameter Code" = "parameter_code"))
}

# Read one zip in 1-million-row chunks, keep only case-study rows and save them with the
# number of rows read. Files already saved are skipped, so a crash resumes where it stopped
filter_hourly_file <- function(zip_path) {
  out_path <- file.path(filtered_dir, str_replace(basename(zip_path), "\\.zip$", ".rds"))
  
  if (file.exists(out_path)) {
    return(out_path)
  }
  
  rows_read <- 0
  
  filtered_rows <- read_csv_chunked(
    zip_path,
    DataFrameCallback$new(\(chunk, pos) {
      stopifnot("readr reported parsing problems" = nrow(problems(chunk)) == 0)
      rows_read <<- rows_read + nrow(chunk)
      keep_case_study_rows(chunk)
    }),
    chunk_size = 1e6,
    col_types = hourly_col_spec
  )
  
  write_rds(list(rows_read = rows_read, data = filtered_rows), out_path, compress = "gz")
  
  rm(filtered_rows)
  invisible(gc())
  
  out_path
}

dir.create(filtered_dir, showWarnings = FALSE)

filtered_paths <- map_chr(zip_paths, filter_hourly_file, .progress = TRUE)

filtered_files <- map(filtered_paths, read_rds)

# Every row in every file must have been read: rows read has to equal the raw row count
filter_log <- tibble(
  file = basename(zip_paths),
  rows_read = map_dbl(filtered_files, "rows_read"),
  rows_kept = map_int(filtered_files, \(x) nrow(x$data))
) %>%
  left_join(hourly_row_counts %>% select(file, raw_rows), by = "file", relationship = "one-to-one")

print(filter_log, n = Inf)

stopifnot(
  "Rows read match the raw row counts" = all(filter_log$rows_read == filter_log$raw_rows),
  "Every file kept some rows" = all(filter_log$rows_kept > 0)
)

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
  "Only the 16 chosen columns were read, plus site_id" = ncol(hourly_raw) == length(hourly_col_spec$cols) + 1,
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
  rows = c(sum(filter_log$raw_rows), nrow(hourly_raw))
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

# Time zone: under local standard time, Texas (UTC-6) is always 6 hours behind GMT.
# Daylight saving time would show up as a 5-hour gap in summer
time_check <- hourly_raw %>%
  select(date_local, time_local, date_gmt, time_gmt) %>%
  mutate(
    local_time = ymd_hm(str_c(date_local, " ", time_local), tz = "UTC"),
    gmt_time = ymd_hm(str_c(date_gmt, " ", time_gmt), tz = "UTC"),
    gmt_minus_local_hours = as.numeric(difftime(gmt_time, local_time, units = "hours"))
  )

time_check %>%
  count(gmt_minus_local_hours) %>%
  print()

stopifnot(
  "Every timestamp parses" = !anyNA(time_check$local_time) && !anyNA(time_check$gmt_time),
  "Every time is on the hour" = all(str_detect(hourly_raw$time_local, "^\\d{2}:00$")),
  "GMT is always 6 hours ahead (local standard time, no daylight saving)" =
    all(time_check$gmt_minus_local_hours == 6)
)

rm(time_check)

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

# Qualifiers, typed with EPA's AQS qualifier table. Any code outside the lookup is
# labelled so it can be looked up before a rule is set
qualifier_types <- bind_rows(
  tibble(
    qualifier = c(as.character(1:9), "MD", "ND", "SQ", "V", "LJ"),
    qualifier_type = "Quality assurance"
  ),
  tibble(
    qualifier = c("RA", "RB", "RC", "RF", "RT", "E"),
    qualifier_type = "Request exclusion"
  ),
  tibble(
    qualifier = c("IA", "IB", "IL", "J", "A"),
    qualifier_type = "Informational"
  )
)

qualifier_counts <- hourly_raw %>%
  filter(!is.na(qualifier)) %>%
  count(pollutant, qualifier, has_value = !is.na(sample_measurement), name = "n_rows") %>%
  left_join(qualifier_types, by = "qualifier", relationship = "many-to-one") %>%
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
methods_ref <- here("data", "reference", "methods_all.csv") %>%
  read_csv(col_types = cols(.default = col_character())) %>%
  clean_names() %>%
  mutate(
    parameter_code = as.integer(parameter_code),
    method_code = str_pad(method_code, width = 3, pad = "0")
  )

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

# Coordinates over time, printed to 6 decimals. A site listed twice has moved (Deer Park #2 moved on 2025-05-30)
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
