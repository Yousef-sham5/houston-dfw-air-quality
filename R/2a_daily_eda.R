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

source(here("R", "utils.R")) # study_years, region_lookup, read helpers, naaqs_statistics(), monthly_profile(), save helpers, chart theme

load_chart_fonts()



# CONFIG ----
processed_dir <- here("data", "processed")

pollutant_levels <- c("PM2.5", "Ozone", "NO2", "SO2", "CO")

# CO stays out of the case-study checkpoint: Harris County has one five-year CO site and Dallas-Fort Worth has none
case_study_pollutants <- c("PM2.5", "Ozone", "NO2", "SO2")

# Group of every Harris site, set by 1c from its distance to the land-cut Ship Channel
harris_groups_path <- here("data", "reference", "harris_site_channel_distance.csv")

# Houston North Loop, Houston Southwest Freeway, Dallas LBJ Freeway, Fort Worth California Parkway North
near_road_ids <- c(
  "48-201-1052",
  "48-201-1066",
  "48-113-1067",
  "48-439-1053"
)

parameter_codes <- tribble(
  ~pollutant, ~parameter_code,
  "PM2.5",    88101L,
  "Ozone",    44201L,
  "NO2",      42602L,
  "SO2",      42401L,
  "CO",       42101L
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels))

# Primary standards in their own units and forms. Each site-year is screened on its own, which is not an EPA
# design value (those average three years). Values are rounded as the standard specifies before comparing:
# ozone truncated to 3 decimals (Appendix U 3(e)), PM2.5 to 0.1 and 1 (Appendix N 4.3), NO2 and SO2 to whole ppb
# (Appendices S 4.2(c) and T 4.1(c)) and CO to whole ppm (50.8(d)), with halves rounded up
naaqs <- tribble(
  ~pollutant, ~standard, ~level, ~digits, ~rounding,  ~units_of_measure,             ~form,
  "Ozone",    "8-hour",  0.070,  3,       "truncate", "Parts per million",           "4th-highest daily maximum 8-hour average",
  "PM2.5",    "24-hour", 35,     0,       "half up",  "Micrograms/cubic meter (LC)", "98th percentile of daily means",
  "PM2.5",    "Annual",  9.0,    1,       "half up",  "Micrograms/cubic meter (LC)", "Mean of the four quarterly means",
  "NO2",      "1-hour",  100,    0,       "half up",  "Parts per billion",           "98th percentile of daily maximum 1-hour values",
  "SO2",      "1-hour",  75,     0,       "half up",  "Parts per billion",           "99th percentile of daily maximum 1-hour values",
  "CO",       "8-hour",  9,      0,       "half up",  "Parts per million",           "2nd-highest daily maximum 8-hour average"
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels))

# Rank of the annual 98th and 99th percentile in a site-year's values sorted from highest, by days with data
# (Table 1 of Appendices N and S for the 98th, Table 1 of Appendix T for the 99th)
percentile_ranks <- tribble(
  ~percentile, ~min_days, ~max_days, ~rank,
  98,          1,         50,        1,
  98,          51,        100,       2,
  98,          101,       150,       3,
  98,          151,       200,       4,
  98,          201,       250,       5,
  98,          251,       300,       6,
  98,          301,       350,       7,
  98,          351,       366,       8,
  99,          1,         100,       1,
  99,          101,       200,       2,
  99,          201,       300,       3,
  99,          301,       366,       4
)

# Which value of the sorted site-year each short-term standard uses: a fixed rank, or a percentile rank from above
naaqs_ranks <- tribble(
  ~pollutant, ~fixed_rank, ~percentile,
  "Ozone",    4,           NA,
  "PM2.5",    NA,          98,
  "NO2",      NA,          98,
  "SO2",      NA,          99,
  "CO",       2,           NA
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels))

# The annual PM2.5 level before EPA's 2024 rule. Screening uses the current 9.0 in every year (table above); the old
# level is only used to count sites that would have passed before the change
pm25_annual_old_level <- 12.0

# First daily value on the new method at monitors whose method changed inside the study window.
# Harvard Street's first hourly value on method 186 is 2024-04-22; its first complete day is 2024-04-23.
# Clinton kept its FRM filter and added a T640X beside it, so its averaged site-days mix both from that date
method_changes <- tribble(
  ~site_id,      ~pollutant, ~new_method_code, ~change_date,
  "48-201-0417", "NO2",      "186",            "2024-04-23",
  "48-201-0416", "NO2",      "186",            "2023-11-09",
  "48-201-1039", "PM2.5",    "738",            "2023-03-17",
  "48-201-0066", "Ozone",    "087",            "2024-04-02",
  "48-201-1035", "PM2.5",    "638",            "2024-10-16"
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels)) %>%
  mutate(change_date = ymd(change_date))

# Teledyne T640 and T640X PM2.5 monitors: firmware-corrected (636, 638) and EPA-corrected (736, 738) codes
t640_method_codes <- c("636", "638", "736", "738")

# Labels 1a builds in code rather than reading from events.csv
fireworks_events <- c("July 4 fireworks", "New Year fireworks")

# January to February 2021 and December 2025 are the only parts of their winters inside the window
partial_winter_years <- c(min(study_years), max(study_years) + 1)

# Census Bureau West region (AK, AZ, CA, CO, HI, ID, MT, NV, NM, OR, UT, WA, WY), for the West and East split of peak
# months in section 5
western_state_codes <- c("02", "04", "06", "08", "15", "16", "30", "32", "35", "41", "49", "53", "56")

# Weekday holidays from April to October that section 6 leaves out of the weekday group, since NO2 on them is closer to a
# Sunday than to a weekday: Memorial Day (last Monday of May), Independence Day as observed (Friday when July 4 is a
# Saturday, Monday when it is a Sunday) and Labor Day (first Monday of September)
weekday_holidays <- tibble(year = study_years) %>%
  mutate(july_4 = make_date(year, 7, 4)) %>%
  mutate(`Memorial Day` = floor_date(make_date(year, 5, 31), "week", week_start = 1)) %>%
  mutate(`Independence Day` = july_4 + case_when(wday(july_4, week_start = 1) == 6 ~ -1, wday(july_4, week_start = 1) == 7 ~ 1, .default = 0)) %>%
  mutate(`Labor Day` = floor_date(make_date(year, 9, 7), "week", week_start = 1)) %>%
  select(-july_4) %>%
  pivot_longer(-year, names_to = "holiday", values_to = "date_local")

stopifnot(
  "1c has written the Harris site groups (run 1c first)" = file.exists(harris_groups_path),
  "Near-road IDs are in the three case-study counties" = all(str_sub(near_road_ids, 1, 6) %in% region_lookup$county_id),
  "Case-study pollutants are daily pollutants other than CO" = setequal(case_study_pollutants, setdiff(pollutant_levels, "CO")),
  "One parameter code per pollutant" = setequal(parameter_codes$pollutant, pollutant_levels),
  "Every pollutant has a NAAQS row" = setequal(naaqs$pollutant, pollutant_levels),
  "Each percentile rank table covers 1 to 366 days without gaps" = all(vapply(
    split(percentile_ranks, percentile_ranks$percentile),
    \(t) identical(as.numeric(unlist(Map(seq, t$min_days, t$max_days))), as.numeric(1:366)),
    logical(1)
  )),
  "Every pollutant has one short-term rank rule" =
    setequal(naaqs_ranks$pollutant, pollutant_levels) && all(is.na(naaqs_ranks$fixed_rank) != is.na(naaqs_ranks$percentile)),
  "The old annual PM2.5 level is above the current one" = pm25_annual_old_level > naaqs$level[naaqs$standard == "Annual"],
  "Partial winters are 2021 and 2026" = identical(partial_winter_years, c(2021, 2026)),
  "The West region has 13 unique two-digit state codes" =
    length(unique(western_state_codes)) == 13 && all(str_detect(western_state_codes, "^\\d{2}$")),
  "Three holidays in each study year, all on weekdays" =
    nrow(weekday_holidays) == 3 * length(study_years) && all(wday(weekday_holidays$date_local, week_start = 1) <= 5),
  "Holiday dates match the federal calendar" =
    all(ymd(c("2021-05-31", "2021-07-05", "2023-07-04", "2025-05-26", "2025-09-01")) %in% weekday_holidays$date_local)
)



# 1. ONE ROW PER SITE AND DAY ----
aqs_long_clean <- read_rds(file.path(processed_dir, "aqs_long_clean.rds"))

sites <- read_rds(file.path(processed_dir, "sites.rds"))

site_coverage <- read_rds(file.path(processed_dir, "site_coverage.rds"))

input_files <- c("aqs_long_clean.rds", "sites.rds", "site_coverage.rds")

input_check <- read_csv(manifest_path, col_types = manifest_col_types) %>%
  filter(file %in% input_files) %>%
  mutate(md5_on_disk = unname(tools::md5sum(file.path(processed_dir, file))))

stopifnot(
  "The manifest lists the three daily checkpoints" = setequal(input_check$file, input_files),
  "The daily checkpoints match the manifest (rerun 1a if not)" = all(input_check$md5 == input_check$md5_on_disk),
  "aqs_long_clean has the manifest's row count" =
    nrow(aqs_long_clean) == input_check$rows[input_check$file == "aqs_long_clean.rds"],
  "Pollutant levels match the daily table" = identical(levels(aqs_long_clean$pollutant), pollutant_levels),
  "Every near-road site is in sites.rds" = all(near_road_ids %in% sites$site_id)
)

method_types <- read_methods_ref() %>%
  distinct(parameter_code, method_code, method_type)

stopifnot(
  "One FRM/FEM type per parameter and method code" =
    !anyDuplicated(select(method_types, parameter_code, method_code))
)

daily_instruments <- aqs_long_clean %>%
  left_join(parameter_codes, by = "pollutant", relationship = "many-to-one") %>%
  left_join(method_types, by = c("parameter_code", "method_code"), relationship = "many-to-one")

rm(aqs_long_clean)
invisible(gc())

# PM2.5 is judged on its daily mean, the gases on their daily maximum, in original units
daily_instruments <- daily_instruments %>%
  mutate(value = if_else(pollutant == "PM2.5", arithmetic_mean, first_max_value))

# Sorting puts each site-day's instruments next to each other, so site-days can be numbered and counted in one
# pass. Grouping 5 million site-days with group_by() takes minutes
daily_instruments <- daily_instruments %>%
  arrange(pollutant, site_id, date_local)

daily_instruments <- daily_instruments %>%
  mutate(is_new_site_day = pollutant != lag(pollutant) | site_id != lag(site_id) | date_local != lag(date_local)) %>%
  mutate(is_new_site_day = coalesce(is_new_site_day, TRUE)) %>%
  mutate(site_day_id = cumsum(is_new_site_day)) %>%
  mutate(n_instruments = tabulate(site_day_id)[site_day_id])

# An independent count on every row: each row's site-day is matched by a text key, which does not rely on the sort
site_day_key <- str_c(daily_instruments$pollutant, daily_instruments$site_id, daily_instruments$date_local)

site_day_index <- match(site_day_key, unique(site_day_key))

stopifnot(
  "Instrument counts match an independent count on every row" =
    identical(tabulate(site_day_index)[site_day_index], daily_instruments$n_instruments)
)

rm(site_day_key, site_day_index)

stopifnot(
  "Every instrument-day has an FRM or FEM method type" = all(daily_instruments$method_type %in% c("FRM", "FEM")),
  "Every instrument-day has a value" = !anyNA(daily_instruments$value)
)

method_change_check <- method_changes %>%
  left_join(
    daily_instruments %>%
      semi_join(method_changes, by = c("site_id", "pollutant")) %>%
      group_by(site_id, pollutant, method_code) %>%
      summarise(first_date = min(date_local), .groups = "drop"),
    by = c("site_id", "pollutant", "new_method_code" = "method_code"),
    relationship = "one-to-one"
  )

print(method_change_check)

stopifnot(
  "Each listed method change starts on its listed date" =
    all(method_change_check$first_date == method_change_check$change_date)
)

# Rows of one site-day sit together, so a label that differs from the row above within the same site-day is a conflict
collocated_label_conflicts <- daily_instruments %>%
  mutate(label = coalesce(event_name, "")) %>%
  mutate(previous_label = lag(label)) %>%
  filter(!is_new_site_day, label != previous_label)

stopifnot("Collocated instruments never carry two different event labels" = nrow(collocated_label_conflicts) == 0)

# Columns that hold one value per site and day, so they survive the averaging unchanged
site_day_columns <- c(
  "pollutant", "site_id", "state_code", "county_code", "date_local", "year", "month", "year_month",
  "day_of_year", "season", "season_year", "day_of_week", "is_weekend", "units_of_measure", "event_name",
  "n_instruments"
)

single_instrument_days <- daily_instruments %>%
  filter(n_instruments == 1) %>%
  mutate(method_types = method_type) %>%
  mutate(is_agency_event_flagged = event_type == "Included") %>%
  select(site_day_id, all_of(site_day_columns), method_types, value, is_agency_event_flagged)

# Collocated instruments are averaged per site and day (decision P13). A day with both kinds reads "FEM+FRM".
# rowsum() totals each site-day's readings and counts in one pass, where a grouped summarise() takes about a minute
collocated_rows <- daily_instruments %>%
  filter(n_instruments > 1)

collocated_totals <- rowsum(
  cbind(
    value_total = collocated_rows$value,
    n_fem = collocated_rows$method_type == "FEM",
    n_frm = collocated_rows$method_type == "FRM",
    n_included = collocated_rows$event_type == "Included"
  ),
  group = collocated_rows$site_day_id
)

collocated_values <- as_tibble(collocated_totals) %>%
  mutate(site_day_id = as.integer(rownames(collocated_totals))) %>%
  mutate(value = value_total / (n_fem + n_frm)) %>%
  mutate(method_types = case_when(n_fem > 0 & n_frm > 0 ~ "FEM+FRM", n_fem > 0 ~ "FEM", .default = "FRM")) %>%
  mutate(is_agency_event_flagged = n_included > 0) %>%
  select(site_day_id, method_types, value, is_agency_event_flagged)

collocated_days <- collocated_rows %>%
  distinct(site_day_id, .keep_all = TRUE) %>%
  select(site_day_id, all_of(site_day_columns)) %>%
  inner_join(collocated_values, by = "site_day_id", relationship = "one-to-one")

daily_sites <- bind_rows(single_instrument_days, collocated_days) %>%
  arrange(site_day_id) %>%
  select(-site_day_id)

rm(single_instrument_days, collocated_rows, collocated_totals, collocated_values, collocated_days)
invisible(gc())

daily_sites <- daily_sites %>%
  left_join(site_coverage, by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
  mutate(is_five_year = n_years_active == length(study_years))

daily_sites <- daily_sites %>%
  left_join(
    select(sites, site_id, local_site_name, state_name, cbsa_name),
    by = "site_id",
    relationship = "many-to-one"
  )

daily_sites <- daily_sites %>%
  mutate(
    event_class = case_when(
      is.na(event_name) ~ "None",
      event_name %in% fireworks_events ~ "Fireworks",
      .default = "Event"
    )
  ) %>%
  mutate(event_class = factor(event_class, levels = c("None", "Event", "Fireworks")))

daily_sites <- daily_sites %>%
  mutate(is_full_season = !(season == "Winter" & season_year %in% partial_winter_years))

site_days_expected <- max(daily_instruments$site_day_id)

unlisted_event_names <- daily_sites %>%
  filter(!is.na(event_name)) %>%
  distinct(event_name) %>%
  filter(!event_name %in% read_events()$event_name)

partial_winter_months <- daily_sites %>%
  filter(!is_full_season) %>%
  distinct(year, month)

stopifnot(
  "One row per pollutant, site and day" = nrow(daily_sites) == site_days_expected,
  "Every instrument-day is counted once" = sum(daily_sites$n_instruments) == nrow(daily_instruments),
  "Every site-day has a value" = !anyNA(daily_sites$value),
  "Every site-pollutant has a coverage count" = !anyNA(daily_sites$n_years_active),
  "Every site-day has site metadata" = !anyNA(daily_sites$state_name),
  "Only fireworks labels come from outside events.csv" = setequal(unlisted_event_names$event_name, fireworks_events),
  "Partial winters are Jan-Feb 2021 and Dec 2025 only" =
    setequal(paste(partial_winter_months$year, partial_winter_months$month), c("2021 Jan", "2021 Feb", "2025 Dec"))
)

collocation_summary <- daily_sites %>%
  group_by(pollutant) %>%
  summarise(
    site_days = n(),
    collocated_site_days = sum(n_instruments > 1),
    pct_collocated = round(100 * mean(n_instruments > 1), 1),
    pct_case_study_collocated = round(100 * mean(n_instruments[str_sub(site_id, 1, 6) %in% region_lookup$county_id] > 1), 1),
    five_year_sites = n_distinct(site_id[is_five_year]),
    .groups = "drop"
  )

print(collocation_summary)

daily_sites %>%
  filter(pollutant == "PM2.5") %>%
  count(method_types) %>%
  print()



# 2. HOW THE NETWORK CHANGED ----
# Sites per pollutant and year, the % change from the first to the last year, and the share with all five years
first_year <- as.character(min(study_years))

last_year <- as.character(max(study_years))

sites_per_year <- daily_sites %>%
  distinct(pollutant, year, site_id) %>%
  count(pollutant, year, name = "n_sites")

stopifnot("Every pollutant reports in every study year" = nrow(sites_per_year) == length(pollutant_levels) * length(study_years))

five_year_sites <- daily_sites %>%
  group_by(pollutant) %>%
  summarise(
    n_sites_ever = n_distinct(site_id),
    n_five_year_sites = n_distinct(site_id[is_five_year]),
    .groups = "drop"
  ) %>%
  mutate(pct_five_year = round(100 * n_five_year_sites / n_sites_ever, 1))

site_change <- sites_per_year %>%
  pivot_wider(names_from = year, values_from = n_sites) %>%
  mutate(pct_change = round(100 * (.data[[last_year]] - .data[[first_year]]) / .data[[first_year]], 1)) %>%
  left_join(five_year_sites, by = "pollutant", relationship = "one-to-one")

print(site_change)

# Share of PM2.5 instrument-days measured by FEM monitors, and by T640s in particular, each year
pm25_instrument_mix <- daily_instruments %>%
  filter(pollutant == "PM2.5") %>%
  group_by(year) %>%
  summarise(
    n_instrument_days = n(),
    n_fem = sum(method_type == "FEM"),
    n_frm = sum(method_type == "FRM"),
    n_t640 = sum(method_code %in% t640_method_codes),
    .groups = "drop"
  ) %>%
  mutate(pct_fem = round(100 * n_fem / n_instrument_days, 1)) %>%
  mutate(pct_t640 = round(100 * n_t640 / n_instrument_days, 1))

print(pm25_instrument_mix)

t640_method_types <- daily_instruments %>%
  filter(pollutant == "PM2.5", method_code %in% t640_method_codes) %>%
  distinct(method_type)

stopifnot(
  "Every PM2.5 instrument-day is FEM or FRM" =
    all(pm25_instrument_mix$n_fem + pm25_instrument_mix$n_frm == pm25_instrument_mix$n_instrument_days),
  "T640 monitors are all FEM" = identical(t640_method_types$method_type, "FEM")
)

# FEM minus FRM on site-days where both reported, by year and by event class.
# Each kind is averaged first. A positive gap means FEM read higher. rowsum() totals each site-day's FEM and FRM
# readings in one pass, where a grouped mean over the collocated site-days takes about 19 seconds
pm25_collocated <- daily_instruments %>%
  filter(pollutant == "PM2.5", n_instruments > 1) %>%
  mutate(is_fem = method_type == "FEM")

type_totals <- rowsum(
  cbind(
    fem_total = pm25_collocated$value * pm25_collocated$is_fem,
    n_fem = pm25_collocated$is_fem,
    frm_total = pm25_collocated$value * !pm25_collocated$is_fem,
    n_frm = !pm25_collocated$is_fem
  ),
  group = pm25_collocated$site_day_id
)

fem_frm_pairs <- as_tibble(type_totals) %>%
  mutate(site_day_id = as.integer(rownames(type_totals))) %>%
  filter(n_fem > 0, n_frm > 0) %>%
  mutate(FEM = fem_total / n_fem) %>%
  mutate(FRM = frm_total / n_frm) %>%
  mutate(fem_minus_frm = FEM - FRM)

fem_frm_pairs <- pm25_collocated %>%
  distinct(site_day_id, site_id, date_local, year) %>%
  inner_join(fem_frm_pairs, by = "site_day_id", relationship = "one-to-one") %>%
  select(site_id, date_local, year, FEM, FRM, fem_minus_frm)

fem_frm_pairs <- fem_frm_pairs %>%
  left_join(
    daily_sites %>%
      filter(pollutant == "PM2.5") %>%
      select(site_id, date_local, event_class),
    by = c("site_id", "date_local"),
    relationship = "one-to-one"
  )

fem_frm_gap_by_year <- fem_frm_pairs %>%
  group_by(year) %>%
  summarise(
    n_sites = n_distinct(site_id),
    n_paired_days = n(),
    mean_gap = round(mean(fem_minus_frm), 2),
    median_gap = round(median(fem_minus_frm), 2),
    q25_gap = round(quantile(fem_minus_frm, 0.25), 2),
    q75_gap = round(quantile(fem_minus_frm, 0.75), 2),
    .groups = "drop"
  )

print(fem_frm_gap_by_year)

fem_frm_gap_by_event <- fem_frm_pairs %>%
  group_by(year, event_class) %>%
  summarise(
    n_paired_days = n(),
    mean_gap = round(mean(fem_minus_frm), 2),
    median_gap = round(median(fem_minus_frm), 2),
    .groups = "drop"
  )

print(fem_frm_gap_by_event, n = Inf)

pm25_mixed_site_days <- daily_sites %>%
  filter(pollutant == "PM2.5", method_types == "FEM+FRM") %>%
  nrow()

stopifnot(
  "Every FEM+FRM site-day gives one pair" = nrow(fem_frm_pairs) == pm25_mixed_site_days,
  "Every pair has an event class" = !anyNA(fem_frm_pairs$event_class)
)

# PM2.5 sampling schedule per site-year, from 1a's thresholds on the median gap between the site's sampled days
# (up to 1.5 days is daily, up to 4.5 is 1-in-3)
pm25_schedules <- daily_sites %>%
  filter(pollutant == "PM2.5") %>%
  group_by(site_id, year) %>%
  summarise(
    n_days = n(),
    is_date_ordered = !is.unsorted(date_local),
    median_gap_days = median(as.numeric(diff(date_local))),
    .groups = "drop"
  ) %>%
  mutate(
    schedule = case_when(
      is.na(median_gap_days) ~ "insufficient data",
      median_gap_days <= 1.5 ~ "daily",
      median_gap_days <= 4.5 ~ "1-in-3",
      .default = "1-in-6"
    )
  ) %>%
  mutate(schedule = factor(schedule, levels = c("daily", "1-in-3", "1-in-6", "insufficient data")))

schedule_mix <- pm25_schedules %>%
  count(year, schedule) %>%
  group_by(year) %>%
  mutate(pct_site_years = round(100 * n / sum(n), 1)) %>%
  ungroup()

print(schedule_mix, n = Inf)

schedule_site_years <- schedule_mix %>%
  group_by(year) %>%
  summarise(n_site_years = sum(n), .groups = "drop") %>%
  inner_join(filter(sites_per_year, pollutant == "PM2.5"), by = "year", relationship = "one-to-one")

stopifnot(
  "Sampled days are in date order within every site-year" = all(pm25_schedules$is_date_ordered),
  "Each PM2.5 site-year has one schedule" = all(schedule_site_years$n_site_years == schedule_site_years$n_sites)
)

# Ozone site-years with no December or January data (seasonal monitors), nationally and at the case-study sites
ozone_site_years <- daily_sites %>%
  filter(pollutant == "Ozone") %>%
  group_by(site_id, year) %>%
  summarise(has_winter_data = any(month %in% c("Dec", "Jan")), .groups = "drop")

seasonal_ozone <- ozone_site_years %>%
  group_by(year) %>%
  summarise(
    n_site_years = n(),
    n_seasonal = sum(!has_winter_data),
    .groups = "drop"
  ) %>%
  mutate(pct_seasonal = round(100 * n_seasonal / n_site_years, 1))

print(seasonal_ozone)

case_study_ozone_site_years <- ozone_site_years %>%
  filter(str_sub(site_id, 1, 6) %in% region_lookup$county_id) %>%
  semi_join(
    filter(site_coverage, pollutant == "Ozone", n_years_active == length(study_years)),
    by = "site_id"
  )

ozone_site_counts <- filter(sites_per_year, pollutant == "Ozone")

stopifnot(
  "Ozone site-years match the yearly ozone site counts" = all(seasonal_ozone$n_site_years == ozone_site_counts$n_sites),
  "23 five-year ozone sites in the case-study counties" = n_distinct(case_study_ozone_site_years$site_id) == 23,
  "No five-year case-study ozone site is seasonal" = all(case_study_ozone_site_years$has_winter_data)
)

# Four-panel figure of the site, monitor-mix, sampling and FEM minus FRM results. Teal marks the series each panel is
# about and grey the rest
year_scale <- scale_x_continuous(breaks = study_years)

share_scale <- scale_y_continuous(labels = label_number(suffix = "%"), limits = c(0, 100))

site_change_plot <- site_change %>%
  mutate(pollutant = reorder(pollutant, pct_change)) %>%
  mutate(is_large_drop = pct_change <= -10) %>%
  mutate(label = sprintf("%+.1f%%", pct_change)) %>%
  mutate(label_hjust = if_else(pct_change > 0, -0.3, 1.3))

change_panel <- ggplot(site_change_plot, aes(pct_change, pollutant)) +
  geom_col(aes(fill = is_large_drop), width = 0.42) +
  geom_vline(xintercept = 0, colour = chart_ink[["axis"]], linewidth = 0.35) +
  geom_text(aes(label = label, hjust = label_hjust, colour = is_large_drop), family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt) +
  scale_fill_manual(values = c(`TRUE` = chart_fills[["accent"]], `FALSE` = chart_fills[["other"]]), guide = "none") +
  scale_colour_manual(values = c(`TRUE` = chart_fills[["accent"]], `FALSE` = chart_ink[["muted"]]), guide = "none") +
  scale_x_continuous(labels = label_number(suffix = "%"), breaks = c(-20, -10, 0), expand = expansion(mult = c(0.42, 0.42))) +
  labs(title = "01  SITES REPORTING", subtitle = str_c("Change in sites, ", first_year, " to ", last_year), x = NULL, y = NULL) +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 8)
  )

instrument_mix_plot <- pm25_instrument_mix %>%
  select(year, FEM = pct_fem, T640 = pct_t640) %>%
  pivot_longer(c(FEM, T640), names_to = "share", values_to = "pct") %>%
  mutate(label = str_c(share, " ", pct, "%"))

instrument_mix_ends <- instrument_mix_plot %>%
  filter(year == max(year))

mix_panel <- ggplot(instrument_mix_plot, aes(year, pct, colour = share)) +
  geom_line(linewidth = 0.7) +
  chart_end_label(filter(instrument_mix_ends, share == "FEM"), "year", "pct", "label") +
  chart_end_label(filter(instrument_mix_ends, share == "T640"), "year", "pct", "label", colour = chart_ink[["muted"]]) +
  scale_colour_manual(values = c(FEM = chart_fills[["accent"]], T640 = chart_fills[["other"]]), guide = "none") +
  year_scale +
  share_scale +
  labs(title = "02  INSTRUMENT MIX", subtitle = "Share of PM2.5 instrument-days", x = NULL, y = NULL) +
  theme_aqs()

daily_schedule_plot <- schedule_mix %>%
  filter(schedule == "daily") %>%
  mutate(label = str_c(pct_site_years, "%"))

schedule_panel <- ggplot(daily_schedule_plot, aes(year, pct_site_years)) +
  geom_line(linewidth = 0.7, colour = chart_fills[["accent"]]) +
  chart_end_label(filter(daily_schedule_plot, year == min(year)), "year", "pct_site_years", "label", hjust = 0) +
  chart_end_label(filter(daily_schedule_plot, year == max(year)), "year", "pct_site_years", "label") +
  year_scale +
  share_scale +
  labs(title = "03  SAMPLING", subtitle = "PM2.5 site-years sampled every day", x = NULL, y = NULL) +
  theme_aqs()

gap_by_day_type <- fem_frm_gap_by_event %>%
  filter(event_class != "Fireworks") %>%
  mutate(day_type = if_else(event_class == "Event", "Event days", "Ordinary days")) %>%
  mutate(label = str_c(if_else(day_type == "Event days", "EVENT ", "ORDINARY "), sprintf("%+.1f", median_gap)))

gap_ends <- gap_by_day_type %>%
  filter(year == max(year))

smoke_year <- gap_by_day_type %>%
  filter(day_type == "Event days") %>%
  slice_max(median_gap, n = 1)

stopifnot("The widest event-day gap falls in 2023, the Canadian smoke year the band labels" = identical(smoke_year$year, 2023))

gap_panel <- ggplot(gap_by_day_type, aes(year, median_gap, colour = day_type)) +
  annotate("rect", xmin = smoke_year$year - 0.5, xmax = smoke_year$year + 0.5, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
  annotate(
    "text", x = smoke_year$year, y = Inf, label = "SMOKE YEAR", vjust = 1.6,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_ink[["muted"]]
  ) +
  geom_hline(yintercept = 0, colour = chart_ink[["axis"]], linewidth = 0.35) +
  geom_line(linewidth = 0.7) +
  chart_end_label(filter(gap_ends, day_type == "Event days"), "year", "median_gap", "label") +
  chart_end_label(filter(gap_ends, day_type == "Ordinary days"), "year", "median_gap", "label", colour = chart_ink[["muted"]]) +
  scale_colour_manual(values = c("Event days" = chart_fills[["accent"]], "Ordinary days" = chart_fills[["other"]]), guide = "none") +
  year_scale +
  scale_y_continuous(limits = c(0, ceiling(max(gap_by_day_type$median_gap)) + 0.6), breaks = 0:5) +
  labs(title = "04  MONITOR GAP", subtitle = "FEM reading above FRM, µg/m³", x = NULL, y = NULL) +
  theme_aqs()

ordinary_gap_range <- range(gap_by_day_type$median_gap[gap_by_day_type$day_type == "Ordinary days"])

event_gap_range <- range(gap_by_day_type$median_gap[gap_by_day_type$day_type == "Event days"])

network_header <- chart_header(
  sprintf("FIGURE 2A.1  /  NATIONAL MONITORING NETWORK  /  %s TO %s", first_year, last_year),
  "SO2 and CO sites fell as PM2.5 went automated",
  sprintf(
    str_c(
      "Automated FEM monitors read %.1f to %.1f µg/m³ above FRM filter samplers on ordinary days\n",
      "and %.1f to %.1f µg/m³ above them on smoke, dust and storm days."
    ),
    ordinary_gap_range[1], ordinary_gap_range[2], event_gap_range[1], event_gap_range[2]
  )
)

network_footer <- chart_footer(sprintf(
  "EPA AQS daily data, %s to %s, after Phase 1 cleaning. Monitor gap: median of %s site-days with both\nmonitors. T640 is one FEM model. %s",
  first_year, last_year, format(sum(gap_by_day_type$n_paired_days), big.mark = ","),
  "Event days are events.csv windows; fireworks days are not shown."
))

network_figure <- chart_compose(network_header, list(change_panel, mix_panel, schedule_panel, gap_panel), network_footer)

dir.create(here("figures", "phase2"), recursive = TRUE, showWarnings = FALSE)

network_figure_path <- here("figures", "phase2", "2a.01_network.png")

save_started <- Sys.time()

ggsave(network_figure_path, network_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2a.01_network.png was written (close any viewer of it and rerun this step)" =
    file.mtime(network_figure_path) >= save_started - 2
)

# One long table of the yearly results above, saved as a CSV record in section 14
network_by_year <- bind_rows(
  transmute(sites_per_year, pollutant = as.character(pollutant), year, metric = "n_sites", value = as.numeric(n_sites)),
  transmute(pm25_instrument_mix, pollutant = "PM2.5", year, metric = "pct_fem", value = pct_fem),
  transmute(pm25_instrument_mix, pollutant = "PM2.5", year, metric = "pct_t640", value = pct_t640),
  transmute(fem_frm_gap_by_year, pollutant = "PM2.5", year, metric = "mean_fem_minus_frm_ugm3", value = mean_gap),
  transmute(fem_frm_gap_by_year, pollutant = "PM2.5", year, metric = "median_fem_minus_frm_ugm3", value = median_gap),
  transmute(
    schedule_mix,
    pollutant = "PM2.5", year, metric = str_c("pct_site_years_", str_replace_all(schedule, "[ -]", "_")), value = pct_site_years
  ),
  transmute(seasonal_ozone, pollutant = "Ozone", year, metric = "pct_seasonal_site_years", value = pct_seasonal)
)

duplicate_network_rows <- network_by_year %>%
  count(pollutant, year, metric) %>%
  filter(n > 1)

stopifnot(
  "One network row per pollutant, year and metric" = nrow(duplicate_network_rows) == 0,
  "Every network row has a value" = !anyNA(network_by_year$value)
)



# 3. NATIONAL STATISTICS IN NAAQS FORM ----
# Five-year site-years only: every year of these sites passed 1a's 75% completeness rule
naaqs_site_days <- daily_sites %>%
  filter(is_five_year) %>%
  select(pollutant, site_id, state_name, cbsa_name, year, date_local, value, event_class)

site_year_days <- naaqs_site_days %>%
  count(pollutant, site_id, year, name = "n_days")

site_year_days %>%
  summarise(min_days = min(n_days), median_days = median(n_days), max_days = max(n_days), .by = pollutant) %>%
  print()

stopifnot(
  "Every five-year site-year has at least the 1-in-6 minimum of 46 days" = min(site_year_days$n_days) >= 46,
  "No site-year has more days than the calendar" = max(site_year_days$n_days) <= 366
)

# Each standard's value per site-year, with and without event days. naaqs_statistics() is in utils.R so 2b screens the
# case-study sites with the same rules
naaqs_site_year <- bind_rows(
  naaqs_statistics(naaqs_site_days, naaqs, naaqs_ranks, percentile_ranks) %>%
    mutate(day_set = "All days"),
  naaqs_statistics(filter(naaqs_site_days, event_class == "None"), naaqs, naaqs_ranks, percentile_ranks) %>%
    mutate(day_set = "Without event and fireworks days")
)

duplicate_naaqs_rows <- naaqs_site_year %>%
  count(day_set, pollutant, standard, site_id, year) %>%
  filter(n > 1)

naaqs_site_counts <- naaqs_site_year %>%
  filter(day_set == "All days") %>%
  summarise(n_sites = n_distinct(site_id), .by = pollutant) %>%
  inner_join(five_year_sites, by = "pollutant", relationship = "one-to-one")

stopifnot(
  "One value per day set, standard, site and year" = nrow(duplicate_naaqs_rows) == 0,
  "Every value is filled in" = !anyNA(naaqs_site_year$value_rounded),
  "Site counts match the five-year sites from section 2" = all(naaqs_site_counts$n_sites == naaqs_site_counts$n_five_year_sites)
)

# Median, 90th percentile and share of sites above the level, per standard and year, with and without event days
naaqs_summary <- naaqs_site_year %>%
  summarise(
    n_sites = n(),
    median_value = median(value_rounded),
    p90_value = quantile(value_rounded, 0.9),
    n_above = sum(is_above),
    pct_above = round(100 * mean(is_above), 1),
    .by = c(day_set, pollutant, standard, year)
  ) %>%
  arrange(day_set, pollutant, standard, year)

print(naaqs_summary, n = Inf)

naaqs_summary %>%
  select(day_set, pollutant, standard, year, pct_above) %>%
  pivot_wider(names_from = year, values_from = pct_above) %>%
  print(n = Inf)

# Sites on annual PM2.5 that pass the old 12.0 level but fail the current 9.0, from the quarterly means and from a plain
# mean of days
pm25_plain_annual <- naaqs_site_days %>%
  filter(pollutant == "PM2.5") %>%
  summarise(value = mean(value), .by = c(site_id, year)) %>%
  semi_join(filter(naaqs_site_year, day_set == "All days", standard == "Annual"), by = c("site_id", "year"))

pm25_annual_level <- naaqs$level[naaqs$standard == "Annual"]

pm25_annual_bands <- bind_rows(
  naaqs_site_year %>%
    filter(day_set == "All days", standard == "Annual") %>%
    transmute(method = "Mean of quarterly means", year, value_rounded),
  pm25_plain_annual %>%
    transmute(method = "Plain mean of days", year, value_rounded = round_half_up(value, 1))
) %>%
  summarise(
    n_sites = n(),
    n_pass_old_fail_new = sum(value_rounded > pm25_annual_level & value_rounded <= pm25_annual_old_level),
    n_fail_old = sum(value_rounded > pm25_annual_old_level),
    .by = c(method, year)
  )

print(pm25_annual_bands, n = Inf)

# Three-year screen in the form of an EPA design value: each site's annual value averaged over three consecutive
# years, then rounded as the standard specifies. CO is left out, since its standard is judged one year at a time
design_windows <- tibble(window_end = (min(study_years) + 2):max(study_years)) %>%
  mutate(window = sprintf("%d to %d", window_end - 2, window_end))

naaqs_design_values <- naaqs_site_year %>%
  filter(day_set == "All days", pollutant != "CO") %>%
  cross_join(design_windows) %>%
  filter(between(year, window_end - 2, window_end)) %>%
  summarise(n_years = n(), design_value = mean(value), .by = c(pollutant, standard, site_id, window, window_end)) %>%
  filter(n_years == 3) %>%
  left_join(select(naaqs, pollutant, standard, level, digits, rounding), by = c("pollutant", "standard"), relationship = "many-to-one") %>%
  mutate(design_value = if_else(rounding == "truncate", truncate_to(design_value, digits), round_half_up(design_value, digits))) %>%
  mutate(is_above = design_value > level)

design_value_summary <- naaqs_design_values %>%
  summarise(
    n_sites = n(),
    median_design_value = median(design_value),
    n_above = sum(is_above),
    pct_above = round(100 * mean(is_above), 1),
    .by = c(pollutant, standard, window, window_end)
  ) %>%
  arrange(pollutant, standard, window_end)

stopifnot(
  "Three windows for each of the five standards with design values" = nrow(design_value_summary) == 5 * nrow(design_windows),
  "Every design value averages exactly three years" = all(naaqs_design_values$n_years == 3)
)

design_value_summary %>%
  left_join(
    naaqs_summary %>%
      filter(day_set == "All days") %>%
      select(pollutant, standard, window_end = year, pct_above_final_year = pct_above),
    by = c("pollutant", "standard", "window_end"),
    relationship = "one-to-one"
  ) %>%
  print(n = Inf)

# Six-panel figure of each site's value divided by its standard's level, so 1.0 is the standard in every panel.
# Teal shows the median and middle half of sites with all days, grey the median without event and fireworks days
naaqs_ratios <- naaqs_site_year %>%
  mutate(ratio = value_rounded / level) %>%
  summarise(
    median_ratio = median(ratio),
    q25_ratio = quantile(ratio, 0.25),
    q75_ratio = quantile(ratio, 0.75),
    pct_above = round(100 * mean(is_above), 1),
    .by = c(day_set, pollutant, standard, year)
  )

naaqs_panel_order <- tribble(
  ~pollutant, ~standard, ~statistic,
  "Ozone",    "8-hour",  "4TH-HIGHEST DAY",
  "PM2.5",    "24-hour", "98TH PERCENTILE DAY",
  "PM2.5",    "Annual",  "MEAN OF QUARTERS",
  "NO2",      "1-hour",  "98TH PERCENTILE DAY",
  "SO2",      "1-hour",  "99TH PERCENTILE DAY",
  "CO",       "8-hour",  "2ND-HIGHEST DAY"
) %>%
  mutate(panel_title = str_c(pollutant, " ", standard)) %>%
  mutate(kicker = sprintf("%02d  %s", row_number(), statistic))

stopifnot(
  "The panel order covers every standard once" =
    identical(sort(str_c(naaqs_panel_order$pollutant, naaqs_panel_order$standard)), sort(str_c(naaqs$pollutant, naaqs$standard)))
)

ratio_limit <- ceiling(max(naaqs_ratios$q75_ratio) * 10) / 10

naaqs_panel <- function(panel_pollutant, panel_standard) {
  panel_labels <- filter(naaqs_panel_order, pollutant == panel_pollutant, standard == panel_standard)
  all_days <- filter(naaqs_ratios, pollutant == panel_pollutant, standard == panel_standard, day_set == "All days")
  no_events <- filter(naaqs_ratios, pollutant == panel_pollutant, standard == panel_standard, day_set != "All days")
  final_year <- filter(all_days, year == max(year))
  ggplot(all_days, aes(year, median_ratio)) +
    geom_hline(yintercept = 1, colour = chart_ink[["primary"]], linewidth = 0.35) +
    annotate(
      "text", x = max(study_years) + 0.3, y = 1, label = "STANDARD", hjust = 1, vjust = -0.7,
      family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 1) / .pt, colour = chart_ink[["muted"]]
    ) +
    geom_segment(aes(xend = year, y = q25_ratio, yend = q75_ratio), colour = chart_fills[["accent"]], linewidth = 0.6, alpha = 0.45) +
    geom_point(data = no_events, aes(year + 0.22, median_ratio), colour = chart_fills[["other"]], size = 1.5) +
    geom_point(colour = chart_fills[["accent"]], size = 1.7) +
    year_scale +
    scale_y_continuous(limits = c(0, ratio_limit), breaks = seq(0, ratio_limit, 0.5), labels = label_number(accuracy = 0.1)) +
    labs(
      title = panel_labels$kicker,
      subtitle = panel_labels$panel_title,
      caption = sprintf("%.1f%% OF SITES ABOVE IN %d", final_year$pct_above, final_year$year),
      x = NULL,
      y = NULL
    ) +
    theme_aqs() +
    theme(
      axis.text.x = element_text(size = chart_sizes[["axis"]] - 0.6),
      plot.caption = element_text(
        family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
        hjust = 0, margin = margin(t = 6)
      )
    )
}

naaqs_panels <- Map(naaqs_panel, as.character(naaqs_panel_order$pollutant), naaqs_panel_order$standard)

worst_year <- naaqs_summary %>%
  filter(day_set == "All days", pollutant == "Ozone") %>%
  slice_max(pct_above, n = 1)

worst_year_pm25 <- naaqs_summary %>%
  filter(day_set == "All days", pollutant == "PM2.5", standard == "Annual", year == worst_year$year)

most_missed <- naaqs_summary %>%
  filter(day_set == "All days") %>%
  summarise(mean_pct_above = mean(pct_above), .by = c(pollutant, standard)) %>%
  slice_max(mean_pct_above, n = 2)

stopifnot(
  "Ozone and annual PM2.5 are the two most-missed standards, as the title says" =
    setequal(str_c(most_missed$pollutant, most_missed$standard), c("Ozone8-hour", "PM2.5Annual"))
)

naaqs_header <- chart_header(
  "FIGURE 2A.2  /  NAAQS SCREENING  /  FIVE-YEAR SITES",
  "Ozone and annual PM2.5 are missed most often",
  sprintf(
    str_c(
      "Each site's value for the year divided by the standard's level, so 1.0 is the standard. In %d,\n",
      "%.1f%% of ozone sites and %.1f%% of sites on the annual PM2.5 standard were above it."
    ),
    worst_year$year, worst_year$pct_above, worst_year_pm25$pct_above
  ),
  key = tribble(
    ~mark, ~colour,                          ~label,
    "dot", chart_fills[["accent"]],          "Median site",
    "bar", alpha(chart_fills[["accent"]], 0.45), "Middle half of sites",
    "dot", chart_fills[["other"]],           "Median without event and fireworks days"
  )
)

naaqs_site_note <- naaqs_site_counts %>%
  arrange(pollutant) %>%
  mutate(label = str_c(pollutant, " ", format(n_sites, big.mark = ","))) %>%
  pull(label) %>%
  str_flatten(collapse = ", ")

naaqs_footer <- chart_footer(sprintf(
  str_c(
    "EPA AQS daily data, %s to %s. Single-year screening values for five-year sites, not EPA design values.\n",
    "The year's value: ozone's 4th-highest day, CO's 2nd-highest, or the 98th or 99th percentile day for PM2.5, NO2 and SO2.\n",
    "Five-year sites: %s."
  ),
  first_year, last_year, naaqs_site_note
))

naaqs_figure <- chart_compose(naaqs_header, naaqs_panels, naaqs_footer, ncol = 3)

naaqs_figure_path <- here("figures", "phase2", "2a.02_naaqs_form.png")

save_started <- Sys.time()

ggsave(naaqs_figure_path, naaqs_figure, width = 6.5, height = 6.2, dpi = 300)

stopifnot(
  "2a.02_naaqs_form.png was written (close any viewer of it and rerun this step)" =
    file.mtime(naaqs_figure_path) >= save_started - 2
)

rm(naaqs_site_days, pm25_plain_annual)
invisible(gc())



# 4. EXCEEDANCE SCREENING AND EVENTS ----
# A site-day exceeds when its value, rounded as the standard specifies, is above the short-term level. All sites are
# kept, since rates per 1,000 site-days already allow for a network that changes in size. These are screening counts,
# not violations: the standards allow some days above the level
short_term_levels <- naaqs %>%
  filter(standard != "Annual") %>%
  select(pollutant, standard, level, digits, rounding)

site_day_exceedances <- daily_sites %>%
  select(pollutant, site_id, local_site_name, state_name, cbsa_name, year, date_local, value, event_name, event_class,
         is_agency_event_flagged, is_five_year) %>%
  inner_join(short_term_levels, by = "pollutant", relationship = "many-to-one") %>%
  mutate(value_rounded = if_else(rounding == "truncate", truncate_to(value, digits), round_half_up(value, digits))) %>%
  mutate(is_exceedance = value_rounded > level)

exceedances <- site_day_exceedances %>%
  filter(is_exceedance)

stopifnot(
  "Every site-day has a short-term level" = nrow(site_day_exceedances) == nrow(daily_sites),
  "Every site-day is judged" = !anyNA(site_day_exceedances$is_exceedance)
)

# Exceedance site-days per 1,000 site-days with data, per pollutant and year, for all sites and for five-year sites
exceedance_rates <- bind_rows(
  site_day_exceedances %>%
    summarise(site_days = n(), n_exceedances = sum(is_exceedance), .by = c(pollutant, year)) %>%
    mutate(site_set = "All sites"),
  site_day_exceedances %>%
    filter(is_five_year) %>%
    summarise(site_days = n(), n_exceedances = sum(is_exceedance), .by = c(pollutant, year)) %>%
    mutate(site_set = "Five-year sites")
) %>%
  mutate(per_1000 = round(1000 * n_exceedances / site_days, 2)) %>%
  arrange(site_set, pollutant, year)

exceedance_rates %>%
  select(site_set, pollutant, year, per_1000) %>%
  pivot_wider(names_from = year, values_from = per_1000) %>%
  print(n = Inf)

stopifnot(
  "Rates lie between 0 and 1,000" = all(between(exceedance_rates$per_1000, 0, 1000)),
  "The all-site counts add up to every exceedance" =
    sum(exceedance_rates$n_exceedances[exceedance_rates$site_set == "All sites"]) == nrow(exceedances)
)

# How many exceedances fall on labelled event days and on fireworks days, per pollutant and year, and which events
# contributed most
exceedances_by_class <- exceedances %>%
  count(pollutant, year, event_class) %>%
  complete(pollutant, year, event_class, fill = list(n = 0)) %>%
  pivot_wider(names_from = event_class, values_from = n) %>%
  mutate(total = None + Event + Fireworks) %>%
  mutate(pct_event = if_else(total > 0, round(100 * Event / total, 1), NA_real_)) %>%
  mutate(pct_fireworks = if_else(total > 0, round(100 * Fireworks / total, 1), NA_real_))

print(exceedances_by_class, n = Inf)

top_events <- exceedances %>%
  filter(event_class == "Event") %>%
  count(event_name, pollutant, name = "exceedance_site_days", sort = TRUE)

print(head(top_events, 10))

stopifnot(
  "Every exceedance has exactly one class" = sum(exceedances_by_class$total, na.rm = TRUE) == nrow(exceedances)
)

# Our event labels against EPA's own exceptional-event flag ("Included"), for PM2.5 and ozone exceedances
agency_flag_share <- exceedances %>%
  filter(pollutant %in% c("PM2.5", "Ozone")) %>%
  summarise(n_exceedances = n(), pct_agency_flagged = round(100 * mean(is_agency_event_flagged), 1), .by = c(pollutant, year)) %>%
  arrange(pollutant, year)

print(agency_flag_share)

exceedances %>%
  filter(pollutant %in% c("PM2.5", "Ozone")) %>%
  count(pollutant, event_class, is_agency_event_flagged) %>%
  pivot_wider(names_from = is_agency_event_flagged, values_from = n, values_fill = 0, names_prefix = "agency_flagged_") %>%
  print()

# Where exceedances concentrate: the top states and metros per pollutant (metros with and without event days), and the
# share held by each pollutant's 10 busiest sites
top_states <- exceedances %>%
  count(pollutant, state_name, name = "n_exceedances") %>%
  mutate(pct_of_pollutant = round(100 * n_exceedances / sum(n_exceedances), 1), .by = pollutant) %>%
  slice_max(n_exceedances, n = 3, by = pollutant, with_ties = FALSE)

print(top_states, n = Inf)

top_metros <- exceedances %>%
  filter(!is.na(cbsa_name)) %>%
  summarise(n_all_days = n(), n_ordinary_days = sum(event_class == "None"), .by = c(pollutant, cbsa_name)) %>%
  filter(pollutant %in% c("PM2.5", "Ozone"))

bind_rows(
  slice_max(top_metros, n_all_days, n = 5, by = pollutant, with_ties = FALSE) %>%
    mutate(ranked_by = "All days"),
  slice_max(top_metros, n_ordinary_days, n = 5, by = pollutant, with_ties = FALSE) %>%
    mutate(ranked_by = "Ordinary days only")
) %>%
  arrange(pollutant, ranked_by) %>%
  print(n = Inf)

site_concentration <- exceedances %>%
  count(pollutant, site_id, local_site_name, state_name, name = "n_exceedances") %>%
  arrange(pollutant, desc(n_exceedances)) %>%
  mutate(site_rank = row_number(), .by = pollutant) %>%
  summarise(
    n_sites_with_exceedances = n(),
    pct_at_top_10_sites = round(100 * sum(n_exceedances[site_rank <= 10]) / sum(n_exceedances), 1),
    busiest_site = str_c(local_site_name[1], ", ", state_name[1]),
    busiest_site_exceedances = n_exceedances[1],
    .by = pollutant
  )

print(site_concentration, width = Inf)

# One-line facts: the few NO2 and CO exceedances by state and year, and the check that the missing December 31 ozone
# rows (a 1a known limit) can hardly change the counts
exceedances %>%
  filter(pollutant %in% c("NO2", "CO")) %>%
  count(pollutant, state_name, year) %>%
  print()

ozone_late_december <- exceedances %>%
  filter(pollutant == "Ozone", month(date_local) == 12, day(date_local) >= 29)

ozone_december_31_rows <- daily_sites %>%
  filter(pollutant == "Ozone", month(date_local) == 12, day(date_local) == 31) %>%
  nrow()

cat("Ozone exceedances on Dec 29-30:", nrow(ozone_late_december), " ozone rows on Dec 31:", ozone_december_31_rows, "\n")

stopifnot(
  "No ozone rows on December 31 (1a known limit)" = ozone_december_31_rows == 0,
  "Late-December ozone exceedances are rare" = nrow(ozone_late_december) <= 5
)

# Three-panel figure of exceedance days per 1,000 site-days, split into ordinary, event and fireworks days
day_class_fills <- c(None = chart_fills[["accent"]], Event = chart_fills[["other"]], Fireworks = "#dcdbd4")

figure_pollutants <- tribble(
  ~pollutant, ~kicker,                ~panel_title,
  "PM2.5",    "01  PM2.5 24-HOUR",    "Days above 35 µg/m³",
  "Ozone",    "02  OZONE 8-HOUR",     "Days above 0.070 ppm",
  "SO2",      "03  SO2 1-HOUR",       "Days above 75 ppb"
)

class_rates <- exceedances_by_class %>%
  filter(pollutant %in% figure_pollutants$pollutant) %>%
  inner_join(filter(exceedance_rates, site_set == "All sites"), by = c("pollutant", "year"), relationship = "one-to-one") %>%
  pivot_longer(c(None, Event, Fireworks), names_to = "event_class", values_to = "n_class") %>%
  mutate(event_class = factor(event_class, levels = c("Fireworks", "Event", "None"))) %>%
  mutate(class_per_1000 = 1000 * n_class / site_days)

stopifnot(
  "Class rates add up to each year's rate" = all(abs(
    summarise(class_rates, total = sum(class_per_1000), .by = c(pollutant, year, per_1000)) %>% transmute(total - per_1000) %>% pull()
  ) < 0.01)
)

exceedance_panel <- function(panel_pollutant) {
  panel_labels <- filter(figure_pollutants, pollutant == panel_pollutant)
  panel_data <- filter(class_rates, pollutant == panel_pollutant)
  panel_totals <- distinct(panel_data, year, per_1000)
  peak_event_year <- exceedances_by_class %>%
    filter(pollutant == panel_pollutant) %>%
    slice_max(pct_event, n = 1, with_ties = FALSE)
  panel_caption <- if (peak_event_year$pct_event == 0) {
    "NONE ON EVENT DAYS"
  } else {
    sprintf("%.1f%% ON EVENT DAYS IN %d", peak_event_year$pct_event, peak_event_year$year)
  }
  ggplot(panel_data, aes(year, class_per_1000, fill = event_class)) +
    geom_col(width = 0.55, colour = "white", linewidth = 0.3) +
    geom_text(
      data = panel_totals, aes(year, per_1000, label = sprintf("%.1f", per_1000)), inherit.aes = FALSE, vjust = -0.6,
      family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt, colour = chart_ink[["secondary"]]
    ) +
    scale_fill_manual(values = day_class_fills, guide = "none") +
    year_scale +
    scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
    labs(title = panel_labels$kicker, subtitle = panel_labels$panel_title, caption = panel_caption, x = NULL, y = NULL) +
    theme_aqs() +
    theme(
      axis.text.x = element_text(size = chart_sizes[["axis"]] - 0.6),
      plot.caption = element_text(
        family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
        hjust = 0, margin = margin(t = 6)
      )
    )
}

exceedance_panels <- lapply(figure_pollutants$pollutant, exceedance_panel)

pm25_peak <- exceedances_by_class %>%
  filter(pollutant == "PM2.5") %>%
  slice_max(pct_event, n = 1, with_ties = FALSE)

ozone_same_year <- filter(exceedances_by_class, pollutant == "Ozone", year == pm25_peak$year)

period_event_shares <- exceedances_by_class %>%
  summarise(pct_event = 100 * sum(Event) / sum(total), .by = pollutant)

stopifnot(
  "Events hold over a third of all PM2.5 exceedances, as the title says" =
    period_event_shares$pct_event[period_event_shares$pollutant == "PM2.5"] > 33,
  "Events hold under a twentieth of all ozone exceedances" =
    period_event_shares$pct_event[period_event_shares$pollutant == "Ozone"] < 5
)

exceedance_header <- chart_header(
  "FIGURE 2A.3  /  EXCEEDANCE DAYS  /  ALL SITES",
  "Event days hold over a third of PM2.5 exceedances",
  sprintf(
    str_c(
      "Days above each standard out of every 1,000 site-days. In %d, %.1f%% of PM2.5 exceedance\n",
      "days fell on labelled smoke, dust or storm days, against %.1f%% of ozone exceedance days."
    ),
    pm25_peak$year, pm25_peak$pct_event, ozone_same_year$pct_event
  ),
  key = tribble(
    ~mark,    ~colour,                       ~label,
    "square", day_class_fills[["None"]],      "Ordinary days",
    "square", day_class_fills[["Event"]],     "Event days (smoke, dust, storms)",
    "square", day_class_fills[["Fireworks"]], "Fireworks days"
  )
)

exceedance_footer <- chart_footer(sprintf(
  "EPA AQS daily data, %s to %s, all sites. Screening counts: daily values rounded as each standard specifies and\n%s",
  first_year, last_year, "compared with its level. The standards allow some days above the level, so these are not violations."
))

exceedance_figure <- chart_compose(exceedance_header, exceedance_panels, exceedance_footer, ncol = 3)

exceedance_figure_path <- here("figures", "phase2", "2a.03_exceedances.png")

save_started <- Sys.time()

ggsave(exceedance_figure_path, exceedance_figure, width = 6.5, height = 4.6, dpi = 300)

stopifnot(
  "2a.03_exceedances.png was written (close any viewer of it and rerun this step)" =
    file.mtime(exceedance_figure_path) >= save_started - 2
)

# Two-panel figure of the 10 metros with the most exceedance days for PM2.5 and ozone, split into ordinary, event and
# fireworks days, with the ranks of the two case-study metros
case_study_metros <- daily_sites %>%
  mutate(county_id = str_sub(site_id, 1, 6)) %>%
  filter(county_id %in% region_lookup$county_id, !is.na(cbsa_name)) %>%
  distinct(county_id, cbsa_name) %>%
  inner_join(region_lookup, by = "county_id", relationship = "many-to-one") %>%
  distinct(region, cbsa_name)

stopifnot("One metro for Houston and one for Dallas-Fort Worth" = nrow(case_study_metros) == 2 && n_distinct(case_study_metros$region) == 2)

# First city and first state of a CBSA name: "Los Angeles-Long Beach-Anaheim, CA" becomes "Los Angeles, CA"
short_metro_name <- function(cbsa_name) str_replace(cbsa_name, "^([^-,]+)[^,]*, ([A-Z]{2}).*$", "\\1, \\2")

metro_ranks <- exceedances %>%
  filter(pollutant %in% c("PM2.5", "Ozone"), !is.na(cbsa_name)) %>%
  count(pollutant, cbsa_name, event_class) %>%
  pivot_wider(names_from = event_class, values_from = n, values_fill = 0) %>%
  mutate(n_exceedance_days = None + Event + Fireworks) %>%
  mutate(pct_event = 100 * Event / n_exceedance_days) %>%
  mutate(metro_rank = min_rank(desc(n_exceedance_days)), .by = pollutant) %>%
  left_join(case_study_metros, by = "cbsa_name", relationship = "many-to-one") %>%
  mutate(is_case_study = !is.na(region)) %>%
  mutate(metro_label = if_else(is_case_study, str_c(region, ", TX"), short_metro_name(cbsa_name)))

top_10_metros <- metro_ranks %>%
  filter(metro_rank <= 10)

case_study_metro_ranks <- metro_ranks %>%
  filter(is_case_study) %>%
  select(pollutant, region, metro_rank, n_exceedance_days)

print(top_10_metros %>% select(pollutant, metro_rank, metro_label, n_exceedance_days, pct_event), n = Inf)

print(case_study_metro_ranks)

# 1ST, 2ND, 3RD, 4TH ... with 11TH to 13TH as exceptions
ordinal_label <- function(n) {
  suffix <- if_else(n %% 100 %in% 11:13, "TH", c("TH", "ST", "ND", "RD", rep("TH", 6))[n %% 10 + 1])
  str_c(n, suffix)
}

metro_panel <- function(panel_pollutant, kicker, panel_title) {
  panel_data <- top_10_metros %>%
    filter(pollutant == panel_pollutant) %>%
    mutate(metro_label = reorder(metro_label, n_exceedance_days)) %>%
    pivot_longer(c(None, Event, Fireworks), names_to = "event_class", values_to = "n_class") %>%
    mutate(event_class = factor(event_class, levels = c("Fireworks", "Event", "None")))
  panel_totals <- distinct(panel_data, metro_label, n_exceedance_days, is_case_study)
  case_study_labels <- as.character(panel_totals$metro_label[panel_totals$is_case_study])
  x_limit <- max(panel_totals$n_exceedance_days) * 1.3
  label_gap <- x_limit * 0.015
  panel_ranks <- filter(case_study_metro_ranks, pollutant == panel_pollutant)
  panel_caption <- sprintf(
    "HOUSTON %s, DFW %s OF %d METROS",
    ordinal_label(panel_ranks$metro_rank[panel_ranks$region == "Houston"]),
    ordinal_label(panel_ranks$metro_rank[panel_ranks$region == "Dallas-Fort Worth"]),
    n_distinct(metro_ranks$cbsa_name[metro_ranks$pollutant == panel_pollutant])
  )
  ggplot(panel_data, aes(n_class, metro_label, fill = event_class)) +
    geom_col(width = 0.6, colour = "white", linewidth = 0.3) +
    geom_text(
      data = filter(panel_totals, !is_case_study), aes(n_exceedance_days + label_gap, metro_label, label = comma(n_exceedance_days)),
      inherit.aes = FALSE, hjust = 0, family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt,
      colour = chart_ink[["secondary"]]
    ) +
    geom_text(
      data = filter(panel_totals, is_case_study),
      aes(n_exceedance_days + label_gap, metro_label, label = str_c(comma(n_exceedance_days), "  CASE STUDY")),
      inherit.aes = FALSE, hjust = 0, family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt,
      colour = chart_fills[["accent"]]
    ) +
    scale_fill_manual(values = day_class_fills, guide = "none") +
    scale_y_discrete(limits = levels(panel_data$metro_label), labels = \(labels) parse(text = if_else(
      labels %in% case_study_labels, sprintf('bold("%s")', labels), sprintf('"%s"', labels)
    ))) +
    scale_x_continuous(labels = label_number(scale_cut = cut_short_scale()), n.breaks = 4, limits = c(0, x_limit), expand = c(0, 0)) +
    labs(title = kicker, subtitle = panel_title, caption = panel_caption, x = NULL, y = NULL) +
    theme_aqs() +
    theme(
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
      axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 7.5),
      plot.caption = element_text(
        family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
        hjust = 0, margin = margin(t = 6)
      )
    )
}

metro_panels <- list(
  metro_panel("PM2.5", "01  PM2.5 24-HOUR", "Site-days above 35 µg/m³"),
  metro_panel("Ozone", "02  OZONE 8-HOUR", "Site-days above 0.070 ppm")
)

top_metro_each <- top_10_metros %>%
  filter(metro_rank == 1)

most_event_metro <- top_10_metros %>%
  filter(pollutant == "PM2.5") %>%
  slice_max(pct_event, n = 1, with_ties = FALSE)

most_local_metro <- top_10_metros %>%
  filter(pollutant == "PM2.5") %>%
  slice_min(pct_event, n = 1, with_ties = FALSE)

stopifnot(
  "A California metro tops both lists, as the title says" = all(str_detect(top_metro_each$cbsa_name, ", CA"))
)

metro_header <- chart_header(
  "FIGURE 2A.4  /  WHERE EXCEEDANCES CLUSTER  /  METRO AREAS",
  "California metros top both lists",
  sprintf(
    str_c(
      "Site-days above each standard, summed over each metro's monitors, %s to %s. In %s,\n",
      "%.0f%% of PM2.5 exceedance site-days were event days; in %s, %.0f%% were ordinary."
    ),
    first_year, last_year, most_event_metro$metro_label, most_event_metro$pct_event,
    most_local_metro$metro_label, 100 - most_local_metro$pct_event
  ),
  key = tribble(
    ~mark,    ~colour,                       ~label,
    "square", day_class_fills[["None"]],      "Ordinary days",
    "square", day_class_fills[["Event"]],     "Event days (smoke, dust, storms)",
    "square", day_class_fills[["Fireworks"]], "Fireworks days"
  )
)

metro_footer <- chart_footer(str_c(
  "EPA AQS daily data, all sites, grouped by core-based statistical area. Ranked by exceedance site-days, which rise with\n",
  "the number of monitors in a metro. Bold names are the two case-study metros. Screening counts, not violations."
))

metro_figure <- chart_compose(metro_header, metro_panels, metro_footer, ncol = 2)

metro_figure_path <- here("figures", "phase2", "2a.04_exceedance_metros.png")

save_started <- Sys.time()

ggsave(metro_figure_path, metro_figure, width = 6.5, height = 4.8, dpi = 300)

stopifnot(
  "2a.04_exceedance_metros.png was written (close any viewer of it and rerun this step)" =
    file.mtime(metro_figure_path) >= save_started - 2
)

# One row per pollutant, state, metro and year, saved as a CSV record in section 14
exceedances_by_area <- site_day_exceedances %>%
  summarise(
    site_days = n(),
    n_exceedances = sum(is_exceedance),
    n_event = sum(is_exceedance & event_class == "Event"),
    n_fireworks = sum(is_exceedance & event_class == "Fireworks"),
    .by = c(pollutant, state_name, cbsa_name, year)
  ) %>%
  mutate(per_1000 = round(1000 * n_exceedances / site_days, 2)) %>%
  arrange(pollutant, state_name, cbsa_name, year)

stopifnot(
  "Area counts add up to the national exceedances" = sum(exceedances_by_area$n_exceedances) == nrow(exceedances),
  "Area site-days add up to every site-day" = sum(exceedances_by_area$site_days) == nrow(site_day_exceedances),
  "Event and fireworks days never exceed the total" =
    all(exceedances_by_area$n_event + exceedances_by_area$n_fireworks <= exceedances_by_area$n_exceedances)
)

rm(site_day_exceedances)
invisible(gc())



# 5. SEASONALITY ----
# Five-year sites only. Ozone keeps the sites with December or January data in every study year, so each month is
# averaged over the same sites. Seasonal monitors would otherwise leave the winter months to a different set of sites
five_year_ozone_ids <- daily_sites %>%
  filter(pollutant == "Ozone", is_five_year) %>%
  distinct(site_id) %>%
  pull(site_id)

year_round_ozone_ids <- ozone_site_years %>%
  filter(site_id %in% five_year_ozone_ids) %>%
  summarise(n_winter_years = sum(has_winter_data), .by = site_id) %>%
  filter(n_winter_years == length(study_years)) %>%
  pull(site_id)

cat("Five-year ozone sites:", length(five_year_ozone_ids), " reporting every winter:", length(year_round_ozone_ids), "\n")

seasonal_site_days <- daily_sites %>%
  filter(is_five_year) %>%
  filter(pollutant != "Ozone" | site_id %in% year_round_ozone_ids) %>%
  select(pollutant, site_id, state_code, year, month, year_month, season, season_year, is_full_season, value, event_class)

stopifnot(
  "615 of the 964 five-year ozone sites report every winter" =
    length(five_year_ozone_ids) == 964 && length(year_round_ozone_ids) == 615
)

# One row per site and month with the mean of all days and of ordinary days. A site-month is kept when it has at least
# 75% of the days its schedule expects: every day for the gases, every 1st, 3rd or 6th day for PM2.5 (section 2)
sampling_intervals <- pm25_schedules %>%
  transmute(
    pollutant = factor("PM2.5", levels = pollutant_levels),
    site_id,
    year,
    sampling_interval = case_when(schedule == "1-in-3" ~ 3, schedule == "1-in-6" ~ 6, .default = 1)
  )

# daily_sites is sorted by pollutant, site and date, so each site-month's days sit together and can be numbered in one
# pass. rowsum() then totals every site-month at once, where a grouped summarise() takes about 25 seconds
seasonal_site_days <- seasonal_site_days %>%
  mutate(is_new_site_month = pollutant != lag(pollutant) | site_id != lag(site_id) | year_month != lag(year_month)) %>%
  mutate(is_new_site_month = coalesce(is_new_site_month, TRUE)) %>%
  mutate(site_month_id = cumsum(is_new_site_month))

stopifnot(
  "Each site-month is numbered once" =
    max(seasonal_site_days$site_month_id) == nrow(distinct(seasonal_site_days, pollutant, site_id, year_month))
)

site_month_totals <- rowsum(
  cbind(
    n_days = rep(1, nrow(seasonal_site_days)),
    value_total = seasonal_site_days$value,
    n_ordinary_days = seasonal_site_days$event_class == "None",
    ordinary_total = seasonal_site_days$value * (seasonal_site_days$event_class == "None")
  ),
  group = seasonal_site_days$site_month_id
)

site_months <- seasonal_site_days %>%
  filter(is_new_site_month) %>%
  select(site_month_id, pollutant, site_id, state_code, year, month, year_month, season, season_year, is_full_season) %>%
  inner_join(
    as_tibble(site_month_totals) %>%
      mutate(site_month_id = as.integer(rownames(site_month_totals))),
    by = "site_month_id",
    relationship = "one-to-one"
  ) %>%
  mutate(mean_value = value_total / n_days) %>%
  mutate(mean_ordinary = if_else(n_ordinary_days > 0, ordinary_total / n_ordinary_days, NA_real_)) %>%
  left_join(sampling_intervals, by = c("pollutant", "site_id", "year"), relationship = "many-to-one") %>%
  mutate(sampling_interval = coalesce(sampling_interval, 1)) %>%
  mutate(expected_days = as.numeric(days_in_month(year_month)) / sampling_interval) %>%
  mutate(is_complete = n_days >= 0.75 * expected_days)

site_month_completeness <- site_months %>%
  summarise(
    n_site_months = n(),
    n_dropped = sum(!is_complete),
    pct_dropped = round(100 * mean(!is_complete), 2),
    .by = pollutant
  )

print(site_month_completeness)

complete_site_months <- site_months %>%
  filter(is_complete)

stopifnot(
  "Site-months hold every kept site-day once" = sum(site_months$n_days) == nrow(seasonal_site_days),
  "One row per pollutant, site and month" = nrow(distinct(site_months, pollutant, site_id, year_month)) == nrow(site_months),
  "No site-month has more days than its month" = all(site_months$n_days <= days_in_month(site_months$year_month)),
  "The 75% rule drops under 6% of site-months for every pollutant" = all(site_month_completeness$pct_dropped < 6)
)

# Typical year: each site's mean for a calendar month across the five years, each year counting once, then the median
# and middle half across sites. monthly_profile() is in utils.R, where 2b reuses it with the case-study groups
site_calendar_months <- complete_site_months %>%
  summarise(
    n_years = n(),
    mean_value = mean(mean_value),
    mean_ordinary = mean(mean_ordinary, na.rm = TRUE),
    .by = c(pollutant, site_id, state_code, month)
  ) %>%
  mutate(mean_ordinary = if_else(is.nan(mean_ordinary), NA_real_, mean_ordinary))

national_monthly_profile <- monthly_profile(site_calendar_months)

national_monthly_profile %>%
  select(pollutant, month, median_value) %>%
  pivot_wider(names_from = pollutant, values_from = median_value) %>%
  print()

profile_peaks <- national_monthly_profile %>%
  summarise(
    peak_month = month[which.max(median_value)],
    peak_value = max(median_value),
    trough_month = month[which.min(median_value)],
    trough_value = min(median_value),
    peak_month_ordinary = month[which.max(median_ordinary)],
    peak_to_trough_ordinary = max(median_ordinary) / min(median_ordinary),
    .by = pollutant
  ) %>%
  mutate(peak_to_trough = peak_value / trough_value)

print(profile_peaks, width = Inf)

profile_site_counts <- national_monthly_profile %>%
  left_join(
    count(distinct(complete_site_months, pollutant, site_id), pollutant, name = "n_sites_total"),
    by = "pollutant",
    relationship = "many-to-one"
  )

cat(
  "SO2 site-months with a negative mean:",
  sum(complete_site_months$pollutant == "SO2" & round(complete_site_months$mean_value, 3) < 0), "\n"
)

stopifnot(
  "Twelve calendar months per pollutant" = all(count(national_monthly_profile, pollutant)$n == 12),
  "Each calendar month keeps at least 99% of the pollutant's sites" =
    all(profile_site_counts$n_sites >= 0.99 * profile_site_counts$n_sites_total)
)

# The calendar month with each site's highest mean, and how peak seasons split between the Census West region and the
# rest, with PM2.5 also on ordinary days only
month_seasons <- daily_sites %>%
  distinct(month, season)

site_peak_months <- site_calendar_months %>%
  slice_max(mean_value, n = 1, by = c(pollutant, site_id), with_ties = FALSE) %>%
  mutate(region = if_else(state_code %in% western_state_codes, "West", "East")) %>%
  left_join(month_seasons, by = "month", relationship = "many-to-one")

pm25_ordinary_peak_months <- site_calendar_months %>%
  filter(pollutant == "PM2.5", !is.na(mean_ordinary)) %>%
  slice_max(mean_ordinary, n = 1, by = site_id, with_ties = FALSE) %>%
  mutate(region = if_else(state_code %in% western_state_codes, "West", "East")) %>%
  left_join(month_seasons, by = "month", relationship = "many-to-one")

peak_month_shares <- site_peak_months %>%
  count(pollutant, month, name = "n_sites") %>%
  complete(pollutant, month, fill = list(n_sites = 0)) %>%
  mutate(pct_sites = 100 * n_sites / sum(n_sites), .by = pollutant)

peak_month_shares %>%
  select(pollutant, month, pct_sites) %>%
  mutate(pct_sites = round(pct_sites, 1)) %>%
  pivot_wider(names_from = pollutant, values_from = pct_sites) %>%
  print()

peak_seasons_by_region <- bind_rows(
  site_peak_months %>%
    filter(pollutant %in% c("PM2.5", "Ozone")) %>%
    count(pollutant, region, season, name = "n_sites") %>%
    mutate(day_set = "All days"),
  pm25_ordinary_peak_months %>%
    count(region, season, name = "n_sites") %>%
    mutate(pollutant = factor("PM2.5", levels = pollutant_levels)) %>%
    mutate(day_set = "Ordinary days")
)

peak_seasons_by_region %>%
  pivot_wider(names_from = season, values_from = n_sites, values_fill = 0) %>%
  arrange(pollutant, day_set, region) %>%
  print()

site_peak_months %>%
  filter(pollutant == "Ozone") %>%
  count(region, month) %>%
  pivot_wider(names_from = month, values_from = n, values_fill = 0) %>%
  print(width = Inf)

peak_share_totals <- peak_month_shares %>%
  summarise(total = sum(pct_sites), .by = pollutant)

stopifnot(
  "Twelve months, each in one season" = nrow(month_seasons) == 12 && !anyDuplicated(month_seasons$month),
  "One peak month per site" = nrow(site_peak_months) == nrow(distinct(site_calendar_months, pollutant, site_id)),
  "Peak-month shares sum to 100 for every pollutant" = all(abs(peak_share_totals$total - 100) < 1e-9)
)

# Month by month: the median and middle half across sites for each of the 60 months, with all days and ordinary days.
# The gap between the two medians is what labelled event and fireworks days added
national_monthly_series <- complete_site_months %>%
  summarise(
    n_sites = n(),
    median_value = median(mean_value),
    q25_value = quantile(mean_value, 0.25),
    q75_value = quantile(mean_value, 0.75),
    median_ordinary = median(mean_ordinary, na.rm = TRUE),
    .by = c(pollutant, year_month)
  ) %>%
  arrange(pollutant, year_month) %>%
  mutate(event_effect = median_value - median_ordinary)

pm25_event_months <- seasonal_site_days %>%
  filter(pollutant == "PM2.5") %>%
  summarise(
    pct_event_days = round(100 * mean(event_class == "Event"), 1),
    pct_fireworks_days = round(100 * mean(event_class == "Fireworks"), 1),
    .by = year_month
  ) %>%
  arrange(desc(pct_event_days))

print(head(pm25_event_months, 8))

national_monthly_series %>%
  filter(pollutant == "PM2.5") %>%
  slice_max(event_effect, n = 6) %>%
  print()

series_months <- national_monthly_series %>%
  count(pollutant, name = "n_months")

series_site_counts <- national_monthly_series %>%
  summarise(min_sites = min(n_sites), max_sites = max(n_sites), .by = pollutant)

print(series_site_counts)

national_monthly_series %>%
  slice_min(n_sites, n = 2, by = pollutant, with_ties = FALSE) %>%
  select(pollutant, year_month, n_sites) %>%
  print()

stopifnot(
  "Every pollutant has all 60 months" = all(series_months$n_months == 12 * length(study_years)),
  "Every month keeps at least 90% of the pollutant's sites" =
    all(series_site_counts$min_sites >= 0.9 * series_site_counts$max_sites)
)

# Seasons by year from complete site-months: a site-season needs all three of its months. The partial winters are left out
site_seasons <- complete_site_months %>%
  filter(is_full_season) %>%
  summarise(n_months = n(), mean_value = mean(mean_value), .by = c(pollutant, site_id, season_year, season)) %>%
  filter(n_months == 3)

season_medians <- site_seasons %>%
  summarise(n_sites = n(), median_value = median(mean_value), .by = c(pollutant, season_year, season)) %>%
  arrange(pollutant, season_year, season)

season_medians %>%
  select(pollutant, season_year, season, median_value) %>%
  pivot_wider(names_from = season, values_from = median_value) %>%
  print(n = Inf)

winter_years <- season_medians %>%
  filter(season == "Winter") %>%
  distinct(season_year)

stopifnot(
  "Four full winters, 2022 to 2025" = setequal(winter_years$season_year, (min(study_years) + 1):max(study_years)),
  "Five years of every other season for every pollutant" =
    nrow(filter(season_medians, season != "Winter")) == length(pollutant_levels) * 3 * length(study_years)
)

# Six-panel figure of the typical year: one panel per pollutant with the median site and the middle half of sites, and
# a sixth panel with the share of sites peaking in each month
band_alpha <- 0.18

month_scale <- scale_x_continuous(breaks = 1:12, labels = str_sub(month.abb, 1, 1), expand = expansion(add = 0.4))

profile_panel_labels <- tribble(
  ~pollutant, ~kicker,                ~panel_title,     ~digits,
  "PM2.5",    "01  DAILY MEAN",       "PM2.5 (µg/m³)",  1,
  "Ozone",    "02  DAILY MAX 8-HOUR", "Ozone (ppm)",    3,
  "NO2",      "03  DAILY MAX 1-HOUR", "NO2 (ppb)",      1,
  "SO2",      "04  DAILY MAX 1-HOUR", "SO2 (ppb)",      2,
  "CO",       "05  DAILY MAX 8-HOUR", "CO (ppm)",       2
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels))

profile_panel <- function(panel_pollutant) {
  panel_labels <- filter(profile_panel_labels, pollutant == panel_pollutant)
  panel_peak <- filter(profile_peaks, pollutant == panel_pollutant)
  panel_data <- national_monthly_profile %>%
    filter(pollutant == panel_pollutant) %>%
    mutate(month_number = as.integer(month))
  peak_point <- panel_data %>%
    filter(month == panel_peak$peak_month) %>%
    mutate(label = formatC(median_value, format = "f", digits = panel_labels$digits))
  peak_hjust <- case_when(peak_point$month_number <= 2 ~ 0, peak_point$month_number >= 11 ~ 1, .default = 0.5)
  panel_plot <- ggplot(panel_data, aes(month_number, median_value)) +
    geom_ribbon(aes(ymin = q25_value, ymax = q75_value), fill = chart_fills[["accent"]], alpha = band_alpha)
  if (panel_pollutant == "PM2.5") {
    panel_plot <- panel_plot +
      geom_line(aes(y = median_ordinary), colour = chart_fills[["other"]], linewidth = 0.6)
  }
  panel_plot +
    geom_line(colour = chart_fills[["accent"]], linewidth = 0.7) +
    chart_end_label(peak_point, "month_number", "median_value", "label", hjust = peak_hjust) +
    month_scale +
    expand_limits(y = 0) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
    labs(
      title = panel_labels$kicker,
      subtitle = panel_labels$panel_title,
      caption = sprintf(
        "PEAK %s, %.1f× THE %s LOW", toupper(panel_peak$peak_month), panel_peak$peak_to_trough, toupper(panel_peak$trough_month)
      ),
      x = NULL,
      y = NULL
    ) +
    theme_aqs() +
    theme(
      plot.caption = element_text(
        family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
        hjust = 0, margin = margin(t = 6)
      )
    )
}

top_peak_share <- peak_month_shares %>%
  slice_max(pct_sites, n = 1, with_ties = FALSE)

peak_tile_data <- peak_month_shares %>%
  mutate(month_number = as.integer(month)) %>%
  mutate(is_top_month = pct_sites == max(pct_sites), .by = pollutant) %>%
  mutate(label = if_else(is_top_month, sprintf("%.0f", pct_sites), ""))

peak_tile_panel <- ggplot(peak_tile_data, aes(month_number, pollutant, fill = pct_sites)) +
  geom_tile(colour = "white", linewidth = 0.6) +
  geom_text(aes(label = label, colour = pct_sites >= 25), family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.5) / .pt) +
  scale_fill_gradient(low = chart_fills[["band"]], high = chart_fills[["accent"]], limits = c(0, NA), guide = "none") +
  scale_colour_manual(values = c(`TRUE` = "white", `FALSE` = chart_ink[["primary"]]), guide = "none") +
  scale_x_continuous(breaks = 1:12, labels = str_sub(month.abb, 1, 1), expand = c(0, 0)) +
  scale_y_discrete(limits = rev(pollutant_levels)) +
  labs(
    title = "06  PEAK MONTH",
    subtitle = "Share of sites peaking (%)",
    caption = sprintf("%.0f%% OF %s SITES PEAK IN %s", top_peak_share$pct_sites, top_peak_share$pollutant, toupper(top_peak_share$month)),
    x = NULL,
    y = NULL
  ) +
  theme_aqs() +
  theme(
    panel.grid.major = element_blank(),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 7),
    plot.caption = element_text(
      family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
      hjust = 0, margin = margin(t = 6)
    )
  )

profile_panels <- c(lapply(profile_panel_labels$pollutant, profile_panel), list(peak_tile_panel))

winter_months <- month_seasons$month[month_seasons$season == "Winter"]

summer_months <- month_seasons$month[month_seasons$season == "Summer"]

stopifnot(
  "NO2 and CO peak in winter, as the title says" =
    all(profile_peaks$peak_month[profile_peaks$pollutant %in% c("NO2", "CO")] %in% winter_months),
  "Ozone and PM2.5 peak in summer, as the title and subtitle say" =
    all(profile_peaks$peak_month[profile_peaks$pollutant %in% c("Ozone", "PM2.5")] %in% summer_months)
)

pm25_peak_profile <- national_monthly_profile %>%
  filter(pollutant == "PM2.5", month == profile_peaks$peak_month[profile_peaks$pollutant == "PM2.5"])

profile_header <- chart_header(
  "FIGURE 2A.5  /  THE TYPICAL YEAR  /  FIVE-YEAR SITES",
  "NO2 and CO peak in winter, ozone in summer",
  sprintf(
    str_c(
      "Median of each site's monthly mean over %s to %s, with the middle half of sites shaded. In %s,\n",
      "the PM2.5 median is %.1f µg/m³ with all days and %.1f without event and fireworks days."
    ),
    first_year, last_year, month.name[as.integer(pm25_peak_profile$month)], pm25_peak_profile$median_value,
    pm25_peak_profile$median_ordinary
  ),
  key = tribble(
    ~mark,    ~colour,                                    ~label,
    "dot",    chart_fills[["accent"]],                    "Median site",
    "square", alpha(chart_fills[["accent"]], band_alpha), "Middle half of sites",
    "dot",    chart_fills[["other"]],                     "PM2.5 median without event and fireworks days"
  )
)

profile_site_counts <- site_calendar_months %>%
  distinct(pollutant, site_id) %>%
  count(pollutant, name = "n_sites")

profile_site_note <- profile_site_counts %>%
  mutate(label = str_c(pollutant, " ", n_sites)) %>%
  pull(label) %>%
  str_flatten(collapse = ", ")

stopifnot(
  "The typical year uses only the ozone sites that report every winter" =
    profile_site_counts$n_sites[profile_site_counts$pollutant == "Ozone"] == length(year_round_ozone_ids)
)

profile_footer <- chart_footer(sprintf(
  str_c(
    "EPA AQS daily data, five-year sites: %s. Ozone uses only the sites that\n",
    "report every winter. Site-months need 75%% of their expected days. Ozone has no December 31 rows. Peak month:\n",
    "the calendar month with a site's highest mean."
  ),
  profile_site_note
))

profile_figure <- chart_compose(profile_header, profile_panels, profile_footer, ncol = 3)

profile_figure_path <- here("figures", "phase2", "2a.05_monthly_profile.png")

save_started <- Sys.time()

ggsave(profile_figure_path, profile_figure, width = 6.5, height = 6.0, dpi = 300)

stopifnot(
  "2a.05_monthly_profile.png was written (close any viewer of it and rerun this step)" =
    file.mtime(profile_figure_path) >= save_started - 2
)

# Two-panel figure of the 60 monthly medians for PM2.5 and ozone. The grey PM2.5 line leaves out event and fireworks
# days, so the gap between the lines is what labelled events added
series_panel_labels <- tribble(
  ~pollutant, ~kicker,                       ~panel_title,
  "PM2.5",    "01  PM2.5 DAILY MEAN",         "Monthly median (µg/m³)",
  "Ozone",    "02  OZONE DAILY MAX 8-HOUR",   "Monthly median (ppm)"
)

pm25_series <- national_monthly_series %>%
  filter(pollutant == "PM2.5")

highest_pm25_month <- pm25_series %>%
  slice_max(median_value, n = 1, with_ties = FALSE)

largest_event_month <- pm25_series %>%
  slice_max(event_effect, n = 1, with_ties = FALSE)

highest_ordinary_month <- pm25_series %>%
  slice_max(median_ordinary, n = 1, with_ties = FALSE)

highest_ozone_month <- national_monthly_series %>%
  filter(pollutant == "Ozone") %>%
  slice_max(median_value, n = 1, with_ties = FALSE)

stopifnot(
  "The highest PM2.5 month is the one events added most to, as the title says" =
    identical(highest_pm25_month$year_month, largest_event_month$year_month),
  "Without event days a different month would be highest, as the subtitle says" =
    !identical(highest_pm25_month$year_month, highest_ordinary_month$year_month)
)

month_year_label <- function(dates) str_c(toupper(month.abb[month(dates)]), " ", year(dates))

month_year_name <- function(dates) str_c(month.name[month(dates)], " ", year(dates))

year_starts <- ymd(str_c(study_years, "-01-01"))

series_panel <- function(panel_pollutant) {
  panel_labels <- filter(series_panel_labels, pollutant == panel_pollutant)
  panel_data <- filter(national_monthly_series, pollutant == panel_pollutant)
  panel_plot <- ggplot(panel_data, aes(year_month, median_value)) +
    geom_ribbon(aes(ymin = q25_value, ymax = q75_value), fill = chart_fills[["accent"]], alpha = band_alpha)
  if (panel_pollutant == "PM2.5") {
    marked_month <- largest_event_month %>%
      mutate(label = sprintf("%s  %.1f", month_year_label(year_month), median_value)) %>%
      mutate(label_ordinary = sprintf("%.1f WITHOUT EVENTS", median_ordinary))
    panel_plot <- panel_plot +
      geom_line(aes(y = median_ordinary), colour = chart_fills[["other"]], linewidth = 0.6) +
      chart_end_label(marked_month, "year_month", "median_value", "label", hjust = 1.08, vjust = 0.4) +
      chart_end_label(marked_month, "year_month", "median_ordinary", "label_ordinary", colour = chart_ink[["muted"]], hjust = 1.08, vjust = 0.4)
    panel_caption <- sprintf(
      "EVENTS ADDED %.1f TO THE %s MEDIAN", largest_event_month$event_effect, month_year_label(largest_event_month$year_month)
    )
  } else {
    panel_caption <- sprintf("HIGHEST MONTH %s, %.3f PPM", month_year_label(highest_ozone_month$year_month), highest_ozone_month$median_value)
  }
  panel_plot +
    geom_line(colour = chart_fills[["accent"]], linewidth = 0.7) +
    scale_x_date(breaks = year_starts, date_labels = "%Y", expand = expansion(add = 15)) +
    expand_limits(y = 0) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.08))) +
    labs(title = panel_labels$kicker, subtitle = panel_labels$panel_title, caption = panel_caption, x = NULL, y = NULL) +
    theme_aqs() +
    theme(
      plot.caption = element_text(
        family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
        hjust = 0, margin = margin(t = 6)
      )
    )
}

series_panels <- lapply(series_panel_labels$pollutant, series_panel)

series_header <- chart_header(
  "FIGURE 2A.6  /  MONTH BY MONTH  /  FIVE-YEAR SITES",
  sprintf("Event days made %s the top PM2.5 month", month_year_name(highest_pm25_month$year_month)),
  sprintf(
    str_c(
      "Median of each site's monthly mean. In %s, the PM2.5 median was %.1f µg/m³ with all days\n",
      "and %.1f without event and fireworks days, which would rank it below %s (%.1f)."
    ),
    month_year_name(highest_pm25_month$year_month), highest_pm25_month$median_value, highest_pm25_month$median_ordinary,
    month_year_name(highest_ordinary_month$year_month), highest_ordinary_month$median_ordinary
  ),
  key = tribble(
    ~mark,    ~colour,                                    ~label,
    "dot",    chart_fills[["accent"]],                    "Median site, all days",
    "square", alpha(chart_fills[["accent"]], band_alpha), "Middle half of sites",
    "dot",    chart_fills[["other"]],                     "PM2.5 median without event and fireworks days"
  )
)

series_footer <- chart_footer(sprintf(
  str_c(
    "EPA AQS daily data, five-year sites, site-months with 75%% of their expected days. Ozone uses the %d sites that\n",
    "report every winter. Event days are events.csv windows (smoke, dust, storms)."
  ),
  length(year_round_ozone_ids)
))

series_figure <- chart_compose(series_header, series_panels, series_footer, ncol = 1)

series_figure_path <- here("figures", "phase2", "2a.06_monthly_series.png")

save_started <- Sys.time()

ggsave(series_figure_path, series_figure, width = 6.5, height = 6.2, dpi = 300)

stopifnot(
  "2a.06_monthly_series.png was written (close any viewer of it and rerun this step)" =
    file.mtime(series_figure_path) >= save_started - 2
)

rm(seasonal_site_days, site_month_totals)
invisible(gc())



# 6. WEEKEND EFFECT ----
# April to October at five-year sites, ordinary days only, so smoke cannot tilt either side. Weekend is Saturday and
# Sunday. The weekday holidays in CONFIG are left out of both groups
weekend_site_days <- daily_sites %>%
  filter(is_five_year, between(as.integer(month), 4, 10), event_class == "None") %>%
  select(pollutant, site_id, state_code, cbsa_name, year, date_local, day_of_week, is_weekend, value) %>%
  left_join(select(weekday_holidays, date_local, holiday), by = "date_local", relationship = "many-to-one")

# Each holiday's mean against the site's ordinary weekdays, beside Saturday and Sunday, to show why holidays are left out
day_type_means <- weekend_site_days %>%
  mutate(
    day_type = case_when(
      !is.na(holiday) ~ holiday,
      is_weekend ~ as.character(day_of_week),
      .default = "Weekday"
    )
  ) %>%
  summarise(mean_value = mean(value), .by = c(pollutant, site_id, day_type))

day_type_ratios <- day_type_means %>%
  left_join(
    day_type_means %>%
      filter(day_type == "Weekday") %>%
      select(pollutant, site_id, weekday_mean = mean_value),
    by = c("pollutant", "site_id"),
    relationship = "many-to-one"
  ) %>%
  filter(weekday_mean > 0) %>%
  mutate(ratio = mean_value / weekday_mean) %>%
  summarise(median_ratio = median(ratio), .by = c(pollutant, day_type))

day_type_ratios %>%
  pivot_wider(names_from = pollutant, values_from = median_ratio) %>%
  print()

no2_day_types <- day_type_ratios %>%
  filter(pollutant == "NO2")

no2_sunday_ratio <- no2_day_types$median_ratio[no2_day_types$day_type == "Sun"]

no2_holiday_ratios <- no2_day_types$median_ratio[no2_day_types$day_type %in% weekday_holidays$holiday]

stopifnot(
  "Every holiday in CONFIG falls in the April to October window" = length(no2_holiday_ratios) == n_distinct(weekday_holidays$holiday),
  "NO2 on each left-out holiday is closer to Sunday than to a weekday" = all(no2_holiday_ratios < (1 + no2_sunday_ratio) / 2)
)

# Weekend mean over weekday mean per site, with Saturday and Sunday on their own. A site needs a weekday mean above zero
# for its ratio to mean anything, which drops a few SO2 and CO sites that read near zero
weekend_ratios <- weekend_site_days %>%
  filter(is.na(holiday)) %>%
  summarise(
    n_weekday_days = sum(!is_weekend),
    n_weekend_days = sum(is_weekend),
    weekday_mean = mean(value[!is_weekend]),
    weekend_mean = mean(value[is_weekend]),
    saturday_mean = mean(value[day_of_week == "Sat"]),
    sunday_mean = mean(value[day_of_week == "Sun"]),
    .by = c(pollutant, site_id, state_code, cbsa_name)
  )

cat("Sites dropped for a weekday mean at or below zero:", sum(weekend_ratios$weekday_mean <= 0), "\n")

weekend_ratios <- weekend_ratios %>%
  filter(weekday_mean > 0) %>%
  mutate(weekend_ratio = weekend_mean / weekday_mean) %>%
  mutate(saturday_ratio = saturday_mean / weekday_mean) %>%
  mutate(sunday_ratio = sunday_mean / weekday_mean)

weekend_summary <- weekend_ratios %>%
  summarise(
    n_sites = n(),
    median_ratio = median(weekend_ratio),
    q25_ratio = quantile(weekend_ratio, 0.25),
    q75_ratio = quantile(weekend_ratio, 0.75),
    median_saturday = median(saturday_ratio),
    median_sunday = median(sunday_ratio),
    pct_higher_on_weekends = round(100 * mean(weekend_ratio > 1), 1),
    .by = pollutant
  ) %>%
  arrange(pollutant)

print(weekend_summary, width = Inf)

stopifnot(
  "One ratio per pollutant and site" = nrow(distinct(weekend_ratios, pollutant, site_id)) == nrow(weekend_ratios),
  "Every site has at least 30 weekend days" = min(weekend_ratios$n_weekend_days) >= 30,
  "Every ratio is a finite number" = all(is.finite(weekend_ratios$weekend_ratio))
)

# Each day of the week against the site's weekday mean, and the weekend ratio year by year
day_of_week_profile <- weekend_site_days %>%
  filter(is.na(holiday)) %>%
  summarise(day_mean = mean(value), .by = c(pollutant, site_id, day_of_week)) %>%
  inner_join(select(weekend_ratios, pollutant, site_id, weekday_mean), by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
  mutate(day_ratio = day_mean / weekday_mean) %>%
  summarise(n_sites = n(), median_ratio = median(day_ratio), .by = c(pollutant, day_of_week)) %>%
  arrange(pollutant, day_of_week)

day_of_week_profile %>%
  select(pollutant, day_of_week, median_ratio) %>%
  pivot_wider(names_from = pollutant, values_from = median_ratio) %>%
  print()

weekend_by_year <- weekend_site_days %>%
  filter(is.na(holiday)) %>%
  summarise(weekday_mean = mean(value[!is_weekend]), weekend_mean = mean(value[is_weekend]), .by = c(pollutant, site_id, year)) %>%
  filter(weekday_mean > 0) %>%
  mutate(weekend_ratio = weekend_mean / weekday_mean) %>%
  filter(is.finite(weekend_ratio)) %>%
  summarise(n_sites = n(), median_ratio = median(weekend_ratio), .by = c(pollutant, year)) %>%
  arrange(pollutant, year)

weekend_by_year %>%
  select(pollutant, year, median_ratio) %>%
  pivot_wider(names_from = year, values_from = median_ratio) %>%
  print()

stopifnot(
  "Seven days per pollutant in the profile" = all(count(day_of_week_profile, pollutant)$n == 7),
  "Five years per pollutant" = all(count(weekend_by_year, pollutant)$n == length(study_years))
)

# Where weekend ozone rises: the Census West region against the rest, and metros with at least 5 five-year ozone sites
ozone_weekend_regions <- weekend_ratios %>%
  filter(pollutant == "Ozone") %>%
  mutate(region = if_else(state_code %in% western_state_codes, "West", "East")) %>%
  summarise(
    n_sites = n(),
    median_ratio = median(weekend_ratio),
    pct_higher_on_weekends = round(100 * mean(weekend_ratio > 1), 1),
    .by = region
  )

print(ozone_weekend_regions)

ozone_weekend_metros <- weekend_ratios %>%
  filter(pollutant == "Ozone", !is.na(cbsa_name)) %>%
  summarise(
    n_sites = n(),
    median_ratio = median(weekend_ratio),
    pct_higher_on_weekends = round(100 * mean(weekend_ratio > 1), 1),
    .by = cbsa_name
  ) %>%
  filter(n_sites >= 5) %>%
  left_join(case_study_metros, by = "cbsa_name", relationship = "many-to-one") %>%
  mutate(is_case_study = !is.na(region)) %>%
  mutate(metro_label = if_else(is_case_study, str_c(region, ", TX"), short_metro_name(cbsa_name))) %>%
  mutate(metro_rank = min_rank(desc(median_ratio))) %>%
  arrange(metro_rank)

print(head(ozone_weekend_metros, 10))

print(filter(ozone_weekend_metros, is_case_study))

stopifnot("Both case-study metros have at least 5 five-year ozone sites" = sum(ozone_weekend_metros$is_case_study) == 2)

# Case-study group of every Harris, Dallas and Tarrant site, saved for 2b in section 7. Harris sites take the group 1c
# set from their distance to the Ship Channel; the Bayport-adjacent site belongs to neither Houston group
harris_groups <- read_csv(
  harris_groups_path,
  col_types = cols_only(site_id = col_character(), km_to_channel = col_double(), site_group = col_character())
)

site_groups <- daily_sites %>%
  distinct(site_id) %>%
  mutate(county_id = str_sub(site_id, 1, 6)) %>%
  inner_join(region_lookup, by = "county_id", relationship = "many-to-one") %>%
  left_join(select(harris_groups, site_id, houston_group = site_group), by = "site_id", relationship = "one-to-one") %>%
  mutate(site_group = if_else(region == "Houston", houston_group, "Dallas-Fort Worth"))

harris_sites_without_group <- site_groups %>%
  filter(region == "Houston", is.na(site_group))

site_groups <- site_groups %>%
  filter(site_group %in% names(site_group_colours)) %>%
  mutate(site_group = factor(site_group, levels = names(site_group_colours))) %>%
  select(site_id, region, site_group)

weekend_by_group <- weekend_ratios %>%
  inner_join(site_groups, by = "site_id", relationship = "many-to-one") %>%
  summarise(
    n_sites = n(),
    median_ratio = median(weekend_ratio),
    min_ratio = min(weekend_ratio),
    max_ratio = max(weekend_ratio),
    .by = c(pollutant, site_group)
  ) %>%
  arrange(pollutant, site_group)

print(weekend_by_group, n = Inf)

stopifnot(
  "Every Harris site in the daily data has a group from 1c (rerun 1c if not)" = nrow(harris_sites_without_group) == 0,
  "9 Harris sites with daily data are within the Ship Channel cutoff" = sum(site_groups$site_group == "Houston Ship Channel") == 9,
  "Group labels match the chart colours" = all(levels(site_groups$site_group) == names(site_group_colours))
)

# NO2 against ozone at sites that measure both. Ozone rising where NO2 falls is consistent with VOC-limited ozone, where
# less NOx leaves more ozone
no2_ozone_ratios <- weekend_ratios %>%
  filter(pollutant %in% c("NO2", "Ozone")) %>%
  select(pollutant, site_id, weekend_ratio) %>%
  pivot_wider(names_from = pollutant, values_from = weekend_ratio) %>%
  filter(!is.na(NO2), !is.na(Ozone)) %>%
  left_join(site_groups, by = "site_id", relationship = "one-to-one")

no2_ozone_summary <- no2_ozone_ratios %>%
  summarise(
    n_sites = n(),
    n_ozone_higher = sum(Ozone > 1),
    n_no2_lower = sum(NO2 < 1),
    spearman = cor(NO2, Ozone, method = "spearman")
  )

print(no2_ozone_summary)

# Four-panel figure: the weekend ratio of each pollutant, NO2 and ozone through the week, NO2 against ozone per site with
# the case-study sites in their group colours, and the metros where weekend ozone rises most
weekend_row_data <- weekend_summary %>%
  mutate(pollutant = reorder(pollutant, -median_ratio)) %>%
  mutate(label = sprintf("%.2f", median_ratio))

ratio_panel <- ggplot(weekend_row_data, aes(median_ratio, pollutant)) +
  geom_vline(xintercept = 1, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_segment(aes(x = q25_ratio, xend = q75_ratio, yend = pollutant), colour = chart_fills[["accent"]], linewidth = 1.6, alpha = 0.45) +
  geom_point(colour = chart_fills[["accent"]], size = 1.9) +
  geom_text(
    aes(x = q75_ratio, label = label), hjust = -0.35, family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt,
    colour = chart_ink[["secondary"]]
  ) +
  scale_x_continuous(limits = c(0.7, 1.15), breaks = seq(0.7, 1.1, 0.1)) +
  labs(
    title = "01  WEEKEND OVER WEEKDAY",
    subtitle = "Below 1.0 is lower on weekends",
    caption = sprintf("%s SITE RATIOS ACROSS 5 POLLUTANTS", comma(sum(weekend_summary$n_sites))),
    x = NULL,
    y = NULL
  ) +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 7.5),
    plot.caption = element_text(
      family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
      hjust = 0, margin = margin(t = 6)
    )
  )

day_of_week_data <- day_of_week_profile %>%
  filter(pollutant %in% c("NO2", "Ozone")) %>%
  mutate(day_number = as.integer(day_of_week)) %>%
  mutate(label = sprintf("%s %.2f", toupper(pollutant), median_ratio))

sunday_points <- day_of_week_data %>%
  filter(day_number == 7)

no2_sunday <- filter(sunday_points, pollutant == "NO2")

day_panel <- ggplot(day_of_week_data, aes(day_number, median_ratio, colour = pollutant)) +
  geom_hline(yintercept = 1, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_line(linewidth = 0.7) +
  chart_end_label(no2_sunday, "day_number", "median_ratio", "label", hjust = -0.15, vjust = 0.4) +
  chart_end_label(
    filter(sunday_points, pollutant == "Ozone"), "day_number", "median_ratio", "label", colour = chart_ink[["muted"]], hjust = -0.15, vjust = 0.4
  ) +
  scale_colour_manual(values = c(NO2 = chart_fills[["accent"]], Ozone = chart_fills[["other"]]), guide = "none") +
  scale_x_continuous(breaks = 1:7, labels = levels(day_of_week_profile$day_of_week), expand = expansion(add = c(0.3, 2.8))) +
  scale_y_continuous(limits = c(0.7, 1.06), breaks = seq(0.7, 1.0, 0.1)) +
  labs(
    title = "02  DAY OF WEEK",
    subtitle = "Ratio to the site's weekday mean",
    caption = sprintf("SUNDAY NO2 %.0f%% BELOW WEEKDAYS", 100 * (1 - no2_sunday$median_ratio)),
    x = NULL,
    y = NULL
  ) +
  theme_aqs() +
  theme(
    plot.caption = element_text(
      family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
      hjust = 0, margin = margin(t = 6)
    )
  )

# Group labels sit above the highest dot so they never cover one
group_label_data <- tibble(
  site_group = factor(names(site_group_colours), levels = names(site_group_colours)),
  label = toupper(names(site_group_colours))
) %>%
  mutate(NO2 = min(no2_ozone_ratios$NO2)) %>%
  mutate(Ozone = max(no2_ozone_ratios$Ozone) + 0.07 - (row_number() - 1) * 0.021)

scatter_panel <- ggplot(no2_ozone_ratios, aes(NO2, Ozone)) +
  geom_hline(yintercept = 1, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_point(data = filter(no2_ozone_ratios, is.na(site_group)), colour = chart_fills[["other"]], size = 0.9, alpha = 0.7) +
  geom_point(data = filter(no2_ozone_ratios, !is.na(site_group)), aes(fill = site_group), shape = 21, colour = "white", stroke = 0.4, size = 2) +
  geom_text(
    data = group_label_data, aes(label = label, colour = site_group), hjust = 0,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt
  ) +
  scale_fill_manual(values = site_group_colours, guide = "none") +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  labs(
    title = "03  NO2 AGAINST OZONE",
    subtitle = "One dot per site, 1.0 is no change",
    caption = sprintf("OZONE HIGHER ON WEEKENDS AT %d OF %d SITES", no2_ozone_summary$n_ozone_higher, no2_ozone_summary$n_sites),
    x = "NO2 RATIO",
    y = "OZONE RATIO"
  ) +
  theme_aqs() +
  theme(
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.title = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["muted"]], size = chart_sizes[["axis"]]),
    plot.caption = element_text(
      family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
      hjust = 0, margin = margin(t = 6)
    )
  )

metro_rows <- ozone_weekend_metros %>%
  filter(metro_rank <= 8 | is_case_study) %>%
  mutate(metro_label = reorder(metro_label, median_ratio)) %>%
  mutate(is_higher = median_ratio > 1) %>%
  mutate(label = sprintf("%+.1f%%", 100 * (median_ratio - 1)))

case_study_metro_labels <- as.character(metro_rows$metro_label[metro_rows$is_case_study])

case_study_ozone_metros <- filter(metro_rows, is_case_study)

ozone_metro_panel <- ggplot(metro_rows, aes(median_ratio, metro_label)) +
  geom_vline(xintercept = 1, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_segment(aes(x = 1, xend = median_ratio, yend = metro_label, colour = is_higher), linewidth = 0.6) +
  geom_point(aes(colour = is_higher), size = 1.9) +
  geom_text(
    aes(label = label, hjust = if_else(is_higher, -0.3, 1.3)), family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt,
    colour = chart_ink[["secondary"]]
  ) +
  scale_colour_manual(values = c(`TRUE` = chart_fills[["accent"]], `FALSE` = chart_fills[["other"]]), guide = "none") +
  scale_y_discrete(limits = levels(metro_rows$metro_label), labels = \(labels) parse(text = if_else(
    labels %in% case_study_metro_labels, sprintf('bold("%s")', labels), sprintf('"%s"', labels)
  ))) +
  scale_x_continuous(expand = expansion(mult = c(0.9, 0.55)), breaks = c(0.95, 1, 1.05), labels = label_number(accuracy = 0.01)) +
  coord_cartesian(clip = "off") +
  labs(
    title = "04  WHERE WEEKEND OZONE RISES",
    subtitle = "Median site, metros with 5+ sites",
    caption = sprintf(
      "HOUSTON %s, DFW %s",
      case_study_ozone_metros$label[case_study_ozone_metros$region == "Houston"],
      case_study_ozone_metros$label[case_study_ozone_metros$region == "Dallas-Fort Worth"]
    ),
    x = NULL,
    y = NULL
  ) +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 7.5),
    plot.caption = element_text(
      family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["label"]] - 0.5,
      hjust = 0, margin = margin(t = 6)
    )
  )

no2_summary <- filter(weekend_summary, pollutant == "NO2")

ozone_summary <- filter(weekend_summary, pollutant == "Ozone")

top_ozone_metro <- slice_min(ozone_weekend_metros, metro_rank, n = 1, with_ties = FALSE)

stopifnot(
  "NO2 at the median site is about a fifth lower on weekends, as the title says" = round(1 - no2_summary$median_ratio, 1) == 0.2,
  "Ozone at the median site is lower on weekends, as the subtitle says" = ozone_summary$median_ratio < 1,
  "The top metro's ozone is higher on weekends" = top_ozone_metro$median_ratio > 1
)

weekend_header <- chart_header(
  "FIGURE 2A.7  /  WEEKEND EFFECT  /  APRIL TO OCTOBER",
  "Weekend NO2 runs a fifth below weekdays",
  sprintf(
    str_c(
      "Ozone at the median site is %.1f%% lower on weekends, and higher at %.0f%% of sites.\n",
      "%s leads at %+.1f%%, consistent with VOC-limited ozone, which rises when NOx falls."
    ),
    100 * (1 - ozone_summary$median_ratio), ozone_summary$pct_higher_on_weekends, top_ozone_metro$metro_label,
    100 * (top_ozone_metro$median_ratio - 1)
  ),
  key = tribble(
    ~mark, ~colour,                                ~label,
    "dot", chart_fills[["accent"]],                "Median site",
    "bar", alpha(chart_fills[["accent"]], 0.45),   "Middle half of sites"
  )
)

weekend_footer <- chart_footer(str_c(
  "EPA AQS daily data, April to October 2021 to 2025, five-year sites, without event and fireworks days. Weekend\n",
  "means Saturday and Sunday. Memorial Day, Independence Day and Labor Day are left out of both groups."
))

weekend_figure <- chart_compose(weekend_header, list(ratio_panel, day_panel, scatter_panel, free(ozone_metro_panel)), weekend_footer)

weekend_figure_path <- here("figures", "phase2", "2a.07_weekend.png")

save_started <- Sys.time()

ggsave(weekend_figure_path, weekend_figure, width = 6.5, height = 6.6, dpi = 300)

stopifnot(
  "2a.07_weekend.png was written (close any viewer of it and rerun this step)" =
    file.mtime(weekend_figure_path) >= save_started - 2
)

rm(weekend_site_days, day_type_means)
invisible(gc())



# 7. SAVE THE CASE-STUDY CHECKPOINT ----
# Site-days of every Harris, Dallas and Tarrant site in a case-study group, with a flag for days on a monitor's new
# method. 2b_daily_case_study.R starts from these files, so the national table is only built here
daily_case_study <- daily_sites %>%
  filter(pollutant %in% case_study_pollutants) %>%
  inner_join(site_groups, by = "site_id", relationship = "many-to-one")

daily_case_study <- daily_case_study %>%
  left_join(select(method_changes, site_id, pollutant, change_date), by = c("site_id", "pollutant"), relationship = "many-to-one") %>%
  mutate(is_post_method_change = coalesce(date_local >= change_date, FALSE)) %>%
  select(-change_date)

daily_case_study <- daily_case_study %>%
  select(
    site_id, local_site_name, site_group, region, pollutant, date_local, year, month, year_month, season, season_year,
    is_full_season, day_of_week, is_weekend, units_of_measure, value, n_instruments, method_types, n_years_active,
    is_five_year, event_name, event_class, is_agency_event_flagged, is_post_method_change
  ) %>%
  arrange(pollutant, site_id, date_local)

# Each instrument's own daily value, for method histories and collocated FEM and FRM comparisons
daily_case_study_instruments <- daily_instruments %>%
  semi_join(daily_case_study, by = c("pollutant", "site_id")) %>%
  select(site_id, pollutant, poc, method_code, method_type, date_local, value) %>%
  arrange(pollutant, site_id, poc, date_local)

# Section 5's site-months for the five-year case-study sites, so 2b's monthly profiles follow the same 75% rule
daily_case_study_months <- site_months %>%
  filter(pollutant %in% case_study_pollutants) %>%
  inner_join(site_groups, by = "site_id", relationship = "many-to-one") %>%
  select(
    site_id, site_group, region, pollutant, year, month, year_month, season, season_year, is_full_season,
    n_days, n_ordinary_days, sampling_interval, expected_days, is_complete, mean_value, mean_ordinary
  ) %>%
  arrange(pollutant, site_id, year_month)

case_study_keys <- daily_case_study %>%
  count(pollutant, site_id, date_local) %>%
  filter(n > 1)

five_year_case_study_sites <- daily_case_study %>%
  filter(is_five_year) %>%
  distinct(pollutant, site_group, site_id) %>%
  count(pollutant, site_group, name = "n_sites")

print(five_year_case_study_sites)

first_flagged_days <- daily_case_study %>%
  filter(is_post_method_change) %>%
  summarise(first_flagged = min(date_local), .by = c(site_id, pollutant)) %>%
  right_join(method_changes, by = c("site_id", "pollutant"), relationship = "one-to-one")

five_year_case_study_days <- daily_case_study %>%
  filter(is_five_year) %>%
  nrow()

stopifnot(
  "One row per pollutant, site and day" = nrow(case_study_keys) == 0,
  "Every case-study site-day has a group and a value" = !anyNA(daily_case_study$site_group) && !anyNA(daily_case_study$value),
  "No Bayport-adjacent site is saved" =
    !any(daily_case_study$site_id %in% harris_groups$site_id[harris_groups$site_group == "Excluded: Bayport-adjacent"]),
  "Only Harris, Dallas and Tarrant sites are saved" = all(str_sub(daily_case_study$site_id, 1, 6) %in% region_lookup$county_id),
  "Five-year sites per group: PM2.5 3, 1, 3; ozone 6, 10, 6; NO2 4, 3, 4; SO2 3, 1, 0" =
    identical(five_year_case_study_sites$n_sites, c(3L, 1L, 3L, 6L, 10L, 6L, 4L, 3L, 4L, 3L, 1L)),
  "Every listed method change is flagged from its first day" = all(first_flagged_days$first_flagged == first_flagged_days$change_date),
  "Instrument-days add up to the site-days' instrument counts" =
    nrow(daily_case_study_instruments) == sum(daily_case_study$n_instruments),
  "Site-months hold every five-year case-study site-day once" = sum(daily_case_study_months$n_days) == five_year_case_study_days
)

case_study_checkpoint <- list(
  daily_case_study = daily_case_study,
  daily_case_study_instruments = daily_case_study_instruments,
  daily_case_study_months = daily_case_study_months
)

# Each file is reloaded and checked against the object in memory (save_checkpoints() in utils.R)
case_study_checkpoint_paths <- save_checkpoints(case_study_checkpoint, processed_dir)

case_study_dictionary <- tribble(
  ~table,                         ~column,                   ~description,
  "daily_case_study",             "site_id",                 "AQS site ID: state-county-site; joins to sites, aqs_long_clean and hourly_case_study",
  "daily_case_study",             "local_site_name",         "Site name given by the reporting agency",
  "daily_case_study",             "site_group",              "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "daily_case_study",             "region",                  "Houston or Dallas-Fort Worth",
  "daily_case_study",             "pollutant",               "PM2.5, Ozone, NO2 or SO2; CO is left out of the case study",
  "daily_case_study",             "date_local",              "Sample date in local time",
  "daily_case_study",             "year",                    "Calendar year",
  "daily_case_study",             "month",                   "Month, ordered Jan to Dec",
  "daily_case_study",             "year_month",              "First day of the month",
  "daily_case_study",             "season",                  "Meteorological season; winter is Dec to Feb",
  "daily_case_study",             "season_year",             "Year the season belongs to; December counts toward the next year's winter",
  "daily_case_study",             "is_full_season",          "FALSE in the partial winters inside the window (Jan to Feb 2021 and Dec 2025)",
  "daily_case_study",             "day_of_week",             "Day of the week, ordered Mon to Sun",
  "daily_case_study",             "is_weekend",              "TRUE on Saturday and Sunday",
  "daily_case_study",             "units_of_measure",        "Units of the original values (ppm, ppb, or µg/m³ at local conditions)",
  "daily_case_study",             "value",                   "PM2.5 daily mean or gas daily max in original units; collocated instruments averaged",
  "daily_case_study",             "n_instruments",           "Instruments averaged into the site-day",
  "daily_case_study",             "method_types",            "FRM, FEM or FEM+FRM for the instruments averaged that day",
  "daily_case_study",             "n_years_active",          "Study years (0 to 5) in which the site met the 75% completeness rule for the pollutant",
  "daily_case_study",             "is_five_year",            "TRUE when the site has all five study years for the pollutant",
  "daily_case_study",             "event_name",              "Event from events.csv or a fireworks window; NA when no event applies",
  "daily_case_study",             "event_class",             "None, Event (an events.csv window) or Fireworks (PM2.5 only)",
  "daily_case_study",             "is_agency_event_flagged", "TRUE when any instrument that day has EPA's exceptional-event flag (Included)",
  "daily_case_study",             "is_post_method_change",   "TRUE on or after the site's method change in 2a CONFIG method_changes (5 monitors)",
  "daily_case_study_instruments", "site_id",                 "AQS site ID; joins to daily_case_study",
  "daily_case_study_instruments", "pollutant",               "PM2.5, Ozone, NO2 or SO2",
  "daily_case_study_instruments", "poc",                     "Parameter occurrence code; separates instruments of one pollutant at one site",
  "daily_case_study_instruments", "method_code",             "AQS method code; FRM or FEM methods only",
  "daily_case_study_instruments", "method_type",             "FRM or FEM, from EPA's methods table",
  "daily_case_study_instruments", "date_local",              "Sample date in local time",
  "daily_case_study_instruments", "value",                   "The instrument's PM2.5 daily mean or gas daily maximum in original units",
  "daily_case_study_months",      "site_id",                 "AQS site ID; five-year sites, ozone only those reporting every winter (2a section 5)",
  "daily_case_study_months",      "site_group",              "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "daily_case_study_months",      "region",                  "Houston or Dallas-Fort Worth",
  "daily_case_study_months",      "pollutant",               "PM2.5, Ozone, NO2 or SO2",
  "daily_case_study_months",      "year",                    "Calendar year",
  "daily_case_study_months",      "month",                   "Month, ordered Jan to Dec",
  "daily_case_study_months",      "year_month",              "First day of the month",
  "daily_case_study_months",      "season",                  "Meteorological season; winter is Dec to Feb",
  "daily_case_study_months",      "season_year",             "Year the season belongs to; December counts toward the next year's winter",
  "daily_case_study_months",      "is_full_season",          "FALSE in the partial winters inside the window (Jan to Feb 2021 and Dec 2025)",
  "daily_case_study_months",      "n_days",                  "Days with data in the site-month",
  "daily_case_study_months",      "n_ordinary_days",         "Days with data and no event or fireworks label",
  "daily_case_study_months",      "sampling_interval",       "Days between scheduled samples: 1, 3 or 6 for PM2.5, 1 for the gases",
  "daily_case_study_months",      "expected_days",           "Days in the month divided by the sampling interval",
  "daily_case_study_months",      "is_complete",             "TRUE with at least 75% of the expected days; only these enter monthly profiles",
  "daily_case_study_months",      "mean_value",              "Mean of the site-month's daily values in original units",
  "daily_case_study_months",      "mean_ordinary",           "Mean over days with no event or fireworks label; NA when the month has none"
)

# Stops on a saved column without a description, or a description of a column that was not saved
case_study_dictionary <- document_tables(case_study_checkpoint, case_study_dictionary)

# 1a, 1d and 1e add their own rows to both shared files, and only the rows of these three tables are replaced here
replace_own_rows(case_study_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

case_study_manifest <- manifest_rows(case_study_checkpoint, case_study_checkpoint_paths)

stopifnot("Every case-study file is under GitHub's 100 MiB limit" = all(case_study_manifest$under_github_limit))

checkpoint_manifest <- replace_own_rows(case_study_manifest, manifest_path, key = "file", col_types = manifest_col_types)

print(checkpoint_manifest, width = Inf)
