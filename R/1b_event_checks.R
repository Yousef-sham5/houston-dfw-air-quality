# SETUP ----
library(dplyr)
library(readr)
library(tidyr)
library(stringr)
library(lubridate)
library(here)

source(here("R", "utils.R")) # event_medians()

checkpoint_paths <- c(
  aqs_long = here("data", "processed", "aqs_long_clean.rds"),
  sites = here("data", "processed", "sites.rds")
)

stopifnot(
  "Run 1a_import_clean.R and save the step 18 checkpoint first" =
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
# 12 candidate states, Jul 13-29
smoke_2021_states <- c("36", "34", "42", "09", "25", "44", "24", "11", "10", "51", "50", "33")

smoke_2021_check <- aqs_long %>%
  event_medians("state_code", smoke_2021_states, "PM2.5", "2021-07-13", "2021-07-29") %>%
  select(-n_sites) %>%
  pivot_wider(names_from = area, values_from = median_value) %>%
  arrange(pollutant, date_local)

print(smoke_2021_check, n = Inf, width = Inf)



# HURRICANE IDA ----
# Louisiana, Aug 15 to Sep 20, 2021
ida_check <- aqs_long %>%
  event_medians("state_code", "22", all_pollutants, "2021-08-15", "2021-09-20") %>%
  select(-area) %>%
  pivot_wider(names_from = pollutant, values_from = c(median_value, n_sites))

print(ida_check, n = Inf, width = Inf)



# EAST PALESTINE DERAILMENT ----
# Columbiana County and 8 nearby counties, Jan 28 to Feb 14, 2023
palestine_counties <- c(
  "39-029", "39-099", "39-155", "39-081",
  "42-007", "42-073", "42-003",
  "54-029", "54-009"
)

palestine_check <- aqs_long %>%
  event_medians("county_id", palestine_counties, c("PM2.5", "CO"), "2023-01-28", "2023-02-14") %>%
  select(-n_sites) %>%
  pivot_wider(names_from = area, values_from = median_value) %>%
  arrange(pollutant, date_local)

print(palestine_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, EARLY JUNE 2023 ----
# 17 candidate states, May 28 to Jun 16
smoke_2023_states <- c(
  "36", "34", "42", "09", "25", "44", "50", "33", "23",
  "24", "11", "10", "51", "54", "39", "26", "37"
)

smoke_2023_check <- aqs_long %>%
  event_medians("state_code", smoke_2023_states, "PM2.5", "2023-05-28", "2023-06-16") %>%
  select(-n_sites) %>%
  pivot_wider(names_from = area, values_from = median_value) %>%
  arrange(pollutant, date_local)

print(smoke_2023_check, n = Inf, width = Inf)



# CANADIAN WILDFIRE SMOKE, LATE JUNE 2023 ----
# 11 candidate states, Jun 20 to Jul 3 (ends before the July 4 fireworks window)
smoke_late_june_states <- c("17", "26", "55", "18", "39", "27", "19", "42", "36", "21", "29")

smoke_late_june_check <- aqs_long %>%
  event_medians("state_code", smoke_late_june_states, c("PM2.5", "Ozone"), "2023-06-20", "2023-07-03") %>%
  select(-n_sites) %>%
  pivot_wider(names_from = area, values_from = median_value) %>%
  arrange(pollutant, date_local)

print(smoke_late_june_check, n = Inf, width = Inf)



# HURRICANE BERYL ----
# Harris County, Jul 1-24, 2024
beryl_check <- aqs_long %>%
  event_medians("county_id", "48-201", all_pollutants, "2024-07-01", "2024-07-24") %>%
  select(-area) %>%
  pivot_wider(names_from = pollutant, values_from = c(median_value, n_sites))

print(beryl_check, n = Inf, width = Inf)

# CO by Harris County site during Beryl (one site stayed online)
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



# LA PALISADES AND EATON FIRES ----
# LA County and 4 neighbors, Jan 2-24, 2025
la_fire_counties <- c("06-037", "06-059", "06-065", "06-071", "06-111")

la_fire_check <- aqs_long %>%
  event_medians("county_id", la_fire_counties, c("PM2.5", "CO", "NO2"), "2025-01-02", "2025-01-24") %>%
  select(-n_sites) %>%
  pivot_wider(names_from = area, values_from = median_value) %>%
  arrange(pollutant, date_local)

print(la_fire_check, n = Inf, width = Inf)
