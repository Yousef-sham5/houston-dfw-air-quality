# SETUP ----
library(dplyr)
library(readr)
library(tidyr)
library(stringr)
library(lubridate)
library(janitor)
library(ggplot2)
library(scales)
library(patchwork)
library(here)

source(here("R", "utils.R")) # study_years, region_lookup, read_methods_ref(), save helpers, chart theme

load_chart_fonts()

# The fitting packages are called with :: so MASS, which fitdistrplus attaches, never masks dplyr's select()
stopifnot(
  "moments is installed (run R/0_setup.R)" = requireNamespace("moments", quietly = TRUE),
  "fitdistrplus is installed (run R/0_setup.R)" = requireNamespace("fitdistrplus", quietly = TRUE)
)



# CONFIG ----
processed_dir <- here("data", "processed")

# CSV records go to the phase 3 folder; the dictionary stays in data/processed
records_dir <- file.path(processed_dir, "phase3")

dir.create(records_dir, recursive = TRUE, showWarnings = FALSE)

input_files <- c("aqs_long_clean.rds", "sites.rds", "site_coverage.rds", "daily_case_study.rds")

pollutant_levels <- c("PM2.5", "Ozone", "NO2", "SO2", "CO")

parameter_codes <- tribble(
  ~pollutant, ~parameter_code,
  "PM2.5",    88101L,
  "Ozone",    44201L,
  "NO2",      42602L,
  "SO2",      42401L,
  "CO",       42101L
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels))

# Five-year sites per pollutant (2a section 1) and their site-days after collocated instruments are averaged
five_year_site_counts <- c("PM2.5" = 769L, "Ozone" = 964L, "NO2" = 312L, "SO2" = 301L, "CO" = 135L)

five_year_site_days <- 4016891L

# Five-year ozone sites with December or January data in every year (2a section 5). The rest are seasonal monitors
year_round_ozone_sites <- 615L

# Labels 1a builds in code rather than reading from events.csv
fireworks_events <- c("July 4 fireworks", "New Year fireworks")

# January to February 2021 and December 2025 are the only parts of their winters inside the window
partial_winter_years <- c(min(study_years), max(study_years) + 1)

# Teledyne T640 and T640X PM2.5 monitors: firmware-corrected (636, 638) and EPA-corrected (736, 738) codes
t640_method_codes <- c("636", "638", "736", "738")

# Days between samples for each PM2.5 schedule; gas monitors run daily
sampling_schedules <- c("Daily" = 1, "1-in-3" = 3, "1-in-6" = 6)

# Values at or below zero are instrument noise around a true level near zero. The fits use half the method's federal
# detection limit in their place (decision P11); the reported value is kept beside it
mdl_fraction <- 0.5

# A site with at least this share of days at or below zero is left out of the fits and read through its spike days.
# In the case study this covers Clinton, Croquet and Park Place SO2
near_zero_share <- 0.25

# Copied from 2b CONFIG, so the case-study fits use the same groups and with-and-without checks
harris_groups_path <- here("data", "reference", "harris_site_channel_distance.csv")

ship_channel_km <- 7.5

transition_km <- 15

transition_band <- str_c(ship_channel_km, " to ", transition_km, " km")

# Houston North Loop, Houston Southwest Freeway, Dallas LBJ Freeway, Fort Worth California Parkway North
near_road_ids <- c(
  "48-201-1052",
  "48-201-1066",
  "48-113-1067",
  "48-439-1053"
)

sensitivity_sites <- tribble(
  ~site_id,      ~pollutant, ~local_site_name,                      ~left_out,
  "48-201-0066", "Ozone",    "Houston Westhollow",                  "Days after the method change",
  "48-201-0416", "NO2",      "Park Place",                          "Days after the method change",
  "48-201-0417", "NO2",      "Houston Harvard Street",              "Days after the method change",
  "48-439-1053", "PM2.5",    "Fort Worth California Parkway North", "Whole site"
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels))

relocations <- tribble(
  ~site_id,      ~relocation_date,
  "48-201-1039", "2025-05-30"
) %>%
  mutate(relocation_date = ymd(relocation_date))

# Houston SO2 sites by how they are read: Deer Park #2 (detection limit 0.2 ppb) is fitted, the others are near zero
houston_so2_ids <- c(
  "Clinton"              = "48-201-1035",
  "Houston Croquet"      = "48-201-0051",
  "Park Place"           = "48-201-0416",
  "Houston Deer Park #2" = "48-201-1039"
)

# Warm months for the season check, the same April to October window as 2a's weekend comparison
warm_months <- c("Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct")

# Census Bureau West region (AK, AZ, CA, CO, HI, ID, MT, NV, NM, OR, UT, WA, WY), copied from 2a, for the PM2.5 region check
western_state_codes <- c("02", "04", "06", "08", "15", "16", "30", "32", "35", "41", "49", "53", "56")

# Percentiles compared with each reference curve in the Q-Q summaries
qq_percentiles <- c(1, 5, 10, 25, 50, 75, 90, 95, 99)

# Histogram bins of each day against its site's median, on a log2 scale: quarter-steps from 1/16 to 16 times the median.
# Days beyond either end stay in the end bins
shape_bin_width <- 0.25

shape_bin_limit <- 4

# SO2 monitors with this federal detection limit report most days below it, so one check keeps only lower-limit sites
coarse_so2_limit <- 2

# A site needs this many days under a check for its shape measures to be read
min_shape_days <- 100

# A curve fits a site closely when none of the site's percentiles misses it by more than this many SDs
close_fit_miss <- 0.25

# The federal detection limit of the case-study ozone monitors. Readings below it are noise-level, and on a log scale a
# few of them can pull the skew a long way
very_low_ozone_ppm <- 0.005

figures_dir <- here("figures", "phase3")

stopifnot(
  "One parameter code per pollutant" = setequal(parameter_codes$pollutant, pollutant_levels),
  "Five-year site counts cover every pollutant" = setequal(names(five_year_site_counts), pollutant_levels),
  "Partial winters are 2021 and 2026" = identical(partial_winter_years, c(2021, 2026)),
  "Half the detection limit replaces values at or below zero" = mdl_fraction == 0.5,
  "The near-zero share is a fraction" = between(near_zero_share, 0, 1),
  "1c has written the Harris site groups (run 1c first)" = file.exists(harris_groups_path),
  "The transition band starts at the Ship Channel cutoff" = ship_channel_km < transition_km,
  "Near-road IDs are in the three case-study counties" = all(str_sub(near_road_ids, 1, 6) %in% region_lookup$county_id),
  "Sensitivity sites are unique site-pollutants" = !anyDuplicated(select(sensitivity_sites, site_id, pollutant)),
  "Relocation dates fall inside the study years" = all(year(relocations$relocation_date) %in% study_years),
  "Four Houston SO2 sites, all in Harris County" = length(houston_so2_ids) == 4 && all(str_sub(houston_so2_ids, 1, 6) == "48-201"),
  "Warm months are seven months of the year" = length(warm_months) == 7 && all(warm_months %in% month.abb),
  "The West region has 13 unique two-digit state codes" =
    length(unique(western_state_codes)) == 13 && all(str_detect(western_state_codes, "^\\d{2}$")),
  "Q-Q percentiles rise between 1 and 99" = !is.unsorted(qq_percentiles) && all(between(qq_percentiles, 1, 99)),
  "The histogram range is a whole number of bins" = (2 * shape_bin_limit / shape_bin_width) %% 1 == 0
)



# 1. FIT TABLE AND DATA NUANCES ----
# The daily checkpoints, checked against the manifest
aqs_long_clean <- read_rds(file.path(processed_dir, "aqs_long_clean.rds"))

sites <- read_rds(file.path(processed_dir, "sites.rds"))

site_coverage <- read_rds(file.path(processed_dir, "site_coverage.rds"))

daily_case_study <- read_rds(file.path(processed_dir, "daily_case_study.rds"))

input_check <- read_csv(manifest_path, col_types = manifest_col_types) %>%
  filter(file %in% input_files) %>%
  mutate(md5_on_disk = unname(tools::md5sum(file.path(processed_dir, file))))

stopifnot(
  "The manifest lists the four inputs" = setequal(input_check$file, input_files),
  "The inputs match the manifest (rerun 1a and 2a if not)" = all(input_check$md5 == input_check$md5_on_disk),
  "Pollutant levels match the daily table" = identical(levels(aqs_long_clean$pollutant), pollutant_levels),
  "Pollutant levels match the coverage table" = identical(levels(site_coverage$pollutant), pollutant_levels),
  "Pollutant levels match the case-study table" = identical(levels(daily_case_study$pollutant), pollutant_levels)
)

# Federal detection limit and FRM/FEM type of each method, for the five pollutants
method_limits <- read_methods_ref() %>%
  inner_join(parameter_codes, by = "parameter_code", relationship = "many-to-one") %>%
  distinct(parameter_code, method_code, method_type, federal_mdl, mdl_units = units) %>%
  mutate(federal_mdl = as.numeric(federal_mdl))

stopifnot(
  "One detection limit per parameter and method code" = !anyDuplicated(select(method_limits, parameter_code, method_code))
)

five_year_sites <- site_coverage %>%
  filter(n_years_active == length(study_years)) %>%
  select(pollutant, site_id)

fit_instruments <- aqs_long_clean %>%
  semi_join(five_year_sites, by = c("pollutant", "site_id"))

rm(aqs_long_clean)
invisible(gc())

fit_instruments <- fit_instruments %>%
  left_join(parameter_codes, by = "pollutant", relationship = "many-to-one") %>%
  left_join(method_limits, by = c("parameter_code", "method_code"), relationship = "many-to-one")

# PM2.5 is judged on its daily mean, the gases on their daily maximum, in original units
fit_instruments <- fit_instruments %>%
  mutate(value = if_else(pollutant == "PM2.5", arithmetic_mean, first_max_value))

stopifnot(
  "Every instrument-day has a value" = !anyNA(fit_instruments$value),
  "Every instrument-day has an FRM or FEM method type" = all(fit_instruments$method_type %in% c("FRM", "FEM")),
  "Every instrument-day has a federal detection limit" = !anyNA(fit_instruments$federal_mdl) && all(fit_instruments$federal_mdl > 0),
  "Detection limits are in the data's units" = all(fit_instruments$mdl_units == fit_instruments$units_of_measure)
)

# Collocated instruments are averaged per site and day, as in 2a (decision P13). Sorting puts each site-day's rows
# together, so rowsum() can total them in one pass
fit_instruments <- fit_instruments %>%
  arrange(pollutant, site_id, date_local)

fit_instruments <- fit_instruments %>%
  mutate(is_new_site_day = pollutant != lag(pollutant) | site_id != lag(site_id) | date_local != lag(date_local)) %>%
  mutate(is_new_site_day = coalesce(is_new_site_day, TRUE)) %>%
  mutate(site_day_id = cumsum(is_new_site_day))

collocated_label_conflicts <- fit_instruments %>%
  mutate(label = coalesce(event_name, "")) %>%
  mutate(previous_label = lag(label)) %>%
  filter(!is_new_site_day, label != previous_label)

stopifnot("Collocated instruments never carry two different event labels" = nrow(collocated_label_conflicts) == 0)

site_day_totals <- rowsum(
  cbind(
    value_total = fit_instruments$value,
    mdl_total = fit_instruments$federal_mdl,
    n_instruments = 1,
    n_fem = fit_instruments$method_type == "FEM",
    n_t640 = fit_instruments$method_code %in% t640_method_codes
  ),
  group = fit_instruments$site_day_id
)

site_day_values <- as_tibble(site_day_totals) %>%
  mutate(site_day_id = as.integer(rownames(site_day_totals))) %>%
  mutate(value = value_total / n_instruments) %>%
  mutate(federal_mdl = mdl_total / n_instruments) %>%
  mutate(method_types = case_when(n_fem == n_instruments ~ "FEM", n_fem == 0 ~ "FRM", .default = "FEM+FRM")) %>%
  mutate(has_t640 = n_t640 > 0) %>%
  mutate(n_instruments = as.integer(n_instruments)) %>%
  select(site_day_id, n_instruments, method_types, has_t640, value, federal_mdl)

fit_days <- fit_instruments %>%
  filter(is_new_site_day) %>%
  select(site_day_id, pollutant, site_id, state_code, date_local, year, month, season, season_year, is_weekend, units_of_measure, event_name) %>%
  inner_join(site_day_values, by = "site_day_id", relationship = "one-to-one") %>%
  select(-site_day_id)

rm(site_day_totals, site_day_values, collocated_label_conflicts)
invisible(gc())

fit_days <- fit_days %>%
  mutate(event_class = case_when(is.na(event_name) ~ "None", event_name %in% fireworks_events ~ "Fireworks", .default = "Event")) %>%
  mutate(event_class = factor(event_class, levels = c("None", "Event", "Fireworks")))

fit_days <- fit_days %>%
  mutate(is_full_season = !(season == "Winter" & season_year %in% partial_winter_years))

# The fitting copy: values at or below zero take half the detection limit, every other value stays as reported
fit_days <- fit_days %>%
  mutate(is_at_or_below_zero = value <= 0) %>%
  mutate(is_below_mdl = value < federal_mdl) %>%
  mutate(value_fit = if_else(is_at_or_below_zero, mdl_fraction * federal_mdl, value))

five_year_check <- fit_days %>%
  distinct(pollutant, site_id) %>%
  count(pollutant)

stopifnot(
  "Five-year site-days match 2a after averaging" = nrow(fit_days) == five_year_site_days,
  "Every instrument-day is counted once" = sum(fit_days$n_instruments) == nrow(fit_instruments),
  "Five-year sites per pollutant match 2a" =
    identical(five_year_check$n[match(names(five_year_site_counts), five_year_check$pollutant)], unname(five_year_site_counts)),
  "One row per pollutant, site and day" = !anyDuplicated(select(fit_days, pollutant, site_id, date_local)),
  "Every fitting value is above zero" = all(fit_days$value_fit > 0),
  "Only values at or below zero are replaced" = all((fit_days$value_fit != fit_days$value) == fit_days$is_at_or_below_zero)
)

# Method codes in each year. A site whose set of codes changes swapped or added an instrument, which can shift its level
# and look like a trend
method_sets <- fit_instruments %>%
  distinct(pollutant, site_id, year, method_code) %>%
  arrange(method_code) %>%
  summarise(method_set = str_c(method_code, collapse = "+"), .by = c(pollutant, site_id, year))

site_methods <- fit_instruments %>%
  distinct(pollutant, site_id, method_code, federal_mdl) %>%
  arrange(method_code) %>%
  summarise(
    method_codes = str_c(unique(method_code), collapse = "; "),
    n_mdl_values = n_distinct(federal_mdl),
    federal_mdl_min = min(federal_mdl),
    federal_mdl_max = max(federal_mdl),
    .by = c(pollutant, site_id)
  ) %>%
  left_join(
    summarise(method_sets, has_method_change = n_distinct(method_set) > 1, .by = c(pollutant, site_id)),
    by = c("pollutant", "site_id"),
    relationship = "one-to-one"
  )

# Measurement step: the smallest gap between a site's distinct positive readings, before averaging. Coarse steps
# (ozone 0.001 ppm, CO 0.1 ppm) give many tied values, which fit tests built for smooth data handle poorly
value_steps <- fit_instruments %>%
  filter(value > 0) %>%
  distinct(pollutant, site_id, value) %>%
  arrange(pollutant, site_id, value) %>%
  mutate(step = round(value - lag(value), 6), .by = c(pollutant, site_id)) %>%
  summarise(n_distinct_values = n(), value_step = min(step, na.rm = TRUE), .by = c(pollutant, site_id))

rm(fit_instruments, method_sets)
invisible(gc())

# Sampling schedule per site-year from the typical gap between samples. A PM2.5 site that moves from 1-in-3 to daily
# sampling catches more high days, so its exceedance counts can rise with no change in the air
site_year_schedules <- fit_days %>%
  select(pollutant, site_id, year, date_local) %>%
  arrange(pollutant, site_id, date_local) %>%
  mutate(gap_days = as.numeric(date_local - lag(date_local)), .by = c(pollutant, site_id, year)) %>%
  summarise(median_gap_days = median(gap_days, na.rm = TRUE), n_days = n(), .by = c(pollutant, site_id, year)) %>%
  mutate(schedule = coalesce(names(sampling_schedules)[match(median_gap_days, sampling_schedules)], "Irregular"))

site_schedules <- site_year_schedules %>%
  arrange(year) %>%
  summarise(
    min_days_in_year = min(n_days),
    sampling_schedule = if_else(n_distinct(schedule) == 1, first(schedule), "Changed"),
    schedules_by_year = str_c(schedule, collapse = ", "),
    .by = c(pollutant, site_id)
  )

# Sites with December or January data in every year. Seasonal ozone monitors stop in autumn, so a year-round fit at
# those sites describes the ozone season only
winter_years <- fit_days %>%
  filter(month %in% c("Dec", "Jan")) %>%
  distinct(pollutant, site_id, year) %>%
  count(pollutant, site_id, name = "years_with_winter_data")

site_day_summary <- fit_days %>%
  summarise(
    n_site_days = n(),
    pct_collocated_days = 100 * mean(n_instruments > 1),
    pct_fem_days = 100 * mean(method_types != "FRM"),
    pct_t640_days = 100 * mean(has_t640),
    pct_at_or_below_zero = 100 * mean(is_at_or_below_zero),
    pct_below_mdl = 100 * mean(is_below_mdl),
    pct_positive_under_substitute = 100 * mean(!is_at_or_below_zero & value < mdl_fraction * federal_mdl),
    pct_event_days = 100 * mean(event_class == "Event"),
    pct_fireworks_days = 100 * mean(event_class == "Fireworks"),
    .by = c(pollutant, site_id)
  )

# Case-study five-year site-days from 2a section 7, with the Houston distance bands from 1c and the checks 2b runs
harris_groups <- read_csv(
  harris_groups_path,
  col_types = cols(
    site_id = col_character(),
    local_site_name = col_character(),
    latitude = col_double(),
    longitude = col_double(),
    km_to_channel = col_double(),
    distance_band = col_character(),
    site_group = col_character(),
    in_memo_list = col_logical(),
    memo_site_group = col_character()
  )
)

case_fit_days <- daily_case_study %>%
  filter(is_five_year) %>%
  left_join(select(harris_groups, site_id, km_to_channel, distance_band), by = "site_id", relationship = "many-to-one")

case_fit_days <- case_fit_days %>%
  mutate(in_transition_band = coalesce(distance_band == transition_band & site_group == "Houston other", FALSE))

case_fit_days <- case_fit_days %>%
  left_join(relocations, by = "site_id", relationship = "many-to-one") %>%
  mutate(is_post_relocation = coalesce(date_local >= relocation_date, FALSE)) %>%
  select(-relocation_date)

case_fit_days <- case_fit_days %>%
  left_join(
    select(sensitivity_sites, site_id, pollutant, sensitivity_left_out = left_out),
    by = c("site_id", "pollutant"),
    relationship = "many-to-one"
  )

case_fit_days <- case_fit_days %>%
  mutate(is_near_road = site_id %in% near_road_ids)

# The case study takes the fitting columns from the national table, so both use one substitution rule
case_fit_days <- case_fit_days %>%
  left_join(
    select(fit_days, pollutant, site_id, date_local, value_national = value, federal_mdl, is_at_or_below_zero, is_below_mdl, value_fit),
    by = c("pollutant", "site_id", "date_local"),
    relationship = "one-to-one"
  )

case_group_counts <- case_fit_days %>%
  distinct(pollutant, site_group, site_id) %>%
  count(pollutant, site_group, .drop = FALSE) %>%
  filter(pollutant != "CO")

transition_keys <- case_fit_days %>%
  filter(in_transition_band) %>%
  distinct(site_id, pollutant) %>%
  transmute(key = str_c(site_id, " ", pollutant))

stopifnot(
  "Every case-study five-year site-day is in the national fit table" = !anyNA(case_fit_days$value_national),
  "Case-study values equal the national rebuild" = isTRUE(all.equal(case_fit_days$value, case_fit_days$value_national, tolerance = 1e-9)),
  "Five-year sites per group: PM2.5 3, 1, 3; ozone 6, 10, 6; NO2 4, 3, 4; SO2 3, 1, 0" =
    identical(case_group_counts$n, c(3L, 1L, 3L, 6L, 10L, 6L, 4L, 3L, 4L, 3L, 1L, 0L)),
  "The transition check removes North Wayside, Harvard Street, Monroe and Baytown Garth ozone and Harvard Street NO2" =
    setequal(
      transition_keys$key,
      c("48-201-0046 Ozone", "48-201-0417 Ozone", "48-201-0062 Ozone", "48-201-1017 Ozone", "48-201-0417 NO2")
    ),
  "Every sensitivity site-pollutant is a five-year case-study site" =
    nrow(anti_join(sensitivity_sites, case_fit_days, by = c("site_id", "pollutant"))) == 0,
  "The Deer Park #2 flag starts on its move" =
    min(case_fit_days$date_local[case_fit_days$is_post_relocation]) == relocations$relocation_date
)

case_fit_days <- case_fit_days %>%
  select(-value_national)

case_study_roles <- case_fit_days %>%
  summarise(
    in_transition_band = any(in_transition_band),
    sensitivity_left_out = first(sensitivity_left_out),
    is_near_road = any(is_near_road),
    has_relocation = any(is_post_relocation),
    .by = c(pollutant, site_id, site_group)
  )

# One row per five-year site and pollutant with every nuance that can bend a fitted distribution or a trend
fit_site_inventory <- site_day_summary %>%
  left_join(select(sites, site_id, local_site_name, state_name, cbsa_name), by = "site_id", relationship = "many-to-one") %>%
  left_join(site_schedules, by = c("pollutant", "site_id"), relationship = "one-to-one") %>%
  left_join(winter_years, by = c("pollutant", "site_id"), relationship = "one-to-one") %>%
  left_join(site_methods, by = c("pollutant", "site_id"), relationship = "one-to-one") %>%
  left_join(value_steps, by = c("pollutant", "site_id"), relationship = "one-to-one") %>%
  left_join(case_study_roles, by = c("pollutant", "site_id"), relationship = "one-to-one")

fit_site_inventory <- fit_site_inventory %>%
  mutate(is_year_round = coalesce(years_with_winter_data, 0L) == length(study_years)) %>%
  mutate(is_near_zero_site = pct_at_or_below_zero >= 100 * near_zero_share) %>%
  mutate(across(starts_with("pct_"), \(x) round(x, 2)))

fit_site_inventory <- fit_site_inventory %>%
  select(
    pollutant, site_id, local_site_name, state_name, cbsa_name, site_group, n_site_days, min_days_in_year,
    sampling_schedule, schedules_by_year, is_year_round, method_codes, has_method_change, n_mdl_values,
    federal_mdl_min, federal_mdl_max, pct_collocated_days, pct_fem_days, pct_t640_days, pct_at_or_below_zero,
    pct_below_mdl, pct_positive_under_substitute, pct_event_days, pct_fireworks_days, n_distinct_values, value_step,
    is_near_zero_site, in_transition_band, sensitivity_left_out, is_near_road, has_relocation
  ) %>%
  arrange(pollutant, site_id)

houston_so2_flags <- fit_site_inventory %>%
  filter(pollutant == "SO2", site_id %in% houston_so2_ids) %>%
  arrange(match(site_id, houston_so2_ids))

stopifnot(
  "One inventory row per five-year site and pollutant" = nrow(fit_site_inventory) == sum(five_year_site_counts),
  "Every site has a schedule, method history and measurement step" =
    !anyNA(select(fit_site_inventory, sampling_schedule, method_codes, has_method_change, value_step)),
  "Ozone sites reporting every winter match 2a" =
    sum(fit_site_inventory$is_year_round[fit_site_inventory$pollutant == "Ozone"]) == year_round_ozone_sites,
  "Every case-study five-year site has a group in the inventory" =
    sum(!is.na(fit_site_inventory$site_group)) == nrow(case_study_roles),
  "Clinton, Croquet and Park Place SO2 are near-zero sites and Deer Park #2 is not, as CONFIG says" =
    identical(houston_so2_flags$is_near_zero_site, c(TRUE, TRUE, TRUE, FALSE))
)

# Nuances per pollutant: how much the substitution touches, and how many sites changed instrument, schedule or season
pollutant_day_nuances <- fit_days %>%
  summarise(
    site_days = n(),
    pct_at_or_below_zero = round(100 * mean(is_at_or_below_zero), 2),
    pct_below_mdl = round(100 * mean(is_below_mdl), 2),
    pct_positive_under_substitute = round(100 * mean(!is_at_or_below_zero & value < mdl_fraction * federal_mdl), 2),
    pct_event_or_fireworks = round(100 * mean(event_class != "None"), 2),
    .by = pollutant
  )

pollutant_site_nuances <- fit_site_inventory %>%
  summarise(
    sites = n(),
    near_zero_sites = sum(is_near_zero_site),
    method_change_sites = sum(has_method_change),
    schedule_change_sites = sum(sampling_schedule == "Changed"),
    seasonal_sites = sum(!is_year_round),
    median_step = median(value_step),
    median_distinct_values = median(n_distinct_values),
    .by = pollutant
  )

nuance_summary <- pollutant_site_nuances %>%
  inner_join(pollutant_day_nuances, by = "pollutant", relationship = "one-to-one") %>%
  arrange(pollutant)

print(as.data.frame(nuance_summary))

fit_site_inventory %>%
  filter(pollutant == "PM2.5") %>%
  count(sampling_schedule) %>%
  print()

fit_site_inventory %>%
  filter(!is.na(site_group)) %>%
  select(pollutant, site_group, local_site_name, pct_at_or_below_zero, has_method_change, sensitivity_left_out, is_near_zero_site) %>%
  print(n = Inf, width = Inf)

stopifnot(
  "Every pollutant appears in the nuance summary" = setequal(as.character(nuance_summary$pollutant), pollutant_levels),
  "Nuance site counts add up to the inventory" = sum(nuance_summary$sites) == nrow(fit_site_inventory)
)

inventory_records <- list(
  distribution_site_inventory = fit_site_inventory
)

save_records(inventory_records, records_dir)

inventory_dictionary <- tribble(
  ~table,                        ~column,                         ~description,
  "distribution_site_inventory", "pollutant",                     "PM2.5, Ozone, NO2, SO2 or CO",
  "distribution_site_inventory", "site_id",                       "AQS site ID: state-county-site",
  "distribution_site_inventory", "local_site_name",               "Site name given by the reporting agency; can be NA",
  "distribution_site_inventory", "state_name",                    "State or territory name",
  "distribution_site_inventory", "cbsa_name",                     "Core-based statistical area; NA for sites outside one",
  "distribution_site_inventory", "site_group",                    "Case-study group for five-year Harris, Dallas and Tarrant sites; NA elsewhere",
  "distribution_site_inventory", "n_site_days",                   "Site-days with data, collocated instruments averaged",
  "distribution_site_inventory", "min_days_in_year",              "Fewest site-days in any study year",
  "distribution_site_inventory", "sampling_schedule",             "Daily, 1-in-3, 1-in-6 or Irregular from the median gap; Changed if years differ",
  "distribution_site_inventory", "schedules_by_year",             "Schedule in each year, 2021 to 2025",
  "distribution_site_inventory", "is_year_round",                 "TRUE with December or January data in every year; FALSE for seasonal monitors",
  "distribution_site_inventory", "method_codes",                  "AQS method codes used at the site during 2021 to 2025",
  "distribution_site_inventory", "has_method_change",             "TRUE when the set of method codes differs between years",
  "distribution_site_inventory", "n_mdl_values",                  "Distinct federal detection limits among the site's methods",
  "distribution_site_inventory", "federal_mdl_min",               "Lowest federal detection limit of the site's methods, in original units",
  "distribution_site_inventory", "federal_mdl_max",               "Highest federal detection limit of the site's methods, in original units",
  "distribution_site_inventory", "pct_collocated_days",           "% of site-days averaged over more than one instrument",
  "distribution_site_inventory", "pct_fem_days",                  "% of site-days with at least one FEM instrument",
  "distribution_site_inventory", "pct_t640_days",                 "% of site-days with a T640 or T640X PM2.5 monitor",
  "distribution_site_inventory", "pct_at_or_below_zero",          "% of site-days at or below zero; these take half the detection limit in the fits",
  "distribution_site_inventory", "pct_below_mdl",                 "% of site-days below the federal detection limit",
  "distribution_site_inventory", "pct_positive_under_substitute", "% of site-days above zero but below the substituted value",
  "distribution_site_inventory", "pct_event_days",                "% of site-days in an events.csv window",
  "distribution_site_inventory", "pct_fireworks_days",            "% of site-days in a fireworks window (PM2.5 only)",
  "distribution_site_inventory", "n_distinct_values",             "Distinct positive instrument readings before collocated averaging",
  "distribution_site_inventory", "value_step",                    "Measurement step: smallest gap between distinct positive readings",
  "distribution_site_inventory", "is_near_zero_site",             "TRUE when 25% or more of site-days are at or below zero",
  "distribution_site_inventory", "in_transition_band",            "TRUE for Houston other sites 7.5 to 15 km from the channel",
  "distribution_site_inventory", "sensitivity_left_out",          "Whole site or Days after the method change in the checks; else NA",
  "distribution_site_inventory", "is_near_road",                  "TRUE for the near-road case-study sites; NA outside the case study",
  "distribution_site_inventory", "has_relocation",                "TRUE for Houston Deer Park #2, which moved on 2025-05-30"
)

# Stops on a saved column without a description, or a description of a column that was not saved
inventory_dictionary <- document_tables(inventory_records, inventory_dictionary)

replace_own_rows(inventory_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 2. DESCRIPTIVE TABLE ----
# Summary statistics of the reported values, in original units. Pooled numbers weight each site by its days and mix the
# gaps between sites with the swings inside a site, so each row also gives the typical site's own mean, SD and skewness
# and the share of the pooled variance that lies between sites. Skewness is 0 and kurtosis 3 for a normal curve
describe_days <- function(site_days, group_cols) {
  pooled <- site_days %>%
    summarise(
      units_of_measure = first(units_of_measure),
      n_units = n_distinct(units_of_measure),
      n_sites = n_distinct(site_id),
      n_near_zero_sites = n_distinct(site_id[is_near_zero_site]),
      n_site_days = n(),
      mean = mean(value),
      sd = sd(value),
      min = min(value),
      q1 = quantile(value, 0.25),
      median = median(value),
      q3 = quantile(value, 0.75),
      p98 = quantile(value, 0.98),
      p99 = quantile(value, 0.99),
      max = max(value),
      skewness = moments::skewness(value),
      kurtosis = moments::kurtosis(value),
      total_sum_squares = sum((value - mean(value))^2),
      pct_at_or_below_zero = 100 * mean(is_at_or_below_zero),
      pct_event_days = 100 * mean(event_class == "Event"),
      pct_fireworks_days = 100 * mean(event_class == "Fireworks"),
      .by = all_of(group_cols)
    )

  site_level <- site_days %>%
    summarise(
      site_days = n(),
      site_mean = mean(value),
      site_sd = sd(value),
      site_skewness = moments::skewness(value),
      .by = all_of(c(group_cols, "site_id"))
    ) %>%
    summarise(
      median_site_mean = median(site_mean),
      median_site_sd = median(site_sd),
      median_site_skewness = median(site_skewness),
      between_sum_squares = sum(site_days * (site_mean - weighted.mean(site_mean, site_days))^2),
      .by = all_of(group_cols)
    )

  described <- pooled %>%
    inner_join(site_level, by = group_cols, relationship = "one-to-one") %>%
    mutate(pct_variance_between_sites = if_else(n_sites > 1, 100 * between_sum_squares / total_sum_squares, NA_real_)) %>%
    select(-total_sum_squares, -between_sum_squares)

  stopifnot(
    "Each described group uses one unit" = all(described$n_units == 1),
    "Each described group has a spread at every site" = !anyNA(described$median_site_skewness)
  )

  described %>%
    select(-n_units)
}

# A check that leaves a comparison's days exactly as in the ordinary-day row adds nothing, so it is dropped for that row
drop_unchanged_checks <- function(summary_rows, group_cols, kept_sets = c("All days", "Ordinary days")) {
  ordinary_days <- summary_rows %>%
    filter(site_set == "Ordinary days") %>%
    select(all_of(group_cols), ordinary_site_days = n_site_days)

  summary_rows %>%
    left_join(ordinary_days, by = group_cols, relationship = "many-to-one") %>%
    filter(site_set %in% kept_sets | n_site_days != ordinary_site_days) %>%
    select(-ordinary_site_days)
}

# Site flags from section 1, so each check below keeps or drops whole sites
site_flags <- fit_site_inventory %>%
  select(pollutant, site_id, is_year_round, is_near_zero_site, has_method_change, sampling_schedule)

summary_days <- fit_days %>%
  select(pollutant, site_id, units_of_measure, value, is_at_or_below_zero, event_class) %>%
  left_join(site_flags, by = c("pollutant", "site_id"), relationship = "many-to-one")

ordinary_summary_days <- summary_days %>%
  filter(event_class == "None")

national_site_sets <- list(
  "All days" = summary_days,
  "Ordinary days" = ordinary_summary_days,
  "Year-round sites" = filter(ordinary_summary_days, is_year_round),
  "Without near-zero sites" = filter(ordinary_summary_days, !is_near_zero_site),
  "Sites without a method change" = filter(ordinary_summary_days, !has_method_change),
  "Sites on daily sampling" = filter(ordinary_summary_days, sampling_schedule == "Daily")
)

national_summary <- bind_rows(Map(
  \(site_days, site_set) mutate(describe_days(site_days, "pollutant"), site_set = site_set),
  national_site_sets,
  names(national_site_sets)
)) %>%
  drop_unchanged_checks("pollutant") %>%
  mutate(scope = "National")

rm(summary_days, ordinary_summary_days, national_site_sets)
invisible(gc())

# The same table per case-study group, with the checks 2b runs, on ordinary days
case_summary_days <- case_fit_days %>%
  left_join(select(site_flags, pollutant, site_id, is_near_zero_site), by = c("pollutant", "site_id"), relationship = "many-to-one")

case_ordinary_days <- case_summary_days %>%
  filter(event_class == "None")

case_site_sets <- list(
  "All days" = case_summary_days,
  "Ordinary days" = case_ordinary_days,
  "Without the transition band" = filter(case_ordinary_days, !in_transition_band),
  "Without days after method changes" =
    filter(case_ordinary_days, !(coalesce(sensitivity_left_out == "Days after the method change", FALSE) & is_post_method_change)),
  "Without whole-site checks" = filter(case_ordinary_days, !coalesce(sensitivity_left_out == "Whole site", FALSE)),
  "Without Deer Park #2 after its move" = filter(case_ordinary_days, !is_post_relocation),
  "Without near-zero sites" = filter(case_ordinary_days, !is_near_zero_site)
)

case_group_cols <- c("pollutant", "site_group")

case_summary <- bind_rows(Map(
  \(site_days, site_set) mutate(describe_days(site_days, case_group_cols), site_set = site_set),
  case_site_sets,
  names(case_site_sets)
)) %>%
  drop_unchanged_checks(case_group_cols) %>%
  mutate(scope = "Case study")

rm(case_summary_days, case_ordinary_days, case_site_sets)

# Means do not describe a group led by near-zero SO2 sites, where most daily maximums sit at the noise floor, so those
# rows keep only the percentiles and the shares. Nationally these sites are a minority, and a check row leaves them out
mean_based_columns <- c(
  "mean", "sd", "skewness", "kurtosis", "median_site_mean", "median_site_sd", "median_site_skewness", "pct_variance_between_sites"
)

case_summary <- case_summary %>%
  mutate(across(all_of(mean_based_columns), \(x) if_else(n_near_zero_sites > 0, NA_real_, x)))

summary_site_set_levels <- c(
  "All days",
  "Ordinary days",
  "Year-round sites",
  "Without near-zero sites",
  "Sites without a method change",
  "Sites on daily sampling",
  "Without the transition band",
  "Without days after method changes",
  "Without whole-site checks",
  "Without Deer Park #2 after its move"
)

distribution_summary <- bind_rows(national_summary, case_summary) %>%
  mutate(scope = factor(scope, levels = c("National", "Case study"))) %>%
  mutate(site_set = factor(site_set, levels = summary_site_set_levels)) %>%
  arrange(scope, pollutant, site_group, site_set) %>%
  mutate(across(c(mean, sd, min, q1, median, q3, p98, p99, max, starts_with("median_site"), skewness, kurtosis), \(x) signif(x, 5))) %>%
  mutate(across(starts_with("pct_"), \(x) round(x, 2))) %>%
  select(
    scope, pollutant, site_group, site_set, units_of_measure, n_sites, n_near_zero_sites, n_site_days, mean, sd, min, q1, median,
    q3, p98, p99, max, skewness, kurtosis, median_site_mean, median_site_sd, median_site_skewness, pct_variance_between_sites,
    pct_at_or_below_zero, pct_event_days, pct_fireworks_days
  )

all_days_rows <- distribution_summary %>%
  filter(site_set == "All days")

national_all_days <- all_days_rows %>%
  filter(scope == "National")

case_all_days <- all_days_rows %>%
  filter(scope == "Case study")

ordinary_rows <- distribution_summary %>%
  filter(site_set != "All days")

stopifnot(
  "National all-day rows hold every five-year site-day" = sum(national_all_days$n_site_days) == nrow(fit_days),
  "National site counts match CONFIG" =
    identical(national_all_days$n_sites[match(names(five_year_site_counts), national_all_days$pollutant)], unname(five_year_site_counts)),
  "Case-study all-day rows hold every case-study site-day" = sum(case_all_days$n_site_days) == nrow(case_fit_days),
  "Case-study site counts match section 1" = identical(case_all_days$n_sites, case_group_counts$n[case_group_counts$n > 0]),
  "Twenty national rows: every pollutant all days, ordinary and method check, plus 1 year-round, 3 near-zero and 1 daily-sampling check" =
    sum(distribution_summary$scope == "National") == 20,
  "Thirty-three case-study rows: 22 all-day and ordinary, 2 transition, 3 method, 1 whole-site, 4 Deer Park #2, 1 near-zero" =
    sum(distribution_summary$scope == "Case study") == 33,
  "Percentiles rise in order in every row" =
    with(distribution_summary, all(min <= q1 & q1 <= median & median <= q3 & q3 <= p98 & p98 <= p99 & p99 <= max)),
  "No ordinary-day row holds an event or fireworks day" = all(ordinary_rows$pct_event_days == 0 & ordinary_rows$pct_fireworks_days == 0),
  "Every national all-day distribution leans right" = all(national_all_days$skewness > 0 & national_all_days$mean > national_all_days$median),
  "The share of variance between sites is a percentage" =
    all(between(distribution_summary$pct_variance_between_sites, 0, 100), na.rm = TRUE),
  "Mean-based columns are blank only for case-study rows with near-zero sites" =
    identical(
      is.na(distribution_summary$mean),
      distribution_summary$scope == "Case study" & distribution_summary$n_near_zero_sites > 0
    )
)

distribution_summary %>%
  filter(scope == "National") %>%
  select(pollutant, site_set, n_sites, n_site_days, mean, sd, median, q3, p99, max, skewness, kurtosis, median_site_skewness) %>%
  print(n = Inf, width = Inf)

distribution_summary %>%
  filter(scope == "Case study", site_set %in% c("All days", "Ordinary days")) %>%
  select(pollutant, site_group, site_set, n_sites, n_site_days, mean, sd, median, p98, max, skewness, pct_at_or_below_zero) %>%
  print(n = Inf, width = Inf)

summary_records <- list(
  distribution_summary = distribution_summary
)

save_records(summary_records, records_dir)

summary_dictionary <- tribble(
  ~table,                 ~column,                      ~description,
  "distribution_summary", "scope",                      "National (all five-year sites) or Case study (five-year sites per group)",
  "distribution_summary", "pollutant",                  "PM2.5, Ozone, NO2, SO2 or CO; CO is national only",
  "distribution_summary", "site_group",                 "Case-study group; NA in national rows",
  "distribution_summary", "site_set",                   "All days, Ordinary days (no event or fireworks days), or a check run on ordinary days",
  "distribution_summary", "units_of_measure",           "Units of the values in the row",
  "distribution_summary", "n_sites",                    "Sites in the row",
  "distribution_summary", "n_near_zero_sites",          "Sites in the row with 25% or more of their days at or below zero",
  "distribution_summary", "n_site_days",                "Site-days in the row; nearby days are linked, so this overstates independent values",
  "distribution_summary", "mean",                       "Pooled mean of the reported values; NA for case-study rows with near-zero sites",
  "distribution_summary", "sd",                         "Pooled standard deviation; NA for case-study rows with near-zero sites",
  "distribution_summary", "min",                        "Lowest reported value",
  "distribution_summary", "q1",                         "25th percentile",
  "distribution_summary", "median",                     "50th percentile",
  "distribution_summary", "q3",                         "75th percentile",
  "distribution_summary", "p98",                        "98th percentile of all site-days pooled; not a NAAQS-form value",
  "distribution_summary", "p99",                        "99th percentile of all site-days pooled; not a NAAQS-form value",
  "distribution_summary", "max",                        "Highest reported value",
  "distribution_summary", "skewness",                   "Pooled skewness (moments package); 0 for a normal curve",
  "distribution_summary", "kurtosis",                   "Pooled kurtosis (moments package, Pearson form); 3 for a normal curve",
  "distribution_summary", "median_site_mean",           "Median across sites of each site's own mean",
  "distribution_summary", "median_site_sd",             "Median across sites of each site's own standard deviation",
  "distribution_summary", "median_site_skewness",       "Median across sites of each site's own skewness",
  "distribution_summary", "pct_variance_between_sites", "% of pooled variance from differences between site means; NA with one site",
  "distribution_summary", "pct_at_or_below_zero",       "% of site-days at or below zero",
  "distribution_summary", "pct_event_days",             "% of site-days in an events.csv window",
  "distribution_summary", "pct_fireworks_days",         "% of site-days in a fireworks window (PM2.5 only)"
)

# Stops on a saved column without a description, or a description of a column that was not saved
summary_dictionary <- document_tables(summary_records, summary_dictionary)

replace_own_rows(summary_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 3. SHAPE OF THE DAILY VALUES ----
shape_bins <- tibble(bin = seq(-shape_bin_limit, shape_bin_limit - shape_bin_width, by = shape_bin_width)) %>%
  mutate(bin_upper = bin + shape_bin_width) %>%
  mutate(is_open_ended = bin == min(bin) | bin_upper == max(bin_upper))

# The bin of each day. Rounding first keeps a day exactly on an edge in the upper bin, since a ratio of 2 can compute as
# just under 2
shape_bin_of <- function(log2_ratio) {
  pmin(pmax(floor(round(log2_ratio, 10) / shape_bin_width) * shape_bin_width, min(shape_bins$bin)), max(shape_bins$bin))
}

# Share of a site's days that its own lognormal curve puts in the wrong histogram bin: half the absolute gaps, since each
# misplaced day counts twice. Measured site by site, because averaging sites first would cancel their misses
days_off_lognormal <- function(values) {
  log2_ratio <- log2(values / median(values))
  bin_index <- round((shape_bin_of(log2_ratio) - min(shape_bins$bin)) / shape_bin_width) + 1
  actual_share <- tabulate(bin_index, nrow(shape_bins)) / length(values)
  upper_share <- pnorm(shape_bins$bin_upper, mean(log2_ratio), sd(log2_ratio))
  lower_share <- pnorm(shape_bins$bin, mean(log2_ratio), sd(log2_ratio))
  upper_share[nrow(shape_bins)] <- 1
  lower_share[1] <- 0
  100 * sum(abs(actual_share - (upper_share - lower_share))) / 2
}

# How far each percentile misses a perfect normal curve, in SDs. Passing the logs measures the miss from a lognormal instead
qq_miss <- function(values) {
  abs((quantile(values, qq_percentiles / 100, names = FALSE) - mean(values)) / sd(values) - qnorm(qq_percentiles / 100))
}

# Each site's own shape on the fitting copy, before and after logs, with near-zero sites left out as in the fits. The
# ratios compare the site's percentiles with the normal and lognormal curves that share its mean and SD. The quantile
# skew uses the 10th, 50th and 90th percentiles, so a handful of very low days cannot drive it. Values are rounded before
# counting ties, since averaging instruments can leave 5.8 and 5.8000000000000007
shape_by_site <- function(site_days, group_cols) {
  site_days %>%
    mutate(log_value = log(value_fit)) %>%
    mutate(rounded_value = round(value_fit, 6)) %>%
    summarise(
      n_days = n(),
      pct_filled_in = 100 * mean(is_at_or_below_zero),
      pct_top_value = 100 * max(tabulate(match(rounded_value, unique(rounded_value)))) / n(),
      pct_days_off_lognormal = days_off_lognormal(value_fit),
      mean_miss_normal = mean(qq_miss(value_fit)),
      mean_miss_lognormal = mean(qq_miss(log_value)),
      largest_miss_normal = max(qq_miss(value_fit)),
      largest_miss_lognormal = max(qq_miss(log_value)),
      mean_value = mean(value_fit),
      sd_value = sd(value_fit),
      mean_log = mean(log_value),
      sd_log = sd(log_value),
      skewness = moments::skewness(value_fit),
      kurtosis = moments::kurtosis(value_fit),
      log_skewness = moments::skewness(log_value),
      log_kurtosis = moments::kurtosis(log_value),
      log_p10 = quantile(log_value, 0.10, names = FALSE),
      log_p50 = quantile(log_value, 0.50, names = FALSE),
      log_p90 = quantile(log_value, 0.90, names = FALSE),
      p05 = quantile(value_fit, 0.05, names = FALSE),
      p99 = quantile(value_fit, 0.99, names = FALSE),
      .by = all_of(c(group_cols, "site_id"))
    ) %>%
    mutate(log_quantile_skew = (log_p90 + log_p10 - 2 * log_p50) / (log_p90 - log_p10)) %>%
    mutate(spread_factor = exp(sd_log)) %>%
    mutate(p99_over_normal = p99 / (mean_value + qnorm(0.99) * sd_value)) %>%
    mutate(p99_over_lognormal = p99 / exp(mean_log + qnorm(0.99) * sd_log)) %>%
    mutate(p05_over_lognormal = p05 / exp(mean_log + qnorm(0.05) * sd_log)) %>%
    mutate(normal_p01_is_negative = mean_value + qnorm(0.01) * sd_value < 0) %>%
    select(-mean_value, -sd_value, -mean_log, -sd_log, -log_p10, -log_p50, -log_p90, -p05, -p99)
}

shape_measures <- c(
  "skewness", "kurtosis", "log_skewness", "log_kurtosis", "log_quantile_skew", "spread_factor",
  "p99_over_normal", "p99_over_lognormal", "p05_over_lognormal", "pct_days_off_lognormal", "pct_top_value", "pct_filled_in"
)

# The typical site and the middle half across sites, per pollutant or group. Each site counts once
summarise_shapes <- function(site_shapes, group_cols) {
  site_shapes %>%
    summarise(
      n_sites = n(),
      n_site_days = sum(n_days),
      pct_sites_log_nearer_symmetry = 100 * mean(abs(log_skewness) < abs(skewness)),
      pct_sites_normal_p01_negative = 100 * mean(normal_p01_is_negative),
      pct_sites_lognormal_closer = 100 * mean(mean_miss_lognormal < mean_miss_normal),
      pct_sites_lognormal_close = 100 * mean(largest_miss_lognormal <= close_fit_miss),
      pct_sites_normal_close = 100 * mean(largest_miss_normal <= close_fit_miss),
      across(
        all_of(shape_measures),
        list(median = \(x) median(x), q1 = \(x) quantile(x, 0.25, names = FALSE), q3 = \(x) quantile(x, 0.75, names = FALSE)),
        .names = "{.col}_{.fn}"
      ),
      .by = all_of(group_cols)
    )
}

# Q-Q summary: at each site, how many SDs each percentile sits from the mean, on the plain and the log scale. A perfect
# normal or lognormal site would match the theoretical value. Standard units stay usable at the low end, where a normal
# curve can predict a negative concentration and a ratio would break
qq_by_group <- function(site_days, group_cols) {
  site_days %>%
    mutate(log_value = log(value_fit)) %>%
    reframe(
      percentile = qq_percentiles,
      Normal = (quantile(value_fit, qq_percentiles / 100, names = FALSE) - mean(value_fit)) / sd(value_fit),
      Lognormal = (quantile(log_value, qq_percentiles / 100, names = FALSE) - mean(log_value)) / sd(log_value),
      .by = all_of(c(group_cols, "site_id"))
    ) %>%
    pivot_longer(c(Normal, Lognormal), names_to = "reference", values_to = "observed_z") %>%
    summarise(
      n_sites = n(),
      median_observed_z = median(observed_z),
      q1_observed_z = quantile(observed_z, 0.25, names = FALSE),
      q3_observed_z = quantile(observed_z, 0.75, names = FALSE),
      .by = all_of(c(group_cols, "reference", "percentile"))
    ) %>%
    mutate(theoretical_z = qnorm(percentile / 100))
}

# Share of days in each bin of value / site median, with each site counting once, beside what each site's own lognormal
# would put there. Dividing by the site median removes the gaps between sites, so only the shape is left
histogram_by_group <- function(site_days, group_cols) {
  ratio_days <- site_days %>%
    mutate(log2_ratio = log2(value_fit / median(value_fit)), .by = all_of(c(group_cols, "site_id"))) %>%
    mutate(bin = shape_bin_of(log2_ratio))

  n_group_sites <- ratio_days %>%
    distinct(across(all_of(c(group_cols, "site_id")))) %>%
    count(across(all_of(group_cols)), name = "n_sites")

  observed <- ratio_days %>%
    count(across(all_of(c(group_cols, "site_id", "bin"))), name = "n_days") %>%
    mutate(site_share = n_days / sum(n_days), .by = all_of(c(group_cols, "site_id"))) %>%
    summarise(total_share = sum(site_share), .by = all_of(c(group_cols, "bin")))

  predicted <- ratio_days %>%
    summarise(mean_log2 = mean(log2_ratio), sd_log2 = sd(log2_ratio), .by = all_of(c(group_cols, "site_id"))) %>%
    cross_join(shape_bins) %>%
    mutate(upper_share = if_else(bin_upper == max(shape_bins$bin_upper), 1, pnorm(bin_upper, mean_log2, sd_log2))) %>%
    mutate(lower_share = if_else(bin == min(shape_bins$bin), 0, pnorm(bin, mean_log2, sd_log2))) %>%
    summarise(predicted_total = sum(upper_share - lower_share), .by = all_of(c(group_cols, "bin", "bin_upper", "is_open_ended")))

  predicted %>%
    left_join(observed, by = c(group_cols, "bin"), relationship = "one-to-one") %>%
    left_join(n_group_sites, by = group_cols, relationship = "many-to-one") %>%
    mutate(pct_of_days = 100 * coalesce(total_share, 0) / n_sites) %>%
    mutate(pct_lognormal = 100 * predicted_total / n_sites) %>%
    mutate(ratio_lower = 2^bin) %>%
    mutate(ratio_upper = 2^bin_upper) %>%
    select(all_of(group_cols), n_sites, bin, ratio_lower, ratio_upper, is_open_ended, pct_of_days, pct_lognormal) %>%
    arrange(across(all_of(c(group_cols, "bin"))))
}

# The fitting days, without near-zero sites, on ordinary days as the main run. Site flags from section 1 drive the checks
shape_site_flags <- fit_site_inventory %>%
  mutate(region = if_else(str_sub(site_id, 1, 2) %in% western_state_codes, "West", "East")) %>%
  select(
    pollutant, site_id, local_site_name, state_name, site_group, region, is_year_round, has_method_change,
    sampling_schedule, federal_mdl_max, is_near_zero_site
  )

shape_days <- fit_days %>%
  select(pollutant, site_id, month, event_class, is_at_or_below_zero, value_fit) %>%
  semi_join(filter(shape_site_flags, !is_near_zero_site), by = c("pollutant", "site_id"))

ordinary_shape_days <- shape_days %>%
  filter(event_class == "None")

site_shapes <- shape_by_site(ordinary_shape_days, "pollutant") %>%
  left_join(shape_site_flags, by = c("pollutant", "site_id"), relationship = "one-to-one")

eligible_site_counts <- site_shapes %>%
  count(pollutant)

near_zero_counts <- fit_site_inventory %>%
  summarise(n_near_zero = sum(is_near_zero_site), .by = pollutant)

site_count_check <- eligible_site_counts %>%
  inner_join(near_zero_counts, by = "pollutant", relationship = "one-to-one")

stopifnot(
  "Every site outside the near-zero rule has a shape row" =
    all(site_count_check$n == unname(five_year_site_counts[as.character(site_count_check$pollutant)]) - site_count_check$n_near_zero),
  "Every site has every shape measure" = !anyNA(select(site_shapes, all_of(shape_measures))),
  "Every site has enough days to read its shape" = all(site_shapes$n_days >= min_shape_days),
  "Spread factors sit above 1" = all(site_shapes$spread_factor > 1)
)

# National checks. Those that recompute each site's shape come first; the rest keep or drop whole sites
warm_shape_days <- ordinary_shape_days %>%
  filter(month %in% warm_months)

national_site_shapes <- list(
  "Ordinary days" = site_shapes,
  "All days" = shape_by_site(shape_days, "pollutant"),
  "Warm season" = shape_by_site(warm_shape_days, "pollutant"),
  "Without values at or below zero" = shape_by_site(filter(ordinary_shape_days, !is_at_or_below_zero), "pollutant"),
  "Year-round sites" = filter(site_shapes, is_year_round),
  "Sites on daily sampling" = filter(site_shapes, sampling_schedule == "Daily"),
  "Sites without a method change" = filter(site_shapes, !has_method_change),
  "Sites with a method change" = filter(site_shapes, has_method_change),
  "Western PM2.5 sites" = filter(site_shapes, pollutant == "PM2.5", region == "West"),
  "Eastern PM2.5 sites" = filter(site_shapes, pollutant == "PM2.5", region == "East"),
  "SO2 sites with a lower limit" = filter(site_shapes, pollutant == "SO2", federal_mdl_max < coarse_so2_limit)
)

stopifnot(
  "Every site keeps enough days under the national checks" =
    all(vapply(national_site_shapes, \(shapes) min(shapes$n_days) >= min_shape_days, logical(1)))
)

national_shape_summary <- bind_rows(Map(
  \(shapes, site_set) mutate(summarise_shapes(shapes, "pollutant"), site_set = site_set),
  national_site_shapes,
  names(national_site_shapes)
)) %>%
  drop_unchanged_checks("pollutant", kept_sets = "Ordinary days") %>%
  mutate(scope = "National")

rm(warm_shape_days, national_site_shapes)
invisible(gc())

# The same by case-study group, with the checks 2b runs
case_shape_days <- case_fit_days %>%
  semi_join(filter(shape_site_flags, !is_near_zero_site), by = c("pollutant", "site_id"))

case_ordinary_shape_days <- case_shape_days %>%
  filter(event_class == "None")

case_shape_sets <- list(
  "Ordinary days" = case_ordinary_shape_days,
  "All days" = case_shape_days,
  "Warm season" = filter(case_ordinary_shape_days, month %in% warm_months),
  "Cool season" = filter(case_ordinary_shape_days, !month %in% warm_months),
  "Without values at or below zero" = filter(case_ordinary_shape_days, !is_at_or_below_zero),
  "Without the transition band" = filter(case_ordinary_shape_days, !in_transition_band),
  "Without days after method changes" =
    filter(case_ordinary_shape_days, !(coalesce(sensitivity_left_out == "Days after the method change", FALSE) & is_post_method_change)),
  "Without whole-site checks" = filter(case_ordinary_shape_days, !coalesce(sensitivity_left_out == "Whole site", FALSE)),
  "Without Deer Park #2 after its move" = filter(case_ordinary_shape_days, !is_post_relocation)
)

case_site_shapes <- lapply(case_shape_sets, \(site_days) shape_by_site(site_days, case_group_cols))

stopifnot(
  "Every case-study site keeps enough days under each check" =
    all(vapply(case_site_shapes, \(shapes) min(shapes$n_days) >= min_shape_days, logical(1)))
)

case_shape_summary <- bind_rows(Map(
  \(shapes, site_set) mutate(summarise_shapes(shapes, case_group_cols), site_set = site_set),
  case_site_shapes,
  names(case_site_shapes)
)) %>%
  drop_unchanged_checks(case_group_cols, kept_sets = "Ordinary days") %>%
  mutate(scope = "Case study")

rm(case_shape_sets)

shape_summary_set_levels <- c(
  "Ordinary days", "All days", "Warm season", "Cool season", "Without values at or below zero", "Year-round sites",
  "Sites on daily sampling",
  "Sites without a method change", "Sites with a method change", "Western PM2.5 sites", "Eastern PM2.5 sites",
  "SO2 sites with a lower limit", "Without the transition band", "Without days after method changes",
  "Without whole-site checks", "Without Deer Park #2 after its move"
)

shape_summary <- bind_rows(national_shape_summary, case_shape_summary) %>%
  mutate(scope = factor(scope, levels = c("National", "Case study"))) %>%
  mutate(site_set = factor(site_set, levels = shape_summary_set_levels)) %>%
  arrange(scope, pollutant, site_group, site_set) %>%
  select(scope, pollutant, site_group, site_set, n_sites, n_site_days, starts_with("pct_sites"), everything())

qq_points <- bind_rows(
  mutate(qq_by_group(ordinary_shape_days, "pollutant"), scope = "National"),
  mutate(qq_by_group(case_ordinary_shape_days, case_group_cols), scope = "Case study")
) %>%
  mutate(scope = factor(scope, levels = c("National", "Case study"))) %>%
  arrange(scope, pollutant, site_group, reference, percentile) %>%
  select(scope, pollutant, site_group, reference, percentile, theoretical_z, n_sites, median_observed_z, q1_observed_z, q3_observed_z)

shape_histograms <- bind_rows(
  mutate(histogram_by_group(ordinary_shape_days, "pollutant"), scope = "National"),
  mutate(histogram_by_group(case_ordinary_shape_days, case_group_cols), scope = "Case study")
) %>%
  mutate(scope = factor(scope, levels = c("National", "Case study"))) %>%
  arrange(scope, pollutant, site_group, bin) %>%
  select(scope, pollutant, site_group, n_sites, bin, ratio_lower, ratio_upper, is_open_ended, pct_of_days, pct_lognormal)

histogram_totals <- shape_histograms %>%
  summarise(observed = sum(pct_of_days), lognormal = sum(pct_lognormal), .by = c(scope, pollutant, site_group))

main_shapes <- shape_summary %>%
  filter(site_set == "Ordinary days")

national_main_shapes <- main_shapes %>%
  filter(scope == "National")

case_main_shapes <- main_shapes %>%
  filter(scope == "Case study")

stopifnot(
  "Each histogram holds all of its days" = all(abs(histogram_totals$observed - 100) < 1e-6),
  "Each lognormal reference adds to 100%" = all(abs(histogram_totals$lognormal - 100) < 1e-6),
  "Fifteen rows hold each main result: five pollutants and ten case-study groups" = nrow(main_shapes) == 15 && nrow(histogram_totals) == 15,
  "Nine percentiles and two reference curves per row" = nrow(qq_points) == 15 * 2 * length(qq_percentiles),
  "SO2 in the case study is Deer Park #2 alone" =
    case_main_shapes$n_sites[case_main_shapes$pollutant == "SO2"] == 1 && sum(case_main_shapes$pollutant == "SO2") == 1,
  "Thirty-five national rows: 20 ordinary, all-day, warm and without zeros; 1 year-round, 1 daily, 10 method, 2 region, 1 SO2 limit" =
    sum(shape_summary$scope == "National") == 35,
  "Fifty-four case-study rows: 39 ordinary, all-day, warm and cool; 5 without zeros, 2 transition, 3 method, 1 whole-site, 4 Deer Park #2" =
    sum(shape_summary$scope == "Case study") == 54
)

site_shapes %>%
  filter(!is.na(site_group)) %>%
  select(pollutant, site_group, local_site_name, n_days, skewness, log_skewness, log_quantile_skew, p99_over_lognormal, pct_top_value) %>%
  arrange(pollutant, site_group, local_site_name) %>%
  print(n = Inf, width = Inf)

shape_summary %>%
  select(
    scope, pollutant, site_group, site_set, n_sites, n_site_days, skewness_median, log_skewness_median, log_quantile_skew_median,
    spread_factor_median, p99_over_normal_median, p99_over_lognormal_median, pct_sites_log_nearer_symmetry, pct_sites_normal_p01_negative
  ) %>%
  mutate(across(where(is.numeric), \(x) signif(x, 3))) %>%
  print(n = Inf, width = Inf)

# Figure 3.1: each pollutant's shape at a typical site. The left panels remove site level, and the right panels show
# where each curve misses
figure_percentiles <- c(1, 10, 50, 90, 99)

ratio_breaks <- c(-4, -2, 0, 2, 4)

ratio_labels <- c("1/16", "1/4", "1", "4", "16")

national_panel_names <- c("PM2.5" = "PM2.5", "Ozone" = "OZONE", "NO2" = "NO2", "SO2" = "SO2", "CO" = "CO")

# The Q-Q panels plot the miss from a perfect fit in SDs, so the small gaps at each percentile can be read
miss_breaks <- c(-1, 0, 1)

miss_labels <- c("-1", "0", "+1")

miss_limits <- c(-1.9, 1.9)

qq_panel_extent <- qq_points %>%
  summarise(largest = max(abs(c(median_observed_z, q1_observed_z, q3_observed_z) - theoretical_z)), .by = c(scope, pollutant, site_group, reference))

stopifnot("Every Q-Q point and range fits inside its panel" = all(qq_panel_extent$largest <= max(miss_limits)))

national_shape_histogram_panel <- function(pollutant_name, panel_number) {
  bars <- shape_histograms %>%
    filter(scope == "National", pollutant == pollutant_name) %>%
    mutate(bin_mid = bin + shape_bin_width / 2)

  gap <- national_main_shapes$pct_days_off_lognormal_median[national_main_shapes$pollutant == pollutant_name]

  ggplot(bars, aes(bin_mid, pct_of_days)) +
    geom_col(width = shape_bin_width * 0.86, fill = chart_fills[["accent"]]) +
    geom_line(aes(y = pct_lognormal), colour = chart_ink[["primary"]], linewidth = 0.45, linetype = "22") +
    scale_x_continuous(
      breaks = ratio_breaks,
      labels = ratio_labels,
      limits = c(-shape_bin_limit, shape_bin_limit),
      expand = expansion(mult = 0.01)
    ) +
    scale_y_continuous(breaks = breaks_pretty(n = 3), labels = \(x) str_c(x, "%"), expand = expansion(mult = c(0, 0.08))) +
    labs(
      title = sprintf("%02d  %s", panel_number, national_panel_names[[pollutant_name]]),
      subtitle = sprintf("Typical site: %.1f%% off lognormal", gap),
      x = NULL,
      y = NULL
    ) +
    theme_aqs()
}

national_qq_panel <- function(pollutant_name, panel_number) {
  points <- qq_points %>%
    filter(scope == "National", pollutant == pollutant_name) %>%
    mutate(reference = factor(reference, levels = c("Normal", "Lognormal")))

  lognormal_share <- national_main_shapes$pct_sites_lognormal_closer[national_main_shapes$pollutant == pollutant_name]

  closer_label <- if_else(
    lognormal_share >= 50,
    sprintf("Lognormal closer at %.0f%% of sites", lognormal_share),
    sprintf("Normal closer at %.0f%% of sites", 100 - lognormal_share)
  )

  ggplot(points, aes(theoretical_z, median_observed_z - theoretical_z, colour = reference, fill = reference)) +
    geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35, linetype = "22") +
    geom_ribbon(aes(ymin = q1_observed_z - theoretical_z, ymax = q3_observed_z - theoretical_z), colour = NA, alpha = 0.22) +
    geom_line(linewidth = 0.55) +
    geom_point(size = 0.9) +
    scale_colour_manual(values = c("Normal" = chart_ink[["muted"]], "Lognormal" = chart_fills[["accent"]]), guide = "none") +
    scale_fill_manual(values = c("Normal" = chart_ink[["muted"]], "Lognormal" = chart_fills[["accent"]]), guide = "none") +
    scale_x_continuous(breaks = qnorm(figure_percentiles / 100), labels = str_c("P", figure_percentiles)) +
    scale_y_continuous(breaks = miss_breaks, labels = miss_labels) +
    coord_cartesian(ylim = miss_limits) +
    labs(title = sprintf("%02d  %s", panel_number, national_panel_names[[pollutant_name]]), subtitle = closer_label, x = NULL, y = NULL) +
    theme_aqs()
}

national_shape_panels <- unlist(
  lapply(seq_along(pollutant_levels), \(i) list(
    national_shape_histogram_panel(pollutant_levels[i], 2 * i - 1),
    national_qq_panel(pollutant_levels[i], 2 * i)
  )),
  recursive = FALSE
)

# The title and subtitle must hold under every national check, site by site
national_check_rows <- shape_summary %>%
  filter(scope == "National")

log_suited_rows <- national_check_rows %>%
  filter(pollutant %in% c("PM2.5", "SO2", "CO"))

ozone_check_rows <- national_check_rows %>%
  filter(pollutant == "Ozone")

no2_check_rows <- national_check_rows %>%
  filter(pollutant == "NO2")

stopifnot(
  "A lognormal is closer and logs bring skew nearer zero at 75% of PM2.5, SO2 and CO sites under every check, as the title says" =
    all(log_suited_rows$pct_sites_lognormal_closer >= 75) && all(log_suited_rows$pct_sites_log_nearer_symmetry >= 75),
  "A normal curve is closer at three in four ozone sites under every check, as the subtitle says" =
    all(ozone_check_rows$pct_sites_lognormal_closer <= 25),
  "NO2 sites split between the two curves under every check, as the subtitle says" =
    all(between(no2_check_rows$pct_sites_lognormal_closer, 50, 75))
)

national_shape_header <- chart_header(
  sprintf("FIGURE 3.1  /  SHAPE OF THE DAILY VALUES  /  %s FIVE-YEAR SITES", comma(sum(national_main_shapes$n_sites))),
  "A log scale suits PM2.5, SO2 and CO best",
  str_c(
    "Ozone sits closer to a normal curve, and NO2 sites split between the two.\n",
    "Left: days against each site's median. Right: how far each percentile misses each curve."
  ),
  key = tribble(
    ~mark,    ~colour,                 ~label,
    "square", chart_fills[["accent"]], "Days (left), lognormal miss (right)",
    "square", chart_ink[["muted"]],    "Normal miss (right)",
    "bar",    chart_ink[["primary"]],  "Dashed: lognormal (left), perfect fit (right)"
  )
)

national_shape_footer <- chart_footer(str_c(
  "EPA AQS, ordinary days, values at or below zero at half the detection limit, near-zero sites left out. Each site counts\n",
  "once. Right: median and middle half across sites of the miss in SDs; above zero, the actual percentile runs higher.\n",
  "End bars hold days beyond 1/16 and 16 times the median. SO2 and CO report in coarse steps, which widens their misses."
))

national_shape_figure <- chart_compose(national_shape_header, national_shape_panels, national_shape_footer)

dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

national_shape_path <- file.path(figures_dir, "3.01_shape.png")

save_started <- Sys.time()

ggsave(national_shape_path, national_shape_figure, width = 6.5, height = 9.4, dpi = 300)

stopifnot(
  "3.01_shape.png was written (close any viewer of it and rerun this step)" = file.mtime(national_shape_path) >= save_started - 2
)

# Figure 3.2: the same shape by case-study group. One curve per group, since the groups overlap
case_histogram_panel <- function(pollutant_name, panel_number, panel_name) {
  ggplot(
    filter(shape_histograms, scope == "Case study", pollutant == pollutant_name) %>%
      mutate(bin_mid = bin + shape_bin_width / 2),
    aes(bin_mid, pct_of_days, colour = site_group)
  ) +
    geom_line(linewidth = 0.55) +
    scale_colour_manual(values = site_group_colours, guide = "none") +
    scale_x_continuous(breaks = ratio_breaks, labels = ratio_labels, limits = c(-shape_bin_limit, shape_bin_limit)) +
    scale_y_continuous(
      breaks = breaks_pretty(n = 3),
      labels = \(x) str_c(x, "%"),
      expand = expansion(mult = c(0, 0.08)),
      limits = c(0, NA)
    ) +
    labs(title = sprintf("%02d  %s", panel_number, panel_name), subtitle = "Around site median", x = NULL, y = NULL) +
    theme_aqs()
}

case_qq_panel <- function(pollutant_name, reference_name, panel_number, panel_name) {
  ggplot(
    filter(qq_points, scope == "Case study", pollutant == pollutant_name, reference == reference_name),
    aes(theoretical_z, median_observed_z - theoretical_z, colour = site_group)
  ) +
    geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35, linetype = "22") +
    geom_line(linewidth = 0.55) +
    geom_point(size = 0.8) +
    scale_colour_manual(values = site_group_colours, guide = "none") +
    scale_x_continuous(breaks = qnorm(c(1, 50, 99) / 100), labels = c("P1", "P50", "P99")) +
    scale_y_continuous(breaks = miss_breaks, labels = miss_labels) +
    coord_cartesian(ylim = miss_limits) +
    labs(
      title = sprintf("%02d  %s", panel_number, panel_name),
      subtitle = str_c("Against ", str_to_lower(reference_name)),
      x = NULL,
      y = NULL
    ) +
    theme_aqs()
}

case_panel_names <- c("PM2.5" = "PM2.5", "Ozone" = "OZONE", "NO2" = "NO2", "SO2" = "SO2, DEER PARK #2")

case_shape_panels <- unlist(
  lapply(seq_along(case_panel_names), \(i) {
    pollutant_name <- names(case_panel_names)[i]
    list(
      case_histogram_panel(pollutant_name, 3 * i - 2, case_panel_names[[i]]),
      case_qq_panel(pollutant_name, "Lognormal", 3 * i - 1, case_panel_names[[i]]),
      case_qq_panel(pollutant_name, "Normal", 3 * i, case_panel_names[[i]])
    )
  }),
  recursive = FALSE
)

# The title must hold under every check. A check that leaves a group unchanged has no row, so that group keeps its main row
group_shape_range <- function(check_name) {
  check_rows <- shape_summary %>%
    filter(scope == "Case study", pollutant != "SO2", site_set == check_name)

  case_main_shapes %>%
    filter(pollutant != "SO2") %>%
    anti_join(check_rows, by = c("pollutant", "site_group")) %>%
    bind_rows(check_rows) %>%
    summarise(
      spread_ratio = max(spread_factor_median) / min(spread_factor_median),
      quantile_skew_range = max(log_quantile_skew_median) - min(log_quantile_skew_median),
      .by = pollutant
    ) %>%
    mutate(site_set = check_name)
}

case_check_names <- as.character(unique(shape_summary$site_set[shape_summary$scope == "Case study"]))

group_shape_ranges <- bind_rows(lapply(case_check_names, group_shape_range))

case_ozone_shapes <- case_main_shapes %>%
  filter(pollutant == "Ozone")

dfw_ozone_log_skew <- case_ozone_shapes$log_skewness_median[case_ozone_shapes$site_group == "Dallas-Fort Worth"]

houston_ozone_log_skew <- case_ozone_shapes$log_skewness_median[case_ozone_shapes$site_group != "Dallas-Fort Worth"]

# Ozone's log skew once readings below the detection limit are set aside in every group, and how few readings those are
ozone_case_days <- case_ordinary_shape_days %>%
  filter(pollutant == "Ozone")

ozone_trimmed_skews <- ozone_case_days %>%
  filter(value_fit >= very_low_ozone_ppm) %>%
  summarise(log_skewness = moments::skewness(log(value_fit)), .by = c(site_group, site_id)) %>%
  summarise(trimmed_log_skewness = median(log_skewness), .by = site_group)

dfw_ozone_trimmed_skew <- ozone_trimmed_skews$trimmed_log_skewness[ozone_trimmed_skews$site_group == "Dallas-Fort Worth"]

houston_ozone_trimmed_skew <- ozone_trimmed_skews$trimmed_log_skewness[ozone_trimmed_skews$site_group != "Dallas-Fort Worth"]

dfw_very_low_days <- ozone_case_days %>%
  filter(site_group == "Dallas-Fort Worth", value_fit < very_low_ozone_ppm)

very_low_days_all_groups <- ozone_case_days %>%
  filter(value_fit < very_low_ozone_ppm) %>%
  count(date_local, name = "n_sites") %>%
  arrange(desc(n_sites))

print(as.data.frame(ozone_trimmed_skews))

print(as.data.frame(very_low_days_all_groups))

print(as.data.frame(arrange(group_shape_ranges, desc(spread_ratio)) %>% slice_head(n = 3)))

# How often a lognormal beats a normal curve for ozone, year-round and by season
ozone_closer_sites <- function(check_name) {
  case_site_shapes[[check_name]] %>%
    filter(pollutant == "Ozone") %>%
    summarise(n_sites = n(), n_lognormal_closer = sum(mean_miss_lognormal < mean_miss_normal), .by = site_group)
}

ozone_year_round <- ozone_closer_sites("Ordinary days")

ozone_warm <- ozone_closer_sites("Warm season")

ozone_cool <- ozone_closer_sites("Cool season")

houston_year_round <- ozone_year_round %>%
  filter(site_group != "Dallas-Fort Worth")

dfw_year_round <- ozone_year_round %>%
  filter(site_group == "Dallas-Fort Worth")

houston_warm <- ozone_warm %>%
  filter(site_group != "Dallas-Fort Worth")

dfw_warm <- ozone_warm %>%
  filter(site_group == "Dallas-Fort Worth")

bind_rows(
  mutate(ozone_year_round, season = "Year-round"),
  mutate(ozone_warm, season = "Warm"),
  mutate(ozone_cool, season = "Cool")
) %>%
  as.data.frame() %>%
  print()

stopifnot(
  "Spread factors and quantile skews sit close across the groups under every check, as the title says" =
    all(group_shape_ranges$spread_ratio < 1.15) && all(group_shape_ranges$quantile_skew_range < 0.15),
  "A normal curve is closer at every case-study ozone site in the cool season, as the subtitle says" = sum(ozone_cool$n_lognormal_closer) == 0,
  "A lognormal is closer at most Houston ozone sites in the warm season, as the subtitle says" =
    sum(houston_warm$n_lognormal_closer) / sum(houston_warm$n_sites) > 0.75,
  "Dallas-Fort Worth ozone splits in the warm season, as the subtitle says" = dfw_warm$n_lognormal_closer == dfw_warm$n_sites / 2,
  "Year-round, a lognormal is closer at every Houston ozone site and at no Dallas-Fort Worth site" =
    all(houston_year_round$n_lognormal_closer == houston_year_round$n_sites) && dfw_year_round$n_lognormal_closer == 0,
  "Every case-study ozone monitor has the detection limit in CONFIG" = all(ozone_case_days$federal_mdl == very_low_ozone_ppm),
  "Readings below the limit are a tiny share of Dallas-Fort Worth ozone and halve its log skew gap to Houston, as the footer says" =
    nrow(dfw_very_low_days) / sum(ozone_case_days$site_group == "Dallas-Fort Worth") < 0.005 &&
    all(dfw_ozone_log_skew < houston_ozone_log_skew - 0.5) &&
    mean(houston_ozone_trimmed_skew) - dfw_ozone_trimmed_skew <= 0.6 * (mean(houston_ozone_log_skew) - dfw_ozone_log_skew)
)

# Deer Park #2 SO2: half the detection limit lands on the same value as a common reading, so one value holds many days
deer_park_so2_days <- case_ordinary_shape_days %>%
  filter(pollutant == "SO2")

deer_park_so2_top <- deer_park_so2_days %>%
  count(value_fit, sort = TRUE) %>%
  slice_head(n = 1)

stopifnot(
  "SO2 in the case study is one site" = n_distinct(deer_park_so2_days$site_id) == 1,
  "The most common Deer Park #2 SO2 value is its filled-in value" =
    isTRUE(all.equal(deer_park_so2_top$value_fit, mdl_fraction * unique(deer_park_so2_days$federal_mdl)))
)

case_shape_header <- chart_header(
  "FIGURE 3.2  /  CASE-STUDY SHAPE  /  FIVE-YEAR SITES",
  "The three groups have similar shapes",
  sprintf(
    str_c(
      "Spread and middle-range skew sit close in each pollutant. Ozone's closest curve shifts with the\n",
      "season: normal in cool months at all %d sites, lognormal in warm months at %d of %d Houston\n",
      "sites, and an even split in Dallas-Fort Worth."
    ),
    sum(ozone_cool$n_sites), sum(houston_warm$n_lognormal_closer), sum(houston_warm$n_sites)
  ),
  key = tribble(
    ~mark,    ~colour,                                      ~label,
    "square", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "square", site_group_colours[["Houston other"]],        "Houston other",
    "square", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",
    "bar",    chart_ink[["primary"]],                       "Dashed: a perfect fit"
  )
)

case_shape_footer <- chart_footer(sprintf(
  str_c(
    "EPA AQS, ordinary days, five-year sites: PM2.5 %s, ozone %s, NO2 %s in the order of the key. Houston\n",
    "other PM2.5 is Aldine alone. SO2 is Deer Park #2 alone, with %.1f%% of days at %.1f ppb, half its detection limit.\n",
    "Dallas-Fort Worth ozone's log skew of %.2f leans on %d readings on %d dates below the %.0f ppb limit. Q-Q: miss in SDs."
  ),
  str_c(case_main_shapes$n_sites[case_main_shapes$pollutant == "PM2.5"], collapse = "/"),
  str_c(case_main_shapes$n_sites[case_main_shapes$pollutant == "Ozone"], collapse = "/"),
  str_c(case_main_shapes$n_sites[case_main_shapes$pollutant == "NO2"], collapse = "/"),
  100 * deer_park_so2_top$n / nrow(deer_park_so2_days),
  deer_park_so2_top$value_fit,
  dfw_ozone_log_skew,
  nrow(dfw_very_low_days),
  n_distinct(dfw_very_low_days$date_local),
  1000 * very_low_ozone_ppm
))

case_shape_figure <- chart_compose(case_shape_header, case_shape_panels, case_shape_footer, ncol = 3)

case_shape_path <- file.path(figures_dir, "3.02_case_study_shape.png")

save_started <- Sys.time()

ggsave(case_shape_path, case_shape_figure, width = 6.5, height = 8.6, dpi = 300)

stopifnot(
  "3.02_case_study_shape.png was written (close any viewer of it and rerun this step)" = file.mtime(case_shape_path) >= save_started - 2
)

# Four CSV records: one row per site, medians under each check, and the numbers behind both figures
shape_site_record <- site_shapes %>%
  select(
    pollutant, site_id, local_site_name, state_name, region, site_group, n_days, pct_filled_in, pct_top_value, skewness, kurtosis,
    log_skewness, log_kurtosis, log_quantile_skew, spread_factor, p99_over_normal, p99_over_lognormal, p05_over_lognormal,
    pct_days_off_lognormal, mean_miss_normal, mean_miss_lognormal, largest_miss_normal, largest_miss_lognormal,
    normal_p01_is_negative
  ) %>%
  arrange(pollutant, site_id) %>%
  mutate(across(where(is.double), \(x) signif(x, 4)))

shape_records <- list(
  distribution_shape_sites = shape_site_record,
  distribution_shape_summary = mutate(shape_summary, across(where(is.double), \(x) signif(x, 4))),
  distribution_qq_points = mutate(qq_points, across(where(is.double), \(x) signif(x, 4))),
  distribution_shape_histograms = mutate(shape_histograms, across(c(pct_of_days, pct_lognormal), \(x) signif(x, 4)))
)

save_records(shape_records, records_dir)

shape_measure_descriptions <- c(
  "skewness" = "skewness of the fitting values; 0 for a normal curve",
  "kurtosis" = "kurtosis of the fitting values (Pearson form); 3 for a normal curve",
  "log_skewness" = "skewness after taking logs; 0 for a lognormal curve",
  "log_kurtosis" = "kurtosis after taking logs; 3 for a lognormal curve",
  "log_quantile_skew" = "(P90 + P10 - 2 x P50) / (P90 - P10) of the logs; 0 when symmetric, and a few extreme days cannot drive it",
  "spread_factor" = "exp(SD of the logs): how many times above or below its typical level a site usually swings",
  "p99_over_normal" = "actual 99th percentile / the 99th percentile of a normal curve with the same mean and SD",
  "p99_over_lognormal" = "actual 99th percentile / the 99th percentile of a lognormal curve with the same log mean and SD",
  "p05_over_lognormal" = "actual 5th percentile / the 5th percentile of a lognormal curve with the same log mean and SD",
  "pct_days_off_lognormal" = "% of days the site's own lognormal curve puts in the wrong quarter-log2 bin",
  "pct_top_value" = "% of days on the most common value",
  "pct_filled_in" = "% of days at or below zero, filled in with half the detection limit"
)

shape_summary_statistics <- c(
  "median" = "Median across sites of ",
  "q1" = "25th percentile across sites of ",
  "q3" = "75th percentile across sites of "
)

shape_summary_measure_rows <- tibble(
  measure = rep(names(shape_measure_descriptions), each = length(shape_summary_statistics)),
  statistic = rep(names(shape_summary_statistics), times = length(shape_measure_descriptions))
) %>%
  mutate(column = str_c(measure, "_", statistic)) %>%
  mutate(label = unname(shape_summary_statistics[statistic])) %>%
  mutate(description = str_c(label, shape_measure_descriptions[measure])) %>%
  mutate(table = "distribution_shape_summary") %>%
  select(table, column, description)

shape_dictionary <- bind_rows(
  tribble(
    ~table,                     ~column,                  ~description,
    "distribution_shape_sites", "pollutant",              "PM2.5, Ozone, NO2, SO2 or CO",
    "distribution_shape_sites", "site_id",                "AQS site ID; five-year sites outside the near-zero rule",
    "distribution_shape_sites", "local_site_name",        "Site name given by the reporting agency; can be NA",
    "distribution_shape_sites", "state_name",             "State or territory name",
    "distribution_shape_sites", "region",                 "West (Census West region) or East (every other state or territory), for the PM2.5 check",
    "distribution_shape_sites", "site_group",             "Case-study group; NA outside the case study",
    "distribution_shape_sites", "n_days",                 "Ordinary days at the site",
    "distribution_shape_sites", "normal_p01_is_negative", "TRUE when a normal curve with the site's mean and SD puts P1 below zero",
    "distribution_shape_sites", "mean_miss_normal",       "Mean miss in SDs across nine percentiles from the site's normal curve",
    "distribution_shape_sites", "mean_miss_lognormal",    "Mean miss in SDs across nine percentiles from the site's lognormal curve",
    "distribution_shape_sites", "largest_miss_normal",    "Largest miss in SDs at any of the nine percentiles from the normal curve",
    "distribution_shape_sites", "largest_miss_lognormal", "Largest miss in SDs at any of the nine percentiles from the lognormal curve"
  ),
  tibble(
    column = names(shape_measure_descriptions),
    description = str_c("At this site: ", shape_measure_descriptions),
    table = "distribution_shape_sites"
  ),
  tribble(
    ~table,                       ~column,                         ~description,
    "distribution_shape_summary", "scope",                         "National (all sites outside the near-zero rule) or Case study (per group)",
    "distribution_shape_summary", "pollutant",                     "PM2.5, Ozone, NO2, SO2 or CO; CO is national only",
    "distribution_shape_summary", "site_group",                    "Case-study group; NA in national rows",
    "distribution_shape_summary", "site_set",                      "Ordinary days (main run), All days, or a check run on ordinary days",
    "distribution_shape_summary", "n_sites",                       "Sites in the row",
    "distribution_shape_summary", "n_site_days",                   "Site-days in the row",
    "distribution_shape_summary", "pct_sites_log_nearer_symmetry", "% of sites whose skew is closer to zero after taking logs",
    "distribution_shape_summary", "pct_sites_normal_p01_negative", "% of sites where a normal curve puts the 1st percentile below zero",
    "distribution_shape_summary", "pct_sites_lognormal_closer",    "% of sites with a smaller mean miss from a lognormal than from a normal curve",
    "distribution_shape_summary", "pct_sites_lognormal_close",     "% of sites where no percentile misses the lognormal by more than 0.25 SDs",
    "distribution_shape_summary", "pct_sites_normal_close",        "% of sites where no percentile misses the normal curve by more than 0.25 SDs"
  ),
  shape_summary_measure_rows,
  tribble(
    ~table,                   ~column,             ~description,
    "distribution_qq_points", "scope",             "National or Case study; main run on ordinary days",
    "distribution_qq_points", "pollutant",         "PM2.5, Ozone, NO2, SO2 or CO; CO is national only",
    "distribution_qq_points", "site_group",        "Case-study group; NA in national rows",
    "distribution_qq_points", "reference",         "Normal (plain values) or Lognormal (logs of the values)",
    "distribution_qq_points", "percentile",        "Percentile compared",
    "distribution_qq_points", "theoretical_z",     "SDs from the mean that a perfect curve puts this percentile",
    "distribution_qq_points", "n_sites",           "Sites summarised",
    "distribution_qq_points", "median_observed_z", "Median across sites of the SDs from the mean this percentile actually sits",
    "distribution_qq_points", "q1_observed_z",     "25th percentile across sites of those SDs",
    "distribution_qq_points", "q3_observed_z",     "75th percentile across sites of those SDs"
  ),
  tribble(
    ~table,                          ~column,         ~description,
    "distribution_shape_histograms", "scope",         "National or Case study; main run on ordinary days",
    "distribution_shape_histograms", "pollutant",     "PM2.5, Ozone, NO2, SO2 or CO; CO is national only",
    "distribution_shape_histograms", "site_group",    "Case-study group; NA in national rows",
    "distribution_shape_histograms", "n_sites",       "Sites summarised; each counts once",
    "distribution_shape_histograms", "bin",           "Lower edge of the bin in log2 of value / site median",
    "distribution_shape_histograms", "ratio_lower",   "Lower edge of the bin as a multiple of the site median",
    "distribution_shape_histograms", "ratio_upper",   "Upper edge of the bin as a multiple of the site median",
    "distribution_shape_histograms", "is_open_ended", "TRUE for the two end bins, which also hold days beyond them",
    "distribution_shape_histograms", "pct_of_days",   "% of days in the bin, averaged across sites",
    "distribution_shape_histograms", "pct_lognormal", "% of days each site's own lognormal curve puts in the bin, averaged across sites"
  )
)

# Stops on a saved column without a description, or a description of a column that was not saved
shape_dictionary <- document_tables(shape_records, shape_dictionary)

replace_own_rows(shape_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(shape_days, ordinary_shape_days, case_shape_days, case_site_shapes)
invisible(gc())
