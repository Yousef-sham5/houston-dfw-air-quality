# SETUP ----
library(dplyr)
library(readr)
library(tidyr)
library(stringr)
library(lubridate)
library(ggplot2)
library(scales)
library(patchwork)
library(here)

source(here("R", "utils.R")) # study_years, read_events(), manifest and save helpers, chart theme

load_chart_fonts()



# CONFIG ----
processed_dir <- here("data", "processed")

# CSV records go to a folder per phase; checkpoints, the dictionary and the manifest stay in data/processed
records_dir <- file.path(processed_dir, "phase2")

dir.create(records_dir, recursive = TRUE, showWarnings = FALSE)

# Hourly pollutants from 1d and hourly wind and temperature from 1e, joined on site_id and datetime_utc
hourly_files <- c("hourly_case_study.rds", "hourly_weather.rds")

hourly_pollutants <- c("Ozone", "NO2", "SO2")

# Distance of every Harris site to the land-cut Ship Channel and its group, from 1c
harris_groups_path <- here("data", "reference", "harris_site_channel_distance.csv")

# The distance rule set in 1c. Houston other sites in the transition band sit nearer the channel than the rest and are
# left out in one check
ship_channel_km <- 7.5

transition_km <- 15

transition_band <- str_c(ship_channel_km, " to ", transition_km, " km")

study_start <- make_date(min(study_years), 1, 1)

study_end <- make_date(max(study_years), 12, 31)

possible_hours <- 24 * (as.numeric(study_end - study_start) + 1)

# A month counts as covered in figure 2C.1 when it holds at least 75% of its hours, the share behind a complete day
covered_month_share <- 0.75

# The two Texas events in the hourly data. 2b covers them, so 2c leaves their hours out of the ordinary hours
case_study_events <- c("Winter Storm Uri", "Hurricane Beryl")

# Copied from 2a CONFIG. Weekday holidays from April to October that weekend comparisons leave out, since NO2 on them
# is closer to a Sunday than to a weekday: Memorial Day, Independence Day as observed and Labor Day
weekday_holidays <- tibble(year = study_years) %>%
  mutate(july_4 = make_date(year, 7, 4)) %>%
  mutate(`Memorial Day` = floor_date(make_date(year, 5, 31), "week", week_start = 1)) %>%
  mutate(`Independence Day` = july_4 + case_when(wday(july_4, week_start = 1) == 6 ~ -1, wday(july_4, week_start = 1) == 7 ~ 1, .default = 0)) %>%
  mutate(`Labor Day` = floor_date(make_date(year, 9, 7), "week", week_start = 1)) %>%
  select(-july_4) %>%
  pivot_longer(-year, names_to = "holiday", values_to = "date_local")

# The checks every later section runs beside the main result, as in 2b. The memo-list grouping moves no hourly site, so it
# is not repeated here
hourly_check_levels <- c(
  "Main",
  "Without the transition band",
  "Without hours after the method change",
  "Without Deer Park #2 after its move"
)

# Daily cycles (section 2). Hours are local standard time all year, so a 7 to 9 am summer rush hour on daylight time
# shows as hours 6 to 8. The afternoon window brackets the ozone peak
cycle_pollutants <- c("Ozone", "NO2")

morning_hours <- 6:8

afternoon_hours <- 12:16

# Weekend comparisons use April to October, as in 2a section 6
weekend_months <- 4:10

# 95% ranges for the gaps, as in 2b section 7: the days are resampled 1,000 times in whole 14-day runs, because nearby
# days share weather and are not independent. The seed makes every run give the same ranges
bootstrap_block_days <- 14

bootstrap_reps <- 1000

bootstrap_seed <- 2026

# SO2 spike hours (section 4): at least 5 ppb, the spike cutoff in 2b and 2.5 times the 2 ppb detection limit at three of
# the four sites. 10 ppb is a check. Daytime is 9 am to 6 pm, when daytime heating mixes the air near the ground
so2_spike_ppb <- 5

so2_check_spike_ppb <- 10

daytime_hours <- 9:17

stopifnot(
  "The five study years hold 43,824 hours" = possible_hours == 43824,
  "The SO2 check cutoff is above the main one" = so2_check_spike_ppb > so2_spike_ppb,
  "The cycle pollutants are hourly pollutants" = all(cycle_pollutants %in% hourly_pollutants),
  "The morning and afternoon windows do not overlap" = !any(morning_hours %in% afternoon_hours),
  "1c has written the Harris site groups (run 1c first)" = file.exists(harris_groups_path),
  "The transition band starts at the Ship Channel cutoff" = ship_channel_km < transition_km,
  "Both events are in events.csv" = all(case_study_events %in% read_events()$event_name),
  "Three holidays in each study year, all on weekdays" =
    nrow(weekday_holidays) == 3 * length(study_years) && all(wday(weekday_holidays$date_local, week_start = 1) <= 5),
  "Holiday dates match the federal calendar" =
    all(ymd(c("2021-05-31", "2021-07-05", "2023-07-04", "2025-05-26", "2025-09-01")) %in% weekday_holidays$date_local)
)



# 1. HOURLY SITES, COVERAGE AND FLAGS ----
# The hourly checkpoints from 1d and 1e, checked against the manifest, and the Harris site groups from 1c
hourly_case_study <- read_rds(file.path(processed_dir, "hourly_case_study.rds"))

hourly_weather <- read_rds(file.path(processed_dir, "hourly_weather.rds"))

input_rows <- c(nrow(hourly_case_study), nrow(hourly_weather))

input_check <- read_csv(manifest_path, col_types = manifest_col_types) %>%
  filter(file %in% hourly_files) %>%
  mutate(md5_on_disk = unname(tools::md5sum(file.path(processed_dir, file))))

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

monitors <- hourly_case_study %>%
  distinct(site_group, region, site_id, local_site_name, pollutant)

# Houston sites must carry the group 1c set from distance; a mismatch means 1d ran before the latest 1c
houston_group_check <- monitors %>%
  filter(region == "Houston") %>%
  distinct(site_id, site_group) %>%
  inner_join(
    select(harris_groups, site_id, group_from_1c = site_group, memo_site_group),
    by = "site_id", relationship = "one-to-one"
  )

houston_site_count <- n_distinct(monitors$site_id[monitors$region == "Houston"])

event_names <- unique(na.omit(hourly_case_study$event_name))

stopifnot(
  "The manifest lists both hourly files" = setequal(input_check$file, hourly_files),
  "The inputs match the manifest (rerun 1d and 1e if not)" = all(input_check$md5 == input_check$md5_on_disk),
  "Row counts match the manifest" = identical(input_check$rows[match(hourly_files, input_check$file)], input_rows),
  "16 monitors at 9 sites" = nrow(monitors) == 16 && n_distinct(monitors$site_id) == 9,
  "Only ozone, NO2 and SO2" = setequal(monitors$pollutant, hourly_pollutants),
  "Every group has a chart colour" = all(monitors$site_group %in% names(site_group_colours)),
  "One row per monitor and hour" = !anyDuplicated(hourly_case_study[c("site_id", "pollutant", "datetime_utc")]),
  "One weather row per site and hour" = !anyDuplicated(hourly_weather[c("site_id", "datetime_utc")]),
  "Weather covers the same 9 sites" = setequal(hourly_weather$site_id, monitors$site_id),
  "Every Houston hourly site has a distance from 1c" = nrow(houston_group_check) == houston_site_count,
  "Houston groups match 1c (rerun 1d after 1c if not)" = all(houston_group_check$site_group == houston_group_check$group_from_1c),
  "The memo-list grouping moves no hourly site" = all(houston_group_check$site_group == houston_group_check$memo_site_group),
  "The hourly events are Uri and Beryl" = setequal(event_names, case_study_events)
)

# Wind and temperature for the same site and hour. Harvard Street carries Bayland Park's temperature and Croquet's wind (1e)
weather_columns <- hourly_weather %>%
  select(
    site_id, datetime_utc, weather_datetime_local = datetime_local, temp_c, temp_source_site, wind_speed_ms, wind_dir_deg,
    wind_sector, wind_u_ms, wind_v_ms, wind_source_site, is_calm, is_wind_spike, is_sonic_wind
  )

hourly <- hourly_case_study %>%
  mutate(site_group = factor(site_group, levels = names(site_group_colours))) %>%
  mutate(pollutant = factor(pollutant, levels = hourly_pollutants)) %>%
  left_join(weather_columns, by = c("site_id", "datetime_utc"), relationship = "many-to-one")

stopifnot(
  "The join keeps every pollutant hour" = nrow(hourly) == nrow(hourly_case_study),
  "Matched hours agree on local time" = all(hourly$weather_datetime_local == hourly$datetime_local, na.rm = TRUE),
  "Every hour with a wind sector has a calm flag" = all(is.na(hourly$wind_sector) == is.na(hourly$is_calm))
)

hourly <- hourly %>%
  select(-weather_datetime_local)

# Hour rules every later section uses. A valid day follows the daily rule (ozone: 13 of 17 8-hour means; NO2 and SO2: 18
# of 24 hours). Ordinary hours also leave out Uri, Beryl and wildfire-flagged hours. Direction hours have a wind
# direction, with calm hours (direction unreliable) and the one wind-spike hour left out
hourly <- hourly %>%
  mutate(is_valid_day = if_else(pollutant == "Ozone", coalesce(is_valid_ozone_day, FALSE), is_complete_day)) %>%
  mutate(is_ordinary_hour = is_valid_day & is.na(event_name) & !is_wildfire_flagged) %>%
  mutate(has_wind = !is.na(wind_sector)) %>%
  mutate(is_direction_hour = has_wind & !coalesce(is_calm, FALSE) & !coalesce(is_wind_spike, FALSE)) %>%
  mutate(is_weekday_holiday = date_local %in% weekday_holidays$date_local)

# Distance to the channel per site. Houston other sites in the transition band are left out in one check
site_roles <- monitors %>%
  distinct(site_id, site_group) %>%
  left_join(select(harris_groups, site_id, km_to_channel, distance_band), by = "site_id", relationship = "one-to-one") %>%
  mutate(in_transition_band = coalesce(distance_band == transition_band & site_group == "Houston other", FALSE))

hourly <- hourly %>%
  left_join(select(site_roles, site_id, in_transition_band), by = "site_id", relationship = "many-to-one")

transition_sites <- site_roles$site_id[site_roles$in_transition_band]

dfw_sites <- site_roles %>%
  filter(site_group == "Dallas-Fort Worth")

stopifnot(
  "Houston Harvard Street is the one hourly site in the transition band" = identical(transition_sites, "48-201-0417"),
  "Dallas-Fort Worth sites have no channel distance" = all(is.na(dfw_sites$km_to_channel))
)

# When each flagged change starts: Harvard Street NO2's new method, the Deer Park #2 move and each sonic wind sensor
method_change_starts <- hourly %>%
  filter(is_post_method_change) %>%
  summarise(method_change_from = min(date_local), .by = c(site_id, pollutant))

relocation_starts <- hourly %>%
  filter(is_post_relocation) %>%
  summarise(relocated_from = min(date_local), .by = c(site_id, pollutant))

own_wind_days <- hourly_weather %>%
  filter(!is.na(wind_sector), wind_source_site == site_id) %>%
  distinct(site_id, date_local)

sonic_wind_starts <- hourly_weather %>%
  filter(is_sonic_wind) %>%
  summarise(sonic_wind_from = min(date_local), .by = site_id) %>%
  inner_join(
    summarise(own_wind_days, first_own_wind = min(date_local), .by = site_id),
    by = "site_id", relationship = "one-to-one"
  ) %>%
  filter(sonic_wind_from > first_own_wind) %>%
  select(site_id, sonic_wind_from)

# Longest run of whole days without wind, from the wind each site uses (Croquet's at Harvard Street)
wind_gaps <- hourly_weather %>%
  filter(!is.na(wind_sector)) %>%
  distinct(site_id, date_local) %>%
  arrange(site_id, date_local) %>%
  mutate(gap_days = as.numeric(date_local - lag(date_local)) - 1, .by = site_id) %>%
  summarise(longest_wind_gap_days = max(gap_days, na.rm = TRUE), .by = site_id)

print(method_change_starts)
print(relocation_starts)
print(sonic_wind_starts)

stopifnot(
  "Only Harvard Street NO2 changed method, from 2024-04-22" =
    nrow(method_change_starts) == 1 && method_change_starts$site_id == "48-201-0417" &&
    method_change_starts$pollutant == "NO2" && method_change_starts$method_change_from == ymd("2024-04-22"),
  "Deer Park #2 is flagged from 2025-05-30 for all three pollutants" =
    nrow(relocation_starts) == 3 && all(relocation_starts$site_id == "48-201-1039") &&
    all(relocation_starts$relocated_from == ymd("2025-05-30")),
  "Five sites switched to a sonic wind sensor" = nrow(sonic_wind_starts) == 5,
  "Harvard Street has no wind sensor of its own" = !"48-201-0417" %in% own_wind_days$site_id
)

# One row per monitor: coverage by year, the hours each rule keeps, the weather behind them and the checks it is in
year_hours <- tibble(year = study_years) %>%
  mutate(hours_in_year = 24 * (365 + leap_year(year)))

hours_per_year <- hourly %>%
  mutate(year = year(date_local)) %>%
  count(site_id, pollutant, year) %>%
  inner_join(year_hours, by = "year", relationship = "many-to-one") %>%
  mutate(pct_hours = round(100 * n / hours_in_year, 1)) %>%
  mutate(year = str_c("pct_hours_", year)) %>%
  select(site_id, pollutant, year, pct_hours) %>%
  pivot_wider(names_from = year, values_from = pct_hours, values_fill = 0)

# Ordinary hours with a usable wind direction in each of the 12 sectors. A pollution rose is only as reliable as its
# emptiest sector, so the smallest count is kept
sector_hours <- hourly %>%
  filter(is_ordinary_hour, is_direction_hour) %>%
  count(site_id, pollutant, wind_sector) %>%
  complete(nesting(site_id, pollutant), wind_sector = seq(0, 330, 30), fill = list(n = 0L)) %>%
  summarise(min_sector_hours = min(n), .by = c(site_id, pollutant))

hourly_inventory <- hourly %>%
  summarise(
    method_codes = str_c(sort(unique(method_code)), collapse = "; "),
    first_hour = format(min(datetime_local), "%Y-%m-%d %H:%M"),
    last_hour = format(max(datetime_local), "%Y-%m-%d %H:%M"),
    n_hours = n(),
    n_valid_day_hours = sum(is_valid_day),
    n_event_hours = sum(!is.na(event_name)),
    n_wildfire_hours = sum(is_wildfire_flagged),
    n_ordinary_hours = sum(is_ordinary_hour),
    n_holiday_hours = sum(is_weekday_holiday),
    n_post_method_change_hours = sum(is_post_method_change),
    n_post_relocation_hours = sum(is_post_relocation),
    pct_below_mdl = round(100 * mean(below_mdl), 1),
    pct_with_temperature = round(100 * mean(!is.na(temp_c)), 1),
    pct_with_wind = round(100 * mean(has_wind), 1),
    wind_from_site = wind_source_site[has_wind][1],
    pct_calm = round(100 * mean(is_calm[has_wind]), 1),
    n_direction_hours = sum(is_ordinary_hour & is_direction_hour),
    .by = c(site_group, region, site_id, local_site_name, pollutant)
  )

hourly_inventory <- hourly_inventory %>%
  mutate(pct_hours = round(100 * n_hours / possible_hours, 1)) %>%
  mutate(pct_ordinary_hours = round(100 * n_ordinary_hours / possible_hours, 1)) %>%
  mutate(pct_direction_hours = round(100 * n_direction_hours / possible_hours, 1)) %>%
  left_join(hours_per_year, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(sector_hours, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(select(site_roles, site_id, km_to_channel, distance_band, in_transition_band), by = "site_id", relationship = "many-to-one") %>%
  left_join(method_change_starts, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(relocation_starts, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(sonic_wind_starts, by = "site_id", relationship = "many-to-one") %>%
  left_join(wind_gaps, by = "site_id", relationship = "many-to-one")

hourly_inventory <- hourly_inventory %>%
  mutate(
    left_out_in_checks = case_when(
      in_transition_band & n_post_method_change_hours > 0 ~ "Without the transition band; without hours after the method change",
      in_transition_band ~ "Without the transition band",
      n_post_relocation_hours > 0 ~ "Without Deer Park #2 after its move",
      .default = NA_character_
    )
  )

hourly_inventory <- hourly_inventory %>%
  select(
    site_group, region, site_id, local_site_name, pollutant, km_to_channel, distance_band, in_transition_band,
    left_out_in_checks, method_codes, method_change_from, relocated_from, first_hour, last_hour, n_hours, pct_hours,
    starts_with("pct_hours_"), n_valid_day_hours, n_event_hours, n_wildfire_hours, n_ordinary_hours, pct_ordinary_hours,
    n_holiday_hours, n_post_method_change_hours, n_post_relocation_hours, pct_below_mdl, pct_with_temperature,
    pct_with_wind, wind_from_site, sonic_wind_from, longest_wind_gap_days, pct_calm, n_direction_hours,
    pct_direction_hours, min_sector_hours
  ) %>%
  arrange(pollutant, site_group, local_site_name)

hourly_inventory %>%
  select(pollutant, site_group, local_site_name, pct_hours, pct_ordinary_hours, pct_with_wind, pct_calm, pct_direction_hours, min_sector_hours) %>%
  print(n = Inf, width = Inf)

stopifnot(
  "One row per monitor" = nrow(hourly_inventory) == 16 && !anyDuplicated(hourly_inventory[c("site_id", "pollutant")]),
  "The inventory holds every hour" = sum(hourly_inventory$n_hours) == nrow(hourly),
  "142 wildfire-flagged ozone hours" = sum(hourly_inventory$n_wildfire_hours) == 142,
  "14,108 Harvard Street NO2 hours after the method change" = sum(hourly_inventory$n_post_method_change_hours) == 14108,
  "Every monitor has temperature on at least 97% of its hours" = all(hourly_inventory$pct_with_temperature >= 97),
  "Every monitor has wind in all 12 sectors on at least 300 ordinary hours each" = all(hourly_inventory$min_sector_hours >= 300),
  "Ordinary hours are a subset of all hours" = all(hourly_inventory$n_ordinary_hours <= hourly_inventory$n_valid_day_hours)
)

# The same hours under each check, stacked with a site_set label. Reused in sections 2 to 6; pass only the columns a
# step needs, since four copies of the full table would not fit comfortably in memory
hourly_site_sets <- function(hours) {
  versions <- list(
    hours %>%
      mutate(site_set = "Main"),
    hours %>%
      filter(!in_transition_band) %>%
      mutate(site_set = "Without the transition band"),
    hours %>%
      filter(!is_post_method_change) %>%
      mutate(site_set = "Without hours after the method change"),
    hours %>%
      filter(!is_post_relocation) %>%
      mutate(site_set = "Without Deer Park #2 after its move")
  )
  bind_rows(versions) %>%
    mutate(site_set = factor(site_set, levels = hourly_check_levels))
}

ordinary_site_sets <- hourly %>%
  filter(is_ordinary_hour) %>%
  select(pollutant, site_group, site_id, datetime_utc, in_transition_band, is_post_method_change, is_post_relocation) %>%
  hourly_site_sets()

site_set_counts <- ordinary_site_sets %>%
  summarise(n_monitors = n_distinct(site_id), n_hours = n(), .by = c(site_set, pollutant, site_group)) %>%
  arrange(site_set, pollutant, site_group)

print(site_set_counts, n = Inf)

main_monitor_counts <- site_set_counts$n_monitors[site_set_counts$site_set == "Main"]

transition_monitor_counts <- site_set_counts$n_monitors[site_set_counts$site_set == "Without the transition band"]

stopifnot(
  "Main monitors per group: ozone 2, 2, 2; NO2 2, 2, 2; SO2 3, 1" = identical(main_monitor_counts, c(2L, 2L, 2L, 2L, 2L, 2L, 3L, 1L)),
  "Without the transition band, Houston other has Bayland Park alone for ozone and NO2" =
    identical(transition_monitor_counts, c(2L, 1L, 2L, 2L, 1L, 2L, 3L, 1L))
)

# Ordinary hours in which every group has at least one monitor reporting, so hour-by-hour comparisons stay balanced
groups_per_pollutant <- site_set_counts %>%
  filter(site_set == "Main") %>%
  count(pollutant, name = "n_groups")

same_hour_coverage <- ordinary_site_sets %>%
  distinct(site_set, pollutant, site_group, datetime_utc) %>%
  count(site_set, pollutant, datetime_utc, name = "groups_reporting") %>%
  inner_join(groups_per_pollutant, by = "pollutant", relationship = "many-to-one") %>%
  summarise(hours_every_group = sum(groups_reporting == n_groups), .by = c(site_set, pollutant)) %>%
  mutate(pct_every_group = round(100 * hours_every_group / possible_hours, 1)) %>%
  arrange(site_set, pollutant)

print(same_hour_coverage)

main_same_hour <- same_hour_coverage %>%
  filter(site_set == "Main")

main_coverage_floor <- floor(min(main_same_hour$pct_every_group))

lowest_same_hour <- same_hour_coverage %>%
  slice_min(pct_every_group, n = 1, with_ties = FALSE)

stopifnot(
  "In the main set every group reports together in at least 95% of hours" = all(main_same_hour$pct_every_group >= 95),
  "Every check keeps every group together in at least 85% of hours" = all(same_hour_coverage$pct_every_group >= 85),
  "The transition check is the thinnest, since Bayland Park alone carries Houston other" =
    lowest_same_hour$site_set == "Without the transition band"
)

# How many hours each rule keeps, per pollutant and group: all hours, valid days, ordinary hours, and those with a
# usable wind direction
hour_funnel <- hourly %>%
  summarise(
    n_monitors = n_distinct(site_id),
    all_hours = n(),
    valid_day_hours = sum(is_valid_day),
    ordinary_hours = sum(is_ordinary_hour),
    with_wind_direction = sum(is_ordinary_hour & is_direction_hour),
    .by = c(pollutant, site_group)
  ) %>%
  arrange(pollutant, site_group)

print(hour_funnel)

funnel_totals <- hour_funnel %>%
  summarise(across(c(all_hours, valid_day_hours, ordinary_hours, with_wind_direction), sum))

print(funnel_totals)

stopifnot(
  "The funnel starts from all 661,545 pollutant-hours" = funnel_totals$all_hours == nrow(hourly_case_study),
  "Each rule keeps fewer hours than the one before" =
    funnel_totals$valid_day_hours <= funnel_totals$all_hours &&
    funnel_totals$ordinary_hours <= funnel_totals$valid_day_hours &&
    funnel_totals$with_wind_direction <= funnel_totals$ordinary_hours
)

# Figure 2C.1: when each monitor and wind sensor reported, and how many hours each keeps for the analysis
short_site_name <- function(local_site_name) {
  local_site_name %>%
    str_remove("^Houston (?!East$)") %>%
    str_remove(" Airport Executive$")
}

transition_names <- short_site_name(monitors$local_site_name[monitors$site_id %in% transition_sites]) %>%
  unique()

bold_row_label <- function(row_keys) {
  names_only <- str_remove(row_keys, "^[^|]*\\|")
  parse(text = if_else(names_only %in% transition_names, sprintf('bold("%s")', names_only), sprintf('"%s"', names_only)))
}

layer_levels <- c(hourly_pollutants, "Wind")

pollutant_months <- hourly %>%
  mutate(month_start = floor_date(date_local, "month")) %>%
  mutate(layer = as.character(pollutant)) %>%
  count(layer, site_id, local_site_name, site_group, month_start, name = "n_hours")

wind_months <- hourly_weather %>%
  filter(!is.na(wind_sector), wind_source_site == site_id) %>%
  mutate(site_group = factor(site_group, levels = names(site_group_colours))) %>%
  mutate(month_start = floor_date(date_local, "month")) %>%
  mutate(layer = "Wind") %>%
  count(layer, site_id, local_site_name, site_group, month_start, name = "n_hours")

coverage_tiles <- bind_rows(pollutant_months, wind_months) %>%
  mutate(layer = factor(layer, levels = layer_levels)) %>%
  mutate(month_days = unname(days_in_month(month_start))) %>%
  mutate(month_mid = month_start + month_days / 2) %>%
  mutate(share = n_hours / (24 * month_days)) %>%
  mutate(is_covered = share >= covered_month_share) %>%
  mutate(group_colour = unname(site_group_colours[as.character(site_group)])) %>%
  mutate(tile_colour = if_else(is_covered, group_colour, chart_fills[["other"]])) %>%
  mutate(short_name = short_site_name(local_site_name))

coverage_rows <- coverage_tiles %>%
  distinct(layer, site_group, short_name, site_id) %>%
  arrange(layer, site_group, short_name) %>%
  mutate(row_key = str_c(layer, "|", short_name)) %>%
  mutate(row_key = factor(row_key, levels = rev(row_key)))

coverage_tiles <- coverage_tiles %>%
  inner_join(select(coverage_rows, layer, site_id, row_key), by = c("layer", "site_id"), relationship = "many-to-one")

relocation_date <- relocation_starts$relocated_from[1]

relocation_site <- relocation_starts$site_id[1]

coverage_marks <- bind_rows(
  transmute(method_change_starts, layer = as.character(pollutant), site_id, mark_date = method_change_from, mark_colour = chart_ink[["primary"]]),
  transmute(sonic_wind_starts, layer = "Wind", site_id, mark_date = sonic_wind_from, mark_colour = chart_ink[["primary"]]),
  tibble(layer = layer_levels, site_id = relocation_site, mark_date = relocation_date, mark_colour = chart_fills[["accent"]])
) %>%
  mutate(layer = factor(layer, levels = layer_levels)) %>%
  inner_join(select(coverage_rows, layer, site_id, row_key), by = c("layer", "site_id"), relationship = "many-to-one")

partial_months <- coverage_tiles %>%
  filter(!is_covered)

stopifnot(
  "24 coverage rows: 6 ozone, 6 NO2, 4 SO2 and 8 own wind sensors" =
    nrow(coverage_rows) == 24 && identical(as.integer(table(coverage_rows$layer)), c(6L, 6L, 4L, 8L)),
  "Every mark sits on a coverage row" = nrow(coverage_marks) == 1 + 5 + 4,
  "No month holds more hours than it has" = all(coverage_tiles$share <= 1)
)

coverage_panel <- ggplot(coverage_tiles) +
  geom_tile(aes(x = month_mid, y = row_key, width = month_days, fill = tile_colour), height = 0.72) +
  geom_point(data = coverage_marks, aes(mark_date, row_key, colour = mark_colour), shape = "|", size = 2.6) +
  facet_grid(layer ~ ., scales = "free_y", space = "free_y", labeller = as_labeller(toupper)) +
  scale_fill_identity() +
  scale_colour_identity() +
  scale_x_date(
    limits = c(study_start, study_end + 1), breaks = make_date(study_years, 1, 1), labels = \(x) year(x),
    expand = expansion(mult = 0.01)
  ) +
  scale_y_discrete(labels = bold_row_label) +
  labs(title = "01  COVERAGE BY MONTH", subtitle = "Hours each monitor and wind sensor reported", x = NULL, y = NULL) +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    panel.spacing = unit(5, "pt"),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.3),
    strip.text.y = element_text(
      angle = 0, hjust = 0, family = chart_fonts[["mono"]], colour = chart_ink[["secondary"]], size = chart_sizes[["axis"]],
      margin = margin(l = 5)
    )
  )

analysis_rows <- hourly_inventory %>%
  mutate(short_name = short_site_name(local_site_name)) %>%
  arrange(pollutant, site_group, short_name) %>%
  mutate(row_key = str_c(pollutant, "|", short_name)) %>%
  mutate(row_key = factor(row_key, levels = rev(row_key))) %>%
  mutate(group_colour = unname(site_group_colours[as.character(site_group)]))

analysis_x_low <- 20 * floor((min(analysis_rows$pct_direction_hours) - 10) / 20)

# Arrows run from the ordinary hours to those left with a wind direction, so each line reads as hours lost. Gaps under
# 4 points are too short for an arrowhead and get a plain line
long_drops <- analysis_rows %>%
  filter(pct_ordinary_hours - pct_direction_hours >= 4)

short_drops <- analysis_rows %>%
  filter(pct_ordinary_hours - pct_direction_hours < 4)

# The dot and ring are named once, above the top row
top_row <- analysis_rows %>%
  filter(row_key == last(levels(row_key)))

mark_labels <- bind_rows(
  transmute(top_row, pollutant, row_key, x = pct_ordinary_hours - 1.5, label = "ORDINARY", hjust = 0),
  transmute(top_row, pollutant, row_key, x = pct_direction_hours + 1.5, label = "WITH WIND", hjust = 1)
)

# The blank layer comes first so the rows keep the group order of panel 01
analysis_panel <- ggplot(analysis_rows, aes(y = row_key)) +
  geom_blank(aes(x = pct_ordinary_hours)) +
  geom_segment(
    data = long_drops, aes(x = pct_ordinary_hours - 1.2, xend = pct_direction_hours + 1.6, yend = row_key),
    colour = chart_ink[["axis"]], linewidth = 0.6, arrow = arrow(length = unit(3, "pt"), type = "closed")
  ) +
  geom_segment(
    data = short_drops, aes(x = pct_direction_hours, xend = pct_ordinary_hours, yend = row_key),
    colour = chart_ink[["axis"]], linewidth = 0.6
  ) +
  geom_text(
    data = mark_labels, aes(x = x, label = label, hjust = hjust), position = position_nudge(y = 0.62),
    family = chart_fonts[["mono"]], size = (chart_sizes[["kicker"]] - 0.8) / .pt, colour = chart_fills[["accent"]]
  ) +
  geom_point(aes(x = pct_direction_hours, colour = group_colour), shape = 21, fill = "white", size = 1.7, stroke = 0.7) +
  geom_point(aes(x = pct_ordinary_hours, colour = group_colour), size = 1.7) +
  geom_text(
    aes(x = pct_direction_hours, label = sprintf("%.0f", pct_direction_hours)), hjust = 1.7,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_ink[["muted"]]
  ) +
  geom_text(
    aes(x = pct_ordinary_hours, label = sprintf("%.0f", pct_ordinary_hours)), hjust = -0.7,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_ink[["secondary"]]
  ) +
  facet_grid(pollutant ~ ., scales = "free_y", space = "free_y", labeller = as_labeller(toupper)) +
  scale_colour_identity() +
  scale_x_continuous(
    limits = c(analysis_x_low, 100), breaks = seq(analysis_x_low, 100, 20), labels = \(x) str_c(x, "%"),
    expand = expansion(mult = c(0.02, 0.06))
  ) +
  scale_y_discrete(labels = bold_row_label) +
  labs(title = "02  HOURS FOR ANALYSIS", subtitle = sprintf("Share of all %s hours, 2021 to 2025", comma(possible_hours)), x = NULL, y = NULL) +
  coord_cartesian(clip = "off") +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    panel.spacing = unit(5, "pt"),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.3),
    strip.text.y = element_text(
      angle = 0, hjust = 0, family = chart_fonts[["mono"]], colour = chart_ink[["secondary"]], size = chart_sizes[["axis"]],
      margin = margin(l = 5)
    )
  )

thinnest_wind <- hourly_inventory %>%
  slice_min(pct_direction_hours, n = 1, with_ties = FALSE)

stopifnot(
  "Every group reports together in at least the share the title gives" = all(main_same_hour$pct_every_group >= main_coverage_floor),
  "The thinnest wind record has a long gap in its wind, as the subtitle says" = thinnest_wind$longest_wind_gap_days > 300
)

coverage_header <- chart_header(
  sprintf("FIGURE 2C.1  /  HOURLY DATA  /  %s TO %s", min(study_years), max(study_years)),
  sprintf("Every group reports together in %s%% of hours", main_coverage_floor),
  sprintf(
    str_c(
      "%s monitors at %s sites, %s hours; %s pass the valid-day, event and wildfire rules.\n",
      "Usable wind direction is thinnest at %s: %s%% of hours, after a %s-day gap in its wind."
    ),
    nrow(monitors), n_distinct(monitors$site_id), comma(funnel_totals$all_hours), comma(funnel_totals$ordinary_hours),
    short_site_name(thinnest_wind$local_site_name), round(thinnest_wind$pct_direction_hours), comma(thinnest_wind$longest_wind_gap_days)
  ),
  key = tribble(
    ~mark,    ~colour,                                      ~label,
    "square", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "square", site_group_colours[["Houston other"]],        "Houston other",
    "square", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",
    "square", chart_fills[["other"]],                       "Month under 75% of hours"
  )
)

coverage_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d, 1e). Ordinary hours: valid day, no Uri, Beryl or wildfire flag. Together: all groups report.\n",
  "Panel 01: black ticks mark Harvard Street's NO2 method change and the sonic wind sensors, teal the Deer Park #2 move.\n",
  "Panel 02: arrows show hours lost without a wind direction. Bold Harvard Street (", transition_band, ") uses Croquet's wind."
))

coverage_figure <- chart_compose(coverage_header, list(coverage_panel, analysis_panel), coverage_footer, widths = c(1.55, 1))

dir.create(here("figures", "phase2"), recursive = TRUE, showWarnings = FALSE)

coverage_figure_path <- here("figures", "phase2", "2c.01_coverage.png")

save_started <- Sys.time()

ggsave(coverage_figure_path, coverage_figure, width = 6.5, height = 7.6, dpi = 300)

stopifnot(
  "2c.01_coverage.png was written (close any viewer of it and rerun this step)" =
    file.mtime(coverage_figure_path) >= save_started - 2
)

# The inventory is saved now as a CSV record, so it can be opened while later sections are built
inventory_records <- list(
  case_study_hourly_inventory = hourly_inventory
)

save_records(inventory_records, records_dir)

inventory_dictionary <- tribble(
  ~table,                        ~column,                      ~description,
  "case_study_hourly_inventory", "site_group",                 "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "case_study_hourly_inventory", "region",                     "Houston or Dallas-Fort Worth",
  "case_study_hourly_inventory", "site_id",                    "AQS site ID: state-county-site",
  "case_study_hourly_inventory", "local_site_name",            "Site name given by the reporting agency",
  "case_study_hourly_inventory", "pollutant",                  "Ozone, NO2 or SO2",
  "case_study_hourly_inventory", "km_to_channel",              "Distance to the land-cut Ship Channel in km, from 1c; NA in Dallas-Fort Worth",
  "case_study_hourly_inventory", "distance_band",              "Within 7.5 km, 7.5 to 15 km or Over 15 km from the channel; NA in Dallas-Fort Worth",
  "case_study_hourly_inventory", "in_transition_band",         "TRUE for Houston other sites 7.5 to 15 km from the channel; left out in one check",
  "case_study_hourly_inventory", "left_out_in_checks",         "The 2c checks that leave out this monitor or some of its hours; NA when none",
  "case_study_hourly_inventory", "method_codes",               "AQS method codes the monitor reported under",
  "case_study_hourly_inventory", "method_change_from",         "First day on the new method (Harvard Street NO2); NA when the method never changed",
  "case_study_hourly_inventory", "relocated_from",             "First day after the Deer Park #2 move; NA at other sites",
  "case_study_hourly_inventory", "first_hour",                 "First hour with data, local standard time (UTC-6)",
  "case_study_hourly_inventory", "last_hour",                  "Last hour with data, local standard time (UTC-6)",
  "case_study_hourly_inventory", "n_hours",                    "Hours with data",
  "case_study_hourly_inventory", "pct_hours",                  "Hours with data as a share of the 43,824 study hours",
  "case_study_hourly_inventory", "pct_hours_2021",             "Hours with data as a share of the hours in 2021",
  "case_study_hourly_inventory", "pct_hours_2022",             "Hours with data as a share of the hours in 2022",
  "case_study_hourly_inventory", "pct_hours_2023",             "Hours with data as a share of the hours in 2023",
  "case_study_hourly_inventory", "pct_hours_2024",             "Hours with data as a share of the hours in 2024",
  "case_study_hourly_inventory", "pct_hours_2025",             "Hours with data as a share of the hours in 2025",
  "case_study_hourly_inventory", "n_valid_day_hours",          "Hours on valid days: 13 of 17 8-hour means for ozone, 18 of 24 hours for NO2 and SO2",
  "case_study_hourly_inventory", "n_event_hours",              "Hours during Winter Storm Uri or Hurricane Beryl",
  "case_study_hourly_inventory", "n_wildfire_hours",           "Hours with the RT wildfire qualifier",
  "case_study_hourly_inventory", "n_ordinary_hours",           "Valid-day hours outside Uri, Beryl and wildfire flags; the hours 2c analyses",
  "case_study_hourly_inventory", "pct_ordinary_hours",         "Ordinary hours as a share of the 43,824 study hours",
  "case_study_hourly_inventory", "n_holiday_hours",            "Hours on the three holidays left out of weekend comparisons",
  "case_study_hourly_inventory", "n_post_method_change_hours", "Hours after the Harvard Street NO2 method change (is_post_method_change)",
  "case_study_hourly_inventory", "n_post_relocation_hours",    "Hours after the Deer Park #2 move (is_post_relocation)",
  "case_study_hourly_inventory", "pct_below_mdl",              "Share of hours below the method detection limit",
  "case_study_hourly_inventory", "pct_with_temperature",       "Share of hours with a temperature (Bayland Park's at Harvard Street)",
  "case_study_hourly_inventory", "pct_with_wind",              "Share of hours with a wind reading (Croquet's at Harvard Street)",
  "case_study_hourly_inventory", "wind_from_site",             "AQS site ID of the wind sensor used",
  "case_study_hourly_inventory", "sonic_wind_from",            "First day on the sonic wind sensor at a site that switched; NA otherwise",
  "case_study_hourly_inventory", "longest_wind_gap_days",      "Longest run of whole days without wind in the wind used",
  "case_study_hourly_inventory", "pct_calm",                   "Share of hours with wind that are calm (below 0.5 m/s)",
  "case_study_hourly_inventory", "n_direction_hours",          "Ordinary hours with a usable wind direction (not calm, not the wind-spike hour)",
  "case_study_hourly_inventory", "pct_direction_hours",        "Ordinary hours with a usable wind direction as a share of the 43,824 study hours",
  "case_study_hourly_inventory", "min_sector_hours",           "Direction hours in the thinnest of the 12 wind sectors"
)

# Stops on a saved column without a description, or a description of a column that was not saved
inventory_dictionary <- document_tables(inventory_records, inventory_dictionary)

replace_own_rows(inventory_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 2. DAILY CYCLES: OZONE AND NO2 ----
# Ozone and NO2 by hour of day on ordinary hours. A group's value at an hour is the mean of its sites' means, so each
# site counts equally
cycle_hours <- hourly %>%
  filter(is_ordinary_hour, pollutant %in% cycle_pollutants) %>%
  mutate(pollutant = factor(as.character(pollutant), levels = cycle_pollutants)) %>%
  select(
    pollutant, site_group, site_id, datetime_utc, date_local, hour_local, season, is_weekend, is_weekday_holiday,
    in_transition_band, is_post_method_change, is_post_relocation, value_ppb
  )

cycle_monitor_hours <- cycle_hours %>%
  count(pollutant, site_group, site_id, hour_local)

stopifnot(
  "Two sites per group for ozone and for NO2" = all(count(distinct(cycle_hours, pollutant, site_group, site_id), pollutant, site_group)$n == 2),
  "Every monitor has all 24 hours of the day" = all(count(cycle_monitor_hours, pollutant, site_id)$n == 24),
  "Every monitor has at least 1,000 ordinary hours at each hour of the day" = min(cycle_monitor_hours$n) >= 1000,
  "No missing values" = !anyNA(cycle_hours$value_ppb)
)

cycle_site_sets <- hourly_site_sets(cycle_hours)

# Each check only removes hours, so one that keeps every main hour of a pollutant changes nothing and is dropped for that
# pollutant (ozone has no method change)
unchanged_cycle_sets <- cycle_site_sets %>%
  count(site_set, pollutant) %>%
  mutate(is_unchanged = site_set != "Main" & n == n[site_set == "Main"], .by = pollutant) %>%
  filter(is_unchanged)

print(unchanged_cycle_sets)

cycle_site_sets <- cycle_site_sets %>%
  anti_join(unchanged_cycle_sets, by = c("site_set", "pollutant"))

stopifnot(
  "Only the method-change check leaves a pollutant unchanged, for ozone" =
    nrow(unchanged_cycle_sets) == 1 && unchanged_cycle_sets$pollutant == "Ozone" &&
    unchanged_cycle_sets$site_set == "Without hours after the method change"
)

season_levels <- c("All year", levels(cycle_hours$season))

# Each site's mean at each hour, over the whole year and within each season
site_hour_means <- bind_rows(
  cycle_site_sets %>%
    summarise(n_hours = n(), site_mean_ppb = mean(value_ppb), .by = c(site_set, pollutant, site_group, site_id, hour_local)) %>%
    mutate(season = "All year"),
  cycle_site_sets %>%
    summarise(n_hours = n(), site_mean_ppb = mean(value_ppb), .by = c(site_set, pollutant, site_group, site_id, season, hour_local)) %>%
    mutate(season = as.character(season))
) %>%
  mutate(season = factor(season, levels = season_levels))

group_profiles <- site_hour_means %>%
  summarise(
    n_sites = n(),
    mean_ppb = mean(site_mean_ppb),
    low_site_ppb = min(site_mean_ppb),
    high_site_ppb = max(site_mean_ppb),
    .by = c(site_set, pollutant, season, site_group, hour_local)
  ) %>%
  arrange(site_set, pollutant, season, site_group, hour_local)

stopifnot(
  "24 hours for every set, pollutant, season and group" =
    all(count(group_profiles, site_set, pollutant, season, site_group)$n == 24),
  "The site band holds the group mean" =
    all(group_profiles$low_site_ppb <= group_profiles$mean_ppb & group_profiles$mean_ppb <= group_profiles$high_site_ppb)
)

# When each group peaks, over the year and by season
peak_hours <- group_profiles %>%
  filter(site_set == "Main") %>%
  summarise(
    peak_hour = hour_local[which.max(mean_ppb)],
    peak_ppb = max(mean_ppb),
    low_hour = hour_local[which.min(mean_ppb)],
    low_ppb = min(mean_ppb),
    .by = c(pollutant, season, site_group)
  ) %>%
  mutate(daily_range_ppb = peak_ppb - low_ppb)

peak_hours %>%
  mutate(across(where(is.double), \(x) round(x, 1))) %>%
  print(n = Inf)

all_year_peaks <- peak_hours %>%
  filter(season == "All year")

stopifnot(
  "Over the year, ozone peaks in the afternoon window in every group" =
    all(all_year_peaks$peak_hour[all_year_peaks$pollutant == "Ozone"] %in% afternoon_hours),
  "Over the year, NO2 peaks in the morning window in every group" =
    all(all_year_peaks$peak_hour[all_year_peaks$pollutant == "NO2"] %in% morning_hours)
)

# Ship Channel minus Houston other in the same hour, on hours when both groups report. A group's value in an hour is
# the mean of its sites reporting then
paired_gaps <- cycle_site_sets %>%
  filter(site_group != "Dallas-Fort Worth") %>%
  summarise(group_ppb = mean(value_ppb), .by = c(site_set, pollutant, site_group, datetime_utc, date_local, hour_local)) %>%
  mutate(site_group = if_else(site_group == "Houston Ship Channel", "ship_channel_ppb", "houston_other_ppb")) %>%
  pivot_wider(names_from = site_group, values_from = group_ppb) %>%
  filter(!is.na(ship_channel_ppb), !is.na(houston_other_ppb)) %>%
  mutate(gap_ppb = ship_channel_ppb - houston_other_ppb)

hour_gaps <- paired_gaps %>%
  summarise(n_paired_hours = n(), gap_ppb = mean(gap_ppb), .by = c(site_set, pollutant, hour_local)) %>%
  arrange(site_set, pollutant, hour_local)

# A table of days (rows) by hours of the day (columns). Each resample builds a new five years from random 14-day runs
# of rows and takes the mean gap at each hour; the middle 95% of the 1,000 means is the range
hour_gap_ranges <- function(gaps) {
  gap_wide <- gaps %>%
    select(date_local, hour_local, gap_ppb) %>%
    pivot_wider(names_from = hour_local, values_from = gap_ppb, names_sort = TRUE) %>%
    arrange(date_local)
  gap_matrix <- as.matrix(select(gap_wide, -date_local))
  n_days <- nrow(gap_matrix)
  block_starts <- seq_len(n_days - bootstrap_block_days + 1)
  n_blocks <- ceiling(n_days / bootstrap_block_days)
  resampled_means <- vapply(seq_len(bootstrap_reps), \(rep) {
    picked <- sample(block_starts, n_blocks, replace = TRUE)
    rows <- as.vector(outer(seq_len(bootstrap_block_days) - 1, picked, `+`))[seq_len(n_days)]
    colMeans(gap_matrix[rows, , drop = FALSE], na.rm = TRUE)
  }, numeric(ncol(gap_matrix)))
  tibble(
    hour_local = as.integer(colnames(gap_matrix)),
    ci_low = apply(resampled_means, 1, quantile, 0.025, names = FALSE),
    ci_high = apply(resampled_means, 1, quantile, 0.975, names = FALSE)
  )
}

set.seed(bootstrap_seed)

gap_ranges <- bind_rows(lapply(cycle_pollutants, \(pollutant_name) {
  paired_gaps %>%
    filter(site_set == "Main", pollutant == pollutant_name) %>%
    hour_gap_ranges() %>%
    mutate(site_set = factor("Main", levels = hourly_check_levels), pollutant = factor(pollutant_name, levels = cycle_pollutants))
}))

hour_gaps <- hour_gaps %>%
  left_join(gap_ranges, by = c("site_set", "pollutant", "hour_local"), relationship = "one-to-one")

main_gaps <- hour_gaps %>%
  filter(site_set == "Main")

main_gaps %>%
  mutate(across(where(is.double), \(x) round(x, 2))) %>%
  print(n = Inf)

stopifnot(
  "24 paired hours of the day for every set and pollutant" = all(count(hour_gaps, site_set, pollutant)$n == 24),
  "Every main hour of the day has a 95% range around its gap" =
    !anyNA(main_gaps$ci_low) && all(main_gaps$ci_low <= main_gaps$gap_ppb & main_gaps$gap_ppb <= main_gaps$ci_high),
  "Every hour of the day rests on at least 1,000 paired hours" = min(hour_gaps$n_paired_hours) >= 1000
)

# Weekend against weekday at each hour, April to October with the three holidays left out of both, as in 2a section 6
weekend_profiles <- cycle_site_sets %>%
  filter(month(date_local) %in% weekend_months, !is_weekday_holiday) %>%
  summarise(
    n_weekday_hours = sum(!is_weekend),
    n_weekend_hours = sum(is_weekend),
    weekday_ppb = mean(value_ppb[!is_weekend]),
    weekend_ppb = mean(value_ppb[is_weekend]),
    .by = c(site_set, pollutant, site_group, site_id, hour_local)
  ) %>%
  summarise(
    n_sites = n(),
    min_weekend_hours = min(n_weekend_hours),
    weekday_ppb = mean(weekday_ppb),
    weekend_ppb = mean(weekend_ppb),
    .by = c(site_set, pollutant, site_group, hour_local)
  ) %>%
  mutate(weekend_ratio = weekend_ppb / weekday_ppb) %>%
  arrange(site_set, pollutant, site_group, hour_local)

morning_weekend <- weekend_profiles %>%
  filter(hour_local %in% morning_hours) %>%
  summarise(morning_weekend_ratio = mean(weekend_ppb) / mean(weekday_ppb), .by = c(site_set, pollutant, site_group))

morning_weekend %>%
  filter(site_set == "Main") %>%
  mutate(morning_weekend_ratio = round(morning_weekend_ratio, 3)) %>%
  print()

# The thinnest cell is Harvard Street NO2 at 1 am before its method change: 89 weekend hours over two warm seasons
stopifnot(
  "Every site has at least 80 weekend hours at each hour of the day" = min(weekend_profiles$min_weekend_hours) >= 80,
  "Every site has at least 130 weekend hours at each hour of the day in the main set" =
    min(weekend_profiles$min_weekend_hours[weekend_profiles$site_set == "Main"]) >= 130,
  "Every weekend ratio is a finite number" = all(is.finite(weekend_profiles$weekend_ratio)),
  "Morning NO2 is lower on weekends in every group and check" =
    all(morning_weekend$morning_weekend_ratio[morning_weekend$pollutant == "NO2"] < 1)
)

# Each check side by side: the Ship Channel gap over the day and in each window, and the morning weekend ratio per group
cycle_checks <- hour_gaps %>%
  summarise(
    mean_gap_ppb = mean(gap_ppb),
    morning_gap_ppb = mean(gap_ppb[hour_local %in% morning_hours]),
    afternoon_gap_ppb = mean(gap_ppb[hour_local %in% afternoon_hours]),
    hours_ship_channel_higher = sum(gap_ppb > 0),
    .by = c(site_set, pollutant)
  ) %>%
  left_join(
    morning_weekend %>%
      mutate(site_group = str_c("weekend_ratio_", str_replace_all(str_to_lower(site_group), "[^a-z]+", "_"))) %>%
      pivot_wider(names_from = site_group, values_from = morning_weekend_ratio),
    by = c("site_set", "pollutant"),
    relationship = "one-to-one"
  ) %>%
  mutate(across(where(is.double), \(x) round(x, 3))) %>%
  arrange(pollutant, site_set)

print(cycle_checks, width = Inf)

main_ozone_gaps <- main_gaps %>%
  filter(pollutant == "Ozone")

main_no2_gaps <- main_gaps %>%
  filter(pollutant == "NO2")

widest_ozone_gap <- main_ozone_gaps %>%
  slice_min(gap_ppb, n = 1, with_ties = FALSE)

widest_no2_gap <- main_no2_gaps %>%
  slice_max(gap_ppb, n = 1, with_ties = FALSE)

stopifnot(
  "Ship Channel ozone is lower at all 24 hours, each 95% range below zero, as the title says" = all(main_ozone_gaps$ci_high < 0),
  "Ship Channel NO2 is higher at all 24 hours, each 95% range above zero, as the title says" = all(main_no2_gaps$ci_low > 0),
  "Both gaps are widest in the late afternoon, as the subtitle says" = all(c(widest_ozone_gap$hour_local, widest_no2_gap$hour_local) %in% 15:18),
  "Every check keeps both gaps at all 24 hours, as the footer says" =
    all(cycle_checks$hours_ship_channel_higher == if_else(cycle_checks$pollutant == "NO2", 24L, 0L)),
  "Morning NO2 falls least at the Ship Channel under every check" =
    all(cycle_checks$weekend_ratio_houston_ship_channel[cycle_checks$pollutant == "NO2"] >
      pmax(cycle_checks$weekend_ratio_houston_other, cycle_checks$weekend_ratio_dallas_fort_worth)[cycle_checks$pollutant == "NO2"])
)

# Figure 2C.2: the average day per group, and the Ship Channel gap at each hour with its range and the checks
hour_axis <- scale_x_continuous(breaks = seq(0, 18, 6), labels = \(x) sprintf("%02d:00", x), expand = expansion(mult = 0.02))

short_hour_axis <- scale_x_continuous(breaks = seq(0, 18, 6), expand = expansion(mult = 0.02))

main_profiles <- group_profiles %>%
  filter(site_set == "Main")

profile_panel <- function(pollutant_name, kicker) {
  ggplot(filter(main_profiles, pollutant == pollutant_name, season == "All year"), aes(hour_local, mean_ppb)) +
    geom_ribbon(aes(ymin = low_site_ppb, ymax = high_site_ppb, fill = site_group), alpha = 0.15) +
    geom_line(aes(colour = site_group), linewidth = 0.7) +
    scale_colour_manual(values = site_group_colours, guide = "none") +
    scale_fill_manual(values = site_group_colours, guide = "none") +
    scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
    hour_axis +
    labs(title = kicker, subtitle = "Mean by hour of day (ppb)", x = NULL, y = NULL) +
    theme_aqs()
}

gap_panel <- function(pollutant_name, kicker) {
  gaps <- filter(hour_gaps, pollutant == pollutant_name)
  ggplot(filter(gaps, site_set == "Main"), aes(hour_local, gap_ppb)) +
    geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35) +
    geom_ribbon(aes(ymin = ci_low, ymax = ci_high), fill = site_group_colours[["Houston Ship Channel"]], alpha = 0.2) +
    geom_line(
      data = filter(gaps, site_set != "Main"), aes(group = site_set, linetype = site_set == "Without the transition band"),
      colour = chart_ink[["muted"]], linewidth = 0.35
    ) +
    geom_line(colour = site_group_colours[["Houston Ship Channel"]], linewidth = 0.8) +
    scale_linetype_manual(values = c(`TRUE` = "22", `FALSE` = "solid"), guide = "none") +
    hour_axis +
    labs(title = kicker, subtitle = "Ship Channel minus Houston other (ppb)", x = NULL, y = NULL) +
    theme_aqs()
}

cycle_header <- chart_header(
  sprintf("FIGURE 2C.2  /  DAILY CYCLES  /  %s TO %s", min(study_years), max(study_years)),
  "Ship Channel: more NO2, less ozone, every hour",
  sprintf(
    str_c(
      "Both gaps are widest late in the day: NO2 +%.1f ppb at %02d:00 and ozone %.1f ppb at %02d:00.\n",
      "Matching peaks are consistent with fresh NO near the channel using up ozone; section 3 tests it."
    ),
    widest_no2_gap$gap_ppb, widest_no2_gap$hour_local, widest_ozone_gap$gap_ppb, widest_ozone_gap$hour_local
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "dot", site_group_colours[["Houston other"]],        "Houston other",
    "dot", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",
    "dot", chart_ink[["muted"]],                         "Checks"
  )
)

cycle_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d), ordinary hours, 2 sites per group. Local standard time: 06:00 is 7 am daylight time.\n",
  "01, 02: bands span each group's two sites. 03, 04: same-hour gap, 95% range from ", comma(bootstrap_reps),
  " resamples of ", bootstrap_block_days, "-day blocks.\n",
  "Grey: the checks; dashed leaves out Harvard Street (", transition_band, "). Every check keeps both gaps at all 24 hours."
))

cycle_figure <- chart_compose(
  cycle_header,
  list(profile_panel("Ozone", "01  OZONE"), profile_panel("NO2", "02  NO2"), gap_panel("Ozone", "03  OZONE GAP"), gap_panel("NO2", "04  NO2 GAP")),
  cycle_footer
)

cycle_figure_path <- here("figures", "phase2", "2c.02_daily_cycles.png")

save_started <- Sys.time()

ggsave(cycle_figure_path, cycle_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2c.02_daily_cycles.png was written (close any viewer of it and rerun this step)" =
    file.mtime(cycle_figure_path) >= save_started - 2
)

# Figure 2C.3: the average day by season, and weekend against weekday at each hour
main_morning_no2 <- morning_weekend %>%
  filter(site_set == "Main", pollutant == "NO2")

main_morning_ozone <- morning_weekend %>%
  filter(site_set == "Main", pollutant == "Ozone")

morning_no2_ratio <- function(group) {
  main_morning_no2$morning_weekend_ratio[main_morning_no2$site_group == group]
}

stopifnot(
  "Morning NO2 falls least on weekends at the Ship Channel, as the title says" =
    morning_no2_ratio("Houston Ship Channel") == max(main_morning_no2$morning_weekend_ratio),
  "Morning ozone is higher on weekends in every group, as the subtitle says" = all(main_morning_ozone$morning_weekend_ratio > 1)
)

facet_strips <- theme(
  strip.text.x = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["secondary"]], size = chart_sizes[["axis"]], hjust = 0),
  panel.spacing.x = unit(14, "pt")
)

season_panel <- function(pollutant_name, kicker) {
  ggplot(filter(main_profiles, pollutant == pollutant_name, season != "All year"), aes(hour_local, mean_ppb, colour = site_group)) +
    geom_line(linewidth = 0.6) +
    facet_grid(. ~ season, labeller = as_labeller(toupper)) +
    scale_colour_manual(values = site_group_colours, guide = "none") +
    scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
    short_hour_axis +
    labs(title = kicker, subtitle = "Mean by hour of day, 0 to 23 (ppb)", x = NULL, y = NULL) +
    theme_aqs() +
    facet_strips
}

weekend_panel <- ggplot(filter(weekend_profiles, site_set == "Main"), aes(hour_local, weekend_ratio, colour = site_group)) +
  annotate("rect", xmin = min(morning_hours) - 0.5, xmax = max(morning_hours) + 0.5, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
  geom_hline(yintercept = 1, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_line(linewidth = 0.6) +
  facet_grid(. ~ pollutant, labeller = as_labeller(toupper)) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  hour_axis +
  labs(title = "03  WEEKEND", subtitle = "Weekend mean over weekday mean, April to October", x = NULL, y = NULL) +
  theme_aqs() +
  facet_strips

season_weekend_header <- chart_header(
  sprintf("FIGURE 2C.3  /  SEASON AND WEEKEND  /  %s TO %s", min(study_years), max(study_years)),
  "NO2 falls least on Ship Channel weekend mornings",
  sprintf(
    str_c(
      "Weekend over weekday NO2 at %s to %s am: Ship Channel %.2f, Houston other %.2f, DFW %.2f.\n",
      "Consistent with more all-week NO2 sources. Morning ozone is %.0f to %.0f%% higher on weekends."
    ),
    min(morning_hours), max(morning_hours), morning_no2_ratio("Houston Ship Channel"), morning_no2_ratio("Houston other"),
    morning_no2_ratio("Dallas-Fort Worth"), 100 * (min(main_morning_ozone$morning_weekend_ratio) - 1),
    100 * (max(main_morning_ozone$morning_weekend_ratio) - 1)
  ),
  key = tribble(
    ~mark,    ~colour,                                     ~label,
    "dot",    site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "dot",    site_group_colours[["Houston other"]],        "Houston other",
    "dot",    site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",
    "square", chart_ink[["grid"]],                          "Morning window"
  )
)

season_weekend_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d), ordinary hours, 2 sites per group, local standard time. Winter is December to February.\n",
  "03: Memorial Day, Independence Day and Labor Day left out of both sides, as in 2a. Below 1: lower on weekends."
))

season_weekend_figure <- chart_compose(
  season_weekend_header,
  list(season_panel("Ozone", "01  OZONE BY SEASON"), season_panel("NO2", "02  NO2 BY SEASON"), weekend_panel),
  season_weekend_footer,
  ncol = 1
)

season_weekend_figure_path <- here("figures", "phase2", "2c.03_season_weekend.png")

save_started <- Sys.time()

ggsave(season_weekend_figure_path, season_weekend_figure, width = 6.5, height = 7.6, dpi = 300)

stopifnot(
  "2c.03_season_weekend.png was written (close any viewer of it and rerun this step)" =
    file.mtime(season_weekend_figure_path) >= save_started - 2
)

# CSV records: site and group profiles by hour and season, the Ship Channel gap by hour, weekend ratios and the checks
site_names <- monitors %>%
  distinct(site_id, local_site_name)

site_profiles <- site_hour_means %>%
  filter(site_set == "Main") %>%
  left_join(site_names, by = "site_id", relationship = "many-to-one") %>%
  select(pollutant, season, site_group, site_id, local_site_name, hour_local, n_hours, mean_ppb = site_mean_ppb) %>%
  mutate(mean_ppb = round(mean_ppb, 2)) %>%
  arrange(pollutant, season, site_group, site_id, hour_local)

cycle_records <- list(
  case_study_hourly_site_profiles = site_profiles,
  case_study_hourly_group_profiles = mutate(group_profiles, across(c(mean_ppb, low_site_ppb, high_site_ppb), \(x) round(x, 2))),
  case_study_hourly_gaps = mutate(hour_gaps, across(c(gap_ppb, ci_low, ci_high), \(x) round(x, 2))),
  case_study_hourly_weekend = weekend_profiles %>%
    mutate(across(c(weekday_ppb, weekend_ppb), \(x) round(x, 2))) %>%
    mutate(weekend_ratio = round(weekend_ratio, 3)),
  case_study_hourly_cycle_checks = cycle_checks
)

stopifnot(
  "Site profiles: 12 monitors, 5 seasons, 24 hours" = nrow(site_profiles) == 12 * 5 * 24,
  "Group profiles: 7 set-pollutant pairs, 5 seasons, 3 groups, 24 hours" = nrow(group_profiles) == 7 * 5 * 3 * 24,
  "Checks: 3 sets for ozone and 4 for NO2" = nrow(cycle_checks) == 7
)

save_records(cycle_records, records_dir)

cycle_dictionary <- tribble(
  ~table,                             ~column,                     ~description,
  "case_study_hourly_site_profiles",  "pollutant",                 "Ozone or NO2",
  "case_study_hourly_site_profiles",  "season",                    "All year, or a meteorological season (winter is December to February)",
  "case_study_hourly_site_profiles",  "site_group",                "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "case_study_hourly_site_profiles",  "site_id",                   "AQS site ID: state-county-site",
  "case_study_hourly_site_profiles",  "local_site_name",           "Site name given by the reporting agency",
  "case_study_hourly_site_profiles",  "hour_local",                "Hour of day, local standard time (UTC-6); 6 is 7 am daylight time",
  "case_study_hourly_site_profiles",  "n_hours",                   "Ordinary hours behind the mean",
  "case_study_hourly_site_profiles",  "mean_ppb",                  "Mean of the ordinary hours, ppb",
  "case_study_hourly_group_profiles", "site_set",                  "Main or a check: transition band, method change, Deer Park #2 after its move",
  "case_study_hourly_group_profiles", "pollutant",                 "Ozone or NO2",
  "case_study_hourly_group_profiles", "season",                    "All year, or a meteorological season (winter is December to February)",
  "case_study_hourly_group_profiles", "site_group",                "Case-study group under that site set",
  "case_study_hourly_group_profiles", "hour_local",                "Hour of day, local standard time (UTC-6)",
  "case_study_hourly_group_profiles", "n_sites",                   "Sites in the group",
  "case_study_hourly_group_profiles", "mean_ppb",                  "Mean of the sites' means at that hour, each site weighted equally, ppb",
  "case_study_hourly_group_profiles", "low_site_ppb",              "Lowest site mean at that hour, ppb",
  "case_study_hourly_group_profiles", "high_site_ppb",             "Highest site mean at that hour, ppb",
  "case_study_hourly_gaps",           "site_set",                  "Main or a check: transition band, method change, Deer Park #2 after its move",
  "case_study_hourly_gaps",           "pollutant",                 "Ozone or NO2",
  "case_study_hourly_gaps",           "hour_local",                "Hour of day, local standard time (UTC-6)",
  "case_study_hourly_gaps",           "n_paired_hours",            "Hours when both groups report",
  "case_study_hourly_gaps",           "gap_ppb",                   "Mean Ship Channel minus Houston other in the same hour, ppb",
  "case_study_hourly_gaps",           "ci_low",                    "Lower end of the 95% range from the 14-day block bootstrap; NA for checks",
  "case_study_hourly_gaps",           "ci_high",                   "Upper end of the 95% range from the 14-day block bootstrap; NA for checks",
  "case_study_hourly_weekend",        "site_set",                  "Main or a check: transition band, method change, Deer Park #2 after its move",
  "case_study_hourly_weekend",        "pollutant",                 "Ozone or NO2",
  "case_study_hourly_weekend",        "site_group",                "Case-study group under that site set",
  "case_study_hourly_weekend",        "hour_local",                "Hour of day, local standard time (UTC-6)",
  "case_study_hourly_weekend",        "n_sites",                   "Sites in the group",
  "case_study_hourly_weekend",        "min_weekend_hours",         "Weekend hours at the group's thinnest site",
  "case_study_hourly_weekend",        "weekday_ppb",               "Mean of the sites' weekday means, April to October, three holidays left out, ppb",
  "case_study_hourly_weekend",        "weekend_ppb",               "Mean of the sites' Saturday and Sunday means, April to October, ppb",
  "case_study_hourly_weekend",        "weekend_ratio",             "weekend_ppb over weekday_ppb; below 1 means lower on weekends",
  "case_study_hourly_cycle_checks",   "site_set",                  "Main or a check: transition band, method change, Deer Park #2 after its move",
  "case_study_hourly_cycle_checks",   "pollutant",                 "Ozone or NO2",
  "case_study_hourly_cycle_checks",   "mean_gap_ppb",              "Ship Channel minus Houston other, mean of the 24 hourly gaps, ppb",
  "case_study_hourly_cycle_checks",   "morning_gap_ppb",           "The same gap averaged over 6 to 8 am local standard time, ppb",
  "case_study_hourly_cycle_checks",   "afternoon_gap_ppb",         "The same gap averaged over 12 to 4 pm local standard time, ppb",
  "case_study_hourly_cycle_checks",   "hours_ship_channel_higher", "Hours of the day, of 24, when the Ship Channel mean is higher",
  "case_study_hourly_cycle_checks",   "weekend_ratio_houston_ship_channel", "Ship Channel weekend over weekday mean, 6 to 8 am, April to October",
  "case_study_hourly_cycle_checks",   "weekend_ratio_houston_other",        "Houston other weekend over weekday mean, 6 to 8 am, April to October",
  "case_study_hourly_cycle_checks",   "weekend_ratio_dallas_fort_worth",    "Dallas-Fort Worth weekend over weekday mean, 6 to 8 am, April to October"
)

cycle_dictionary <- document_tables(cycle_records, cycle_dictionary)

replace_own_rows(cycle_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(cycle_site_sets, paired_gaps)



# 3. OZONE AND NO2 TOGETHER (OX) ----
# NO from exhausts and stacks turns ozone into NO2 one for one (NO + O3 -> NO2 + O2), which leaves ozone plus NO2 (Ox)
# unchanged. If the Ship Channel's lower ozone came only from this, its Ox would match Houston other's. Ox is built per
# site and hour, from hours when both pollutants are ordinary at that site
ox_measures <- c("Ozone", "NO2", "Ox")

ox_hours <- cycle_hours %>%
  pivot_wider(
    id_cols = c(site_group, site_id, datetime_utc, date_local, hour_local, season, in_transition_band),
    names_from = pollutant,
    values_from = c(value_ppb, is_post_method_change, is_post_relocation)
  ) %>%
  filter(!is.na(value_ppb_Ozone), !is.na(value_ppb_NO2)) %>%
  mutate(is_post_method_change = is_post_method_change_Ozone | is_post_method_change_NO2) %>%
  mutate(is_post_relocation = is_post_relocation_Ozone | is_post_relocation_NO2) %>%
  mutate(ozone_ppb = value_ppb_Ozone, no2_ppb = value_ppb_NO2) %>%
  mutate(ox_ppb = ozone_ppb + no2_ppb) %>%
  select(
    site_group, site_id, datetime_utc, date_local, hour_local, season, in_transition_band, is_post_method_change,
    is_post_relocation, ozone_ppb, no2_ppb, ox_ppb
  )

# Each site's paired hours against its ozone hours, and its five-year means
ox_site_summary <- ox_hours %>%
  summarise(
    n_paired_hours = n(),
    mean_ozone_ppb = mean(ozone_ppb),
    mean_no2_ppb = mean(no2_ppb),
    mean_ox_ppb = mean(ox_ppb),
    .by = c(site_group, site_id)
  ) %>%
  left_join(
    count(filter(cycle_hours, pollutant == "Ozone"), site_id, name = "n_ozone_hours"),
    by = "site_id", relationship = "one-to-one"
  ) %>%
  left_join(distinct(monitors, site_id, local_site_name), by = "site_id", relationship = "one-to-one") %>%
  mutate(pct_of_ozone_hours = round(100 * n_paired_hours / n_ozone_hours, 1)) %>%
  mutate(across(c(mean_ozone_ppb, mean_no2_ppb, mean_ox_ppb), \(x) round(x, 2))) %>%
  select(site_group, site_id, local_site_name, n_ozone_hours, n_paired_hours, pct_of_ozone_hours, mean_ozone_ppb, mean_no2_ppb, mean_ox_ppb) %>%
  arrange(site_group, local_site_name)

print(ox_site_summary, width = Inf)

stopifnot(
  "Every ozone site also measures NO2, so each group keeps two sites" = all(count(ox_site_summary, site_group)$n == 2),
  "Each site pairs at least 85% of its ozone hours with NO2" = all(ox_site_summary$pct_of_ozone_hours >= 85),
  "One row per site and hour" = !anyDuplicated(ox_hours[c("site_id", "datetime_utc")])
)

ox_long <- ox_hours %>%
  hourly_site_sets() %>%
  pivot_longer(c(ozone_ppb, no2_ppb, ox_ppb), names_to = "measure", values_to = "value_ppb") %>%
  mutate(measure = factor(measure, levels = c("ozone_ppb", "no2_ppb", "ox_ppb"), labels = ox_measures))

# Ox by hour per group, each site counting equally, over the year and by season
ox_site_hour_means <- bind_rows(
  ox_long %>%
    filter(measure == "Ox") %>%
    summarise(site_mean_ppb = mean(value_ppb), .by = c(site_set, site_group, site_id, hour_local)) %>%
    mutate(season = "All year"),
  ox_long %>%
    filter(measure == "Ox") %>%
    summarise(site_mean_ppb = mean(value_ppb), .by = c(site_set, site_group, site_id, season, hour_local)) %>%
    mutate(season = as.character(season))
) %>%
  mutate(season = factor(season, levels = season_levels))

ox_profiles <- ox_site_hour_means %>%
  summarise(
    n_sites = n(),
    mean_ox_ppb = mean(site_mean_ppb),
    low_site_ppb = min(site_mean_ppb),
    high_site_ppb = max(site_mean_ppb),
    .by = c(site_set, season, site_group, hour_local)
  ) %>%
  arrange(site_set, season, site_group, hour_local)

stopifnot(
  "24 hours for every set, season and group" = all(count(ox_profiles, site_set, season, site_group)$n == 24)
)

# Ship Channel minus Houston other in the same hour, for ozone, NO2 and Ox
ox_paired_gaps <- ox_long %>%
  filter(site_group != "Dallas-Fort Worth") %>%
  summarise(group_ppb = mean(value_ppb), .by = c(site_set, measure, site_group, datetime_utc, date_local, hour_local, season)) %>%
  mutate(site_group = if_else(site_group == "Houston Ship Channel", "ship_channel_ppb", "houston_other_ppb")) %>%
  pivot_wider(names_from = site_group, values_from = group_ppb) %>%
  filter(!is.na(ship_channel_ppb), !is.na(houston_other_ppb)) %>%
  mutate(gap_ppb = ship_channel_ppb - houston_other_ppb)

ox_hour_gaps <- ox_paired_gaps %>%
  summarise(n_paired_hours = n(), gap_ppb = mean(gap_ppb), .by = c(site_set, measure, hour_local)) %>%
  arrange(site_set, measure, hour_local)

set.seed(bootstrap_seed)

ox_hour_ranges <- ox_paired_gaps %>%
  filter(site_set == "Main", measure == "Ox") %>%
  hour_gap_ranges() %>%
  mutate(site_set = factor("Main", levels = hourly_check_levels), measure = factor("Ox", levels = ox_measures))

ox_hour_gaps <- ox_hour_gaps %>%
  left_join(ox_hour_ranges, by = c("site_set", "measure", "hour_local"), relationship = "one-to-one")

ox_hour_gaps %>%
  filter(site_set == "Main") %>%
  select(measure, hour_local, gap_ppb) %>%
  pivot_wider(names_from = measure, values_from = gap_ppb) %>%
  mutate(across(where(is.double), \(x) round(x, 2))) %>%
  print(n = Inf)

stopifnot(
  "24 hours for every set and measure" = all(count(ox_hour_gaps, site_set, measure)$n == 24),
  "Every hour rests on at least 1,000 paired hours" = min(ox_hour_gaps$n_paired_hours) >= 1000
)

# Each day's mean gap, then the mean over days for the year and each season. The 95% range resamples 14-day runs of
# days in date order; within a season the runs can join the end of one year to the start of the next
block_mean_range <- function(x) {
  n_days <- length(x)
  block_starts <- seq_len(n_days - bootstrap_block_days + 1)
  n_blocks <- ceiling(n_days / bootstrap_block_days)
  resampled_means <- vapply(seq_len(bootstrap_reps), \(rep) {
    picked <- sample(block_starts, n_blocks, replace = TRUE)
    mean(x[as.vector(outer(seq_len(bootstrap_block_days) - 1, picked, `+`))][seq_len(n_days)])
  }, numeric(1))
  unname(quantile(resampled_means, c(0.025, 0.975)))
}

ox_day_gaps <- ox_paired_gaps %>%
  summarise(gap_ppb = mean(gap_ppb), .by = c(site_set, measure, season, date_local))

ox_season_days <- bind_rows(
  ox_day_gaps %>%
    mutate(season = "All year"),
  ox_day_gaps %>%
    mutate(season = as.character(season))
) %>%
  mutate(season = factor(season, levels = season_levels)) %>%
  arrange(site_set, measure, season, date_local)

ox_season_ranges <- ox_season_days %>%
  filter(site_set == "Main") %>%
  summarise(range = list(block_mean_range(gap_ppb)), .by = c(site_set, measure, season)) %>%
  mutate(ci_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(ci_high = vapply(range, \(r) r[2], numeric(1))) %>%
  select(-range)

ox_season_gaps <- ox_season_days %>%
  summarise(n_days = n(), gap_ppb = mean(gap_ppb), .by = c(site_set, measure, season)) %>%
  left_join(ox_season_ranges, by = c("site_set", "measure", "season"), relationship = "one-to-one") %>%
  arrange(site_set, measure, season)

# One row per check and season: the three gaps side by side, and the share of the ozone gap that Ox closes
ox_checks <- ox_season_gaps %>%
  select(site_set, season, measure, n_days, gap_ppb, ci_low, ci_high) %>%
  mutate(measure = str_to_lower(measure)) %>%
  pivot_wider(names_from = measure, values_from = c(gap_ppb, ci_low, ci_high), names_glue = "{measure}_{.value}") %>%
  select(site_set, season, n_days, ozone_gap_ppb, no2_gap_ppb, ox_gap_ppb, ozone_ci_low, ozone_ci_high, ox_ci_low, ox_ci_high) %>%
  mutate(share_of_ozone_gap_closed = 1 - ox_gap_ppb / ozone_gap_ppb) %>%
  mutate(across(where(is.double), \(x) round(x, 3))) %>%
  arrange(season, site_set)

print(ox_checks, n = Inf, width = Inf)

main_ox <- ox_checks %>%
  filter(site_set == "Main")

ox_season <- function(season_name) {
  filter(main_ox, season == season_name)
}

year_checks <- ox_checks %>%
  filter(season == "All year")

winter_checks <- ox_checks %>%
  filter(season == "Winter")

transition_year <- year_checks %>%
  filter(site_set == "Without the transition band")

stopifnot(
  "One row per check and season" = nrow(ox_checks) == length(hourly_check_levels) * length(season_levels),
  "Over the year, Ship Channel ozone is lower and its NO2 higher" =
    ox_season("All year")$ozone_gap_ppb < 0 && ox_season("All year")$no2_gap_ppb > 0,
  "Every check keeps the ozone gap below zero over the year" = all(year_checks$ozone_gap_ppb < 0),
  "Every check has Ox closing at least half the ozone gap over the year, as the title says" =
    all(year_checks$share_of_ozone_gap_closed >= 0.5),
  "In winter the main Ox gap's 95% range includes zero, as the subtitle says" =
    ox_season("Winter")$ox_ci_low < 0 && ox_season("Winter")$ox_ci_high > 0,
  "In winter every check has Ox closing at least 90% of the ozone gap" = all(winter_checks$share_of_ozone_gap_closed >= 0.9),
  "Without Harvard Street, Ox closes over 90% of the ozone gap over the year, as the subtitle says" =
    transition_year$share_of_ozone_gap_closed > 0.9
)

# Figure 2C.4: Ox by hour per group, the three gaps by hour, and the ozone and Ox gaps by season and under each check
ox_gap_colours <- c(Ozone = chart_ink[["muted"]], NO2 = chart_ink[["muted"]], Ox = chart_fills[["accent"]])

ox_gap_lines <- c(Ozone = "solid", NO2 = "22", Ox = "solid")

ox_profile_panel <- ggplot(filter(ox_profiles, site_set == "Main", season == "All year"), aes(hour_local, mean_ox_ppb)) +
  geom_ribbon(aes(ymin = low_site_ppb, ymax = high_site_ppb, fill = site_group), alpha = 0.15) +
  geom_line(aes(colour = site_group), linewidth = 0.7) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_fill_manual(values = site_group_colours, guide = "none") +
  scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
  hour_axis +
  labs(title = "01  OX BY HOUR", subtitle = "Ozone + NO2, mean by hour (ppb)", x = NULL, y = NULL) +
  theme_aqs()

main_ox_hour_gaps <- ox_hour_gaps %>%
  filter(site_set == "Main")

ox_line_labels <- main_ox_hour_gaps %>%
  filter(hour_local == 2) %>%
  mutate(label = toupper(as.character(measure))) %>%
  mutate(vjust = if_else(measure == "Ozone", 1.9, -1))

ox_gap_panel <- ggplot(main_ox_hour_gaps, aes(hour_local, gap_ppb, colour = measure)) +
  geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_ribbon(
    aes(ymin = ci_low, ymax = ci_high), data = filter(main_ox_hour_gaps, measure == "Ox"), fill = chart_fills[["accent"]],
    alpha = 0.18, colour = NA
  ) +
  geom_line(aes(linewidth = measure == "Ox", linetype = measure)) +
  geom_text(
    data = ox_line_labels, aes(label = label, vjust = vjust), hjust = 0.5,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt
  ) +
  scale_colour_manual(values = ox_gap_colours, guide = "none") +
  scale_linetype_manual(values = ox_gap_lines, guide = "none") +
  scale_linewidth_manual(values = c(`TRUE` = 0.8, `FALSE` = 0.5), guide = "none") +
  hour_axis +
  labs(title = "02  GAPS BY HOUR", subtitle = "Ship Channel minus Houston other (ppb)", x = NULL, y = NULL) +
  theme_aqs()

# The grey line joins the ozone gap to the Ox gap: its length is the part of the ozone gap that NO2 accounts for
ox_season_panel <- ggplot(main_ox, aes(x = season)) +
  geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_segment(aes(y = ozone_gap_ppb, yend = ox_gap_ppb), colour = chart_ink[["axis"]], linewidth = 0.6) +
  geom_errorbar(aes(ymin = ox_ci_low, ymax = ox_ci_high), colour = chart_fills[["accent"]], width = 0.18, linewidth = 0.45) +
  geom_point(aes(y = ozone_gap_ppb), colour = chart_ink[["muted"]], size = 1.8) +
  geom_point(aes(y = ox_gap_ppb), colour = chart_fills[["accent"]], size = 1.8) +
  scale_x_discrete(labels = \(x) toupper(str_remove(x, "^All "))) +
  labs(title = "03  BY SEASON", subtitle = "Mean daily gap, ozone and Ox (ppb)", x = NULL, y = NULL) +
  theme_aqs()

check_labels <- c(
  "Main" = "Main",
  "Without the transition band" = "Without Harvard Street",
  "Without hours after the method change" = "Without method change",
  "Without Deer Park #2 after its move" = "Without Deer Park move"
)

check_rows <- ox_checks %>%
  filter(season == "All year") %>%
  mutate(check = factor(check_labels[as.character(site_set)], levels = rev(check_labels)))

# Check names sit above each row rather than on the axis, so this panel's left edge lines up with panel 02 above it
ox_check_panel <- ggplot(check_rows, aes(y = check)) +
  geom_vline(xintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_segment(aes(x = ozone_gap_ppb, xend = ox_gap_ppb, yend = check), colour = chart_ink[["axis"]], linewidth = 0.6) +
  geom_errorbar(
    aes(xmin = ox_ci_low, xmax = ox_ci_high), orientation = "y", colour = chart_fills[["accent"]], width = 0.25, linewidth = 0.45
  ) +
  geom_point(aes(x = ozone_gap_ppb), colour = chart_ink[["muted"]], size = 1.8) +
  geom_point(aes(x = ox_gap_ppb), colour = chart_fills[["accent"]], size = 1.8) +
  geom_text(
    aes(x = -Inf, label = check), hjust = 0, vjust = -1.1,
    family = chart_fonts[["text"]], size = (chart_sizes[["label"]] - 0.6) / .pt, colour = chart_ink[["secondary"]]
  ) +
  geom_text(
    aes(x = coalesce(ox_ci_high, ox_gap_ppb), label = sprintf("%.0f%%", 100 * share_of_ozone_gap_closed)), hjust = -0.5,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_fills[["accent"]]
  ) +
  scale_x_continuous(expand = expansion(mult = c(0.05, 0.15))) +
  scale_y_discrete(expand = expansion(add = c(0.4, 0.8))) +
  labs(title = "04  CHECKS", subtitle = "Over the year; % of the ozone gap closed", x = NULL, y = NULL) +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_blank()
  )

ox_header <- chart_header(
  sprintf("FIGURE 2C.4  /  OZONE AND NO2 TOGETHER (OX)  /  %s TO %s", min(study_years), max(study_years)),
  "Adding NO2 back closes at least half the gap",
  sprintf(
    str_c(
      "Over the year, Ox closes %.0f%% of the Ship Channel's %.1f ppb ozone gap; in winter, all of it.\n",
      "Without Harvard Street, the Houston other site nearest the channel, it closes %.0f%%."
    ),
    100 * ox_season("All year")$share_of_ozone_gap_closed, abs(ox_season("All year")$ozone_gap_ppb),
    100 * transition_year$share_of_ozone_gap_closed
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "dot", site_group_colours[["Houston other"]],        "Houston other",
    "dot", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",
    "dot", chart_ink[["muted"]],                         "Ozone gap",
    "dot", chart_fills[["accent"]],                      "Ox gap"
  )
)

ox_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d), ordinary hours with both pollutants at the same site, 2 sites per group, local standard time.\n",
  "02 to 04: same-hour gaps, 95% ranges from ", comma(bootstrap_reps), " resamples of ", bootstrap_block_days,
  "-day blocks. Grey lines: the part NO2 accounts for.\n",
  "NO2 by the standard method also counts some other nitrogen oxides, so Ox can read slightly high in aged air."
))

ox_figure <- chart_compose(ox_header, list(ox_profile_panel, ox_gap_panel, ox_season_panel, ox_check_panel), ox_footer)

ox_figure_path <- here("figures", "phase2", "2c.04_ox.png")

save_started <- Sys.time()

ggsave(ox_figure_path, ox_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2c.04_ox.png was written (close any viewer of it and rerun this step)" = file.mtime(ox_figure_path) >= save_started - 2
)

# CSV records: each site's paired hours and means, Ox by hour per group, the gaps by hour, and the gaps by season and check
ox_records <- list(
  case_study_ox_sites = ox_site_summary,
  case_study_ox_profiles = mutate(ox_profiles, across(c(mean_ox_ppb, low_site_ppb, high_site_ppb), \(x) round(x, 2))),
  case_study_ox_hour_gaps = mutate(ox_hour_gaps, across(c(gap_ppb, ci_low, ci_high), \(x) round(x, 2))),
  case_study_ox_checks = ox_checks
)

stopifnot(
  "Ox profiles: 4 sets, 5 seasons, 3 groups, 24 hours" = nrow(ox_profiles) == 4 * 5 * 3 * 24,
  "Ox hour gaps: 4 sets, 3 measures, 24 hours" = nrow(ox_hour_gaps) == 4 * 3 * 24
)

save_records(ox_records, records_dir)

ox_dictionary <- tribble(
  ~table,                    ~column,                     ~description,
  "case_study_ox_sites",     "site_group",                "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "case_study_ox_sites",     "site_id",                   "AQS site ID: state-county-site",
  "case_study_ox_sites",     "local_site_name",           "Site name given by the reporting agency",
  "case_study_ox_sites",     "n_ozone_hours",             "Ordinary ozone hours",
  "case_study_ox_sites",     "n_paired_hours",            "Hours when ozone and NO2 are both ordinary at the site",
  "case_study_ox_sites",     "pct_of_ozone_hours",        "Paired hours as a share of the ordinary ozone hours",
  "case_study_ox_sites",     "mean_ozone_ppb",            "Mean ozone over the paired hours, ppb",
  "case_study_ox_sites",     "mean_no2_ppb",              "Mean NO2 over the paired hours, ppb",
  "case_study_ox_sites",     "mean_ox_ppb",               "Mean Ox (ozone + NO2) over the paired hours, ppb",
  "case_study_ox_profiles",  "site_set",                  "Main or a check: transition band, method change, Deer Park #2 after its move",
  "case_study_ox_profiles",  "season",                    "All year, or a meteorological season (winter is December to February)",
  "case_study_ox_profiles",  "site_group",                "Case-study group under that site set",
  "case_study_ox_profiles",  "hour_local",                "Hour of day, local standard time (UTC-6)",
  "case_study_ox_profiles",  "n_sites",                   "Sites in the group",
  "case_study_ox_profiles",  "mean_ox_ppb",               "Mean of the sites' mean Ox at that hour, each site weighted equally, ppb",
  "case_study_ox_profiles",  "low_site_ppb",              "Lowest site mean Ox at that hour, ppb",
  "case_study_ox_profiles",  "high_site_ppb",             "Highest site mean Ox at that hour, ppb",
  "case_study_ox_hour_gaps", "site_set",                  "Main or a check: transition band, method change, Deer Park #2 after its move",
  "case_study_ox_hour_gaps", "measure",                   "Ozone, NO2 or Ox, all on paired hours",
  "case_study_ox_hour_gaps", "hour_local",                "Hour of day, local standard time (UTC-6)",
  "case_study_ox_hour_gaps", "n_paired_hours",            "Hours when both groups report",
  "case_study_ox_hour_gaps", "gap_ppb",                   "Mean Ship Channel minus Houston other in the same hour, ppb",
  "case_study_ox_hour_gaps", "ci_low",                    "Lower end of the 95% range from the 14-day block bootstrap; Ox in the main set only",
  "case_study_ox_hour_gaps", "ci_high",                   "Upper end of the 95% range from the 14-day block bootstrap; Ox in the main set only",
  "case_study_ox_checks",    "site_set",                  "Main or a check: transition band, method change, Deer Park #2 after its move",
  "case_study_ox_checks",    "season",                    "All year, or a meteorological season (winter is December to February)",
  "case_study_ox_checks",    "n_days",                    "Days with at least one paired hour for both groups",
  "case_study_ox_checks",    "ozone_gap_ppb",             "Mean daily Ship Channel minus Houston other ozone, ppb",
  "case_study_ox_checks",    "no2_gap_ppb",               "Mean daily Ship Channel minus Houston other NO2, ppb",
  "case_study_ox_checks",    "ox_gap_ppb",                "Mean daily Ship Channel minus Houston other Ox, ppb",
  "case_study_ox_checks",    "ozone_ci_low",              "Lower end of the 95% range of the ozone gap; main set only",
  "case_study_ox_checks",    "ozone_ci_high",             "Upper end of the 95% range of the ozone gap; main set only",
  "case_study_ox_checks",    "ox_ci_low",                 "Lower end of the 95% range of the Ox gap; main set only",
  "case_study_ox_checks",    "ox_ci_high",                "Upper end of the 95% range of the Ox gap; main set only",
  "case_study_ox_checks",    "share_of_ozone_gap_closed", "1 minus the Ox gap over the ozone gap: the part of the ozone gap that NO2 accounts for"
)

ox_dictionary <- document_tables(ox_records, ox_dictionary)

replace_own_rows(ox_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(ox_long, ox_paired_gaps)



# 4. SO2 SPIKE HOURS ----
# SO2 is below the detection limit in most hours, so it is read through spike hours. Rates are per 1,000 ordinary hours so
# sites with different coverage compare. Each site is shown on its own, since Houston other is Croquet alone
so2_hours <- hourly %>%
  filter(pollutant == "SO2", is_ordinary_hour) %>%
  mutate(short_name = short_site_name(local_site_name)) %>%
  mutate(is_spike = value_ppb >= so2_spike_ppb) %>%
  mutate(is_check_spike = value_ppb >= so2_check_spike_ppb) %>%
  select(
    site_group, site_id, short_name, datetime_utc, date_local, hour_local, season, is_weekend, is_weekday_holiday,
    in_transition_band, is_post_method_change, is_post_relocation, value_ppb, below_mdl, is_spike, is_check_spike
  )

so2_site_sets <- hourly_site_sets(so2_hours)

# Checks that remove no SO2 hours change nothing and are dropped, as in section 2
unchanged_so2_sets <- so2_site_sets %>%
  count(site_set) %>%
  filter(site_set != "Main", n == n[site_set == "Main"])

so2_site_sets <- so2_site_sets %>%
  anti_join(unchanged_so2_sets, by = "site_set")

stopifnot(
  "Three Ship Channel SO2 sites and Croquet" =
    identical(as.integer(table(distinct(so2_hours, site_group, site_id)$site_group)), c(3L, 1L, 0L)),
  "Only the Deer Park #2 check changes the SO2 hours" =
    setequal(unique(as.character(so2_site_sets$site_set)), c("Main", "Without Deer Park #2 after its move"))
)

# Consecutive spike hours at a site form one episode
so2_episodes <- so2_site_sets %>%
  filter(is_spike) %>%
  arrange(site_set, site_id, datetime_utc) %>%
  mutate(hours_since_last = as.numeric(difftime(datetime_utc, lag(datetime_utc), units = "hours")), .by = c(site_set, site_id)) %>%
  mutate(episode = cumsum(is.na(hours_since_last) | hours_since_last > 1), .by = c(site_set, site_id)) %>%
  summarise(episode_hours = n(), .by = c(site_set, site_id, episode))

# Ship Channel spike hours that another Ship Channel site shares; few shared hours point to separate local plumes
shared_spikes <- so2_site_sets %>%
  filter(site_group == "Houston Ship Channel", is_spike) %>%
  add_count(site_set, datetime_utc, name = "n_sites_spiking")

so2_spike_sites <- so2_site_sets %>%
  summarise(
    n_hours = n(),
    pct_below_mdl = round(100 * mean(below_mdl), 1),
    n_spike_hours = sum(is_spike),
    spike_rate_per_1000 = 1000 * mean(is_spike),
    n_spike_days = n_distinct(date_local[is_spike]),
    n_check_spike_hours = sum(is_check_spike),
    check_spike_rate_per_1000 = 1000 * mean(is_check_spike),
    max_ppb = max(value_ppb),
    pct_spikes_daytime = 100 * mean(hour_local[is_spike] %in% daytime_hours),
    .by = c(site_set, site_group, site_id, short_name)
  ) %>%
  left_join(
    summarise(so2_episodes, n_episodes = n(), median_episode_hours = median(episode_hours), max_episode_hours = max(episode_hours),
      .by = c(site_set, site_id)),
    by = c("site_set", "site_id"), relationship = "one-to-one"
  ) %>%
  left_join(
    summarise(shared_spikes, n_spike_hours_shared = sum(n_sites_spiking > 1), .by = c(site_set, site_id)),
    by = c("site_set", "site_id"), relationship = "one-to-one"
  ) %>%
  mutate(across(c(spike_rate_per_1000, check_spike_rate_per_1000, pct_spikes_daytime), \(x) round(x, 2))) %>%
  arrange(site_set, desc(spike_rate_per_1000))

print(so2_spike_sites, width = Inf)

main_spike_sites <- so2_spike_sites %>%
  filter(site_set == "Main")

check_rate_shift <- so2_spike_sites %>%
  filter(site_set != "Main") %>%
  inner_join(select(main_spike_sites, site_id, main_rate = spike_rate_per_1000), by = "site_id", relationship = "one-to-one") %>%
  mutate(shift_share = abs(spike_rate_per_1000 - main_rate) / main_rate)

stopifnot(
  "Every site has at least 20 spike hours" = all(main_spike_sites$n_spike_hours >= 20),
  "Every spike episode is counted once" = all(main_spike_sites$n_episodes <= main_spike_sites$n_spike_hours),
  "The Deer Park #2 check keeps every site's spike rate within 10% of the main rate" = all(check_rate_shift$shift_share <= 0.1)
)

main_shared_hours <- shared_spikes %>%
  filter(site_set == "Main") %>%
  distinct(datetime_utc, n_sites_spiking)

n_ship_channel_spike_hours <- nrow(main_shared_hours)

n_shared_spike_hours <- sum(main_shared_hours$n_sites_spiking > 1)

cat("Ship Channel spike hours:", n_ship_channel_spike_hours, " shared by two or more sites:", n_shared_spike_hours, "\n")

# Spike rates by hour of day, season and day type for each site. Day type uses April to October with the three holidays
# left out, as in section 2
spike_rate_rows <- function(hours, period_type, period_col) {
  hours %>%
    summarise(n_hours = n(), n_spike_hours = sum(is_spike), .by = c(site_group, site_id, short_name, all_of(period_col))) %>%
    mutate(spike_rate_per_1000 = 1000 * n_spike_hours / n_hours) %>%
    mutate(period_type = period_type, period = as.character(.data[[period_col]])) %>%
    select(site_group, site_id, short_name, period_type, period, n_hours, n_spike_hours, spike_rate_per_1000)
}

weekend_so2_hours <- so2_hours %>%
  filter(month(date_local) %in% weekend_months, !is_weekday_holiday) %>%
  mutate(day_type = if_else(is_weekend, "Weekend", "Weekday"))

so2_spike_profiles <- bind_rows(
  spike_rate_rows(so2_hours, "Hour of day", "hour_local"),
  spike_rate_rows(so2_hours, "Season", "season"),
  spike_rate_rows(weekend_so2_hours, "Day type", "day_type")
)

site_season_rates <- so2_spike_profiles %>%
  filter(period_type == "Season") %>%
  mutate(season = factor(period, levels = levels(so2_hours$season)))

croquet_spikes <- main_spike_sites %>%
  filter(site_group == "Houston other")

croquet_seasons <- site_season_rates %>%
  filter(site_group == "Houston other") %>%
  arrange(desc(spike_rate_per_1000))

croquet_summer_ratio <- croquet_seasons$spike_rate_per_1000[1] / croquet_seasons$spike_rate_per_1000[2]

site_day_types <- so2_spike_profiles %>%
  filter(period_type == "Day type") %>%
  select(site_id, period, spike_rate_per_1000) %>%
  pivot_wider(names_from = period, values_from = spike_rate_per_1000)

stopifnot(
  "24 hours, 4 seasons and 2 day types per site" = all(count(so2_spike_profiles, site_id)$n == 24 + 4 + 2),
  "Croquet spikes have the highest daytime share, at least 90%, as the title says" =
    croquet_spikes$pct_spikes_daytime >= 90 && croquet_spikes$pct_spikes_daytime == max(main_spike_sites$pct_spikes_daytime),
  "Croquet spikes most in summer, as the subtitle says" = croquet_seasons$period[1] == "Summer",
  "Spikes are short: the median episode at every site is one hour, as the subtitle says" = all(main_spike_sites$median_episode_hours == 1),
  "Under 10% of Ship Channel spike hours are shared by two sites, as the subtitle says" =
    n_shared_spike_hours < 0.1 * n_ship_channel_spike_hours,
  "No site spikes twice as often on weekdays as on weekends, except Deer Park #2 with few spikes" =
    all(site_day_types$Weekday[site_day_types$site_id != relocation_site] < 2 * site_day_types$Weekend[site_day_types$site_id != relocation_site])
)

# Deer Park #2 is the one site measuring SO2, ozone and NO2. On its spike hours, each gas is compared with the spike-free
# mean at the same hour of day and month. More NO2 means the plume carries nitrogen oxides; less ozone at night would be
# the section 3 reaction (fresh NO using up ozone) inside the plume
plume_hours <- hourly %>%
  filter(site_id == relocation_site, is_ordinary_hour) %>%
  select(datetime_utc, date_local, hour_local, pollutant, value_ppb) %>%
  pivot_wider(names_from = pollutant, values_from = value_ppb) %>%
  filter(!is.na(SO2), !is.na(Ozone), !is.na(NO2)) %>%
  mutate(Ox = Ozone + NO2) %>%
  mutate(is_spike = SO2 >= so2_spike_ppb) %>%
  mutate(month = month(date_local)) %>%
  mutate(period = if_else(hour_local %in% daytime_hours, "Day, 9 am to 6 pm", "Night and morning"))

plume_normal <- plume_hours %>%
  filter(!is_spike) %>%
  summarise(across(c(Ozone, NO2, Ox), mean, .names = "normal_{.col}"), n_normal_hours = n(), .by = c(hour_local, month))

plume_spikes <- plume_hours %>%
  filter(is_spike) %>%
  arrange(datetime_utc) %>%
  mutate(episode = cumsum(is.na(lag(datetime_utc)) | as.numeric(difftime(datetime_utc, lag(datetime_utc), units = "hours")) > 1)) %>%
  inner_join(plume_normal, by = c("hour_local", "month"), relationship = "many-to-one") %>%
  mutate(Ozone = Ozone - normal_Ozone, NO2 = NO2 - normal_NO2, Ox = Ox - normal_Ox) %>%
  select(datetime_utc, period, episode, Ozone, NO2, Ox, n_normal_hours) %>%
  pivot_longer(c(Ozone, NO2, Ox), names_to = "measure", values_to = "difference_ppb")

stopifnot(
  "Every spike hour has at least 50 spike-free hours at the same hour and month to compare with" = min(plume_spikes$n_normal_hours) >= 50
)

# 95% ranges resample whole episodes, since hours within one plume are linked
episode_mean_range <- function(values, episodes) {
  by_episode <- split(values, episodes)
  resampled_means <- vapply(seq_len(bootstrap_reps), \(rep) {
    mean(unlist(by_episode[sample(names(by_episode), length(by_episode), replace = TRUE)]))
  }, numeric(1))
  unname(quantile(resampled_means, c(0.025, 0.975)))
}

set.seed(bootstrap_seed)

plume_test <- bind_rows(
  mutate(plume_spikes, period = "All hours"),
  plume_spikes
) %>%
  summarise(
    n_spike_hours = n(),
    n_episodes = n_distinct(episode),
    mean_difference_ppb = mean(difference_ppb),
    range = list(episode_mean_range(difference_ppb, episode)),
    .by = c(period, measure)
  ) %>%
  mutate(ci_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(ci_high = vapply(range, \(r) r[2], numeric(1))) %>%
  select(-range) %>%
  mutate(period = factor(period, levels = c("All hours", "Day, 9 am to 6 pm", "Night and morning"))) %>%
  mutate(measure = factor(measure, levels = ox_measures)) %>%
  arrange(period, measure) %>%
  mutate(across(c(mean_difference_ppb, ci_low, ci_high), \(x) round(x, 2)))

print(plume_test)

plume_result <- function(period_name, measure_name) {
  filter(plume_test, period == period_name, measure == measure_name)
}

night_ozone <- plume_result("Night and morning", "Ozone")

all_no2 <- plume_result("All hours", "NO2")

stopifnot(
  "NO2 is higher on Deer Park #2 spike hours, range clear of zero, as the subtitle says" = all_no2$ci_low > 0,
  "Ozone is lower on night and morning spike hours, as the subtitle says" = night_ozone$mean_difference_ppb < 0
)

# Figure 2C.5: when each site spikes, by hour of day, season and day type, and the Deer Park #2 plume test. Labels sit on
# the panels so each one reads on its own
site_levels <- main_spike_sites$short_name

n_so2_sites <- length(site_levels)

so2_label_size <- (chart_sizes[["label"]] - 0.7) / .pt

so2_site_axis <- theme(
  panel.grid.major = element_blank(),
  axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.3)
)

hour_rates <- so2_spike_profiles %>%
  filter(period_type == "Hour of day") %>%
  mutate(hour_local = as.integer(period)) %>%
  mutate(short_name = factor(short_name, levels = rev(site_levels)))

# Each site's share of spikes in the daytime window, written at the end of its row
daytime_shares <- main_spike_sites %>%
  mutate(short_name = factor(short_name, levels = rev(site_levels))) %>%
  mutate(label = sprintf("%.0f%%", pct_spikes_daytime))

so2_hour_panel <- ggplot(hour_rates, aes(hour_local, short_name)) +
  geom_tile(aes(fill = spike_rate_per_1000), colour = "white", linewidth = 0.3) +
  annotate(
    "segment", x = min(daytime_hours) - 0.5, xend = max(daytime_hours) + 0.5, y = n_so2_sites + 0.62, yend = n_so2_sites + 0.62,
    colour = chart_ink[["secondary"]], linewidth = 0.4
  ) +
  annotate(
    "text", x = mean(daytime_hours), y = n_so2_sites + 0.62, label = "9 AM TO 6 PM", vjust = -0.6,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_ink[["secondary"]]
  ) +
  annotate(
    "text", x = 24.6, y = n_so2_sites + 0.62, label = "BY DAY", hjust = 0, vjust = -0.6,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_ink[["secondary"]]
  ) +
  geom_text(
    data = daytime_shares, aes(x = 24.6, label = label), hjust = 0,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_ink[["secondary"]]
  ) +
  scale_fill_gradient(
    low = "white", high = chart_fills[["accent"]], name = "SPIKE HOURS PER 1,000",
    guide = guide_colourbar(title.position = "left", barwidth = unit(70, "pt"), barheight = unit(4, "pt"))
  ) +
  scale_x_continuous(breaks = seq(0, 18, 6), labels = \(x) sprintf("%02d:00", x), expand = expansion(add = c(0.6, 3.4))) +
  scale_y_discrete(expand = expansion(add = c(0.6, 1.1))) +
  coord_cartesian(clip = "off") +
  labs(title = "01  BY HOUR OF DAY", subtitle = "When in the day each site spikes", x = NULL, y = NULL) +
  theme_aqs() +
  so2_site_axis +
  theme(
    legend.position = "bottom",
    legend.title = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["muted"]], size = chart_sizes[["axis"]] - 0.6),
    legend.text = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["muted"]], size = chart_sizes[["axis"]] - 0.6),
    legend.margin = margin(4, 0, 0, 0)
  )

season_rates <- site_season_rates %>%
  mutate(short_name = factor(short_name, levels = rev(site_levels)))

so2_season_panel <- ggplot(season_rates, aes(season, short_name, fill = spike_rate_per_1000)) +
  geom_tile(colour = "white", linewidth = 0.3) +
  geom_text(
    aes(label = sprintf("%.1f", spike_rate_per_1000), colour = spike_rate_per_1000 > 0.6 * max(spike_rate_per_1000)),
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.5) / .pt
  ) +
  scale_fill_gradient(low = "white", high = chart_fills[["accent"]], guide = "none") +
  scale_colour_manual(values = c(`TRUE` = "white", `FALSE` = chart_ink[["secondary"]]), guide = "none") +
  scale_x_discrete(labels = toupper, position = "top") +
  labs(title = "02  BY SEASON", subtitle = "Spike hours per 1,000 hours", x = NULL, y = NULL) +
  theme_aqs() +
  so2_site_axis +
  theme(axis.text.x.top = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["muted"]], size = chart_sizes[["axis"]]))

day_type_rates <- so2_spike_profiles %>%
  filter(period_type == "Day type") %>%
  mutate(short_name = factor(short_name, levels = rev(site_levels))) %>%
  mutate(group_colour = unname(site_group_colours[as.character(site_group)]))

day_type_wide <- day_type_rates %>%
  select(short_name, group_colour, period, spike_rate_per_1000) %>%
  pivot_wider(names_from = period, values_from = spike_rate_per_1000)

# The ring (weekend) and dot (weekday) are named once, above the top row; each name is anchored to the side away from
# the other point so the two never overlap
top_day_type <- day_type_wide %>%
  filter(short_name == site_levels[1])

day_type_names <- tibble(
  short_name = factor(site_levels[1], levels = rev(site_levels)),
  label = c("WEEKEND", "WEEKDAY"),
  x = c(top_day_type$Weekend, top_day_type$Weekday),
  hjust = if_else(c(top_day_type$Weekend, top_day_type$Weekday) == pmin(top_day_type$Weekend, top_day_type$Weekday), 1, 0)
)

so2_day_type_panel <- ggplot(day_type_rates, aes(spike_rate_per_1000, short_name)) +
  geom_segment(data = day_type_wide, aes(x = Weekend, xend = Weekday, yend = short_name), colour = chart_ink[["axis"]], linewidth = 0.6) +
  geom_point(data = filter(day_type_rates, period == "Weekend"), aes(colour = group_colour), shape = 21, fill = "white", size = 1.8, stroke = 0.7) +
  geom_point(data = filter(day_type_rates, period == "Weekday"), aes(colour = group_colour), size = 1.8) +
  geom_text(
    data = day_type_names, aes(x = x, label = label, hjust = hjust), nudge_y = 0.5,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_fills[["accent"]]
  ) +
  scale_colour_identity() +
  scale_x_continuous(limits = c(0, NA), expand = expansion(mult = c(0.02, 0.12))) +
  coord_cartesian(clip = "off") +
  labs(title = "03  WEEKDAY AND WEEKEND", subtitle = "Spike hours per 1,000, April to October", x = NULL, y = NULL) +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.3)
  )

measure_labels <- c(Ozone = "Ozone", NO2 = "NO2", Ox = "Ox (ozone + NO2)")

period_labels <- c("Day, 9 am to 6 pm" = "DAY", "Night and morning" = "NIGHT")

# Day and night sit side by side, each with its own value labels, so no label lands on another range
plume_plot <- plume_test %>%
  filter(period != "All hours") %>%
  mutate(period = factor(as.character(period), levels = names(period_labels))) %>%
  mutate(measure = factor(measure, levels = rev(ox_measures))) %>%
  mutate(value_label = sprintf("%+.1f", mean_difference_ppb))

so2_plume_panel <- ggplot(plume_plot, aes(mean_difference_ppb, measure)) +
  geom_vline(xintercept = 0, colour = chart_ink[["axis"]], linewidth = 0.4) +
  geom_errorbar(aes(xmin = ci_low, xmax = ci_high), orientation = "y", width = 0, linewidth = 0.8, colour = chart_fills[["accent"]]) +
  geom_point(size = 1.7, colour = chart_fills[["accent"]]) +
  geom_text(
    aes(label = value_label), vjust = -0.95,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_ink[["secondary"]]
  ) +
  facet_grid(. ~ period, labeller = as_labeller(period_labels)) +
  scale_x_continuous(breaks = c(-5, 0, 5, 10)) +
  scale_y_discrete(labels = measure_labels, expand = expansion(add = c(0.5, 0.8))) +
  labs(title = "04  DEER PARK #2 PLUMES", subtitle = "Spike hours minus a normal hour (ppb)", x = NULL, y = NULL) +
  theme_aqs() +
  facet_strips +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.3)
  )

so2_header <- chart_header(
  sprintf("FIGURE 2C.5  /  SO2 SPIKE HOURS  /  %s TO %s", min(study_years), max(study_years)),
  "Croquet's SO2 spikes come almost only by day",
  sprintf(
    str_c(
      "%.0f%% of its spike hours fall from 9 am to 6 pm, and its summer rate is %.0f times any other season's.\n",
      "Spikes last about an hour, seldom hit two sites at once, and add %.1f ppb of NO2 at Deer Park #2."
    ),
    croquet_spikes$pct_spikes_daytime, croquet_summer_ratio, all_no2$mean_difference_ppb
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel site",
    "dot", site_group_colours[["Houston other"]],        "Houston other site (Croquet)"
  )
)

so2_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d). Spike: an hour at ", so2_spike_ppb, " ppb or more (detection limit 2 ppb, 0.2 at Deer Park #2).\n",
  "03: three weekday holidays left out. 04: each gas on spike hours minus its usual level at that hour and month.\n",
  "Day: 9 am to 6 pm; night: all other hours. Bars: 95% ranges, resampling whole episodes. Clinton's baseline drifts low."
))

so2_figure <- chart_compose(so2_header, list(so2_hour_panel, so2_season_panel, so2_day_type_panel, so2_plume_panel), so2_footer)

so2_figure_path <- here("figures", "phase2", "2c.05_so2_spikes.png")

save_started <- Sys.time()

ggsave(so2_figure_path, so2_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2c.05_so2_spikes.png was written (close any viewer of it and rerun this step)" = file.mtime(so2_figure_path) >= save_started - 2
)

# CSV records: spike counts per site and check, spike rates by hour, season and day type, and the plume test
so2_records <- list(
  case_study_so2_spike_sites = rename(so2_spike_sites, local_site_name = short_name),
  case_study_so2_spike_profiles = so2_spike_profiles %>%
    rename(local_site_name = short_name) %>%
    mutate(spike_rate_per_1000 = round(spike_rate_per_1000, 2)),
  case_study_so2_plume_test = plume_test
)

save_records(so2_records, records_dir)

so2_dictionary <- tribble(
  ~table,                          ~column,                     ~description,
  "case_study_so2_spike_sites",    "site_set",                  "Main or Without Deer Park #2 after its move (the only check that changes SO2 hours)",
  "case_study_so2_spike_sites",    "site_group",                "Case-study group: Houston Ship Channel or Houston other",
  "case_study_so2_spike_sites",    "site_id",                   "AQS site ID: state-county-site",
  "case_study_so2_spike_sites",    "local_site_name",           "Site name, shortened",
  "case_study_so2_spike_sites",    "n_hours",                   "Ordinary SO2 hours",
  "case_study_so2_spike_sites",    "pct_below_mdl",             "Share of hours below the method detection limit",
  "case_study_so2_spike_sites",    "n_spike_hours",             "Hours at or above 5 ppb",
  "case_study_so2_spike_sites",    "spike_rate_per_1000",       "Spike hours per 1,000 ordinary hours",
  "case_study_so2_spike_sites",    "n_spike_days",              "Days with at least one spike hour",
  "case_study_so2_spike_sites",    "n_check_spike_hours",       "Hours at or above 10 ppb (the check cutoff)",
  "case_study_so2_spike_sites",    "check_spike_rate_per_1000", "Hours at or above 10 ppb per 1,000 ordinary hours",
  "case_study_so2_spike_sites",    "max_ppb",                   "Highest ordinary hour, ppb",
  "case_study_so2_spike_sites",    "pct_spikes_daytime",        "Share of spike hours between 9 am and 6 pm, local standard time",
  "case_study_so2_spike_sites",    "n_episodes",                "Runs of consecutive spike hours",
  "case_study_so2_spike_sites",    "median_episode_hours",      "Median length of an episode, hours",
  "case_study_so2_spike_sites",    "max_episode_hours",         "Longest episode, hours",
  "case_study_so2_spike_sites",    "n_spike_hours_shared",      "Spike hours when another Ship Channel site also spiked; NA at Croquet",
  "case_study_so2_spike_profiles", "site_group",                "Case-study group: Houston Ship Channel or Houston other",
  "case_study_so2_spike_profiles", "site_id",                   "AQS site ID: state-county-site",
  "case_study_so2_spike_profiles", "local_site_name",           "Site name, shortened",
  "case_study_so2_spike_profiles", "period_type",               "Hour of day, Season, or Day type (April to October, three holidays left out)",
  "case_study_so2_spike_profiles", "period",                    "The hour (0 to 23, local standard time), season, or Weekday / Weekend",
  "case_study_so2_spike_profiles", "n_hours",                   "Ordinary SO2 hours in the period",
  "case_study_so2_spike_profiles", "n_spike_hours",             "Hours at or above 5 ppb in the period",
  "case_study_so2_spike_profiles", "spike_rate_per_1000",       "Spike hours per 1,000 ordinary hours in the period",
  "case_study_so2_plume_test",     "period",                    "All hours, Day (9 am to 6 pm) or Night and morning, local standard time",
  "case_study_so2_plume_test",     "measure",                   "Ozone, NO2 or Ox (ozone + NO2) at Deer Park #2",
  "case_study_so2_plume_test",     "n_spike_hours",             "SO2 spike hours with ozone and NO2 also ordinary",
  "case_study_so2_plume_test",     "n_episodes",                "Runs of consecutive spike hours among them",
  "case_study_so2_plume_test",     "mean_difference_ppb",       "Mean on spike hours minus the spike-free mean at the same hour and month, ppb",
  "case_study_so2_plume_test",     "ci_low",                    "Lower end of the 95% range from resampling whole episodes",
  "case_study_so2_plume_test",     "ci_high",                   "Upper end of the 95% range from resampling whole episodes"
)

so2_dictionary <- document_tables(so2_records, so2_dictionary)

replace_own_rows(so2_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(so2_site_sets)
