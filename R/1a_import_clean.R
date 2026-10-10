# SETUP ----
library(dplyr)
library(readr)
library(tidyr)
library(stringr)
library(janitor)
library(lubridate)
library(lobstr)
library(here)

source(here("R", "utils.R")) # log_step(), region_lookup



# CONFIG ----
study_years <- 2021:2025

pollutant_lookup <- tribble(
  ~parameter_code, ~pollutant, ~units_of_measure,             ~mw_g_mol, ~to_ppb,
  88101L,          "PM2.5",    "Micrograms/cubic meter (LC)", NA,        NA,
  44201L,          "Ozone",    "Parts per million",           48.00,     1000,
  42602L,          "NO2",      "Parts per billion",           46.01,     1,
  42401L,          "SO2",      "Parts per billion",           64.06,     1,
  42101L,          "CO",       "Parts per million",           28.01,     1000
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant))

state_fips      <- sprintf("%02d", 1:56)
territory_codes <- c("72", "78")
non_us_codes    <- "80"



# 1. IMPORT AND INSPECT ----
col_spec <- cols_only(
  `State Code`          = col_character(),
  `County Code`         = col_character(),
  `Site Num`            = col_character(),
  `Parameter Code`      = col_integer(),
  `POC`                 = col_integer(),
  `Latitude`            = col_double(),
  `Longitude`           = col_double(),
  `Sample Duration`     = col_character(),
  `Pollutant Standard`  = col_character(),
  `Date Local`          = col_date(),
  `Units of Measure`    = col_character(),
  `Event Type`          = col_character(),
  `Observation Count`   = col_integer(),
  `Observation Percent` = col_double(),
  `Arithmetic Mean`     = col_double(),
  `1st Max Value`       = col_double(),
  `1st Max Hour`        = col_integer(),
  `AQI`                 = col_integer(),
  `Method Code`         = col_character(),
  `Method Name`         = col_character(),
  `Local Site Name`     = col_character(),
  `State Name`          = col_character(),
  `County Name`         = col_character(),
  `CBSA Name`           = col_character()
)

csv_paths <- here("data", "raw") %>%
  list.files(pattern = "^daily_.*\\.csv$", full.names = TRUE)

expected_files <- expand_grid(
  parameter_code = pollutant_lookup$parameter_code,
  year = study_years
) %>%
  mutate(file = str_c("daily_", parameter_code, "_", year, ".csv"))

stopifnot(
  "data/raw must hold one file per pollutant and year" =
    setequal(basename(csv_paths), expected_files$file)
)

aqs_raw <- csv_paths %>%
  read_csv(col_types = col_spec)

stopifnot(
  "readr reported parsing problems" = nrow(problems(aqs_raw)) == 0,
  "All 24 columns imported" = ncol(aqs_raw) == length(col_spec$cols)
)

aqs_long <- aqs_raw %>%
  clean_names() %>%
  rename(
    first_max_value = x1st_max_value,
    first_max_hour  = x1st_max_hour
  )

rm(aqs_raw)

import_check <- aqs_long %>%
  count(parameter_code, year = year(date_local))

missing_combos <- expected_files %>%
  anti_join(import_check, by = c("parameter_code", "year"))

extra_combos <- import_check %>%
  anti_join(expected_files, by = c("parameter_code", "year"))

stopifnot(
  "Every pollutant has data in every study year" = nrow(missing_combos) == 0,
  "No data outside the study pollutants and years" = nrow(extra_combos) == 0
)

cleaning_log <- tibble(
  step = "Raw import",
  rows = nrow(aqs_long),
  rows_removed = NA_integer_
)

# Inspect
glimpse(aqs_long)

print(summary(aqs_long))

raw_na <- aqs_long %>%
  summarise(across(everything(), \(x) sum(is.na(x)))) %>%
  pivot_longer(everything(), names_to = "column", values_to = "n_missing") %>%
  filter(n_missing > 0) %>%
  arrange(desc(n_missing))

print(raw_na)



# 2. SITE ID ----
aqs_long <- aqs_long %>%
  mutate(site_id = str_c(state_code, county_code, site_num, sep = "-"))



# 3. POLLUTANT LABELS AND UNITS ----
aqs_long <- aqs_long %>%
  mutate(
    pollutant = recode_values(
      parameter_code,
      from = pollutant_lookup$parameter_code,
      to = as.character(pollutant_lookup$pollutant),
      unmatched = "error"
    ),
    pollutant = factor(pollutant, levels = levels(pollutant_lookup$pollutant))
  )

unexpected_units <- aqs_long %>%
  distinct(pollutant, units_of_measure) %>%
  anti_join(pollutant_lookup, by = c("pollutant", "units_of_measure"))

stopifnot("Each pollutant is reported in its expected unit" = nrow(unexpected_units) == 0)



# 4. DROP NON-US SITES ----
unknown_state_codes <- aqs_long %>%
  distinct(state_code) %>%
  filter(!state_code %in% c(state_fips, territory_codes, non_us_codes))

stopifnot("Only state, territory (72, 78) or Mexico (80) codes" = nrow(unknown_state_codes) == 0)

aqs_long <- aqs_long %>%
  filter_out(state_code %in% non_us_codes)

cleaning_log <- cleaning_log %>%
  log_step("Drop non-US sites", aqs_long)



# 5. KEEP NAAQS AVERAGING TIMES ----
duration_check <- aqs_long %>%
  count(pollutant, sample_duration, pollutant_standard)

print(duration_check, n = Inf)

aqs_long <- aqs_long %>%
  filter_out(pollutant == "PM2.5", sample_duration == "1 HOUR") %>%
  filter_out(pollutant == "SO2", sample_duration == "3-HR BLK AVG") %>%
  filter_out(pollutant == "CO", sample_duration == "1 HOUR")

standard_counts <- aqs_long %>%
  distinct(pollutant, pollutant_standard) %>%
  count(pollutant)

stopifnot(
  "Every remaining row has a NAAQS standard" = !anyNA(aqs_long$pollutant_standard),
  "All five pollutants remain" = nrow(standard_counts) == nrow(pollutant_lookup),
  "Exactly one standard per pollutant" = all(standard_counts$n == 1)
)

cleaning_log <- cleaning_log %>%
  log_step("Keep one standard per pollutant", aqs_long)



# 6. VALIDATE METHOD CODES ----
# T640/T640X PM2.5 monitors: 236/238 raw, 636/638 post-firmware, 736/738 EPA-corrected
t640_raw_codes       <- c("236", "238")
t640_firmware_codes  <- c("636", "638")
t640_corrected_codes <- c("736", "738")

stopifnot(
  "Method codes are 3 characters (leading zeros kept)" =
    all(str_length(aqs_long$method_code) == 3, na.rm = TRUE)
)

t640_check <- aqs_long %>%
  filter(method_code %in% c(t640_raw_codes, t640_firmware_codes, t640_corrected_codes)) %>%
  count(year = year(date_local), method_code)

print(t640_check, n = Inf)

gas_methods <- aqs_long %>%
  filter(pollutant != "PM2.5") %>%
  count(pollutant, method_code, method_name) %>%
  arrange(pollutant, desc(n))

print(gas_methods, n = Inf)

# EPA AQS methods reference table (FRM/FEM designations, instrument ranges, units)
methods_ref <- here("data", "reference", "methods_all.csv") %>%
  read_csv(col_types = cols(.default = col_character())) %>%
  clean_names() %>%
  mutate(
    parameter_code = as.integer(parameter_code),
    method_code = str_pad(method_code, width = 3, pad = "0")
  )

regulatory_methods <- methods_ref %>%
  filter(method_type %in% c("FRM", "FEM")) %>%
  distinct(parameter_code, method_code)

# Methods in the data without an FRM/FEM designation
method_status <- aqs_long %>%
  distinct(pollutant, parameter_code, method_code) %>%
  left_join(methods_ref %>% distinct(parameter_code, method_code, method_type),
            by = c("parameter_code", "method_code"))

method_status %>%
  filter(!method_type %in% c("FRM", "FEM")) %>%
  print(n = Inf)

early_firmware_rows <- aqs_long %>%
  filter(
    method_code %in% t640_firmware_codes,
    date_local < ymd("2023-01-01")
  )

corrected_years <- t640_check %>%
  filter(method_code %in% t640_corrected_codes) %>%
  distinct(year) %>%
  pull(year)

stopifnot(
  "No firmware codes (636/638) before 2023" = nrow(early_firmware_rows) == 0,
  "Corrected codes (736/738) cover 2021 and 2022" = all(c(2021, 2022) %in% corrected_years)
)

# Rows to remove, by reason (the three reasons don't overlap)
non_regulatory_count <- aqs_long %>%
  filter(!is.na(method_code), !method_code %in% t640_raw_codes) %>%
  anti_join(regulatory_methods, by = c("parameter_code", "method_code")) %>%
  nrow()

removal_breakdown <- tibble(
  raw_t640 = sum(aqs_long$method_code %in% t640_raw_codes),
  non_regulatory = non_regulatory_count,
  missing_method = sum(is.na(aqs_long$method_code))
)

print(removal_breakdown)

rows_before <- nrow(aqs_long)

aqs_long <- aqs_long %>%
  filter_out(method_code %in% t640_raw_codes) %>%
  semi_join(regulatory_methods, by = c("parameter_code", "method_code"))

stopifnot(
  "Rows removed match the removal breakdown" = rows_before - nrow(aqs_long) == sum(removal_breakdown),
  "No blank method codes remain" = !anyNA(aqs_long$method_code)
)

cleaning_log <- cleaning_log %>%
  log_step("Validate method codes", aqs_long)



# 7. RESOLVE EVENT-TYPE DUPLICATES ----
# Event-flagged days have an "Included" and an "Excluded" row; keep "Included"
allowed_event_types <- c("None", "Included", "Excluded")

event_type_counts <- aqs_long %>%
  count(pollutant, event_type)

print(event_type_counts, n = Inf)

excluded_rows <- aqs_long %>%
  filter(event_type == "Excluded")

included_rows <- aqs_long %>%
  filter(event_type == "Included")

unpaired_excluded <- excluded_rows %>%
  anti_join(included_rows, by = c("pollutant", "site_id", "poc", "date_local", "sample_duration"))

stopifnot(
  "Event types are None, Included or Excluded" = all(aqs_long$event_type %in% allowed_event_types),
  "Every Excluded row has an Included twin" = nrow(unpaired_excluded) == 0
)

aqs_long <- aqs_long %>%
  filter_out(event_type == "Excluded")

cleaning_log <- cleaning_log %>%
  log_step("Keep event-included values", aqs_long)

rm(excluded_rows, included_rows, unpaired_excluded)



# 8. RESOLVE DUPLICATE INSTRUMENT-DAYS ----
t640_codes <- c(t640_firmware_codes, t640_corrected_codes)

# Site-days reported under both a firmware and a corrected code. Matched by site, not POC:
# corrected data can sit under a separate POC (e.g. firmware POC 4, corrected POC 23)
t640_overlap <- aqs_long %>%
  filter(method_code %in% t640_codes) %>%
  mutate(code_type = if_else(method_code %in% t640_firmware_codes, "firmware", "corrected")) %>%
  distinct(site_id, date_local, code_type) %>%
  count(site_id, date_local) %>%
  filter(n > 1)

aqs_long %>%
  filter(method_code %in% t640_codes) %>%
  semi_join(t640_overlap, by = c("site_id", "date_local")) %>%
  count(site_id, poc, method_code, name = "overlap_days") %>%
  print(n = Inf)

# 636 must pair with 736 and 638 with 738 (same T640 model)
mixed_models <- aqs_long %>%
  filter(method_code %in% t640_codes) %>%
  semi_join(t640_overlap, by = c("site_id", "date_local")) %>%
  mutate(model = str_sub(method_code, 2, 3)) %>%
  distinct(site_id, model) %>%
  count(site_id) %>%
  filter(n > 1)

stopifnot("Overlapping codes come from the same T640 model" = nrow(mixed_models) == 0)

# Keep the firmware rows and drop the corrected duplicates
corrected_overlap_rows <- aqs_long %>%
  filter(method_code %in% t640_corrected_codes) %>%
  semi_join(t640_overlap, by = c("site_id", "date_local"))

aqs_long <- aqs_long %>%
  anti_join(corrected_overlap_rows, by = c("site_id", "poc", "date_local", "method_code"))

cleaning_log <- cleaning_log %>%
  log_step("Drop T640 corrected rows overlapping firmware data", aqs_long)

firmware_days <- aqs_long %>%
  filter(method_code %in% t640_firmware_codes) %>%
  distinct(site_id, date_local)

corrected_days <- aqs_long %>%
  filter(method_code %in% t640_corrected_codes) %>%
  distinct(site_id, date_local)

remaining_overlap <- corrected_days %>%
  semi_join(firmware_days, by = c("site_id", "date_local"))

duplicate_keys <- aqs_long %>%
  count(pollutant, site_id, poc, date_local) %>%
  filter(n > 1)

stopifnot(
  "No site-day has both firmware and corrected T640 data" = nrow(remaining_overlap) == 0,
  "One row per instrument per day" = nrow(duplicate_keys) == 0
)

# Site-days with more than one instrument (POC)
multi_poc_days <- aqs_long %>%
  distinct(pollutant, site_id, date_local, poc) %>%
  count(pollutant, site_id, date_local, name = "n_pocs") %>%
  filter(n_pocs > 1) %>%
  count(pollutant, name = "site_days_with_multiple_pocs")

print(multi_poc_days)

rm(corrected_overlap_rows)



# 9. 75% COMPLETENESS RULE ----
stopifnot("Observation percent is never missing" = !anyNA(aqs_long$observation_percent))

completeness_check <- aqs_long %>%
  group_by(pollutant) %>%
  summarise(
    rows = n(),
    below_75 = sum(observation_percent < 75),
    pct_below_75 = round(100 * below_75 / rows, 2)
  )

print(completeness_check)

aqs_long <- aqs_long %>%
  filter(observation_percent >= 75)

cleaning_log <- cleaning_log %>%
  log_step("Apply 75% completeness rule", aqs_long)



# 10. MISSING VALUES ----
analysis_cols <- c(
  "site_id", "poc", "pollutant", "date_local", "latitude", "longitude",
  "arithmetic_mean", "first_max_value", "observation_percent"
)

analysis_has_na <- aqs_long %>%
  select(all_of(analysis_cols)) %>%
  anyNA()

stopifnot("No missing values in analysis columns" = !analysis_has_na)



# 11. NEGATIVE, ZERO AND OUT-OF-RANGE VALUES ----
value_check <- aqs_long %>%
  group_by(pollutant) %>%
  summarise(
    units = first(units_of_measure),
    rows = n(),
    n_negative = sum(arithmetic_mean < 0),
    n_zero = sum(arithmetic_mean == 0),
    pct_nonpositive = round(100 * (n_negative + n_zero) / rows, 2),
    min_value = min(arithmetic_mean)
  )

print(value_check)

max_check <- aqs_long %>%
  group_by(pollutant) %>%
  summarise(
    n_negative_max = sum(first_max_value < 0),
    min_max_value = min(first_max_value)
  )

print(max_check)

# Three lowest daily means per pollutant
aqs_long %>%
  group_by(pollutant) %>%
  slice_min(arithmetic_mean, n = 3, with_ties = FALSE) %>%
  ungroup() %>%
  select(pollutant, site_id, poc, date_local, method_code, arithmetic_mean, units_of_measure) %>%
  print()

# Reference rows for the methods in the data
data_methods <- aqs_long %>%
  distinct(parameter_code, method_code, units_of_measure)

methods_in_data <- methods_ref %>%
  semi_join(data_methods, by = c("parameter_code", "method_code"))

methods_with_two_units <- methods_in_data %>%
  distinct(parameter_code, method_code, units) %>%
  count(parameter_code, method_code) %>%
  filter(n > 1)

unit_mismatches <- data_methods %>%
  left_join(
    methods_in_data %>% distinct(parameter_code, method_code, units),
    by = c("parameter_code", "method_code")
  ) %>%
  filter(is.na(units) | units != units_of_measure)

stopifnot(
  "Each method lists one unit in the reference table" = nrow(methods_with_two_units) == 0,
  "Method range units match the data's units" = nrow(unit_mismatches) == 0
)

method_limits <- methods_in_data %>%
  mutate(
    min_value = as.numeric(min_value),
    max_value = as.numeric(max_value)
  ) %>%
  group_by(parameter_code, method_code) %>%
  summarise(
    method_min = min(min_value),
    method_max = max(max_value),
    .groups = "drop"
  )

rows_with_limits <- aqs_long %>%
  select(pollutant, site_id, poc, date_local, parameter_code, method_code,
         arithmetic_mean, first_max_value) %>%
  left_join(method_limits, by = c("parameter_code", "method_code"), relationship = "many-to-one")

limits_missing <- rows_with_limits %>%
  select(method_min, method_max) %>%
  anyNA()

stopifnot("Every method has a lower and upper limit" = !limits_missing)

# Drop instrument-days whose daily max exceeds the method's upper limit
out_of_range_rows <- rows_with_limits %>%
  filter(first_max_value > method_max)

out_of_range_rows %>%
  count(pollutant, name = "n_above_method_max") %>%
  print()

in_range_rows <- rows_with_limits %>%
  filter(first_max_value <= method_max)

stopifnot(
  "Remaining daily means are at or above the method's lower limit" =
    all(in_range_rows$arithmetic_mean >= in_range_rows$method_min)
)

aqs_long <- aqs_long %>%
  anti_join(out_of_range_rows, by = c("pollutant", "site_id", "poc", "date_local"))

cleaning_log <- cleaning_log %>%
  log_step("Drop values outside method range", aqs_long)

rm(rows_with_limits, in_range_rows, out_of_range_rows)



# 12. CONVERT UNITS TO µg/m³ ----
# Ideal-gas molar volume at 25 °C and 1 atm
r_gas <- 8.31446261815324 # J/(mol K), CODATA 2017
t_ref <- 298.15           # K
p_ref <- 101325           # Pa

molar_volume <- 1000 * r_gas * t_ref / p_ref # L/mol

conversion_factors <- pollutant_lookup %>%
  mutate(ugm3_factor = if_else(pollutant == "PM2.5", 1, to_ppb * mw_g_mol / molar_volume)) %>%
  select(pollutant, ugm3_factor)

print(conversion_factors)

# Hand-calculated with Vm = 24.4654 L/mol: PM2.5, ozone, NO2, SO2, CO
expected_factors <- c(1, 1961.954, 1.880615, 2.618391, 1144.882)

stopifnot(
  "Conversion factors match the hand calculation" =
    isTRUE(all.equal(conversion_factors$ugm3_factor, expected_factors, tolerance = 1e-6))
)

aqs_long <- aqs_long %>%
  mutate(
    ugm3_factor = recode_values(
      pollutant,
      from = conversion_factors$pollutant,
      to = conversion_factors$ugm3_factor,
      unmatched = "error"
    )
  )

aqs_long <- aqs_long %>%
  mutate(
    mean_ugm3 = arithmetic_mean * ugm3_factor,
    max_ugm3 = first_max_value * ugm3_factor
  ) %>%
  select(-ugm3_factor)



# 13. DERIVED DATE COLUMNS ----
aqs_long <- aqs_long %>%
  mutate(
    year = year(date_local),
    month = month(date_local, label = TRUE, locale = "C"),
    year_month = floor_date(date_local, unit = "month"),
    day_of_year = yday(date_local)
  )

# Meteorological seasons; December counts toward the following year's winter
aqs_long <- aqs_long %>%
  mutate(
    month_num = month(date_local),
    season = case_when(
      month_num %in% c(12, 1, 2) ~ "Winter",
      month_num %in% 3:5 ~ "Spring",
      month_num %in% 6:8 ~ "Summer",
      month_num %in% 9:11 ~ "Autumn"
    ),
    season = factor(season, levels = c("Winter", "Spring", "Summer", "Autumn")),
    season_year = if_else(month_num == 12, year + 1, year)
  ) %>%
  select(-month_num)

aqs_long <- aqs_long %>%
  mutate(
    day_of_week = wday(date_local, label = TRUE, week_start = 1, locale = "C"),
    is_weekend = day_of_week %in% c("Sat", "Sun")
  )

date_cols <- c("year", "month", "year_month", "day_of_year",
               "season", "season_year", "day_of_week", "is_weekend")

date_cols_have_na <- aqs_long %>%
  select(all_of(date_cols)) %>%
  anyNA()

first_day_of_week <- aqs_long %>%
  filter(date_local == ymd("2021-01-01")) %>%
  distinct(day_of_week) %>%
  pull(day_of_week)

stopifnot(
  "No missing date fields" = !date_cols_have_na,
  "Month labels run Jan to Dec" = identical(levels(aqs_long$month), month.abb),
  "Weekday labels run Mon to Sun" =
    identical(levels(aqs_long$day_of_week), c("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")),
  "2021-01-01 is a Friday" = identical(as.character(first_day_of_week), "Fri")
)

aqs_long %>%
  count(season, month) %>%
  print(n = Inf)



# 14. EVENT LABELS ----
events_raw <- here("data", "reference", "events.csv") %>%
  read_csv(col_types = cols(.default = col_character()))

stopifnot("readr reported problems in events.csv" = nrow(problems(events_raw)) == 0)

events <- events_raw %>%
  mutate(
    start_date = ymd(start_date),
    end_date = ymd(end_date)
  )

us_states <- aqs_long %>%
  distinct(state_code) %>%
  pull(state_code)

stopifnot(
  "Event dates parse as yyyy-mm-dd" = !anyNA(events$start_date) && !anyNA(events$end_date),
  "Event windows end on or after they start" = all(events$end_date >= events$start_date),
  "Event state codes are 2 digits (check for Excel-stripped zeros)" =
    all(str_detect(events$state_code, "^\\d{2}$")),
  "Event county codes are 3 digits (check for Excel-stripped zeros)" =
    all(str_detect(events$event_county, "^\\d{3}$"), na.rm = TRUE),
  "Every event state has monitors in the data" = all(events$state_code %in% us_states)
)

# Fireworks windows (July 4-5 and Jan 1), every state, PM2.5 only
july_4 <- expand_grid(state_code = us_states, year = study_years) %>%
  mutate(
    event_name = "July 4 fireworks",
    pollutants = "PM2.5",
    start_date = make_date(year, 7, 4),
    end_date = make_date(year, 7, 5)
  )

new_year <- expand_grid(state_code = us_states, year = study_years) %>%
  mutate(
    event_name = "New Year fireworks",
    pollutants = "PM2.5",
    start_date = make_date(year, 1, 1),
    end_date = make_date(year, 1, 1)
  )

# One row per event, state and pollutant
event_windows <- events %>%
  select(event_name, state_code, event_county, pollutants, start_date, end_date) %>%
  bind_rows(
    july_4 %>% select(event_name, state_code, pollutants, start_date, end_date),
    new_year %>% select(event_name, state_code, pollutants, start_date, end_date)
  ) %>%
  separate_longer_delim(pollutants, delim = ";") %>%
  mutate(event_pollutant = str_trim(pollutants)) %>%
  select(-pollutants)

unknown_event_pollutants <- event_windows %>%
  distinct(event_pollutant) %>%
  filter(!event_pollutant %in% c(levels(aqs_long$pollutant), "all"))

stopifnot("Event pollutants exist in the data (\"all\" = every pollutant)" = nrow(unknown_event_pollutants) == 0)

# Match on state and date window, then on county (if given) and pollutant
event_matches <- aqs_long %>%
  select(pollutant, site_id, poc, date_local, state_code, county_code) %>%
  inner_join(event_windows, by = join_by(state_code, between(date_local, start_date, end_date))) %>%
  filter(
    is.na(event_county) | county_code == event_county,
    event_pollutant == "all" | event_pollutant == as.character(pollutant)
  ) %>%
  distinct(pollutant, site_id, poc, date_local, event_name)

multi_event_days <- event_matches %>%
  count(pollutant, site_id, poc, date_local) %>%
  filter(n > 1)

stopifnot("No instrument-day falls in two events" = nrow(multi_event_days) == 0)

aqs_long <- aqs_long %>%
  select(-any_of("event_name")) %>%
  left_join(
    event_matches,
    by = c("pollutant", "site_id", "poc", "date_local"),
    relationship = "many-to-one"
  )

fireworks_gases <- aqs_long %>%
  filter(
    str_detect(event_name, "fireworks"),
    pollutant != "PM2.5"
  )

stopifnot("Fireworks labels are PM2.5 only" = nrow(fireworks_gases) == 0)

aqs_long %>%
  filter(!is.na(event_name)) %>%
  count(event_name, pollutant) %>%
  print(n = Inf)

aqs_long %>%
  filter(!is.na(event_name)) %>%
  count(event_name, event_type) %>%
  print(n = Inf)

rm(event_matches)



# 15. SITE COVERAGE AND MONITORING GAPS ----
# A year counts as active with at least 75% of its expected samples.
# Seasonal ozone uses the most common federal season (Mar 1 to Oct 31, 245 days),
# except Dallas-Fort Worth, whose season runs Mar 1 to Nov 30 (275 days).
schedule_minimums <- tribble(
  ~schedule,           ~expected_days,
  "daily",             365,
  "1-in-3",            365 / 3,
  "1-in-6",            365 / 6,
  "ozone Mar-Oct",     245,
  "ozone Mar-Nov",     275,
  "insufficient data", Inf
) %>%
  mutate(min_days = ceiling(0.75 * expected_days))

stopifnot(
  "Seasonal ozone minimums are 184 and 207 days" =
    identical(schedule_minimums$min_days[str_starts(schedule_minimums$schedule, "ozone")], c(184, 207))
)

dfw_counties <- region_lookup %>%
  filter(region == "Dallas-Fort Worth") %>%
  pull(county_id)

instrument_years <- aqs_long %>%
  group_by(pollutant, site_id, poc, year) %>%
  summarise(
    median_spacing = median(as.numeric(diff(sort(date_local)))),
    has_winter_data = any(month %in% c("Dec", "Jan")),
    .groups = "drop"
  )

# Ozone with no Dec/Jan data is seasonal; PM2.5 schedule comes from median day spacing
instrument_years <- instrument_years %>%
  mutate(
    schedule = case_when(
      pollutant == "Ozone" & !has_winter_data & str_sub(site_id, 1, 6) %in% dfw_counties ~ "ozone Mar-Nov",
      pollutant == "Ozone" & !has_winter_data ~ "ozone Mar-Oct",
      is.na(median_spacing) ~ "insufficient data",
      pollutant != "PM2.5" ~ "daily",
      median_spacing <= 1.5 ~ "daily",
      median_spacing <= 4.5 ~ "1-in-3",
      .default = "1-in-6"
    )
  )

# A site-year is active if any schedule meets its minimum (days pooled across POCs)
site_schedule_years <- aqs_long %>%
  select(pollutant, site_id, poc, year, date_local) %>%
  inner_join(
    instrument_years %>% select(pollutant, site_id, poc, year, schedule),
    by = c("pollutant", "site_id", "poc", "year"),
    relationship = "many-to-one"
  ) %>%
  distinct(pollutant, site_id, year, schedule, date_local) %>%
  count(pollutant, site_id, year, schedule, name = "n_days") %>%
  left_join(schedule_minimums, by = "schedule", relationship = "many-to-one") %>%
  mutate(meets_minimum = n_days >= min_days)

stopifnot("Every schedule has a minimum" = !anyNA(site_schedule_years$min_days))

site_years <- site_schedule_years %>%
  group_by(pollutant, site_id, year) %>%
  summarise(year_active = any(meets_minimum), .groups = "drop")

site_coverage <- site_years %>%
  group_by(pollutant, site_id) %>%
  summarise(n_years_active = sum(year_active), .groups = "drop")

stopifnot(
  "Every pollutant-site has a coverage value" =
    nrow(site_coverage) == nrow(distinct(aqs_long, pollutant, site_id)),
  "Years active is between 0 and the study length" =
    all(site_coverage$n_years_active %in% 0:length(study_years))
)

# Full-coverage sites in the Houston and Dallas-Fort Worth case-study counties
site_coverage %>%
  filter(n_years_active == length(study_years)) %>%
  mutate(county_id = str_sub(site_id, 1, 6)) %>%
  inner_join(region_lookup, by = "county_id", relationship = "many-to-one") %>%
  count(region, pollutant) %>%
  print(n = Inf)

# Gaps longer than twice an instrument's typical sampling interval
monitor_gaps <- aqs_long %>%
  select(pollutant, site_id, poc, date_local) %>%
  arrange(pollutant, site_id, poc, date_local) %>%
  group_by(pollutant, site_id, poc) %>%
  mutate(
    prev_date = lag(date_local),
    days_since_prev = as.integer(date_local - prev_date)
  ) %>%
  mutate(typical_interval = median(days_since_prev, na.rm = TRUE)) %>%
  ungroup()

monitor_gaps <- monitor_gaps %>%
  filter(days_since_prev > 2 * typical_interval) %>%
  mutate(
    year = year(prev_date),
    gap_start = prev_date + 1,
    gap_end = date_local - 1,
    gap_days = days_since_prev - 1
  ) %>%
  select(pollutant, site_id, poc, year, gap_start, gap_end, gap_days)

# Seasonal ozone off-season: the whole gap falls between Nov 1 and Mar 31
monitor_gaps <- monitor_gaps %>%
  left_join(
    instrument_years %>% select(pollutant, site_id, poc, year, schedule),
    by = c("pollutant", "site_id", "poc", "year"),
    relationship = "many-to-one"
  ) %>%
  mutate(
    off_season_end = make_date(if_else(month(gap_end) <= 3, year(gap_end), year(gap_end) + 1), 3, 31),
    off_season_start = make_date(year(off_season_end) - 1, 11, 1),
    is_off_season = str_starts(schedule, "ozone ") & gap_start >= off_season_start
  )

stopifnot("Every gap has a schedule" = !anyNA(monitor_gaps$schedule))

gap_summary <- monitor_gaps %>%
  filter(!is_off_season) %>%
  group_by(pollutant) %>%
  summarise(
    n_gaps = n(),
    median_gap_days = median(gap_days),
    max_gap_days = max(gap_days),
    gaps_over_90_days = sum(gap_days > 90)
  )

print(gap_summary)

monitor_gaps %>%
  count(is_off_season, name = "n_gaps") %>%
  print()

# Harris County gaps overlapping Winter Storm Uri (Feb 11-20, 2021)
monitor_gaps %>%
  filter(
    str_starts(site_id, "48-201-"),
    gap_start <= ymd("2021-02-20"),
    gap_end >= ymd("2021-02-11")
  ) %>%
  select(pollutant, site_id, poc, gap_start, gap_end, gap_days) %>%
  arrange(gap_start) %>%
  print(n = Inf)

rm(instrument_years, site_schedule_years, site_years)



# 16. SITE TABLE AND UNUSED COLUMNS ----
site_cols <- c(
  "site_id", "state_code", "county_code", "state_name", "county_name",
  "cbsa_name", "local_site_name", "latitude", "longitude"
)

# Sites whose metadata changed during the study (the latest values are kept)
sites_with_changes <- aqs_long %>%
  select(all_of(site_cols)) %>%
  distinct() %>%
  count(site_id) %>%
  filter(n > 1)

print(sites_with_changes, n = Inf)

sites <- aqs_long %>%
  select(all_of(site_cols), date_local) %>%
  slice_max(date_local, n = 1, with_ties = FALSE, by = site_id) %>%
  select(-date_local) %>%
  arrange(site_id)

size_before <- obj_size(aqs_long)

final_cols <- c(
  "site_id", "poc", "pollutant", "method_code", "state_code", "county_code",
  "date_local", "year", "month", "year_month", "day_of_year",
  "season", "season_year", "day_of_week", "is_weekend",
  "units_of_measure", "arithmetic_mean", "first_max_value",
  "first_max_hour", "mean_ugm3", "max_ugm3",
  "event_type", "event_name"
)

aqs_long <- aqs_long %>%
  select(all_of(final_cols))

print(size_before)
print(obj_size(aqs_long))



# 17. FINAL VALIDATION ----
final_counts <- aqs_long %>%
  count(pollutant, year) %>%
  pivot_wider(names_from = year, values_from = n)

duplicate_final_keys <- aqs_long %>%
  count(pollutant, site_id, poc, date_local) %>%
  filter(n > 1)

final_na <- aqs_long %>%
  select(-event_name) %>%
  anyNA()

date_range <- range(aqs_long$date_local)

stopifnot(
  "Every pollutant appears" = nrow(final_counts) == nrow(pollutant_lookup),
  "Every study year appears" = setequal(names(final_counts)[-1], as.character(study_years)),
  "Every pollutant has data in every year" = !anyNA(final_counts),
  "Row total matches the cleaning log" = nrow(aqs_long) == last(cleaning_log$rows),
  "One row per pollutant, site, POC and date" = nrow(duplicate_final_keys) == 0,
  "Only event_name may be missing" = !final_na,
  "Data starts on Jan 1 of the first study year" = date_range[1] == make_date(min(study_years), 1, 1),
  "Data ends on Dec 31 of the last study year" = date_range[2] == make_date(max(study_years), 12, 31)
)

print(cleaning_log)
print(final_counts)



# 18. SAVE CHECKPOINT ----
# Scripts 1b onward read these files: aqs_long_clean.rds and sites.rds are the names 1b expects
processed_dir <- here("data", "processed")

dir.create(processed_dir, recursive = TRUE, showWarnings = FALSE)

checkpoint <- list(
  aqs_long_clean = aqs_long,
  sites = sites,
  site_coverage = site_coverage,
  cleaning_log = cleaning_log
)

checkpoint_paths <- file.path(processed_dir, str_c(names(checkpoint), ".rds"))

for (i in seq_along(checkpoint)) {
  write_rds(checkpoint[[i]], checkpoint_paths[i], compress = "gz")
}

reloaded <- lapply(checkpoint_paths, read_rds)

stopifnot(
  "Saved files reload identical to the objects in memory" =
    identical(unname(reloaded), unname(checkpoint))
)

rm(reloaded)

# Column descriptions for analysts using the checkpoint
data_dictionary <- tribble(
  ~table,           ~column,               ~description,
  "aqs_long_clean", "site_id",             "AQS site ID: state-county-site, e.g. 48-201-1052",
  "aqs_long_clean", "poc",                 "Parameter occurrence code; separates instruments measuring the same pollutant at one site",
  "aqs_long_clean", "pollutant",           "PM2.5, Ozone, NO2, SO2 or CO",
  "aqs_long_clean", "method_code",         "AQS method code; FRM or FEM methods only",
  "aqs_long_clean", "state_code",          "2-digit state FIPS code; 72 = Puerto Rico, 78 = U.S. Virgin Islands",
  "aqs_long_clean", "county_code",         "3-digit county FIPS code",
  "aqs_long_clean", "date_local",          "Sample date in local time",
  "aqs_long_clean", "year",                "Calendar year",
  "aqs_long_clean", "month",               "Month, ordered Jan to Dec",
  "aqs_long_clean", "year_month",          "First day of the month",
  "aqs_long_clean", "day_of_year",         "Day of the year, 1 to 366",
  "aqs_long_clean", "season",              "Meteorological season; winter is Dec to Feb",
  "aqs_long_clean", "season_year",         "Year the season belongs to; December counts toward the next year's winter",
  "aqs_long_clean", "day_of_week",         "Day of the week, ordered Mon to Sun",
  "aqs_long_clean", "is_weekend",          "TRUE on Saturday and Sunday",
  "aqs_long_clean", "units_of_measure",    "Units of the original values (ppm, ppb, or µg/m³ at local conditions)",
  "aqs_long_clean", "arithmetic_mean",     "Daily mean in original units",
  "aqs_long_clean", "first_max_value",     "Daily maximum in original units; the NAAQS metric for the gases",
  "aqs_long_clean", "first_max_hour",      "Hour (0 to 23) of the daily maximum",
  "aqs_long_clean", "mean_ugm3",           "Daily mean in µg/m³; gases converted at 25 °C and 1 atm",
  "aqs_long_clean", "max_ugm3",            "Daily maximum in µg/m³; gases converted at 25 °C and 1 atm",
  "aqs_long_clean", "event_type",          "AQS exceptional-event flag: None or Included",
  "aqs_long_clean", "event_name",          "Event from events.csv or a fireworks window; NA when no event applies",
  "sites",          "site_id",             "AQS site ID; joins to aqs_long_clean and site_coverage",
  "sites",          "state_code",          "2-digit state FIPS code",
  "sites",          "county_code",         "3-digit county FIPS code",
  "sites",          "state_name",          "State or territory name",
  "sites",          "county_name",         "County name",
  "sites",          "cbsa_name",           "Core-based statistical area; NA for sites outside one",
  "sites",          "local_site_name",     "Site name given by the reporting agency; can be NA",
  "sites",          "latitude",            "Latitude in decimal degrees",
  "sites",          "longitude",           "Longitude in decimal degrees",
  "site_coverage",  "pollutant",           "PM2.5, Ozone, NO2, SO2 or CO",
  "site_coverage",  "site_id",             "AQS site ID",
  "site_coverage",  "n_years_active",      "Study years (0 to 5) in which the site met the 75% completeness rule",
  "cleaning_log",   "step",                "Cleaning step",
  "cleaning_log",   "rows",                "Rows remaining after the step",
  "cleaning_log",   "rows_removed",        "Rows removed by the step"
)

saved_columns <- tibble(
  table = rep(names(checkpoint), times = lengths(checkpoint)),
  column = unlist(lapply(checkpoint, names), use.names = FALSE),
  type = unlist(lapply(checkpoint, \(df) vapply(df, \(x) class(x)[1], character(1))), use.names = FALSE)
)

undocumented_columns <- saved_columns %>%
  anti_join(data_dictionary, by = c("table", "column"))

stale_dictionary_rows <- data_dictionary %>%
  anti_join(saved_columns, by = c("table", "column"))

stopifnot(
  "Every saved column is in the data dictionary" = nrow(undocumented_columns) == 0,
  "The data dictionary lists no columns that were not saved" = nrow(stale_dictionary_rows) == 0
)

data_dictionary <- saved_columns %>%
  left_join(data_dictionary, by = c("table", "column"), relationship = "one-to-one")

write_csv(data_dictionary, file.path(processed_dir, "data_dictionary.csv"))

# File sizes and checksums; GitHub rejects files over 100 MiB
github_limit_mib <- 100

checkpoint_manifest <- tibble(
  file = basename(checkpoint_paths),
  rows = vapply(checkpoint, nrow, integer(1)),
  columns = vapply(checkpoint, ncol, integer(1)),
  size_mib = round(file.size(checkpoint_paths) / 2^20, 1),
  md5 = unname(tools::md5sum(checkpoint_paths))
) %>%
  mutate(under_github_limit = size_mib < github_limit_mib)

write_csv(checkpoint_manifest, file.path(processed_dir, "checkpoint_manifest.csv"))

print(checkpoint_manifest, width = Inf)

if (!all(checkpoint_manifest$under_github_limit)) {
  warning(
    "Over GitHub's ", github_limit_mib, " MiB limit: ",
    str_c(checkpoint_manifest$file[!checkpoint_manifest$under_github_limit], collapse = ", "),
    ". Add these files to .gitignore (the README explains how to rebuild them) or track them with Git LFS."
  )
}

rm(checkpoint)
