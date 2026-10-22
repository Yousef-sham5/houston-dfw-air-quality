# SETUP ----
library(dplyr)
library(readr)
library(tidyr)
library(stringr)
library(lubridate)
library(here)

source(here("R", "utils.R")) # event_medians(), event_median_table(), read_events()

checkpoint_paths <- c(
  aqs_long = here("data", "processed", "aqs_long_clean.rds"),
  sites = here("data", "processed", "sites.rds")
)

stopifnot(
  "Run 1a_import_clean.R and save the step 19 checkpoint first" =
    all(file.exists(checkpoint_paths))
)

aqs_long <- read_rds(checkpoint_paths[["aqs_long"]])
sites <- read_rds(checkpoint_paths[["sites"]])

all_pollutants <- levels(aqs_long$pollutant)



# WINTER STORM URI ----
# Harris County, Feb 1 to Mar 7, 2021
uri_check <- aqs_long %>%
  event_medians("county_id", "48-201", c("SO2", "NO2", "CO", "PM2.5"), "2021-02-01", "2021-03-07") %>%
  select(-area) %>%
  pivot_wider(names_from = pollutant, values_from = c(median_value, n_sites))

print(uri_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, JULY 2021 ----
# 12 candidate states, Jul 12 to Aug 3
smoke_2021_states <- c("36", "34", "42", "09", "25", "44", "24", "11", "10", "51", "50", "33")

smoke_2021_check <- aqs_long %>%
  event_median_table("state_code", smoke_2021_states, "PM2.5", "2021-07-12", "2021-08-03")

print(smoke_2021_check, n = Inf, width = Inf)



# WILDFIRE SMOKE, LATE JULY TO EARLY AUGUST 2021 ----
# 15 candidate states, Jul 20 to Aug 18 (Canadian smoke over the Upper Midwest, then western fires)
smoke_late_july_2021_states <- c("08", "16", "19", "20", "27", "31", "32", "35", "38", "40", "41", "46", "49", "53", "56")

smoke_late_july_2021_check <- aqs_long %>%
  event_median_table("state_code", smoke_late_july_2021_states, "PM2.5", "2021-07-20", "2021-08-18")

print(smoke_late_july_2021_check, n = Inf, width = Inf)



# WILDFIRE SMOKE, MID AUGUST 2021 ----
# 6 candidate states, Aug 5-30
smoke_mid_august_2021_states <- c("16", "30", "32", "38", "41", "53")

smoke_mid_august_2021_check <- aqs_long %>%
  event_median_table("state_code", smoke_mid_august_2021_states, "PM2.5", "2021-08-05", "2021-08-30")

print(smoke_mid_august_2021_check, n = Inf, width = Inf)



# WILDFIRE SMOKE, LATE AUGUST 2021 ----
# 4 candidate states, Aug 17 to Sep 8 (Caldor fire)
smoke_late_august_2021_states <- c("06", "32", "49", "56")

smoke_late_august_2021_check <- aqs_long %>%
  event_median_table("state_code", smoke_late_august_2021_states, "PM2.5", "2021-08-17", "2021-09-08")

print(smoke_late_august_2021_check, n = Inf, width = Inf)



# HURRICANE IDA ----
# Louisiana, Aug 15 to Sep 20, 2021
ida_check <- aqs_long %>%
  event_medians("state_code", "22", all_pollutants, "2021-08-15", "2021-09-20") %>%
  select(-area) %>%
  pivot_wider(names_from = pollutant, values_from = c(median_value, n_sites))

print(ida_check, n = Inf, width = Inf)



# WILDFIRE SMOKE, SEPTEMBER 2022 ----
# 6 candidate states, Sep 1-21 (Cedar Creek and Bolt Creek fires; Mosquito fire smoke over Reno)
smoke_september_2022_states <- c("16", "30", "32", "41", "49", "53")

smoke_september_2022_check <- aqs_long %>%
  event_median_table("state_code", smoke_september_2022_states, "PM2.5", "2022-09-01", "2022-09-21")

print(smoke_september_2022_check, n = Inf, width = Inf)



# EAST PALESTINE DERAILMENT ----
# Columbiana County and 8 nearby counties, Jan 28 to Feb 14, 2023
palestine_counties <- c(
  "39-029", "39-099", "39-155", "39-081",
  "42-007", "42-073", "42-003",
  "54-029", "54-009"
)

palestine_check <- aqs_long %>%
  event_median_table("county_id", palestine_counties, c("PM2.5", "CO"), "2023-01-28", "2023-02-14")

print(palestine_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, MAY 2023 ----
# 8 candidate states, May 8-28 (Alberta and British Columbia fires)
smoke_may_2023_states <- c("08", "16", "27", "30", "31", "38", "46", "56")

smoke_may_2023_check <- aqs_long %>%
  event_median_table("state_code", smoke_may_2023_states, "PM2.5", "2023-05-08", "2023-05-28")

print(smoke_may_2023_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, EARLY JUNE 2023 ----
# 17 candidate states, May 28 to Jun 16
smoke_2023_states <- c(
  "36", "34", "42", "09", "25", "44", "50", "33", "23",
  "24", "11", "10", "51", "54", "39", "26", "37"
)

smoke_2023_check <- aqs_long %>%
  event_median_table("state_code", smoke_2023_states, "PM2.5", "2023-05-28", "2023-06-16")

print(smoke_2023_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, LATE JUNE 2023 ----
# 26 candidate states, Jun 19 to Jul 3 (ends before the July 4 fireworks window). The Midwest, New York and
# Pennsylvania first, then New England, the Mid-Atlantic and the Southeast
smoke_late_june_states <- c(
  "17", "26", "55", "18", "39", "27", "19", "42", "36", "21", "29",
  "01", "09", "10", "11", "13", "24", "25", "33", "34", "37", "44", "47", "50", "51", "54"
)

smoke_late_june_check <- aqs_long %>%
  event_median_table("state_code", smoke_late_june_states, c("PM2.5", "Ozone"), "2023-06-19", "2023-07-03")

print(smoke_late_june_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, MID JULY 2023 ----
# 23 candidate states, Jul 5-27 (Montana to the Ohio Valley, then the Carolinas)
smoke_mid_july_2023_states <- c(
  "01", "13", "17", "18", "19", "21", "25", "27", "30", "31", "33", "36",
  "37", "38", "39", "42", "45", "46", "47", "50", "51", "54", "55"
)

smoke_mid_july_2023_check <- aqs_long %>%
  event_median_table("state_code", smoke_mid_july_2023_states, "PM2.5", "2023-07-05", "2023-07-27")

print(smoke_mid_july_2023_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, LATE JULY 2023 ----
# 5 candidate states, Jul 16 to Aug 4
smoke_late_july_2023_states <- c("17", "18", "26", "27", "55")

smoke_late_july_2023_check <- aqs_long %>%
  event_median_table("state_code", smoke_late_july_2023_states, "PM2.5", "2023-07-16", "2023-08-04")

print(smoke_late_july_2023_check, n = Inf, width = Inf)



# WILDFIRE SMOKE, AUGUST 2023 ----
# 4 candidate states, Aug 8-28 (Northwest fires, then the Gray and Oregon Road fires near Spokane)
smoke_august_2023_states <- c("16", "30", "41", "53")

smoke_august_2023_check <- aqs_long %>%
  event_median_table("state_code", smoke_august_2023_states, "PM2.5", "2023-08-08", "2023-08-28")

print(smoke_august_2023_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, SEPTEMBER 2023 ----
# 8 candidate states, Aug 27 to Sep 15
smoke_september_2023_states <- c("19", "20", "29", "30", "31", "38", "46", "56")

smoke_september_2023_check <- aqs_long %>%
  event_median_table("state_code", smoke_september_2023_states, "PM2.5", "2023-08-27", "2023-09-15")

print(smoke_september_2023_check, n = Inf, width = Inf)



# HURRICANE BERYL ----
# Harris County, Jul 1-24, 2024
beryl_check <- aqs_long %>%
  event_medians("county_id", "48-201", all_pollutants, "2024-07-01", "2024-07-24") %>%
  select(-area) %>%
  pivot_wider(names_from = pollutant, values_from = c(median_value, n_sites))

print(beryl_check, n = Inf, width = Inf)

# CO by Harris County site during Beryl (no site on Jul 8-9, one back online from Jul 10)
aqs_long %>%
  filter(
    pollutant == "CO",
    state_code == "48",
    county_code == "201",
    between(date_local, ymd("2024-07-01"), ymd("2024-07-20"))
  ) %>%
  select(site_id, date_local, max_ugm3) %>%
  pivot_wider(names_from = site_id, values_from = max_ugm3) %>%
  print(n = Inf, width = Inf)

sites %>%
  filter(site_id == "48-201-1052") %>%
  select(site_id, local_site_name, latitude, longitude) %>%
  print()



# WILDFIRE SMOKE, SEPTEMBER 2024 ----
# 4 candidate states, Sep 1-19 (Southern California fires over Nevada and Utah)
smoke_september_2024_states <- c("30", "32", "38", "49")

smoke_september_2024_check <- aqs_long %>%
  event_median_table("state_code", smoke_september_2024_states, "PM2.5", "2024-09-01", "2024-09-19")

print(smoke_september_2024_check, n = Inf, width = Inf)



# LA PALISADES AND EATON FIRES ----
# LA County and 4 neighbors, Jan 2-24, 2025
la_fire_counties <- c("06-037", "06-059", "06-065", "06-071", "06-111")

la_fire_check <- aqs_long %>%
  event_median_table("county_id", la_fire_counties, c("PM2.5", "CO", "NO2"), "2025-01-02", "2025-01-24")

print(la_fire_check, n = Inf, width = Inf)



# PLAINS DUST STORM, MARCH 2025 ----
# 7 candidate states, Mar 4-22 (dust from the Texas South Plains and Panhandle to the Great Lakes)
dust_march_2025_states <- c("05", "17", "20", "26", "29", "40", "48")

dust_march_2025_check <- aqs_long %>%
  event_median_table("state_code", dust_march_2025_states, "PM2.5", "2025-03-04", "2025-03-22")

print(dust_march_2025_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, EARLY JUNE 2025 ----
# 13 candidate states, May 23 to Jun 16
smoke_early_june_2025_states <- c("17", "18", "19", "23", "25", "26", "27", "36", "38", "39", "42", "50", "55")

smoke_early_june_2025_check <- aqs_long %>%
  event_median_table("state_code", smoke_early_june_2025_states, "PM2.5", "2025-05-23", "2025-06-16")

print(smoke_early_june_2025_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, MID JULY 2025 ----
# 4 candidate states, Jul 2-22
smoke_mid_july_2025_states <- c("26", "27", "38", "55")

smoke_mid_july_2025_check <- aqs_long %>%
  event_median_table("state_code", smoke_mid_july_2025_states, "PM2.5", "2025-07-02", "2025-07-22")

print(smoke_mid_july_2025_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, LATE JULY 2025 ----
# 18 candidate states, Jul 19 to Aug 15 (New England first, then the Upper Midwest, then the Northeast again)
smoke_late_july_2025_states <- c(
  "09", "17", "18", "19", "20", "23", "25", "26", "27",
  "29", "31", "33", "36", "38", "42", "46", "50", "55"
)

smoke_late_july_2025_check <- aqs_long %>%
  event_median_table("state_code", smoke_late_july_2025_states, "PM2.5", "2025-07-19", "2025-08-15")

print(smoke_late_july_2025_check, n = Inf, width = Inf)



# PM2.5 EVENT RULE CHECK ----
# Every smoke, fire and dust row in events.csv must meet the inclusion rule: on at least one day of the row, the
# area's median PM2.5 is at least twice its median for the event's baseline week, and at least one site-day is
# above 35 µg/m³ (the 24-hour standard). Collocated instruments are averaged per site and day first. Baseline days
# that carry any event label are left out. Uri, Ida and Beryl are outage and emission events and are not judged
# on PM2.5
rule_exempt_events <- c("Winter Storm Uri", "Hurricane Ida", "Hurricane Beryl")

pm25_exceedance_level <- 35

min_ratio_to_baseline <- 2

# The week before each event, or the week after when the week before was itself smoky
event_baselines <- tribble(
  ~event_name,                                     ~base_start,  ~base_end,
  "Wildfire smoke July 2021 (episode 1)",          "2021-07-12", "2021-07-18",
  "Wildfire smoke July 2021 (episode 2)",          "2021-07-28", "2021-08-03",
  "Wildfire smoke late July to early August 2021", "2021-07-20", "2021-07-26",
  "Wildfire smoke mid August 2021",                "2021-08-24", "2021-08-30",
  "Wildfire smoke late August 2021",               "2021-09-02", "2021-09-08",
  "Wildfire smoke September 2022",                 "2022-09-01", "2022-09-07",
  "Canadian wildfire smoke May 2023",              "2023-05-08", "2023-05-14",
  "Canadian wildfire smoke early June 2023",       "2023-05-29", "2023-06-04",
  "Canadian wildfire smoke late June 2023",        "2023-06-19", "2023-06-25",
  "Canadian wildfire smoke mid July 2023",         "2023-07-05", "2023-07-11",
  "Canadian wildfire smoke late July 2023",        "2023-07-29", "2023-08-04",
  "Wildfire smoke August 2023",                    "2023-08-08", "2023-08-14",
  "Canadian wildfire smoke September 2023",        "2023-08-27", "2023-09-02",
  "Wildfire smoke September 2024",                 "2024-09-01", "2024-09-07",
  "LA Palisades and Eaton fires",                  "2025-01-12", "2025-01-18",
  "Plains dust storm March 2025",                  "2025-03-04", "2025-03-10",
  "Canadian wildfire smoke early June 2025",       "2025-05-23", "2025-05-29",
  "Canadian wildfire smoke mid July 2025",         "2025-07-02", "2025-07-08",
  "Canadian wildfire smoke late July 2025",        "2025-07-19", "2025-07-25"
) %>%
  mutate(across(c(base_start, base_end), ymd))

# Dates and codes are checked in read_events() (utils.R), the same reader 1a, 1d and 1e use
events_to_check <- read_events() %>%
  filter(str_detect(pollutants, "PM2.5")) %>%
  filter(!event_name %in% rule_exempt_events) %>%
  mutate(row_id = row_number())

stopifnot(
  "Every checked event has a baseline week" = all(events_to_check$event_name %in% event_baselines$event_name),
  "Every baseline week is 7 days" = all(event_baselines$base_end - event_baselines$base_start == 6)
)

pm25_site_days <- aqs_long %>%
  filter(pollutant == "PM2.5") %>%
  group_by(site_id, state_code, county_code, date_local) %>%
  summarise(
    value = mean(arithmetic_mean),
    is_labelled = any(!is.na(event_name)),
    .groups = "drop"
  )

# The area's median and exceedance count on each day of each row
row_peaks <- events_to_check %>%
  inner_join(pm25_site_days, by = join_by(state_code, start_date <= date_local, end_date >= date_local)) %>%
  filter(is.na(event_county) | county_code == event_county) %>%
  group_by(row_id, date_local) %>%
  summarise(
    area_median = median(value),
    n_exceed = sum(value > pm25_exceedance_level),
    .groups = "drop"
  ) %>%
  group_by(row_id) %>%
  summarise(
    peak_median = max(area_median),
    exceed_site_days = sum(n_exceed),
    .groups = "drop"
  )

# The area's median over the event's baseline week, leaving out labelled days
row_baselines <- events_to_check %>%
  left_join(event_baselines, by = "event_name", relationship = "many-to-one") %>%
  inner_join(pm25_site_days, by = join_by(state_code, base_start <= date_local, base_end >= date_local)) %>%
  filter(is.na(event_county) | county_code == event_county) %>%
  group_by(row_id, date_local) %>%
  summarise(
    area_median = median(value),
    any_labelled = any(is_labelled),
    .groups = "drop"
  ) %>%
  filter(!any_labelled) %>%
  group_by(row_id) %>%
  summarise(baseline_median = median(area_median), .groups = "drop")

event_rule_check <- events_to_check %>%
  left_join(row_peaks, by = "row_id", relationship = "one-to-one") %>%
  left_join(row_baselines, by = "row_id", relationship = "one-to-one") %>%
  mutate(peak_ratio = round(peak_median / baseline_median, 2)) %>%
  mutate(meets_rule = peak_ratio >= min_ratio_to_baseline & exceed_site_days > 0) %>%
  select(event_name, state_code, event_county, start_date, end_date, baseline_median, peak_median, peak_ratio, exceed_site_days, meets_rule)

print(event_rule_check, n = Inf, width = Inf)

stopifnot(
  "Every checked row has data and a baseline" = !anyNA(event_rule_check$peak_ratio),
  "Every smoke, fire and dust row doubles its baseline and has a site-day above 35 µg/m³" = all(event_rule_check$meets_rule)
)
