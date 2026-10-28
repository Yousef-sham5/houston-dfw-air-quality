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
library(jsonlite)

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

# Wind and calm air (section 5). Calm is below 0.5 m/s, EPA's starting threshold for wind sensors (1e). The other
# bands are in m/s
wind_speed_breaks_ms <- c(0, 0.5, 1.5, 3, 5, Inf)

wind_speed_bands <- c("Calm", "0.5 to 1.5", "1.5 to 3", "3 to 5", "5 or more")

# Each calm hour is compared with windy hours at the same site, hour of day and month, so time of day and season
# cancel out. Every such cell needs at least this many windy hours
min_windy_cell_hours <- 30

# A check in section 5 only: hours on the new sonic wind sensors at the five sites that switched are left out
sensor_check_level <- "Without new wind sensors"

# Pollution roses and source directions (section 6). The land-cut channel from 1c's map file, to find the directions in
# which it lies from each site
channel_path <- here("data", "reference", "ship_channel.geojson")

land_cut_sections <- c(
  "CESWG_HS_04_MPE",
  "CESWG_HS_05_ECB",
  "CESWG_HS_06_CBB",
  "CESWG_HS_07_BGB",
  "CESWG_HS_08_GHB",
  "CESWG_HS_09_HSB",
  "CESWG_HS_0A_TPB",
  "CESWG_HS_10_SBT",
  "CESWG_HS_11_HTB",
  "CESWG_HS_12_UTB",
  "CESWG_HS_8A_TPH",
  "CESWG_HS_9A_TPC"
)

# Kilometres on a flat map centred on Houston's latitude (29.7°), as in 1c
km_per_lat_degree <- 110.574

km_per_lon_degree_houston <- 111.320 * cos(29.7 * pi / 180)

# A sector with fewer hours than this is left blank in a rose
min_sector_hours <- 200

# The shared Houston wind for the Ox gap is the vector mean of the Houston sites' own sensors. An hour needs at least
# three sites, and a mean speed of at least 0.5 m/s (the calm threshold) to have a direction
min_wind_sites <- 3

# Four 90-degree quadrants of three 30-degree sectors each, for the Ox gap by season
quadrant_sectors <- tibble(
  wind_sector = seq(0, 330, 30),
  quadrant = c("North", "North", "East", "East", "East", "South", "South", "South", "West", "West", "West", "North")
)

# East wind: the east quadrant, 45° to 135°, used to judge the NO2 peak under every check
east_sectors <- quadrant_sectors$wind_sector[quadrant_sectors$quadrant == "East"]

# Southwest: the two sectors from 195° to 255°
southwest_sectors <- c(210, 240)

# 16-point compass names for the 12 sector centres
compass_names <- c("N", "NNE", "ENE", "E", "ESE", "SSE", "S", "SSW", "WSW", "W", "WNW", "NNW")

# Section 7 redraws the headline 95% ranges with a second seed; an end that moves more than this share of the range's
# width fails validation, as in 2b
bootstrap_check_seed <- 2027

bootstrap_seed_tolerance <- 0.1

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
    all(ymd(c("2021-05-31", "2021-07-05", "2023-07-04", "2025-05-26", "2025-09-01")) %in% weekday_holidays$date_local),
  "Five wind speed bands, the first one calm (below 0.5 m/s)" =
    length(wind_speed_bands) == length(wind_speed_breaks_ms) - 1 && wind_speed_breaks_ms[2] == 0.5,
  "Four quadrants of three sectors each" = all(count(quadrant_sectors, quadrant)$n == 3) && nrow(quadrant_sectors) == 12,
  "The southwest sectors are among the 12" = all(southwest_sectors %in% quadrant_sectors$wind_sector),
  "East wind covers the sectors centred on 60°, 90° and 120°" = identical(east_sectors, c(60, 90, 120)),
  "The seed check uses a different seed" = bootstrap_check_seed != bootstrap_seed
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
  labs(title = "01  COVERAGE BY MONTH", subtitle = "Months with data from each instrument", x = NULL, y = NULL) +
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
  sprintf("All three groups report at once in %s%% of hours", main_coverage_floor),
  sprintf(
    str_c(
      "%s monitors at %s sites; %s of their %s hours are kept (full days, no storms or smoke).\n",
      "Usable wind direction is thinnest at %s: %s%% of hours, after a %s-day gap in its wind."
    ),
    nrow(monitors), n_distinct(monitors$site_id), comma(funnel_totals$ordinary_hours), comma(funnel_totals$all_hours),
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
  "EPA AQS hourly data (1d, 1e). Ordinary (kept) hours: full days outside Winter Storm Uri, Hurricane Beryl and smoke.\n",
  "01: black ticks mark Harvard Street's NO2 method change and new wind sensors; teal marks the Deer Park #2 move.\n",
  "02: arrows show hours lost for lack of a wind direction (calm or missing). Bold Harvard Street uses Croquet's wind."
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

# Gap charts show a + on values above zero and name each side of the zero line, so a reader sees which way is which
signed_labels <- function(x) {
  if_else(x > 0, str_c("+", x), as.character(x))
}

zero_line_labels <- function(above, below, x = Inf, hjust = 1) {
  list(
    annotate(
      "text", x = x, y = 0, label = above, hjust = hjust, vjust = -0.7,
      family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 1.2) / .pt, colour = chart_ink[["muted"]]
    ),
    annotate(
      "text", x = x, y = 0, label = below, hjust = hjust, vjust = 1.7,
      family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 1.2) / .pt, colour = chart_ink[["muted"]]
    )
  )
}

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
    zero_line_labels("SHIP CHANNEL HIGHER", "SHIP CHANNEL LOWER") +
    scale_linetype_manual(values = c(`TRUE` = "22", `FALSE` = "solid"), guide = "none") +
    scale_y_continuous(labels = signed_labels, expand = expansion(mult = 0.14)) +
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

# Shown as percent higher or lower on weekends, which reads more easily than the ratio saved in the record. The side
# labels sit in the NO2 panel only, since ozone runs along the zero line for most of the day; the lower one sits at the
# foot of the panel, below the evening lines
weekend_plot <- weekend_profiles %>%
  filter(site_set == "Main") %>%
  mutate(weekend_pct = 100 * (weekend_ratio - 1))

weekend_side_labels <- tibble(
  pollutant = factor("NO2", levels = cycle_pollutants),
  label = c("HIGHER ON WEEKENDS", "LOWER ON WEEKENDS"),
  y = c(0, -Inf),
  vjust = c(-0.7, -0.6)
)

weekend_panel <- ggplot(weekend_plot, aes(hour_local, weekend_pct, colour = site_group)) +
  annotate("rect", xmin = min(morning_hours) - 0.5, xmax = max(morning_hours) + 0.5, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
  geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_line(linewidth = 0.6) +
  geom_text(
    data = weekend_side_labels, aes(x = Inf, y = y, label = label, vjust = vjust), inherit.aes = FALSE, hjust = 1,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 1.2) / .pt, colour = chart_ink[["muted"]]
  ) +
  facet_grid(. ~ pollutant, labeller = as_labeller(toupper)) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_y_continuous(labels = \(x) str_c(signed_labels(x), "%")) +
  hour_axis +
  labs(title = "03  WEEKEND", subtitle = "Weekend against weekday, April to October", x = NULL, y = NULL) +
  theme_aqs() +
  facet_strips

season_weekend_header <- chart_header(
  sprintf("FIGURE 2C.3  /  SEASON AND WEEKEND  /  %s TO %s", min(study_years), max(study_years)),
  "NO2 falls least on Ship Channel weekend mornings",
  sprintf(
    str_c(
      "Weekend NO2 at %s to %s am vs weekdays: Ship Channel %+.0f%%, Houston other %+.0f%%, DFW %+.0f%%.\n",
      "Consistent with more all-week NO2 sources. Morning ozone is %.0f to %.0f%% higher on weekends."
    ),
    min(morning_hours), max(morning_hours), 100 * (morning_no2_ratio("Houston Ship Channel") - 1),
    100 * (morning_no2_ratio("Houston other") - 1), 100 * (morning_no2_ratio("Dallas-Fort Worth") - 1),
    100 * (min(main_morning_ozone$morning_weekend_ratio) - 1),
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
  "03: weekend mean against weekday mean at each hour; Memorial Day, Independence Day and Labor Day left out, as in 2a."
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

rm(cycle_site_sets)



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
  labs(title = "01  OX BY HOUR", subtitle = "Ox (ozone + NO2) by hour of day (ppb)", x = NULL, y = NULL) +
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
  zero_line_labels("SHIP CHANNEL HIGHER", "SHIP CHANNEL LOWER") +
  scale_colour_manual(values = ox_gap_colours, guide = "none") +
  scale_linetype_manual(values = ox_gap_lines, guide = "none") +
  scale_linewidth_manual(values = c(`TRUE` = 0.8, `FALSE` = 0.5), guide = "none") +
  scale_y_continuous(labels = signed_labels) +
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
  zero_line_labels("SHIP CHANNEL HIGHER", "SHIP CHANNEL LOWER") +
  scale_x_discrete(labels = \(x) toupper(str_remove(x, "^All "))) +
  scale_y_continuous(labels = signed_labels, expand = expansion(mult = c(0.05, 0.12))) +
  labs(title = "03  BY SEASON", subtitle = "Average gap by season (ppb)", x = NULL, y = NULL) +
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
  scale_x_continuous(labels = signed_labels, expand = expansion(mult = c(0.05, 0.15))) +
  scale_y_discrete(expand = expansion(add = c(0.4, 0.8))) +
  labs(title = "04  CHECKS", subtitle = "Share of the ozone gap NO2 accounts for", x = NULL, y = NULL) +
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
    "text", x = 24.6, y = n_so2_sites + 0.62, label = "% BY DAY", hjust = 0, vjust = -0.6,
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
  scale_x_continuous(breaks = c(-5, 0, 5, 10), labels = signed_labels) +
  scale_y_discrete(labels = measure_labels, expand = expansion(add = c(0.5, 0.8))) +
  labs(title = "04  DEER PARK #2 PLUMES", subtitle = "In spike hours against a normal hour (ppb)", x = NULL, y = NULL) +
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



# 5. WIND AND CALM AIR ----
# How the wind behaves at each site, and how calm air changes what the monitors measure. Wind statistics use the eight
# sites with their own wind sensor, outside Uri and Beryl; Harvard Street borrows Croquet's wind (1e) and would repeat it
wind_hours <- hourly_weather %>%
  filter(is.na(event_name), !is.na(wind_sector), wind_source_site == site_id, !is_wind_spike) %>%
  mutate(site_group = factor(site_group, levels = names(site_group_colours))) %>%
  mutate(short_name = short_site_name(local_site_name)) %>%
  mutate(speed_band = cut(wind_speed_ms, wind_speed_breaks_ms, labels = wind_speed_bands, right = FALSE)) %>%
  select(
    site_group, site_id, short_name, datetime_utc, date_local, hour_local, season, wind_speed_ms, wind_sector, wind_u_ms,
    wind_v_ms, is_calm, is_sonic_wind, speed_band
  )

wind_check_levels <- c("Main", sensor_check_level)

stopifnot(
  "Eight sites with their own wind sensor, Harvard Street not among them" =
    n_distinct(wind_hours$site_id) == 8 && !"48-201-0417" %in% wind_hours$site_id,
  "Every wind hour has a speed band" = !anyNA(wind_hours$speed_band),
  "Calm hours are exactly the hours below 0.5 m/s" = all(wind_hours$is_calm == (wind_hours$speed_band == "Calm")),
  "Only the five sites that switched have hours on a new sensor" =
    setequal(unique(wind_hours$site_id[wind_hours$is_sonic_wind]), sonic_wind_starts$site_id)
)

# Each table is built for all hours and again without the new sensors, so the sensor change can be read off directly
wind_sets <- bind_rows(
  wind_hours %>%
    mutate(site_set = "Main"),
  wind_hours %>%
    filter(!is_sonic_wind) %>%
    mutate(site_set = sensor_check_level)
) %>%
  mutate(site_set = factor(site_set, levels = wind_check_levels))

wind_season_hours <- bind_rows(
  wind_hours %>%
    mutate(season = "All year"),
  wind_hours %>%
    mutate(season = as.character(season))
) %>%
  mutate(season = factor(season, levels = season_levels))

# u and v point where the wind blows to (1e), so the direction it comes from is the reverse of their mean. Steadiness is
# the length of the mean vector over the mean speed: 1 when the wind always comes from one direction, near 0 when it
# swings evenly around. Both use hours with wind, since a calm hour has no reliable direction
wind_vectors <- wind_season_hours %>%
  filter(!is_calm) %>%
  summarise(
    mean_u = mean(wind_u_ms),
    mean_v = mean(wind_v_ms),
    mean_moving_speed = mean(wind_speed_ms),
    .by = c(site_id, season)
  ) %>%
  mutate(resultant_from_deg = (atan2(-mean_u, -mean_v) * 180 / pi) %% 360) %>%
  mutate(steadiness = sqrt(mean_u^2 + mean_v^2) / mean_moving_speed) %>%
  select(site_id, season, resultant_from_deg, steadiness)

prevailing_sectors <- wind_season_hours %>%
  filter(!is_calm) %>%
  count(site_id, season, wind_sector) %>%
  mutate(pct_of_moving_hours = 100 * n / sum(n), .by = c(site_id, season)) %>%
  slice_max(n, n = 1, with_ties = FALSE, by = c(site_id, season)) %>%
  select(site_id, season, prevailing_sector = wind_sector, pct_prevailing_sector = pct_of_moving_hours)

wind_site_summary <- wind_season_hours %>%
  summarise(
    n_wind_hours = n(),
    pct_calm = 100 * mean(is_calm),
    pct_calm_old_sensor = 100 * mean(is_calm[!is_sonic_wind]),
    pct_calm_new_sensor = if (any(is_sonic_wind)) 100 * mean(is_calm[is_sonic_wind]) else NA_real_,
    mean_speed_ms = mean(wind_speed_ms),
    median_speed_ms = median(wind_speed_ms),
    .by = c(site_group, site_id, short_name, season)
  ) %>%
  left_join(select(sonic_wind_starts, site_id, sonic_wind_from), by = "site_id", relationship = "many-to-one") %>%
  left_join(wind_vectors, by = c("site_id", "season"), relationship = "one-to-one") %>%
  left_join(prevailing_sectors, by = c("site_id", "season"), relationship = "one-to-one") %>%
  arrange(season, site_group, short_name)

wind_site_summary %>%
  filter(season == "All year") %>%
  select(-season, -site_id) %>%
  mutate(across(where(is.double), \(x) round(x, 2))) %>%
  print(width = Inf)

all_year_wind <- wind_site_summary %>%
  filter(season == "All year")

houston_wind <- wind_site_summary %>%
  filter(site_group != "Dallas-Fort Worth", season %in% c("Winter", "Summer")) %>%
  select(site_id, season, steadiness) %>%
  pivot_wider(names_from = season, values_from = steadiness)

stopifnot(
  "One row per site and season" = nrow(wind_site_summary) == 8 * length(season_levels),
  "Every site has at least 25,000 wind hours" = all(all_year_wind$n_wind_hours >= 25000),
  "The new sensors read at least 1 point fewer calm hours at three of the five sites" =
    sum(all_year_wind$pct_calm_old_sensor - all_year_wind$pct_calm_new_sensor >= 1, na.rm = TRUE) == 3,
  "At every site the wind comes most often from 150 or 180 degrees, as the title says" =
    all(all_year_wind$prevailing_sector %in% c(150, 180)),
  "At every Houston site the summer wind is steadier than the winter wind, as the subtitle says" =
    all(houston_wind$Summer > houston_wind$Winter)
)

# Hours by direction and speed for each wind rose, as a share of all wind hours with calm hours included, so a rose's
# petals and its calm centre add up to 100%
rose_moving <- wind_season_hours %>%
  filter(!is_calm) %>%
  count(site_group, site_id, short_name, season, wind_sector, speed_band, name = "n_hours") %>%
  complete(
    nesting(site_group, site_id, short_name, season),
    wind_sector = seq(0, 330, 30),
    speed_band = factor(wind_speed_bands[-1], levels = wind_speed_bands),
    fill = list(n_hours = 0L)
  ) %>%
  filter(speed_band != "Calm")

rose_calm <- wind_season_hours %>%
  filter(is_calm) %>%
  count(site_group, site_id, short_name, season, speed_band, name = "n_hours")

site_roses <- bind_rows(rose_moving, rose_calm) %>%
  mutate(pct_of_wind_hours = 100 * n_hours / sum(n_hours), .by = c(site_id, season)) %>%
  mutate(level = "Site") %>%
  arrange(season, site_group, short_name, speed_band, wind_sector)

# The six Houston sites together, each counting equally, to show how the wind turns with the seasons
houston_roses <- site_roses %>%
  filter(site_group != "Dallas-Fort Worth") %>%
  summarise(n_sites = n(), n_hours = sum(n_hours), pct_of_wind_hours = mean(pct_of_wind_hours), .by = c(season, wind_sector, speed_band)) %>%
  mutate(level = "Houston, 6 sites")

rose_totals <- site_roses %>%
  summarise(total_pct = sum(pct_of_wind_hours), .by = c(site_id, season))

stopifnot(
  "Each rose has 12 sectors by 4 speed bands plus calm" = all(count(site_roses, site_id, season)$n == 12 * 4 + 1),
  "Each site rose adds up to 100%" = all(abs(rose_totals$total_pct - 100) < 1e-9),
  "The Houston roses average all six Houston sites" = all(houston_roses$n_sites == 6),
  "Each Houston rose adds up to 100%" = all(abs(summarise(houston_roses, s = sum(pct_of_wind_hours), .by = season)$s - 100) < 1e-9)
)

# Calm share by hour of day; a group's value is the mean of its sites' shares
calm_site_hours <- wind_sets %>%
  summarise(n_wind_hours = n(), pct_calm = 100 * mean(is_calm), .by = c(site_set, site_group, site_id, hour_local))

calm_by_hour <- calm_site_hours %>%
  summarise(
    n_sites = n(),
    min_wind_hours = min(n_wind_hours),
    low_site_pct = min(pct_calm),
    high_site_pct = max(pct_calm),
    pct_calm = mean(pct_calm),
    .by = c(site_set, site_group, hour_local)
  ) %>%
  arrange(site_set, site_group, hour_local)

main_calm_hours <- calm_by_hour %>%
  filter(site_set == "Main")

calm_group_shares <- all_year_wind %>%
  summarise(pct_calm = mean(pct_calm), .by = site_group)

calm_share <- function(group) {
  calm_group_shares$pct_calm[calm_group_shares$site_group == group]
}

night_calm <- main_calm_hours %>%
  summarise(night_share_of_calm = sum(pct_calm[hour_local <= 5]) / sum(pct_calm), .by = site_group)

print(calm_group_shares)
print(night_calm)

stopifnot(
  "24 hours for every set and group" = all(count(calm_by_hour, site_set, site_group)$n == 24),
  "Every site has at least 900 wind hours at each hour of the day" = min(main_calm_hours$min_wind_hours) >= 900,
  "Without the new sensors, every site keeps at least 300 wind hours at each hour of the day" = min(calm_by_hour$min_wind_hours) >= 300,
  "Both Houston groups are calm at least 3 times as often as Dallas-Fort Worth, as the subtitle says" =
    min(calm_share("Houston Ship Channel"), calm_share("Houston other")) >= 3 * calm_share("Dallas-Fort Worth"),
  "In both Houston groups, most calm hours fall from midnight to 6 am, as the subtitle says" =
    all(night_calm$night_share_of_calm[night_calm$site_group != "Dallas-Fort Worth"] > 0.5),
  "Without the new sensors, Houston is still the calmer region at every hour" =
    all(
      calm_by_hour %>%
        filter(site_set == sensor_check_level) %>%
        summarise(ok = min(pct_calm[site_group != "Dallas-Fort Worth"]) > pct_calm[site_group == "Dallas-Fort Worth"], .by = hour_local) %>%
        pull(ok)
    )
)

# Ozone, NO2 and Ox on ordinary hours with a wind reading. Ox comes from section 3's paired hours. The spike hour is left out
wind_columns <- hourly_weather %>%
  select(site_id, datetime_utc, wind_speed_ms, is_calm, is_wind_spike, is_sonic_wind)

calm_measure_hours <- bind_rows(
  hourly %>%
    filter(is_ordinary_hour, pollutant %in% cycle_pollutants) %>%
    mutate(measure = as.character(pollutant)) %>%
    select(measure, site_group, site_id, datetime_utc, date_local, hour_local, in_transition_band, is_post_method_change, is_post_relocation, value_ppb),
  ox_hours %>%
    mutate(measure = "Ox") %>%
    select(measure, site_group, site_id, datetime_utc, date_local, hour_local, in_transition_band, is_post_method_change, is_post_relocation, value_ppb = ox_ppb)
) %>%
  inner_join(wind_columns, by = c("site_id", "datetime_utc"), relationship = "many-to-one") %>%
  filter(!is.na(is_calm), !is_wind_spike) %>%
  mutate(measure = factor(measure, levels = ox_measures)) %>%
  mutate(month = month(date_local)) %>%
  mutate(speed_band = cut(wind_speed_ms, wind_speed_breaks_ms, labels = wind_speed_bands, right = FALSE)) %>%
  select(-is_wind_spike)

wind_site_sets <- function(hours) {
  bind_rows(
    hourly_site_sets(hours),
    hours %>%
      filter(!is_sonic_wind) %>%
      mutate(site_set = sensor_check_level)
  ) %>%
    mutate(site_set = factor(as.character(site_set), levels = c(hourly_check_levels, sensor_check_level)))
}

calm_sets <- wind_site_sets(calm_measure_hours)

# Checks that leave a measure's hours unchanged are dropped, as in sections 2 and 4
unchanged_calm_sets <- calm_sets %>%
  count(site_set, measure) %>%
  mutate(is_unchanged = site_set != "Main" & n == n[site_set == "Main"], .by = measure) %>%
  filter(is_unchanged)

print(unchanged_calm_sets)

calm_sets <- calm_sets %>%
  anti_join(unchanged_calm_sets, by = c("site_set", "measure"))

stopifnot(
  "Six sites for ozone, NO2 and Ox" = all(count(distinct(calm_measure_hours, measure, site_id), measure)$n == 6),
  "Calm hours are exactly the hours below 0.5 m/s" = all(calm_measure_hours$is_calm == (calm_measure_hours$speed_band == "Calm")),
  "Only the method-change check leaves ozone unchanged" =
    identical(as.character(unchanged_calm_sets$site_set), "Without hours after the method change") &&
    identical(as.character(unchanged_calm_sets$measure), "Ozone")
)

# Each calm hour minus the mean of windy hours at the same site, hour of day and month. A site's value is the mean over
# days with calm hours of each day's mean difference, so a long calm night counts once
windy_reference <- calm_sets %>%
  filter(!is_calm) %>%
  summarise(n_windy_hours = n(), windy_ppb = mean(value_ppb), .by = c(site_set, measure, site_id, hour_local, month))

calm_differences <- calm_sets %>%
  filter(is_calm) %>%
  left_join(windy_reference, by = c("site_set", "measure", "site_id", "hour_local", "month"), relationship = "many-to-one") %>%
  mutate(difference_ppb = value_ppb - windy_ppb)

# Checks that remove years leave some cells thin, and their calm hours are left out. Bayland Park's old wind sensor ran
# only from March 2021 to April 2022, too short to match by hour and month, so it sits out the sensor check
thin_cell_hours <- calm_differences %>%
  summarise(n_calm_hours = n(), n_thin = sum(is.na(n_windy_hours) | n_windy_hours < min_windy_cell_hours), .by = c(site_set, measure, site_id)) %>%
  mutate(pct_thin = 100 * n_thin / n_calm_hours)

print(filter(thin_cell_hours, n_thin > 0))

sparse_sites <- thin_cell_hours %>%
  filter(pct_thin > 50) %>%
  select(site_set, measure, site_id)

calm_sets <- calm_sets %>%
  anti_join(sparse_sites, by = c("site_set", "measure", "site_id"))

calm_differences <- calm_differences %>%
  anti_join(sparse_sites, by = c("site_set", "measure", "site_id")) %>%
  filter(!is.na(n_windy_hours), n_windy_hours >= min_windy_cell_hours)

kept_thin_cells <- thin_cell_hours %>%
  anti_join(sparse_sites, by = c("site_set", "measure", "site_id"))

stopifnot(
  "The main set compares every calm hour with at least 30 windy hours" = all(thin_cell_hours$n_thin[thin_cell_hours$site_set == "Main"] == 0),
  "Only Bayland Park sits out, and only in the sensor check" =
    all(sparse_sites$site_id == "48-201-0055") && all(sparse_sites$site_set == sensor_check_level),
  "Every other site keeps at least 75% of its calm hours in every check" = all(kept_thin_cells$pct_thin <= 25)
)

calm_site_days <- calm_differences %>%
  summarise(n_calm_hours = n(), difference_ppb = mean(difference_ppb), .by = c(site_set, measure, site_group, site_id, date_local)) %>%
  arrange(site_set, measure, site_id, date_local)

calm_group_days <- calm_site_days %>%
  summarise(difference_ppb = mean(difference_ppb), .by = c(site_set, measure, site_group, date_local)) %>%
  arrange(site_set, measure, site_group, date_local)

# Plain calm and windy means beside the matched difference, so the effect of matching on time of day can be seen
plain_calm_means <- calm_sets %>%
  summarise(
    n_hours = n(),
    n_calm_hours = sum(is_calm),
    mean_calm_ppb = mean(value_ppb[is_calm]),
    mean_windy_ppb = mean(value_ppb[!is_calm]),
    .by = c(site_set, measure, site_group, site_id)
  ) %>%
  mutate(pct_calm = 100 * n_calm_hours / n_hours)

set.seed(bootstrap_seed)

calm_site_effects <- calm_site_days %>%
  summarise(
    n_calm_days = n(),
    calm_minus_windy_ppb = mean(difference_ppb),
    range = if (first(site_set) == "Main") list(block_mean_range(difference_ppb)) else list(c(NA_real_, NA_real_)),
    .by = c(site_set, measure, site_group, site_id)
  ) %>%
  inner_join(plain_calm_means, by = c("site_set", "measure", "site_group", "site_id"), relationship = "one-to-one")

calm_group_effects <- calm_group_days %>%
  summarise(
    n_calm_days = n(),
    calm_minus_windy_ppb = mean(difference_ppb),
    range = if (first(site_set) == "Main") list(block_mean_range(difference_ppb)) else list(c(NA_real_, NA_real_)),
    .by = c(site_set, measure, site_group)
  ) %>%
  inner_join(
    plain_calm_means %>%
      summarise(
        n_hours = sum(n_hours),
        n_calm_hours = sum(n_calm_hours),
        mean_calm_ppb = mean(mean_calm_ppb),
        mean_windy_ppb = mean(mean_windy_ppb),
        pct_calm = mean(pct_calm),
        .by = c(site_set, measure, site_group)
      ),
    by = c("site_set", "measure", "site_group"),
    relationship = "one-to-one"
  )

calm_air <- bind_rows(
  mutate(calm_site_effects, level = "Site"),
  mutate(calm_group_effects, level = "Group")
) %>%
  mutate(ci_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(ci_high = vapply(range, \(r) r[2], numeric(1))) %>%
  select(-range) %>%
  left_join(site_names, by = "site_id", relationship = "many-to-one") %>%
  mutate(plain_ratio = mean_calm_ppb / mean_windy_ppb) %>%
  select(
    site_set, measure, level, site_group, site_id, local_site_name, n_hours, n_calm_hours, n_calm_days, pct_calm, mean_calm_ppb,
    mean_windy_ppb, plain_ratio, calm_minus_windy_ppb, ci_low, ci_high
  ) %>%
  arrange(measure, desc(level), site_set, site_group, local_site_name)

calm_air %>%
  filter(site_set == "Main") %>%
  select(measure, level, site_group, local_site_name, n_calm_hours, plain_ratio, calm_minus_windy_ppb, ci_low, ci_high) %>%
  mutate(across(where(is.double), \(x) round(x, 2))) %>%
  print(n = Inf, width = Inf)

main_site_calm <- calm_air %>%
  filter(site_set == "Main", level == "Site")

main_group_calm <- calm_air %>%
  filter(site_set == "Main", level == "Group")

check_calm <- calm_air %>%
  filter(site_set != "Main")

calm_effect <- function(measure_name, group) {
  main_group_calm$calm_minus_windy_ppb[main_group_calm$measure == measure_name & main_group_calm$site_group == group]
}

group_ox_offset <- main_group_calm %>%
  select(site_group, measure, calm_minus_windy_ppb) %>%
  pivot_wider(names_from = measure, values_from = calm_minus_windy_ppb) %>%
  mutate(share_of_ozone_loss_in_no2 = 1 - Ox / Ozone)

print(group_ox_offset)

stopifnot(
  "NO2 is higher in calm hours at every site, each 95% range above zero, as the title says" =
    all(main_site_calm$ci_low[main_site_calm$measure == "NO2"] > 0),
  "Ozone is lower in calm hours at every site, each 95% range below zero, as the title says" =
    all(main_site_calm$ci_high[main_site_calm$measure == "Ozone"] < 0),
  "Every check keeps both signs at every site and group" =
    all(check_calm$calm_minus_windy_ppb[check_calm$measure == "NO2"] > 0) &&
    all(check_calm$calm_minus_windy_ppb[check_calm$measure == "Ozone"] < 0),
  "Matching on hour and month shrinks the plain NO2 contrast at every site" =
    all((main_site_calm$mean_calm_ppb - main_site_calm$mean_windy_ppb)[main_site_calm$measure == "NO2"] >
      main_site_calm$calm_minus_windy_ppb[main_site_calm$measure == "NO2"])
)

# Each measure by speed band, against a typical hour: the site's mean at the same hour of day and month over all its wind
# hours. A group's value is the mean of its sites' values
typical_hours <- calm_sets %>%
  summarise(typical_ppb = mean(value_ppb), .by = c(site_set, measure, site_id, hour_local, month))

band_site_means <- calm_sets %>%
  left_join(typical_hours, by = c("site_set", "measure", "site_id", "hour_local", "month"), relationship = "many-to-one") %>%
  summarise(
    n_hours = n(),
    mean_speed_ms = mean(wind_speed_ms),
    mean_ppb = mean(value_ppb),
    difference_from_typical_ppb = mean(value_ppb - typical_ppb),
    .by = c(site_set, measure, site_group, site_id, speed_band)
  )

speed_band_means <- bind_rows(
  mutate(band_site_means, level = "Site"),
  band_site_means %>%
    summarise(
      n_sites = n(),
      min_site_hours = min(n_hours),
      n_hours = sum(n_hours),
      mean_speed_ms = mean(mean_speed_ms),
      mean_ppb = mean(mean_ppb),
      difference_from_typical_ppb = mean(difference_from_typical_ppb),
      .by = c(site_set, measure, site_group, speed_band)
    ) %>%
    mutate(level = "Group")
) %>%
  left_join(site_names, by = "site_id", relationship = "many-to-one") %>%
  select(
    site_set, measure, level, site_group, site_id, local_site_name, speed_band, n_sites, n_hours, min_site_hours, mean_speed_ms,
    mean_ppb, difference_from_typical_ppb
  ) %>%
  arrange(measure, desc(level), site_set, site_group, local_site_name, speed_band)

main_band_groups <- speed_band_means %>%
  filter(site_set == "Main", level == "Group")

main_band_groups %>%
  select(measure, site_group, speed_band, mean_speed_ms, difference_from_typical_ppb) %>%
  mutate(across(where(is.double), \(x) round(x, 2))) %>%
  pivot_wider(names_from = speed_band, values_from = c(mean_speed_ms, difference_from_typical_ppb)) %>%
  print(width = Inf)

no2_band_steps <- main_band_groups %>%
  filter(measure == "NO2") %>%
  arrange(site_group, speed_band) %>%
  summarise(falls_every_step = all(diff(difference_from_typical_ppb) < 0), .by = site_group)

stopifnot(
  "Every group and band rests on at least 300 hours at its thinnest site" =
    min(main_band_groups$min_site_hours) >= 300,
  "NO2 falls with every step up in wind speed in every group, as the subtitle says" = all(no2_band_steps$falls_every_step)
)

# SO2 spike hours by wind speed. Calm hours fall mostly at night, when spikes are rare, so day and night are kept apart
so2_wind_hours <- so2_hours %>%
  inner_join(wind_columns, by = c("site_id", "datetime_utc"), relationship = "many-to-one") %>%
  filter(!is.na(is_calm), !is_wind_spike) %>%
  mutate(speed_band = cut(wind_speed_ms, wind_speed_breaks_ms, labels = wind_speed_bands, right = FALSE)) %>%
  mutate(period = if_else(hour_local %in% daytime_hours, "Day, 9 am to 6 pm", "Night and morning"))

so2_wind_sets <- wind_site_sets(so2_wind_hours)

unchanged_so2_wind_sets <- so2_wind_sets %>%
  count(site_set) %>%
  filter(site_set != "Main", n == n[site_set == "Main"])

so2_wind_sets <- so2_wind_sets %>%
  anti_join(unchanged_so2_wind_sets, by = "site_set")

so2_speed_bands <- bind_rows(
  mutate(so2_wind_sets, period = "All hours"),
  so2_wind_sets
) %>%
  summarise(
    n_hours = n(),
    n_spike_hours = sum(is_spike),
    mean_speed_ms = mean(wind_speed_ms),
    .by = c(site_set, site_group, site_id, short_name, period, speed_band)
  ) %>%
  complete(nesting(site_set, site_group, site_id, short_name, period), speed_band, fill = list(n_hours = 0L, n_spike_hours = 0L)) %>%
  mutate(spike_rate_per_1000 = 1000 * n_spike_hours / n_hours) %>%
  mutate(period = factor(period, levels = c("All hours", "Day, 9 am to 6 pm", "Night and morning"))) %>%
  arrange(site_set, site_group, short_name, period, speed_band)

main_so2_bands <- so2_speed_bands %>%
  filter(site_set == "Main", period != "All hours")

so2_band_peaks <- main_so2_bands %>%
  filter(period == "Day, 9 am to 6 pm") %>%
  summarise(
    peak_band = speed_band[which.max(spike_rate_per_1000)],
    strong_rate = spike_rate_per_1000[speed_band == "5 or more"],
    .by = short_name
  )

print(so2_band_peaks)

stopifnot(
  "Every site and period has hours in every band" = all(main_so2_bands$n_hours > 0),
  "Only the Deer Park #2 move and the sensor check change SO2 hours" =
    setequal(unique(as.character(so2_wind_sets$site_set)), c("Main", "Without Deer Park #2 after its move", sensor_check_level)),
  "By day, every site spikes most in calm or light wind (under 1.5 m/s) and never above 5 m/s" =
    all(so2_band_peaks$peak_band %in% wind_speed_bands[1:2]) && all(so2_band_peaks$strong_rate == 0)
)

# Figure 2C.6: a wind rose per site, and the six Houston sites by season. Petals stack hours by speed in each 30° sector,
# pointing to where the wind comes from; the centre holds the calm share. All roses share one scale
rose_band_colours <- c("0.5 to 1.5" = "#c2dfe2", "1.5 to 3" = "#86bec3", "3 to 5" = "#2d8a93", "5 or more" = "#0a4a50")

rose_hole <- 9

rose_ring_step <- 10

houston_season_roses <- houston_roses %>%
  filter(season != "All year")

rose_peak <- bind_rows(filter(site_roses, season == "All year"), houston_season_roses) %>%
  filter(speed_band != "Calm") %>%
  summarise(sector_pct = sum(pct_of_wind_hours), .by = c(level, site_id, season, wind_sector)) %>%
  pull(sector_pct) %>%
  max()

# The scale ends at the longest petal, so the roses use the whole panel
rose_top <- rose_peak

rose_rings <- rose_hole + seq(rose_ring_step, rose_top, rose_ring_step)

compass_points <- tibble(wind_sector = c(0, 90, 180, 270), label = c("N", "E", "S", "W"))

rose_panel <- function(roses, kicker, kicker_colour, name, caption) {
  petals <- roses %>%
    filter(speed_band != "Calm") %>%
    arrange(wind_sector, speed_band) %>%
    mutate(ymax = rose_hole + cumsum(pct_of_wind_hours), .by = wind_sector) %>%
    mutate(ymin = ymax - pct_of_wind_hours)
  calm_pct <- roses$pct_of_wind_hours[roses$speed_band == "Calm"]
  ggplot(petals) +
    annotate("rect", xmin = -15, xmax = 345, ymin = 0, ymax = rose_hole, fill = chart_fills[["band"]]) +
    geom_hline(yintercept = rose_rings, colour = chart_ink[["grid"]], linewidth = 0.3) +
    geom_rect(
      aes(xmin = wind_sector - 13, xmax = wind_sector + 13, ymin = ymin, ymax = ymax, fill = speed_band),
      colour = "white", linewidth = 0.12
    ) +
    annotate(
      "text", x = 0, y = 0, label = sprintf("%.0f%%", calm_pct), vjust = 0.05,
      family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.4) / .pt, colour = chart_ink[["primary"]]
    ) +
    annotate(
      "text", x = 0, y = 0, label = "CALM", vjust = 1.35,
      family = chart_fonts[["mono"]], size = (chart_sizes[["axis"]] - 1.8) / .pt, colour = chart_ink[["secondary"]]
    ) +
    geom_text(
      data = compass_points, aes(x = wind_sector, y = rose_hole + rose_top + 3.5, label = label),
      family = chart_fonts[["mono"]], size = (chart_sizes[["axis"]] - 0.6) / .pt, colour = chart_ink[["muted"]]
    ) +
    annotate("path", x = seq(-15, 345, 1), y = rose_hole + rose_top, colour = chart_ink[["axis"]], linewidth = 0.3) +
    scale_x_continuous(limits = c(-15, 345), expand = expansion(0)) +
    scale_y_continuous(limits = c(0, rose_hole + rose_top + 4.5), expand = expansion(0)) +
    scale_fill_manual(values = rose_band_colours, guide = "none") +
    coord_polar(start = -pi / 12, clip = "off") +
    labs(title = kicker, subtitle = name, caption = caption, x = NULL, y = NULL) +
    theme_aqs() +
    theme(
      axis.text = element_blank(),
      panel.grid.major = element_blank(),
      panel.grid.major.x = element_blank(),
      panel.grid.major.y = element_blank(),
      plot.title = element_text(colour = kicker_colour),
      plot.caption = element_text(family = chart_fonts[["mono"]], size = chart_sizes[["axis"]] - 0.8, margin = margin(t = 2)),
      plot.margin = margin(0, 10, 20, 0)
    )
}

group_kickers <- c("Houston Ship Channel" = "SHIP CHANNEL", "Houston other" = "HOUSTON OTHER", "Dallas-Fort Worth" = "DALLAS-FORT WORTH")

rose_site_order <- all_year_wind %>%
  left_join(select(site_roles, site_id, km_to_channel), by = "site_id", relationship = "one-to-one") %>%
  arrange(site_group, km_to_channel, short_name)

site_rose_panels <- lapply(seq_len(nrow(rose_site_order)), \(i) {
  site <- rose_site_order[i, ]
  rose_panel(
    filter(site_roses, site_id == site$site_id, season == "All year"),
    group_kickers[[as.character(site$site_group)]],
    site_group_colours[[as.character(site$site_group)]],
    site$short_name,
    sprintf("%s wind hours", comma(site$n_wind_hours))
  )
})

houston_steadiness <- wind_site_summary %>%
  filter(site_group != "Dallas-Fort Worth") %>%
  summarise(steadiness = mean(steadiness), .by = season)

season_steadiness <- function(season_name) {
  houston_steadiness$steadiness[houston_steadiness$season == season_name]
}

season_rose_panels <- lapply(levels(wind_hours$season), \(season_name) {
  rose_panel(
    filter(houston_season_roses, season == season_name),
    "HOUSTON, 6 SITES",
    chart_fills[["accent"]],
    season_name,
    sprintf("Steadiness %.2f", season_steadiness(season_name))
  )
})

# North covers the sectors from 330° to 30°, south those from 150° to 210°
houston_compass <- houston_season_roses %>%
  filter(speed_band != "Calm") %>%
  summarise(
    north_pct = sum(pct_of_wind_hours[wind_sector %in% c(330, 0, 30)]),
    south_pct = sum(pct_of_wind_hours[wind_sector %in% c(150, 180, 210)]),
    .by = season
  )

print(houston_compass)

winter_compass <- houston_compass %>%
  filter(season == "Winter")

summer_compass <- houston_compass %>%
  filter(season == "Summer")

stopifnot(
  "Every rose fits inside the shared scale" = rose_peak <= rose_top,
  "Houston's summer wind comes from the south in at least half of all hours, as the subtitle says" = summer_compass$south_pct >= 50,
  "Houston's winter wind comes from the north and from the south in at least a fifth of hours each, as the subtitle says" =
    winter_compass$north_pct >= 20 && winter_compass$south_pct >= 20,
  "Houston's wind is steadiest in summer and least steady in winter" =
    season_steadiness("Summer") == max(houston_steadiness$steadiness[houston_steadiness$season != "All year"]) &&
    season_steadiness("Winter") == min(houston_steadiness$steadiness[houston_steadiness$season != "All year"])
)

calm_ratio_low <- min(calm_share("Houston Ship Channel"), calm_share("Houston other")) / calm_share("Dallas-Fort Worth")

calm_ratio_high <- max(calm_share("Houston Ship Channel"), calm_share("Houston other")) / calm_share("Dallas-Fort Worth")

wind_rose_header <- chart_header(
  sprintf("FIGURE 2C.6  /  WIND  /  %s TO %s", min(study_years), max(study_years)),
  "Wind blows mostly from the south at every site",
  sprintf(
    str_c(
      "Houston sites are calm %.0f to %.0f times as often as DFW's, mostly from midnight to 6 am.\n",
      "Summer wind holds to the south (%.0f%% of hours); winter wind swings between north and south."
    ),
    calm_ratio_low, calm_ratio_high, summer_compass$south_pct
  ),
  key = tribble(
    ~mark,    ~colour,                          ~label,
    "square", rose_band_colours[["0.5 to 1.5"]], "0.5-1.5 m/s",
    "square", rose_band_colours[["1.5 to 3"]],   "1.5-3",
    "square", rose_band_colours[["3 to 5"]],     "3-5",
    "square", rose_band_colours[["5 or more"]],  "5+",
    "square", chart_fills[["band"]],             "Centre: % of hours calm"
  )
)

long_wind_gaps <- wind_gaps %>%
  filter(longest_wind_gap_days > 100) %>%
  inner_join(distinct(wind_hours, site_id, short_name), by = "site_id", relationship = "one-to-one") %>%
  arrange(desc(longest_wind_gap_days))

stopifnot(
  "Three sites have a wind gap of over 100 days, as the footer says" = nrow(long_wind_gaps) == 3
)

wind_rose_footer <- chart_footer(str_c(
  "EPA AQS hourly wind (1e), Uri and Beryl left out. Petals point to where the wind comes from. Calm: under 0.5 m/s.\n",
  "Rings at 10% and 20%, edge ", sprintf("%.0f", rose_peak), "%. Days without wind: ",
  str_c(long_wind_gaps$short_name, " ", long_wind_gaps$longest_wind_gap_days, collapse = ", "), ".\n",
  "Harvard Street has no wind sensor (uses Croquet's). Steadiness: 1 if the wind keeps one direction, 0 if it swings."
))

wind_rose_figure <- chart_compose(wind_rose_header, c(site_rose_panels, season_rose_panels), wind_rose_footer, ncol = 4)

wind_rose_figure_path <- here("figures", "phase2", "2c.06_wind_roses.png")

save_started <- Sys.time()

ggsave(wind_rose_figure_path, wind_rose_figure, width = 6.5, height = 8.4, dpi = 300)

stopifnot(
  "2c.06_wind_roses.png was written (close any viewer of it and rerun this step)" =
    file.mtime(wind_rose_figure_path) >= save_started - 2
)

# Figure 2C.7: when the air is calm, how each measure moves with wind speed, calm against windy hours per site, and SO2
# spikes by wind speed
calm_hour_panel <- ggplot(main_calm_hours, aes(hour_local, pct_calm)) +
  annotate("rect", xmin = -0.5, xmax = 5.5, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
  annotate(
    "text", x = 2.5, y = Inf, label = "MIDNIGHT\nTO 6 AM", vjust = 1.3, lineheight = 0.95,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_ink[["secondary"]]
  ) +
  geom_line(aes(colour = site_group), linewidth = 0.8) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_y_continuous(limits = c(0, NA), labels = \(x) str_c(x, "%"), expand = expansion(mult = c(0, 0.22))) +
  hour_axis +
  labs(title = "01  CALM AIR BY HOUR", subtitle = "Share of hours with calm air", x = NULL, y = NULL) +
  theme_aqs()

speed_panel_data <- main_band_groups %>%
  filter(measure %in% cycle_pollutants) %>%
  mutate(measure = factor(as.character(measure), levels = cycle_pollutants))

# "CALM" is written by the first points: below them for ozone, above them for NO2
speed_calm_labels <- speed_panel_data %>%
  filter(speed_band == "Calm") %>%
  summarise(x = mean(mean_speed_ms), top = max(difference_from_typical_ppb), bottom = min(difference_from_typical_ppb), .by = measure) %>%
  mutate(y = if_else(measure == "NO2", top + 1.7, bottom - 1.7)) %>%
  mutate(label = "CALM")

speed_panel <- ggplot(speed_panel_data, aes(mean_speed_ms, difference_from_typical_ppb, colour = site_group)) +
  geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_line(linewidth = 0.6) +
  geom_point(size = 1.3) +
  geom_text(
    data = speed_calm_labels, aes(x = x, y = y, label = label), inherit.aes = FALSE, hjust = 0.2,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_ink[["secondary"]]
  ) +
  facet_grid(. ~ measure, labeller = as_labeller(toupper)) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(breaks = c(0, 2, 4, 6), labels = \(x) if_else(x == 6, "6 m/s", as.character(x)), expand = expansion(mult = 0.06)) +
  scale_y_continuous(labels = signed_labels) +
  labs(title = "02  WIND SPEED", subtitle = "Above or below a normal hour (ppb)", x = NULL, y = NULL) +
  theme_aqs() +
  facet_strips

calm_site_order <- main_site_calm %>%
  distinct(site_group, site_id, local_site_name) %>%
  mutate(short_name = short_site_name(local_site_name)) %>%
  arrange(site_group, short_name)

# Ozone falls and NO2 rises in calm air at every site (asserted above), so both share one axis: ozone to the left of zero,
# NO2 to the right, and Ox, their sum, as a diamond. A diamond near zero means the ozone lost is mostly found again as NO2
calm_site_rows <- calm_air %>%
  filter(level == "Site") %>%
  mutate(short_name = factor(short_site_name(local_site_name), levels = rev(calm_site_order$short_name))) %>%
  mutate(group_colour = unname(site_group_colours[as.character(site_group)]))

main_calm_rows <- calm_site_rows %>%
  filter(site_set == "Main", measure %in% cycle_pollutants)

main_ox_rows <- calm_site_rows %>%
  filter(site_set == "Main", measure == "Ox")

check_calm_rows <- calm_site_rows %>%
  filter(site_set != "Main", measure %in% cycle_pollutants)

n_calm_sites <- nrow(calm_site_order)

calm_side_labels <- tibble(x = c(-0.6, 0.6), label = c("OZONE LOWER", "NO2 HIGHER"), hjust = c(1, 0))

top_ox_row <- main_ox_rows %>%
  filter(short_name == last(levels(short_name)))

calm_site_panel <- ggplot(main_calm_rows, aes(calm_minus_windy_ppb, short_name)) +
  geom_vline(xintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_point(data = check_calm_rows, colour = chart_ink[["muted"]], shape = "|", size = 2.6) +
  geom_errorbar(aes(xmin = ci_low, xmax = ci_high, colour = group_colour), orientation = "y", width = 0, linewidth = 0.8) +
  geom_point(aes(colour = group_colour), size = 1.6) +
  geom_point(data = main_ox_rows, colour = chart_fills[["accent"]], shape = 18, size = 2.4) +
  geom_text(
    data = top_ox_row, aes(label = "OX"), hjust = 1.7, vjust = 0.4,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_fills[["accent"]]
  ) +
  geom_text(
    data = calm_side_labels, aes(x = x, y = n_calm_sites + 0.85, label = label, hjust = hjust), inherit.aes = FALSE,
    family = chart_fonts[["mono"]], size = so2_label_size, colour = chart_ink[["secondary"]]
  ) +
  scale_colour_identity() +
  scale_x_continuous(breaks = seq(-10, 10, 2), labels = signed_labels) +
  scale_y_discrete(expand = expansion(add = c(0.6, 1.2))) +
  coord_cartesian(clip = "off") +
  labs(title = "03  CALM AGAINST WINDY", subtitle = "Calm hours minus windy hours (ppb)", x = NULL, y = NULL) +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.3)
  )

so2_band_labels <- c("Calm" = "Calm", "0.5 to 1.5" = "0.5-1.5", "1.5 to 3" = "1.5-3", "3 to 5" = "3-5", "5 or more" = "5+")

so2_period_labels <- c("Day, 9 am to 6 pm" = "DAY, 9 AM TO 6 PM", "Night and morning" = "NIGHT, 6 PM TO 9 AM")

so2_tiles <- main_so2_bands %>%
  mutate(period = factor(as.character(period), levels = names(period_labels))) %>%
  mutate(short_name = factor(short_name, levels = rev(site_levels))) %>%
  mutate(label = if_else(spike_rate_per_1000 >= 10, sprintf("%.0f", spike_rate_per_1000), sprintf("%.1f", spike_rate_per_1000))) %>%
  mutate(label = if_else(n_spike_hours == 0, "0", label))

so2_wind_panel <- ggplot(so2_tiles, aes(speed_band, short_name, fill = spike_rate_per_1000)) +
  geom_tile(colour = "white", linewidth = 0.3) +
  geom_text(
    aes(label = label, colour = spike_rate_per_1000 > 0.6 * max(spike_rate_per_1000)),
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 1.2) / .pt
  ) +
  facet_wrap(~period, ncol = 1, labeller = as_labeller(so2_period_labels)) +
  scale_fill_gradient(low = "white", high = chart_fills[["accent"]], guide = "none") +
  scale_colour_manual(values = c(`TRUE` = "white", `FALSE` = chart_ink[["secondary"]]), guide = "none") +
  scale_x_discrete(labels = so2_band_labels) +
  labs(title = "04  SO2 SPIKES BY WIND SPEED", subtitle = "Spike hours per 1,000, by wind (m/s)", x = NULL, y = NULL) +
  theme_aqs() +
  facet_strips +
  so2_site_axis +
  theme(
    axis.text.x = element_text(size = chart_sizes[["axis"]] - 0.8),
    panel.spacing.y = unit(6, "pt"),
    strip.text.x = element_text(margin = margin(b = 3))
  )

no2_site_effects <- main_site_calm %>%
  filter(measure == "NO2")

ozone_site_effects <- main_site_calm %>%
  filter(measure == "Ozone")

ox_offset_low <- min(group_ox_offset$share_of_ozone_loss_in_no2)

calm_header <- chart_header(
  sprintf("FIGURE 2C.7  /  CALM AIR  /  %s TO %s", min(study_years), max(study_years)),
  "Calm air lifts NO2 and cuts ozone at every site",
  sprintf(
    str_c(
      "Calm hours carry %.1f to %.1f ppb more NO2 and %.1f to %.1f ppb less ozone than windy hours.\n",
      "At least %.0f%% of the ozone lost shows up as NO2 in every group, consistent with NO using up ozone."
    ),
    min(no2_site_effects$calm_minus_windy_ppb), max(no2_site_effects$calm_minus_windy_ppb),
    abs(max(ozone_site_effects$calm_minus_windy_ppb)), abs(min(ozone_site_effects$calm_minus_windy_ppb)), 100 * ox_offset_low
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "dot", site_group_colours[["Houston other"]],        "Houston other",
    "dot", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",
    "dot", chart_fills[["accent"]],                      "Ox (ozone + NO2)",
    "bar", chart_ink[["muted"]],                         "Checks"
  )
)

calm_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d, 1e), ordinary hours with wind. Calm: wind under 0.5 m/s. Lines: mean of each group's sites.\n",
  "02, 03: compared with hours at the same site, hour of day and month, so time of day and season cancel out.\n",
  "03: bars are 95% ranges (", bootstrap_block_days, "-day blocks); grey ticks are checks. 04: a spike is an hour at ",
  so2_spike_ppb, " ppb or more."
))

# Panel 03's site names would push panel 01 to the right to line up with it, so panel 03 is laid out on its own
calm_figure <- chart_compose(calm_header, list(calm_hour_panel, speed_panel, free(calm_site_panel), so2_wind_panel), calm_footer)

calm_figure_path <- here("figures", "phase2", "2c.07_calm_air.png")

save_started <- Sys.time()

ggsave(calm_figure_path, calm_figure, width = 6.5, height = 7, dpi = 300)

stopifnot(
  "2c.07_calm_air.png was written (close any viewer of it and rerun this step)" = file.mtime(calm_figure_path) >= save_started - 2
)

# CSV records: wind per site and season, the wind roses, calm share by hour, calm against windy hours, each measure by
# wind speed, and SO2 spikes by wind speed
wind_site_record <- wind_site_summary %>%
  left_join(site_names, by = "site_id", relationship = "many-to-one") %>%
  select(
    site_group, site_id, local_site_name, season, n_wind_hours, pct_calm, pct_calm_old_sensor, pct_calm_new_sensor, sonic_wind_from,
    mean_speed_ms, median_speed_ms, resultant_from_deg, steadiness, prevailing_sector, pct_prevailing_sector
  ) %>%
  mutate(across(where(is.double), \(x) round(x, 2)))

wind_rose_record <- bind_rows(
  mutate(site_roses, n_sites = 1L),
  houston_roses
) %>%
  left_join(site_names, by = "site_id", relationship = "many-to-one") %>%
  select(level, season, site_group, site_id, local_site_name, n_sites, wind_sector, speed_band, n_hours, pct_of_wind_hours) %>%
  mutate(pct_of_wind_hours = round(pct_of_wind_hours, 3))

speed_band_record <- speed_band_means %>%
  mutate(n_sites = coalesce(n_sites, 1L)) %>%
  mutate(min_site_hours = coalesce(min_site_hours, n_hours)) %>%
  mutate(across(c(mean_speed_ms, mean_ppb, difference_from_typical_ppb), \(x) round(x, 2)))

wind_records <- list(
  case_study_wind_sites = wind_site_record,
  case_study_wind_roses = wind_rose_record,
  case_study_calm_by_hour = mutate(calm_by_hour, across(c(low_site_pct, high_site_pct, pct_calm), \(x) round(x, 2))),
  case_study_calm_air = calm_air %>%
    mutate(across(c(pct_calm, mean_calm_ppb, mean_windy_ppb, calm_minus_windy_ppb, ci_low, ci_high), \(x) round(x, 2))) %>%
    mutate(plain_ratio = round(plain_ratio, 3)),
  case_study_wind_speed_bands = speed_band_record,
  case_study_so2_wind_speed = so2_speed_bands %>%
    rename(local_site_name = short_name) %>%
    mutate(mean_speed_ms = round(mean_speed_ms, 2)) %>%
    mutate(spike_rate_per_1000 = round(spike_rate_per_1000, 2))
)

stopifnot(
  "Wind sites: 8 sites by 5 seasons" = nrow(wind_site_record) == 8 * 5,
  "Wind roses: 8 sites and the Houston average, 5 seasons each, 49 cells per rose" = nrow(wind_rose_record) == (8 + 1) * 5 * 49,
  "Calm by hour: 2 sets, 3 groups, 24 hours" = nrow(calm_by_hour) == 2 * 3 * 24,
  "Calm air: one row per set, measure and site or group, with no duplicates" =
    !anyDuplicated(calm_air[c("site_set", "measure", "level", "site_group", "site_id")]),
  "Speed bands: 5 bands for every set, measure and site or group" =
    all(count(speed_band_record, site_set, measure, level, site_group, site_id)$n == length(wind_speed_bands)),
  "SO2 by wind speed: 5 bands for every set, site and period" =
    all(count(so2_speed_bands, site_set, site_id, period)$n == length(wind_speed_bands))
)

save_records(wind_records, records_dir)

wind_dictionary <- tribble(
  ~table,                        ~column,                       ~description,
  "case_study_wind_sites",       "site_group",                  "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "case_study_wind_sites",       "site_id",                     "AQS site ID of a site with its own wind sensor (Harvard Street, which borrows Croquet's, is left out)",
  "case_study_wind_sites",       "local_site_name",             "Site name given by the reporting agency",
  "case_study_wind_sites",       "season",                      "All year, or a meteorological season (winter is December to February)",
  "case_study_wind_sites",       "n_wind_hours",                "Hours with a wind reading outside Uri and Beryl, the wind-spike hour left out",
  "case_study_wind_sites",       "pct_calm",                    "Share of wind hours that are calm (below 0.5 m/s)",
  "case_study_wind_sites",       "pct_calm_old_sensor",         "Calm share on the older wind sensor (all hours at sites that never switched)",
  "case_study_wind_sites",       "pct_calm_new_sensor",         "Calm share on the sonic sensor; NA at sites that never switched",
  "case_study_wind_sites",       "sonic_wind_from",             "First day on the sonic wind sensor; NA at sites that never switched",
  "case_study_wind_sites",       "mean_speed_ms",               "Mean wind speed, m/s",
  "case_study_wind_sites",       "median_speed_ms",             "Median wind speed, m/s",
  "case_study_wind_sites",       "resultant_from_deg",          "Direction of the mean wind vector over non-calm hours, degrees the wind comes from, clockwise from north",
  "case_study_wind_sites",       "steadiness",                  "Length of the mean wind vector over the mean speed, non-calm hours: 1 one direction, 0 evenly spread",
  "case_study_wind_sites",       "prevailing_sector",           "30-degree sector the wind comes from most often (centre angle), non-calm hours",
  "case_study_wind_sites",       "pct_prevailing_sector",       "Share of non-calm hours from the prevailing sector",
  "case_study_wind_roses",       "level",                       "Site, or Houston, 6 sites (the six Houston sites with their own wind, each weighted equally)",
  "case_study_wind_roses",       "season",                      "All year, or a meteorological season (winter is December to February)",
  "case_study_wind_roses",       "site_group",                  "Case-study group; NA for the Houston average",
  "case_study_wind_roses",       "site_id",                     "AQS site ID; NA for the Houston average",
  "case_study_wind_roses",       "local_site_name",             "Site name given by the reporting agency; NA for the Houston average",
  "case_study_wind_roses",       "n_sites",                     "Sites behind the row",
  "case_study_wind_roses",       "wind_sector",                 "30-degree sector the wind comes from (centre angle, 0 is north); NA for calm hours",
  "case_study_wind_roses",       "speed_band",                  "Calm (below 0.5 m/s), 0.5 to 1.5, 1.5 to 3, 3 to 5 or 5 or more m/s",
  "case_study_wind_roses",       "n_hours",                     "Wind hours in the sector and band (summed over sites for the Houston average)",
  "case_study_wind_roses",       "pct_of_wind_hours",           "Share of all wind hours, calm included, so each rose adds up to 100 (site mean for the Houston average)",
  "case_study_calm_by_hour",     "site_set",                    "Main, or Without new wind sensors (hours on the sonic sensors at the five sites that switched left out)",
  "case_study_calm_by_hour",     "site_group",                  "Case-study group",
  "case_study_calm_by_hour",     "hour_local",                  "Hour of day, local standard time (UTC-6)",
  "case_study_calm_by_hour",     "n_sites",                     "Sites with their own wind sensor in the group",
  "case_study_calm_by_hour",     "min_wind_hours",              "Wind hours at the group's thinnest site at that hour",
  "case_study_calm_by_hour",     "low_site_pct",                "Lowest site calm share at that hour",
  "case_study_calm_by_hour",     "high_site_pct",               "Highest site calm share at that hour",
  "case_study_calm_by_hour",     "pct_calm",                    "Mean of the sites' calm shares at that hour, each site weighted equally",
  "case_study_calm_air",         "site_set",                    "Main or a check: transition band, method change, Deer Park #2 after its move, without new wind sensors",
  "case_study_calm_air",         "measure",                     "Ozone, NO2 or Ox (ozone + NO2 on hours with both)",
  "case_study_calm_air",         "level",                       "Site or Group",
  "case_study_calm_air",         "site_group",                  "Case-study group under that site set",
  "case_study_calm_air",         "site_id",                     "AQS site ID; NA for group rows",
  "case_study_calm_air",         "local_site_name",             "Site name given by the reporting agency; NA for group rows",
  "case_study_calm_air",         "n_hours",                     "Ordinary hours with wind (summed over sites for groups)",
  "case_study_calm_air",         "n_calm_hours",                "Calm hours among them",
  "case_study_calm_air",         "n_calm_days",                 "Days with at least one compared calm hour",
  "case_study_calm_air",         "pct_calm",                    "Calm hours as a share of hours (mean of sites for groups)",
  "case_study_calm_air",         "mean_calm_ppb",               "Plain mean over calm hours, ppb (mean of sites for groups)",
  "case_study_calm_air",         "mean_windy_ppb",              "Plain mean over windy hours, ppb (mean of sites for groups)",
  "case_study_calm_air",         "plain_ratio",                 "mean_calm_ppb over mean_windy_ppb, not matched on time of day",
  "case_study_calm_air",         "calm_minus_windy_ppb",        "Each calm hour minus the windy mean at the same site, hour of day and month, averaged by day, then over days, ppb",
  "case_study_calm_air",         "ci_low",                      "Lower end of the 95% range from the 14-day block bootstrap; main set only",
  "case_study_calm_air",         "ci_high",                     "Upper end of the 95% range from the 14-day block bootstrap; main set only",
  "case_study_wind_speed_bands", "site_set",                    "Main or a check: transition band, method change, Deer Park #2 after its move, without new wind sensors",
  "case_study_wind_speed_bands", "measure",                     "Ozone, NO2 or Ox (ozone + NO2 on hours with both)",
  "case_study_wind_speed_bands", "level",                       "Site or Group",
  "case_study_wind_speed_bands", "site_group",                  "Case-study group under that site set",
  "case_study_wind_speed_bands", "site_id",                     "AQS site ID; NA for group rows",
  "case_study_wind_speed_bands", "local_site_name",             "Site name given by the reporting agency; NA for group rows",
  "case_study_wind_speed_bands", "speed_band",                  "Calm (below 0.5 m/s), 0.5 to 1.5, 1.5 to 3, 3 to 5 or 5 or more m/s",
  "case_study_wind_speed_bands", "n_sites",                     "Sites behind the row",
  "case_study_wind_speed_bands", "n_hours",                     "Ordinary hours with wind in the band (summed over sites for groups)",
  "case_study_wind_speed_bands", "min_site_hours",              "Hours at the thinnest site in the band",
  "case_study_wind_speed_bands", "mean_speed_ms",               "Mean wind speed in the band, m/s (mean of sites for groups)",
  "case_study_wind_speed_bands", "mean_ppb",                    "Plain mean in the band, ppb (mean of sites for groups)",
  "case_study_wind_speed_bands", "difference_from_typical_ppb", "Mean of each hour minus the site's mean at the same hour of day and month, ppb (mean of sites for groups)",
  "case_study_so2_wind_speed",   "site_set",                    "Main, Without Deer Park #2 after its move, or Without new wind sensors",
  "case_study_so2_wind_speed",   "site_group",                  "Case-study group: Houston Ship Channel or Houston other",
  "case_study_so2_wind_speed",   "site_id",                     "AQS site ID: state-county-site",
  "case_study_so2_wind_speed",   "local_site_name",             "Site name, shortened",
  "case_study_so2_wind_speed",   "period",                      "All hours, Day (9 am to 6 pm) or Night and morning, local standard time",
  "case_study_so2_wind_speed",   "speed_band",                  "Calm (below 0.5 m/s), 0.5 to 1.5, 1.5 to 3, 3 to 5 or 5 or more m/s",
  "case_study_so2_wind_speed",   "n_hours",                     "Ordinary SO2 hours with wind in the band and period",
  "case_study_so2_wind_speed",   "n_spike_hours",               "Hours at or above 5 ppb",
  "case_study_so2_wind_speed",   "mean_speed_ms",               "Mean wind speed in the band, m/s; NA when the band has no hours",
  "case_study_so2_wind_speed",   "spike_rate_per_1000",         "Spike hours per 1,000 hours in the band and period"
)

wind_dictionary <- document_tables(wind_records, wind_dictionary)

replace_own_rows(wind_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(wind_sets, wind_season_hours, calm_measure_hours, calm_sets, calm_differences, so2_wind_hours, so2_wind_sets)



# 6. POLLUTION ROSES AND SOURCE DIRECTIONS ----
# Which wind directions bring NO2, ozone and SO2 spikes to each site, and whether wind direction explains the Ship
# Channel Ox gap that section 3 left. Direction hours only: calm hours and the wind-spike hour have no reliable direction
channel_features <- read_json(channel_path)$features

feature_sections <- vapply(channel_features, \(feature) feature$properties$channelareaidpk, character(1))

channel_vertices <- bind_rows(lapply(channel_features[feature_sections %in% land_cut_sections], \(feature) {
  ring <- feature$geometry$coordinates[[1]]
  tibble(
    longitude = vapply(ring, \(point) point[[1]], numeric(1)),
    latitude = vapply(ring, \(point) point[[2]], numeric(1))
  )
}))

stopifnot(
  "All 12 land-cut sections are in the channel file" = all(land_cut_sections %in% feature_sections),
  "The land-cut channel has vertices" = nrow(channel_vertices) > 100
)

# A 30-degree sector is named by its centre, so sector 0 runs from 345° up to 15° (as in 1e)
sector_of <- function(degrees) {
  30 * (floor((degrees + 15) / 30) %% 12)
}

# Bearing from each Houston site to every vertex of the channel: the directions the wind must come from to carry
# channel air to the site
houston_hourly_sites <- site_roles %>%
  filter(!is.na(km_to_channel)) %>%
  inner_join(select(harris_groups, site_id, latitude, longitude), by = "site_id", relationship = "one-to-one")

channel_sight_lines <- houston_hourly_sites %>%
  select(site_id, site_latitude = latitude, site_longitude = longitude) %>%
  cross_join(channel_vertices) %>%
  mutate(east_km = (longitude - site_longitude) * km_per_lon_degree_houston) %>%
  mutate(north_km = (latitude - site_latitude) * km_per_lat_degree) %>%
  mutate(bearing_deg = (atan2(east_km, north_km) * 180 / pi) %% 360) %>%
  mutate(vertex_km = sqrt(east_km^2 + north_km^2)) %>%
  mutate(wind_sector = sector_of(bearing_deg))

channel_bearings <- channel_sight_lines %>%
  summarise(
    nearest_bearing_deg = bearing_deg[which.min(vertex_km)],
    channel_sectors = str_c(sort(unique(wind_sector)), collapse = "; "),
    n_channel_sectors = n_distinct(wind_sector),
    .by = site_id
  ) %>%
  inner_join(select(houston_hourly_sites, site_group, site_id, km_to_channel), by = "site_id", relationship = "one-to-one")

channel_sectors <- channel_sight_lines %>%
  distinct(site_id, wind_sector) %>%
  mutate(in_channel_direction = TRUE)

print(channel_bearings)

stopifnot(
  "Every Houston hourly site has a bearing to the channel" = nrow(channel_bearings) == nrow(houston_hourly_sites),
  "The 1c distance matches the nearest vertex within 1 km" =
    all(abs(channel_sight_lines %>% summarise(d = min(vertex_km), .by = site_id) %>%
      inner_join(select(site_roles, site_id, km_to_channel), by = "site_id") %>%
      mutate(gap = d - km_to_channel) %>% pull(gap)) < 1),
  "From Croquet and Bayland Park the channel lies to the east-northeast" =
    all(channel_bearings$nearest_bearing_deg[channel_bearings$site_group == "Houston other" & !channel_bearings$site_id %in% transition_sites] < 90)
)

compass_name <- function(wind_sector) {
  compass_names[wind_sector / 30 + 1]
}

# NO2 and ozone by direction against a normal hour: the site's mean at the same hour of day and month over its direction
# hours. A ratio above 1 means more than usual comes with wind from that sector
rose_hours <- hourly %>%
  filter(is_ordinary_hour, is_direction_hour, pollutant %in% cycle_pollutants) %>%
  mutate(measure = factor(as.character(pollutant), levels = cycle_pollutants)) %>%
  mutate(month = month(date_local)) %>%
  select(
    measure, site_group, site_id, datetime_utc, hour_local, month, wind_sector, in_transition_band, is_post_method_change,
    is_post_relocation, is_sonic_wind, value_ppb
  )

rose_sets <- wind_site_sets(rose_hours)

unchanged_rose_sets <- rose_sets %>%
  count(site_set, measure) %>%
  mutate(is_unchanged = site_set != "Main" & n == n[site_set == "Main"], .by = measure) %>%
  filter(is_unchanged)

rose_sets <- rose_sets %>%
  anti_join(unchanged_rose_sets, by = c("site_set", "measure"))

rose_typical <- rose_sets %>%
  summarise(typical_ppb = mean(value_ppb), .by = c(site_set, measure, site_id, hour_local, month))

pollution_roses <- rose_sets %>%
  left_join(rose_typical, by = c("site_set", "measure", "site_id", "hour_local", "month"), relationship = "many-to-one") %>%
  summarise(
    n_hours = n(),
    mean_ppb = mean(value_ppb),
    typical_ppb = mean(typical_ppb),
    .by = c(site_set, measure, site_group, site_id, wind_sector)
  ) %>%
  complete(nesting(site_set, measure, site_group, site_id), wind_sector = seq(0, 330, 30), fill = list(n_hours = 0L)) %>%
  mutate(ratio_to_typical = mean_ppb / typical_ppb) %>%
  mutate(difference_from_typical_ppb = mean_ppb - typical_ppb) %>%
  mutate(pct_of_hours = 100 * n_hours / sum(n_hours), .by = c(site_set, measure, site_id)) %>%
  mutate(is_thin_sector = n_hours < min_sector_hours) %>%
  left_join(channel_sectors, by = c("site_id", "wind_sector"), relationship = "many-to-one") %>%
  mutate(in_channel_direction = coalesce(in_channel_direction, FALSE)) %>%
  arrange(site_set, measure, site_group, site_id, wind_sector)

main_roses <- pollution_roses %>%
  filter(site_set == "Main")

no2_peaks <- main_roses %>%
  filter(measure == "NO2", !is_thin_sector) %>%
  slice_max(ratio_to_typical, n = 1, by = site_id) %>%
  left_join(site_names, by = "site_id", relationship = "many-to-one")

print(select(no2_peaks, site_group, local_site_name, wind_sector, ratio_to_typical, difference_from_typical_ppb))

houston_no2_peaks <- no2_peaks %>%
  filter(site_group != "Dallas-Fort Worth")

check_no2_peaks <- pollution_roses %>%
  filter(site_set != "Main", measure == "NO2", site_group != "Dallas-Fort Worth", !is_thin_sector) %>%
  slice_max(ratio_to_typical, n = 1, by = c(site_set, site_id))

stopifnot(
  "Every main site and sector has at least 200 direction hours" = !any(main_roses$is_thin_sector),
  "Shares of hours add up to 100 for every site" =
    all(abs(summarise(pollution_roses, s = sum(pct_of_hours), .by = c(site_set, measure, site_id))$s - 100) < 1e-9),
  "At every Houston site NO2 runs highest with wind from 60° or 90°, as the subtitle says" = all(houston_no2_peaks$wind_sector %in% c(60, 90)),
  "Every check keeps the Houston NO2 peak in east wind (45° to 135°)" = all(check_no2_peaks$wind_sector %in% east_sectors)
)

# SO2 spike hours by direction: the share of a site's spikes from each sector beside the share of all its hours from
# that sector. A sector holding far more spikes than hours points to a source that way
so2_direction_hours <- hourly %>%
  filter(pollutant == "SO2", is_ordinary_hour, is_direction_hour) %>%
  mutate(is_spike = value_ppb >= so2_spike_ppb) %>%
  mutate(period = if_else(hour_local %in% daytime_hours, "Day, 9 am to 6 pm", "Night and morning")) %>%
  mutate(short_name = short_site_name(local_site_name)) %>%
  select(
    site_group, site_id, short_name, datetime_utc, period, wind_sector, in_transition_band, is_post_method_change,
    is_post_relocation, is_sonic_wind, is_spike
  )

so2_direction_sets <- wind_site_sets(so2_direction_hours)

unchanged_so2_direction_sets <- so2_direction_sets %>%
  count(site_set) %>%
  filter(site_set != "Main", n == n[site_set == "Main"])

so2_direction_sets <- so2_direction_sets %>%
  anti_join(unchanged_so2_direction_sets, by = "site_set")

so2_directions <- bind_rows(
  mutate(so2_direction_sets, period = "All hours"),
  filter(so2_direction_sets, period == "Day, 9 am to 6 pm")
) %>%
  summarise(n_hours = n(), n_spike_hours = sum(is_spike), .by = c(site_set, site_group, site_id, short_name, period, wind_sector)) %>%
  complete(nesting(site_set, site_group, site_id, short_name, period), wind_sector = seq(0, 330, 30), fill = list(n_hours = 0L, n_spike_hours = 0L)) %>%
  mutate(spike_rate_per_1000 = 1000 * n_spike_hours / n_hours) %>%
  mutate(pct_of_spike_hours = 100 * n_spike_hours / sum(n_spike_hours), .by = c(site_set, site_id, period)) %>%
  mutate(pct_of_hours = 100 * n_hours / sum(n_hours), .by = c(site_set, site_id, period)) %>%
  left_join(channel_sectors, by = c("site_id", "wind_sector"), relationship = "many-to-one") %>%
  mutate(in_channel_direction = coalesce(in_channel_direction, FALSE)) %>%
  mutate(period = factor(period, levels = c("All hours", "Day, 9 am to 6 pm"))) %>%
  arrange(site_set, site_group, short_name, period, wind_sector)

# Each site's share of spike hours from the channel side and from the southwest, against the share of its hours from there.
# 95% ranges resample whole spike episodes, as in section 4
main_so2_spikes <- so2_direction_sets %>%
  filter(site_set == "Main", is_spike) %>%
  left_join(channel_sectors, by = c("site_id", "wind_sector"), relationship = "many-to-one") %>%
  mutate(from_channel = coalesce(in_channel_direction, FALSE)) %>%
  mutate(from_southwest = wind_sector %in% southwest_sectors) %>%
  arrange(site_id, datetime_utc) %>%
  mutate(episode = cumsum(is.na(lag(datetime_utc)) | as.numeric(difftime(datetime_utc, lag(datetime_utc), units = "hours")) > 1), .by = site_id)

set.seed(bootstrap_seed)

so2_direction_shares <- main_so2_spikes %>%
  summarise(
    n_spike_hours = n(),
    n_episodes = n_distinct(episode),
    pct_spikes_from_channel = 100 * mean(from_channel),
    channel_range = list(100 * episode_mean_range(as.numeric(from_channel), episode)),
    pct_spikes_from_southwest = 100 * mean(from_southwest),
    southwest_range = list(100 * episode_mean_range(as.numeric(from_southwest), episode)),
    .by = c(site_group, site_id, short_name)
  ) %>%
  mutate(channel_ci_low = vapply(channel_range, \(r) r[1], numeric(1))) %>%
  mutate(channel_ci_high = vapply(channel_range, \(r) r[2], numeric(1))) %>%
  mutate(southwest_ci_low = vapply(southwest_range, \(r) r[1], numeric(1))) %>%
  mutate(southwest_ci_high = vapply(southwest_range, \(r) r[2], numeric(1))) %>%
  select(-channel_range, -southwest_range) %>%
  inner_join(
    so2_directions %>%
      filter(site_set == "Main", period == "All hours") %>%
      summarise(
        pct_hours_from_channel = sum(pct_of_hours[in_channel_direction]),
        pct_hours_from_southwest = sum(pct_of_hours[wind_sector %in% southwest_sectors]),
        .by = site_id
      ),
    by = "site_id", relationship = "one-to-one"
  )

print(so2_direction_shares, width = Inf)

so2_share <- function(site_name, column) {
  so2_direction_shares[[column]][so2_direction_shares$short_name == site_name]
}

croquet_day_rates <- so2_directions %>%
  filter(site_set == "Main", short_name == "Croquet", period == "Day, 9 am to 6 pm") %>%
  summarise(
    southwest_rate = 1000 * sum(n_spike_hours[wind_sector %in% southwest_sectors]) / sum(n_hours[wind_sector %in% southwest_sectors]),
    other_rate = 1000 * sum(n_spike_hours[!wind_sector %in% southwest_sectors]) / sum(n_hours[!wind_sector %in% southwest_sectors])
  )

check_croquet_shares <- so2_direction_sets %>%
  filter(site_set != "Main", is_spike, short_name == "Croquet") %>%
  summarise(pct_from_southwest = 100 * mean(wind_sector %in% southwest_sectors), .by = site_set)

print(croquet_day_rates)

stopifnot(
  "Croquet's spikes come from the southwest in over half of spike hours, range above half, as the subtitle says" =
    so2_share("Croquet", "southwest_ci_low") > 50,
  "Southwest wind holds under a quarter of Croquet's hours" = so2_share("Croquet", "pct_hours_from_southwest") < 25,
  "Croquet's spikes almost never come from the channel side" = so2_share("Croquet", "pct_spikes_from_channel") < 5,
  "Park Place's spikes come from the channel side in over half of spike hours, as the subtitle says" =
    so2_share("Park Place", "channel_ci_low") > 50,
  "Park Place's spikes come from the channel side at least twice as often as its hours do" =
    so2_share("Park Place", "pct_spikes_from_channel") >= 2 * so2_share("Park Place", "pct_hours_from_channel"),
  "Every check keeps Croquet's southwest share above half" = all(check_croquet_shares$pct_from_southwest > 50)
)

# The shared Houston wind for the Ox gap: one direction per hour from the vector mean of the Houston sites' own sensors,
# and again from their old sensors only for the sensor check
houston_wind_hours <- hourly_weather %>%
  filter(region == "Houston", wind_source_site == site_id, !is.na(wind_sector), !is_wind_spike, is.na(event_name)) %>%
  select(site_id, datetime_utc, wind_u_ms, wind_v_ms, is_sonic_wind)

shared_wind <- bind_rows(
  houston_wind_hours %>%
    mutate(wind_set = "All sensors"),
  houston_wind_hours %>%
    filter(!is_sonic_wind) %>%
    mutate(wind_set = "Old sensors")
) %>%
  summarise(n_wind_sites = n(), mean_u = mean(wind_u_ms), mean_v = mean(wind_v_ms), .by = c(wind_set, datetime_utc)) %>%
  mutate(shared_speed_ms = sqrt(mean_u^2 + mean_v^2)) %>%
  mutate(shared_from_deg = (atan2(-mean_u, -mean_v) * 180 / pi) %% 360) %>%
  filter(n_wind_sites >= min_wind_sites, shared_speed_ms >= 0.5) %>%
  mutate(wind_sector = sector_of(shared_from_deg)) %>%
  left_join(quadrant_sectors, by = "wind_sector", relationship = "many-to-one") %>%
  select(wind_set, datetime_utc, n_wind_sites, shared_speed_ms, wind_sector, quadrant)

print(count(shared_wind, wind_set, quadrant))

stopifnot(
  "Six Houston sites have their own wind sensor" = n_distinct(houston_wind_hours$site_id) == 6,
  "Every shared-wind hour has a sector and quadrant" = !anyNA(shared_wind$quadrant)
)

# Ozone, NO2 and Ox gaps per hour, as in section 3, joined to the shared wind
wind_ox_gaps <- ox_hours %>%
  filter(site_group != "Dallas-Fort Worth") %>%
  hourly_site_sets() %>%
  pivot_longer(c(ozone_ppb, no2_ppb, ox_ppb), names_to = "measure", values_to = "value_ppb") %>%
  mutate(measure = factor(measure, levels = c("ozone_ppb", "no2_ppb", "ox_ppb"), labels = ox_measures)) %>%
  summarise(group_ppb = mean(value_ppb), .by = c(site_set, measure, site_group, datetime_utc, date_local, season)) %>%
  mutate(site_group = if_else(site_group == "Houston Ship Channel", "ship_channel_ppb", "houston_other_ppb")) %>%
  pivot_wider(names_from = site_group, values_from = group_ppb) %>%
  filter(!is.na(ship_channel_ppb), !is.na(houston_other_ppb)) %>%
  mutate(gap_ppb = ship_channel_ppb - houston_other_ppb) %>%
  select(site_set, measure, datetime_utc, date_local, season, gap_ppb)

ox_wind_gaps <- bind_rows(
  wind_ox_gaps %>%
    inner_join(filter(shared_wind, wind_set == "All sensors"), by = "datetime_utc", relationship = "many-to-one"),
  wind_ox_gaps %>%
    filter(site_set == "Main") %>%
    inner_join(filter(shared_wind, wind_set == "Old sensors"), by = "datetime_utc", relationship = "many-to-one") %>%
    mutate(site_set = sensor_check_level)
) %>%
  mutate(site_set = factor(as.character(site_set), levels = c(hourly_check_levels, sensor_check_level)))

# Wind from the channel toward Houston other: the sectors in which the channel lies from the Houston other ozone sites in
# each set (Bayland Park, and Harvard Street where it is kept)
houston_other_ox_sites <- ox_hours %>%
  filter(site_group == "Houston other") %>%
  distinct(site_id, in_transition_band)

channel_wind_sectors <- tibble(site_set = factor(c(hourly_check_levels, sensor_check_level), levels = c(hourly_check_levels, sensor_check_level))) %>%
  cross_join(houston_other_ox_sites) %>%
  filter(!(site_set == "Without the transition band" & in_transition_band)) %>%
  inner_join(channel_sectors, by = "site_id", relationship = "many-to-many") %>%
  distinct(site_set, wind_sector) %>%
  mutate(is_channel_wind = TRUE)

ox_wind_gaps <- ox_wind_gaps %>%
  left_join(channel_wind_sectors, by = c("site_set", "wind_sector"), relationship = "many-to-one") %>%
  mutate(is_channel_wind = coalesce(is_channel_wind, FALSE))

print(arrange(channel_wind_sectors, site_set, wind_sector), n = Inf)

# Each day's mean gap within a direction, then the mean over days, as in section 3. Directions are the 12 sectors over the
# year, the four quadrants by season, and wind from the channel against all other wind
direction_day_gaps <- bind_rows(
  ox_wind_gaps %>%
    mutate(direction_type = "Sector", direction = as.character(wind_sector), season = "All year"),
  ox_wind_gaps %>%
    mutate(direction_type = "Quadrant", direction = quadrant, season = "All year"),
  ox_wind_gaps %>%
    mutate(direction_type = "Quadrant", direction = quadrant, season = as.character(season)),
  ox_wind_gaps %>%
    mutate(direction_type = "Channel or other", direction = if_else(is_channel_wind, "From the channel", "Other"), season = "All year"),
  ox_wind_gaps %>%
    mutate(direction_type = "Channel or other", direction = if_else(is_channel_wind, "From the channel", "Other"), season = as.character(season))
) %>%
  summarise(n_hours = n(), gap_ppb = mean(gap_ppb), .by = c(site_set, measure, direction_type, direction, season, date_local)) %>%
  arrange(site_set, measure, direction_type, direction, season, date_local)

set.seed(bootstrap_seed)

ox_direction_ranges <- direction_day_gaps %>%
  filter(site_set %in% c("Main", "Without the transition band"), measure == "Ox", direction_type != "Sector") %>%
  summarise(range = list(block_mean_range(gap_ppb)), .by = c(site_set, measure, direction_type, direction, season)) %>%
  mutate(ox_ci_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(ox_ci_high = vapply(range, \(r) r[2], numeric(1))) %>%
  select(-range, -measure)

ox_by_wind <- direction_day_gaps %>%
  summarise(n_hours = sum(n_hours), n_days = n(), gap_ppb = mean(gap_ppb), .by = c(site_set, measure, direction_type, direction, season)) %>%
  mutate(measure = str_to_lower(measure)) %>%
  pivot_wider(names_from = measure, values_from = gap_ppb, names_glue = "{measure}_gap_ppb") %>%
  left_join(ox_direction_ranges, by = c("site_set", "direction_type", "direction", "season"), relationship = "one-to-one") %>%
  mutate(share_of_ozone_gap_closed = 1 - ox_gap_ppb / ozone_gap_ppb) %>%
  mutate(season = factor(season, levels = season_levels)) %>%
  arrange(site_set, direction_type, season, direction)

ox_by_wind %>%
  filter(site_set %in% c("Main", "Without the transition band"), direction_type == "Quadrant") %>%
  select(site_set, season, direction, n_hours, ozone_gap_ppb, ox_gap_ppb, ox_ci_low, ox_ci_high) %>%
  mutate(across(where(is.double), \(x) round(x, 2))) %>%
  print(n = Inf)

channel_or_other <- ox_by_wind %>%
  filter(direction_type == "Channel or other")

channel_or_other %>%
  select(site_set, season, direction, n_hours, ozone_gap_ppb, ox_gap_ppb, ox_ci_low, ox_ci_high, share_of_ozone_gap_closed) %>%
  mutate(across(where(is.double), \(x) round(x, 2))) %>%
  print(n = Inf)

channel_year <- channel_or_other %>%
  filter(season == "All year") %>%
  select(site_set, direction, ox_gap_ppb, ox_ci_low, ox_ci_high) %>%
  pivot_wider(names_from = direction, values_from = c(ox_gap_ppb, ox_ci_low, ox_ci_high))

channel_gap <- function(set, column) {
  channel_year[[column]][channel_year$site_set == set]
}

south_without_harvard <- ox_by_wind %>%
  filter(site_set == "Without the transition band", direction_type == "Quadrant", season == "All year", direction == "South")

stopifnot(
  "Every quadrant in every season rests on at least 300 hours" =
    min(ox_by_wind$n_hours[ox_by_wind$direction_type == "Quadrant"]) >= 300,
  "Every check has a wider Ox gap in wind from the channel than in other wind, as the title says" =
    all(channel_year$`ox_gap_ppb_From the channel` < channel_year$ox_gap_ppb_Other),
  "In wind from the channel the Ox gap's 95% range is below zero, with and without Harvard Street" =
    channel_gap("Main", "ox_ci_high_From the channel") < 0 && channel_gap("Without the transition band", "ox_ci_high_From the channel") < 0,
  "Without Harvard Street, the Ox gap in other wind is within 0.5 ppb of zero, as the subtitle says" =
    abs(channel_gap("Without the transition band", "ox_gap_ppb_Other")) <= 0.5,
  "Without Harvard Street, south wind gives the Ship Channel slightly more Ox, range above zero" = south_without_harvard$ox_ci_low > 0
)

# Harvard Street, the Houston other site nearest the channel, against Bayland Park, the farthest, under the same shared
# wind. Higher Ox at Harvard Street with wind from the channel side would match channel air reaching it first
harvard_site <- transition_sites

bayland_site <- site_roles %>%
  filter(site_group == "Houston other", !in_transition_band, site_id %in% ox_hours$site_id) %>%
  pull(site_id)

harvard_bayland_gaps <- ox_hours %>%
  filter(site_id %in% c(harvard_site, bayland_site)) %>%
  mutate(site = if_else(site_id == harvard_site, "harvard", "bayland")) %>%
  select(site, datetime_utc, date_local, ozone_ppb, no2_ppb, ox_ppb) %>%
  pivot_wider(names_from = site, values_from = c(ozone_ppb, no2_ppb, ox_ppb)) %>%
  filter(!is.na(ox_ppb_harvard), !is.na(ox_ppb_bayland)) %>%
  inner_join(filter(shared_wind, wind_set == "All sensors"), by = "datetime_utc", relationship = "one-to-one") %>%
  mutate(ozone_gap = ozone_ppb_harvard - ozone_ppb_bayland, no2_gap = no2_ppb_harvard - no2_ppb_bayland, ox_gap = ox_ppb_harvard - ox_ppb_bayland)

set.seed(bootstrap_seed)

harvard_bayland <- harvard_bayland_gaps %>%
  summarise(n_hours = n(), ozone_gap = mean(ozone_gap), no2_gap = mean(no2_gap), ox_gap = mean(ox_gap), .by = c(wind_sector, date_local)) %>%
  arrange(wind_sector, date_local) %>%
  summarise(
    n_hours = sum(n_hours),
    n_days = n(),
    ozone_gap_ppb = mean(ozone_gap),
    no2_gap_ppb = mean(no2_gap),
    ox_gap_ppb = mean(ox_gap),
    range = list(block_mean_range(ox_gap)),
    .by = wind_sector
  ) %>%
  mutate(ox_ci_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(ox_ci_high = vapply(range, \(r) r[2], numeric(1))) %>%
  select(-range) %>%
  left_join(filter(channel_sectors, site_id == harvard_site) %>% select(-site_id), by = "wind_sector", relationship = "one-to-one") %>%
  mutate(in_channel_direction = coalesce(in_channel_direction, FALSE)) %>%
  arrange(wind_sector)

print(mutate(harvard_bayland, across(where(is.double), \(x) round(x, 2))))

stopifnot(
  "Harvard Street and Bayland Park pair on at least 20,000 hours" = sum(harvard_bayland$n_hours) >= 20000,
  "Every sector has at least 200 paired hours" = min(harvard_bayland$n_hours) >= min_sector_hours
)

# Figures 2C.8 and 2C.9: NO2 roses and SO2 spike roses, four large roses each, with the side facing the channel shaded
channel_shade <- "#fbe3d7"

above_normal_fill <- chart_fills[["accent"]]

below_normal_fill <- "#cfcec7"

spike_fill <- "#0a4a50"

compass_words <- c(
  "north", "north-northeast", "east-northeast", "east", "east-southeast", "south-southeast", "south", "south-southwest",
  "west-southwest", "west", "west-northwest", "north-northwest"
)

no2_rose_order <- channel_bearings %>%
  filter(site_id %in% main_roses$site_id[main_roses$measure == "NO2"]) %>%
  arrange(km_to_channel)

# The two sites the SO2 story turns on come first
so2_rose_order <- channel_bearings %>%
  filter(site_id %in% so2_direction_shares$site_id) %>%
  inner_join(select(so2_direction_shares, site_id, short_name), by = "site_id", relationship = "one-to-one") %>%
  mutate(order = match(short_name, c("Park Place", "Croquet", "Deer Park #2", "Clinton"))) %>%
  arrange(order)

no2_rose_top <- 0.1 * ceiling(10 * max(main_roses$ratio_to_typical[main_roses$measure == "NO2" & main_roses$site_id %in% no2_rose_order$site_id]))

main_so2_directions <- so2_directions %>%
  filter(site_set == "Main", period == "All hours")

so2_rose_top <- 10 * ceiling(max(main_so2_directions$pct_of_spike_hours, main_so2_directions$pct_of_hours) / 10)

direction_rose_base <- function(sectors_toward_channel, top, kicker, kicker_colour, name, caption, radius_scale = "identity") {
  list(
    annotate(
      "rect", xmin = sectors_toward_channel - 15, xmax = sectors_toward_channel + 15, ymin = 0, ymax = top, fill = channel_shade
    ),
    geom_text(
      data = compass_points, aes(x = wind_sector, y = top * 1.12, label = label), inherit.aes = FALSE,
      family = chart_fonts[["mono"]], size = chart_sizes[["axis"]] / .pt, colour = chart_ink[["muted"]]
    ),
    annotate("path", x = seq(-15, 345, 1), y = top, colour = chart_ink[["axis"]], linewidth = 0.3),
    scale_x_continuous(limits = c(-15, 345), expand = expansion(0)),
    scale_y_continuous(limits = c(0, top * 1.16), expand = expansion(0), transform = radius_scale),
    coord_polar(start = -pi / 12, clip = "off"),
    labs(title = kicker, subtitle = name, caption = caption, x = NULL, y = NULL),
    theme_aqs(),
    theme(
      axis.text = element_blank(),
      panel.grid.major = element_blank(),
      panel.grid.major.x = element_blank(),
      panel.grid.major.y = element_blank(),
      plot.title = element_text(colour = kicker_colour),
      plot.caption = element_text(family = chart_fonts[["mono"]], size = chart_sizes[["axis"]] - 0.4, margin = margin(t = 4)),
      plot.margin = margin(0, 18, 20, 0)
    )
  )
}

site_sectors_toward_channel <- function(site) {
  channel_sectors$wind_sector[channel_sectors$site_id == site]
}

no2_rose_panel <- function(site) {
  petals <- main_roses %>%
    filter(measure == "NO2", site_id == site) %>%
    mutate(petal_fill = if_else(ratio_to_typical > 1, above_normal_fill, below_normal_fill))
  peak <- slice_max(petals, ratio_to_typical, n = 1)
  site_row <- filter(no2_rose_order, site_id == site)
  ggplot(petals) +
    direction_rose_base(
      site_sectors_toward_channel(site), no2_rose_top,
      str_c("NO2  /  ", group_kickers[[as.character(site_row$site_group)]]), site_group_colours[[as.character(site_row$site_group)]],
      short_site_name(site_names$local_site_name[site_names$site_id == site]),
      sprintf("Most NO2 in %s wind: %.1f times usual", compass_words[peak$wind_sector / 30 + 1], peak$ratio_to_typical)
    ) +
    geom_rect(aes(xmin = wind_sector - 12, xmax = wind_sector + 12, ymin = 0, ymax = ratio_to_typical, fill = petal_fill)) +
    annotate("path", x = seq(-15, 345, 1), y = 1, colour = chart_ink[["primary"]], linewidth = 0.5) +
    annotate(
      "text", x = 210, y = 1, label = "USUAL", vjust = 1.6,
      family = chart_fonts[["mono"]], size = (chart_sizes[["axis"]] - 1.2) / .pt, colour = chart_ink[["primary"]]
    ) +
    scale_fill_identity()
}

so2_rose_panel <- function(site) {
  sectors <- main_so2_directions %>%
    filter(site_id == site) %>%
    arrange(wind_sector) %>%
    mutate(next_pct_of_hours = lead(pct_of_hours, default = first(pct_of_hours)))
  shares <- filter(so2_direction_shares, site_id == site)
  caption <- if (shares$site_group == "Houston other") {
    sprintf("Southwest: %.0f%% of spikes, %.0f%% of hours", shares$pct_spikes_from_southwest, shares$pct_hours_from_southwest)
  } else {
    sprintf("Channel side: %.0f%% of spikes, %.0f%% of hours", shares$pct_spikes_from_channel, shares$pct_hours_from_channel)
  }
  ggplot(sectors) +
    direction_rose_base(
      site_sectors_toward_channel(site), so2_rose_top,
      str_c("SO2  /  ", group_kickers[[as.character(shares$site_group)]]), site_group_colours[[as.character(shares$site_group)]],
      shares$short_name, caption, radius_scale = "sqrt"
    ) +
    geom_rect(aes(xmin = wind_sector - 12, xmax = wind_sector + 12, ymin = 0, ymax = pct_of_spike_hours), fill = spike_fill) +
    geom_segment(aes(x = wind_sector - 15, xend = wind_sector + 15, y = pct_of_hours, yend = pct_of_hours), colour = chart_ink[["primary"]], linewidth = 0.45) +
    geom_segment(aes(x = wind_sector + 15, xend = wind_sector + 15, y = pct_of_hours, yend = next_pct_of_hours), colour = chart_ink[["primary"]], linewidth = 0.45)
}

no2_rose_panels <- lapply(no2_rose_order$site_id, no2_rose_panel)

so2_rose_panels <- lapply(so2_rose_order$site_id, so2_rose_panel)

stopifnot(
  "Four NO2 roses and four SO2 roses" = length(no2_rose_panels) == 4 && length(so2_rose_panels) == 4,
  "Every NO2 petal fits inside its scale" = no2_rose_top >= max(main_roses$ratio_to_typical[main_roses$measure == "NO2" & main_roses$site_id %in% no2_rose_order$site_id]),
  "Croquet's spikes come from the far side of the channel, as the subtitle says" = so2_share("Croquet", "pct_spikes_from_channel") < 5
)

no2_rose_header <- chart_header(
  sprintf("FIGURE 2C.8  /  NO2 BY WIND DIRECTION  /  %s TO %s", min(study_years), max(study_years)),
  "NO2 runs highest in wind from the east",
  str_c(
    "Each petal points to where the wind comes from. Past the dark ring: more NO2 than usual.\n",
    "At all four Houston sites the longest petals point east."
  ),
  key = tribble(
    ~mark,    ~colour,           ~label,
    "square", above_normal_fill, "More NO2 than usual",
    "square", below_normal_fill, "Less than usual",
    "square", channel_shade,     "Toward the Ship Channel"
  )
)

no2_rose_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d, 1e), ordinary hours with a wind direction (calm hours left out). Sectors are 30° wide.\n",
  "Usual: the site's own average at the same hour of day and month, so time of day and season do not shape the petals.\n",
  "Harvard Street has no wind sensor and uses Croquet's wind."
))

no2_rose_figure <- chart_compose(no2_rose_header, no2_rose_panels, no2_rose_footer, ncol = 2)

no2_rose_figure_path <- here("figures", "phase2", "2c.08_no2_roses.png")

save_started <- Sys.time()

ggsave(no2_rose_figure_path, no2_rose_figure, width = 6.5, height = 7.4, dpi = 300)

stopifnot(
  "2c.08_no2_roses.png was written (close any viewer of it and rerun this step)" = file.mtime(no2_rose_figure_path) >= save_started - 2
)

so2_rose_header <- chart_header(
  sprintf("FIGURE 2C.9  /  SO2 SPIKES BY WIND DIRECTION  /  %s TO %s", min(study_years), max(study_years)),
  "Croquet's SO2 spikes come from the southwest",
  str_c(
    "Dark petals: where spike hours come from. Black outline: where the wind usually comes from.\n",
    "Park Place's spikes come from the Ship Channel side (shaded); Croquet's come from the far side."
  ),
  key = tribble(
    ~mark,    ~colour,                ~label,
    "square", spike_fill,             "Spike hours",
    "bar",    chart_ink[["primary"]], "All hours",
    "square", channel_shade,          "Toward the Ship Channel"
  )
)

so2_rose_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d, 1e), ordinary hours with a wind direction (calm hours left out). Sectors are 30° wide.\n",
  "Spike: an hour at ", so2_spike_ppb, " ppb or more. A petal reaching past the outline: spikes come from that side more than wind does.\n",
  "Petal area shows each direction's share, so small petals stay visible."
))

so2_rose_figure <- chart_compose(so2_rose_header, so2_rose_panels, so2_rose_footer, ncol = 2)

so2_rose_figure_path <- here("figures", "phase2", "2c.09_so2_roses.png")

save_started <- Sys.time()

ggsave(so2_rose_figure_path, so2_rose_figure, width = 6.5, height = 7.4, dpi = 300)

stopifnot(
  "2c.09_so2_roses.png was written (close any viewer of it and rerun this step)" = file.mtime(so2_rose_figure_path) >= save_started - 2
)

# Figure 2C.10: the Ox gap in wind from the channel against other wind, with and without Harvard Street, over the year and
# by season. The sector detail, the other checks and Harvard Street against Bayland Park are in the CSV record
main_channel_sectors <- channel_wind_sectors$wind_sector[channel_wind_sectors$site_set == "Main"]

wind_type_fills <- c("Wind from the channel" = chart_fills[["accent"]], "Other wind" = below_normal_fill)

harvard_labels <- c("Main" = "With Harvard St", "Without the transition band" = "Without Harvard St")

channel_bars <- ox_by_wind %>%
  filter(direction_type == "Channel or other", season == "All year", site_set %in% names(harvard_labels)) %>%
  mutate(set_label = factor(harvard_labels[as.character(site_set)], levels = harvard_labels)) %>%
  mutate(wind_type = factor(if_else(direction == "Other", "Other wind", "Wind from the channel"), levels = names(wind_type_fills))) %>%
  mutate(label = sprintf("%+.1f", ox_gap_ppb)) %>%
  mutate(label_y = if_else(ox_gap_ppb < 0, pmin(ox_ci_low, ox_gap_ppb), pmax(ox_ci_high, ox_gap_ppb))) %>%
  mutate(label_vjust = if_else(ox_gap_ppb < 0, 1.5, -0.6))

bar_dodge <- position_dodge(width = 0.78)

channel_bar_panel <- ggplot(channel_bars, aes(set_label, ox_gap_ppb, fill = wind_type)) +
  geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35) +
  geom_col(position = bar_dodge, width = 0.72) +
  geom_errorbar(aes(ymin = ox_ci_low, ymax = ox_ci_high), position = bar_dodge, width = 0, colour = chart_ink[["secondary"]], linewidth = 0.45) +
  geom_text(
    aes(y = label_y, label = label, vjust = label_vjust), position = bar_dodge,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.4) / .pt, colour = chart_ink[["primary"]]
  ) +
  annotate(
    "text", x = -Inf, y = Inf, label = "SHIP CHANNEL HAS MORE OX", hjust = -0.04, vjust = 1.4,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 1.2) / .pt, colour = chart_ink[["muted"]]
  ) +
  annotate(
    "text", x = -Inf, y = -Inf, label = "HOUSTON OTHER HAS MORE OX", hjust = -0.04, vjust = -0.6,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 1.2) / .pt, colour = chart_ink[["muted"]]
  ) +
  scale_fill_manual(values = wind_type_fills, guide = "none") +
  scale_y_continuous(labels = signed_labels, expand = expansion(mult = c(0.3, 0.3))) +
  labs(title = "01  OVER THE YEAR", subtitle = "Ox gap, all seasons (ppb)", x = NULL, y = NULL) +
  theme_aqs() +
  theme(axis.text.x = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.6))

season_tiles <- ox_by_wind %>%
  filter(direction_type == "Channel or other", site_set %in% names(harvard_labels)) %>%
  mutate(facet = factor(toupper(harvard_labels[as.character(site_set)]), levels = toupper(harvard_labels))) %>%
  mutate(direction = factor(if_else(direction == "Other", "Other\nwind", "Channel\nwind"), levels = c("Channel\nwind", "Other\nwind"))) %>%
  mutate(season = factor(as.character(season), levels = rev(season_levels))) %>%
  mutate(excludes_zero = ox_ci_high < 0 | ox_ci_low > 0) %>%
  mutate(label = sprintf("%+.1f", ox_gap_ppb))

tile_limit <- ceiling(max(abs(season_tiles$ox_gap_ppb)))

ox_season_panel <- ggplot(season_tiles, aes(direction, season, fill = ox_gap_ppb)) +
  geom_tile(colour = "white", linewidth = 0.4) +
  geom_text(
    aes(label = label, colour = excludes_zero),
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.6) / .pt
  ) +
  scale_colour_manual(values = c(`TRUE` = chart_ink[["primary"]], `FALSE` = chart_ink[["muted"]]), guide = "none") +
  facet_grid(. ~ facet) +
  scale_fill_gradient2(
    low = site_group_colours[["Houston other"]], mid = "white", high = site_group_colours[["Houston Ship Channel"]], midpoint = 0,
    limits = c(-tile_limit, tile_limit), guide = "none"
  ) +
  scale_x_discrete(position = "top") +
  scale_y_discrete(labels = \(x) toupper(x)) +
  labs(title = "02  BY SEASON", subtitle = "The same gap, season by season (ppb)", x = NULL, y = NULL) +
  theme_aqs() +
  facet_strips +
  theme(
    panel.grid.major = element_blank(),
    axis.text.x.top = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.2, lineheight = 0.9),
    axis.text.y = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["muted"]], size = chart_sizes[["axis"]] - 0.6),
    strip.text.x = element_text(margin = margin(b = 4), size = chart_sizes[["axis"]] - 0.6),
    panel.spacing.x = unit(8, "pt")
  )

without_harvard_channel <- channel_gap("Without the transition band", "ox_gap_ppb_From the channel")

ox_wind_header <- chart_header(
  sprintf("FIGURE 2C.10  /  OX GAP BY WIND  /  %s TO %s", min(study_years), max(study_years)),
  "The leftover gap appears in wind from the channel",
  sprintf(
    str_c(
      "Ox is ozone plus NO2. Below zero, the Houston other sites have more Ox than the Ship Channel.\n",
      "Without Harvard Street: %.1f ppb in wind from the channel, close to zero in all other wind.\n",
      "Consistent with ozone forming in channel air as it crosses Houston."
    ),
    without_harvard_channel
  ),
  key = tribble(
    ~mark,    ~colour,                                     ~label,
    "square", chart_fills[["accent"]],                     "Wind from the channel",
    "square", below_normal_fill,                           "Other wind",
    "square", site_group_colours[["Houston other"]],       "Houston other more Ox",
    "square", site_group_colours[["Houston Ship Channel"]], "Ship Channel more Ox"
  )
)

ox_wind_footer <- chart_footer(str_c(
  "EPA AQS hourly data (1d, 1e). Wind: average of the 6 Houston wind sensors in each hour. Calm hours left out.\n",
  "Wind from the channel: from ", min(main_channel_sectors) - 15, "° to ", max(main_channel_sectors) + 15,
  "°, the directions in which it lies from Bayland Park and Harvard Street.\n",
  "Bars: 95% ranges (", bootstrap_block_days, "-day blocks). Table: grey values could be zero. Every check: case_study_ox_gap_by_wind.csv."
))

ox_wind_figure <- chart_compose(ox_wind_header, list(channel_bar_panel, ox_season_panel), ox_wind_footer, widths = c(1, 1.15))

ox_wind_figure_path <- here("figures", "phase2", "2c.10_ox_by_wind.png")

save_started <- Sys.time()

ggsave(ox_wind_figure_path, ox_wind_figure, width = 6.5, height = 5, dpi = 300)

stopifnot(
  "2c.10_ox_by_wind.png was written (close any viewer of it and rerun this step)" = file.mtime(ox_wind_figure_path) >= save_started - 2
)

# CSV records: each Houston site's bearings to the channel with its SO2 spike shares, the NO2 and ozone roses, SO2 spikes by
# direction, and the Ox gap by wind direction
channel_record <- channel_bearings %>%
  left_join(site_names, by = "site_id", relationship = "one-to-one") %>%
  left_join(select(so2_direction_shares, -site_group, -short_name), by = "site_id", relationship = "one-to-one") %>%
  select(
    site_group, site_id, local_site_name, km_to_channel, nearest_bearing_deg, channel_sectors, n_channel_sectors, n_spike_hours,
    n_episodes, pct_spikes_from_channel, channel_ci_low, channel_ci_high, pct_hours_from_channel, pct_spikes_from_southwest,
    southwest_ci_low, southwest_ci_high, pct_hours_from_southwest
  ) %>%
  mutate(across(where(is.double), \(x) round(x, 2))) %>%
  arrange(site_group, km_to_channel)

rose_record <- pollution_roses %>%
  left_join(site_names, by = "site_id", relationship = "many-to-one") %>%
  select(
    site_set, measure, site_group, site_id, local_site_name, wind_sector, in_channel_direction, n_hours, pct_of_hours, is_thin_sector,
    mean_ppb, typical_ppb, ratio_to_typical, difference_from_typical_ppb
  ) %>%
  mutate(across(c(pct_of_hours, mean_ppb, typical_ppb, difference_from_typical_ppb), \(x) round(x, 2))) %>%
  mutate(ratio_to_typical = round(ratio_to_typical, 3))

ox_wind_record <- bind_rows(
  ox_by_wind %>%
    mutate(comparison = "Ship Channel minus Houston other", season = as.character(season)),
  harvard_bayland %>%
    mutate(comparison = "Harvard Street minus Bayland Park", site_set = factor("Main", levels = levels(ox_by_wind$site_set))) %>%
    mutate(direction_type = "Sector", direction = as.character(wind_sector), season = "All year") %>%
    select(-wind_sector, -in_channel_direction)
) %>%
  select(
    comparison, site_set, direction_type, direction, season, n_hours, n_days, ozone_gap_ppb, no2_gap_ppb, ox_gap_ppb, ox_ci_low,
    ox_ci_high, share_of_ozone_gap_closed
  ) %>%
  mutate(across(c(ozone_gap_ppb, no2_gap_ppb, ox_gap_ppb, ox_ci_low, ox_ci_high), \(x) round(x, 2))) %>%
  mutate(share_of_ozone_gap_closed = round(share_of_ozone_gap_closed, 3))

direction_records <- list(
  case_study_channel_bearings = channel_record,
  case_study_pollution_roses = rose_record,
  case_study_so2_directions = so2_directions %>%
    rename(local_site_name = short_name) %>%
    mutate(across(c(spike_rate_per_1000, pct_of_spike_hours, pct_of_hours), \(x) round(x, 2))),
  case_study_ox_gap_by_wind = ox_wind_record
)

stopifnot(
  "Channel bearings: one row per Houston hourly site" = nrow(channel_record) == nrow(houston_hourly_sites),
  "Pollution roses: 12 sectors for every set, measure and site" = all(count(rose_record, site_set, measure, site_id)$n == 12),
  "SO2 directions: 12 sectors for every set, site and period" = all(count(so2_directions, site_set, site_id, period)$n == 12),
  "Ox gap by wind: one row per comparison, set, direction and season" =
    !anyDuplicated(ox_wind_record[c("comparison", "site_set", "direction_type", "direction", "season")])
)

save_records(direction_records, records_dir)

direction_dictionary <- tribble(
  ~table,                        ~column,                       ~description,
  "case_study_channel_bearings", "site_group",                  "Case-study group: Houston Ship Channel or Houston other",
  "case_study_channel_bearings", "site_id",                     "AQS site ID of a Houston hourly site",
  "case_study_channel_bearings", "local_site_name",             "Site name given by the reporting agency",
  "case_study_channel_bearings", "km_to_channel",               "Distance to the land-cut Ship Channel in km, from 1c",
  "case_study_channel_bearings", "nearest_bearing_deg",         "Compass bearing from the site to the nearest point of the channel, degrees clockwise from north",
  "case_study_channel_bearings", "channel_sectors",             "30-degree wind sectors (centre angles) in which the land-cut channel lies from the site",
  "case_study_channel_bearings", "n_channel_sectors",           "Number of those sectors",
  "case_study_channel_bearings", "n_spike_hours",               "SO2 spike hours (5 ppb or more) with a wind direction; NA at sites without SO2",
  "case_study_channel_bearings", "n_episodes",                  "Runs of consecutive spike hours among them",
  "case_study_channel_bearings", "pct_spikes_from_channel",     "Share of spike hours with wind from the channel sectors",
  "case_study_channel_bearings", "channel_ci_low",              "Lower end of its 95% range from resampling whole episodes",
  "case_study_channel_bearings", "channel_ci_high",             "Upper end of its 95% range from resampling whole episodes",
  "case_study_channel_bearings", "pct_hours_from_channel",      "Share of all SO2 hours with wind from the channel sectors",
  "case_study_channel_bearings", "pct_spikes_from_southwest",   "Share of spike hours with wind from 195 to 255 degrees",
  "case_study_channel_bearings", "southwest_ci_low",            "Lower end of its 95% range from resampling whole episodes",
  "case_study_channel_bearings", "southwest_ci_high",           "Upper end of its 95% range from resampling whole episodes",
  "case_study_channel_bearings", "pct_hours_from_southwest",    "Share of all SO2 hours with wind from 195 to 255 degrees",
  "case_study_pollution_roses",  "site_set",                    "Main or a check: transition band, method change, Deer Park #2 after its move, without new wind sensors",
  "case_study_pollution_roses",  "measure",                     "Ozone or NO2",
  "case_study_pollution_roses",  "site_group",                  "Case-study group",
  "case_study_pollution_roses",  "site_id",                     "AQS site ID: state-county-site",
  "case_study_pollution_roses",  "local_site_name",             "Site name given by the reporting agency",
  "case_study_pollution_roses",  "wind_sector",                 "30-degree sector the wind comes from (centre angle, 0 is north)",
  "case_study_pollution_roses",  "in_channel_direction",        "TRUE when the land-cut channel lies in this sector from the site",
  "case_study_pollution_roses",  "n_hours",                     "Ordinary hours with a wind direction (not calm) in the sector",
  "case_study_pollution_roses",  "pct_of_hours",                "Share of the site's direction hours in the sector",
  "case_study_pollution_roses",  "is_thin_sector",              "TRUE when the sector has fewer than 200 hours; left blank in figures",
  "case_study_pollution_roses",  "mean_ppb",                    "Mean in the sector, ppb; NA when the sector has no hours",
  "case_study_pollution_roses",  "typical_ppb",                 "Mean of the site's normal hour (same hour of day and month) over the sector's hours, ppb",
  "case_study_pollution_roses",  "ratio_to_typical",            "mean_ppb over typical_ppb; above 1 means more than usual with wind from this sector",
  "case_study_pollution_roses",  "difference_from_typical_ppb", "mean_ppb minus typical_ppb",
  "case_study_so2_directions",   "site_set",                    "Main, Without Deer Park #2 after its move, or Without new wind sensors",
  "case_study_so2_directions",   "site_group",                  "Case-study group: Houston Ship Channel or Houston other",
  "case_study_so2_directions",   "site_id",                     "AQS site ID: state-county-site",
  "case_study_so2_directions",   "local_site_name",             "Site name, shortened",
  "case_study_so2_directions",   "period",                      "All hours, or Day (9 am to 6 pm, local standard time)",
  "case_study_so2_directions",   "wind_sector",                 "30-degree sector the wind comes from (centre angle, 0 is north)",
  "case_study_so2_directions",   "n_hours",                     "Ordinary SO2 hours with a wind direction in the sector and period",
  "case_study_so2_directions",   "n_spike_hours",               "Hours at or above 5 ppb",
  "case_study_so2_directions",   "spike_rate_per_1000",         "Spike hours per 1,000 hours in the sector",
  "case_study_so2_directions",   "pct_of_spike_hours",          "Share of the site's spike hours in the sector",
  "case_study_so2_directions",   "pct_of_hours",                "Share of the site's hours in the sector",
  "case_study_so2_directions",   "in_channel_direction",        "TRUE when the land-cut channel lies in this sector from the site",
  "case_study_ox_gap_by_wind",   "comparison",                  "Ship Channel minus Houston other, or Harvard Street minus Bayland Park",
  "case_study_ox_gap_by_wind",   "site_set",                    "Main or a check: transition band, method change, Deer Park #2 after its move, without new wind sensors",
  "case_study_ox_gap_by_wind",   "direction_type",              "Sector (12 of 30 degrees), Quadrant (4 of 90 degrees), or Channel or other",
  "case_study_ox_gap_by_wind",   "direction",                   "Sector centre angle, quadrant name, or From the channel / Other, by the shared Houston wind",
  "case_study_ox_gap_by_wind",   "season",                      "All year, or a meteorological season (winter is December to February)",
  "case_study_ox_gap_by_wind",   "n_hours",                     "Paired hours with a shared wind direction",
  "case_study_ox_gap_by_wind",   "n_days",                      "Days with at least one such hour",
  "case_study_ox_gap_by_wind",   "ozone_gap_ppb",               "Mean daily ozone difference, ppb",
  "case_study_ox_gap_by_wind",   "no2_gap_ppb",                 "Mean daily NO2 difference, ppb",
  "case_study_ox_gap_by_wind",   "ox_gap_ppb",                  "Mean daily Ox (ozone + NO2) difference, ppb",
  "case_study_ox_gap_by_wind",   "ox_ci_low",                   "Lower end of the 95% range from the 14-day block bootstrap; main set, Harvard check and Harvard rows only",
  "case_study_ox_gap_by_wind",   "ox_ci_high",                  "Upper end of the 95% range from the 14-day block bootstrap; main set, Harvard check and Harvard rows only",
  "case_study_ox_gap_by_wind",   "share_of_ozone_gap_closed",   "1 minus the Ox gap over the ozone gap; NA for the Harvard Street rows"
)

direction_dictionary <- document_tables(direction_records, direction_dictionary)

replace_own_rows(direction_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(rose_hours, rose_sets, so2_direction_hours, so2_direction_sets, wind_ox_gaps, ox_wind_gaps, channel_sight_lines)



# 7. VALIDATE AND SAVE ----
# Every headline 95% range redrawn with a second seed, every headline finding under every check (figure 2C.11), one table of
# headline numbers for the report, and a final observed / expected / passed table
set.seed(bootstrap_check_seed)

# Hour gaps (2C.2): the 24 hourly ranges for NO2 and ozone, from the main paired hours kept from section 2
seed_hour_gaps <- bind_rows(lapply(cycle_pollutants, \(pollutant_name) {
  paired_gaps %>%
    filter(site_set == "Main", pollutant == pollutant_name) %>%
    hour_gap_ranges() %>%
    rename(check_low = ci_low, check_high = ci_high) %>%
    mutate(pollutant = pollutant_name)
})) %>%
  inner_join(
    main_gaps %>%
      mutate(pollutant = as.character(pollutant)) %>%
      select(pollutant, hour_local, estimate = gap_ppb, ci_low, ci_high),
    by = c("pollutant", "hour_local"),
    relationship = "one-to-one"
  ) %>%
  mutate(finding_id = if_else(pollutant == "NO2", "R01", "R02"), item = str_c(pollutant, " at ", hour_local, ":00")) %>%
  select(finding_id, item, estimate, ci_low, ci_high, check_low, check_high)

# Ox gap over the year and in winter (2C.4)
seed_ox_seasons <- ox_season_days %>%
  filter(site_set == "Main", measure == "Ox", season %in% c("All year", "Winter")) %>%
  summarise(range = list(block_mean_range(gap_ppb)), .by = season) %>%
  mutate(check_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(check_high = vapply(range, \(r) r[2], numeric(1))) %>%
  inner_join(
    filter(main_ox, season %in% c("All year", "Winter")) %>%
      select(season, estimate = ox_gap_ppb, ci_low = ox_ci_low, ci_high = ox_ci_high),
    by = "season",
    relationship = "one-to-one"
  ) %>%
  mutate(finding_id = "R04", item = str_c("Ox gap, ", season)) %>%
  select(finding_id, item, estimate, ci_low, ci_high, check_low, check_high)

# Deer Park #2 plume NO2 (2C.5)
plume_no2 <- plume_spikes %>%
  filter(period %in% c("Day, 9 am to 6 pm", "Night and morning"), measure == "NO2")

plume_no2_check <- episode_mean_range(plume_no2$difference_ppb, plume_no2$episode)

seed_plume <- tibble(
  finding_id = "R06",
  item = "Deer Park #2 plume NO2",
  estimate = all_no2$mean_difference_ppb,
  ci_low = all_no2$ci_low,
  ci_high = all_no2$ci_high,
  check_low = plume_no2_check[1],
  check_high = plume_no2_check[2]
)

# Calm minus windy at each site (2C.7)
seed_calm <- calm_site_days %>%
  filter(site_set == "Main", measure %in% cycle_pollutants) %>%
  summarise(range = list(block_mean_range(difference_ppb)), .by = c(measure, site_id)) %>%
  mutate(check_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(check_high = vapply(range, \(r) r[2], numeric(1))) %>%
  inner_join(
    main_site_calm %>%
      select(measure, site_id, local_site_name, estimate = calm_minus_windy_ppb, ci_low, ci_high),
    by = c("measure", "site_id"),
    relationship = "one-to-one"
  ) %>%
  mutate(finding_id = "R07", item = str_c(measure, ", ", short_site_name(local_site_name))) %>%
  select(finding_id, item, estimate, ci_low, ci_high, check_low, check_high)

# Croquet's southwest share and Park Place's channel-side share of spike hours (2C.9), in percent and tested against half
spike_share_check <- function(site_name, column) {
  spikes <- filter(main_so2_spikes, short_name == site_name)
  100 * episode_mean_range(as.numeric(spikes[[column]]), spikes$episode)
}

croquet_share_check <- spike_share_check("Croquet", "from_southwest")

park_place_share_check <- spike_share_check("Park Place", "from_channel")

seed_spike_shares <- tibble(
  finding_id = c("R09", "R09"),
  item = c("Croquet, share from the southwest", "Park Place, share from the channel side"),
  estimate = c(so2_share("Croquet", "pct_spikes_from_southwest"), so2_share("Park Place", "pct_spikes_from_channel")),
  ci_low = c(so2_share("Croquet", "southwest_ci_low"), so2_share("Park Place", "channel_ci_low")),
  ci_high = c(so2_share("Croquet", "southwest_ci_high"), so2_share("Park Place", "channel_ci_high")),
  check_low = c(croquet_share_check[1], park_place_share_check[1]),
  check_high = c(croquet_share_check[2], park_place_share_check[2]),
  threshold = 50
)

# The Ox gap in wind from the channel, with and without Harvard Street (2C.10)
seed_channel_wind <- direction_day_gaps %>%
  filter(
    site_set %in% c("Main", "Without the transition band"), measure == "Ox", direction_type == "Channel or other",
    direction == "From the channel", season == "All year"
  ) %>%
  summarise(range = list(block_mean_range(gap_ppb)), .by = site_set) %>%
  mutate(check_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(check_high = vapply(range, \(r) r[2], numeric(1))) %>%
  inner_join(
    channel_year %>%
      select(site_set, estimate = `ox_gap_ppb_From the channel`, ci_low = `ox_ci_low_From the channel`, ci_high = `ox_ci_high_From the channel`),
    by = "site_set",
    relationship = "one-to-one"
  ) %>%
  mutate(finding_id = "R10", item = if_else(site_set == "Main", "Channel wind, with Harvard Street", "Channel wind, without Harvard Street")) %>%
  select(finding_id, item, estimate, ci_low, ci_high, check_low, check_high)

# A range keeps its verdict when it stays on the same side of its threshold (zero, or half for the spike shares)
seed_check <- bind_rows(seed_hour_gaps, seed_ox_seasons, seed_plume, seed_calm, seed_spike_shares, seed_channel_wind) %>%
  mutate(threshold = coalesce(threshold, 0)) %>%
  mutate(main_verdict = case_when(ci_low > threshold ~ "Above", ci_high < threshold ~ "Below", .default = "Includes")) %>%
  mutate(check_verdict = case_when(check_low > threshold ~ "Above", check_high < threshold ~ "Below", .default = "Includes")) %>%
  mutate(verdict_changes = main_verdict != check_verdict) %>%
  mutate(largest_shift = pmax(abs(check_low - ci_low), abs(check_high - ci_high))) %>%
  mutate(shift_share = largest_shift / (ci_high - ci_low))

seed_check %>%
  summarise(n_ranges = n(), n_verdicts_changed = sum(verdict_changes), largest_shift_share = max(shift_share), .by = finding_id) %>%
  mutate(largest_shift_share = round(largest_shift_share, 3)) %>%
  print()

stopifnot(
  "Every redrawn range is complete" = !anyNA(seed_check$check_low) && !anyNA(seed_check$check_high),
  "48 hour gaps, 2 Ox seasons, 1 plume, 12 calm comparisons, 2 spike shares and 2 channel-wind gaps" = nrow(seed_check) == 48 + 2 + 1 + 12 + 2 + 2
)

# Every headline finding under every check. A check that removes no hours a finding uses is left blank, as it would only
# repeat the main result
robustness_columns <- c(hourly_check_levels, sensor_check_level, "Second seed")

findings <- tribble(
  ~finding_id, ~figure, ~finding,
  "R01",       "2C.2",  "Ship Channel NO2 higher at every hour",
  "R02",       "2C.2",  "Ship Channel ozone lower at every hour",
  "R03",       "2C.3",  "Weekend NO2 falls least at the Ship Channel",
  "R04",       "2C.4",  "Ox closes at least half the ozone gap",
  "R05",       "2C.5",  "Croquet's SO2 spikes come by day",
  "R06",       "2C.5",  "Deer Park #2 plumes carry extra NO2",
  "R07",       "2C.7",  "Calm air: more NO2, less ozone, every site",
  "R08",       "2C.8",  "NO2 runs highest in east wind",
  "R09",       "2C.9",  "Croquet's SO2 spikes come from the southwest",
  "R10",       "2C.10", "Ox gap wider in wind from the channel"
)

houston_no2_peak_sets <- pollution_roses %>%
  filter(measure == "NO2", site_group != "Dallas-Fort Worth", !is_thin_sector) %>%
  slice_max(ratio_to_typical, n = 1, by = c(site_set, site_id)) %>%
  summarise(holds = all(wind_sector %in% east_sectors), .by = site_set)

calm_site_sets <- calm_air %>%
  filter(level == "Site", measure %in% cycle_pollutants) %>%
  summarise(
    holds = all(calm_minus_windy_ppb[measure == "NO2"] > 0) && all(calm_minus_windy_ppb[measure == "Ozone"] < 0),
    .by = site_set
  )

croquet_southwest_sets <- bind_rows(
  tibble(site_set = "Main", pct_from_southwest = so2_share("Croquet", "pct_spikes_from_southwest")),
  mutate(check_croquet_shares, site_set = as.character(site_set))
)

seed_holds <- seed_check %>%
  summarise(holds = !any(verdict_changes) && all(shift_share <= bootstrap_seed_tolerance), .by = finding_id) %>%
  mutate(site_set = "Second seed")

robustness <- bind_rows(
  cycle_checks %>%
    filter(pollutant == "NO2") %>%
    transmute(finding_id = "R01", site_set = as.character(site_set), holds = hours_ship_channel_higher == 24),
  cycle_checks %>%
    filter(pollutant == "Ozone") %>%
    transmute(finding_id = "R02", site_set = as.character(site_set), holds = hours_ship_channel_higher == 0),
  cycle_checks %>%
    filter(pollutant == "NO2") %>%
    transmute(
      finding_id = "R03", site_set = as.character(site_set),
      holds = weekend_ratio_houston_ship_channel > pmax(weekend_ratio_houston_other, weekend_ratio_dallas_fort_worth)
    ),
  ox_checks %>%
    filter(season == "All year") %>%
    transmute(finding_id = "R04", site_set = as.character(site_set), holds = share_of_ozone_gap_closed >= 0.5),
  so2_spike_sites %>%
    filter(short_name == "Croquet") %>%
    transmute(finding_id = "R05", site_set = as.character(site_set), holds = pct_spikes_daytime >= 90),
  tibble(finding_id = "R06", site_set = "Main", holds = all_no2$ci_low > 0),
  transmute(calm_site_sets, finding_id = "R07", site_set = as.character(site_set), holds = holds),
  transmute(houston_no2_peak_sets, finding_id = "R08", site_set = as.character(site_set), holds = holds),
  transmute(croquet_southwest_sets, finding_id = "R09", site_set = site_set, holds = pct_from_southwest > 50),
  transmute(channel_year, finding_id = "R10", site_set = as.character(site_set), holds = `ox_gap_ppb_From the channel` < ox_gap_ppb_Other),
  seed_holds
) %>%
  complete(finding_id = findings$finding_id, site_set = robustness_columns) %>%
  inner_join(findings, by = "finding_id", relationship = "many-to-one") %>%
  mutate(result = case_when(is.na(holds) ~ "Does not apply", holds ~ "Holds", .default = "Fails")) %>%
  mutate(site_set = factor(site_set, levels = robustness_columns)) %>%
  select(finding_id, figure, finding, site_set, result) %>%
  arrange(finding_id, site_set)

robustness %>%
  select(finding_id, site_set, result) %>%
  pivot_wider(names_from = site_set, values_from = result) %>%
  print(width = Inf)

n_failing <- sum(robustness$result == "Fails")

n_tested <- sum(robustness$result != "Does not apply")

stopifnot(
  "One row per finding and column" = nrow(robustness) == nrow(findings) * length(robustness_columns),
  "Every finding holds in the main set" = all(robustness$result[robustness$site_set == "Main"] == "Holds"),
  "Every finding holds under every check that applies, as figure 2C.11's title says" = n_failing == 0
)

# Headline numbers for the report: one row per number the text quotes, each with its unit, 95% range where there is one,
# and the record it comes from, so the report reads numbers instead of retyping them
group_value <- function(table, group, column) {
  table[[column]][table$site_group == group]
}

morning_no2_change <- function(group) {
  100 * (morning_no2_ratio(group) - 1)
}

calm_effect_range <- function(measure_name, column) {
  main_group_calm[[column]][main_group_calm$measure == measure_name]
}

houston_no2_peak_rows <- no2_peaks %>%
  filter(site_group != "Dallas-Fort Worth") %>%
  mutate(subject = short_site_name(local_site_name))

headline_rows <- list(
  tibble(
    figure = "2C.1", finding = "Hours in which every group reports together", subject = "All groups",
    value = main_coverage_floor, unit = "% of hours", ci_low = NA_real_, ci_high = NA_real_,
    source_table = "case_study_hourly_inventory"
  ),
  tibble(
    figure = "2C.2", finding = "Widest Ship Channel minus Houston other NO2 gap, by hour", subject = sprintf("%02d:00", widest_no2_gap$hour_local),
    value = widest_no2_gap$gap_ppb, unit = "ppb", ci_low = widest_no2_gap$ci_low, ci_high = widest_no2_gap$ci_high,
    source_table = "case_study_hourly_gaps"
  ),
  tibble(
    figure = "2C.2", finding = "Widest Ship Channel minus Houston other ozone gap, by hour", subject = sprintf("%02d:00", widest_ozone_gap$hour_local),
    value = widest_ozone_gap$gap_ppb, unit = "ppb", ci_low = widest_ozone_gap$ci_low, ci_high = widest_ozone_gap$ci_high,
    source_table = "case_study_hourly_gaps"
  ),
  tibble(
    figure = "2C.3", finding = "Weekend against weekday NO2, 6 to 8 am, April to October", subject = names(site_group_colours),
    value = vapply(names(site_group_colours), morning_no2_change, numeric(1)), unit = "%", ci_low = NA_real_, ci_high = NA_real_,
    source_table = "case_study_hourly_cycle_checks"
  ),
  tibble(
    figure = "2C.4", finding = "Ship Channel minus Houston other ozone, over the year", subject = "Main",
    value = ox_season("All year")$ozone_gap_ppb, unit = "ppb", ci_low = ox_season("All year")$ozone_ci_low,
    ci_high = ox_season("All year")$ozone_ci_high, source_table = "case_study_ox_checks"
  ),
  tibble(
    figure = "2C.4", finding = "Share of the ozone gap that Ox closes, over the year", subject = c("Main", "Without Harvard Street"),
    value = 100 * c(ox_season("All year")$share_of_ozone_gap_closed, transition_year$share_of_ozone_gap_closed), unit = "%",
    ci_low = NA_real_, ci_high = NA_real_, source_table = "case_study_ox_checks"
  ),
  tibble(
    figure = "2C.4", finding = "Share of the ozone gap that Ox closes, winter", subject = "Main",
    value = 100 * ox_season("Winter")$share_of_ozone_gap_closed, unit = "%", ci_low = NA_real_, ci_high = NA_real_,
    source_table = "case_study_ox_checks"
  ),
  tibble(
    figure = "2C.5", finding = "Croquet SO2 spike hours from 9 am to 6 pm", subject = "Croquet",
    value = croquet_spikes$pct_spikes_daytime, unit = "% of spike hours", ci_low = NA_real_, ci_high = NA_real_,
    source_table = "case_study_so2_spike_sites"
  ),
  tibble(
    figure = "2C.5", finding = "Croquet summer spike rate over the next highest season", subject = "Croquet",
    value = croquet_summer_ratio, unit = "times", ci_low = NA_real_, ci_high = NA_real_, source_table = "case_study_so2_spike_profiles"
  ),
  tibble(
    figure = "2C.5", finding = "Extra NO2 in Deer Park #2 SO2 spike hours", subject = "Deer Park #2",
    value = all_no2$mean_difference_ppb, unit = "ppb", ci_low = all_no2$ci_low, ci_high = all_no2$ci_high,
    source_table = "case_study_so2_plume_test"
  ),
  tibble(
    figure = "2C.6", finding = "Share of hours that are calm", subject = as.character(calm_group_shares$site_group),
    value = calm_group_shares$pct_calm, unit = "% of wind hours", ci_low = NA_real_, ci_high = NA_real_,
    source_table = "case_study_wind_sites"
  ),
  tibble(
    figure = "2C.7", finding = "Calm minus windy hours at the same hour and month", subject = c("NO2, every site", "Ozone, every site"),
    value = c(min(no2_site_effects$calm_minus_windy_ppb), max(ozone_site_effects$calm_minus_windy_ppb)), unit = "ppb, smallest site",
    ci_low = NA_real_, ci_high = NA_real_, source_table = "case_study_calm_air"
  ),
  tibble(
    figure = "2C.7", finding = "Share of the ozone lost in calm air that shows up as NO2", subject = "Lowest group",
    value = 100 * ox_offset_low, unit = "%", ci_low = NA_real_, ci_high = NA_real_, source_table = "case_study_calm_air"
  ),
  tibble(
    figure = "2C.8", finding = "NO2 in the wind direction with the most, against usual", subject = houston_no2_peak_rows$subject,
    value = houston_no2_peak_rows$ratio_to_typical, unit = "times usual", ci_low = NA_real_, ci_high = NA_real_,
    source_table = "case_study_pollution_roses"
  ),
  tibble(
    figure = "2C.9", finding = c("Croquet SO2 spike hours from the southwest", "Park Place SO2 spike hours from the channel side"),
    subject = c("Croquet", "Park Place"),
    value = c(so2_share("Croquet", "pct_spikes_from_southwest"), so2_share("Park Place", "pct_spikes_from_channel")),
    unit = "% of spike hours",
    ci_low = c(so2_share("Croquet", "southwest_ci_low"), so2_share("Park Place", "channel_ci_low")),
    ci_high = c(so2_share("Croquet", "southwest_ci_high"), so2_share("Park Place", "channel_ci_high")),
    source_table = "case_study_channel_bearings"
  ),
  tibble(
    figure = "2C.9", finding = c("Croquet hours with wind from the southwest", "Park Place hours with wind from the channel side"),
    subject = c("Croquet", "Park Place"),
    value = c(so2_share("Croquet", "pct_hours_from_southwest"), so2_share("Park Place", "pct_hours_from_channel")),
    unit = "% of hours", ci_low = NA_real_, ci_high = NA_real_, source_table = "case_study_channel_bearings"
  ),
  tibble(
    figure = "2C.10", finding = "Ship Channel minus Houston other Ox, by wind", subject = c("Channel wind, without Harvard Street", "Other wind, without Harvard Street"),
    value = c(channel_gap("Without the transition band", "ox_gap_ppb_From the channel"), channel_gap("Without the transition band", "ox_gap_ppb_Other")),
    unit = "ppb",
    ci_low = c(channel_gap("Without the transition band", "ox_ci_low_From the channel"), channel_gap("Without the transition band", "ox_ci_low_Other")),
    ci_high = c(channel_gap("Without the transition band", "ox_ci_high_From the channel"), channel_gap("Without the transition band", "ox_ci_high_Other")),
    source_table = "case_study_ox_gap_by_wind"
  ),
  tibble(
    figure = "2C.11", finding = "Headline findings that hold under every check that applies", subject = "All findings",
    value = nrow(findings) - n_distinct(robustness$finding_id[robustness$result == "Fails"]), unit = str_c("of ", nrow(findings)),
    ci_low = NA_real_, ci_high = NA_real_, source_table = "case_study_hourly_robustness"
  )
)

hourly_headlines <- bind_rows(headline_rows) %>%
  mutate(headline_id = sprintf("H%02d", row_number())) %>%
  mutate(across(c(value, ci_low, ci_high), \(x) round(x, 2))) %>%
  select(headline_id, figure, finding, subject, value, unit, ci_low, ci_high, source_table)

print(hourly_headlines, n = Inf, width = Inf)

stopifnot(
  "Every headline has a value" = !anyNA(hourly_headlines$value),
  "Every headline range holds its value" =
    all(is.na(hourly_headlines$ci_low) | (hourly_headlines$ci_low <= hourly_headlines$value & hourly_headlines$value <= hourly_headlines$ci_high))
)

# Figure 2C.11: every headline finding under every check, one cell each
robustness_labels <- c(
  "Main" = "Main",
  "Without the transition band" = "No Harvard\nStreet",
  "Without hours after the method change" = "No method\nchange",
  "Without Deer Park #2 after its move" = "No Deer\nPark move",
  "Without new wind sensors" = "No new wind\nsensors",
  "Second seed" = "Second\nseed"
)

result_fills <- c("Holds" = chart_fills[["accent"]], "Fails" = site_group_colours[["Houston Ship Channel"]], "Does not apply" = chart_fills[["band"]])

result_text <- c("Holds" = "HOLDS", "Fails" = "FAILS", "Does not apply" = "")

robustness_plot <- robustness %>%
  mutate(row_label = factor(str_c(figure, "  ", finding), levels = rev(str_c(findings$figure, "  ", findings$finding)))) %>%
  mutate(column_label = factor(robustness_labels[as.character(site_set)], levels = robustness_labels)) %>%
  mutate(cell_text = result_text[result]) %>%
  mutate(text_colour = if_else(result == "Does not apply", chart_ink[["muted"]], "white"))

robustness_panel <- ggplot(robustness_plot, aes(column_label, row_label, fill = result)) +
  geom_tile(colour = "white", linewidth = 0.8) +
  geom_text(aes(label = cell_text, colour = text_colour), family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 1) / .pt) +
  scale_fill_manual(values = result_fills, guide = "none") +
  scale_colour_identity() +
  scale_x_discrete(position = "top") +
  labs(title = "01  FINDINGS AND CHECKS", subtitle = "Does each finding survive each check?", x = NULL, y = NULL) +
  theme_aqs() +
  theme(
    panel.grid.major = element_blank(),
    axis.text.x.top = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.2, lineheight = 0.95),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.6, hjust = 0)
  )

robustness_header <- chart_header(
  sprintf("FIGURE 2C.11  /  EVERY CHECK  /  %s TO %s", min(study_years), max(study_years)),
  "Every finding holds under every check",
  str_c(
    "Each row is a finding from 2C.2 to 2C.10; each column reruns it without one data issue.\n",
    "Pale cells: the check changes nothing for that finding. Second seed: 95% ranges redrawn."
  ),
  key = tribble(
    ~mark,    ~colour,                        ~label,
    "square", result_fills[["Holds"]],        "Holds",
    "square", result_fills[["Fails"]],        "Fails",
    "square", result_fills[["Does not apply"]], "Check changes nothing"
  )
)

robustness_footer <- chart_footer(str_c(
  "Harvard Street: the Houston other site nearest the channel. Method change: Harvard Street NO2 from April 2024.\n",
  "Deer Park move: its hours from May 2025. New wind sensors: hours on the sonic sensors at five sites.\n",
  "Second seed: ", n_distinct(seed_check$item), " ranges redrawn with seed ", bootstrap_check_seed,
  "; each must stay on its side of zero (50% for spike shares)."
))

robustness_figure <- chart_compose(robustness_header, list(robustness_panel), robustness_footer, ncol = 1)

robustness_figure_path <- here("figures", "phase2", "2c.11_checks.png")

save_started <- Sys.time()

ggsave(robustness_figure_path, robustness_figure, width = 6.5, height = 5.4, dpi = 300)

stopifnot(
  "2c.11_checks.png was written (close any viewer of it and rerun this step)" = file.mtime(robustness_figure_path) >= save_started - 2
)

# Final validation: inputs, hour rules, ranges, findings and saved files
hourly_rows_listed <- input_check$rows[match(hourly_files, input_check$file)]

duplicate_monitor_hours <- sum(duplicated(hourly_case_study[c("site_id", "pollutant", "datetime_utc")]))

houston_group_mismatches <- sum(as.character(houston_group_check$site_group) != houston_group_check$group_from_1c)

main_ranges <- bind_rows(
  transmute(main_gaps, estimate = gap_ppb, ci_low, ci_high),
  transmute(filter(ox_season_gaps, site_set == "Main"), estimate = gap_ppb, ci_low, ci_high),
  transmute(plume_test, estimate = mean_difference_ppb, ci_low, ci_high),
  transmute(filter(calm_air, site_set == "Main"), estimate = calm_minus_windy_ppb, ci_low, ci_high),
  transmute(filter(ox_by_wind, !is.na(ox_ci_low)), estimate = ox_gap_ppb, ci_low = ox_ci_low, ci_high = ox_ci_high),
  transmute(so2_direction_shares, estimate = pct_spikes_from_channel, ci_low = channel_ci_low, ci_high = channel_ci_high),
  transmute(so2_direction_shares, estimate = pct_spikes_from_southwest, ci_low = southwest_ci_low, ci_high = southwest_ci_high)
)

ranges_missing_estimate <- sum(main_ranges$estimate < main_ranges$ci_low - 1e-9 | main_ranges$estimate > main_ranges$ci_high + 1e-9)

figure_paths <- here("figures", "phase2", c(
  "2c.01_coverage.png", "2c.02_daily_cycles.png", "2c.03_season_weekend.png", "2c.04_ox.png", "2c.05_so2_spikes.png",
  "2c.06_wind_roses.png", "2c.07_calm_air.png", "2c.08_no2_roses.png", "2c.09_so2_roses.png", "2c.10_ox_by_wind.png",
  "2c.11_checks.png"
))

final_records <- list(
  case_study_hourly_seed_check = seed_check %>%
    inner_join(select(findings, finding_id, figure), by = "finding_id", relationship = "many-to-one") %>%
    select(finding_id, figure, item, threshold, estimate, ci_low, ci_high, check_low, check_high, main_verdict, check_verdict, verdict_changes, shift_share) %>%
    mutate(across(c(estimate, ci_low, ci_high, check_low, check_high), \(x) round(x, 3))) %>%
    mutate(shift_share = round(shift_share, 3)),
  case_study_hourly_robustness = mutate(robustness, site_set = as.character(site_set)),
  case_study_hourly_headlines = hourly_headlines
)

earlier_records <- c(inventory_records, cycle_records, ox_records, so2_records, wind_records, direction_records, final_records)

save_records(final_records, records_dir)

documented_tables <- read_csv(data_dictionary_path, col_types = cols(.default = col_character())) %>%
  distinct(table) %>%
  pull(table)

record_paths <- file.path(records_dir, str_c(names(earlier_records), ".csv"))

headline_sources_missing <- sum(!hourly_headlines$source_table %in% names(earlier_records))

count_checks <- tribble(
  ~check,                                                            ~observed,                                   ~expected,
  "Pollutant-hours in hourly_case_study.rds against the manifest",   nrow(hourly_case_study),                     hourly_rows_listed[1],
  "Site-hours in hourly_weather.rds against the manifest",           nrow(hourly_weather),                        hourly_rows_listed[2],
  "Duplicate monitor-hours",                                         duplicate_monitor_hours,                     0,
  "Houston sites whose group differs from 1c",                       houston_group_mismatches,                    0,
  "Ordinary hours (valid day, no Uri, Beryl or wildfire flag)",      funnel_totals$ordinary_hours,                649365,
  "Ordinary hours with a usable wind direction",                     funnel_totals$with_wind_direction,           559229,
  "Main-set hours with every group reporting, lowest share under 95%", sum(main_same_hour$pct_every_group < 95),  0,
  "Main 95% ranges that leave out their own estimate",               ranges_missing_estimate,                     0,
  "Second-seed ranges whose verdict changes",                        sum(seed_check$verdict_changes),             0,
  "Second-seed ranges whose ends move over 10% of their width",      sum(seed_check$shift_share > bootstrap_seed_tolerance), 0,
  "Finding and check pairs that fail",                               n_failing,                                   0,
  "Headlines whose source table is not saved",                       headline_sources_missing,                    0,
  "2c figures on disk",                                              sum(file.exists(figure_paths)),              length(figure_paths),
  "Saved 2c tables without data dictionary rows (this table aside)", sum(!names(earlier_records) %in% c(documented_tables, names(final_records))), 0,
  "Saved 2c tables at or over the GitHub limit",                     sum(file.size(record_paths) / 2^20 >= github_limit_mib), 0
) %>%
  mutate(observed = as.character(observed)) %>%
  mutate(expected = as.character(expected))

text_checks <- tribble(
  ~check,                                                      ~observed,                                           ~expected,
  "Monitors and sites",                                        str_c(nrow(monitors), " monitors, ", n_distinct(monitors$site_id), " sites"), "16 monitors, 9 sites",
  "Main monitors per group: ozone, NO2, SO2",                  str_flatten(main_monitor_counts, collapse = "/"),    "2/2/2/2/2/2/3/1",
  "Houston other site in the transition band",                 str_flatten(transition_sites, collapse = ", "),       "48-201-0417",
  "Sites that sit out a check for lack of data",                str_flatten(unique(sparse_sites$site_id), collapse = ", "), "48-201-0055"
)

case_study_hourly_validation <- bind_rows(count_checks, text_checks) %>%
  mutate(passed = observed == expected)

print(case_study_hourly_validation, n = Inf, width = Inf)

stopifnot("Every 2c validation check passed" = all(case_study_hourly_validation$passed))

# CSV records: the validation table, saved last so it reports on every other file
validation_records <- list(
  case_study_hourly_validation = case_study_hourly_validation
)

save_records(validation_records, records_dir)

final_dictionary <- tribble(
  ~table,                         ~column,           ~description,
  "case_study_hourly_seed_check", "finding_id",      "Finding the range supports, as in case_study_hourly_robustness",
  "case_study_hourly_seed_check", "figure",          "Figure that shows the finding",
  "case_study_hourly_seed_check", "item",            "The range: an hour of day, season, site or comparison",
  "case_study_hourly_seed_check", "threshold",       "Value the range is judged against: 0, or 50 for the spike shares (in percent)",
  "case_study_hourly_seed_check", "estimate",        "The main estimate (ppb, or percent for the spike shares)",
  "case_study_hourly_seed_check", "ci_low",          "Lower end of the main 95% range (seed 2026)",
  "case_study_hourly_seed_check", "ci_high",         "Upper end of the main 95% range (seed 2026)",
  "case_study_hourly_seed_check", "check_low",       "Lower end of the same range redrawn with seed 2027",
  "case_study_hourly_seed_check", "check_high",      "Upper end of the same range redrawn with seed 2027",
  "case_study_hourly_seed_check", "main_verdict",    "Above, Below or Includes the threshold, main range",
  "case_study_hourly_seed_check", "check_verdict",   "Above, Below or Includes the threshold, redrawn range",
  "case_study_hourly_seed_check", "verdict_changes", "TRUE when the redrawn range lands on a different side of the threshold",
  "case_study_hourly_seed_check", "shift_share",     "Largest move of either end as a share of the main range's width",
  "case_study_hourly_robustness", "finding_id",      "R01 to R10, one per headline finding",
  "case_study_hourly_robustness", "figure",          "Figure that shows the finding",
  "case_study_hourly_robustness", "finding",         "The finding in plain words",
  "case_study_hourly_robustness", "site_set",        "Main, one of the four data checks, or Second seed",
  "case_study_hourly_robustness", "result",          "Holds, Fails, or Does not apply (the check removes no hours the finding uses)",
  "case_study_hourly_headlines",  "headline_id",     "H01 onward, in figure order",
  "case_study_hourly_headlines",  "figure",          "Figure that shows the number",
  "case_study_hourly_headlines",  "finding",         "What the number measures, in plain words",
  "case_study_hourly_headlines",  "subject",         "Group, site, hour or set the number belongs to",
  "case_study_hourly_headlines",  "value",           "The number, rounded to 2 decimals",
  "case_study_hourly_headlines",  "unit",            "Unit of value",
  "case_study_hourly_headlines",  "ci_low",          "Lower end of the 95% range where the record gives one; NA otherwise",
  "case_study_hourly_headlines",  "ci_high",         "Upper end of the 95% range where the record gives one; NA otherwise",
  "case_study_hourly_headlines",  "source_table",    "CSV record in data/processed/phase2 the number comes from",
  "case_study_hourly_validation", "check",           "What 2c section 7 checks: inputs, hour rules, 95% ranges, findings or saved files",
  "case_study_hourly_validation", "observed",        "Value found in this run",
  "case_study_hourly_validation", "expected",        "Value the check requires",
  "case_study_hourly_validation", "passed",          "TRUE when observed equals expected; the script stops otherwise"
)

final_dictionary <- document_tables(c(final_records, validation_records), final_dictionary)

replace_own_rows(final_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(paired_gaps, direction_day_gaps)
