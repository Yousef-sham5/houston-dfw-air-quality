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

source(here("R", "utils.R")) # study_years, region_lookup, read_events(), naaqs_statistics(), monthly_profile(), save helpers, chart theme

load_chart_fonts()



# CONFIG ----
processed_dir <- here("data", "processed")

# CSV records go to a folder per phase; checkpoints, the dictionary and the manifest stay in data/processed
records_dir <- file.path(processed_dir, "phase2")

dir.create(records_dir, recursive = TRUE, showWarnings = FALSE)

# Written by 2a section 7, which builds the site groups, collocated averages and site-months from the national table
case_study_files <- c("daily_case_study.rds", "daily_case_study_instruments.rds", "daily_case_study_months.rds")

pollutant_levels <- c("PM2.5", "Ozone", "NO2", "SO2", "CO")

# CO stays out of the case study: Harris County has one five-year CO site and Dallas-Fort Worth has none
case_study_pollutants <- c("PM2.5", "Ozone", "NO2", "SO2")

# Copied from 2a CONFIG, so naaqs_statistics() screens the case-study sites with the same levels, rounding and ranks.
# Values are rounded as the standard specifies before comparing: ozone truncated to 3 decimals (Appendix U 3(e)),
# PM2.5 to 0.1 and 1 (Appendix N 4.3), NO2 and SO2 to whole ppb (Appendices S 4.2(c) and T 4.1(c)) and CO to whole
# ppm (50.8(d)), with halves rounded up
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

# Houston North Loop, Houston Southwest Freeway, Dallas LBJ Freeway, Fort Worth California Parkway North
near_road_ids <- c(
  "48-201-1052",
  "48-201-1066",
  "48-113-1067",
  "48-439-1053"
)

# Distance of every Harris site to the land-cut Ship Channel, its group and its group under the memo list, from 1c
harris_groups_path <- here("data", "reference", "harris_site_channel_distance.csv")

# The distance rule set in 1c, repeated for figure 2B.01 and checked against 1c's groups in section 1. Houston other
# sites in the transition band sit nearer the channel than the rest and are left out in one check
ship_channel_km <- 7.5

transition_km <- 15

transition_band <- str_c(ship_channel_km, " to ", transition_km, " km")

# Sites run with and without, since each could tilt its group. Park Place and Harvard Street NO2 read lower than their
# neighbours after their method changes, and Westhollow ozone read closer to its neighbours after its change; California
# Parkway North is near-road and one of three five-year Dallas-Fort Worth PM2.5 sites
sensitivity_sites <- tribble(
  ~site_id,      ~pollutant, ~local_site_name,                      ~left_out,
  "48-201-0066", "Ozone",    "Houston Westhollow",                  "Days after the method change",
  "48-201-0416", "NO2",      "Park Place",                          "Days after the method change",
  "48-201-0417", "NO2",      "Houston Harvard Street",              "Days after the method change",
  "48-439-1053", "PM2.5",    "Fort Worth California Parkway North", "Whole site"
) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels))

# Houston Deer Park #2 moved on 2025-05-30, the date 1d uses for its hourly flag
relocations <- tribble(
  ~site_id,      ~relocation_date,
  "48-201-1039", "2025-05-30"
) %>%
  mutate(relocation_date = ymd(relocation_date))

# PM2.5 sites with four of the five years, added in one sensitivity run since Houston other has one five-year PM2.5
# site: Clinton, Houston North Wayside, Houston Westhollow, Convention Center and Dallas Hinton. Houston North Loop
# also has four years but is near-road, so it stays out
four_year_pm25_ids <- c(
  "48-201-1035",
  "48-201-0046",
  "48-201-0066",
  "48-113-0050",
  "48-113-0069"
)

# NO2 sites with four of the five years, added in one sensitivity run that also lifts the Houston distance test from 7
# to 10 sites: Channelview, Clinton, Northwest Harris County, Dallas Hinton, Dallas North #2, Eagle Mountain Lake and
# Keller. The four-year near-road sites (North Loop, Southwest Freeway, California Parkway North) stay out
four_year_no2_ids <- c(
  "48-201-0026",
  "48-201-1035",
  "48-201-0029",
  "48-113-0069",
  "48-113-0075",
  "48-439-0075",
  "48-439-2003"
)

# A gap longer than this many days breaks a site's bar in figure 2B.1
long_gap_days <- 30

# Same-day comparisons (section 7): 95% ranges from a moving-block bootstrap. Nearby days are linked, so whole
# two-week blocks are resampled; the seed makes every run give the same ranges
bootstrap_block_days <- 14

bootstrap_reps <- 1000

bootstrap_seed <- 2026

# Section 8 reruns the main ranges with a second seed; an end that moves more than this share of the range's width
# fails validation
bootstrap_check_seed <- 2027

bootstrap_seed_tolerance <- 0.1

# The two Texas events with a case-study chapter of their own
case_study_events <- c("Winter Storm Uri", "Hurricane Beryl")

stopifnot(
  "Case-study pollutants are daily pollutants other than CO" = setequal(case_study_pollutants, setdiff(pollutant_levels, "CO")),
  "Every pollutant has a NAAQS row" = setequal(naaqs$pollutant, pollutant_levels),
  "Each percentile rank table covers 1 to 366 days without gaps" = all(vapply(
    split(percentile_ranks, percentile_ranks$percentile),
    \(t) identical(as.numeric(unlist(Map(seq, t$min_days, t$max_days))), as.numeric(1:366)),
    logical(1)
  )),
  "Every pollutant has one short-term rank rule" =
    setequal(naaqs_ranks$pollutant, pollutant_levels) && all(is.na(naaqs_ranks$fixed_rank) != is.na(naaqs_ranks$percentile)),
  "Near-road IDs are in the three case-study counties" = all(str_sub(near_road_ids, 1, 6) %in% region_lookup$county_id),
  "1c has written the Harris site groups (run 1c first)" = file.exists(harris_groups_path),
  "The transition band starts at the Ship Channel cutoff" = ship_channel_km < transition_km,
  "Sensitivity sites are unique case-study site-pollutants" =
    !anyDuplicated(select(sensitivity_sites, site_id, pollutant)) &&
    all(sensitivity_sites$pollutant %in% case_study_pollutants) &&
    all(str_sub(sensitivity_sites$site_id, 1, 6) %in% region_lookup$county_id),
  "Sensitivity sites leave out a whole site or its days after a method change" =
    all(sensitivity_sites$left_out %in% c("Whole site", "Days after the method change")),
  "Relocation dates fall inside the study years" = all(year(relocations$relocation_date) %in% study_years),
  "Four-year PM2.5 sites are unique case-study county sites" =
    !anyDuplicated(four_year_pm25_ids) && all(str_sub(four_year_pm25_ids, 1, 6) %in% region_lookup$county_id),
  "No near-road site is in the four-year PM2.5 set" = !any(four_year_pm25_ids %in% near_road_ids),
  "Four-year NO2 sites are unique case-study county sites" =
    !anyDuplicated(four_year_no2_ids) && all(str_sub(four_year_no2_ids, 1, 6) %in% region_lookup$county_id),
  "No near-road site is in the four-year NO2 set" = !any(four_year_no2_ids %in% near_road_ids),
  "The seed check uses a different seed" = bootstrap_check_seed != bootstrap_seed,
  "Both case-study events are in events.csv" = all(case_study_events %in% read_events()$event_name)
)



# 1. CASE-STUDY SITES AND NUANCES ----
# The case-study checkpoint from 2a section 7, checked against the manifest, and the Harris site groups from 1c
daily_case_study <- read_rds(file.path(processed_dir, "daily_case_study.rds"))

daily_case_study_instruments <- read_rds(file.path(processed_dir, "daily_case_study_instruments.rds"))

daily_case_study_months <- read_rds(file.path(processed_dir, "daily_case_study_months.rds"))

input_rows <- c(nrow(daily_case_study), nrow(daily_case_study_instruments), nrow(daily_case_study_months))

input_check <- read_csv(manifest_path, col_types = manifest_col_types) %>%
  filter(file %in% case_study_files) %>%
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

site_names <- daily_case_study %>%
  distinct(site_id, local_site_name)

sensitivity_name_check <- sensitivity_sites %>%
  left_join(site_names, by = "site_id", suffix = c("", "_data"), relationship = "many-to-one")

# Houston sites must carry the group 1c set from distance; a mismatch means 2a ran before the latest 1c
houston_group_check <- daily_case_study %>%
  filter(region == "Houston") %>%
  distinct(site_id, site_group) %>%
  inner_join(select(harris_groups, site_id, group_from_1c = site_group), by = "site_id", relationship = "one-to-one")

houston_site_count <- n_distinct(daily_case_study$site_id[daily_case_study$region == "Houston"])

grouped_harris_sites <- harris_groups %>%
  filter(site_group != "Excluded: Bayport-adjacent")

stopifnot(
  "The manifest lists the three case-study files" = setequal(input_check$file, case_study_files),
  "The inputs match the manifest (rerun 2a if not)" = all(input_check$md5 == input_check$md5_on_disk),
  "Row counts match the manifest" = identical(input_check$rows[match(case_study_files, input_check$file)], input_rows),
  "Every Houston site has a distance from 1c" = nrow(houston_group_check) == houston_site_count,
  "Houston groups match 1c (rerun 2a after 1c if not)" =
    all(as.character(houston_group_check$site_group) == houston_group_check$group_from_1c),
  "1c's groups follow the CONFIG cutoff" =
    all((grouped_harris_sites$km_to_channel <= ship_channel_km) == (grouped_harris_sites$site_group == "Houston Ship Channel")),
  "The transition band is one of 1c's distance bands" = transition_band %in% harris_groups$distance_band,
  "Pollutant levels match CONFIG" = identical(levels(daily_case_study$pollutant), pollutant_levels),
  "Only case-study pollutants are saved" = all(daily_case_study$pollutant %in% case_study_pollutants),
  "Site groups follow the chart colour order" = identical(levels(daily_case_study$site_group), names(site_group_colours)),
  "Every sensitivity site-pollutant is in the data" =
    nrow(anti_join(sensitivity_sites, daily_case_study, by = c("site_id", "pollutant"))) == 0,
  "Sensitivity site names match the data" = all(sensitivity_name_check$local_site_name == sensitivity_name_check$local_site_name_data),
  "Every near-road site is in the data" = all(near_road_ids %in% daily_case_study$site_id),
  "Every relocated site is in the data" = all(relocations$site_id %in% daily_case_study$site_id)
)

# Days at Deer Park #2 on or after its move, flagged as in the hourly table and kept
daily_case_study <- daily_case_study %>%
  left_join(relocations, by = "site_id", relationship = "many-to-one") %>%
  mutate(is_post_relocation = coalesce(date_local >= relocation_date, FALSE)) %>%
  select(-relocation_date)

relocation_check <- daily_case_study %>%
  filter(is_post_relocation) %>%
  summarise(first_flagged = min(date_local), n_site_days = n(), .by = c(site_id, local_site_name, pollutant))

print(relocation_check)

stopifnot(
  "Only relocated sites are flagged" = all(relocation_check$site_id %in% relocations$site_id),
  "The flag starts on the relocation date" = all(relocation_check$first_flagged == relocations$relocation_date[1])
)

# Distance to the land-cut Ship Channel for every Houston site. Houston other sites in the transition band are left out
# in one check, and the memo-list group is kept for another
houston_distances <- harris_groups %>%
  semi_join(daily_case_study, by = "site_id") %>%
  mutate(in_transition_band = distance_band == transition_band & site_group == "Houston other") %>%
  select(site_id, local_site_name, site_group, km_to_channel, distance_band, in_transition_band, in_memo_list, memo_site_group) %>%
  arrange(km_to_channel)

print(houston_distances, n = Inf, width = Inf)

farthest_ship_channel_site <- houston_distances %>%
  filter(site_group == "Houston Ship Channel") %>%
  slice_max(km_to_channel, n = 1, with_ties = FALSE)

nearest_other_site <- houston_distances %>%
  filter(site_group == "Houston other") %>%
  slice_min(km_to_channel, n = 1, with_ties = FALSE)

n_ship_channel_sites <- sum(houston_distances$site_group == "Houston Ship Channel")

stopifnot(
  "Every Houston site has one distance" = nrow(houston_distances) == houston_site_count,
  "Every Ship Channel site is nearer the channel than every Houston other site" =
    farthest_ship_channel_site$km_to_channel < nearest_other_site$km_to_channel,
  "Nine Houston sites lie within the cutoff, as figure 2B.01's title says" = n_ship_channel_sites == 9
)

# Each instrument's method periods. A method is new when it first reports more than 30 days after the site's first day,
# which separates a method change from a second instrument that ran from the start
method_periods <- daily_case_study_instruments %>%
  summarise(first_date = min(date_local), last_date = max(date_local), .by = c(site_id, pollutant, poc, method_code, method_type)) %>%
  arrange(site_id, pollutant, first_date, poc)

site_first_dates <- daily_case_study_instruments %>%
  summarise(site_first_date = min(date_local), .by = c(site_id, pollutant))

new_method_starts <- method_periods %>%
  slice_min(first_date, n = 1, by = c(site_id, pollutant, method_code), with_ties = FALSE) %>%
  inner_join(site_first_dates, by = c("site_id", "pollutant"), relationship = "many-to-one") %>%
  filter(first_date > site_first_date + 30) %>%
  select(site_id, pollutant, method_code, change_date = first_date)

method_history <- method_periods %>%
  mutate(period = str_c(method_type, " ", method_code, " (POC ", poc, ") ", first_date, " to ", last_date)) %>%
  summarise(method_history = str_c(period, collapse = "; "), .by = c(site_id, pollutant))

method_change_dates <- new_method_starts %>%
  summarise(method_change_date = min(change_date), .by = c(site_id, pollutant))

listed_method_changes <- daily_case_study %>%
  filter(is_post_method_change) %>%
  summarise(change_date = min(date_local), .by = c(site_id, pollutant)) %>%
  mutate(is_listed_method_change = TRUE)

listed_change_check <- listed_method_changes %>%
  semi_join(new_method_starts, by = c("site_id", "pollutant", "change_date"))

print(new_method_starts, n = Inf, width = Inf)

# Same-day FEM minus FRM at PM2.5 sites that ran both
fem_frm_by_site <- daily_case_study_instruments %>%
  filter(pollutant == "PM2.5") %>%
  summarise(fem = mean(value[method_type == "FEM"]), frm = mean(value[method_type == "FRM"]), .by = c(site_id, pollutant, date_local)) %>%
  filter(!is.nan(fem), !is.nan(frm)) %>%
  summarise(n_fem_frm_days = n(), fem_minus_frm_ugm3 = round(mean(fem - frm), 2), .by = c(site_id, pollutant))

print(fem_frm_by_site)

# Missing days between consecutive records. PM2.5 sites sampled every 3rd or 6th day show their schedule as short gaps
site_day_gaps <- daily_case_study %>%
  arrange(pollutant, site_id, date_local) %>%
  mutate(gap_days = as.numeric(date_local - lag(date_local)) - 1, .by = c(pollutant, site_id)) %>%
  mutate(gap_start = lag(date_local) + 1, .by = c(pollutant, site_id))

longest_gaps <- site_day_gaps %>%
  filter(!is.na(gap_days)) %>%
  slice_max(gap_days, n = 1, by = c(pollutant, site_id), with_ties = FALSE) %>%
  select(site_id, pollutant, longest_gap_days = gap_days, longest_gap_start = gap_start)

days_per_year <- daily_case_study %>%
  count(site_id, pollutant, year) %>%
  mutate(year = str_c("days_", year)) %>%
  pivot_wider(names_from = year, values_from = n, values_fill = 0L)

# One row per site and pollutant: coverage, methods, distance and the role in each analysis
study_days <- as.numeric(make_date(max(study_years), 12, 31) - make_date(min(study_years), 1, 1)) + 1

site_inventory <- daily_case_study %>%
  summarise(
    first_date = min(date_local),
    last_date = max(date_local),
    n_site_days = n(),
    n_years_active = first(n_years_active),
    is_five_year = first(is_five_year),
    max_instruments = max(n_instruments),
    n_collocated_days = sum(n_instruments > 1),
    n_event_days = sum(event_class == "Event"),
    n_fireworks_days = sum(event_class == "Fireworks"),
    .by = c(site_group, region, site_id, local_site_name, pollutant)
  ) %>%
  mutate(pct_study_days = round(100 * n_site_days / study_days, 1))

site_inventory <- site_inventory %>%
  left_join(days_per_year, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(longest_gaps, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(method_history, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(method_change_dates, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(
    select(listed_method_changes, site_id, pollutant, is_listed_method_change),
    by = c("site_id", "pollutant"), relationship = "one-to-one"
  ) %>%
  left_join(fem_frm_by_site, by = c("site_id", "pollutant"), relationship = "one-to-one") %>%
  left_join(
    select(sensitivity_sites, site_id, pollutant, sensitivity_left_out = left_out),
    by = c("site_id", "pollutant"), relationship = "one-to-one"
  ) %>%
  left_join(
    select(houston_distances, site_id, km_to_channel, distance_band, in_transition_band, in_memo_list, memo_site_group),
    by = "site_id", relationship = "many-to-one"
  )

site_inventory <- site_inventory %>%
  mutate(is_listed_method_change = coalesce(is_listed_method_change, FALSE)) %>%
  mutate(n_fem_frm_days = coalesce(n_fem_frm_days, 0L)) %>%
  mutate(in_transition_band = coalesce(in_transition_band, FALSE)) %>%
  mutate(in_memo_list = coalesce(in_memo_list, FALSE)) %>%
  mutate(memo_site_group = if_else(region == "Houston", memo_site_group, "Dallas-Fort Worth")) %>%
  mutate(is_near_road = site_id %in% near_road_ids) %>%
  mutate(has_relocation = site_id %in% relocations$site_id)

site_inventory <- site_inventory %>%
  mutate(
    analysis_role = case_when(
      is_five_year ~ "Main",
      pollutant == "PM2.5" & site_id %in% four_year_pm25_ids ~ "4-year PM2.5 sensitivity",
      pollutant == "NO2" & site_id %in% four_year_no2_ids ~ "4-year NO2 sensitivity",
      .default = "Inventory only"
    )
  )

site_inventory <- site_inventory %>%
  select(
    site_group, region, site_id, local_site_name, pollutant, analysis_role, is_five_year, n_years_active,
    first_date, last_date, n_site_days, pct_study_days, starts_with("days_"), longest_gap_days, longest_gap_start,
    max_instruments, n_collocated_days, n_fem_frm_days, fem_minus_frm_ugm3, method_history, method_change_date,
    is_listed_method_change, is_near_road, sensitivity_left_out, has_relocation, km_to_channel, distance_band,
    in_transition_band, in_memo_list, memo_site_group, n_event_days, n_fireworks_days
  ) %>%
  arrange(site_group, pollutant, local_site_name)

site_inventory %>%
  select(site_group, local_site_name, pollutant, analysis_role, n_years_active, pct_study_days, longest_gap_days, km_to_channel) %>%
  print(n = Inf, width = Inf)

unlisted_change_roles <- site_inventory %>%
  filter(!is.na(method_change_date), !is_listed_method_change)

four_year_check <- site_inventory %>%
  filter(pollutant == "PM2.5", site_id %in% four_year_pm25_ids)

four_year_no2_check <- site_inventory %>%
  filter(pollutant == "NO2", site_id %in% four_year_no2_ids)

transition_main_rows <- site_inventory %>%
  filter(analysis_role == "Main", in_transition_band) %>%
  transmute(key = str_c(site_id, " ", pollutant))

stopifnot(
  "One row per site and pollutant" = nrow(distinct(site_inventory, site_id, pollutant)) == nrow(site_inventory),
  "33 sites and 68 site-pollutants" = n_distinct(site_inventory$site_id) == 33 && nrow(site_inventory) == 68,
  "The inventory holds every site-day" = sum(site_inventory$n_site_days) == nrow(daily_case_study),
  "Days per year add up to site-days" =
    all(rowSums(select(site_inventory, starts_with("days_"))) == site_inventory$n_site_days),
  "Each listed method change starts on a new method in the instrument data" = nrow(listed_change_check) == nrow(listed_method_changes),
  "Nine site-pollutants start a new method during the study" = nrow(distinct(new_method_starts, site_id, pollutant)) == 9,
  "Every unlisted method change is at a site without five years" = !any(unlisted_change_roles$is_five_year),
  "Every four-year PM2.5 site has four years" = nrow(four_year_check) == 5 && all(four_year_check$n_years_active == 4),
  "Every four-year NO2 site has four years" = nrow(four_year_no2_check) == 7 && all(four_year_no2_check$n_years_active == 4),
  "The transition check removes North Wayside, Harvard Street, Monroe and Baytown Garth ozone and Harvard Street NO2" =
    setequal(
      transition_main_rows$key,
      c("48-201-0046 Ozone", "48-201-0417 Ozone", "48-201-0062 Ozone", "48-201-1017 Ozone", "48-201-0417 NO2")
    ),
  "Dallas-Fort Worth sites have no channel distance" = all(is.na(site_inventory$km_to_channel[site_inventory$region != "Houston"]))
)

# Sites per group in each site set: main five-year sites, without the transition band, grouped by the memo list, and with
# the four-year PM2.5 sites
memo_set_counts <- site_inventory %>%
  filter(analysis_role == "Main") %>%
  mutate(site_group = factor(memo_site_group, levels = names(site_group_colours))) %>%
  count(pollutant, site_group, name = "memo_grouping")

site_set_counts <- site_inventory %>%
  summarise(
    main = sum(analysis_role == "Main"),
    transition_check = sum(analysis_role == "Main" & !in_transition_band),
    with_four_year_sites = sum(analysis_role != "Inventory only"),
    main_site_days = sum(n_site_days[analysis_role == "Main"]),
    .by = c(pollutant, site_group)
  ) %>%
  left_join(memo_set_counts, by = c("pollutant", "site_group"), relationship = "one-to-one") %>%
  mutate(memo_grouping = coalesce(memo_grouping, 0L)) %>%
  relocate(memo_grouping, .after = transition_check) %>%
  arrange(pollutant, site_group)

print(site_set_counts)

# Days on which every group has at least one five-year site, so same-day comparisons stay balanced
groups_per_pollutant <- site_set_counts %>%
  filter(main > 0) %>%
  count(pollutant, name = "n_groups")

same_day_coverage <- daily_case_study %>%
  filter(is_five_year) %>%
  distinct(pollutant, site_group, date_local) %>%
  count(pollutant, date_local, name = "groups_reporting") %>%
  inner_join(groups_per_pollutant, by = "pollutant", relationship = "many-to-one") %>%
  summarise(days_every_group = sum(groups_reporting == n_groups), n_groups = first(n_groups), .by = pollutant)

print(same_day_coverage)

# The thinnest site-year and the share of site-months that pass the 75% rule, per group
site_year_completeness <- daily_case_study %>%
  filter(is_five_year) %>%
  count(pollutant, site_group, site_id, year) %>%
  summarise(min_days_in_site_year = min(n), median_days_in_site_year = median(n), .by = c(pollutant, site_group))

site_month_completeness <- daily_case_study_months %>%
  summarise(n_site_months = n(), pct_complete = round(100 * mean(is_complete), 1), .by = c(pollutant, site_group))

site_year_completeness %>%
  left_join(site_month_completeness, by = c("pollutant", "site_group"), relationship = "one-to-one") %>%
  arrange(pollutant, site_group) %>%
  print()

stopifnot(
  "Main five-year sites per group: PM2.5 3, 1, 3; ozone 6, 10, 6; NO2 4, 3, 4; SO2 3, 1, 0" =
    identical(site_set_counts$main, c(3L, 1L, 3L, 6L, 10L, 6L, 4L, 3L, 4L, 3L, 1L, 0L)),
  "Without the transition band: ozone 6, 6, 6 and NO2 4, 2, 4" =
    identical(site_set_counts$transition_check[4:9], c(6L, 6L, 6L, 4L, 2L, 4L)),
  "The memo list gives the old groups: PM2.5 2, 2, 3; ozone 7, 9, 6" = identical(site_set_counts$memo_grouping[1:6], c(2L, 2L, 3L, 7L, 9L, 6L)),
  "The four-year PM2.5 set gives 4, 3 and 5 PM2.5 sites" = identical(site_set_counts$with_four_year_sites[1:3], c(4L, 3L, 5L)),
  "The four-year NO2 set gives 6, 4 and 8 NO2 sites" = identical(site_set_counts$with_four_year_sites[7:9], c(6L, 4L, 8L)),
  "Every group reports on at least 95% of days for each pollutant" = all(same_day_coverage$days_every_group >= 0.95 * study_days)
)

# Figure 2B.1: when each site reported, where methods changed, and how far each Houston site sits from the Ship Channel
short_site_name <- function(local_site_name) {
  local_site_name %>%
    str_remove("^Houston ") %>%
    str_replace("Fort Worth California Parkway North", "California Pkwy North") %>%
    str_remove(" Executive$") %>%
    str_remove(" Elementary$")
}

timeline_rows <- site_inventory %>%
  filter(analysis_role != "Inventory only") %>%
  mutate(short_name = short_site_name(local_site_name)) %>%
  arrange(pollutant, site_group, short_name) %>%
  mutate(row_key = str_c(pollutant, "|", short_name)) %>%
  mutate(row_key = factor(row_key, levels = rev(row_key))) %>%
  mutate(bar_colour = if_else(analysis_role == "Main", unname(site_group_colours[as.character(site_group)]), chart_fills[["other"]])) %>%
  select(site_id, pollutant, site_group, row_key, bar_colour)

coverage_runs <- site_day_gaps %>%
  semi_join(timeline_rows, by = c("site_id", "pollutant")) %>%
  mutate(is_new_run = coalesce(gap_days > long_gap_days, TRUE)) %>%
  mutate(run_id = cumsum(is_new_run), .by = c(pollutant, site_id)) %>%
  summarise(run_start = min(date_local), run_end = max(date_local), .by = c(pollutant, site_id, run_id)) %>%
  inner_join(timeline_rows, by = c("site_id", "pollutant"), relationship = "many-to-one")

method_change_marks <- new_method_starts %>%
  inner_join(timeline_rows, by = c("site_id", "pollutant"), relationship = "many-to-one")

relocation_marks <- relocations %>%
  inner_join(timeline_rows, by = "site_id", relationship = "one-to-many")

study_start <- make_date(min(study_years), 1, 1)

study_end <- make_date(max(study_years), 12, 31)

stopifnot(
  "One timeline row per site and pollutant" = !anyDuplicated(timeline_rows$row_key),
  "56 timeline rows: 44 main, 5 four-year PM2.5 and 7 four-year NO2" = nrow(timeline_rows) == 56
)

timeline_panel <- ggplot(coverage_runs) +
  geom_segment(aes(x = run_start, xend = run_end + 1, y = row_key, yend = row_key, colour = bar_colour), linewidth = 1.3) +
  geom_point(data = method_change_marks, aes(change_date, row_key), shape = "|", size = 2.4, colour = chart_ink[["primary"]]) +
  geom_point(data = relocation_marks, aes(relocation_date, row_key), shape = "|", size = 2.4, colour = chart_fills[["accent"]]) +
  facet_grid(pollutant ~ ., scales = "free_y", space = "free_y") +
  scale_colour_identity() +
  scale_x_date(
    limits = c(study_start, study_end + 1), breaks = make_date(study_years, 1, 1), labels = \(x) year(x),
    expand = expansion(mult = 0.01)
  ) +
  scale_y_discrete(labels = \(x) str_remove(x, "^[^|]*\\|")) +
  labs(title = "01  DATA COVERAGE", subtitle = "Days reported by each site", x = NULL, y = NULL) +
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

distance_plot <- site_inventory %>%
  filter(region == "Houston") %>%
  distinct(site_id, local_site_name, site_group, km_to_channel, in_transition_band) %>%
  mutate(short_name = short_site_name(local_site_name)) %>%
  mutate(short_name = reorder(short_name, -km_to_channel)) %>%
  mutate(km_label = sprintf("%.1f", km_to_channel))

transition_names <- as.character(distance_plot$short_name[distance_plot$in_transition_band])

distance_panel <- ggplot(distance_plot, aes(km_to_channel, short_name)) +
  annotate("rect", xmin = ship_channel_km, xmax = transition_km, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
  annotate(
    "text", x = ship_channel_km, y = -Inf, label = str_c(ship_channel_km, " KM"), hjust = -0.12, vjust = -0.8,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_ink[["muted"]]
  ) +
  geom_point(aes(colour = site_group), size = 1.7) +
  geom_text(
    aes(label = km_label), hjust = -0.45,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_ink[["muted"]]
  ) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(limits = c(0, 55), breaks = seq(0, 50, 10), expand = expansion(mult = c(0, 0.02))) +
  scale_y_discrete(
    labels = \(labels) parse(text = if_else(labels %in% transition_names, sprintf('bold("%s")', labels), sprintf('"%s"', labels)))
  ) +
  labs(title = "02  DISTANCE", subtitle = "Km to the land-cut Ship Channel", x = NULL, y = NULL) +
  coord_cartesian(clip = "off") +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 6.3)
  )

paired_pollutants <- same_day_coverage %>%
  filter(n_groups == 3)

sites_header <- chart_header(
  sprintf("FIGURE 2B.1  /  CASE-STUDY SITES  /  %s TO %s", min(study_years), max(study_years)),
  sprintf("Nine sites sit within %s km of the Ship Channel", ship_channel_km),
  sprintf(
    str_c(
      "They form the Ship Channel group; the nearest other site, %s, is %.1f km away.\n",
      "All three groups report on %s to %s of %s days for PM2.5, ozone and NO2."
    ),
    short_site_name(nearest_other_site$local_site_name), nearest_other_site$km_to_channel,
    comma(min(paired_pollutants$days_every_group)), comma(max(paired_pollutants$days_every_group)), comma(study_days)
  ),
  key = tribble(
    ~mark,    ~colour,                                     ~label,
    "square", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "square", site_group_colours[["Houston other"]],        "Houston other",
    "square", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",
    "square", chart_fills[["other"]],                       "4-year check"
  )
)

sites_footer <- chart_footer(str_c(
  "EPA AQS daily data, Harris, Dallas and Tarrant counties. Panel 01: five-year sites and the 4-year checks; bars\n",
  "break at gaps over ", long_gap_days, " days, black ticks mark a new method and teal ticks the Deer Park #2 move. Panel 02:\n",
  "distance to the land-cut channel (USACE). Bold sites in the shaded ", transition_band, " band are left out in one check."
))

stopifnot(
  "Three groups report together for PM2.5, ozone and NO2" = setequal(as.character(paired_pollutants$pollutant), c("PM2.5", "Ozone", "NO2"))
)

sites_figure <- chart_compose(sites_header, list(timeline_panel, distance_panel), sites_footer, widths = c(1.6, 1))

dir.create(here("figures", "phase2"), recursive = TRUE, showWarnings = FALSE)

sites_figure_path <- here("figures", "phase2", "2b.01_sites.png")

save_started <- Sys.time()

ggsave(sites_figure_path, sites_figure, width = 6.5, height = 9.4, dpi = 300)

stopifnot(
  "2b.01_sites.png was written (close any viewer of it and rerun this step)" =
    file.mtime(sites_figure_path) >= save_started - 2
)

# The inventory is saved now as a CSV record, so it can be opened while later sections are built
inventory_records <- list(
  case_study_site_inventory = site_inventory
)

save_records(inventory_records, records_dir)

inventory_dictionary <- tribble(
  ~table,                      ~column,                     ~description,
  "case_study_site_inventory", "site_group",                "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "case_study_site_inventory", "region",                    "Houston or Dallas-Fort Worth",
  "case_study_site_inventory", "site_id",                   "AQS site ID: state-county-site",
  "case_study_site_inventory", "local_site_name",           "Site name given by the reporting agency",
  "case_study_site_inventory", "pollutant",                 "PM2.5, Ozone, NO2 or SO2",
  "case_study_site_inventory", "analysis_role",             "Main (five-year site), 4-year PM2.5 or NO2 sensitivity, or Inventory only",
  "case_study_site_inventory", "is_five_year",              "TRUE when the site has all five study years for the pollutant",
  "case_study_site_inventory", "n_years_active",            "Study years (0 to 5) that met the 75% completeness rule",
  "case_study_site_inventory", "first_date",                "First day with data",
  "case_study_site_inventory", "last_date",                 "Last day with data",
  "case_study_site_inventory", "n_site_days",               "Days with data",
  "case_study_site_inventory", "pct_study_days",            "Days with data as a share of the 1,826 study days",
  "case_study_site_inventory", "days_2021",                 "Days with data in 2021",
  "case_study_site_inventory", "days_2022",                 "Days with data in 2022",
  "case_study_site_inventory", "days_2023",                 "Days with data in 2023",
  "case_study_site_inventory", "days_2024",                 "Days with data in 2024",
  "case_study_site_inventory", "days_2025",                 "Days with data in 2025",
  "case_study_site_inventory", "longest_gap_days",          "Longest run of missing days between records, incl. days off a 1-in-3 or 1-in-6 schedule",
  "case_study_site_inventory", "longest_gap_start",         "First missing day of the longest gap",
  "case_study_site_inventory", "max_instruments",           "Most instruments averaged on one day",
  "case_study_site_inventory", "n_collocated_days",         "Days averaged over more than one instrument",
  "case_study_site_inventory", "n_fem_frm_days",            "PM2.5 days with both an FEM and an FRM reading",
  "case_study_site_inventory", "fem_minus_frm_ugm3",        "Mean FEM minus FRM on those days, µg/m³; NA without paired days",
  "case_study_site_inventory", "method_history",            "Each instrument's method type, AQS method code, POC and dates",
  "case_study_site_inventory", "method_change_date",        "First day of a method that began over 30 days after the site's first day; NA if none",
  "case_study_site_inventory", "is_listed_method_change",   "TRUE when 2a flags the change (is_post_method_change in daily_case_study)",
  "case_study_site_inventory", "is_near_road",              "TRUE for the four near-road sites",
  "case_study_site_inventory", "sensitivity_left_out",      "Whole site or Days after the method change in the with-and-without checks; else NA",
  "case_study_site_inventory", "has_relocation",            "TRUE for Houston Deer Park #2, which moved on 2025-05-30",
  "case_study_site_inventory", "km_to_channel",             "Distance to the land-cut Ship Channel in km, from 1c; NA in Dallas-Fort Worth",
  "case_study_site_inventory", "distance_band",             "Within 7.5 km, 7.5 to 15 km or Over 15 km from the channel; NA in Dallas-Fort Worth",
  "case_study_site_inventory", "in_transition_band",        "TRUE for Houston other sites 7.5 to 15 km from the channel; left out in one check",
  "case_study_site_inventory", "in_memo_list",              "TRUE for sites on the TCEQ Region 12 memo list plus Park Place and Baytown Garth",
  "case_study_site_inventory", "memo_site_group",           "Group under the memo list, used in the memo-grouping check",
  "case_study_site_inventory", "n_event_days",              "Days in an events.csv window",
  "case_study_site_inventory", "n_fireworks_days",          "Fireworks days (PM2.5 only)"
)

# Stops on a saved column without a description, or a description of a column that was not saved
inventory_dictionary <- document_tables(inventory_records, inventory_dictionary)

replace_own_rows(inventory_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 2. OZONE ----
# Five-year ozone sites. A day's value is its highest 8-hour mean in ppm, truncated to 3 decimals as Appendix U
# specifies, and the day exceeds when that is above the 0.070 ppm level
ozone_level <- naaqs$level[naaqs$pollutant == "Ozone"]

ozone_digits <- naaqs$digits[naaqs$pollutant == "Ozone"]

site_roles <- site_inventory %>%
  select(site_id, pollutant, in_transition_band, memo_site_group, sensitivity_left_out, km_to_channel)

ozone_days <- daily_case_study %>%
  filter(pollutant == "Ozone", is_five_year) %>%
  left_join(site_roles, by = c("site_id", "pollutant"), relationship = "many-to-one") %>%
  mutate(value_truncated = truncate_to(value, ozone_digits)) %>%
  mutate(is_exceedance = value_truncated > ozone_level)

stopifnot(
  "Six, ten and six five-year ozone sites" =
    identical(as.integer(table(distinct(ozone_days, site_id, site_group)$site_group)), c(6L, 10L, 6L)),
  "Ozone values are in ppm" = all(ozone_days$units_of_measure == "Parts per million"),
  "Ozone values sit between -0.005 and 0.2 ppm (small negatives are instrument noise, kept as reported)" =
    all(between(ozone_days$value, -0.005, 0.2))
)

# The same site-days under each check, stacked with a site_set label. Reused in sections 3 to 5
site_set_levels <- c(
  "Main",
  "Without the transition band",
  "Memo-list groups",
  "Without days after method changes",
  "Without whole-site checks",
  "Without Deer Park #2 after its move",
  "Without event and fireworks days",
  "With 4-year sites",
  "At least half of each group's sites"
)

site_set_versions <- function(site_days) {
  has_method_check <- any(site_days$sensitivity_left_out == "Days after the method change" & site_days$is_post_method_change, na.rm = TRUE)
  has_whole_site_check <- any(site_days$sensitivity_left_out == "Whole site", na.rm = TRUE)
  versions <- list(
    site_days %>%
      mutate(site_set = "Main"),
    site_days %>%
      filter(!in_transition_band) %>%
      mutate(site_set = "Without the transition band"),
    site_days %>%
      mutate(site_group = factor(memo_site_group, levels = names(site_group_colours))) %>%
      mutate(site_set = "Memo-list groups"),
    if (has_method_check) {
      site_days %>%
        filter(!(coalesce(sensitivity_left_out == "Days after the method change", FALSE) & is_post_method_change)) %>%
        mutate(site_set = "Without days after method changes")
    },
    if (has_whole_site_check) {
      site_days %>%
        filter(!coalesce(sensitivity_left_out == "Whole site", FALSE)) %>%
        mutate(site_set = "Without whole-site checks")
    },
    site_days %>%
      filter(!is_post_relocation) %>%
      mutate(site_set = "Without Deer Park #2 after its move")
  )
  bind_rows(versions) %>%
    mutate(site_set = factor(site_set, levels = site_set_levels))
}

ozone_site_sets <- site_set_versions(ozone_days)

# Exceedance days per site per year, by group and check
ozone_by_group <- ozone_site_sets %>%
  summarise(
    n_sites = n_distinct(site_id),
    n_site_days = n(),
    n_exceedance_days = sum(is_exceedance),
    .by = c(site_set, site_group, year)
  ) %>%
  mutate(days_per_site = n_exceedance_days / n_sites) %>%
  mutate(rate_per_1000 = 1000 * n_exceedance_days / n_site_days) %>%
  arrange(site_set, site_group, year)

ozone_by_group %>%
  filter(site_set == "Main") %>%
  mutate(days_per_site = round(days_per_site, 1)) %>%
  select(site_group, year, days_per_site) %>%
  pivot_wider(names_from = year, values_from = days_per_site) %>%
  print()

# Each check side by side: five-year mean days per site, and the years in which the Ship Channel is lowest
ozone_check_summary <- ozone_by_group %>%
  mutate(rank_in_year = rank(days_per_site, ties.method = "min"), .by = c(site_set, year)) %>%
  summarise(
    mean_days_per_site = round(mean(days_per_site), 1),
    years_lowest = sum(rank_in_year == 1),
    .by = c(site_set, site_group)
  ) %>%
  pivot_wider(names_from = site_group, values_from = c(mean_days_per_site, years_lowest))

print(ozone_check_summary, width = Inf)

ozone_main_by_year <- ozone_by_group %>%
  filter(site_set == "Main") %>%
  mutate(is_highest = days_per_site == max(days_per_site), is_lowest = days_per_site == min(days_per_site), .by = year)

ship_channel_lowest_years <- ozone_main_by_year %>%
  filter(site_group == "Houston Ship Channel", is_lowest) %>%
  nrow()

dfw_highest_years <- ozone_main_by_year %>%
  filter(site_group == "Dallas-Fort Worth", is_highest) %>%
  nrow()

event_day_exceedances <- ozone_days %>%
  filter(is_exceedance, event_class != "None") %>%
  nrow()

cat("Ozone exceedance site-days:", sum(ozone_days$is_exceedance), " on event days:", event_day_exceedances, "\n")

stopifnot(
  "Dallas-Fort Worth has the most exceedance days per site in every year, as the figure title says" =
    dfw_highest_years == length(study_years),
  "The Ship Channel has the fewest in 3 of 5 years, as the subtitle says" = ship_channel_lowest_years == 3,
  "No ozone exceedance falls on an event day, as the subtitle says" = event_day_exceedances == 0,
  "Each check keeps every group" = all(count(ozone_by_group, site_set, year)$n == 3)
)

# Season: exceedance days by calendar month, and the typical year from section 5's site-months of 2a
ozone_monthly_exceedances <- ozone_days %>%
  filter(is_exceedance) %>%
  count(site_group, month, name = "n_exceedance_days") %>%
  complete(site_group, month, fill = list(n_exceedance_days = 0L))

ozone_monthly_exceedances %>%
  pivot_wider(names_from = month, values_from = n_exceedance_days) %>%
  print(width = Inf)

ozone_site_calendar_months <- daily_case_study_months %>%
  filter(pollutant == "Ozone", is_complete) %>%
  summarise(
    n_years = n(),
    mean_value = mean(mean_value),
    mean_ordinary = mean(mean_ordinary, na.rm = TRUE),
    .by = c(pollutant, site_group, site_id, month)
  ) %>%
  mutate(mean_ordinary = if_else(is.nan(mean_ordinary), NA_real_, mean_ordinary))

ozone_monthly_profile <- monthly_profile(ozone_site_calendar_months, c("pollutant", "site_group"))

houston_july_dip <- ozone_monthly_profile %>%
  filter(site_group != "Dallas-Fort Worth") %>%
  summarise(july = median_value[month == "Jul"], june = median_value[month == "Jun"], august = median_value[month == "Aug"], .by = site_group)

print(houston_july_dip)

stopifnot(
  "Twelve months per group" = all(count(ozone_monthly_profile, site_group)$n == 12),
  "Both Houston groups dip in July below June and August, as the subtitle says" =
    all(houston_july_dip$july < houston_july_dip$june & houston_july_dip$july < houston_july_dip$august)
)

# The standard: each site-year's 4th-highest day (naaqs_statistics() in utils.R) and a three-year screen of the same values
ozone_fourth_highest <- naaqs_statistics(ozone_days, naaqs, naaqs_ranks, percentile_ranks) %>%
  left_join(distinct(ozone_days, site_id, site_group, local_site_name), by = "site_id", relationship = "many-to-one")

ozone_three_year <- ozone_fourth_highest %>%
  arrange(site_id, year) %>%
  mutate(three_year_mean = (value_rounded + lag(value_rounded) + lag(value_rounded, 2)) / 3, .by = site_id) %>%
  mutate(three_year_screen = truncate_to(three_year_mean, ozone_digits)) %>%
  select(site_id, year, three_year_screen)

ozone_standard_by_group <- ozone_fourth_highest %>%
  summarise(n_sites = n(), n_above = sum(is_above), median_fourth = median(value_rounded), .by = c(site_group, year)) %>%
  arrange(site_group, year)

print(ozone_standard_by_group)

ozone_fourth_highest %>%
  slice_max(value_rounded, n = 3) %>%
  select(site_group, local_site_name, year, value_rounded) %>%
  print()

stopifnot(
  "One 4th-highest value per five-year site-year" = nrow(ozone_fourth_highest) == 22 * length(study_years),
  "Every 4th-highest value is filled in" = !anyNA(ozone_fourth_highest$value_rounded)
)

# Distance gradient for the Houston sites: five-year mean, mean 4th-highest and exceedance days against km to the channel
ozone_houston_sites <- ozone_days %>%
  filter(region == "Houston") %>%
  summarise(
    mean_ppm = mean(value),
    n_exceedance_days = sum(is_exceedance),
    km_to_channel = first(km_to_channel),
    .by = c(site_id, local_site_name, site_group)
  ) %>%
  left_join(summarise(ozone_fourth_highest, mean_fourth = mean(value_rounded), .by = site_id), by = "site_id", relationship = "one-to-one")

spearman_test <- function(x, y) {
  test <- cor.test(x, y, method = "spearman", exact = FALSE)
  tibble(rho = unname(test$estimate), p_value = test$p.value)
}

ozone_gradient <- bind_rows(
  spearman_test(ozone_houston_sites$km_to_channel, ozone_houston_sites$mean_ppm) %>% mutate(measure = "Five-year mean"),
  spearman_test(ozone_houston_sites$km_to_channel, ozone_houston_sites$mean_fourth) %>% mutate(measure = "Mean 4th-highest"),
  spearman_test(ozone_houston_sites$km_to_channel, ozone_houston_sites$n_exceedance_days) %>% mutate(measure = "Exceedance days")
) %>%
  mutate(n_sites = nrow(ozone_houston_sites))

print(ozone_gradient)

stopifnot(
  "Sixteen Houston ozone sites in the gradient" = nrow(ozone_houston_sites) == 16,
  "Every Houston ozone site has a distance" = !anyNA(ozone_houston_sites$km_to_channel)
)

# Figure 2B.02: exceedance days by year, the typical year, the standard and the distance gradient
year_axis <- scale_x_continuous(breaks = study_years, expand = expansion(mult = c(0.06, 0.1)))

main_ozone_by_group <- ozone_by_group %>%
  filter(site_set == "Main") %>%
  mutate(label = sprintf("%.1f", days_per_site))

exceedance_panel <- ggplot(main_ozone_by_group, aes(year, days_per_site, colour = site_group)) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.3) +
  lapply(names(site_group_colours), \(group) {
    chart_end_label(
      filter(main_ozone_by_group, site_group == group, year == max(year)), "year", "days_per_site", "label",
      colour = site_group_colours[[group]], hjust = -0.35, vjust = 0.5
    )
  }) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  year_axis +
  scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.08))) +
  coord_cartesian(clip = "off") +
  labs(title = "01  EXCEEDANCE DAYS", subtitle = "Days above 0.070 ppm per site per year", x = NULL, y = NULL) +
  theme_aqs()

typical_year_panel <- ggplot(ozone_monthly_profile, aes(month, median_value, colour = site_group, group = site_group)) +
  geom_line(linewidth = 0.7) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_discrete(labels = \(x) str_sub(x, 1, 1)) +
  scale_y_continuous(breaks = seq(0.02, 0.06, 0.01), labels = label_number(accuracy = 0.01)) +
  labs(title = "02  TYPICAL YEAR", subtitle = "Monthly mean of daily peaks (ppm)", x = NULL, y = NULL) +
  theme_aqs()

standard_panel <- ggplot(ozone_fourth_highest, aes(year, value_rounded, colour = site_group)) +
  geom_hline(yintercept = ozone_level, colour = chart_ink[["primary"]], linewidth = 0.4, linetype = "22") +
  geom_point(position = position_dodge(width = 0.6), size = 1.1, alpha = 0.85) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(breaks = study_years) +
  scale_y_continuous(labels = label_number(accuracy = 0.01)) +
  labs(title = "03  STANDARD", subtitle = "4th-highest day per site and year (ppm)", x = NULL, y = NULL) +
  theme_aqs()

gradient_label <- ozone_gradient %>%
  filter(measure == "Five-year mean") %>%
  mutate(label = sprintf("SPEARMAN %.2f  /  P = %.2f  /  %d SITES", rho, p_value, n_sites))

gradient_panel <- ggplot(ozone_houston_sites, aes(km_to_channel, mean_ppm, colour = site_group)) +
  annotate("rect", xmin = ship_channel_km, xmax = transition_km, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
  annotate(
    "text", x = Inf, y = Inf, label = gradient_label$label, hjust = 1, vjust = 1.6,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_ink[["secondary"]]
  ) +
  geom_point(size = 1.8) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(breaks = seq(0, 50, 10)) +
  scale_y_continuous(breaks = seq(0.030, 0.044, 0.002), labels = label_number(accuracy = 0.001), expand = expansion(mult = c(0.08, 0.22))) +
  labs(title = "04  DISTANCE", subtitle = "Five-year mean (ppm) by km to the channel", x = NULL, y = NULL) +
  theme_aqs()

ozone_header <- chart_header(
  sprintf("FIGURE 2B.2  /  OZONE  /  %s TO %s", min(study_years), max(study_years)),
  "DFW tops ozone exceedance days in every year",
  str_c(
    "The Ship Channel has the fewest in 3 of 5 years, consistent with fresh NO using up ozone near its\n",
    "sources. Both Houston groups dip in July, and no exceedance falls on an event day."
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "dot", site_group_colours[["Houston other"]],        "Houston other",
    "dot", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth"
  )
)

ozone_footer <- chart_footer(str_c(
  "EPA AQS daily data, five-year ozone sites (6, 10 and 6). A day exceeds when its 8-hour peak, truncated to 3 decimals,\n",
  "is above 0.070 ppm. Panel 03: the dashed line is the 0.070 standard. Panel 04: Houston sites; the band is ", transition_band, "."
))

ozone_figure <- chart_compose(ozone_header, list(exceedance_panel, typical_year_panel, standard_panel, gradient_panel), ozone_footer)

ozone_figure_path <- here("figures", "phase2", "2b.02_ozone.png")

save_started <- Sys.time()

ggsave(ozone_figure_path, ozone_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2b.02_ozone.png was written (close any viewer of it and rerun this step)" =
    file.mtime(ozone_figure_path) >= save_started - 2
)

# CSV records: one row per site and year, and one per group, year and check
ozone_site_years <- ozone_days %>%
  summarise(n_site_days = n(), n_exceedance_days = sum(is_exceedance), .by = c(site_group, site_id, local_site_name, year)) %>%
  left_join(select(ozone_fourth_highest, site_id, year, fourth_highest_ppm = value_rounded, is_above_standard = is_above),
            by = c("site_id", "year"), relationship = "one-to-one") %>%
  left_join(ozone_three_year, by = c("site_id", "year"), relationship = "one-to-one") %>%
  arrange(site_group, site_id, year)

ozone_records <- list(
  case_study_ozone_site_years = ozone_site_years,
  case_study_ozone_by_group = mutate(ozone_by_group, across(c(days_per_site, rate_per_1000), \(x) round(x, 2)))
)

save_records(ozone_records, records_dir)

ozone_dictionary <- tribble(
  ~table,                        ~column,               ~description,
  "case_study_ozone_site_years", "site_group",          "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "case_study_ozone_site_years", "site_id",             "AQS site ID: state-county-site",
  "case_study_ozone_site_years", "local_site_name",     "Site name given by the reporting agency",
  "case_study_ozone_site_years", "year",                "Calendar year",
  "case_study_ozone_site_years", "n_site_days",         "Days with an ozone value",
  "case_study_ozone_site_years", "n_exceedance_days",   "Days whose 8-hour peak, truncated to 3 decimals, is above 0.070 ppm",
  "case_study_ozone_site_years", "fourth_highest_ppm",  "4th-highest daily 8-hour peak of the year, truncated, ppm",
  "case_study_ozone_site_years", "is_above_standard",   "TRUE when the 4th-highest value is above 0.070 ppm",
  "case_study_ozone_site_years", "three_year_screen",   "Mean of this and the two previous 4th-highest values, truncated; NA in 2021 and 2022",
  "case_study_ozone_by_group",   "site_set",            "Main, or the check applied: transition band, memo groups, method changes, Deer Park #2 move",
  "case_study_ozone_by_group",   "site_group",          "Case-study group under that site set",
  "case_study_ozone_by_group",   "year",                "Calendar year",
  "case_study_ozone_by_group",   "n_sites",             "Five-year ozone sites in the group",
  "case_study_ozone_by_group",   "n_site_days",         "Site-days with an ozone value",
  "case_study_ozone_by_group",   "n_exceedance_days",   "Site-days above 0.070 ppm",
  "case_study_ozone_by_group",   "days_per_site",       "Exceedance days per site in the year",
  "case_study_ozone_by_group",   "rate_per_1000",       "Exceedance days per 1,000 site-days"
)

ozone_dictionary <- document_tables(ozone_records, ozone_dictionary)

replace_own_rows(ozone_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 3. NO2 ----
# Five-year NO2 sites. A day's value is its highest 1-hour reading in ppb. Each site gets a yearly mean of these daily
# peaks, and a group is summarised by the median of its sites' means, so one busy site cannot dominate
no2_level <- naaqs$level[naaqs$pollutant == "NO2"]

no2_days <- daily_case_study %>%
  filter(pollutant == "NO2", is_five_year) %>%
  left_join(site_roles, by = c("site_id", "pollutant"), relationship = "many-to-one")

stopifnot(
  "Four, three and four five-year NO2 sites" =
    identical(as.integer(table(distinct(no2_days, site_id, site_group)$site_group)), c(4L, 3L, 4L)),
  "NO2 values are in ppb" = all(no2_days$units_of_measure == "Parts per billion"),
  "NO2 daily peaks sit between -5 and 150 ppb" = all(between(no2_days$value, -5, 150))
)

# The 4-year check adds the NO2 sites with four of the five years to every group
no2_four_year_days <- daily_case_study %>%
  filter(pollutant == "NO2", site_id %in% four_year_no2_ids) %>%
  left_join(site_roles, by = c("site_id", "pollutant"), relationship = "many-to-one")

stopifnot(
  "Seven four-year NO2 sites, none of them five-year" =
    n_distinct(no2_four_year_days$site_id) == 7 && !any(no2_four_year_days$is_five_year)
)

no2_site_sets <- bind_rows(
  site_set_versions(no2_days) %>%
    mutate(site_set = as.character(site_set)),
  bind_rows(no2_days, no2_four_year_days) %>%
    mutate(site_set = "With 4-year sites")
) %>%
  mutate(site_set = factor(site_set, levels = site_set_levels))

no2_site_year_means <- no2_site_sets %>%
  summarise(site_mean_ppb = mean(value), n_site_days = n(), .by = c(site_set, site_group, site_id, year))

no2_by_group <- no2_site_year_means %>%
  summarise(n_sites = n(), median_site_mean_ppb = median(site_mean_ppb), .by = c(site_set, site_group, year)) %>%
  arrange(site_set, site_group, year)

no2_by_group %>%
  filter(site_set == "Main") %>%
  mutate(median_site_mean_ppb = round(median_site_mean_ppb, 1)) %>%
  select(site_group, year, median_site_mean_ppb) %>%
  pivot_wider(names_from = year, values_from = median_site_mean_ppb) %>%
  print()

# Each check side by side: five-year mean of the group values, and the years in which the Ship Channel is highest
no2_check_summary <- no2_by_group %>%
  mutate(rank_in_year = rank(-median_site_mean_ppb, ties.method = "min"), .by = c(site_set, year)) %>%
  summarise(
    five_year_ppb = round(mean(median_site_mean_ppb), 1),
    years_highest = sum(rank_in_year == 1),
    .by = c(site_set, site_group)
  ) %>%
  pivot_wider(names_from = site_group, values_from = c(five_year_ppb, years_highest))

print(no2_check_summary, width = Inf)

no2_ship_channel_lead <- no2_by_group %>%
  filter(site_group != "Dallas-Fort Worth") %>%
  summarise(five_year_ppb = mean(median_site_mean_ppb), .by = c(site_set, site_group)) %>%
  pivot_wider(names_from = site_group, values_from = five_year_ppb) %>%
  mutate(lead_ppb = `Houston Ship Channel` - `Houston other`)

print(no2_ship_channel_lead)

ship_channel_highest_no2_years <- no2_by_group %>%
  filter(site_set == "Main") %>%
  filter(median_site_mean_ppb == max(median_site_mean_ppb), .by = year) %>%
  filter(site_group == "Houston Ship Channel") %>%
  nrow()

main_lead <- no2_ship_channel_lead$lead_ppb[no2_ship_channel_lead$site_set == "Main"]

method_check_lead <- no2_ship_channel_lead$lead_ppb[no2_ship_channel_lead$site_set == "Without days after method changes"]

stopifnot(
  "The Ship Channel has the highest NO2 in every year, as the figure title says" = ship_channel_highest_no2_years == length(study_years),
  "The Ship Channel lead widens without the days after method changes, as the subtitle says" = method_check_lead > main_lead,
  "Each check keeps every group" = all(count(no2_by_group, site_set, year)$n == 3)
)

# The standard: each site-year's 98th-percentile day (naaqs_statistics() in utils.R), rounded to whole ppb
no2_p98 <- naaqs_statistics(no2_days, naaqs, naaqs_ranks, percentile_ranks) %>%
  left_join(distinct(no2_days, site_id, site_group, local_site_name), by = "site_id", relationship = "many-to-one")

no2_p98 %>%
  summarise(max_p98 = max(value_rounded), median_p98 = median(value_rounded), .by = c(site_group, year)) %>%
  arrange(site_group, year) %>%
  print()

stopifnot(
  "One 98th-percentile value per five-year site-year" = nrow(no2_p98) == 11 * length(study_years),
  "Every site-year stays below the 100 ppb standard, as the subtitle says" = !any(no2_p98$is_above)
)

# Season: the typical year by group, and winter against summer with the partial winters left out
no2_site_calendar_months <- daily_case_study_months %>%
  filter(pollutant == "NO2", is_complete) %>%
  summarise(
    n_years = n(),
    mean_value = mean(mean_value),
    mean_ordinary = mean(mean_ordinary, na.rm = TRUE),
    .by = c(pollutant, site_group, site_id, month)
  ) %>%
  mutate(mean_ordinary = if_else(is.nan(mean_ordinary), NA_real_, mean_ordinary))

no2_monthly_profile <- monthly_profile(no2_site_calendar_months, c("pollutant", "site_group"))

no2_season_ratio <- no2_days %>%
  filter(is_full_season, season %in% c("Winter", "Summer")) %>%
  summarise(site_mean_ppb = mean(value), .by = c(site_group, site_id, season)) %>%
  summarise(median_ppb = median(site_mean_ppb), .by = c(site_group, season)) %>%
  pivot_wider(names_from = season, values_from = median_ppb) %>%
  mutate(winter_to_summer = Winter / Summer)

print(no2_season_ratio)

stopifnot(
  "Twelve months per group" = all(count(no2_monthly_profile, site_group)$n == 12),
  "Winter is higher than summer in every group" = all(no2_season_ratio$winter_to_summer > 1)
)

# Deer Park #2 stepped up in 2024 for an unknown reason (Phase 1 known limit); shown here, with no separate check
no2_days %>%
  filter(local_site_name == "Houston Deer Park #2") %>%
  summarise(mean_daily_peak_ppb = round(mean(value), 1), .by = year) %>%
  print()

# Distance gradient for the Houston sites: five-year mean of the daily peaks against km to the channel
no2_houston_sites <- bind_rows(no2_days, no2_four_year_days) %>%
  filter(region == "Houston") %>%
  summarise(
    mean_ppb = mean(value),
    km_to_channel = first(km_to_channel),
    is_five_year = first(is_five_year),
    .by = c(site_id, local_site_name, site_group)
  )

five_year_houston_no2 <- no2_houston_sites %>%
  filter(is_five_year)

no2_gradient <- bind_rows(
  spearman_test(five_year_houston_no2$km_to_channel, five_year_houston_no2$mean_ppb) %>%
    mutate(site_set = "Five-year sites", n_sites = nrow(five_year_houston_no2)),
  spearman_test(no2_houston_sites$km_to_channel, no2_houston_sites$mean_ppb) %>%
    mutate(site_set = "With 4-year sites", n_sites = nrow(no2_houston_sites))
)

print(no2_gradient)

# Leave-one-out: drop each site in turn, to see whether one site carries the gradient
no2_leave_one_out <- bind_rows(lapply(no2_houston_sites$site_id, \(left_out_id) {
  kept <- filter(no2_houston_sites, site_id != left_out_id)
  spearman_test(kept$km_to_channel, kept$mean_ppb) %>%
    mutate(left_out = no2_houston_sites$local_site_name[no2_houston_sites$site_id == left_out_id])
}))

print(arrange(no2_leave_one_out, p_value), n = Inf)

stopifnot("The gradient stays negative whichever site is left out" = all(no2_leave_one_out$rho < 0))

stopifnot(
  "Seven five-year and ten in all Houston NO2 sites in the gradient" = nrow(five_year_houston_no2) == 7 && nrow(no2_houston_sites) == 10,
  "Every Houston NO2 site has a distance" = !anyNA(no2_houston_sites$km_to_channel)
)

# Figure 2B.3: yearly level by group, the typical year, the standard and the distance gradient
main_no2_by_group <- no2_by_group %>%
  filter(site_set == "Main") %>%
  mutate(label = sprintf("%.1f", median_site_mean_ppb))

no2_year_panel <- ggplot(main_no2_by_group, aes(year, median_site_mean_ppb, colour = site_group)) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.3) +
  lapply(names(site_group_colours), \(group) {
    chart_end_label(
      filter(main_no2_by_group, site_group == group, year == max(year)), "year", "median_site_mean_ppb", "label",
      colour = site_group_colours[[group]], hjust = -0.35, vjust = 0.5
    )
  }) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  year_axis +
  coord_cartesian(clip = "off") +
  labs(title = "01  LEVEL", subtitle = "Mean daily peak, median site (ppb)", x = NULL, y = NULL) +
  theme_aqs()

no2_typical_year_panel <- ggplot(no2_monthly_profile, aes(month, median_value, colour = site_group, group = site_group)) +
  geom_line(linewidth = 0.7) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_discrete(labels = \(x) str_sub(x, 1, 1)) +
  labs(title = "02  TYPICAL YEAR", subtitle = "Monthly mean of daily peaks (ppb)", x = NULL, y = NULL) +
  theme_aqs()

no2_standard_panel <- ggplot(no2_p98, aes(year, value_rounded, colour = site_group)) +
  geom_hline(yintercept = no2_level, colour = chart_ink[["primary"]], linewidth = 0.4, linetype = "22") +
  geom_point(position = position_dodge(width = 0.6), size = 1.1, alpha = 0.85) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(breaks = study_years) +
  scale_y_continuous(limits = c(0, no2_level * 1.05), breaks = seq(0, 100, 25)) +
  labs(title = "03  STANDARD", subtitle = "98th-percentile day per site and year (ppb)", x = NULL, y = NULL) +
  theme_aqs()

no2_gradient_label <- no2_gradient %>%
  mutate(label = sprintf("%s: SPEARMAN %.2f  /  P = %.2f", if_else(site_set == "Five-year sites", "5-YEAR", "WITH 4-YEAR"), rho, p_value)) %>%
  summarise(label = str_c(label, collapse = "\n"))

no2_gradient_panel <- ggplot(no2_houston_sites, aes(km_to_channel, mean_ppb, colour = site_group)) +
  annotate("rect", xmin = ship_channel_km, xmax = transition_km, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
  annotate(
    "text", x = Inf, y = Inf, label = no2_gradient_label$label, hjust = 1, vjust = 1.6,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_ink[["secondary"]]
  ) +
  geom_point(aes(shape = is_five_year), size = 1.8, stroke = 0.9) +
  scale_shape_manual(values = c(`TRUE` = 16, `FALSE` = 1), guide = "none") +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(breaks = seq(0, 50, 10)) +
  scale_y_continuous(breaks = seq(8, 28, 4), expand = expansion(mult = c(0.08, 0.25))) +
  labs(title = "04  DISTANCE", subtitle = "Mean (ppb) by km to the channel", x = NULL, y = NULL) +
  theme_aqs()

no2_header <- chart_header(
  sprintf("FIGURE 2B.3  /  NO2  /  %s TO %s", min(study_years), max(study_years)),
  "Ship Channel NO2 is highest in every year",
  sprintf(
    str_c(
      "Its lead over Houston other grows from %.1f to %.1f ppb without the days after two method changes.\n",
      "Every site stays far below the 100 ppb standard, and winter runs %.1f to %.1f times summer."
    ),
    main_lead, method_check_lead, min(no2_season_ratio$winter_to_summer), max(no2_season_ratio$winter_to_summer)
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "dot", site_group_colours[["Houston other"]],        "Houston other",
    "dot", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth"
  )
)

no2_footer <- chart_footer(str_c(
  "EPA AQS daily data, five-year NO2 sites (4, 3 and 4). Daily peak: highest 1-hour value. Panel 03: the dashed line is the\n",
  "100 ppb standard. Panel 04: Houston sites, hollow points have four of five years; the band is ", transition_band, "."
))

no2_figure <- chart_compose(no2_header, list(no2_year_panel, no2_typical_year_panel, no2_standard_panel, no2_gradient_panel), no2_footer)

no2_figure_path <- here("figures", "phase2", "2b.03_no2.png")

save_started <- Sys.time()

ggsave(no2_figure_path, no2_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2b.03_no2.png was written (close any viewer of it and rerun this step)" =
    file.mtime(no2_figure_path) >= save_started - 2
)

# CSV records: one row per site and year, and one per group, year and check
no2_site_years <- no2_site_year_means %>%
  filter(site_set == "Main") %>%
  select(site_group, site_id, year, n_site_days, mean_daily_peak_ppb = site_mean_ppb) %>%
  left_join(distinct(no2_days, site_id, local_site_name), by = "site_id", relationship = "many-to-one") %>%
  left_join(select(no2_p98, site_id, year, p98_ppb = value_rounded, is_above_standard = is_above), by = c("site_id", "year"),
            relationship = "one-to-one") %>%
  relocate(local_site_name, .after = site_id) %>%
  mutate(mean_daily_peak_ppb = round(mean_daily_peak_ppb, 2)) %>%
  arrange(site_group, site_id, year)

no2_records <- list(
  case_study_no2_site_years = no2_site_years,
  case_study_no2_by_group = mutate(no2_by_group, median_site_mean_ppb = round(median_site_mean_ppb, 2))
)

save_records(no2_records, records_dir)

no2_dictionary <- tribble(
  ~table,                      ~column,                 ~description,
  "case_study_no2_site_years", "site_group",            "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "case_study_no2_site_years", "site_id",               "AQS site ID: state-county-site",
  "case_study_no2_site_years", "local_site_name",       "Site name given by the reporting agency",
  "case_study_no2_site_years", "year",                  "Calendar year",
  "case_study_no2_site_years", "n_site_days",           "Days with an NO2 value",
  "case_study_no2_site_years", "mean_daily_peak_ppb",   "Mean of the daily highest 1-hour values, ppb",
  "case_study_no2_site_years", "p98_ppb",               "98th-percentile daily peak of the year, rounded to whole ppb",
  "case_study_no2_site_years", "is_above_standard",     "TRUE when the 98th-percentile value is above 100 ppb",
  "case_study_no2_by_group",   "site_set",              "Main or a check: transition band, memo groups, method changes, Deer Park #2, 4-year sites",
  "case_study_no2_by_group",   "site_group",            "Case-study group under that site set",
  "case_study_no2_by_group",   "year",                  "Calendar year",
  "case_study_no2_by_group",   "n_sites",               "Five-year NO2 sites in the group with data that year",
  "case_study_no2_by_group",   "median_site_mean_ppb",  "Median across sites of each site's mean daily peak, ppb"
)

no2_dictionary <- document_tables(no2_records, no2_dictionary)

replace_own_rows(no2_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 4. PM2.5 ----
# Five-year PM2.5 sites. A day's value is its 24-hour mean in µg/m³. The annual standard (9.0) is judged on the mean of the
# four quarterly means and the 24-hour standard (35) on the 98th-percentile day, both from naaqs_statistics() in utils.R
pm25_annual_level <- naaqs$level[naaqs$pollutant == "PM2.5" & naaqs$standard == "Annual"]

pm25_daily_level <- naaqs$level[naaqs$pollutant == "PM2.5" & naaqs$standard == "24-hour"]

pm25_days <- daily_case_study %>%
  filter(pollutant == "PM2.5", is_five_year) %>%
  left_join(site_roles, by = c("site_id", "pollutant"), relationship = "many-to-one")

pm25_four_year_days <- daily_case_study %>%
  filter(pollutant == "PM2.5", site_id %in% four_year_pm25_ids) %>%
  left_join(site_roles, by = c("site_id", "pollutant"), relationship = "many-to-one")

stopifnot(
  "Three, one and three five-year PM2.5 sites" =
    identical(as.integer(table(distinct(pm25_days, site_id, site_group)$site_group)), c(3L, 1L, 3L)),
  "Five four-year PM2.5 sites, none of them five-year" =
    n_distinct(pm25_four_year_days$site_id) == 5 && !any(pm25_four_year_days$is_five_year),
  "PM2.5 values are in µg/m³" = all(pm25_days$units_of_measure == "Micrograms/cubic meter (LC)"),
  "PM2.5 daily means sit between -5 and 500 µg/m³" = all(between(pm25_days$value, -5, 500))
)

# The usual checks, plus one without event and fireworks days and one with the four-year sites
pm25_site_sets <- bind_rows(
  site_set_versions(pm25_days) %>%
    mutate(site_set = as.character(site_set)),
  pm25_days %>%
    filter(event_class == "None") %>%
    mutate(site_set = "Without event and fireworks days"),
  bind_rows(pm25_days, pm25_four_year_days) %>%
    mutate(site_set = "With 4-year sites")
) %>%
  mutate(site_set = factor(site_set, levels = site_set_levels))

pm25_statistics <- bind_rows(lapply(levels(droplevels(pm25_site_sets$site_set)), \(set) {
  set_days <- filter(pm25_site_sets, site_set == set)
  naaqs_statistics(set_days, naaqs, naaqs_ranks, percentile_ranks) %>%
    left_join(distinct(set_days, site_id, site_group), by = "site_id", relationship = "many-to-one") %>%
    mutate(site_set = set)
})) %>%
  mutate(site_set = factor(site_set, levels = site_set_levels))

pm25_by_group <- pm25_statistics %>%
  summarise(n_sites = n(), median_value = median(value_rounded), n_above = sum(is_above), .by = c(site_set, standard, site_group, year)) %>%
  arrange(site_set, standard, site_group, year)

pm25_by_group %>%
  filter(site_set == "Main", standard == "Annual") %>%
  mutate(cell = sprintf("%.1f (%d/%d)", median_value, n_above, n_sites)) %>%
  select(site_group, year, cell) %>%
  pivot_wider(names_from = year, values_from = cell) %>%
  print()

# Each check side by side: five-year mean of each group's annual value
pm25_check_summary <- pm25_by_group %>%
  filter(standard == "Annual") %>%
  summarise(five_year_annual = round(mean(median_value), 2), .by = c(site_set, site_group)) %>%
  pivot_wider(names_from = site_group, values_from = five_year_annual)

print(pm25_check_summary, width = Inf)

main_annual <- pm25_statistics %>%
  filter(site_set == "Main", standard == "Annual")

main_annual_by_group <- pm25_by_group %>%
  filter(site_set == "Main", standard == "Annual") %>%
  summarise(five_year_annual = mean(median_value), .by = site_group)

ship_channel_annual <- main_annual_by_group$five_year_annual[main_annual_by_group$site_group == "Houston Ship Channel"]

houston_other_annual <- main_annual_by_group$five_year_annual[main_annual_by_group$site_group == "Houston other"]

four_year_sites_per_group <- pm25_site_sets %>%
  filter(site_set == "With 4-year sites") %>%
  distinct(site_group, site_id) %>%
  count(site_group)

stopifnot(
  "All seven five-year PM2.5 sites were above the annual level in 2023, as the figure title says" =
    sum(main_annual$year == 2023 & main_annual$is_above) == 7,
  "The Ship Channel is not above Houston other on the annual mean, as the subtitle says" = ship_channel_annual <= houston_other_annual,
  "The four-year set gives 4, 3 and 5 PM2.5 sites" = identical(four_year_sites_per_group$n, c(4L, 3L, 5L))
)

# Days above the 24-hour level (rounded to whole µg/m³), split by day class, and the dates that hold most of them
pm25_high_days <- pm25_days %>%
  filter(round_half_up(value, 0) > pm25_daily_level)

pm25_high_by_class <- pm25_high_days %>%
  count(site_group, event_class, name = "n_site_days") %>%
  complete(site_group, event_class, fill = list(n_site_days = 0L))

print(pm25_high_by_class)

pm25_high_dates <- pm25_high_days %>%
  count(date_local, event_name, name = "n_sites", sort = TRUE)

print(head(pm25_high_dates, 8))

top_five_date_days <- sum(head(pm25_high_dates$n_sites, 5))

stopifnot("Five dates hold at least half of the site-days above 35 µg/m³, as the subtitle says" = top_five_date_days >= nrow(pm25_high_days) / 2)

# Season: the typical year by group
pm25_site_calendar_months <- daily_case_study_months %>%
  filter(pollutant == "PM2.5", is_complete) %>%
  summarise(
    n_years = n(),
    mean_value = mean(mean_value),
    mean_ordinary = mean(mean_ordinary, na.rm = TRUE),
    .by = c(pollutant, site_group, site_id, month)
  ) %>%
  mutate(mean_ordinary = if_else(is.nan(mean_ordinary), NA_real_, mean_ordinary))

pm25_monthly_profile <- monthly_profile(pm25_site_calendar_months, c("pollutant", "site_group"))

pm25_peak_months <- pm25_monthly_profile %>%
  slice_max(median_value, n = 1, by = site_group, with_ties = FALSE)

print(pm25_peak_months)

stopifnot("Every group peaks from May to July" = all(pm25_peak_months$month %in% c("May", "Jun", "Jul")))

# Deer Park #2 changed instruments on 2023-03-17 and 2023-07-06. Houston East, which kept one, rises over the same months,
# so the middle period is compared with it before reading a step into it
instrument_periods <- daily_case_study %>%
  filter(pollutant == "PM2.5", local_site_name %in% c("Houston Deer Park #2", "Houston East")) %>%
  mutate(
    period = case_when(
      date_local < ymd("2023-03-17") ~ "1. Before 2023-03-17",
      date_local < ymd("2023-07-06") ~ "2. 2023-03-17 to 07-05",
      .default = "3. From 2023-07-06"
    )
  ) %>%
  summarise(mean_ugm3 = round(mean(value), 2), n_days = n(), .by = c(local_site_name, period)) %>%
  arrange(local_site_name, period)

print(instrument_periods)

# Distance gradient for the Houston sites, five-year and with the four-year sites
pm25_houston_sites <- bind_rows(pm25_days, pm25_four_year_days) %>%
  filter(region == "Houston") %>%
  summarise(
    mean_ugm3 = mean(value),
    km_to_channel = first(km_to_channel),
    is_five_year = first(is_five_year),
    .by = c(site_id, local_site_name, site_group)
  )

five_year_houston_pm25 <- pm25_houston_sites %>%
  filter(is_five_year)

pm25_gradient <- bind_rows(
  spearman_test(five_year_houston_pm25$km_to_channel, five_year_houston_pm25$mean_ugm3) %>%
    mutate(site_set = "Five-year sites", n_sites = nrow(five_year_houston_pm25)),
  spearman_test(pm25_houston_sites$km_to_channel, pm25_houston_sites$mean_ugm3) %>%
    mutate(site_set = "With 4-year sites", n_sites = nrow(pm25_houston_sites))
)

print(pm25_gradient)

stopifnot("Four five-year and seven in all Houston PM2.5 sites in the gradient" = nrow(five_year_houston_pm25) == 4 && nrow(pm25_houston_sites) == 7)

# Figure 2B.4: annual mean against the standard, the typical year, days above 35 by cause, and the distance gradient
main_pm25_annual <- pm25_by_group %>%
  filter(site_set == "Main", standard == "Annual") %>%
  mutate(label = sprintf("%.1f", median_value))

pm25_annual_panel <- ggplot(main_pm25_annual, aes(year, median_value, colour = site_group)) +
  annotate(
    "segment", x = min(study_years) - 0.15, xend = max(study_years) + 0.15, y = pm25_annual_level, yend = pm25_annual_level,
    colour = chart_ink[["primary"]], linewidth = 0.4, linetype = "22"
  ) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.3) +
  lapply(names(site_group_colours), \(group) {
    chart_end_label(
      filter(main_pm25_annual, site_group == group, year == max(year)), "year", "median_value", "label",
      colour = site_group_colours[[group]], hjust = -0.35, vjust = 0.5
    )
  }) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  year_axis +
  coord_cartesian(clip = "off") +
  labs(title = "01  ANNUAL MEAN", subtitle = "Median site (µg/m³); dashed line 9.0", x = NULL, y = NULL) +
  theme_aqs()

pm25_typical_year_panel <- ggplot(pm25_monthly_profile, aes(month, median_value, colour = site_group, group = site_group)) +
  geom_line(linewidth = 0.7) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_discrete(labels = \(x) str_sub(x, 1, 1)) +
  labs(title = "02  TYPICAL YEAR", subtitle = "Monthly mean of daily means (µg/m³)", x = NULL, y = NULL) +
  theme_aqs()

day_class_labels <- c(None = "Ordinary", Event = "Event", Fireworks = "Fireworks")

pm25_high_plot <- pm25_high_by_class %>%
  mutate(day_class = factor(day_class_labels[as.character(event_class)], levels = rev(day_class_labels))) %>%
  mutate(group_label = recode_values(
    as.character(site_group),
    from = names(site_group_colours),
    to = c("Ship Channel", "Houston other", "DFW"),
    unmatched = "error"
  )) %>%
  mutate(group_label = factor(group_label, levels = c("Ship Channel", "Houston other", "DFW")))

pm25_high_totals <- pm25_high_plot %>%
  summarise(n_site_days = sum(n_site_days), .by = group_label)

pm25_high_panel <- ggplot(pm25_high_plot, aes(group_label, n_site_days, fill = day_class)) +
  geom_col(width = 0.5) +
  geom_text(
    data = pm25_high_totals, aes(group_label, n_site_days, label = n_site_days), inherit.aes = FALSE, vjust = -0.6,
    family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt, colour = chart_ink[["secondary"]]
  ) +
  scale_fill_manual(
    values = c(Ordinary = chart_fills[["accent"]], Event = chart_fills[["other"]], Fireworks = "#dcdbd4"),
    breaks = c("Ordinary", "Event", "Fireworks"), name = NULL
  ) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(title = "03  DAYS ABOVE 35", subtitle = "Site-days above the 24-hour level", x = NULL, y = NULL) +
  theme_aqs() +
  theme(axis.text.x = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 7))

pm25_gradient_label <- pm25_gradient %>%
  mutate(label = sprintf("%s: SPEARMAN %.2f  /  P = %.2f", if_else(site_set == "Five-year sites", "5-YEAR", "WITH 4-YEAR"), rho, p_value)) %>%
  summarise(label = str_c(label, collapse = "\n"))

pm25_gradient_panel <- ggplot(pm25_houston_sites, aes(km_to_channel, mean_ugm3, colour = site_group)) +
  annotate("rect", xmin = ship_channel_km, xmax = transition_km, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
  annotate(
    "text", x = Inf, y = Inf, label = pm25_gradient_label$label, hjust = 1, vjust = 1.6,
    family = chart_fonts[["mono"]], size = (chart_sizes[["label"]] - 0.7) / .pt, colour = chart_ink[["secondary"]]
  ) +
  geom_point(aes(shape = is_five_year), size = 1.8, stroke = 0.9) +
  scale_shape_manual(values = c(`TRUE` = 16, `FALSE` = 1), guide = "none") +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(breaks = seq(0, 40, 10)) +
  scale_y_continuous(expand = expansion(mult = c(0.08, 0.9))) +
  labs(title = "04  DISTANCE", subtitle = "Mean (µg/m³) by km to the channel", x = NULL, y = NULL) +
  theme_aqs()

pm25_header <- chart_header(
  sprintf("FIGURE 2B.4  /  PM2.5  /  %s TO %s", min(study_years), max(study_years)),
  "All PM2.5 sites topped the annual level in 2023",
  sprintf(
    str_c(
      "Houston other averages %.1f µg/m³ and the Ship Channel %.1f, consistent with regional PM2.5.\n",
      "%d of the %d site-days above 35 µg/m³ fall on five dates."
    ),
    houston_other_annual, ship_channel_annual, top_five_date_days, nrow(pm25_high_days)
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "dot", site_group_colours[["Houston other"]],        "Houston other",
    "dot", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth"
  )
)

pm25_footer <- chart_footer(str_c(
  "EPA AQS daily data, five-year PM2.5 sites (3, 1 and 3). Annual mean: mean of the four quarterly means, rounded to 0.1.\n",
  "Panel 04: Houston sites, hollow points have four of five years; the band is ", transition_band, "."
))

pm25_figure <- chart_compose(pm25_header, list(pm25_annual_panel, pm25_typical_year_panel, pm25_high_panel, pm25_gradient_panel), pm25_footer)

pm25_figure_path <- here("figures", "phase2", "2b.04_pm25.png")

save_started <- Sys.time()

ggsave(pm25_figure_path, pm25_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2b.04_pm25.png was written (close any viewer of it and rerun this step)" =
    file.mtime(pm25_figure_path) >= save_started - 2
)

# CSV records: one row per site and year (five-year and four-year sites), and one per check, standard, group and year
pm25_site_years <- bind_rows(pm25_days, pm25_four_year_days) %>%
  summarise(
    n_site_days = n(),
    n_days_above_35 = sum(round_half_up(value, 0) > pm25_daily_level),
    .by = c(site_group, site_id, local_site_name, is_five_year, year)
  ) %>%
  left_join(
    pm25_statistics %>%
      filter(site_set == "With 4-year sites", standard == "Annual") %>%
      select(site_id, year, annual_mean_ugm3 = value_rounded, is_above_annual = is_above),
    by = c("site_id", "year"), relationship = "one-to-one"
  ) %>%
  left_join(
    pm25_statistics %>%
      filter(site_set == "With 4-year sites", standard == "24-hour") %>%
      select(site_id, year, p98_ugm3 = value_rounded, is_above_24_hour = is_above),
    by = c("site_id", "year"), relationship = "one-to-one"
  ) %>%
  arrange(site_group, site_id, year)

pm25_records <- list(
  case_study_pm25_site_years = pm25_site_years,
  case_study_pm25_by_group = mutate(pm25_by_group, median_value = round(median_value, 2))
)

save_records(pm25_records, records_dir)

pm25_dictionary <- tribble(
  ~table,                       ~column,            ~description,
  "case_study_pm25_site_years", "site_group",       "Case-study group: Houston Ship Channel, Houston other or Dallas-Fort Worth",
  "case_study_pm25_site_years", "site_id",          "AQS site ID: state-county-site",
  "case_study_pm25_site_years", "local_site_name",  "Site name given by the reporting agency",
  "case_study_pm25_site_years", "is_five_year",     "TRUE for five-year sites; FALSE for the four-year sites in the 4-year check",
  "case_study_pm25_site_years", "year",             "Calendar year",
  "case_study_pm25_site_years", "n_site_days",      "Days with a PM2.5 value",
  "case_study_pm25_site_years", "n_days_above_35",  "Days whose 24-hour mean, rounded to whole µg/m³, is above 35",
  "case_study_pm25_site_years", "annual_mean_ugm3", "Mean of the four quarterly means, rounded to 0.1 µg/m³; NA without all four quarters",
  "case_study_pm25_site_years", "is_above_annual",  "TRUE when the annual mean is above 9.0 µg/m³",
  "case_study_pm25_site_years", "p98_ugm3",         "98th-percentile day of the year, rounded to whole µg/m³",
  "case_study_pm25_site_years", "is_above_24_hour", "TRUE when the 98th-percentile value is above 35 µg/m³",
  "case_study_pm25_by_group",   "site_set",         "Main or a check: transition band, memo groups, whole-site, Deer Park #2, events, 4-year sites",
  "case_study_pm25_by_group",   "standard",         "Annual (mean of quarterly means) or 24-hour (98th percentile)",
  "case_study_pm25_by_group",   "site_group",       "Case-study group under that site set",
  "case_study_pm25_by_group",   "year",             "Calendar year",
  "case_study_pm25_by_group",   "n_sites",          "Sites with a value for that standard and year",
  "case_study_pm25_by_group",   "median_value",     "Median site value, µg/m³",
  "case_study_pm25_by_group",   "n_above",          "Sites above the level"
)

pm25_dictionary <- document_tables(pm25_records, pm25_dictionary)

replace_own_rows(pm25_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 5. SO2 ----
# Five-year SO2 sites: three at the Ship Channel and Croquet in Houston other; Dallas-Fort Worth has none. SO2 sits near
# zero on most days, so it is read through spike days (daily 1-hour peak at or above 5, 10 or 20 ppb, all above every
# monitor's 2 ppb detection limit) and never through a mean
so2_level <- naaqs$level[naaqs$pollutant == "SO2"]

so2_spike_ppb <- c(5, 10, 20)

so2_days <- daily_case_study %>%
  filter(pollutant == "SO2", is_five_year) %>%
  left_join(site_roles, by = c("site_id", "pollutant"), relationship = "many-to-one") %>%
  mutate(is_spike = value >= so2_spike_ppb[1])

stopifnot(
  "Three Ship Channel SO2 sites and one in Houston other" =
    identical(as.integer(table(distinct(so2_days, site_id, site_group)$site_group)), c(3L, 1L, 0L)),
  "SO2 values are in ppb" = all(so2_days$units_of_measure == "Parts per billion"),
  "SO2 daily peaks sit between -5 and 150 ppb" = all(between(so2_days$value, -5, 150))
)

# Spike days per site and year at each threshold
so2_spikes_by_site <- so2_days %>%
  summarise(
    n_site_days = n(),
    n_days_ge5 = sum(value >= so2_spike_ppb[1]),
    n_days_ge10 = sum(value >= so2_spike_ppb[2]),
    n_days_ge20 = sum(value >= so2_spike_ppb[3]),
    .by = c(site_group, site_id, local_site_name, year)
  )

so2_spikes_by_site %>%
  select(local_site_name, year, n_days_ge5, n_days_ge10, n_days_ge20) %>%
  pivot_longer(starts_with("n_days"), names_to = "threshold", values_to = "n_days") %>%
  pivot_wider(names_from = year, values_from = n_days) %>%
  arrange(threshold, local_site_name) %>%
  print(n = Inf)

so2_site_totals <- so2_spikes_by_site %>%
  summarise(n_spike_days = sum(n_days_ge5), .by = c(site_group, site_id, local_site_name)) %>%
  arrange(desc(n_spike_days))

print(so2_site_totals)

# Spike days per site in each group and check
so2_site_sets <- site_set_versions(so2_days)

so2_by_group <- so2_site_sets %>%
  summarise(n_spike_days = sum(is_spike), n_site_days = n(), .by = c(site_set, site_group, site_id, year)) %>%
  summarise(n_sites = n(), n_site_days = sum(n_site_days), spike_days_per_site = mean(n_spike_days), .by = c(site_set, site_group, year)) %>%
  arrange(site_set, site_group, year)

so2_by_group %>%
  mutate(spike_days_per_site = round(spike_days_per_site, 1)) %>%
  select(site_set, site_group, year, spike_days_per_site) %>%
  pivot_wider(names_from = year, values_from = spike_days_per_site) %>%
  print(n = Inf)

so2_main_by_year <- so2_by_group %>%
  filter(site_set == "Main") %>%
  select(site_group, year, spike_days_per_site) %>%
  pivot_wider(names_from = site_group, values_from = spike_days_per_site)

croquet_higher_years <- sum(so2_main_by_year$`Houston other` > so2_main_by_year$`Houston Ship Channel`)

so2_check_years <- so2_by_group %>%
  select(site_set, site_group, year, spike_days_per_site) %>%
  pivot_wider(names_from = site_group, values_from = spike_days_per_site) %>%
  summarise(years_croquet_higher = sum(`Houston other` > `Houston Ship Channel`), .by = site_set)

print(so2_check_years)

stopifnot(
  "Park Place and Croquet have the most spike days, as the figure title says" =
    setequal(head(so2_site_totals$local_site_name, 2), c("Park Place", "Houston Croquet")),
  "Croquet has more spike days than the Ship Channel site average in every year, as the subtitle says" =
    croquet_higher_years == length(study_years),
  "Every check keeps Croquet above the Ship Channel average in every year" = all(so2_check_years$years_croquet_higher == length(study_years))
)

# Season: share of days at or above 5 ppb, by site, with the partial winters left out
so2_seasons <- so2_days %>%
  filter(is_full_season) %>%
  summarise(pct_spike_days = 100 * mean(is_spike), .by = c(site_group, local_site_name, season))

so2_seasons %>%
  mutate(pct_spike_days = round(pct_spike_days, 1)) %>%
  pivot_wider(names_from = season, values_from = pct_spike_days) %>%
  print()

croquet_top_season <- so2_seasons %>%
  filter(local_site_name == "Houston Croquet") %>%
  slice_max(pct_spike_days, n = 1, with_ties = FALSE)

stopifnot("Croquet spikes most in summer, as the subtitle says" = croquet_top_season$season == "Summer")

# Weekdays against weekends, the follow-up to 2a's weekend drop at the Ship Channel (Monday to Friday against
# Saturday and Sunday, all months)
so2_weekend <- so2_days %>%
  summarise(
    pct_spike_weekday = round(100 * mean(is_spike[!is_weekend]), 1),
    pct_spike_weekend = round(100 * mean(is_spike[is_weekend]), 1),
    .by = c(site_group, local_site_name)
  )

print(so2_weekend)

# The standard: each site-year's 99th-percentile day (naaqs_statistics() in utils.R), and every day above 75 ppb
so2_p99 <- naaqs_statistics(so2_days, naaqs, naaqs_ranks, percentile_ranks) %>%
  left_join(distinct(so2_days, site_id, site_group, local_site_name), by = "site_id", relationship = "many-to-one")

so2_days_above_level <- so2_days %>%
  filter(round_half_up(value, 0) > so2_level) %>%
  select(local_site_name, date_local, value)

print(so2_days_above_level)

stopifnot(
  "One 99th-percentile value per five-year site-year" = nrow(so2_p99) == 4 * length(study_years),
  "No site-year is above the 75 ppb standard" = !any(so2_p99$is_above),
  "Only one day is above 75 ppb, as the subtitle says" = nrow(so2_days_above_level) == 1
)

# Clinton's baseline drifts low (Phase 1): the share of its days that peak below the 2 ppb detection limit, by year
so2_low_days <- so2_days %>%
  summarise(pct_below_2_ppb = round(100 * mean(value < 2), 1), pct_below_zero = round(100 * mean(value < 0), 1), .by = c(local_site_name, year)) %>%
  arrange(local_site_name, year)

print(so2_low_days, n = Inf)

# No spike falls on an event day
so2_event_spikes <- so2_days %>%
  filter(is_spike, event_class != "None") %>%
  nrow()

cat("SO2 spike days on event days:", so2_event_spikes, "\n")

# Figure 2B.5: spike days per site, by year, by season and against the standard
so2_short_names <- so2_site_totals %>%
  mutate(short_name = short_site_name(local_site_name)) %>%
  mutate(short_name = reorder(short_name, n_spike_days))

so2_total_panel <- ggplot(so2_short_names, aes(n_spike_days, short_name, fill = site_group)) +
  geom_col(width = 0.5) +
  geom_text(
    aes(label = n_spike_days), hjust = -0.3,
    family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt, colour = chart_ink[["secondary"]]
  ) +
  scale_fill_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(expand = expansion(mult = c(0, 0.18))) +
  labs(title = "01  SPIKE DAYS", subtitle = "Days at or above 5 ppb, 2021 to 2025", x = NULL, y = NULL) +
  theme_aqs() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
    axis.text.y = element_text(family = chart_fonts[["text"]], colour = chart_ink[["secondary"]], size = 7.5)
  )

main_so2_by_group <- so2_by_group %>%
  filter(site_set == "Main") %>%
  mutate(label = sprintf("%.1f", spike_days_per_site))

so2_year_panel <- ggplot(main_so2_by_group, aes(year, spike_days_per_site, colour = site_group)) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.3) +
  lapply(c("Houston Ship Channel", "Houston other"), \(group) {
    chart_end_label(
      filter(main_so2_by_group, site_group == group, year == max(year)), "year", "spike_days_per_site", "label",
      colour = site_group_colours[[group]], hjust = -0.35, vjust = 0.5
    )
  }) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  year_axis +
  scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.08))) +
  coord_cartesian(clip = "off") +
  labs(title = "02  BY YEAR", subtitle = "Spike days per site", x = NULL, y = NULL) +
  theme_aqs()

so2_season_by_group <- so2_days %>%
  filter(is_full_season) %>%
  summarise(pct_spike_days = 100 * mean(is_spike), .by = c(site_group, season))

so2_season_panel <- ggplot(so2_season_by_group, aes(season, pct_spike_days, colour = site_group, group = site_group)) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 1.3) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_y_continuous(limits = c(0, 15), breaks = seq(0, 15, 5), labels = label_number(suffix = "%"), expand = expansion(mult = c(0, 0.04))) +
  labs(title = "03  SEASON", subtitle = "Share of days that spike", x = NULL, y = NULL) +
  theme_aqs()

so2_standard_panel <- ggplot(so2_p99, aes(year, value_rounded, colour = site_group)) +
  geom_hline(yintercept = so2_level, colour = chart_ink[["primary"]], linewidth = 0.4, linetype = "22") +
  geom_point(position = position_dodge(width = 0.5), size = 1.3, alpha = 0.85) +
  scale_colour_manual(values = site_group_colours, guide = "none") +
  scale_x_continuous(breaks = study_years) +
  scale_y_continuous(limits = c(0, so2_level * 1.05), breaks = seq(0, 75, 25)) +
  labs(title = "04  STANDARD", subtitle = "99th-percentile day per site and year (ppb)", x = NULL, y = NULL) +
  theme_aqs()

so2_header <- chart_header(
  sprintf("FIGURE 2B.5  /  SO2  /  %s TO %s", min(study_years), max(study_years)),
  "SO2 spikes most at Park Place and Croquet",
  str_c(
    "Croquet, 22 km from the channel, has more spike days than the Ship Channel average in every year,\n",
    "mostly in summer, consistent with an unidentified nearby source. Only one day tops 75 ppb."
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel (3 sites)",
    "dot", site_group_colours[["Houston other"]],        "Houston other (Croquet)"
  )
)

so2_footer <- chart_footer(str_c(
  "EPA AQS daily data, five-year SO2 sites; Dallas-Fort Worth has none. Spike: daily 1-hour peak at or above 5 ppb. Clinton\n",
  "reads below the 2 ppb detection limit on most days and drifts lower, so its count may run low. Dashed line: 75 ppb."
))

so2_figure <- chart_compose(so2_header, list(free(so2_total_panel), so2_year_panel, so2_season_panel, so2_standard_panel), so2_footer)

so2_figure_path <- here("figures", "phase2", "2b.05_so2.png")

save_started <- Sys.time()

ggsave(so2_figure_path, so2_figure, width = 6.5, height = 6.2, dpi = 300)

stopifnot(
  "2b.05_so2.png was written (close any viewer of it and rerun this step)" =
    file.mtime(so2_figure_path) >= save_started - 2
)

# CSV records: one row per site and year, and one per group, year and check
so2_site_years <- so2_spikes_by_site %>%
  left_join(select(so2_p99, site_id, year, p99_ppb = value_rounded, is_above_standard = is_above), by = c("site_id", "year"),
            relationship = "one-to-one") %>%
  left_join(select(so2_low_days, local_site_name, year, pct_below_2_ppb), by = c("local_site_name", "year"), relationship = "one-to-one") %>%
  arrange(site_group, site_id, year)

so2_records <- list(
  case_study_so2_site_years = so2_site_years,
  case_study_so2_by_group = mutate(so2_by_group, spike_days_per_site = round(spike_days_per_site, 2))
)

save_records(so2_records, records_dir)

so2_dictionary <- tribble(
  ~table,                      ~column,               ~description,
  "case_study_so2_site_years", "site_group",          "Case-study group: Houston Ship Channel or Houston other",
  "case_study_so2_site_years", "site_id",             "AQS site ID: state-county-site",
  "case_study_so2_site_years", "local_site_name",     "Site name given by the reporting agency",
  "case_study_so2_site_years", "year",                "Calendar year",
  "case_study_so2_site_years", "n_site_days",         "Days with an SO2 value",
  "case_study_so2_site_years", "n_days_ge5",          "Days whose highest 1-hour value is 5 ppb or more",
  "case_study_so2_site_years", "n_days_ge10",         "Days whose highest 1-hour value is 10 ppb or more",
  "case_study_so2_site_years", "n_days_ge20",         "Days whose highest 1-hour value is 20 ppb or more",
  "case_study_so2_site_years", "p99_ppb",             "99th-percentile daily peak of the year, rounded to whole ppb",
  "case_study_so2_site_years", "is_above_standard",   "TRUE when the 99th-percentile value is above 75 ppb",
  "case_study_so2_site_years", "pct_below_2_ppb",     "Share of days whose peak is below the 2 ppb detection limit",
  "case_study_so2_by_group",   "site_set",            "Main or a check: transition band, memo groups, Deer Park #2 move",
  "case_study_so2_by_group",   "site_group",          "Case-study group under that site set",
  "case_study_so2_by_group",   "year",                "Calendar year",
  "case_study_so2_by_group",   "n_sites",             "Five-year SO2 sites in the group",
  "case_study_so2_by_group",   "n_site_days",         "Site-days with an SO2 value",
  "case_study_so2_by_group",   "spike_days_per_site", "Days at or above 5 ppb per site in the year"
)

so2_dictionary <- document_tables(so2_records, so2_dictionary)

replace_own_rows(so2_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 6. EVENTS: URI AND BERYL ----
# Both events cut power across Houston. Two questions: how many five-year monitors kept reporting, and how levels moved
# against normal. Normal is the same calendar dates in the other four study years at the same sites; the week before is
# kept as a check. SO2 sits near zero, so its ratios mean little and it appears only in the reporting counts
event_windows <- read_events() %>%
  filter(state_code == "48", event_name %in% case_study_events) %>%
  summarise(start_date = min(start_date), end_date = max(end_date), .by = event_name) %>%
  mutate(event_name = factor(event_name, levels = case_study_events))

near_road_check_id <- "48-201-1052"

stopifnot(
  "Both events have one window in Texas" = nrow(event_windows) == 2,
  "Houston North Loop is a near-road site in the data" =
    near_road_check_id %in% near_road_ids && near_road_check_id %in% daily_case_study$site_id
)

five_year_monitors <- daily_case_study %>%
  filter(is_five_year) %>%
  distinct(site_group, pollutant, site_id)

monitors_per_group <- five_year_monitors %>%
  count(site_group, name = "n_monitors")

# Share of each group's five-year monitors (site and gas) reporting on each day, from a week before to a week after
event_reporting <- bind_rows(lapply(seq_len(nrow(event_windows)), \(i) {
  window <- event_windows[i, ]
  daily_case_study %>%
    filter(is_five_year, between(date_local, window$start_date - 7, window$end_date + 7)) %>%
    distinct(site_group, pollutant, site_id, date_local) %>%
    count(site_group, date_local, name = "n_reporting") %>%
    complete(site_group, date_local = seq(window$start_date - 7, window$end_date + 7, by = "day"), fill = list(n_reporting = 0L)) %>%
    mutate(event_name = window$event_name, in_window = between(date_local, window$start_date, window$end_date))
})) %>%
  left_join(monitors_per_group, by = "site_group", relationship = "many-to-one") %>%
  mutate(pct_reporting = 100 * n_reporting / n_monitors)

event_reporting_summary <- event_reporting %>%
  summarise(lowest_pct = round(min(pct_reporting), 1), pct_reporting = round(mean(pct_reporting), 1), .by = c(event_name, site_group, in_window)) %>%
  arrange(event_name, site_group, desc(in_window))

print(event_reporting_summary)

# The emptiest day for each Houston gas, counting days with no site reporting
houston_lowest_days <- bind_rows(lapply(seq_len(nrow(event_windows)), \(i) {
  window <- event_windows[i, ]
  daily_case_study %>%
    filter(is_five_year, region == "Houston", between(date_local, window$start_date, window$end_date)) %>%
    mutate(pollutant = droplevels(pollutant)) %>%
    count(pollutant, date_local, name = "n_sites") %>%
    complete(pollutant, date_local = seq(window$start_date, window$end_date, by = "day"), fill = list(n_sites = 0L)) %>%
    mutate(event_name = window$event_name)
})) %>%
  slice_min(n_sites, n = 1, by = c(event_name, pollutant), with_ties = FALSE)

print(houston_lowest_days)

# Levels against normal for each group and gas (SO2 left out), with the near-road North Loop NO2 as its own row
level_days <- daily_case_study %>%
  filter(pollutant != "SO2", is_five_year | (site_id == near_road_check_id & pollutant == "NO2")) %>%
  mutate(
    level_group = if_else(
      site_id == near_road_check_id & pollutant == "NO2", "North Loop (near-road)", as.character(site_group)
    )
  ) %>%
  mutate(month_day = format(date_local, "%m-%d"))

event_levels <- bind_rows(lapply(seq_len(nrow(event_windows)), \(i) {
  window <- event_windows[i, ]
  window_days <- format(seq(window$start_date, window$end_date, by = "day"), "%m-%d")
  event_year <- year(window$start_date)
  event_days <- level_days %>%
    filter(between(date_local, window$start_date, window$end_date))
  normal_days <- level_days %>%
    filter(month_day %in% window_days, year != event_year)
  week_before_days <- level_days %>%
    filter(between(date_local, window$start_date - 7, window$start_date - 1))
  n_window_days <- length(window_days)
  event_days %>%
    summarise(
      n_event_site_days = n(),
      median_sites_per_day = median(c(tabulate(as.integer(factor(date_local))), rep(0, n_window_days - n_distinct(date_local)))),
      median_event = median(value),
      .by = c(level_group, pollutant)
    ) %>%
    left_join(summarise(normal_days, median_normal = median(value), .by = c(level_group, pollutant)), by = c("level_group", "pollutant")) %>%
    left_join(
      summarise(week_before_days, median_week_before = median(value), .by = c(level_group, pollutant)),
      by = c("level_group", "pollutant")
    ) %>%
    mutate(event_name = window$event_name)
})) %>%
  mutate(ratio_normal = median_event / median_normal) %>%
  mutate(ratio_week_before = median_event / median_week_before) %>%
  mutate(is_thin = median_sites_per_day <= 1) %>%
  arrange(event_name, pollutant, level_group)

event_levels %>%
  mutate(across(c(ratio_normal, ratio_week_before), \(x) round(x, 2))) %>%
  select(event_name, pollutant, level_group, n_event_site_days, median_sites_per_day, ratio_normal, ratio_week_before, is_thin) %>%
  print(n = Inf, width = Inf)

group_ratio <- function(event, gas, groups) {
  event_levels$ratio_normal[event_levels$event_name == event & event_levels$pollutant == gas & event_levels$level_group %in% groups]
}

uri_pm25 <- group_ratio("Winter Storm Uri", "PM2.5", names(site_group_colours))

uri_houston_no2 <- group_ratio("Winter Storm Uri", "NO2", c("Houston Ship Channel", "Houston other"))

beryl_houston_no2 <- group_ratio("Hurricane Beryl", "NO2", c("Houston Ship Channel", "Houston other"))

ship_channel_beryl_reporting <- event_reporting_summary %>%
  filter(event_name == "Hurricane Beryl", site_group == "Houston Ship Channel", in_window) %>%
  pull(pct_reporting)

stopifnot(
  "Fewer than half of the Ship Channel monitors reported during Beryl, as the figure title says" = ship_channel_beryl_reporting < 50,
  "Dallas-Fort Worth kept reporting through Beryl" =
    event_reporting_summary$pct_reporting[event_reporting_summary$event_name == "Hurricane Beryl" &
      event_reporting_summary$site_group == "Dallas-Fort Worth" & event_reporting_summary$in_window] >= 90,
  "PM2.5 rose above normal in every group during Uri, as the subtitle says" = all(uri_pm25 > 1),
  "Houston NO2 fell below normal during Uri, as the subtitle says" = all(uri_houston_no2 < 1),
  "Houston NO2 rose above normal during Beryl, as the subtitle says" = all(beryl_houston_no2 > 1)
)

# Figure 2B.6: monitors reporting and levels against normal, for each event
reporting_panel <- function(event, kicker) {
  window <- filter(event_windows, event_name == event)
  ggplot(filter(event_reporting, event_name == event), aes(date_local, pct_reporting, colour = site_group)) +
    annotate("rect", xmin = window$start_date - 0.5, xmax = window$end_date + 0.5, ymin = -Inf, ymax = Inf, fill = chart_fills[["band"]]) +
    geom_line(linewidth = 0.7) +
    scale_colour_manual(values = site_group_colours, guide = "none") +
    scale_x_date(date_breaks = "1 week", labels = \(x) str_c(month.abb[month(x)], " ", day(x))) +
    scale_y_continuous(limits = c(0, 100), labels = label_number(suffix = "%")) +
    labs(title = kicker, subtitle = "Five-year monitors reporting each day", x = NULL, y = NULL) +
    theme_aqs()
}

level_colours <- c(site_group_colours, "North Loop (near-road)" = chart_ink[["primary"]])

level_panel <- function(event, kicker) {
  panel_data <- event_levels %>%
    filter(event_name == event) %>%
    mutate(gas_index = match(pollutant, c("NO2", "Ozone", "PM2.5"))) %>%
    mutate(offset = match(level_group, names(level_colours)) - 2.5) %>%
    mutate(y = gas_index + 0.16 * offset)
  ggplot(panel_data, aes(ratio_normal, y, colour = level_group)) +
    geom_vline(xintercept = 1, colour = chart_ink[["axis"]], linewidth = 0.4) +
    geom_point(aes(shape = is_thin), size = 2, stroke = 0.9) +
    scale_shape_manual(values = c(`FALSE` = 16, `TRUE` = 1), guide = "none") +
    scale_colour_manual(values = level_colours, guide = "none") +
    scale_x_continuous(trans = "log2", limits = c(0.5, 3.2), breaks = c(0.5, 1, 2), labels = c("0.5x", "1x", "2x")) +
    scale_y_continuous(breaks = 1:3, labels = c("NO2", "Ozone", "PM2.5"), expand = expansion(add = 0.4)) +
    labs(title = kicker, subtitle = "Median during the event against normal", x = NULL, y = NULL) +
    theme_aqs() +
    theme(
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
      axis.text.y = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["secondary"]], size = chart_sizes[["axis"]])
    )
}

events_header <- chart_header(
  sprintf("FIGURE 2B.6  /  EVENTS  /  URI %s AND BERYL %s", year(event_windows$start_date[1]), year(event_windows$start_date[2])),
  "Beryl knocked out most Ship Channel monitors",
  sprintf(
    str_c(
      "During Uri, PM2.5 ran %.1f to %.1f times normal and Houston NO2 fell. During Beryl, Houston NO2\n",
      "ran about %.1f times normal at the few sites still on, consistent with generators and disrupted traffic."
    ),
    min(uri_pm25), max(uri_pm25), mean(beryl_houston_no2)
  ),
  key = tribble(
    ~mark, ~colour,                                     ~label,
    "dot", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
    "dot", site_group_colours[["Houston other"]],        "Houston other",
    "dot", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",
    "dot", chart_ink[["primary"]],                       "North Loop NO2 (near-road)"
  )
)

events_monitor_note <- monitors_per_group %>%
  mutate(label = str_c(site_group, " ", n_monitors)) %>%
  pull(label) %>%
  str_flatten(collapse = ", ")

events_footer <- chart_footer(str_c(
  "EPA AQS daily data. Five-year monitors (site and gas): ", events_monitor_note, ".\n",
  "Shaded: the events.csv window. Normal: the same dates in the other four years. Hollow points: one site or none\n",
  "on most event days. SO2 sits near zero and is left out of the level panels."
))

events_figure <- chart_compose(
  events_header,
  list(
    reporting_panel("Winter Storm Uri", "01  URI: MONITORS"),
    level_panel("Winter Storm Uri", "02  URI: LEVELS"),
    reporting_panel("Hurricane Beryl", "03  BERYL: MONITORS"),
    level_panel("Hurricane Beryl", "04  BERYL: LEVELS")
  ),
  events_footer
)

events_figure_path <- here("figures", "phase2", "2b.06_events.png")

save_started <- Sys.time()

ggsave(events_figure_path, events_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2b.06_events.png was written (close any viewer of it and rerun this step)" =
    file.mtime(events_figure_path) >= save_started - 2
)

# CSV records: daily reporting shares and the level ratios
event_records <- list(
  case_study_event_reporting = event_reporting %>%
    mutate(pct_reporting = round(pct_reporting, 1)) %>%
    select(event_name, site_group, date_local, in_window, n_monitors, n_reporting, pct_reporting),
  case_study_event_levels = event_levels %>%
    mutate(across(c(median_event, median_normal, median_week_before, ratio_normal, ratio_week_before), \(x) round(x, 4))) %>%
    select(
      event_name, pollutant, level_group, n_event_site_days, median_sites_per_day, is_thin,
      median_event, median_normal, ratio_normal, median_week_before, ratio_week_before
    )
)

save_records(event_records, records_dir)

event_dictionary <- tribble(
  ~table,                       ~column,                ~description,
  "case_study_event_reporting", "event_name",           "Winter Storm Uri or Hurricane Beryl",
  "case_study_event_reporting", "site_group",           "Case-study group",
  "case_study_event_reporting", "date_local",           "Day, from a week before the event window to a week after",
  "case_study_event_reporting", "in_window",            "TRUE inside the events.csv window",
  "case_study_event_reporting", "n_monitors",           "Five-year monitors (site and gas) in the group",
  "case_study_event_reporting", "n_reporting",          "Monitors with a value that day",
  "case_study_event_reporting", "pct_reporting",        "Share of the group's monitors reporting that day",
  "case_study_event_levels",    "event_name",           "Winter Storm Uri or Hurricane Beryl",
  "case_study_event_levels",    "pollutant",            "PM2.5, Ozone or NO2 (SO2 left out, near zero)",
  "case_study_event_levels",    "level_group",          "Case-study group, or North Loop (near-road) for NO2",
  "case_study_event_levels",    "n_event_site_days",    "Site-days with data inside the window",
  "case_study_event_levels",    "median_sites_per_day", "Median number of sites reporting per event day",
  "case_study_event_levels",    "is_thin",              "TRUE when one site or none reported on most event days",
  "case_study_event_levels",    "median_event",         "Median daily value inside the window (PM2.5 µg/m³, ozone ppm, NO2 ppb)",
  "case_study_event_levels",    "median_normal",        "Median on the same calendar dates in the other four study years",
  "case_study_event_levels",    "ratio_normal",         "median_event divided by median_normal",
  "case_study_event_levels",    "median_week_before",   "Median over the seven days before the window",
  "case_study_event_levels",    "ratio_week_before",    "median_event divided by median_week_before"
)

event_dictionary <- document_tables(event_records, event_dictionary)

replace_own_rows(event_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 7. PAIRED SAME-DAY DIFFERENCES ----
# The main test. Each group's daily value is the mean of its five-year sites reporting that day; the difference between
# two groups on the same day cancels most of the weather they share. Ozone is in ppb here so the gases share one scale
paired_columns <- c(
  "site_set", "pollutant", "site_group", "region", "site_id", "date_local", "season", "year", "is_full_season", "event_class", "value"
)

paired_site_days <- bind_rows(
  select(ozone_site_sets, all_of(paired_columns)),
  select(no2_site_sets, all_of(paired_columns)),
  select(pm25_site_sets, all_of(paired_columns)),
  select(so2_site_sets, all_of(paired_columns))
) %>%
  mutate(site_set = as.character(site_set))

# Checks added here for every gas: without event and fireworks days (PM2.5 already has it), and only group-days on which
# at least half of the group's sites reported
gas_event_free_days <- paired_site_days %>%
  filter(site_set == "Main", pollutant != "PM2.5", event_class == "None") %>%
  mutate(site_set = "Without event and fireworks days")

group_site_counts <- paired_site_days %>%
  filter(site_set == "Main") %>%
  distinct(pollutant, site_group, site_id) %>%
  count(pollutant, site_group, name = "n_group_sites")

half_site_days <- paired_site_days %>%
  filter(site_set == "Main") %>%
  add_count(pollutant, site_group, date_local, name = "n_reporting") %>%
  inner_join(group_site_counts, by = c("pollutant", "site_group"), relationship = "many-to-one") %>%
  filter(n_reporting >= n_group_sites / 2) %>%
  select(-n_reporting, -n_group_sites) %>%
  mutate(site_set = "At least half of each group's sites")

paired_site_days <- bind_rows(paired_site_days, gas_event_free_days, half_site_days) %>%
  mutate(site_set = factor(site_set, levels = site_set_levels)) %>%
  mutate(value = if_else(pollutant == "Ozone", value * 1000, value))

group_daily <- paired_site_days %>%
  summarise(group_value = mean(value), .by = c(site_set, pollutant, site_group, date_local, season, year, is_full_season))

houston_daily <- paired_site_days %>%
  filter(region == "Houston") %>%
  summarise(houston_value = mean(value), .by = c(site_set, pollutant, date_local))

contrast_levels <- c("Ship Channel minus Houston other", "Houston minus Dallas-Fort Worth")

daily_differences <- group_daily %>%
  pivot_wider(names_from = site_group, values_from = group_value) %>%
  left_join(houston_daily, by = c("site_set", "pollutant", "date_local"), relationship = "one-to-one") %>%
  mutate(`Ship Channel minus Houston other` = `Houston Ship Channel` - `Houston other`) %>%
  mutate(`Houston minus Dallas-Fort Worth` = houston_value - `Dallas-Fort Worth`) %>%
  select(site_set, pollutant, date_local, season, year, is_full_season, all_of(contrast_levels)) %>%
  pivot_longer(all_of(contrast_levels), names_to = "contrast", values_to = "difference") %>%
  filter(!is.na(difference)) %>%
  mutate(contrast = factor(contrast, levels = contrast_levels)) %>%
  arrange(site_set, contrast, pollutant, date_local)

stopifnot(
  "No Dallas-Fort Worth SO2 comparison" = !any(daily_differences$pollutant == "SO2" & daily_differences$contrast == contrast_levels[2]),
  "Every main comparison has at least 1,700 days" =
    all(count(filter(daily_differences, site_set == "Main"), contrast, pollutant)$n >= 1700)
)

# A check that leaves a comparison's days and values exactly as in the main run is not a separate run: its range would
# differ from the main one only by resampling chance. It is dropped for that comparison, so its row stays empty
difference_series <- daily_differences %>%
  summarise(dates = list(date_local), values = list(difference), .by = c(site_set, contrast, pollutant))

main_series <- difference_series %>%
  filter(site_set == "Main") %>%
  select(contrast, pollutant, main_dates = dates, main_values = values)

unchanged_checks <- difference_series %>%
  filter(site_set != "Main") %>%
  inner_join(main_series, by = c("contrast", "pollutant"), relationship = "many-to-one") %>%
  mutate(is_unchanged = mapply(\(d, v, md, mv) identical(d, md) && isTRUE(all.equal(v, mv)), dates, values, main_dates, main_values)) %>%
  filter(is_unchanged) %>%
  select(site_set, contrast, pollutant)

print(unchanged_checks, n = Inf)

daily_differences <- daily_differences %>%
  anti_join(unchanged_checks, by = c("site_set", "contrast", "pollutant"))

stopifnot(
  "Nine checks leave a comparison unchanged, among them both Ship Channel SO2 checks that move no SO2 site" =
    nrow(unchanged_checks) == 9 &&
    nrow(filter(unchanged_checks, pollutant == "SO2", site_set %in% c("Without the transition band", "Memo-list groups"))) == 2
)

# Median of a day-ordered series and a 95% range from resampled two-week blocks
block_bootstrap_range <- function(x) {
  n <- length(x)
  if (n < 2 * bootstrap_block_days) {
    return(c(NA_real_, NA_real_))
  }
  block_starts <- seq_len(n - bootstrap_block_days + 1)
  n_blocks <- ceiling(n / bootstrap_block_days)
  medians <- vapply(seq_len(bootstrap_reps), \(rep) {
    picked <- sample(block_starts, n_blocks, replace = TRUE)
    median(x[as.vector(outer(seq_len(bootstrap_block_days) - 1, picked, `+`))][seq_len(n)])
  }, numeric(1))
  unname(quantile(medians, c(0.025, 0.975)))
}

summarise_differences <- function(differences, by) {
  differences %>%
    arrange(date_local) %>%
    summarise(
      n_days = n(),
      median_difference = median(difference),
      pct_days_positive = 100 * mean(difference > 0),
      range = list(block_bootstrap_range(difference)),
      .by = all_of(by)
    ) %>%
    mutate(ci_low = vapply(range, \(r) r[1], numeric(1))) %>%
    mutate(ci_high = vapply(range, \(r) r[2], numeric(1))) %>%
    select(-range)
}

set.seed(bootstrap_seed)

main_differences <- daily_differences %>%
  filter(site_set == "Main")

paired_results <- bind_rows(
  summarise_differences(daily_differences, c("site_set", "contrast", "pollutant")) %>%
    mutate(period_type = "Overall", period = str_c(min(study_years), " to ", max(study_years))),
  summarise_differences(filter(main_differences, is_full_season), c("site_set", "contrast", "pollutant", "season")) %>%
    mutate(period_type = "Season", period = as.character(season)),
  summarise_differences(main_differences, c("site_set", "contrast", "pollutant", "year")) %>%
    mutate(period_type = "Year", period = as.character(year))
) %>%
  select(site_set, contrast, pollutant, period_type, period, n_days, median_difference, ci_low, ci_high, pct_days_positive) %>%
  mutate(range_excludes_zero = ci_low > 0 | ci_high < 0)

paired_results %>%
  filter(site_set == "Main", period_type == "Overall") %>%
  mutate(across(c(median_difference, ci_low, ci_high, pct_days_positive), \(x) round(x, 2))) %>%
  print(width = Inf)

paired_results %>%
  filter(period_type == "Overall", contrast == contrast_levels[1], pollutant %in% c("NO2", "Ozone")) %>%
  mutate(cell = sprintf("%+.2f (%+.2f to %+.2f)", median_difference, ci_low, ci_high)) %>%
  select(site_set, pollutant, cell) %>%
  pivot_wider(names_from = pollutant, values_from = cell) %>%
  print(width = Inf)

# Linked days: how closely each day's difference follows the day before (one-day autocorrelation). Above zero, days
# are not independent, which is why whole 14-day blocks are resampled
main_differences %>%
  summarise(lag_one_correlation = round(cor(difference[-1], difference[-n()]), 2), .by = c(contrast, pollutant)) %>%
  print()

main_overall <- paired_results %>%
  filter(site_set == "Main", period_type == "Overall")

result_for <- function(results, contrast_name, gas) {
  filter(results, contrast == contrast_name, pollutant == gas)
}

ship_channel_no2 <- result_for(main_overall, contrast_levels[1], "NO2")

ship_channel_ozone <- result_for(main_overall, contrast_levels[1], "Ozone")

houston_dfw_ozone <- result_for(main_overall, contrast_levels[2], "Ozone")

no2_checks <- paired_results %>%
  filter(period_type == "Overall", contrast == contrast_levels[1], pollutant == "NO2")

no2_years <- paired_results %>%
  filter(site_set == "Main", period_type == "Year", contrast == contrast_levels[1], pollutant == "NO2")

stopifnot(
  "Ship Channel NO2 is above Houston other on the same day, with a range above zero, as the figure title says" = ship_channel_no2$ci_low > 0,
  "Ship Channel ozone is below Houston other, with a range below zero, as the subtitle says" = ship_channel_ozone$ci_high < 0,
  "Houston ozone is below Dallas-Fort Worth, with a range below zero, as the subtitle says" = houston_dfw_ozone$ci_high < 0,
  "Ship Channel NO2 stays above zero under every check" = all(no2_checks$ci_low > 0),
  "Ship Channel NO2 is higher in every year" = all(no2_years$median_difference > 0)
)

# Figure 2B.7: main differences, the Ship Channel against Houston other by season, by check and by year
gas_colours <- c(NO2 = chart_fills[["accent"]], Ozone = chart_ink[["primary"]], SO2 = chart_ink[["muted"]], PM2.5 = chart_fills[["other"]])

contrast_short <- c("Ship Channel minus Houston other" = "SC - OTHER", "Houston minus Dallas-Fort Worth" = "HOU - DFW")

forest_theme <- theme(
  panel.grid.major.y = element_blank(),
  panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
  axis.text.y = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["secondary"]], size = chart_sizes[["axis"]])
)

main_plot <- main_overall %>%
  mutate(row_label = str_c(pollutant, "  ", contrast_short[as.character(contrast)])) %>%
  arrange(contrast, pollutant) %>%
  mutate(row_label = factor(row_label, levels = rev(row_label)))

main_panel <- ggplot(main_plot, aes(median_difference, row_label, colour = pollutant)) +
  geom_vline(xintercept = 0, colour = chart_ink[["axis"]], linewidth = 0.4) +
  geom_errorbar(aes(xmin = ci_low, xmax = ci_high), orientation = "y", width = 0, linewidth = 0.9) +
  geom_point(size = 1.9) +
  scale_colour_manual(values = gas_colours, guide = "none") +
  labs(title = "01  MAIN RESULT", subtitle = "Median same-day difference, 95% range", x = NULL, y = NULL) +
  theme_aqs() +
  forest_theme

season_plot <- paired_results %>%
  filter(site_set == "Main", period_type == "Season", contrast == contrast_levels[1], pollutant %in% c("NO2", "Ozone", "SO2")) %>%
  mutate(period = factor(period, levels = levels(daily_case_study$season)))

season_panel <- ggplot(season_plot, aes(period, median_difference, colour = pollutant)) +
  geom_hline(yintercept = 0, colour = chart_ink[["axis"]], linewidth = 0.4) +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, linewidth = 0.9, position = position_dodge(width = 0.5)) +
  geom_point(size = 1.7, position = position_dodge(width = 0.5)) +
  scale_colour_manual(values = gas_colours, guide = "none") +
  labs(title = "02  BY SEASON", subtitle = "SC minus Houston other (ppb)", x = NULL, y = NULL) +
  theme_aqs()

check_labels <- c(
  "Main" = "Main",
  "Without the transition band" = "No transition band",
  "Memo-list groups" = "Memo-list groups",
  "Without days after method changes" = "No method-change days",
  "Without whole-site checks" = "No near-road PM2.5",
  "Without Deer Park #2 after its move" = "No Deer Park #2 move",
  "Without event and fireworks days" = "No event days",
  "With 4-year sites" = "With 4-year sites",
  "At least half of each group's sites" = "Half the sites or more"
)

check_plot <- paired_results %>%
  filter(period_type == "Overall", contrast == contrast_levels[1], pollutant %in% c("NO2", "Ozone")) %>%
  mutate(check = factor(check_labels[as.character(site_set)], levels = rev(check_labels)))

check_panel <- ggplot(check_plot, aes(median_difference, check, colour = pollutant)) +
  geom_vline(xintercept = 0, colour = chart_ink[["axis"]], linewidth = 0.4) +
  geom_errorbar(aes(xmin = ci_low, xmax = ci_high), orientation = "y", width = 0, linewidth = 0.9) +
  geom_point(size = 1.7) +
  scale_colour_manual(values = gas_colours, guide = "none") +
  labs(title = "03  BY CHECK", subtitle = "SC minus Houston other (ppb)", x = NULL, y = NULL) +
  theme_aqs() +
  forest_theme

year_plot <- paired_results %>%
  filter(site_set == "Main", period_type == "Year", contrast == contrast_levels[1], pollutant %in% c("NO2", "Ozone")) %>%
  mutate(period = as.integer(period))

year_panel <- ggplot(year_plot, aes(period, median_difference, colour = pollutant)) +
  geom_hline(yintercept = 0, colour = chart_ink[["axis"]], linewidth = 0.4) +
  geom_errorbar(aes(ymin = ci_low, ymax = ci_high), width = 0, linewidth = 0.9, position = position_dodge(width = 0.4)) +
  geom_point(size = 1.7, position = position_dodge(width = 0.4)) +
  scale_colour_manual(values = gas_colours, guide = "none") +
  scale_x_continuous(breaks = study_years) +
  labs(title = "04  BY YEAR", subtitle = "SC minus Houston other (ppb)", x = NULL, y = NULL) +
  theme_aqs()

paired_header <- chart_header(
  sprintf("FIGURE 2B.7  /  SAME-DAY DIFFERENCES  /  %s TO %s", min(study_years), max(study_years)),
  "Same-day NO2 is higher at the Ship Channel",
  sprintf(
    str_c(
      "Median gap %+.2f ppb (95%% range %+.2f to %+.2f) against Houston other; ozone is %.2f ppb lower,\n",
      "consistent with fresh NO using up ozone near its sources. Houston ozone runs %.1f ppb below DFW."
    ),
    ship_channel_no2$median_difference, ship_channel_no2$ci_low, ship_channel_no2$ci_high,
    abs(ship_channel_ozone$median_difference), abs(houston_dfw_ozone$median_difference)
  ),
  key = tribble(
    ~mark, ~colour,                ~label,
    "dot", gas_colours[["NO2"]],   "NO2",
    "dot", gas_colours[["Ozone"]], "Ozone",
    "dot", gas_colours[["SO2"]],   "SO2",
    "dot", gas_colours[["PM2.5"]], "PM2.5"
  )
)

paired_footer <- chart_footer(str_c(
  "EPA AQS daily data, five-year sites. Group value: mean of the sites reporting that day. Gases in ppb, PM2.5 in µg/m³.\n",
  "95% ranges: ", format(bootstrap_reps, big.mark = ","), " resamples of ", bootstrap_block_days, "-day blocks, since nearby days are linked. ",
  "Panel 03: every check from sections 2 to 7."
))

paired_figure <- chart_compose(paired_header, list(free(main_panel), season_panel, free(check_panel), year_panel), paired_footer)

paired_figure_path <- here("figures", "phase2", "2b.07_paired.png")

save_started <- Sys.time()

ggsave(paired_figure_path, paired_figure, width = 6.5, height = 6.6, dpi = 300)

stopifnot(
  "2b.07_paired.png was written (close any viewer of it and rerun this step)" =
    file.mtime(paired_figure_path) >= save_started - 2
)

# CSV record: every summary row (overall for each check, by season and by year for the main set)
paired_records <- list(
  case_study_paired_differences = paired_results %>%
    mutate(across(c(median_difference, ci_low, ci_high, pct_days_positive), \(x) round(x, 3)))
)

save_records(paired_records, records_dir)

paired_dictionary <- tribble(
  ~table,                          ~column,               ~description,
  "case_study_paired_differences", "site_set",            "Main or the check applied (as in sections 2 to 6, plus half the sites or more)",
  "case_study_paired_differences", "contrast",            "Ship Channel minus Houston other, or Houston (all Houston sites) minus Dallas-Fort Worth",
  "case_study_paired_differences", "pollutant",           "PM2.5, Ozone, NO2 or SO2 (no Dallas-Fort Worth SO2)",
  "case_study_paired_differences", "period_type",         "Overall, Season or Year",
  "case_study_paired_differences", "period",              "2021 to 2025, the season, or the year",
  "case_study_paired_differences", "n_days",              "Days on which both sides of the contrast had a value",
  "case_study_paired_differences", "median_difference",   "Median same-day difference (ppb for gases, ozone included; µg/m³ for PM2.5)",
  "case_study_paired_differences", "ci_low",              "Lower end of the 95% range from the block bootstrap",
  "case_study_paired_differences", "ci_high",             "Upper end of the 95% range from the block bootstrap",
  "case_study_paired_differences", "pct_days_positive",   "Share of days on which the first side was higher",
  "case_study_paired_differences", "range_excludes_zero", "TRUE when the 95% range lies wholly above or below zero"
)

paired_dictionary <- document_tables(paired_records, paired_dictionary)

replace_own_rows(paired_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 8. VALIDATE AND SAVE ----
# The main ranges rerun with a second seed, every run side by side for each gas, and a final observed / expected /
# passed table saved as a CSV record
set.seed(bootstrap_check_seed)

seed_check <- main_differences %>%
  arrange(date_local) %>%
  summarise(range = list(block_bootstrap_range(difference)), .by = c(contrast, pollutant)) %>%
  mutate(check_low = vapply(range, \(r) r[1], numeric(1))) %>%
  mutate(check_high = vapply(range, \(r) r[2], numeric(1))) %>%
  select(-range) %>%
  inner_join(select(main_overall, contrast, pollutant, ci_low, ci_high), by = c("contrast", "pollutant"), relationship = "one-to-one") %>%
  mutate(largest_shift = pmax(abs(check_low - ci_low), abs(check_high - ci_high))) %>%
  mutate(shift_share = largest_shift / (ci_high - ci_low)) %>%
  mutate(verdict_changes = (ci_low > 0 | ci_high < 0) != (check_low > 0 | check_high < 0))

seed_check %>%
  mutate(across(c(ci_low, ci_high, check_low, check_high, largest_shift, shift_share), \(x) round(x, 3))) %>%
  print(width = Inf)

seed_verdict_changes <- seed_check %>%
  filter(verdict_changes) %>%
  mutate(label = str_c(pollutant, ", ", contrast)) %>%
  pull(label) %>%
  str_flatten(collapse = "; ")

# A run is the main site set or one check. A run holds when its median keeps the main sign and its range is clear of zero
run_results <- paired_results %>%
  filter(period_type == "Overall") %>%
  mutate(main_sign = sign(median_difference[site_set == "Main"]), .by = c(contrast, pollutant)) %>%
  mutate(holds = range_excludes_zero & sign(median_difference) == main_sign)

check_tally <- run_results %>%
  summarise(
    n_runs = n(),
    n_holding = sum(holds),
    n_crossing_zero = sum(!range_excludes_zero),
    runs_not_holding = str_flatten(as.character(site_set[!holds]), collapse = ", "),
    main_sign = first(main_sign),
    .by = c(contrast, pollutant)
  )

print(check_tally, width = Inf)

tally_for <- function(contrast_name, gas) {
  filter(check_tally, contrast == contrast_name, pollutant == gas)
}

no2_tally <- tally_for(contrast_levels[1], "NO2")

so2_tally <- tally_for(contrast_levels[1], "SO2")

ozone_tally <- tally_for(contrast_levels[1], "Ozone")

pm25_tally <- tally_for(contrast_levels[1], "PM2.5")

houston_dfw_tally <- check_tally %>%
  filter(contrast == contrast_levels[2])

# Detection limits from hourly_case_study.rds (mdl_ppb): 2 ppb at Clinton, Croquet and Park Place, 0.2 ppb at Deer Park #2
so2_detection_limit_ppb <- 2

so2_main_difference <- run_results %>%
  filter(contrast == contrast_levels[1], pollutant == "SO2", site_set == "Main") %>%
  pull(median_difference)

stopifnot(
  "No run reverses a main result with a range clear of zero, so grey in figure 2B.8 means the range includes zero" =
    all(check_tally$n_holding + check_tally$n_crossing_zero == check_tally$n_runs),
  "Ship Channel NO2 stays higher in every run, as the figure title says" = no2_tally$main_sign > 0 && no2_tally$n_holding == no2_tally$n_runs,
  "Ship Channel SO2 stays higher in every run, as the subtitle says" = so2_tally$main_sign > 0 && so2_tally$n_holding == so2_tally$n_runs,
  "The SO2 gap is under a tenth of the detection limit, as the subtitle says" = so2_main_difference < so2_detection_limit_ppb / 10,
  "Ship Channel ozone stays lower in every run but the memo-list groups, as the subtitle says" =
    ozone_tally$main_sign < 0 && ozone_tally$runs_not_holding == "Memo-list groups",
  "PM2.5 ranges include zero in at least half the runs, as the subtitle says" = pm25_tally$n_crossing_zero >= pm25_tally$n_runs / 2,
  "Houston minus Dallas-Fort Worth holds in every run for every gas" = all(houston_dfw_tally$n_holding == houston_dfw_tally$n_runs),
  "Only the PM2.5 Ship Channel range changes its verdict with a second seed, as the footer says" =
    seed_verdict_changes == "PM2.5, Ship Channel minus Houston other"
)

# Figure 2B.8: Ship Channel minus Houston other in every run, one panel per gas, each with its own check labels
run_plot <- run_results %>%
  filter(contrast == contrast_levels[1]) %>%
  mutate(check = factor(check_labels[as.character(site_set)], levels = rev(check_labels)))

run_colours <- c("TRUE" = chart_fills[["accent"]], "FALSE" = chart_ink[["muted"]])

run_panel <- function(gas, number) {
  tally <- tally_for(contrast_levels[1], gas)
  gas_runs <- filter(run_plot, pollutant == gas)
  main_value <- gas_runs$median_difference[gas_runs$site_set == "Main"]
  ggplot(gas_runs, aes(median_difference, check, colour = as.character(holds))) +
    geom_vline(xintercept = 0, colour = chart_ink[["axis"]], linewidth = 0.4) +
    geom_vline(xintercept = main_value, colour = chart_fills[["accent"]], linewidth = 0.3, linetype = "22") +
    geom_errorbar(aes(xmin = ci_low, xmax = ci_high), orientation = "y", width = 0, linewidth = 0.9) +
    geom_point(size = 1.7) +
    scale_colour_manual(values = run_colours, guide = "none") +
    scale_x_continuous(breaks = breaks_pretty(n = 3)) +
    scale_y_discrete(drop = FALSE) +
    labs(
      title = str_c(number, "  ", str_to_upper(gas)),
      subtitle = sprintf("%s in %d of %d runs", if_else(tally$main_sign > 0, "Higher", "Lower"), tally$n_holding, tally$n_runs),
      x = NULL,
      y = NULL
    ) +
    theme_aqs() +
    forest_theme
}

no2_run_panel <- run_panel("NO2", "01")

ozone_run_panel <- run_panel("Ozone", "02")

so2_run_panel <- run_panel("SO2", "03")

pm25_run_panel <- run_panel("PM2.5", "04")

runs_header <- chart_header(
  sprintf("FIGURE 2B.8  /  EVERY CHECK  /  %s TO %s", min(study_years), max(study_years)),
  "Ship Channel NO2 holds up under every check",
  sprintf(
    str_c(
      "SO2 is higher in all %d runs, by %.2f ppb, well under the %d ppb detection limit at 3 of 4 sites.\n",
      "Ozone is lower in %d of %d runs (not the memo-list groups); PM2.5 ranges include zero in %d of %d."
    ),
    so2_tally$n_runs, so2_main_difference, so2_detection_limit_ppb, ozone_tally$n_holding, ozone_tally$n_runs,
    pm25_tally$n_crossing_zero, pm25_tally$n_runs
  ),
  key = tribble(
    ~mark, ~colour,                ~label,
    "dot", run_colours[["TRUE"]],  "Same sign as the main result, range clear of zero",
    "dot", run_colours[["FALSE"]], "Range includes zero"
  )
)

runs_footer <- chart_footer(str_c(
  "EPA AQS daily data, five-year sites, same-day differences. A run is the main site set or one check from sections\n",
  "2 to 7. Gases in ppb, PM2.5 in µg/m³. 95% ranges: ", format(bootstrap_reps, big.mark = ","), " resamples of ",
  bootstrap_block_days, "-day blocks. ",
  "Dashed line: the main result.\nEmpty rows: the check does not apply or changes nothing. With a second seed, the PM2.5 main range reaches zero."
))

runs_figure <- chart_compose(runs_header, list(no2_run_panel, ozone_run_panel, so2_run_panel, pm25_run_panel), runs_footer)

runs_figure_path <- here("figures", "phase2", "2b.08_checks.png")

save_started <- Sys.time()

ggsave(runs_figure_path, runs_figure, width = 6.5, height = 6.4, dpi = 300)

stopifnot(
  "2b.08_checks.png was written (close any viewer of it and rerun this step)" =
    file.mtime(runs_figure_path) >= save_started - 2
)

# Final validation: inputs, site sets, ranges, findings and saved files
checkpoint_rows_listed <- input_check$rows[input_check$file == "daily_case_study.rds"]

duplicate_site_days <- daily_case_study %>%
  count(pollutant, site_id, date_local) %>%
  filter(n > 1) %>%
  nrow()

houston_group_mismatches <- sum(as.character(houston_group_check$site_group) != houston_group_check$group_from_1c)

five_year_counts <- site_set_counts %>%
  summarise(counts = str_flatten(main, collapse = "/"), .by = pollutant) %>%
  pull(counts) %>%
  str_flatten(collapse = ", ")

main_set_site_days <- paired_site_days %>%
  filter(site_set == "Main") %>%
  nrow()

run_group_counts <- paired_site_days %>%
  distinct(pollutant, site_set, site_group) %>%
  count(pollutant, site_set, name = "n_groups")

main_group_counts <- run_group_counts %>%
  filter(site_set == "Main") %>%
  select(pollutant, main_groups = n_groups)

runs_missing_a_group <- run_group_counts %>%
  inner_join(main_group_counts, by = "pollutant", relationship = "many-to-one") %>%
  filter(n_groups < main_groups) %>%
  nrow()

missing_ranges <- sum(is.na(paired_results$ci_low) | is.na(paired_results$ci_high))

ranges_missing_median <- sum(
  paired_results$median_difference < paired_results$ci_low | paired_results$median_difference > paired_results$ci_high,
  na.rm = TRUE
)

short_main_comparisons <- sum(main_overall$n_days < 1700)

seed_shifts <- sum(seed_check$shift_share > bootstrap_seed_tolerance)

figure_paths <- c(
  sites_figure_path, ozone_figure_path, no2_figure_path, pm25_figure_path,
  so2_figure_path, events_figure_path, paired_figure_path, runs_figure_path
)

earlier_records <- c(inventory_records, ozone_records, no2_records, pm25_records, so2_records, event_records, paired_records)

documented_tables <- read_csv(data_dictionary_path, col_types = cols(.default = col_character())) %>%
  distinct(table) %>%
  pull(table)

record_paths <- file.path(records_dir, str_c(names(earlier_records), ".csv"))

inventory_size <- str_c(n_distinct(site_inventory$site_id), " sites, ", nrow(site_inventory), " site-pollutants")

no2_runs_not_holding <- no2_tally$n_runs - no2_tally$n_holding

houston_dfw_runs_not_holding <- sum(houston_dfw_tally$n_runs - houston_dfw_tally$n_holding)

undocumented_records <- sum(!names(earlier_records) %in% documented_tables)

records_over_limit <- sum(file.size(record_paths) / 2^20 >= github_limit_mib)

count_checks <- tribble(
  ~check,                                                             ~observed,                      ~expected,
  "Site-days in the checkpoint against the manifest",                 nrow(daily_case_study),         checkpoint_rows_listed,
  "Duplicate site-days (gas, site, day)",                             duplicate_site_days,            0,
  "Houston sites whose group differs from 1c",                        houston_group_mismatches,       0,
  "Main-set site-days against five-year site-days in the checkpoint", main_set_site_days,             sum(daily_case_study$is_five_year),
  "Runs that lose a group the main set has",                          runs_missing_a_group,           0,
  "Same-day results without a 95% range",                             missing_ranges,                 0,
  "95% ranges that leave out their own median",                       ranges_missing_median,          0,
  "Main same-day comparisons with fewer than 1,700 days",             short_main_comparisons,         0,
  "Main ranges whose ends move over 10% of their width (second seed)",  seed_shifts,                   0,
  "Runs in which Ship Channel NO2 is not clearly higher",             no2_runs_not_holding,           0,
  "Runs in which Houston minus Dallas-Fort Worth does not hold",      houston_dfw_runs_not_holding,   0,
  "2b figures on disk",                                               sum(file.exists(figure_paths)), 8,
  "Saved 2b tables without data dictionary rows",                     undocumented_records,           0,
  "Saved 2b tables at or over the GitHub limit",                      records_over_limit,             0
) %>%
  mutate(observed = as.character(observed)) %>%
  mutate(expected = as.character(expected))

text_checks <- tribble(
  ~check,                                                  ~observed,                    ~expected,
  "Sites and site-pollutants in the inventory",            inventory_size,               "33 sites, 68 site-pollutants",
  "Five-year sites per group: PM2.5, ozone, NO2, SO2",     five_year_counts,             "3/1/3, 6/10/6, 4/3/4, 3/1/0",
  "Runs in which Ship Channel ozone is not clearly lower", ozone_tally$runs_not_holding, "Memo-list groups",
  "Main results clear of zero under one seed only",        seed_verdict_changes,         "PM2.5, Ship Channel minus Houston other"
)

case_study_validation <- bind_rows(count_checks, text_checks) %>%
  mutate(passed = observed == expected)

print(case_study_validation, n = Inf, width = Inf)

stopifnot("Every 2b validation check passed" = all(case_study_validation$passed))

# CSV record: the validation table
validation_records <- list(
  case_study_validation = case_study_validation
)

save_records(validation_records, records_dir)

validation_dictionary <- tribble(
  ~table,                  ~column,    ~description,
  "case_study_validation", "check",    "What 2b section 8 checks: inputs, site sets, 95% ranges, findings or saved files",
  "case_study_validation", "observed", "Value found in this run",
  "case_study_validation", "expected", "Value the check requires",
  "case_study_validation", "passed",   "TRUE when observed equals expected; the script stops otherwise"
)

validation_dictionary <- document_tables(validation_records, validation_dictionary)

replace_own_rows(validation_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))
