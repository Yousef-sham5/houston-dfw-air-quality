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

source(here("R", "utils.R"))

# fitting pkgs get called with :: so MASS (which fitdistrplus attaches) never masks dplyr's select()
stopifnot(
  "moments is installed (run R/0_setup.R)" = requireNamespace("moments", quietly = TRUE),
  "fitdistrplus is installed (run R/0_setup.R)" = requireNamespace("fitdistrplus", quietly = TRUE),
  "readxl is installed (run R/0_setup.R)" = requireNamespace("readxl", quietly = TRUE)
)



# CONFIG ----
processed_dir <- here("data", "processed")

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

five_year_site_counts <- c("PM2.5" = 769L, "Ozone" = 964L, "NO2" = 312L, "SO2" = 301L, "CO" = 135L)

five_year_site_days <- 4016891L

year_round_ozone_sites <- 615L

fireworks_events <- c("July 4 fireworks", "New Year fireworks")

partial_winter_years <- c(min(study_years), max(study_years) + 1)

t640_method_codes <- c("636", "638", "736", "738")

sampling_schedules <- c("Daily" = 1, "1-in-3" = 3, "1-in-6" = 6)

# values at or below zero are just noise around a true level near zero. fits use half the method's federal
# MDL instead, the reported value stays next to it
mdl_fraction <- 0.5

# a site with at least this share of days at or below zero gets left out of the fits and read through spike days.
# in the case study that's clinton, croquet and park place SO2
near_zero_share <- 0.25

# copied from 2b CONFIG so the case-study fits use the same groups and with and without checks
harris_groups_path <- here("data", "reference", "harris_site_channel_distance.csv")

ship_channel_km <- 7.5

transition_km <- 15

transition_band <- str_c(ship_channel_km, " to ", transition_km, " km")

# north loop, southwest fwy, LBJ fwy, california pkwy north
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

houston_so2_ids <- c(
  "Clinton"              = "48-201-1035",
  "Houston Croquet"      = "48-201-0051",
  "Park Place"           = "48-201-0416",
  "Houston Deer Park #2" = "48-201-1039"
)

warm_months <- c("Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct")

# census west region (AK, AZ, CA, CO, HI, ID, MT, NV, NM, OR, UT, WA, WY), copied from 2a, for the PM2.5 region check
western_state_codes <- c("02", "04", "06", "08", "15", "16", "30", "32", "35", "41", "49", "53", "56")

qq_percentiles <- c(1, 5, 10, 25, 50, 75, 90, 95, 99)

# histogram bins of each day / its site's median on a log2 scale: quarter-steps from 1/16 to 16x the median.
# days past either end go in the end bins
shape_bin_width <- 0.25

shape_bin_limit <- 4

# SO2 monitors with this MDL report most days under it, so one check keeps only the lower-limit sites
coarse_so2_limit <- 2

min_shape_days <- 100

# a curve fits a site closely when none of its percentiles misses by more than this many SDs
close_fit_miss <- 0.25

# federal MDL of the case-study ozone monitors. readings under it are noise, and on a log scale a
# few of them can drag the skew way off
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

# section 4: the 3 curves in the contest. normal gets fitted next to them as a reference bc section 3 found
# it closest for ozone
contest_curves <- c("lognormal", "gamma", "weibull")

fitdist_names <- c("lognormal" = "lnorm", "gamma" = "gamma", "weibull" = "weibull", "normal" = "norm")

# every curve has 2 params so AIC's penalty cancels and the ranking is just the likelihood
curve_parameter_count <- 2

# fitdistrplus's default stopping rule can leave a shape about 0.08% off the optimum, which moves P99 and the test
# stats in the 4th digit, so its fits run to this tighter rule
fit_relative_tolerance <- 1e-12

# the fast fit has to match fitdistrplus within this AIC on the main run
fit_agreement_tolerance <- 0.001

# usual rule of thumb for a decisive AIC gap. it assumes independent days so the gap also gets scaled for linked days
decisive_aic_gap <- 10

weibull_step_tolerance <- 1e-8

min_link_pairs <- 30

# how often a winner survives resampling. nearby days are linked so whole 2-week blocks get drawn like 2b. a winner
# counts as clear at this share of resamples. all case-study sites + a seeded sample per pollutant get resampled
stability_block_days <- 14

stability_reps <- 100

stability_seed <- 2026

stability_sample_sites <- 100

clear_winner_share <- 0.9

min_tail_days <- 200

# below-limit readings only get censored for the 2 agreed pollutants, and rounding only for CO's 0.1 ppm steps
censored_pollutants <- c("SO2", "CO")

rounded_pollutants <- "CO"

min_instrument_side_days <- 365

# ranges for gaps in group spread: same-date blocks across every site bc sites share weather. copied from 2b
group_range_reps <- 1000

group_range_seed <- 2026

group_range_check_seed <- 2027

group_range_seed_tolerance <- 0.1

group_range_pollutants <- c("PM2.5", "Ozone", "NO2")

stopifnot(
  "Every contest curve has a fitdistrplus name" = all(contest_curves %in% names(fitdist_names)),
  "The normal curve is the reference beside the contest" = setequal(setdiff(names(fitdist_names), contest_curves), "normal"),
  "Stability uses the same block length as 2b" = stability_block_days == 14,
  "A clear winner's share is a fraction" = between(clear_winner_share, 0.5, 1),
  "The seed check uses a different seed" = group_range_check_seed != group_range_seed,
  "Censored pollutants are in the fits" = all(c(censored_pollutants, rounded_pollutants) %in% pollutant_levels),
  "Tail ratios need at least the days a shape needs" = min_tail_days >= min_shape_days,
  "Each group-range pollutant is in the case study" = all(group_range_pollutants %in% pollutant_levels)
)

# section 5: how each short-term standard rounds a daily value before comparing to the limit, copied from 2a.
# first_counted = lowest reading that counts as over the limit
short_term_limits <- tribble(
  ~pollutant, ~limit, ~digits, ~rounding,
  "PM2.5",    35,     0,       "half up",
  "Ozone",    0.070,  3,       "truncate",
  "NO2",      100,    0,       "half up",
  "SO2",      75,     0,       "half up",
  "CO",       9,      0,       "half up"
) %>%
  mutate(first_counted = if_else(rounding == "truncate", limit + 10^-digits, limit + 0.5 * 10^-digits))

tail_percentiles <- c("P98" = 0.98, "P99" = 0.99)

tail_test_levels <- c("Limit", names(tail_percentiles))

# a single site only gets judged with this many actual days, 2 expected vs 1 actual is mostly luck
min_judged_days <- 10

close_tail_ratio <- 1.25

n_top_tail_sites <- 10

# resamples for the ozone tail ranges, the ends need more draws than section 4's gaps to settle within seed tolerance
tail_range_reps <- 2000

# slowest steps save their results here (git ignores it). TRUE recomputes them all and overwrites what's saved
cache_dir <- here("data", "distribution_cache")

rerun_cached_steps <- FALSE

stopifnot(
  "Every pollutant has a short-term limit" = setequal(short_term_limits$pollutant, pollutant_levels),
  "Ozone counts from 0.071 ppm and PM2.5 from 35.5" =
    isTRUE(all.equal(short_term_limits$first_counted[short_term_limits$pollutant == "Ozone"], 0.071)) &&
    short_term_limits$first_counted[short_term_limits$pollutant == "PM2.5"] == 35.5,
  "Tail percentiles rise and stay inside the curve" = !is.unsorted(tail_percentiles) && all(between(tail_percentiles, 0.5, 1)),
  "The closeness ratio is above 1" = close_tail_ratio > 1
)

# section 6: EPA's ozone design value (40 CFR 50, Appendix U) for houston aldine, then every case-study ozone site,
# vs EPA's 2023-2025 design value file, downloaded from epa.gov/air-trends/air-quality-design-values on 2026-11-12
design_value_path <- here("data", "reference", "o3_designvalues_2023_2025_final_06_08_26.xlsx")

design_value_md5 <- "3845feca4954632cd990eb993ba03c28"

aldine_id <- "48-201-0024"

# appendix U 4(a) and 4(b): the standard, and the share of ozone-season days a valid design value needs, on avg over
# 3 years and in each year
ozone_standard_ppm <- 0.070

design_value_completeness <- c(average = 90, each_year = 75)

design_value_windows <- tibble(first_year = min(study_years):(max(study_years) - 2)) %>%
  mutate(last_year = first_year + 2)

stopifnot(
  "EPA's design value file is in data/reference" = file.exists(design_value_path),
  "The standard matches the ozone limit of section 5" = ozone_standard_ppm == short_term_limits$limit[short_term_limits$pollutant == "Ozone"],
  "Three windows: 2021-2023, 2022-2024 and 2023-2025" = nrow(design_value_windows) == 3 && max(design_value_windows$last_year) == 2025
)



# FIGURE STYLE ----
# journal-style figures (helpers in utils.R). these settings override utils.R's colours + fonts here only
stopifnot("Arial is installed, since Phase 3 figures use it" = str_detect(systemfonts::match_fonts("Arial")$path, regex("arial", ignore_case = TRUE)))

chart_fonts[] <- "Arial"

chart_ink[c("primary", "secondary", "muted", "grid", "axis")] <- c("#000000", "#333333", "#666666", "#EBEBEB", "#999999")

chart_fills[c("accent", "other", "band")] <- c("#1D5D9B", "#B5B5B5", "#F2F2F2")

site_group_colours[] <- c("#D55E00", "#0072B2", "#009E73")

chart_sizes[c("key", "label")] <- c(7, 6.5)



# 1. FIT TABLE AND DATA NUANCES ----
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

fit_instruments <- fit_instruments %>%
  mutate(value = if_else(pollutant == "PM2.5", arithmetic_mean, first_max_value))

stopifnot(
  "Every instrument-day has a value" = !anyNA(fit_instruments$value),
  "Every instrument-day has an FRM or FEM method type" = all(fit_instruments$method_type %in% c("FRM", "FEM")),
  "Every instrument-day has a federal detection limit" = !anyNA(fit_instruments$federal_mdl) && all(fit_instruments$federal_mdl > 0),
  "Detection limits are in the data's units" = all(fit_instruments$mdl_units == fit_instruments$units_of_measure)
)

# collocated instruments averaged per site-day like 2a. sorting puts each site-day's rows
# together so rowsum() can total them in one pass
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

# fitting copy: values at or below zero become half the MDL, everything else stays as reported
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

# method codes each year. a site whose set of codes changes swapped or added an instrument, which can shift its level
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

# measurement step = smallest gap between a site's distinct positive readings, before averaging. coarse steps
# (ozone 0.001 ppm, CO 0.1 ppm) give lots of ties, which fit tests built for smooth data don't handle well
value_steps <- fit_instruments %>%
  filter(value > 0) %>%
  distinct(pollutant, site_id, value) %>%
  arrange(pollutant, site_id, value) %>%
  mutate(step = round(value - lag(value), 6), .by = c(pollutant, site_id)) %>%
  summarise(n_distinct_values = n(), value_step = min(step, na.rm = TRUE), .by = c(pollutant, site_id))

rm(fit_instruments, method_sets)
invisible(gc())

# sampling schedule per site-year from the typical gap between samples. a PM2.5 site going from 1-in-3 to daily
# catches more high days, so its exceedance counts can go up without the air changing at all
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

# sites with dec or jan data every year. seasonal ozone monitors stop in autumn so a year-round fit there
# only describes the ozone season
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

# case-study 5-yr site-days from 2a section 7, with the houston distance bands from 1c and the checks 2b runs
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

inventory_dictionary <- document_tables(inventory_records, inventory_dictionary)

replace_own_rows(inventory_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 2. DESCRIPTIVE TABLE ----
# summary stats of the reported values in original units. pooled numbers weight each site by its days and mix the
# gaps between sites with the swings inside a site, so each row also gives the typical site's own mean, SD and skewness
# and the share of pooled variance that's between sites. skewness 0 and kurtosis 3 = normal curve
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

drop_unchanged_checks <- function(summary_rows, group_cols, kept_sets = c("All days", "Ordinary days")) {
  ordinary_days <- summary_rows %>%
    filter(site_set == "Ordinary days") %>%
    select(all_of(group_cols), ordinary_site_days = n_site_days)

  summary_rows %>%
    left_join(ordinary_days, by = group_cols, relationship = "many-to-one") %>%
    filter(site_set %in% kept_sets | n_site_days != ordinary_site_days) %>%
    select(-ordinary_site_days)
}

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

# means don't describe a group led by near-zero SO2 sites where most daily maxes sit at the noise floor, so those
# rows only keep the percentiles and shares. nationally these sites are a minority and a check row drops them
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

summary_dictionary <- document_tables(summary_records, summary_dictionary)

replace_own_rows(summary_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))



# 3. SHAPE OF THE DAILY VALUES ----
shape_bins <- tibble(bin = seq(-shape_bin_limit, shape_bin_limit - shape_bin_width, by = shape_bin_width)) %>%
  mutate(bin_upper = bin + shape_bin_width) %>%
  mutate(is_open_ended = bin == min(bin) | bin_upper == max(bin_upper))

# bin for each day. rounding first keeps a day sitting right on an edge in the upper bin, since a ratio of 2 can
# come out as just under 2
shape_bin_of <- function(log2_ratio) {
  pmin(pmax(floor(round(log2_ratio, 10) / shape_bin_width) * shape_bin_width, min(shape_bins$bin)), max(shape_bins$bin))
}

# share of a site's days its own lognormal puts in the wrong bin: half the absolute gaps bc each
# misplaced day counts twice. done site by site bc averaging sites first would cancel their misses
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

# how far each percentile misses a perfect normal curve, in SDs. pass the logs to measure the miss from a lognormal
qq_miss <- function(values) {
  abs((quantile(values, qq_percentiles / 100, names = FALSE) - mean(values)) / sd(values) - qnorm(qq_percentiles / 100))
}

# each site's own shape on the fitting copy, before and after logs, near-zero sites dropped like in the fits. the
# ratios compare the site's percentiles with the normal and lognormal curves with the same mean and SD. quantile
# skew uses the 10th, 50th, 90th pcts so a few really low days can't drive it. values get rounded before
# counting ties bc averaging instruments can leave 5.8 and 5.8000000000000007
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

# Q-Q summary: at each site, how many SDs each percentile is from the mean, on the plain and log scale. a perfect
# normal or lognormal site would match the theoretical value. standard units still work at the low end, where a normal
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

# share of days in each bin of value / site median (each site counts once), next to what each site's own lognormal
# would put there. dividing by the site median removes the gaps between sites so only the shape's left
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

# fitting days without near-zero sites, ordinary days as the main run. site flags from section 1 drive the checks
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

figure_percentiles <- c(1, 10, 50, 90, 99)

ratio_breaks <- c(-4, -2, 0, 2, 4)

ratio_labels <- c("1/16", "1/4", "1", "4", "16")

national_panel_names <- c("PM2.5" = "PM2.5", "Ozone" = "Ozone", "NO2" = "NO2", "SO2" = "SO2", "CO" = "CO")

# Q-Q panels plot the miss from a perfect fit in SDs so u can actually see the small gaps at each percentile
miss_breaks <- c(-1, 0, 1)

miss_labels <- c("\u22121", "0", "+1")

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
    geom_line(aes(y = pct_lognormal), colour = chart_ink[["primary"]], linewidth = 0.45) +
    scale_x_continuous(
      breaks = ratio_breaks,
      labels = ratio_labels,
      limits = c(-shape_bin_limit, shape_bin_limit),
      expand = expansion(mult = 0.01)
    ) +
    scale_y_continuous(breaks = breaks_pretty(n = 3), labels = \(x) str_c(x, "%"), expand = expansion(mult = c(0, 0.08))) +
    labs(
      title = panel_label(panel_number, national_panel_names[[pollutant_name]]),
      subtitle = sprintf(
        "Typical site %.1f%% off lognormal; %s sites", gap, comma(national_main_shapes$n_sites[national_main_shapes$pollutant == pollutant_name])
      ),
      x = "Day \u00f7 site median, log scale",
      y = "Share of days"
    ) +
    theme_paper()
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

  ggplot(points, aes(theoretical_z, median_observed_z - theoretical_z, colour = reference)) +
    geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35, linetype = "22") +
    geom_line(linewidth = 0.55) +
    geom_point(size = 0.9) +
    scale_colour_manual(values = c("Normal" = chart_ink[["muted"]], "Lognormal" = chart_fills[["accent"]]), guide = "none") +
    scale_x_continuous(breaks = qnorm(figure_percentiles / 100), labels = str_c("P", figure_percentiles)) +
    scale_y_continuous(breaks = miss_breaks, labels = miss_labels) +
    coord_cartesian(ylim = miss_limits) +
    labs(title = panel_label(panel_number, national_panel_names[[pollutant_name]]), subtitle = closer_label, x = "Percentile", y = "Miss in SDs") +
    theme_paper()
}

log_suited_pollutants <- c("PM2.5", "SO2", "CO")

near_normal_pollutants <- c("Ozone", "NO2")

national_shape_panels <- function(pollutant_names) {
  unlist(
    lapply(seq_along(pollutant_names), \(i) list(
      national_shape_histogram_panel(pollutant_names[i], 2 * i - 1),
      national_qq_panel(pollutant_names[i], 2 * i)
    )),
    recursive = FALSE
  )
}

national_check_rows <- shape_summary %>%
  filter(scope == "National")

log_suited_rows <- national_check_rows %>%
  filter(pollutant %in% c("PM2.5", "SO2", "CO"))

ozone_check_rows <- national_check_rows %>%
  filter(pollutant == "Ozone")

no2_check_rows <- national_check_rows %>%
  filter(pollutant == "NO2")

stopifnot(
  "A lognormal is closer and logs bring skew nearer zero at 75% of PM2.5, SO2 and CO sites under every check" =
    all(log_suited_rows$pct_sites_lognormal_closer >= 75) && all(log_suited_rows$pct_sites_log_nearer_symmetry >= 75),
  "A normal curve is closer at three in four ozone sites under every check" =
    all(ozone_check_rows$pct_sites_lognormal_closer <= 25),
  "NO2 sites split between the two curves under every check" =
    all(between(no2_check_rows$pct_sites_lognormal_closer, 50, 75))
)

national_shape_key <- tribble(
  ~mark,    ~colour,                 ~label,
  "square", chart_fills[["accent"]], "Days around the site median",
  "line",   chart_ink[["primary"]],  "Lognormal curve",
  "range",  chart_fills[["accent"]], "Lognormal miss",
  "range",  chart_ink[["muted"]],    "Normal miss",
  "dashed", chart_ink[["primary"]],  "Perfect fit"
)

log_suited_figure <- tagged_figure(
  national_shape_panels(log_suited_pollutants),
  national_shape_key,
  source_note = sprintf(
    str_c(
      "Source: EPA AQS daily data, %s to %s, ordinary days, five-year sites; values at or below zero at half the detection limit, ",
      "near-zero sites left out. Right: median site; above zero, the actual percentile runs higher."
    ),
    min(study_years), max(study_years)
  )
)

near_normal_figure <- tagged_figure(
  national_shape_panels(near_normal_pollutants),
  national_shape_key,
  source_note = sprintf(
    str_c(
      "Source: EPA AQS daily data, %s to %s, ordinary days, five-year sites; values at or below zero at half the detection limit, ",
      "near-zero sites left out. Right: median site; above zero, the actual percentile runs higher."
    ),
    min(study_years), max(study_years)
  )
)

dir.create(figures_dir, recursive = TRUE, showWarnings = FALSE)

save_figure(log_suited_figure, "3.01_shape_log_scale.png", 5.45)

save_figure(near_normal_figure, "3.02_shape_ozone_no2.png", 4.05)

case_group_note <- function(pollutant_name) {
  counts <- case_main_shapes %>%
    filter(pollutant == pollutant_name)
  if (nrow(counts) == 1) return(sprintf("%d site", counts$n_sites))
  sprintf(
    "Sites: Ship Channel %d, Houston other %d, Dallas-Fort Worth %d",
    counts$n_sites[counts$site_group == "Houston Ship Channel"], counts$n_sites[counts$site_group == "Houston other"],
    counts$n_sites[counts$site_group == "Dallas-Fort Worth"]
  )
}

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
    labs(
      title = panel_label(panel_number, panel_name),
      subtitle = case_group_note(pollutant_name),
      x = "Day \u00f7 site median, log scale",
      y = "Share of days"
    ) +
    theme_paper()
}

case_qq_panel <- function(pollutant_name, reference_name, panel_number, panel_name) {
  ggplot(
    filter(qq_points, scope == "Case study", pollutant == pollutant_name, reference == reference_name),
    aes(theoretical_z, median_observed_z - theoretical_z, colour = site_group, shape = site_group)
  ) +
    geom_hline(yintercept = 0, colour = chart_ink[["primary"]], linewidth = 0.35, linetype = "22") +
    geom_line(linewidth = 0.55) +
    geom_point(size = 1.1) +
    scale_colour_manual(values = site_group_colours, guide = "none") +
    scale_shape_manual(values = site_group_shapes, guide = "none") +
    scale_x_continuous(breaks = qnorm(c(1, 50, 99) / 100), labels = c("P1", "P50", "P99")) +
    scale_y_continuous(breaks = miss_breaks, labels = miss_labels) +
    coord_cartesian(ylim = miss_limits) +
    labs(
      title = panel_label(panel_number, panel_name),
      subtitle = str_c("Against ", str_to_lower(reference_name)),
      x = "Percentile",
      y = "Miss in SDs"
    ) +
    theme_paper()
}

case_panel_names <- c("PM2.5" = "PM2.5", "Ozone" = "Ozone", "NO2" = "NO2", "SO2" = "SO2, Deer Park #2")

case_histogram_panels <- lapply(seq_along(case_panel_names), \(i) case_histogram_panel(names(case_panel_names)[i], i, case_panel_names[[i]]))

case_qq_panels <- unlist(
  lapply(seq_along(case_panel_names), \(i) list(
    case_qq_panel(names(case_panel_names)[i], "Lognormal", 2 * i - 1, case_panel_names[[i]]),
    case_qq_panel(names(case_panel_names)[i], "Normal", 2 * i, case_panel_names[[i]])
  )),
  recursive = FALSE
)

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
  "Spread factors and quantile skews sit close across the groups under every check" =
    all(group_shape_ranges$spread_ratio < 1.15) && all(group_shape_ranges$quantile_skew_range < 0.15),
  "A normal curve is closer at every case-study ozone site in the cool season" = sum(ozone_cool$n_lognormal_closer) == 0,
  "A lognormal is closer at most Houston ozone sites in the warm season" =
    sum(houston_warm$n_lognormal_closer) / sum(houston_warm$n_sites) > 0.75,
  "Dallas-Fort Worth ozone splits in the warm season" = dfw_warm$n_lognormal_closer == dfw_warm$n_sites / 2,
  "Year-round, a lognormal is closer at every Houston ozone site and at no Dallas-Fort Worth site" =
    all(houston_year_round$n_lognormal_closer == houston_year_round$n_sites) && dfw_year_round$n_lognormal_closer == 0,
  "Every case-study ozone monitor has the detection limit in CONFIG" = all(ozone_case_days$federal_mdl == very_low_ozone_ppm),
  "Readings below the limit are a tiny share of Dallas-Fort Worth ozone and halve its log skew gap to Houston" =
    nrow(dfw_very_low_days) / sum(ozone_case_days$site_group == "Dallas-Fort Worth") < 0.005 &&
    all(dfw_ozone_log_skew < houston_ozone_log_skew - 0.5) &&
    mean(houston_ozone_trimmed_skew) - dfw_ozone_trimmed_skew <= 0.6 * (mean(houston_ozone_log_skew) - dfw_ozone_log_skew)
)

# deer park #2 SO2: half the MDL lands on the same value as a common reading, so one value holds a lot of days
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

deer_park_so2_median <- median(deer_park_so2_days$value_fit)

stopifnot(
  "Deer Park #2 SO2 readings come in 0.1 ppb steps" =
    all(abs(10 * deer_park_so2_days$value_fit - round(10 * deer_park_so2_days$value_fit)) < 1e-9)
)

case_shape_note <- sprintf(
  str_c(
    "Source: EPA AQS daily data, %s to %s, ordinary days, case-study sites with data in all five years. SO2 is Deer Park #2 alone; its ",
    "readings come in 0.1 ppb steps (%s below the %s ppb limit) around a median of %s ppb, so low days fall on a few ratios."
  ),
  min(study_years), max(study_years), deer_park_so2_top$value_fit, unique(deer_park_so2_days$federal_mdl), deer_park_so2_median
)

case_group_lines <- tribble(
  ~mark,  ~colour,                                      ~label,
  "line", site_group_colours[["Houston Ship Channel"]], "Ship Channel",
  "line", site_group_colours[["Houston other"]],        "Houston other",
  "line", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth"
)

case_shape_figure <- tagged_figure(
  case_histogram_panels,
  case_group_lines,
  source_note = case_shape_note
)

case_qq_figure <- tagged_figure(
  case_qq_panels,
  bind_rows(
    mutate(case_group_lines, mark = "range", shape = unname(site_group_shapes)),
    tibble(mark = "dashed", colour = chart_ink[["primary"]], label = "Perfect fit", shape = 16)
  ),
  source_note = case_shape_note
)

save_figure(case_shape_figure, "3.03_case_study_shape.png", 4.45)

save_figure(case_qq_figure, "3.04_case_study_qq.png", 7.3)

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

shape_dictionary <- document_tables(shape_records, shape_dictionary)

replace_own_rows(shape_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(shape_days, ordinary_shape_days, case_shape_days, case_site_shapes)
invisible(gc())



# 4. FITTED CURVES ----
# slow steps reuse their saved result only while the days, settings and code match what made it, otherwise recompute
step_fingerprint <- function(data, settings, code) {
  tools::md5sum(bytes = serialize(
    list(data = data, settings = settings, code = lapply(code, deparse), r_version = R.version.string),
    NULL,
    version = 2
  ))
}

cached_step <- function(step_name, data, settings, code, compute) {
  fingerprint <- step_fingerprint(data, settings, code)
  cache_path <- file.path(cache_dir, str_c(step_name, ".rds"))
  saved <- if (!rerun_cached_steps && file.exists(cache_path)) read_rds(cache_path) else NULL
  if (identical(saved$fingerprint, fingerprint)) {
    cat("Reused the saved result:", step_name, "\n")
    return(saved$result)
  }
  result <- compute()
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  partial_path <- str_c(cache_path, ".partial")
  write_rds(list(fingerprint = fingerprint, result = result), partial_path, compress = "gz")
  stopifnot("The saved result replaces the old one" = file.rename(partial_path, cache_path))
  result
}

# each site's values get divided by their mean first so params have no units and compare across sites. AIC then
# compares curves inside one site and one check
fast_curve_parameters <- function(values) {
  scaled <- values / mean(values)
  log_scaled <- log(scaled)
  mean_log <- mean(log_scaled)
  sd_log <- sqrt(mean((log_scaled - mean_log)^2))
  gamma_term <- -mean_log
  gamma_shape <- (3 - gamma_term + sqrt((gamma_term - 3)^2 + 24 * gamma_term)) / (12 * gamma_term)
  for (step in 1:10) {
    gamma_shape <- gamma_shape - (log(gamma_shape) - digamma(gamma_shape) - gamma_term) / (1 / gamma_shape - trigamma(gamma_shape))
  }
  weibull_shape <- 1.2 / sd_log
  weibull_settled <- FALSE
  for (step in 1:60) {
    powered <- scaled^weibull_shape
    power_sum <- sum(powered)
    log_sum <- sum(powered * log_scaled)
    slope <- log_sum / power_sum - 1 / weibull_shape - mean_log
    curvature <- (sum(powered * log_scaled^2) * power_sum - log_sum^2) / power_sum^2 + 1 / weibull_shape^2
    weibull_step <- slope / curvature
    weibull_shape <- max(weibull_shape - weibull_step, weibull_shape / 2)
    if (abs(weibull_step) < weibull_step_tolerance) {
      weibull_settled <- TRUE
      break
    }
  }
  stopifnot("Each Weibull fit settles" = weibull_settled)
  list(
    scaled = scaled,
    meanlog = mean_log,
    sdlog = sd_log,
    gamma_shape = gamma_shape,
    gamma_rate = gamma_shape,
    weibull_shape = weibull_shape,
    weibull_scale = mean(scaled^weibull_shape)^(1 / weibull_shape),
    normal_mean = 1,
    normal_sd = sqrt(mean((scaled - 1)^2))
  )
}

package_curve_parameters <- function(values) {
  scaled <- values / mean(values)
  estimates <- lapply(fitdist_names, \(curve) fitdistrplus::fitdist(scaled, curve, control = list(reltol = fit_relative_tolerance))$estimate)
  list(
    scaled = scaled,
    meanlog = estimates$lognormal[["meanlog"]],
    sdlog = estimates$lognormal[["sdlog"]],
    gamma_shape = estimates$gamma[["shape"]],
    gamma_rate = estimates$gamma[["rate"]],
    weibull_shape = estimates$weibull[["shape"]],
    weibull_scale = estimates$weibull[["scale"]],
    normal_mean = estimates$normal[["mean"]],
    normal_sd = estimates$normal[["sd"]]
  )
}

curve_log_likelihoods <- function(parameters) {
  scaled <- parameters$scaled
  c(
    lognormal = sum(dlnorm(scaled, parameters$meanlog, parameters$sdlog, log = TRUE)),
    gamma = sum(dgamma(scaled, parameters$gamma_shape, rate = parameters$gamma_rate, log = TRUE)),
    weibull = sum(dweibull(scaled, parameters$weibull_shape, parameters$weibull_scale, log = TRUE)),
    normal = sum(dnorm(scaled, parameters$normal_mean, parameters$normal_sd, log = TRUE))
  )
}

curve_quantiles <- function(probability, parameters) {
  c(
    lognormal = qlnorm(probability, parameters$meanlog, parameters$sdlog),
    gamma = qgamma(probability, parameters$gamma_shape, rate = parameters$gamma_rate),
    weibull = qweibull(probability, parameters$weibull_shape, parameters$weibull_scale),
    normal = qnorm(probability, parameters$normal_mean, parameters$normal_sd)
  )
}

curve_probabilities <- function(curve, values, parameters) {
  switch(
    curve,
    lognormal = plnorm(values, parameters$meanlog, parameters$sdlog),
    gamma = pgamma(values, parameters$gamma_shape, rate = parameters$gamma_rate),
    weibull = pweibull(values, parameters$weibull_shape, parameters$weibull_scale)
  )
}

# one row per site: AIC for each curve, the winner with and without the normal curve, and where the curves miss the tail.
# KS and anderson-darling are just stats here, their p-values assume smooth independent data and a curve not fit to it
describe_site_fit <- function(parameters) {
  scaled <- parameters$scaled
  n_days <- length(scaled)
  aic <- 2 * curve_parameter_count - 2 * curve_log_likelihoods(parameters)
  contest_aic <- aic[contest_curves]
  winner <- names(which.min(contest_aic))
  fitted_p99 <- curve_quantiles(0.99, parameters)
  fitted_p05 <- curve_quantiles(0.05, parameters)
  actual_p99 <- quantile(scaled, 0.99, names = FALSE)
  actual_p05 <- quantile(scaled, 0.05, names = FALSE)
  has_tail <- n_days >= min_tail_days
  ordered_probability <- curve_probabilities(winner, sort(scaled), parameters)
  bounded_probability <- pmin(pmax(ordered_probability, 1e-12), 1 - 1e-12)
  ranks <- seq_len(n_days)
  tibble(
    n_days = n_days,
    aic_lognormal = aic[["lognormal"]],
    aic_gamma = aic[["gamma"]],
    aic_weibull = aic[["weibull"]],
    aic_normal = aic[["normal"]],
    winner = winner,
    winner_with_normal = names(which.min(aic)),
    aic_gap = sort(contest_aic)[[2]] - sort(contest_aic)[[1]],
    spread_factor = exp(parameters$sdlog),
    gamma_shape = parameters$gamma_shape,
    weibull_shape = parameters$weibull_shape,
    p99_over_lognormal = if (has_tail) actual_p99 / fitted_p99[["lognormal"]] else NA_real_,
    p99_over_gamma = if (has_tail) actual_p99 / fitted_p99[["gamma"]] else NA_real_,
    p99_over_weibull = if (has_tail) actual_p99 / fitted_p99[["weibull"]] else NA_real_,
    p99_over_normal = if (has_tail) actual_p99 / fitted_p99[["normal"]] else NA_real_,
    p99_over_winner = if (has_tail) actual_p99 / fitted_p99[[winner]] else NA_real_,
    p05_over_winner = if (has_tail) actual_p05 / fitted_p05[[winner]] else NA_real_,
    closest_at_p99 = if (has_tail) names(which.min(abs(log(actual_p99 / fitted_p99[contest_curves])))) else NA_character_,
    ks_statistic = max(ranks / n_days - ordered_probability, ordered_probability - (ranks - 1) / n_days),
    anderson_darling = -n_days - mean((2 * ranks - 1) * (log(bounded_probability) + log(1 - rev(bounded_probability))))
  )
}

fit_sites <- function(site_days, site_set, curve_parameters = fast_curve_parameters) {
  kept_days <- site_days %>%
    filter(n() >= min_shape_days, .by = c(pollutant, site_id))

  site_values <- split(kept_days$value_fit, str_c(kept_days$pollutant, "|", kept_days$site_id))

  site_rows <- lapply(site_values, \(values) describe_site_fit(curve_parameters(values)))

  bind_rows(site_rows, .id = "site_key") %>%
    separate_wider_delim(site_key, "|", names = c("pollutant", "site_id")) %>%
    mutate(pollutant = factor(pollutant, levels = pollutant_levels)) %>%
    mutate(site_set = site_set)
}

# days behind each national fit, without near-zero sites. seasonal ozone monitors have too few cool days to describe
# that season, so the cool fits keep year-round ozone sites
fit_source_days <- fit_days %>%
  select(pollutant, site_id, date_local, month, event_class, n_instruments, has_t640, is_at_or_below_zero, value, federal_mdl, value_fit) %>%
  semi_join(filter(shape_site_flags, !is_near_zero_site), by = c("pollutant", "site_id"))

ordinary_fit_days <- fit_source_days %>%
  filter(event_class == "None")

day_order_check <- ordinary_fit_days %>%
  mutate(previous_date = lag(date_local), .by = c(pollutant, site_id)) %>%
  filter(!is.na(previous_date), date_local <= previous_date)

seasonal_ozone_sites <- shape_site_flags %>%
  filter(pollutant == "Ozone", !is_year_round) %>%
  select(pollutant, site_id)

warm_fit_days <- ordinary_fit_days %>%
  filter(month %in% warm_months)

cool_fit_days <- ordinary_fit_days %>%
  filter(!month %in% warm_months) %>%
  anti_join(seasonal_ozone_sites, by = c("pollutant", "site_id"))

stopifnot(
  "Days run in date order within each site" = nrow(day_order_check) == 0,
  "Every case-study ozone site reports all year" =
    !any(seasonal_ozone_sites$site_id %in% shape_site_flags$site_id[shape_site_flags$pollutant == "Ozone" & !is.na(shape_site_flags$site_group)]),
  "The fits start from the sites section 3 kept" = n_distinct(ordinary_fit_days$pollutant, ordinary_fit_days$site_id) == nrow(site_shapes)
)

main_fit_started <- Sys.time()

main_site_fits <- cached_step(
  "main_fits",
  select(ordinary_fit_days, pollutant, site_id, value_fit),
  list(min_shape_days, min_tail_days, contest_curves, fitdist_names, curve_parameter_count, fit_relative_tolerance, packageVersion("fitdistrplus")),
  list(fit_sites, package_curve_parameters, describe_site_fit, curve_log_likelihoods, curve_quantiles, curve_probabilities),
  \() fit_sites(ordinary_fit_days, "Ordinary days", package_curve_parameters)
)

cat("Main fits with fitdistrplus, seconds:", round(as.numeric(difftime(Sys.time(), main_fit_started, units = "secs"))), "\n")

fast_site_fits <- fit_sites(ordinary_fit_days, "Ordinary days")

fit_agreement <- main_site_fits %>%
  inner_join(fast_site_fits, by = c("pollutant", "site_id"), suffix = c("", "_fast"), relationship = "one-to-one") %>%
  mutate(largest_gap = pmax(
    abs(aic_lognormal - aic_lognormal_fast),
    abs(aic_gamma - aic_gamma_fast),
    abs(aic_weibull - aic_weibull_fast),
    abs(aic_normal - aic_normal_fast)
  ))

section_three_spreads <- site_shapes %>%
  select(pollutant, site_id, section_three_spread = spread_factor, section_three_days = n_days)

spread_agreement <- main_site_fits %>%
  inner_join(section_three_spreads, by = c("pollutant", "site_id"), relationship = "one-to-one")

cat("Largest AIC gap, fitdistrplus against the fast fit:", signif(max(fit_agreement$largest_gap), 3), "\n")

stopifnot(
  "One main fit per eligible site" = nrow(main_site_fits) == nrow(site_shapes),
  "The fast fit matches fitdistrplus on every site and curve" = max(fit_agreement$largest_gap) < fit_agreement_tolerance,
  "Both fits name the same winner at every site" = all(fit_agreement$winner == fit_agreement$winner_fast),
  "Fits use the days section 3 counted" = all(spread_agreement$n_days == spread_agreement$section_three_days),
  "Fitted spread matches section 3's spread factor" = all(abs(spread_agreement$spread_factor / spread_agreement$section_three_spread - 1) < 0.01)
)

site_fits <- bind_rows(
  main_site_fits,
  fit_sites(fit_source_days, "All days"),
  fit_sites(warm_fit_days, "Warm season"),
  fit_sites(cool_fit_days, "Cool season"),
  fit_sites(filter(ordinary_fit_days, !is_at_or_below_zero), "Without values at or below zero")
)

rm(fast_site_fits, spread_agreement, section_three_spreads, day_order_check)
invisible(gc())

# linked days: how much each day repeats the day before, and how many independent days that leaves. AIC gaps grow with n
# so they also get scaled down to those days
site_links <- ordinary_fit_days %>%
  mutate(log_value = log(value_fit)) %>%
  mutate(previous_log = lag(log_value), previous_date = lag(date_local), .by = c(pollutant, site_id)) %>%
  filter(date_local - previous_date == 1) %>%
  summarise(n_day_pairs = n(), lag1_correlation = cor(log_value, previous_log), .by = c(pollutant, site_id)) %>%
  mutate(lag1_correlation = if_else(n_day_pairs >= min_link_pairs, lag1_correlation, NA_real_))

site_fits <- site_fits %>%
  left_join(site_links, by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
  mutate(lag1_correlation = if_else(site_set == "Ordinary days", lag1_correlation, NA_real_)) %>%
  mutate(effective_days = pmin(n_days, n_days * (1 - lag1_correlation) / (1 + lag1_correlation))) %>%
  mutate(scaled_aic_gap = aic_gap * effective_days / n_days) %>%
  select(-n_day_pairs)

# winner stability. resampling every site would take about 22 min, so it covers every case-study site per season
# and a seeded sample nationally. each resample draws 2-week blocks of a site's days and checks which curve wins again
set.seed(stability_seed)

national_sample <- shape_site_flags %>%
  filter(!is_near_zero_site) %>%
  arrange(pollutant, site_id) %>%
  slice_sample(n = stability_sample_sites, by = pollutant) %>%
  select(pollutant, site_id) %>%
  mutate(site_set = "Ordinary days")

case_resample_sites <- shape_site_flags %>%
  filter(!is_near_zero_site, !is.na(site_group)) %>%
  select(pollutant, site_id) %>%
  cross_join(tibble(site_set = c("Ordinary days", "Warm season", "Cool season")))

resample_keys <- bind_rows(national_sample, case_resample_sites) %>%
  distinct() %>%
  arrange(site_set, pollutant, site_id)

contest_winner <- function(values) {
  names(which.max(curve_log_likelihoods(fast_curve_parameters(values))[contest_curves]))
}

winner_kept_share <- function(values) {
  n_days <- length(values)
  main_winner <- contest_winner(values)
  block_starts <- seq_len(n_days - stability_block_days + 1)
  n_blocks <- ceiling(n_days / stability_block_days)
  block_offsets <- seq_len(stability_block_days) - 1
  resample_winners <- vapply(seq_len(stability_reps), \(rep) {
    picked <- sample(block_starts, n_blocks, replace = TRUE)
    contest_winner(values[as.vector(outer(block_offsets, picked, `+`))][seq_len(n_days)])
  }, character(1))
  mean(resample_winners == main_winner)
}

resample_started <- Sys.time()

resample_keys <- cached_step(
  "winner_resamples",
  list(
    select(ordinary_fit_days, pollutant, site_id, value_fit),
    select(warm_fit_days, pollutant, site_id, value_fit),
    select(cool_fit_days, pollutant, site_id, value_fit),
    resample_keys
  ),
  list(stability_seed, stability_reps, stability_block_days, contest_curves, weibull_step_tolerance),
  list(contest_winner, winner_kept_share, fast_curve_parameters, curve_log_likelihoods),
  \() {
    resample_values <- list(
      "Ordinary days" = split(ordinary_fit_days$value_fit, str_c(ordinary_fit_days$pollutant, "|", ordinary_fit_days$site_id)),
      "Warm season" = split(warm_fit_days$value_fit, str_c(warm_fit_days$pollutant, "|", warm_fit_days$site_id)),
      "Cool season" = split(cool_fit_days$value_fit, str_c(cool_fit_days$pollutant, "|", cool_fit_days$site_id))
    )
    set.seed(stability_seed)
    resample_keys %>%
      mutate(winner_kept_share = vapply(seq_len(n()), \(i) {
        winner_kept_share(resample_values[[site_set[i]]][[str_c(pollutant[i], "|", site_id[i])]])
      }, numeric(1)))
  }
)

cat("Resampling winners, seconds:", round(as.numeric(difftime(Sys.time(), resample_started, units = "secs"))), "\n")

site_fits <- site_fits %>%
  left_join(resample_keys, by = c("pollutant", "site_id", "site_set"), relationship = "one-to-one") %>%
  mutate(winner_status = case_when(
    is.na(winner_kept_share) ~ "Not resampled",
    winner_kept_share >= clear_winner_share ~ "Clear",
    .default = "No clear winner"
  )) %>%
  left_join(
    select(
      shape_site_flags, pollutant, site_id, local_site_name, state_name, site_group, region, is_year_round, has_method_change,
      sampling_schedule, federal_mdl_max
    ),
    by = c("pollutant", "site_id"),
    relationship = "many-to-one"
  )

invisible(gc())

stopifnot(
  "Every resampled site found its fit" = sum(site_fits$winner_status != "Not resampled") == nrow(resample_keys),
  "One fit per site and check" = !anyDuplicated(select(site_fits, pollutant, site_id, site_set)),
  "Every fit has a winner" = all(site_fits$winner %in% contest_curves) && !anyNA(site_fits$aic_gap)
)

summarise_fits <- function(fits, group_cols) {
  fits %>%
    summarise(
      n_sites = n(),
      n_site_days = sum(n_days),
      wins_lognormal = sum(winner == "lognormal"),
      wins_gamma = sum(winner == "gamma"),
      wins_weibull = sum(winner == "weibull"),
      wins_with_normal_lognormal = sum(winner_with_normal == "lognormal"),
      wins_with_normal_gamma = sum(winner_with_normal == "gamma"),
      wins_with_normal_weibull = sum(winner_with_normal == "weibull"),
      wins_with_normal_normal = sum(winner_with_normal == "normal"),
      median_aic_gap = median(aic_gap),
      pct_sites_gap_decisive = 100 * mean(aic_gap >= decisive_aic_gap),
      median_lag1_correlation = median(lag1_correlation, na.rm = TRUE),
      median_effective_days = median(effective_days, na.rm = TRUE),
      median_scaled_aic_gap = median(scaled_aic_gap, na.rm = TRUE),
      pct_sites_scaled_gap_decisive = 100 * mean(scaled_aic_gap >= decisive_aic_gap, na.rm = TRUE),
      n_sites_resampled = sum(winner_status != "Not resampled"),
      pct_resampled_clear = 100 * sum(winner_status == "Clear") / sum(winner_status != "Not resampled"),
      median_winner_kept_share = median(winner_kept_share, na.rm = TRUE),
      spread_factor_median = median(spread_factor),
      spread_factor_q1 = quantile(spread_factor, 0.25, names = FALSE),
      spread_factor_q3 = quantile(spread_factor, 0.75, names = FALSE),
      gamma_shape_median = median(gamma_shape),
      weibull_shape_median = median(weibull_shape),
      n_sites_with_tail = sum(!is.na(p99_over_winner)),
      p99_over_lognormal_median = median(p99_over_lognormal, na.rm = TRUE),
      p99_over_gamma_median = median(p99_over_gamma, na.rm = TRUE),
      p99_over_weibull_median = median(p99_over_weibull, na.rm = TRUE),
      p99_over_normal_median = median(p99_over_normal, na.rm = TRUE),
      p99_over_winner_median = median(p99_over_winner, na.rm = TRUE),
      p99_over_winner_q1 = quantile(p99_over_winner, 0.25, names = FALSE, na.rm = TRUE),
      p99_over_winner_q3 = quantile(p99_over_winner, 0.75, names = FALSE, na.rm = TRUE),
      p05_over_winner_median = median(p05_over_winner, na.rm = TRUE),
      pct_sites_winner_closest_at_p99 = 100 * mean(closest_at_p99 == winner, na.rm = TRUE),
      ks_statistic_median = median(ks_statistic),
      anderson_darling_median = median(anderson_darling),
      .by = all_of(group_cols)
    ) %>%
    mutate(across(where(is.double), \(x) if_else(is.nan(x), NA_real_, x)))
}

ordinary_site_fits <- site_fits %>%
  filter(site_set == "Ordinary days")

national_fit_sets <- list(
  "Ordinary days" = ordinary_site_fits,
  "All days" = filter(site_fits, site_set == "All days"),
  "Warm season" = filter(site_fits, site_set == "Warm season"),
  "Cool season" = filter(site_fits, site_set == "Cool season"),
  "Without values at or below zero" = filter(site_fits, site_set == "Without values at or below zero"),
  "Year-round sites" = filter(ordinary_site_fits, is_year_round),
  "Sites on daily sampling" = filter(ordinary_site_fits, sampling_schedule == "Daily"),
  "Sites without a method change" = filter(ordinary_site_fits, !has_method_change),
  "Sites with a method change" = filter(ordinary_site_fits, has_method_change),
  "Western PM2.5 sites" = filter(ordinary_site_fits, pollutant == "PM2.5", region == "West"),
  "Eastern PM2.5 sites" = filter(ordinary_site_fits, pollutant == "PM2.5", region == "East"),
  "SO2 sites with a lower limit" = filter(ordinary_site_fits, pollutant == "SO2", federal_mdl_max < coarse_so2_limit)
)

# national resampling shares only count the random sample. case-study sites were hand-picked so they'd tilt it
random_sample_only <- function(fits) {
  fits %>%
    left_join(mutate(national_sample, in_random_sample = TRUE), by = c("pollutant", "site_id", "site_set"), relationship = "one-to-one") %>%
    mutate(winner_status = if_else(coalesce(in_random_sample, FALSE), winner_status, "Not resampled")) %>%
    mutate(winner_kept_share = if_else(coalesce(in_random_sample, FALSE), winner_kept_share, NA_real_)) %>%
    select(-in_random_sample)
}

national_fit_summary <- bind_rows(Map(
  \(fits, site_set) mutate(summarise_fits(random_sample_only(fits), "pollutant"), site_set = site_set),
  national_fit_sets,
  names(national_fit_sets)
)) %>%
  drop_unchanged_checks("pollutant", kept_sets = "Ordinary days") %>%
  mutate(scope = "National")

# same by case-study group with the checks 2b runs. the checks' site rows get fitted here since each
# check only changes a few sites
case_fit_source <- case_ordinary_shape_days %>%
  filter(pollutant != "CO")

case_check_days <- list(
  "Without the transition band" = filter(case_fit_source, !in_transition_band),
  "Without days after method changes" =
    filter(case_fit_source, !(coalesce(sensitivity_left_out == "Days after the method change", FALSE) & is_post_method_change)),
  "Without whole-site checks" = filter(case_fit_source, !coalesce(sensitivity_left_out == "Whole site", FALSE)),
  "Without Deer Park #2 after its move" = filter(case_fit_source, !is_post_relocation)
)

case_site_flags <- shape_site_flags %>%
  filter(!is.na(site_group)) %>%
  select(pollutant, site_id, local_site_name, state_name, site_group, region, is_year_round, has_method_change, sampling_schedule, federal_mdl_max)

case_check_fits <- bind_rows(Map(
  \(site_days, site_set) fit_sites(site_days, site_set),
  case_check_days,
  names(case_check_days)
)) %>%
  left_join(case_site_flags, by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
  mutate(winner_status = "Not resampled") %>%
  mutate(winner_kept_share = NA_real_) %>%
  mutate(lag1_correlation = NA_real_) %>%
  mutate(effective_days = NA_real_) %>%
  mutate(scaled_aic_gap = NA_real_)

case_main_sets <- site_fits %>%
  filter(!is.na(site_group), site_set %in% c("Ordinary days", "All days", "Warm season", "Cool season", "Without values at or below zero"))

case_fit_summary <- bind_rows(case_main_sets, case_check_fits) %>%
  summarise_fits(c(case_group_cols, "site_set")) %>%
  drop_unchanged_checks(case_group_cols, kept_sets = "Ordinary days") %>%
  mutate(scope = "Case study")

fit_summary <- bind_rows(national_fit_summary, case_fit_summary) %>%
  mutate(scope = factor(scope, levels = c("National", "Case study"))) %>%
  mutate(site_set = factor(site_set, levels = shape_summary_set_levels)) %>%
  arrange(scope, pollutant, site_group, site_set) %>%
  select(scope, pollutant, site_group, site_set, everything())

main_fit_days <- ordinary_site_fits %>%
  select(pollutant, site_id, main_days = n_days)

changed_check_fits <- case_check_fits %>%
  left_join(main_fit_days, by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
  filter(n_days != main_days) %>%
  select(-main_days)

stopifnot(
  "Forty-one case-study sites are fitted: PM2.5 7, ozone 22, NO2 11, SO2 1" =
    sum(fit_summary$n_sites[fit_summary$scope == "Case study" & fit_summary$site_set == "Ordinary days"]) == 41,
  "Fits name a set the shape table knows" = !anyNA(fit_summary$site_set),
  "Each main row counts every curve's wins" =
    all(with(fit_summary, wins_lognormal + wins_gamma + wins_weibull == n_sites)) &&
    all(with(fit_summary, wins_with_normal_lognormal + wins_with_normal_gamma + wins_with_normal_weibull + wins_with_normal_normal == n_sites))
)

# censored checks. a day under a limit counts as "somewhere under the limit" and the likelihood uses the curve's share
# under that limit, so the fill-in value doesn't matter. rounding treats each reading as an interval one step wide
censored_data <- function(site_days, version, step = NA_real_) {
  scale_value <- mean(site_days$value_fit)
  if (version == "Rounded readings") {
    lower <- pmax(site_days$value - step / 2, 0)
    upper <- pmax(site_days$value + step / 2, step / 2)
    return(data.frame(left = if_else(lower == 0, NA_real_, lower / scale_value), right = upper / scale_value))
  }
  is_censored <- if (version == "At or below zero censored") site_days$value <= 0 else site_days$value < site_days$federal_mdl
  data.frame(
    left = if_else(is_censored, NA_real_, site_days$value / scale_value),
    right = if_else(is_censored, site_days$federal_mdl / scale_value, site_days$value / scale_value)
  )
}

curve_starts <- function(parameters) {
  list(
    lognormal = list(meanlog = parameters$meanlog, sdlog = parameters$sdlog),
    gamma = list(shape = parameters$gamma_shape, rate = parameters$gamma_rate),
    weibull = list(shape = parameters$weibull_shape, scale = parameters$weibull_scale)
  )
}

# log(F(upper) - F(lower)) done on the log scale from whichever tail is smaller. a rare CO spike can sit so far out on a
# weibull or gamma curve that F rounds to exactly 1, which fitdistcens can't score
interval_log_probability <- function(curve, first, second, lower, upper) {
  log_tail <- function(q, lower_tail) {
    switch(
      curve,
      lognormal = plnorm(q, first, second, lower.tail = lower_tail, log.p = TRUE),
      gamma = pgamma(q, first, rate = second, lower.tail = lower_tail, log.p = TRUE),
      weibull = pweibull(q, first, second, lower.tail = lower_tail, log.p = TRUE)
    )
  }
  use_lower_tail <- log_tail(upper, TRUE) < log(0.5)
  larger <- if_else(use_lower_tail, log_tail(upper, TRUE), log_tail(lower, FALSE))
  smaller <- if_else(use_lower_tail, log_tail(lower, TRUE), log_tail(upper, FALSE))
  larger + log1p(-exp(smaller - larger))
}

fit_rounded_curve <- function(curve, grouped, start) {
  start_values <- unlist(start, use.names = FALSE)
  to_scale <- if (curve == "lognormal") c(identity, exp) else c(exp, exp)
  from_scale <- if (curve == "lognormal") c(identity, log) else c(log, log)
  lower <- coalesce(grouped$left, 0)
  negative_log_likelihood <- function(transformed) {
    first <- to_scale[[1]](transformed[1])
    second <- to_scale[[2]](transformed[2])
    -sum(grouped$n_days * interval_log_probability(curve, first, second, lower, grouped$right))
  }
  found <- optim(
    c(from_scale[[1]](start_values[1]), from_scale[[2]](start_values[2])),
    negative_log_likelihood,
    method = "BFGS",
    control = list(maxit = 500, reltol = fit_relative_tolerance)
  )
  stopifnot("Each rounded fit settles" = found$convergence == 0)
  estimate <- c(to_scale[[1]](found$par[1]), to_scale[[2]](found$par[2]))
  names(estimate) <- names(start)
  list(aic = 2 * curve_parameter_count + 2 * found$value, estimate = estimate)
}

# identical days get grouped with a count, same likelihood but way faster. the plain fit gives the starting
# values bc fitdistcens's defaults can get stuck. it warns about those defaults even when they're not used
censored_site_row <- function(site_days, version, step = NA_real_) {
  site_data <- censored_data(site_days, version, step)
  grouped <- site_data %>%
    mutate(left = round(left, 10)) %>%
    mutate(right = round(right, 10)) %>%
    count(left, right, name = "n_days") %>%
    as.data.frame()
  starts <- curve_starts(fast_curve_parameters(site_days$value_fit))
  actual_p99 <- quantile(site_days$value_fit / mean(site_days$value_fit), 0.99, names = FALSE)
  curve_fits <- lapply(setNames(contest_curves, contest_curves), \(curve) {
    if (version == "Rounded readings") {
      return(fit_rounded_curve(curve, grouped, starts[[curve]]))
    }
    withCallingHandlers(
      fitdistrplus::fitdistcens(
        grouped[, c("left", "right")],
        fitdist_names[[curve]],
        start = starts[[curve]],
        weights = grouped$n_days,
        calcvcov = FALSE,
        control = list(reltol = fit_relative_tolerance)
      ),
      warning = \(w) if (str_detect(conditionMessage(w), "default initial values")) invokeRestart("muffleWarning")
    )
  })
  aic <- vapply(curve_fits, \(fit) fit$aic, numeric(1))
  fitted_p99 <- c(
    lognormal = qlnorm(0.99, curve_fits$lognormal$estimate[["meanlog"]], curve_fits$lognormal$estimate[["sdlog"]]),
    gamma = qgamma(0.99, curve_fits$gamma$estimate[["shape"]], rate = curve_fits$gamma$estimate[["rate"]]),
    weibull = qweibull(0.99, curve_fits$weibull$estimate[["shape"]], curve_fits$weibull$estimate[["scale"]])
  )
  winner <- names(which.min(aic))
  tibble(
    n_days = nrow(site_days),
    pct_censored = 100 * mean(is.na(site_data$left)),
    aic_lognormal = aic[["lognormal"]],
    aic_gamma = aic[["gamma"]],
    aic_weibull = aic[["weibull"]],
    winner = winner,
    aic_gap = sort(aic)[[2]] - sort(aic)[[1]],
    spread_factor = exp(curve_fits$lognormal$estimate[["sdlog"]]),
    p99_over_lognormal = actual_p99 / fitted_p99[["lognormal"]],
    p99_over_winner = actual_p99 / fitted_p99[[winner]]
  )
}

ozone_limit_row <- function(site_days) {
  if (any(site_days$value < site_days$federal_mdl)) {
    return(censored_site_row(site_days, "Readings below the limit censored"))
  }
  plain_fit <- describe_site_fit(fast_curve_parameters(site_days$value_fit))
  plain_fit %>%
    mutate(pct_censored = 0) %>%
    select(n_days, pct_censored, aic_lognormal, aic_gamma, aic_weibull, winner, aic_gap, spread_factor, p99_over_lognormal, p99_over_winner)
}

fit_censored_versions <- function(site_days, version, row_function = NULL) {
  pieces <- split(site_days, str_c(site_days$pollutant, "|", site_days$site_id))
  bind_rows(lapply(pieces, \(piece) {
    if (!is.null(row_function)) {
      return(row_function(piece))
    }
    censored_site_row(piece, version, first(piece$value_step))
  }), .id = "site_key") %>%
    separate_wider_delim(site_key, "|", names = c("pollutant", "site_id")) %>%
    mutate(pollutant = factor(pollutant, levels = pollutant_levels)) %>%
    mutate(version = version)
}

censored_days <- ordinary_fit_days %>%
  filter(pollutant %in% censored_pollutants) %>%
  left_join(select(fit_site_inventory, pollutant, site_id, value_step), by = c("pollutant", "site_id"), relationship = "many-to-one")

censored_started <- Sys.time()

case_ozone_fit_days <- ordinary_fit_days %>%
  filter(pollutant == "Ozone") %>%
  semi_join(filter(case_site_flags, pollutant == "Ozone"), by = c("pollutant", "site_id"))

censored_fits <- cached_step(
  "censored_fits",
  list(censored_days, case_ozone_fit_days),
  list(
    contest_curves, fitdist_names, curve_parameter_count, fit_relative_tolerance, weibull_step_tolerance, rounded_pollutants,
    packageVersion("fitdistrplus")
  ),
  list(
    fit_censored_versions, censored_site_row, ozone_limit_row, censored_data, curve_starts, fit_rounded_curve, interval_log_probability,
    fast_curve_parameters, describe_site_fit
  ),
  \() bind_rows(
    fit_censored_versions(censored_days, "At or below zero censored"),
    fit_censored_versions(censored_days, "Readings below the limit censored"),
    fit_censored_versions(filter(censored_days, pollutant %in% rounded_pollutants), "Rounded readings"),
    fit_censored_versions(case_ozone_fit_days, "Case-study ozone below the limit censored", ozone_limit_row)
  )
)

cat("Censored fits, seconds:", round(as.numeric(difftime(Sys.time(), censored_started, units = "secs"))), "\n")

censored_fits <- censored_fits %>%
  left_join(
    select(ordinary_site_fits, pollutant, site_id, main_winner = winner, main_spread_factor = spread_factor),
    by = c("pollutant", "site_id"),
    relationship = "many-to-one"
  ) %>%
  mutate(is_same_winner = winner == main_winner)

censored_summary <- censored_fits %>%
  left_join(select(case_site_flags, pollutant, site_id, site_group), by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
  summarise(
    n_sites = n(),
    pct_same_winner = 100 * mean(is_same_winner),
    wins_lognormal = sum(winner == "lognormal"),
    wins_gamma = sum(winner == "gamma"),
    wins_weibull = sum(winner == "weibull"),
    median_pct_censored = median(pct_censored),
    median_spread = median(spread_factor),
    median_main_spread = median(main_spread_factor),
    median_p99_over_winner = median(p99_over_winner),
    .by = c(version, pollutant)
  )

print(as.data.frame(censored_summary))

deer_park_id <- houston_so2_ids[["Houston Deer Park #2"]]

deer_park_fits <- censored_fits %>%
  filter(pollutant == "SO2", site_id == deer_park_id)

deer_park_fits %>%
  select(version, n_days, pct_censored, aic_lognormal, aic_gamma, aic_weibull, winner, aic_gap, p99_over_lognormal, p99_over_winner) %>%
  as.data.frame() %>%
  print()

ozone_limit_fits <- censored_fits %>%
  filter(version == "Case-study ozone below the limit censored") %>%
  left_join(select(case_site_flags, pollutant, site_id, site_group), by = c("pollutant", "site_id"), relationship = "many-to-one")

print(as.data.frame(count(ozone_limit_fits, site_group, winner)))

stopifnot(
  "Each censored version covers every site it should" =
    sum(censored_fits$version == "Readings below the limit censored") ==
      sum(site_fits$pollutant %in% censored_pollutants & site_fits$site_set == "Ordinary days"),
  "All 22 case-study ozone sites have a censored check" = nrow(ozone_limit_fits) == 22,
  "Every censored fit names a winner" = all(censored_fits$winner %in% contest_curves)
)

# PM2.5 by instrument inside one site, sites need a full year each side. fitting both sides of one site compares like with
# like, never-T640 sites split at the usual switch date show what the calendar alone does
pm25_days <- ordinary_fit_days %>%
  filter(pollutant == "PM2.5")

t640_side_days <- pm25_days %>%
  mutate(instrument_side = case_when(
    !has_t640 ~ "Without T640",
    n_instruments == 1 ~ "T640 alone",
    .default = NA_character_
  )) %>%
  filter(!is.na(instrument_side))

t640_side_counts <- t640_side_days %>%
  count(site_id, instrument_side) %>%
  pivot_wider(names_from = instrument_side, values_from = n, values_fill = 0L)

t640_sites <- t640_side_counts %>%
  filter(`Without T640` >= min_instrument_side_days, `T640 alone` >= min_instrument_side_days) %>%
  pull(site_id)

typical_switch_date <- t640_side_days %>%
  filter(site_id %in% t640_sites, instrument_side == "T640 alone") %>%
  summarise(first_t640 = min(date_local), .by = site_id) %>%
  summarise(typical = median(first_t640)) %>%
  pull(typical)

control_sites <- shape_site_flags %>%
  filter(pollutant == "PM2.5", !has_method_change, sampling_schedule == "Daily", !is_near_zero_site) %>%
  pull(site_id)

control_days <- pm25_days %>%
  filter(site_id %in% control_sites, !has_t640) %>%
  mutate(instrument_side = if_else(date_local < typical_switch_date, "Control, before the date", "Control, after the date"))

control_side_counts <- control_days %>%
  count(site_id, instrument_side) %>%
  pivot_wider(names_from = instrument_side, values_from = n, values_fill = 0L)

control_sites_kept <- control_side_counts %>%
  filter(`Control, before the date` >= min_instrument_side_days, `Control, after the date` >= min_instrument_side_days) %>%
  pull(site_id)

instrument_side_days <- bind_rows(
  filter(t640_side_days, site_id %in% t640_sites),
  filter(control_days, site_id %in% control_sites_kept)
)

instrument_pieces <- split(
  instrument_side_days,
  str_c(instrument_side_days$instrument_side, "|", instrument_side_days$site_id)
)

instrument_fits <- bind_rows(lapply(instrument_pieces, \(piece) {
  describe_site_fit(fast_curve_parameters(piece$value_fit)) %>%
    mutate(pct_warm_days = 100 * mean(piece$month %in% warm_months))
}), .id = "site_key") %>%
  separate_wider_delim(site_key, "|", names = c("version", "site_id")) %>%
  mutate(pollutant = factor("PM2.5", levels = pollutant_levels))

instrument_summary <- instrument_fits %>%
  summarise(
    n_sites = n(),
    median_days = median(n_days),
    median_pct_warm_days = median(pct_warm_days),
    pct_lognormal = 100 * mean(winner == "lognormal"),
    wins_gamma = sum(winner == "gamma"),
    wins_weibull = sum(winner == "weibull"),
    median_spread = median(spread_factor),
    .by = version
  )

print(as.data.frame(instrument_summary))

cat("Typical first T640 date:", format(typical_switch_date), "\n")

stopifnot(
  "Sites on both sides of the T640 switch exist" = length(t640_sites) > 0,
  "Control sites exist" = length(control_sites_kept) > 0,
  "Each instrument side has a row per site" =
    nrow(instrument_fits) == 2 * (length(t640_sites) + length(control_sites_kept))
)

# group spread. nearby sites share weather so one resample draws the same dates at every site in a pollutant. the
# gap = one group's median site spread minus another's, range = middle 95% of 1,000 resamples
group_spread_levels <- names(site_group_colours)

group_spread_medians <- function(day_table, date_weights = NULL) {
  weights <- if (is.null(date_weights)) rep(1, length(day_table$log_value)) else date_weights[day_table$date_index]
  site_totals <- rowsum(cbind(weights, weights * day_table$log_value, weights * day_table$log_value^2), day_table$site_index, reorder = TRUE)
  spread <- exp(sqrt(pmax(site_totals[, 3] / site_totals[, 1] - (site_totals[, 2] / site_totals[, 1])^2, 0)))
  stopifnot("Every site keeps days in each resample" = all(site_totals[, 1] > 0))
  vapply(group_spread_levels, \(group) median(spread[day_table$site_groups == group]), numeric(1))
}

group_gap_comparisons <- tibble(
  comparison = c("Ship Channel minus Dallas-Fort Worth", "Houston other minus Dallas-Fort Worth", "Ship Channel minus Houston other"),
  first_group = c("Houston Ship Channel", "Houston other", "Houston Ship Channel"),
  second_group = c("Dallas-Fort Worth", "Dallas-Fort Worth", "Houston other")
)

prepare_spread_days <- function(site_days) {
  ordered_sites <- site_days %>%
    distinct(site_id, site_group) %>%
    arrange(site_id)
  site_days %>%
    mutate(log_value = log(value_fit)) %>%
    mutate(date_index = match(date_local, sort(unique(date_local)))) %>%
    mutate(site_index = match(site_id, ordered_sites$site_id)) %>%
    select(log_value, date_index, site_index) %>%
    as.list() %>%
    c(list(site_groups = ordered_sites$site_group, n_dates = n_distinct(site_days$date_local)))
}

spread_gap_ranges <- function(site_days, seed) {
  day_table <- prepare_spread_days(site_days)
  block_starts <- seq_len(day_table$n_dates - stability_block_days + 1)
  n_blocks <- ceiling(day_table$n_dates / stability_block_days)
  block_offsets <- seq_len(stability_block_days) - 1
  set.seed(seed)
  resampled <- t(vapply(seq_len(group_range_reps), \(rep) {
    picked <- sample(block_starts, n_blocks, replace = TRUE)
    chosen <- as.vector(outer(block_offsets, picked, `+`))[seq_len(day_table$n_dates)]
    group_spread_medians(day_table, tabulate(chosen, day_table$n_dates))
  }, numeric(length(group_spread_levels))))
  point_estimate <- group_spread_medians(day_table)
  gap_percentile <- function(first_name, second_name, probability) {
    quantile(resampled[, first_name] - resampled[, second_name], probability, names = FALSE)
  }
  group_gap_comparisons %>%
    mutate(spread_first_group = point_estimate[first_group]) %>%
    mutate(spread_second_group = point_estimate[second_group]) %>%
    mutate(spread_gap = spread_first_group - spread_second_group) %>%
    mutate(gap_low = unname(mapply(gap_percentile, first_group, second_group, 0.025))) %>%
    mutate(gap_high = unname(mapply(gap_percentile, first_group, second_group, 0.975)))
}

group_range_days <- case_fit_source %>%
  filter(pollutant %in% group_range_pollutants)

group_range_sets <- list(
  "Ordinary days" = group_range_days,
  "Warm season" = filter(group_range_days, month %in% warm_months),
  "Cool season" = filter(group_range_days, !month %in% warm_months)
)

group_range_rows <- function(seed) {
  bind_rows(lapply(names(group_range_sets), \(set_name) {
    bind_rows(lapply(group_range_pollutants, \(pollutant_name) {
      spread_gap_ranges(filter(group_range_sets[[set_name]], pollutant == pollutant_name), seed) %>%
        mutate(pollutant = pollutant_name) %>%
        mutate(version = set_name)
    }))
  }))
}

group_spread_gaps <- group_range_rows(group_range_seed)

group_spread_check <- group_range_rows(group_range_check_seed) %>%
  select(comparison, pollutant, version, gap_low_check_seed = gap_low, gap_high_check_seed = gap_high)

group_spread_gaps <- group_spread_gaps %>%
  left_join(group_spread_check, by = c("comparison", "pollutant", "version"), relationship = "one-to-one") %>%
  mutate(seed_shift_share = pmax(abs(gap_low - gap_low_check_seed), abs(gap_high - gap_high_check_seed)) / (gap_high - gap_low)) %>%
  mutate(pollutant = factor(pollutant, levels = pollutant_levels))

print(as.data.frame(mutate(group_spread_gaps, across(where(is.double), \(x) round(x, 3))) %>% select(-first_group, -second_group)))

stopifnot(
  "Both seeds give the same ranges within the tolerance" = all(group_spread_gaps$seed_shift_share <= group_range_seed_tolerance),
  "Nine group gaps per pollutant" = nrow(group_spread_gaps) == 3 * 3 * length(group_range_pollutants)
)

print(as.data.frame(fit_summary %>%
  select(scope, pollutant, site_group, site_set, n_sites, wins_lognormal, wins_gamma, wins_weibull, wins_with_normal_normal,
         median_aic_gap, pct_sites_gap_decisive, median_scaled_aic_gap, pct_sites_scaled_gap_decisive, n_sites_resampled, pct_resampled_clear,
         spread_factor_median, p99_over_winner_median, pct_sites_winner_closest_at_p99) %>%
  mutate(across(where(is.double), \(x) signif(x, 3)))))

# warm-month ozone gap under the checks 2b runs. below-limit readings get set aside in one check bc they
# moved DFW's year-round winner
warm_ozone_days <- case_fit_source %>%
  filter(pollutant == "Ozone", month %in% warm_months)

warm_ozone_all_days <- case_fit_days %>%
  filter(pollutant == "Ozone", month %in% warm_months)

warm_ozone_check_days <- list(
  "Ordinary days" = warm_ozone_days,
  "All days" = warm_ozone_all_days,
  "Without values at or below zero" = filter(warm_ozone_days, !is_at_or_below_zero),
  "Without readings below the limit" = filter(warm_ozone_days, !is_below_mdl),
  "Without the transition band" = filter(warm_ozone_days, !in_transition_band),
  "Without days after method changes" =
    filter(warm_ozone_days, !(coalesce(sensitivity_left_out == "Days after the method change", FALSE) & is_post_method_change)),
  "Without Deer Park #2 after its move" = filter(warm_ozone_days, !is_post_relocation)
)

warm_ozone_check_gaps <- bind_rows(Map(
  \(site_days, site_set) {
    site_days %>%
      summarise(spread = exp(sqrt(mean((log(value_fit) - mean(log(value_fit)))^2))), .by = c(site_group, site_id)) %>%
      summarise(median_spread = median(spread), .by = site_group) %>%
      mutate(gap_to_dfw = median_spread - median_spread[site_group == "Dallas-Fort Worth"]) %>%
      mutate(site_set = site_set)
  },
  warm_ozone_check_days,
  names(warm_ozone_check_days)
))

print(as.data.frame(mutate(warm_ozone_check_gaps, across(where(is.double), \(x) round(x, 3)))))

season_labels <- c("Ordinary days" = "Year", "Warm season" = "Warm", "Cool season" = "Cool")

curve_labels <- c("lognormal" = "Lognormal", "gamma" = "Gamma", "weibull" = "Weibull", "normal" = "Normal")

curve_fills <- c("Lognormal" = chart_fills[["accent"]], "Gamma" = "#8DB6D4", "Weibull" = chart_fills[["other"]], "Normal" = chart_ink[["secondary"]])

curve_text <- c("Lognormal" = "white", "Gamma" = chart_ink[["primary"]], "Weibull" = chart_ink[["primary"]], "Normal" = "white")

national_winner_shares <- fit_summary %>%
  filter(scope == "National", site_set %in% names(season_labels)) %>%
  select(pollutant, site_set, n_sites, starts_with("wins_")) %>%
  pivot_longer(starts_with("wins_"), names_to = "contest", values_to = "n_wins") %>%
  mutate(with_normal = str_starts(contest, "wins_with_normal_")) %>%
  mutate(curve = str_remove(contest, "wins_(with_normal_)?")) %>%
  mutate(curve = factor(curve_labels[curve], levels = rev(curve_labels))) %>%
  mutate(pct_of_sites = 100 * n_wins / n_sites) %>%
  mutate(season = factor(season_labels[as.character(site_set)], levels = rev(season_labels))) %>%
  mutate(share_label = if_else(pct_of_sites >= 17, sprintf("%.0f", pct_of_sites), ""))

winner_site_counts <- fit_summary %>%
  filter(scope == "National", site_set == "Ordinary days")

winner_strip_labels <- setNames(
  str_c(pretty_text(as.character(winner_site_counts$pollutant)), "\n", comma(winner_site_counts$n_sites), " sites"),
  as.character(winner_site_counts$pollutant)
)

winner_panel <- function(show_normal, panel_number, panel_title, panel_subtitle) {
  ggplot(filter(national_winner_shares, with_normal == show_normal), aes(pct_of_sites, season, fill = curve)) +
    geom_col(width = 0.82) +
    geom_text(
      aes(label = share_label, colour = curve),
      position = position_stack(vjust = 0.5),
      family = chart_fonts[["mono"]],
      size = (chart_sizes[["label"]] - 0.8) / .pt
    ) +
    facet_grid(rows = vars(pollutant), switch = "y", labeller = as_labeller(winner_strip_labels)) +
    scale_fill_manual(values = curve_fills, guide = "none") +
    scale_colour_manual(values = curve_text, guide = "none") +
    scale_x_continuous(breaks = c(0, 50, 100), labels = \(x) str_c(x, "%"), expand = expansion(mult = c(0, 0.01))) +
    labs(title = panel_label(panel_number, panel_title), subtitle = panel_subtitle, x = "Share of sites won", y = NULL) +
    theme_paper() +
    theme(
      panel.grid.major.y = element_blank(),
      panel.spacing = unit(5, "pt"),
      strip.placement = "outside",
      strip.text.y.left = element_text(
        family = chart_fonts[["mono"]], colour = chart_ink[["primary"]], size = chart_sizes[["axis"]], angle = 0, hjust = 0, margin = margin(r = 4)
      )
    )
}

ozone_spread_sites <- site_fits %>%
  filter(pollutant == "Ozone", site_set %in% c("Warm season", "Cool season"), !is.na(site_group)) %>%
  mutate(site_group = factor(site_group, levels = rev(names(site_group_colours))))

ozone_spread_boxes <- ozone_spread_sites %>%
  box_stats("spread_factor", c("site_set", "site_group"))

stopifnot("Two seasons, three groups, one spread box each" = nrow(ozone_spread_boxes) == 6)

group_axis_labels <- c("Houston Ship Channel" = "Ship Channel", "Houston other" = "Houston other", "Dallas-Fort Worth" = "Dallas-Fort Worth")

spread_limits <- c(min(ozone_spread_sites$spread_factor) - 0.01, max(ozone_spread_sites$spread_factor) + 0.06)

spread_panel <- function(site_set_name, panel_number, panel_title, panel_subtitle) {
  set_boxes <- filter(ozone_spread_boxes, site_set == site_set_name)
  group_labels <- setNames(
    str_c(group_axis_labels[as.character(set_boxes$site_group)], " (", set_boxes$n_values, ")"),
    as.character(set_boxes$site_group)
  )
  ggplot(set_boxes, aes(y = site_group, colour = site_group, fill = site_group)) +
    geom_box_whisker(horizontal = TRUE, width = 0.5) +
    geom_text(
      aes(x = spread_limits[2], label = sprintf("%.2f", box_median)),
      family = chart_fonts[["mono"]],
      size = chart_sizes[["label"]] / .pt,
      colour = chart_ink[["primary"]],
      hjust = 1
    ) +
    scale_colour_manual(values = site_group_colours, guide = "none") +
    scale_fill_manual(values = alpha(site_group_colours, box_fill_alpha), guide = "none") +
    scale_y_discrete(labels = \(x) group_labels[x], expand = expansion(add = 0.75)) +
    scale_x_continuous(limits = spread_limits, breaks = c(1.35, 1.45, 1.55)) +
    labs(title = panel_label(panel_number, panel_title), subtitle = panel_subtitle, x = "Spread factor, exp(SD of logged days)", y = NULL) +
    theme_paper() +
    theme(panel.grid.major.y = element_blank(), panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25))
}

certainty_levels <- c("AIC gap 10+", "Scaled gap 10+", "Holds")

national_main_fits <- fit_summary %>%
  filter(scope == "National", site_set == "Ordinary days")

winner_certainty <- national_main_fits %>%
  select(pollutant, pct_sites_gap_decisive, pct_sites_scaled_gap_decisive, pct_resampled_clear) %>%
  pivot_longer(-pollutant, names_to = "measure", values_to = "pct_of_sites") %>%
  mutate(measure = certainty_levels[match(measure, c("pct_sites_gap_decisive", "pct_sites_scaled_gap_decisive", "pct_resampled_clear"))]) %>%
  mutate(measure = factor(measure, levels = certainty_levels)) %>%
  mutate(pollutant = factor(pollutant, levels = rev(pollutant_levels)))

certainty_colours <- c("AIC gap 10+" = "white", "Scaled gap 10+" = chart_fills[["other"]], "Holds" = chart_ink[["primary"]])

certainty_panel <- ggplot(winner_certainty, aes(pct_of_sites, pollutant)) +
  geom_line(aes(group = pollutant), colour = chart_ink[["axis"]], linewidth = 0.4) +
  geom_point(aes(fill = measure), shape = 21, size = 2, colour = chart_ink[["primary"]], stroke = 0.4) +
  scale_fill_manual(values = certainty_colours, guide = "none") +
  scale_x_continuous(limits = c(0, 100), breaks = c(0, 50, 100), labels = \(x) str_c(x, "%"), expand = expansion(mult = c(0.01, 0.03))) +
  scale_y_discrete(labels = pretty_text) +
  labs(title = panel_label(3, "% of sites"), subtitle = "AIC gaps overstate the certainty", x = "Share of sites", y = NULL) +
  theme_paper()

instrument_panel_data <- instrument_summary %>%
  mutate(group = if_else(version %in% c("T640 alone", "Without T640"), "With a T640", "Without one")) %>%
  mutate(group = factor(group, levels = c("With a T640", "Without one"))) %>%
  mutate(side = factor(version, levels = rev(c("Without T640", "T640 alone", "Control, before the date", "Control, after the date"))))

instrument_site_counts <- instrument_panel_data %>%
  distinct(group, n_sites) %>%
  arrange(group)

instrument_side_labels <- c(
  "Without T640" = "Other monitor",
  "T640 alone" = "T640 alone",
  "Control, before the date" = "Before date",
  "Control, after the date" = "After date"
)

instrument_panel <- ggplot(instrument_panel_data, aes(pct_lognormal, side)) +
  geom_col(width = 0.72, fill = curve_fills[["Lognormal"]]) +
  geom_text(
    aes(label = sprintf("%.0f%%", pct_lognormal)),
    family = chart_fonts[["mono"]],
    size = chart_sizes[["label"]] / .pt,
    colour = chart_ink[["primary"]],
    hjust = -0.2
  ) +
  facet_grid(rows = vars(group), scales = "free_y", space = "free_y") +
  scale_y_discrete(labels = instrument_side_labels) +
  scale_x_continuous(limits = c(0, 118), breaks = c(0, 50, 100), labels = \(x) str_c(x, "%"), expand = expansion(mult = 0)) +
  labs(
    title = panel_label(4, sprintf("PM2.5: %d T640 sites, %d others", instrument_site_counts$n_sites[1], instrument_site_counts$n_sites[2])),
    subtitle = "Lognormal wins, same sites",
    x = NULL,
    y = NULL
  ) +
  theme_paper() +
  theme(
    panel.grid.major.y = element_blank(),
    panel.spacing = unit(9, "pt"),
    strip.text.y = element_blank()
  )

national_fit_checks <- fit_summary %>%
  filter(scope == "National")

log_led_rows <- national_fit_checks %>%
  filter(pollutant %in% c("SO2", "CO"))

ozone_fit_rows <- national_fit_checks %>%
  filter(pollutant == "Ozone")

plurality_winner <- function(pollutant_name, set_name) {
  row <- national_fit_checks %>%
    filter(pollutant == pollutant_name, site_set == set_name)
  contest_curves[which.max(c(row$wins_lognormal, row$wins_gamma, row$wins_weibull))]
}

t640_row <- instrument_summary %>%
  filter(version == "T640 alone")

without_t640_row <- instrument_summary %>%
  filter(version == "Without T640")

control_before_row <- instrument_summary %>%
  filter(version == "Control, before the date")

control_after_row <- instrument_summary %>%
  filter(version == "Control, after the date")

ozone_group_gaps <- group_spread_gaps %>%
  filter(pollutant == "Ozone", str_ends(comparison, "Dallas-Fort Worth"))

warm_ozone_gaps <- ozone_group_gaps %>%
  filter(version == "Warm season")

cool_ozone_gaps <- ozone_group_gaps %>%
  filter(version == "Cool season")

warm_ozone_gaps_to_dfw <- warm_ozone_check_gaps %>%
  filter(site_group != "Dallas-Fort Worth")

resampled_main_shares <- national_main_fits %>%
  summarise(all_resampled = all(n_sites_resampled == stability_sample_sites))

stopifnot(
  "SO2 and CO lean lognormal under every check" =
    all(log_led_rows$wins_lognormal > log_led_rows$wins_gamma & log_led_rows$wins_lognormal > log_led_rows$wins_weibull),
  "Ozone leans normal under every check once it may compete" =
    all(ozone_fit_rows$wins_with_normal_normal > ozone_fit_rows$wins_with_normal_gamma &
      ozone_fit_rows$wins_with_normal_normal > ozone_fit_rows$wins_with_normal_weibull &
      ozone_fit_rows$wins_with_normal_normal > ozone_fit_rows$wins_with_normal_lognormal),
  "The leading curve changes with the pollutant" =
    plurality_winner("SO2", "Ordinary days") != plurality_winner("Ozone", "Ordinary days"),
  "The leading curve changes with the season for ozone and NO2" =
    plurality_winner("Ozone", "Warm season") != plurality_winner("Ozone", "Cool season") &&
    plurality_winner("NO2", "Warm season") != plurality_winner("NO2", "Cool season"),
  "AIC gaps overstate certainty at every pollutant, as panel (c) says" =
    all(national_main_fits$pct_resampled_clear < national_main_fits$pct_sites_gap_decisive),
  "National resampling shares rest on the random sample alone" = resampled_main_shares$all_resampled,
  "Inside one site, lognormal wins far more often on a T640" =
    t640_row$pct_lognormal >= without_t640_row$pct_lognormal + 30,
  "Sites without a T640 show no such rise over the same dates" = control_after_row$pct_lognormal <= control_before_row$pct_lognormal,
  "Both sides of the T640 comparison span a mix of seasons" = all(between(instrument_summary$median_pct_warm_days, 50, 65)),
  "Houston's warm-season ozone spread sits above Dallas-Fort Worth's with ranges above zero" =
    all(warm_ozone_gaps$gap_low > 0) && nrow(warm_ozone_gaps) == 2,
  "The warm-season gap holds under every check" = all(warm_ozone_gaps_to_dfw$gap_to_dfw > 0.05),
  "Cool-season ozone spreads match, with ranges that reach zero" =
    all(cool_ozone_gaps$gap_low < 0 & cool_ozone_gaps$gap_high > 0) && all(abs(cool_ozone_gaps$spread_gap) < 0.02) && nrow(cool_ozone_gaps) == 2,
  "The Deer Park #2 main fit picks a lognormal that overshoots P99" =
    ordinary_site_fits$winner[ordinary_site_fits$pollutant == "SO2" & ordinary_site_fits$site_id == deer_park_id] == "lognormal" &&
    ordinary_site_fits$p99_over_lognormal[ordinary_site_fits$pollutant == "SO2" & ordinary_site_fits$site_id == deer_park_id] < 0.75,
  "Censoring readings below the limit moves Deer Park #2 to a Weibull close to its P99" =
    deer_park_fits$winner[deer_park_fits$version == "Readings below the limit censored"] == "weibull" &&
    between(deer_park_fits$p99_over_winner[deer_park_fits$version == "Readings below the limit censored"], 0.95, 1.05)
)

national_fit_figure <- tagged_figure(
  list(
    winner_panel(FALSE, 1, "Three curves", "SO2 and CO lean lognormal"),
    winner_panel(TRUE, 2, "With the normal curve allowed", "Ozone leans normal"),
    certainty_panel,
    instrument_panel
  ),
  tribble(
    ~mark,    ~colour,                    ~label,                 ~shape, ~row,
    "square", curve_fills[["Lognormal"]], "Lognormal",            16,     1,
    "square", curve_fills[["Gamma"]],     "Gamma",                16,     1,
    "square", curve_fills[["Weibull"]],   "Weibull",              16,     1,
    "square", curve_fills[["Normal"]],    "Normal",               16,     1,
    "point",  certainty_colours[[1]],     "(c) AIC gap 10+",      21,     2,
    "point",  certainty_colours[[2]],     "(c) Scaled gap 10+",   21,     2,
    "point",  certainty_colours[[3]],     "(c) Winner holds",     21,     2
  ),
  source_note = sprintf(
    str_c(
      "Source: EPA AQS daily data, %s to %s, ordinary days, five-year sites. Winner: lowest AIC per site. (c) Holds: kept in 90%%+ of ",
      "%d two-week block resamples of %d random sites per pollutant. (d) Split at %s for sites without a T640."
    ),
    min(study_years), max(study_years), stability_reps, stability_sample_sites, format(typical_switch_date, "%Y-%m-%d")
  ),
  row_weights = c(1.75, 1)
)

ozone_spread_figure <- tagged_figure(
  list(
    spread_panel(
      "Warm season",
      1,
      "Ozone, warm months",
      sprintf("Houston wider by %.2f to %.2f", min(warm_ozone_gaps$spread_gap), max(warm_ozone_gaps$spread_gap))
    ),
    spread_panel("Cool season", 2, "Ozone, cool months", "The three groups match")
  ),
  tribble(
    ~mark,    ~colour,                                      ~label,                                                                          ~row,
    "square", site_group_colours[["Houston Ship Channel"]], "Ship Channel",                                                                  1,
    "square", site_group_colours[["Houston other"]],        "Houston other",                                                                 1,
    "square", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth",                                                             1,
    "box",    chart_ink[["secondary"]],                     "Sites: box holds the middle half, line and number are the median site, whiskers 10th to 90th percentile", 2
  ),
  source_note = sprintf(
    str_c(
      "Source: EPA AQS daily data, %s to %s, ordinary days, case-study sites, site counts in brackets; cool-season ozone on year-round ",
      "sites. Warm-month gaps to Dallas-Fort Worth have 95%% ranges clear of zero from %s two-week block resamples."
    ),
    min(study_years), max(study_years), comma(group_range_reps)
  )
)

save_figure(national_fit_figure, "3.05_fits.png", 6.4)

save_figure(ozone_spread_figure, "3.06_ozone_spread.png", 2.65)

aic_columns <- c("aic_lognormal", "aic_gamma", "aic_weibull", "aic_normal", "aic_gap", "scaled_aic_gap")

fit_site_record <- bind_rows(site_fits, changed_check_fits) %>%
  mutate(site_set = factor(site_set, levels = shape_summary_set_levels)) %>%
  select(
    pollutant, site_id, local_site_name, state_name, region, site_group, site_set, n_days, aic_lognormal, aic_gamma, aic_weibull, aic_normal,
    winner, winner_with_normal, aic_gap, lag1_correlation, effective_days, scaled_aic_gap, winner_kept_share, winner_status, spread_factor,
    gamma_shape, weibull_shape, p99_over_lognormal, p99_over_gamma, p99_over_weibull, p99_over_normal, p99_over_winner, p05_over_winner,
    closest_at_p99, ks_statistic, anderson_darling
  ) %>%
  arrange(pollutant, site_id, site_set) %>%
  mutate(across(all_of(aic_columns), \(x) round(x, 2))) %>%
  mutate(across(where(is.double) & !all_of(aic_columns), \(x) signif(x, 4)))

site_names <- shape_site_flags %>%
  select(pollutant, site_id, local_site_name, site_group)

censored_check_rows <- censored_fits %>%
  left_join(site_names, by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
  mutate(check = "Censored")

instrument_check_rows <- instrument_fits %>%
  select(
    version, site_id, pollutant, n_days, pct_warm_days, aic_lognormal, aic_gamma, aic_weibull, winner, aic_gap, spread_factor,
    p99_over_lognormal, p99_over_winner
  ) %>%
  left_join(site_names, by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
  mutate(check = "Instrument")

group_check_rows <- group_spread_gaps %>%
  select(-first_group, -second_group) %>%
  mutate(check = "Group spread")

fit_check_record <- bind_rows(censored_check_rows, instrument_check_rows, group_check_rows) %>%
  mutate(check = factor(check, levels = c("Censored", "Instrument", "Group spread"))) %>%
  select(
    check, version, pollutant, site_id, local_site_name, site_group, comparison, n_days, pct_censored, pct_warm_days, aic_lognormal, aic_gamma,
    aic_weibull, winner, main_winner, is_same_winner, aic_gap, spread_factor, main_spread_factor, p99_over_lognormal, p99_over_winner,
    spread_first_group, spread_second_group, spread_gap, gap_low, gap_high, gap_low_check_seed, gap_high_check_seed, seed_shift_share
  ) %>%
  arrange(check, version, pollutant, site_id, comparison) %>%
  mutate(across(c(aic_lognormal, aic_gamma, aic_weibull, aic_gap), \(x) round(x, 2))) %>%
  mutate(across(where(is.double) & !c(aic_lognormal, aic_gamma, aic_weibull, aic_gap), \(x) signif(x, 4)))

stopifnot(
  "Forty national summary rows and fifty-four case-study rows" =
    sum(fit_summary$scope == "National") == 40 && sum(fit_summary$scope == "Case study") == 54,
  "Every site record row has a check and a winner" = !anyNA(fit_site_record$site_set) && !anyNA(fit_site_record$winner),
  "Every check record row names its check and version" = !anyNA(fit_check_record$check) && !anyNA(fit_check_record$version)
)

fit_records <- list(
  distribution_fits = fit_site_record,
  distribution_fit_summary = mutate(fit_summary, across(where(is.double), \(x) signif(x, 4))),
  distribution_fit_checks = fit_check_record
)

save_records(fit_records, records_dir)

fit_dictionary <- bind_rows(
  tribble(
    ~table,               ~column,              ~description,
    "distribution_fits", "pollutant",           "PM2.5, Ozone, NO2, SO2 or CO",
    "distribution_fits", "site_id",             "AQS site ID; five-year sites outside the near-zero rule",
    "distribution_fits", "local_site_name",     "Site name given by the reporting agency; can be NA",
    "distribution_fits", "state_name",          "State or territory name",
    "distribution_fits", "region",              "West (Census West region) or East (every other state or territory)",
    "distribution_fits", "site_group",          "Case-study group; NA outside the case study",
    "distribution_fits", "site_set",            "Ordinary days (main run) or a check; the 2b checks list only the sites they change",
    "distribution_fits", "n_days",              "Days fitted",
    "distribution_fits", "aic_lognormal",       "AIC of the lognormal curve on value / site mean; compare within a site and check only",
    "distribution_fits", "aic_gamma",           "AIC of the gamma curve on value / site mean; compare within a site and check only",
    "distribution_fits", "aic_weibull",         "AIC of the Weibull curve on value / site mean; compare within a site and check only",
    "distribution_fits", "aic_normal",          "AIC of the normal curve on value / site mean, the reference beside the contest",
    "distribution_fits", "winner",              "Lowest AIC among lognormal, gamma and Weibull",
    "distribution_fits", "winner_with_normal",  "Lowest AIC once the normal curve may compete",
    "distribution_fits", "aic_gap",             "AIC of the runner-up minus AIC of the winner, among the three curves",
    "distribution_fits", "lag1_correlation",    "Correlation of log values on consecutive calendar days; main run only; NA below 30 pairs",
    "distribution_fits", "effective_days",      "n x (1 - r) / (1 + r), at most n: independent days after links; main run only",
    "distribution_fits", "scaled_aic_gap",      "aic_gap x effective_days / n_days; main run only",
    "distribution_fits", "winner_kept_share",   "Share of 100 two-week block resamples that keep the winner; NA when not resampled",
    "distribution_fits", "winner_status",       "Clear (share of 0.9 or more), No clear winner, or Not resampled",
    "distribution_fits", "spread_factor",       "exp(fitted SD of the logs): the usual multiple a site swings above or below its typical level",
    "distribution_fits", "gamma_shape",         "Fitted gamma shape; below 1 means most days sit near the floor",
    "distribution_fits", "weibull_shape",       "Fitted Weibull shape; below 1 means most days sit near the floor, about 3.6 is nearly symmetric",
    "distribution_fits", "p99_over_lognormal",  "Actual P99 / the fitted lognormal's P99; below 1, the curve overpredicts; NA below 200 days",
    "distribution_fits", "p99_over_gamma",      "Actual P99 / the fitted gamma's P99; NA below 200 days",
    "distribution_fits", "p99_over_weibull",    "Actual P99 / the fitted Weibull's P99; NA below 200 days",
    "distribution_fits", "p99_over_normal",     "Actual P99 / the fitted normal's P99; NA below 200 days",
    "distribution_fits", "p99_over_winner",     "Actual P99 / the winner's P99; NA below 200 days",
    "distribution_fits", "p05_over_winner",     "Actual P5 / the winner's P5; NA below 200 days",
    "distribution_fits", "closest_at_p99",      "The curve of the three closest to the actual P99; NA below 200 days",
    "distribution_fits", "ks_statistic",        "Kolmogorov-Smirnov distance from the winner; a statistic only: ties and links break its p-value",
    "distribution_fits", "anderson_darling",    "Anderson-Darling statistic against the winner; a statistic only: ties and links break its p-value"
  ),
  tribble(
    ~table,                       ~column,                         ~description,
    "distribution_fit_summary", "scope",                           "National (all sites outside the near-zero rule) or Case study (per group)",
    "distribution_fit_summary", "pollutant",                       "PM2.5, Ozone, NO2, SO2 or CO; CO is national only",
    "distribution_fit_summary", "site_group",                      "Case-study group; NA in national rows",
    "distribution_fit_summary", "site_set",                        "Ordinary days (main run) or a check; a check that changes nothing has no row",
    "distribution_fit_summary", "n_sites",                         "Sites in the row",
    "distribution_fit_summary", "n_site_days",                     "Site-days in the row",
    "distribution_fit_summary", "wins_lognormal",                  "Sites where a lognormal wins among the three curves",
    "distribution_fit_summary", "wins_gamma",                      "Sites where a gamma curve wins among the three curves",
    "distribution_fit_summary", "wins_weibull",                    "Sites where a Weibull curve wins among the three curves",
    "distribution_fit_summary", "wins_with_normal_lognormal",      "Sites where a lognormal wins once the normal curve may compete",
    "distribution_fit_summary", "wins_with_normal_gamma",          "Sites where a gamma curve wins once the normal curve may compete",
    "distribution_fit_summary", "wins_with_normal_weibull",        "Sites where a Weibull curve wins once the normal curve may compete",
    "distribution_fit_summary", "wins_with_normal_normal",         "Sites where the normal curve wins once it may compete",
    "distribution_fit_summary", "median_aic_gap",                  "Median across sites of the AIC gap between winner and runner-up",
    "distribution_fit_summary", "pct_sites_gap_decisive",          "% of sites with an AIC gap of 10 or more",
    "distribution_fit_summary", "median_lag1_correlation",         "Median across sites of the day-to-day correlation of logs; main run only",
    "distribution_fit_summary", "median_effective_days",           "Median across sites of the independent days after links; main run only",
    "distribution_fit_summary", "median_scaled_aic_gap",           "Median across sites of the AIC gap scaled to those days; main run only",
    "distribution_fit_summary", "pct_sites_scaled_gap_decisive",   "% of sites with a scaled AIC gap of 10 or more; main run only",
    "distribution_fit_summary", "n_sites_resampled",               "Sites whose winner was resampled; national rows count only the random sample",
    "distribution_fit_summary", "pct_resampled_clear",             "% of resampled sites keeping their winner in 90%+ of runs; national: random 100",
    "distribution_fit_summary", "median_winner_kept_share",        "Median share of resamples keeping the winner, across resampled sites",
    "distribution_fit_summary", "spread_factor_median",            "Median across sites of the spread factor",
    "distribution_fit_summary", "spread_factor_q1",                "25th percentile across sites of the spread factor",
    "distribution_fit_summary", "spread_factor_q3",                "75th percentile across sites of the spread factor",
    "distribution_fit_summary", "gamma_shape_median",              "Median across sites of the fitted gamma shape",
    "distribution_fit_summary", "weibull_shape_median",            "Median across sites of the fitted Weibull shape",
    "distribution_fit_summary", "n_sites_with_tail",               "Sites with 200 or more days, whose tail ratios are read",
    "distribution_fit_summary", "p99_over_lognormal_median",       "Median across sites of actual P99 / the lognormal's P99",
    "distribution_fit_summary", "p99_over_gamma_median",           "Median across sites of actual P99 / the gamma's P99",
    "distribution_fit_summary", "p99_over_weibull_median",         "Median across sites of actual P99 / the Weibull's P99",
    "distribution_fit_summary", "p99_over_normal_median",          "Median across sites of actual P99 / the normal's P99",
    "distribution_fit_summary", "p99_over_winner_median",          "Median across sites of actual P99 / the winner's P99",
    "distribution_fit_summary", "p99_over_winner_q1",              "25th percentile across sites of actual P99 / the winner's P99",
    "distribution_fit_summary", "p99_over_winner_q3",              "75th percentile across sites of actual P99 / the winner's P99",
    "distribution_fit_summary", "p05_over_winner_median",          "Median across sites of actual P5 / the winner's P5",
    "distribution_fit_summary", "pct_sites_winner_closest_at_p99", "% of sites where the AIC winner is also the closest of the three at P99",
    "distribution_fit_summary", "ks_statistic_median",             "Median across sites of the Kolmogorov-Smirnov distance from the winner",
    "distribution_fit_summary", "anderson_darling_median",         "Median across sites of the Anderson-Darling statistic against the winner"
  ),
  tribble(
    ~table,                     ~column,               ~description,
    "distribution_fit_checks", "check",                "Censored (below-limit and rounding checks), Instrument (PM2.5 T640) or Group spread",
    "distribution_fit_checks", "version",              "The censoring rule, the side of the instrument comparison, or the season of the group gap",
    "distribution_fit_checks", "pollutant",            "PM2.5, Ozone, NO2, SO2 or CO",
    "distribution_fit_checks", "site_id",              "AQS site ID; NA in Group spread rows",
    "distribution_fit_checks", "local_site_name",      "Site name given by the reporting agency; can be NA",
    "distribution_fit_checks", "site_group",           "Case-study group; NA outside the case study",
    "distribution_fit_checks", "comparison",           "Which group is subtracted from which; Group spread rows only",
    "distribution_fit_checks", "n_days",               "Days fitted; NA in Group spread rows",
    "distribution_fit_checks", "pct_censored",         "% of days counted as below a limit; Censored rows only",
    "distribution_fit_checks", "pct_warm_days",        "% of days from April to October; Instrument rows only",
    "distribution_fit_checks", "aic_lognormal",        "AIC of the lognormal curve; compare within a site and version only",
    "distribution_fit_checks", "aic_gamma",            "AIC of the gamma curve; compare within a site and version only",
    "distribution_fit_checks", "aic_weibull",          "AIC of the Weibull curve; compare within a site and version only",
    "distribution_fit_checks", "winner",               "Lowest AIC among the three curves under this version",
    "distribution_fit_checks", "main_winner",          "The site's winner in the main run; Censored rows only",
    "distribution_fit_checks", "is_same_winner",       "TRUE when the censored winner equals the main winner; Censored rows only",
    "distribution_fit_checks", "aic_gap",              "AIC of the runner-up minus AIC of the winner under this version",
    "distribution_fit_checks", "spread_factor",        "exp(fitted SD of the logs) under this version",
    "distribution_fit_checks", "main_spread_factor",   "The site's spread factor in the main run; Censored rows only",
    "distribution_fit_checks", "p99_over_lognormal",   "Actual P99 / the lognormal's P99 under this version; below 1, the curve overpredicts",
    "distribution_fit_checks", "p99_over_winner",      "Actual P99 / the winner's P99 under this version",
    "distribution_fit_checks", "spread_first_group",   "Median site spread factor of the first group named in comparison",
    "distribution_fit_checks", "spread_second_group",  "Median site spread factor of the second group named in comparison",
    "distribution_fit_checks", "spread_gap",           "spread_first_group minus spread_second_group",
    "distribution_fit_checks", "gap_low",              "2.5th percentile of the gap across 1,000 same-date two-week block resamples",
    "distribution_fit_checks", "gap_high",             "97.5th percentile of the gap across those resamples",
    "distribution_fit_checks", "gap_low_check_seed",   "gap_low under the second seed",
    "distribution_fit_checks", "gap_high_check_seed",  "gap_high under the second seed",
    "distribution_fit_checks", "seed_shift_share",     "Largest move of either end between seeds, as a share of the range's width"
  )
)

fit_dictionary <- document_tables(fit_records, fit_dictionary)

replace_own_rows(fit_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

national_main_fits %>%
  select(
    pollutant, n_sites, starts_with("wins_"), median_aic_gap, pct_sites_gap_decisive, median_scaled_aic_gap,
    pct_sites_scaled_gap_decisive, pct_resampled_clear
  ) %>%
  mutate(across(where(is.double), \(x) signif(x, 3))) %>%
  print(n = Inf, width = Inf)

rm(fit_source_days, ordinary_fit_days, warm_fit_days, cool_fit_days, pm25_days, t640_side_days, control_days, instrument_side_days, instrument_pieces)
rm(censored_days, group_range_days, group_range_sets, warm_ozone_days, warm_ozone_all_days, warm_ozone_check_days)
invisible(gc())



# 5. TAILS ----
# each curve gets fit to a site's days and then asked how many of those same days are over a level, so this tests fit
# and forecasts nothing. expected days = days measured x the curve's share over the level
tail_curves <- names(fitdist_names)

curve_shares_above <- function(scaled_cut, parameters) {
  c(
    lognormal = plnorm(scaled_cut, parameters$meanlog, parameters$sdlog, lower.tail = FALSE),
    gamma = pgamma(scaled_cut, parameters$gamma_shape, rate = parameters$gamma_rate, lower.tail = FALSE),
    weibull = pweibull(scaled_cut, parameters$weibull_shape, parameters$weibull_scale, lower.tail = FALSE),
    normal = if (is.null(parameters$normal_sd)) NA_real_ else pnorm(scaled_cut, parameters$normal_mean, parameters$normal_sd, lower.tail = FALSE)
  )
}

# readings sit on a grid of measurement steps and the curve is smooth. a reading of 0.071 stands for the curve from
# 0.0705 to 0.0715, so the curve gets read halfway between the last day left out and the first day counted
percentile_boundary <- function(values, cut) {
  above <- values[values > cut]
  below <- values[values <= cut]
  if (length(above) == 0 || length(below) == 0) {
    return(cut)
  }
  (max(below) + min(above)) / 2
}

limit_rows <- split(short_term_limits, short_term_limits$pollutant)

days_above_limit <- function(values, limit_row) {
  rounded <- if (limit_row$rounding == "truncate") truncate_to(values, limit_row$digits) else round_half_up(values, limit_row$digits)
  sum(rounded > limit_row$limit)
}

site_tail_rows <- function(values, value_step, limit_row, parameters, winner, half_step = TRUE) {
  n_days <- length(values)
  percentile_cuts <- quantile(values, tail_percentiles, names = FALSE)
  curve_cuts <- c(
    if (half_step) limit_row$first_counted - value_step / 2 else limit_row$first_counted,
    if (half_step) vapply(percentile_cuts, \(cut) percentile_boundary(values, cut), numeric(1)) else percentile_cuts
  )
  expected <- t(vapply(curve_cuts, \(cut) n_days * curve_shares_above(cut / mean(values), parameters), numeric(length(tail_curves))))
  actual <- c(days_above_limit(values, limit_row), vapply(percentile_cuts, \(cut) sum(values > cut), numeric(1)))
  closest <- vapply(seq_along(actual), \(i) {
    if (actual[i] == 0) NA_character_ else names(which.min(abs(log(expected[i, contest_curves] / actual[i]))))
  }, character(1))
  winner_expected <- expected[, winner]
  tibble(
    test = tail_test_levels,
    cut_value = c(limit_row$first_counted, percentile_cuts),
    curve_cut = curve_cuts,
    n_days = n_days,
    actual_days = actual,
    expected_lognormal = expected[, "lognormal"],
    expected_gamma = expected[, "gamma"],
    expected_weibull = expected[, "weibull"],
    expected_normal = expected[, "normal"],
    winner = winner,
    expected_winner = winner_expected,
    closest_curve = closest
  )
}

site_step_lookup <- setNames(fit_site_inventory$value_step, str_c(fit_site_inventory$pollutant, "|", fit_site_inventory$site_id))

fit_tail_sites <- function(site_days, site_set, half_step = TRUE) {
  kept_days <- site_days %>%
    filter(n() >= min_shape_days, .by = c(pollutant, site_id))

  site_values <- split(kept_days$value_fit, str_c(kept_days$pollutant, "|", kept_days$site_id))

  site_rows <- lapply(setNames(names(site_values), names(site_values)), \(site_key) {
    parameters <- fast_curve_parameters(site_values[[site_key]])
    site_tail_rows(
      site_values[[site_key]],
      site_step_lookup[[site_key]],
      limit_rows[[str_extract(site_key, "^[^|]+")]],
      parameters,
      names(which.max(curve_log_likelihoods(parameters)[contest_curves])),
      half_step
    )
  })

  bind_rows(site_rows, .id = "site_key") %>%
    separate_wider_delim(site_key, "|", names = c("pollutant", "site_id")) %>%
    mutate(pollutant = factor(pollutant, levels = pollutant_levels)) %>%
    mutate(site_set = site_set)
}

tail_source_days <- fit_days %>%
  select(pollutant, site_id, date_local, month, event_class, is_at_or_below_zero, value_fit) %>%
  semi_join(filter(shape_site_flags, !is_near_zero_site), by = c("pollutant", "site_id"))

tail_ordinary_days <- tail_source_days %>%
  filter(event_class == "None")

# same 2a rounding gives the same count from the reported and fitting values, they only differ at or below zero
limit_count_check <- fit_days %>%
  inner_join(short_term_limits, by = "pollutant", relationship = "many-to-one") %>%
  mutate(value_rounded = if_else(rounding == "truncate", truncate_to(value, digits), round_half_up(value, digits))) %>%
  mutate(is_above = value_rounded > limit) %>%
  mutate(is_above_by_first_counted = value >= first_counted - 1e-9)

tail_started <- Sys.time()

tail_test_results <- cached_step(
  "tail_tests",
  select(tail_source_days, pollutant, site_id, month, event_class, is_at_or_below_zero, value_fit),
  list(
    site_step_lookup, short_term_limits, tail_percentiles, tail_test_levels, tail_curves, contest_curves, min_shape_days, weibull_step_tolerance,
    warm_months
  ),
  list(
    fit_tail_sites, site_tail_rows, curve_shares_above, percentile_boundary, days_above_limit, fast_curve_parameters, curve_log_likelihoods,
    truncate_to, round_half_up
  ),
  \() list(
    site_rows = bind_rows(
      fit_tail_sites(tail_ordinary_days, "Ordinary days"),
      fit_tail_sites(tail_source_days, "All days"),
      fit_tail_sites(filter(tail_ordinary_days, pollutant == "Ozone", month %in% warm_months), "Warm season")
    ),
    check_rows = bind_rows(
      fit_tail_sites(filter(tail_ordinary_days, !is_at_or_below_zero), "Without values at or below zero"),
      fit_tail_sites(tail_ordinary_days, "Without the half-step", half_step = FALSE)
    )
  )
)

tail_site_rows <- tail_test_results$site_rows

tail_check_rows <- tail_test_results$check_rows

cat("Tail tests, seconds:", round(as.numeric(difftime(Sys.time(), tail_started, units = "secs"))), "\n")

tail_winner_check <- tail_site_rows %>%
  distinct(pollutant, site_id, site_set, winner) %>%
  inner_join(
    select(site_fits, pollutant, site_id, site_set, fit_winner = winner),
    by = c("pollutant", "site_id", "site_set"),
    relationship = "one-to-one"
  )

tail_percentile_rows <- tail_site_rows %>%
  filter(test != "Limit", site_set == "Ordinary days", n_days >= min_tail_days)

tail_site_flags <- shape_site_flags %>%
  select(pollutant, site_id, local_site_name, state_name, site_group, region, is_year_round, has_method_change, sampling_schedule, federal_mdl_max)

add_tail_flags <- function(tail_rows) {
  tail_rows %>%
    left_join(tail_site_flags, by = c("pollutant", "site_id"), relationship = "many-to-one") %>%
    mutate(is_judged = actual_days >= min_judged_days & n_days >= min_tail_days)
}

tail_site_rows <- add_tail_flags(tail_site_rows)

tail_check_rows <- add_tail_flags(tail_check_rows)

stopifnot(
  "The limit rule and the first counted value pick the same days" = all(limit_count_check$is_above == limit_count_check$is_above_by_first_counted),
  "Limit counts on all days match the 2a rounding" =
    sum(tail_site_rows$actual_days[tail_site_rows$test == "Limit" & tail_site_rows$site_set == "All days"]) ==
      sum(semi_join(limit_count_check, filter(shape_site_flags, !is_near_zero_site), by = c("pollutant", "site_id"))$is_above),
  "Tail tests use the winner section 4 named at every site" =
    nrow(tail_winner_check) == n_distinct(tail_site_rows$pollutant, tail_site_rows$site_id, tail_site_rows$site_set) &&
    all(tail_winner_check$winner == tail_winner_check$fit_winner),
  "Every test has a row per site and set" = !anyDuplicated(select(tail_site_rows, pollutant, site_id, site_set, test)),
  "Expected days stay between 0 and the days measured" =
    all(between(tail_site_rows$expected_winner, 0, tail_site_rows$n_days)) && !anyNA(tail_site_rows$expected_normal),
  "Each curve is read at a positive value" = all(tail_percentile_rows$curve_cut > 0),
  "Percentile tests count about the share they should" =
    all(tail_percentile_rows$actual_days <= (1 - tail_percentiles[tail_percentile_rows$test]) * tail_percentile_rows$n_days + 1)
)

rm(limit_count_check)
invisible(gc())

# totals show if a curve gets the overall count right. misses with opposite signs cancel in a total, so the typical judged
# site and the share of judged sites within 25% go next to it
summarise_tails <- function(tail_rows, group_cols) {
  tail_rows %>%
    summarise(
      n_sites = n(),
      n_site_days = sum(n_days),
      n_actual_days = sum(actual_days),
      pct_days_above = 100 * sum(actual_days) / sum(n_days),
      n_sites_with_actual_days = sum(actual_days > 0),
      pct_actual_in_top_sites =
        if (n() > n_top_tail_sites) 100 * sum(sort(actual_days, decreasing = TRUE)[seq_len(n_top_tail_sites)]) / sum(actual_days) else NA_real_,
      across(starts_with("expected_"), sum, .names = "total_{.col}"),
      across(
        starts_with("expected_"),
        \(x) sum(x) / sum(actual_days),
        .names = "ratio_total_{str_remove(.col, 'expected_')}"
      ),
      n_judged_sites = sum(is_judged),
      across(
        starts_with("expected_"),
        \(x) median((x / actual_days)[is_judged]),
        .names = "median_ratio_{str_remove(.col, 'expected_')}"
      ),
      q1_ratio_winner = quantile((expected_winner / actual_days)[is_judged], 0.25, names = FALSE, na.rm = TRUE),
      q3_ratio_winner = quantile((expected_winner / actual_days)[is_judged], 0.75, names = FALSE, na.rm = TRUE),
      across(
        starts_with("expected_"),
        \(x) 100 * mean(between((x / actual_days)[is_judged], 1 / close_tail_ratio, close_tail_ratio)),
        .names = "pct_within_25_{str_remove(.col, 'expected_')}"
      ),
      pct_closest_lognormal = 100 * mean(closest_curve[is_judged] == "lognormal"),
      pct_closest_gamma = 100 * mean(closest_curve[is_judged] == "gamma"),
      pct_closest_weibull = 100 * mean(closest_curve[is_judged] == "weibull"),
      pct_winner_closest = 100 * mean(closest_curve[is_judged] == winner[is_judged]),
      .by = all_of(group_cols)
    ) %>%
    mutate(across(where(is.double), \(x) if_else(is.nan(x) | is.infinite(x), NA_real_, x)))
}

tail_ordinary_rows <- tail_site_rows %>%
  filter(site_set == "Ordinary days")

national_tail_sets <- list(
  "Ordinary days" = tail_ordinary_rows,
  "All days" = filter(tail_site_rows, site_set == "All days"),
  "Warm season" = filter(tail_site_rows, site_set == "Warm season"),
  "Without values at or below zero" = filter(tail_check_rows, site_set == "Without values at or below zero"),
  "Year-round sites" = filter(tail_ordinary_rows, is_year_round),
  "Sites on daily sampling" = filter(tail_ordinary_rows, sampling_schedule == "Daily"),
  "Sites without a method change" = filter(tail_ordinary_rows, !has_method_change),
  "Sites with a method change" = filter(tail_ordinary_rows, has_method_change),
  "Western PM2.5 sites" = filter(tail_ordinary_rows, pollutant == "PM2.5", region == "West"),
  "Eastern PM2.5 sites" = filter(tail_ordinary_rows, pollutant == "PM2.5", region == "East"),
  "SO2 sites with a lower limit" = filter(tail_ordinary_rows, pollutant == "SO2", federal_mdl_max < coarse_so2_limit)
)

national_tail_summary <- bind_rows(Map(
  \(tail_rows, site_set) mutate(summarise_tails(tail_rows, c("pollutant", "test")), site_set = site_set),
  national_tail_sets,
  names(national_tail_sets)
)) %>%
  drop_unchanged_checks(c("pollutant", "test"), kept_sets = "Ordinary days") %>%
  bind_rows(mutate(
    summarise_tails(filter(tail_check_rows, site_set == "Without the half-step"), c("pollutant", "test")),
    site_set = "Without the half-step"
  )) %>%
  mutate(scope = "National")

# same by case-study group with the checks 2b runs. warm-month ozone leads so it runs each check too
case_tail_source <- tail_site_rows %>%
  filter(!is.na(site_group))

case_warm_ozone_days <- case_fit_source %>%
  filter(pollutant == "Ozone", month %in% warm_months)

case_warm_ozone_limit_days <- case_warm_ozone_days %>%
  summarise(n_above = days_above_limit(value_fit, limit_rows[["Ozone"]]), .by = c(site_group, site_id))

busiest_warm_ozone_sites <- case_warm_ozone_limit_days %>%
  slice_max(n_above, n = 1, with_ties = FALSE, by = site_group)

case_tail_check_days <- list(
  "Without the transition band" = filter(case_fit_source, !in_transition_band),
  "Without days after method changes" =
    filter(case_fit_source, !(coalesce(sensitivity_left_out == "Days after the method change", FALSE) & is_post_method_change)),
  "Without whole-site checks" = filter(case_fit_source, !coalesce(sensitivity_left_out == "Whole site", FALSE)),
  "Without Deer Park #2 after its move" = filter(case_fit_source, !is_post_relocation)
)

warm_ozone_tail_check_days <- list(
  "Warm season, all days" = filter(case_fit_days, pollutant == "Ozone", month %in% warm_months),
  "Warm season, without readings below the limit" = filter(case_warm_ozone_days, !is_below_mdl),
  "Warm season, without the transition band" = filter(case_warm_ozone_days, !in_transition_band),
  "Warm season, without days after method changes" =
    filter(case_warm_ozone_days, !(coalesce(sensitivity_left_out == "Days after the method change", FALSE) & is_post_method_change)),
  "Warm season, without Deer Park #2 after its move" = filter(case_warm_ozone_days, !is_post_relocation),
  "Warm season, without each group's busiest site" = anti_join(case_warm_ozone_days, busiest_warm_ozone_sites, by = "site_id")
)

fit_case_tail_sets <- function(day_sets) {
  bind_rows(Map(
    \(site_days, site_set) fit_tail_sites(site_days, site_set),
    day_sets,
    names(day_sets)
  )) %>%
    add_tail_flags()
}

case_check_tail_rows <- fit_case_tail_sets(c(case_tail_check_days, warm_ozone_tail_check_days))

case_tail_rows <- bind_rows(
  case_tail_source,
  filter(tail_check_rows, !is.na(site_group), site_set == "Without values at or below zero"),
  filter(case_check_tail_rows, !str_starts(site_set, "Warm season"))
)

case_group_test_cols <- c("pollutant", "site_group", "test")

case_tail_summary <- case_tail_rows %>%
  summarise_tails(c(case_group_test_cols, "site_set")) %>%
  drop_unchanged_checks(case_group_test_cols, kept_sets = "Ordinary days") %>%
  bind_rows(summarise_tails(filter(case_check_tail_rows, str_starts(site_set, "Warm season")), c(case_group_test_cols, "site_set"))) %>%
  bind_rows(summarise_tails(
    filter(tail_check_rows, !is.na(site_group), site_set == "Without the half-step"),
    c(case_group_test_cols, "site_set")
  )) %>%
  mutate(scope = "Case study")

tail_summary_set_levels <- c(shape_summary_set_levels, "Without the half-step", names(warm_ozone_tail_check_days))

tail_summary <- bind_rows(national_tail_summary, case_tail_summary) %>%
  mutate(scope = factor(scope, levels = c("National", "Case study"))) %>%
  mutate(site_set = factor(site_set, levels = tail_summary_set_levels)) %>%
  mutate(test = factor(test, levels = tail_test_levels)) %>%
  arrange(scope, pollutant, site_group, site_set, test) %>%
  select(scope, pollutant, site_group, site_set, test, everything())

print(as.data.frame(tail_summary %>%
  filter(scope == "National", site_set %in% c("Ordinary days", "All days", "Warm season")) %>%
  select(
    pollutant, site_set, test, n_sites, n_actual_days, starts_with("ratio_total_"), n_judged_sites, median_ratio_winner,
    pct_within_25_winner, pct_winner_closest
  ) %>%
  mutate(across(where(is.double), \(x) signif(x, 3)))))

national_tail_counts <- tail_summary %>%
  filter(scope == "National", site_set == "Ordinary days") %>%
  left_join(eligible_site_counts, by = "pollutant", relationship = "many-to-one")

stopifnot(
  "Each check names a set the table knows" = !anyNA(tail_summary$site_set),
  "Each national main row covers every site" = all(national_tail_counts$n_sites == national_tail_counts$n),
  "Forty-one case-study sites are tested: PM2.5 7, ozone 22, NO2 11, SO2 1" =
    sum(tail_summary$n_sites[tail_summary$scope == "Case study" & tail_summary$site_set == "Ordinary days" & tail_summary$test == "Limit"]) == 41
)

# ranges for warm-month and year-round ozone at the limit, in houston and DFW. bad days come in runs and sites
# share weather, so one resample draws the same 2-week blocks of dates at every site and refits every curve. each site
# keeps its named winner, bc a winner that flipped inside a resample would give a range with two humps
range_tail_curves <- c(tail_curves, "winner")

prepare_tail_range_days <- function(site_days) {
  all_dates <- sort(unique(site_days$date_local))
  site_pieces <- split(site_days, site_days$site_id)
  list(
    n_dates = length(all_dates),
    sites = lapply(names(site_pieces), \(site_id) {
      piece <- site_pieces[[site_id]]
      list(
        values = piece$value_fit,
        date_index = match(piece$date_local, all_dates),
        group = as.character(first(piece$site_group)),
        curve_cut = limit_rows[["Ozone"]]$first_counted - site_step_lookup[[str_c("Ozone|", site_id)]] / 2,
        winner = names(which.max(curve_log_likelihoods(fast_curve_parameters(piece$value_fit))[contest_curves]))
      )
    })
  )
}

group_tail_totals <- function(range_days, date_weights = NULL) {
  site_totals <- t(vapply(range_days$sites, \(site) {
    values <- if (is.null(date_weights)) site$values else rep(site$values, date_weights[site$date_index])
    stopifnot("Every site keeps days in each resample" = length(values) >= min_shape_days)
    parameters <- fast_curve_parameters(values)
    expected <- length(values) * curve_shares_above(site$curve_cut / mean(values), parameters)
    c(days = length(values), actual = days_above_limit(values, limit_rows[["Ozone"]]), expected, winner = expected[[site$winner]])
  }, numeric(2 + length(range_tail_curves))))
  rowsum(site_totals, vapply(range_days$sites, \(site) site$group, character(1)), reorder = TRUE)
}

tail_range_measures <- function(totals) {
  ratios <- totals[, range_tail_curves, drop = FALSE] / totals[, "actual"]
  shares <- 100 * totals[, "actual"] / totals[, "days"]
  ratio_names <- str_c(rep(colnames(ratios), each = nrow(ratios)), "|", rep(rownames(ratios), times = ncol(ratios)))
  c(setNames(shares, str_c("Days above the limit, %|", rownames(totals))), setNames(as.vector(ratios), ratio_names))
}

group_tail_ranges <- function(site_days, set_name, seed) {
  range_days <- prepare_tail_range_days(site_days)
  block_starts <- seq_len(range_days$n_dates - stability_block_days + 1)
  n_blocks <- ceiling(range_days$n_dates / stability_block_days)
  block_offsets <- seq_len(stability_block_days) - 1
  point_estimate <- tail_range_measures(group_tail_totals(range_days))
  set.seed(seed)
  resampled <- t(vapply(seq_len(tail_range_reps), \(rep) {
    picked <- sample(block_starts, n_blocks, replace = TRUE)
    chosen <- as.vector(outer(block_offsets, picked, `+`))[seq_len(range_days$n_dates)]
    tail_range_measures(group_tail_totals(range_days, tabulate(chosen, range_days$n_dates)))
  }, numeric(length(point_estimate))))
  colnames(resampled) <- names(point_estimate)
  measure_levels <- unique(str_extract(names(point_estimate), "^[^|]+"))
  group_rows <- tibble(measure_key = names(point_estimate)) %>%
    separate_wider_delim(measure_key, "|", names = c("measure", "site_group"), cols_remove = FALSE) %>%
    mutate(estimate = unname(point_estimate[measure_key])) %>%
    mutate(range_low = apply(resampled[, measure_key, drop = FALSE], 2, quantile, 0.025, names = FALSE)) %>%
    mutate(range_high = apply(resampled[, measure_key, drop = FALSE], 2, quantile, 0.975, names = FALSE)) %>%
    mutate(reference = if_else(measure == first(measure_levels), NA_real_, 1)) %>%
    select(-measure_key)
  gap_rows <- bind_rows(lapply(seq_len(nrow(group_gap_comparisons)), \(i) {
    first_group <- group_gap_comparisons$first_group[i]
    second_group <- group_gap_comparisons$second_group[i]
    gaps <- resampled[, str_c(measure_levels, "|", first_group), drop = FALSE] - resampled[, str_c(measure_levels, "|", second_group), drop = FALSE]
    tibble(
      measure = measure_levels,
      comparison = group_gap_comparisons$comparison[i],
      estimate = unname(point_estimate[str_c(measure_levels, "|", first_group)] - point_estimate[str_c(measure_levels, "|", second_group)]),
      range_low = apply(gaps, 2, quantile, 0.025, names = FALSE),
      range_high = apply(gaps, 2, quantile, 0.975, names = FALSE),
      reference = 0
    )
  }))
  bind_rows(group_rows, gap_rows) %>%
    mutate(site_set = set_name)
}

tail_range_sets <- list(
  "Warm season" = case_warm_ozone_days,
  "Ordinary days" = filter(case_fit_source, pollutant == "Ozone")
)

tail_range_rows <- function(seed) {
  bind_rows(Map(\(site_days, set_name) group_tail_ranges(site_days, set_name, seed), tail_range_sets, names(tail_range_sets)))
}

ranges_started <- Sys.time()

tail_range_results <- cached_step(
  "tail_ranges",
  lapply(tail_range_sets, \(site_days) select(site_days, site_id, site_group, date_local, value_fit)),
  list(
    group_range_seed, group_range_check_seed, tail_range_reps, stability_block_days, min_shape_days, range_tail_curves, tail_curves, contest_curves,
    site_step_lookup, limit_rows[["Ozone"]], group_gap_comparisons, weibull_step_tolerance
  ),
  list(
    tail_range_rows, group_tail_ranges, prepare_tail_range_days, group_tail_totals, tail_range_measures, curve_shares_above, days_above_limit,
    fast_curve_parameters, curve_log_likelihoods, truncate_to, round_half_up
  ),
  \() list(main = tail_range_rows(group_range_seed), check = tail_range_rows(group_range_check_seed))
)

tail_ranges <- tail_range_results$main

tail_ranges_check <- tail_range_results$check %>%
  select(site_set, measure, site_group, comparison, range_low_check_seed = range_low, range_high_check_seed = range_high)

cat("Tail ranges, seconds:", round(as.numeric(difftime(Sys.time(), ranges_started, units = "secs"))), "\n")

tail_ranges <- tail_ranges %>%
  left_join(tail_ranges_check, by = c("site_set", "measure", "site_group", "comparison"), relationship = "one-to-one") %>%
  mutate(seed_shift_share = pmax(abs(range_low - range_low_check_seed), abs(range_high - range_high_check_seed)) / (range_high - range_low)) %>%
  mutate(is_clear_of_reference = range_low > reference | range_high < reference) %>%
  mutate(pollutant = factor("Ozone", levels = pollutant_levels)) %>%
  mutate(test = "Limit")

print(as.data.frame(mutate(tail_ranges, across(where(is.double), \(x) round(x, 3))) %>%
  select(site_set, measure, site_group, comparison, estimate, range_low, range_high, seed_shift_share, is_clear_of_reference)))

cat("Largest seed shift in the tail ranges:", round(max(tail_ranges$seed_shift_share), 3), "\n")

stopifnot(
  "Both seeds give the same tail ranges within the tolerance" = all(tail_ranges$seed_shift_share <= group_range_seed_tolerance),
  "Thirty-six range rows for each ozone set" = nrow(tail_ranges) == 36 * length(tail_range_sets)
)

tail_curve_values <- seq(0.055, 0.1, by = 0.001)

warm_ozone_pieces <- split(case_warm_ozone_days, case_warm_ozone_days$site_id)

warm_ozone_curves <- bind_rows(lapply(warm_ozone_pieces, \(piece) {
  values <- piece$value_fit
  parameters <- fast_curve_parameters(values)
  site_step <- site_step_lookup[[str_c("Ozone|", first(piece$site_id))]]
  expected <- t(vapply(tail_curve_values, \(value) {
    length(values) * curve_shares_above((value - site_step / 2) / mean(values), parameters)
  }, numeric(length(tail_curves))))
  tibble(
    site_group = as.character(first(piece$site_group)),
    value_ppm = tail_curve_values,
    n_days = length(values),
    actual_days = vapply(tail_curve_values, \(value) sum(values >= value - 1e-9), numeric(1)),
    expected_lognormal = expected[, "lognormal"],
    expected_gamma = expected[, "gamma"],
    expected_weibull = expected[, "weibull"],
    expected_normal = expected[, "normal"]
  )
})) %>%
  summarise(
    n_site_days = sum(n_days),
    n_actual_days = sum(actual_days),
    pct_actual = 100 * sum(actual_days) / sum(n_days),
    pct_lognormal = 100 * sum(expected_lognormal) / sum(n_days),
    pct_gamma = 100 * sum(expected_gamma) / sum(n_days),
    pct_weibull = 100 * sum(expected_weibull) / sum(n_days),
    pct_normal = 100 * sum(expected_normal) / sum(n_days),
    .by = c(site_group, value_ppm)
  ) %>%
  mutate(site_group = factor(site_group, levels = names(site_group_colours))) %>%
  arrange(site_group, value_ppm)

warm_ozone_limit_rows <- case_tail_summary %>%
  filter(pollutant == "Ozone", site_set == "Warm season", test == "Limit") %>%
  mutate(site_group = as.character(site_group))

warm_ozone_curves_at_limit <- warm_ozone_curves %>%
  filter(abs(value_ppm - limit_rows[["Ozone"]]$first_counted) < 1e-9) %>%
  mutate(site_group = as.character(site_group)) %>%
  inner_join(warm_ozone_limit_rows, by = "site_group", relationship = "one-to-one", suffix = c("", "_summary")) %>%
  mutate(gamma_days_gap = abs(pct_gamma * n_site_days / 100 - total_expected_gamma))

stopifnot(
  "The tail curves match the limit test" =
    all(warm_ozone_curves_at_limit$n_actual_days == warm_ozone_curves_at_limit$n_actual_days_summary) &&
    all(warm_ozone_curves_at_limit$gamma_days_gap < 1e-6) &&
    nrow(warm_ozone_curves_at_limit) == 3,
  "A site's share of days above a value falls as the value rises" =
    all(with(warm_ozone_curves, ave(pct_actual, site_group, FUN = \(x) c(0, diff(x)))) <= 0)
)

# deer park #2 with below-limit readings censored, read at the same levels as the main fit. the fits repeat section 4's,
# which only kept their AIC and P99
deer_park_tail_days <- tail_ordinary_days %>%
  filter(pollutant == "SO2", site_id == deer_park_id) %>%
  left_join(
    select(fit_days, pollutant, site_id, date_local, value, federal_mdl),
    by = c("pollutant", "site_id", "date_local"),
    relationship = "one-to-one"
  )

deer_park_censored <- censored_data(deer_park_tail_days, "Readings below the limit censored") %>%
  mutate(left = round(left, 10)) %>%
  mutate(right = round(right, 10)) %>%
  count(left, right, name = "n_days") %>%
  as.data.frame()

deer_park_starts <- curve_starts(fast_curve_parameters(deer_park_tail_days$value_fit))

deer_park_curve_fits <- lapply(setNames(contest_curves, contest_curves), \(curve) {
  withCallingHandlers(
    fitdistrplus::fitdistcens(
      deer_park_censored[, c("left", "right")],
      fitdist_names[[curve]],
      start = deer_park_starts[[curve]],
      weights = deer_park_censored$n_days,
      calcvcov = FALSE,
      control = list(reltol = fit_relative_tolerance)
    ),
    warning = \(w) if (str_detect(conditionMessage(w), "default initial values")) invokeRestart("muffleWarning")
  )
})

deer_park_censored_row <- deer_park_fits %>%
  filter(version == "Readings below the limit censored")

deer_park_parameters <- list(
  meanlog = deer_park_curve_fits$lognormal$estimate[["meanlog"]],
  sdlog = deer_park_curve_fits$lognormal$estimate[["sdlog"]],
  gamma_shape = deer_park_curve_fits$gamma$estimate[["shape"]],
  gamma_rate = deer_park_curve_fits$gamma$estimate[["rate"]],
  weibull_shape = deer_park_curve_fits$weibull$estimate[["shape"]],
  weibull_scale = deer_park_curve_fits$weibull$estimate[["scale"]]
)

deer_park_tail_rows <- site_tail_rows(
  deer_park_tail_days$value_fit,
  site_step_lookup[[str_c("SO2|", deer_park_id)]],
  limit_rows[["SO2"]],
  deer_park_parameters,
  deer_park_censored_row$winner
) %>%
  mutate(pollutant = factor("SO2", levels = pollutant_levels)) %>%
  mutate(site_id = deer_park_id) %>%
  mutate(site_set = "Readings below the limit censored") %>%
  add_tail_flags()

deer_park_tail_view <- tail_ordinary_rows %>%
  filter(pollutant == "SO2", site_id == deer_park_id) %>%
  bind_rows(deer_park_tail_rows) %>%
  select(site_set, test, cut_value, curve_cut, n_days, actual_days, starts_with("expected_"), winner, closest_curve)

print(as.data.frame(mutate(deer_park_tail_view, across(where(is.double), \(x) signif(x, 4)))))

stopifnot(
  "The Deer Park #2 refit matches section 4's AIC on every curve" =
    abs(deer_park_curve_fits$lognormal$aic - deer_park_censored_row$aic_lognormal) < fit_agreement_tolerance &&
    abs(deer_park_curve_fits$gamma$aic - deer_park_censored_row$aic_gamma) < fit_agreement_tolerance &&
    abs(deer_park_curve_fits$weibull$aic - deer_park_censored_row$aic_weibull) < fit_agreement_tolerance,
  "Deer Park #2 reads below the limit on more than a fifth of days" = deer_park_censored_row$pct_censored > 20
)

national_tail_main <- tail_summary %>%
  filter(scope == "National", site_set == "Ordinary days")

tail_curve_colours <- curve_fills

tail_ratio_breaks <- c(0.1, 0.25, 0.5, 1, 2, 4)

tail_ratio_labels <- c("0.1", "0.25", "0.5", "1", "2", "4")

tail_ratios_long <- function(summary_rows) {
  summary_rows %>%
    select(row_label, starts_with("ratio_total_")) %>%
    pivot_longer(starts_with("ratio_total_"), names_to = "curve", names_prefix = "ratio_total_", values_to = "ratio")
}

tail_ratio_panel <- function(summary_rows, panel_number, panel_title, panel_subtitle) {
  ratios <- tail_ratios_long(summary_rows)
  curve_ratios <- ratios %>%
    filter(curve != "winner") %>%
    mutate(curve = curve_labels[curve])
  winner_ratios <- ratios %>%
    filter(curve == "winner")
  ggplot(curve_ratios, aes(ratio, row_label)) +
    geom_vline(xintercept = 1, colour = chart_ink[["axis"]], linewidth = 0.4) +
    geom_line(aes(group = row_label), colour = chart_ink[["grid"]], linewidth = 0.5) +
    geom_point(aes(colour = curve), size = 2, alpha = 0.95) +
    geom_point(data = winner_ratios, shape = "|", size = 5, colour = chart_ink[["primary"]]) +
    scale_colour_manual(values = tail_curve_colours, guide = "none") +
    scale_x_log10(limits = c(0.05, 4.5), breaks = tail_ratio_breaks, labels = tail_ratio_labels) +
    labs(title = panel_label(panel_number, panel_title), subtitle = panel_subtitle, x = "Expected \u00f7 actual days, log scale", y = NULL) +
    scale_y_discrete(labels = pretty_text) +
    theme_paper() +
    theme(panel.grid.major.y = element_blank(), panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25))
}

p99_national_rows <- national_tail_main %>%
  filter(test == "P99") %>%
  mutate(row_label = factor(pollutant, levels = rev(pollutant_levels)))

limit_row_levels <- c("Ozone", "Ozone, warm", "PM2.5", "PM2.5, all days")

limit_national_rows <- tail_summary %>%
  filter(scope == "National", test == "Limit", pollutant %in% c("Ozone", "PM2.5"), site_set %in% c("Ordinary days", "Warm season", "All days")) %>%
  filter(!(pollutant == "Ozone" & site_set == "All days")) %>%
  mutate(row_name = case_when(
    pollutant == "Ozone" & site_set == "Warm season" ~ "Ozone, warm",
    pollutant == "PM2.5" & site_set == "All days" ~ "PM2.5, all days",
    .default = as.character(pollutant)
  )) %>%
  mutate(row_name = factor(row_name, levels = limit_row_levels)) %>%
  arrange(row_name) %>%
  mutate(row_text = sprintf("%s\n%s days", row_name, comma(n_actual_days))) %>%
  mutate(row_label = factor(row_text, levels = rev(row_text)))

typical_site_rows <- tail_ordinary_rows %>%
  filter(test == "P99", is_judged) %>%
  mutate(ratio_winner = expected_winner / actual_days) %>%
  box_stats("ratio_winner", "pollutant") %>%
  inner_join(select(p99_national_rows, pollutant, n_judged_sites, median_ratio_winner), by = "pollutant", relationship = "one-to-one") %>%
  arrange(factor(pollutant, levels = pollutant_levels)) %>%
  mutate(row_label = factor(sprintf("%s (%d)", pollutant, n_judged_sites), levels = rev(sprintf("%s (%d)", pollutant, n_judged_sites))))

stopifnot(
  "Every judged pollutant has a box" = nrow(typical_site_rows) == nrow(p99_national_rows),
  "Box medians match the saved typical-site ratios" = isTRUE(all.equal(typical_site_rows$box_median, typical_site_rows$median_ratio_winner)),
  "Each box holds every judged site" = all(typical_site_rows$n_values == typical_site_rows$n_judged_sites)
)

typical_site_panel <- ggplot(typical_site_rows, aes(y = row_label)) +
  geom_vline(xintercept = 1, colour = chart_ink[["axis"]], linewidth = 0.4) +
  geom_box_whisker(horizontal = TRUE, width = 0.55, colour = chart_ink[["secondary"]], fill = alpha(chart_fills[["other"]], 0.6)) +
  geom_text(
    aes(x = p90, label = sprintf("%.2f", box_median)),
    family = chart_fonts[["mono"]],
    size = chart_sizes[["label"]] / .pt,
    colour = chart_ink[["primary"]],
    hjust = -0.35
  ) +
  scale_x_log10(breaks = c(0.25, 0.5, 1, 2, 4), labels = c("0.25", "0.5", "1", "2", "4"), expand = expansion(mult = c(0.05, 0.16))) +
  scale_y_discrete(labels = pretty_text) +
  labs(
    title = panel_label(3, "Each site, top 1%"),
    subtitle = "The winner, site by site",
    x = "Expected \u00f7 actual days",
    y = NULL
  ) +
  theme_paper() +
  theme(panel.grid.major.y = element_blank(), panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25))

within_levels <- c("lognormal" = "Logn.", "gamma" = "Gamma", "weibull" = "Weib.", "normal" = "Norm.", "winner" = "Winner")

within_table <- p99_national_rows %>%
  select(pollutant, starts_with("pct_within_25_")) %>%
  pivot_longer(starts_with("pct_within_25_"), names_to = "curve", names_prefix = "pct_within_25_", values_to = "pct_within") %>%
  mutate(curve = factor(within_levels[curve], levels = within_levels)) %>%
  mutate(pollutant = factor(pollutant, levels = rev(pollutant_levels)))

within_panel <- ggplot(within_table, aes(curve, pollutant, fill = pct_within)) +
  geom_tile(colour = "white", linewidth = 0.8) +
  geom_text(
    aes(label = sprintf("%.0f", pct_within)),
    family = chart_fonts[["mono"]],
    size = chart_sizes[["label"]] / .pt,
    colour = chart_ink[["primary"]]
  ) +
  scale_fill_gradient(low = chart_fills[["band"]], high = chart_fills[["accent"]], limits = c(0, 60), guide = "none") +
  scale_x_discrete(position = "top") +
  scale_y_discrete(labels = pretty_text) +
  labs(title = panel_label(4, "% of sites within 25%, top 1%"), subtitle = "Few sites land close", x = NULL, y = NULL) +
  theme_paper() +
  theme(panel.grid = element_blank())

national_p99_checks <- tail_summary %>%
  filter(scope == "National", test == "P99")

national_limit_checks <- tail_summary %>%
  filter(scope == "National", test == "Limit")

pm25_limit_main <- limit_national_rows %>%
  filter(row_name == "PM2.5")

pm25_limit_all <- limit_national_rows %>%
  filter(row_name == "PM2.5, all days")

ozone_limit_main <- limit_national_rows %>%
  filter(row_name == "Ozone")

ozone_p99_row <- p99_national_rows %>%
  filter(pollutant == "Ozone")

pm25_p99_row <- p99_national_rows %>%
  filter(pollutant == "PM2.5")

no2_p99_row <- p99_national_rows %>%
  filter(pollutant == "NO2")

stopifnot(
  "Under half of judged sites sit within 25% at P99 under every check" = all(national_p99_checks$pct_within_25_winner < 50),
  "Ozone's total lands near 1 while its typical site spreads wide" =
    abs(ozone_p99_row$ratio_total_winner - 1) < 0.15 && ozone_p99_row$q1_ratio_winner < 0.75 && ozone_p99_row$q3_ratio_winner > 1.25,
  "PM2.5's winner runs short at P99 under every check" =
    all(national_p99_checks$ratio_total_winner[national_p99_checks$pollutant == "PM2.5"] < 1),
  "NO2's winner runs long at P99 under every check" =
    all(national_p99_checks$ratio_total_winner[national_p99_checks$pollutant == "NO2"] > 1.25),
  "The lognormal overcounts ozone at the limit under every check, as panel (b) shows" =
    all(national_limit_checks$ratio_total_lognormal[national_limit_checks$pollutant == "Ozone"] > 1.5),
  "Events add PM2.5 limit days the curves miss, as panel (b) shows" =
    pm25_limit_all$n_actual_days > pm25_limit_main$n_actual_days && pm25_limit_all$ratio_total_winner < pm25_limit_main$ratio_total_winner
)

national_tail_figure <- tagged_figure(
  list(
    tail_ratio_panel(p99_national_rows, 1, "All sites, top 1%", "Totals, by curve"),
    tail_ratio_panel(limit_national_rows, 2, "All sites, at the limit", "Totals, by curve"),
    typical_site_panel,
    within_panel
  ),
  tribble(
    ~mark,   ~colour,                           ~label,                                                                                  ~row,
    "point", tail_curve_colours[["Lognormal"]], "Lognormal",                                                                             1,
    "point", tail_curve_colours[["Gamma"]],     "Gamma",                                                                                 1,
    "point", tail_curve_colours[["Weibull"]],   "Weibull",                                                                               1,
    "point", tail_curve_colours[["Normal"]],    "Normal",                                                                                1,
    "tick",  chart_ink[["primary"]],            "(a), (b) Each site's AIC winner",                                                       1,
    "box",   chart_ink[["secondary"]],          "(c) Sites: box holds the middle half, line is the median site, whiskers 10th to 90th percentile", 2
  ),
  source_note = sprintf(
    str_c(
      "Source: EPA AQS daily data, %s to %s, ordinary days unless shown, %s five-year sites. Curves are tested on the days they were fitted ",
      "to. Limits: ozone from 0.071 ppm, PM2.5 from 35.5 \u00b5g/m\u00b3. (c), (d): sites with %d+ days above P99 and %d+ days, counts in brackets."
    ),
    min(study_years), max(study_years), comma(sum(p99_national_rows$n_sites)), min_judged_days, min_tail_days
  )
)

save_figure(national_tail_figure, "3.07_tails.png", 6.75)

group_axis_order <- names(site_group_colours)

warm_curve_lines <- warm_ozone_curves %>%
  select(site_group, value_ppm, starts_with("pct_")) %>%
  pivot_longer(starts_with("pct_"), names_to = "series", names_prefix = "pct_", values_to = "pct_of_days") %>%
  filter(pct_of_days > 0) %>%
  mutate(series = if_else(series == "actual", "Actual", curve_labels[series])) %>%
  mutate(series = factor(series, levels = c(curve_labels, "Actual")))

warm_tail_y_limits <- c(0.03, 40)

warm_limit_shares <- warm_ozone_limit_rows %>%
  select(site_group, pct_days_above)

warm_tail_panel <- function(group_name, panel_number, panel_title) {
  group_lines <- warm_curve_lines %>%
    filter(site_group == group_name)
  group_share <- warm_limit_shares$pct_days_above[warm_limit_shares$site_group == group_name]
  ggplot(group_lines, aes(value_ppm, pct_of_days, colour = series, linewidth = series)) +
    geom_vline(xintercept = limit_rows[["Ozone"]]$first_counted, colour = chart_ink[["axis"]], linewidth = 0.4, linetype = "22") +
    geom_line() +
    scale_colour_manual(values = c(tail_curve_colours, "Actual" = site_group_colours[[group_name]]), guide = "none") +
    scale_linewidth_manual(values = c("Lognormal" = 0.55, "Gamma" = 0.55, "Weibull" = 0.55, "Normal" = 0.55, "Actual" = 0.9), guide = "none") +
    scale_x_continuous(limits = c(0.055, 0.1), breaks = c(0.06, 0.08, 0.1), labels = c("0.06", "0.08", "0.10")) +
    scale_y_log10(
      limits = warm_tail_y_limits,
      breaks = c(0.1, 1, 10),
      labels = c("0.1%", "1%", "10%"),
      oob = oob_keep
    ) +
    coord_cartesian(ylim = warm_tail_y_limits) +
    labs(
      title = panel_label(panel_number, panel_title),
      subtitle = sprintf(
        "%.1f%% of days over the limit, %d sites", group_share, warm_ozone_limit_rows$n_sites[warm_ozone_limit_rows$site_group == group_name]
      ),
      x = "Ozone, ppm",
      y = if (group_name == "Houston Ship Channel") "Share of days above, log scale" else NULL
    ) +
    theme_paper() +
    theme(panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25))
}

range_ratio_rows <- function(set_name) {
  tail_ranges %>%
    filter(site_set == set_name, !is.na(site_group), measure %in% names(curve_labels)) %>%
    mutate(curve = factor(curve_labels[measure], levels = rev(curve_labels))) %>%
    mutate(site_group = factor(site_group, levels = rev(group_axis_order)))
}

tail_range_panel <- function(set_name, panel_number, panel_title, panel_subtitle) {
  ggplot(range_ratio_rows(set_name), aes(estimate, curve, colour = site_group, shape = site_group)) +
    geom_vline(xintercept = 1, colour = chart_ink[["axis"]], linewidth = 0.4) +
    geom_point(position = position_dodge(width = 0.7), size = 1.8) +
    scale_colour_manual(values = site_group_colours, guide = "none") +
    scale_shape_manual(values = site_group_shapes, guide = "none") +
    scale_x_log10(limits = c(0.28, 2.8), breaks = c(0.5, 1, 2), labels = c("0.5", "1", "2")) +
    labs(title = panel_label(panel_number, panel_title), subtitle = panel_subtitle, x = "Expected \u00f7 actual days", y = NULL) +
    theme_paper() +
    theme(panel.grid.major.y = element_blank(), panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25))
}

deer_park_panel_rows <- deer_park_tail_view %>%
  filter(test != "Limit") %>%
  mutate(fit = if_else(site_set == "Ordinary days", "Main fit", "Censored fit")) %>%
  mutate(fit = factor(fit, levels = c("Censored fit", "Main fit"))) %>%
  mutate(ratio = expected_winner / actual_days) %>%
  mutate(test = factor(test, levels = c("P99", "P98")))

deer_park_panel <- ggplot(deer_park_panel_rows, aes(ratio, test, colour = fit)) +
  geom_vline(xintercept = 1, colour = chart_ink[["axis"]], linewidth = 0.4) +
  geom_point(position = position_dodge(width = 0.76), size = 2) +
  geom_text(
    aes(label = sprintf("%s %.2f", if_else(fit == "Main fit", "Main", "Cens."), ratio)),
    position = position_dodge(width = 0.76),
    family = chart_fonts[["mono"]],
    size = chart_sizes[["label"]] / .pt,
    hjust = -0.18
  ) +
  scale_colour_manual(values = c("Main fit" = chart_fills[["accent"]], "Censored fit" = chart_ink[["muted"]]), guide = "none") +
  scale_x_continuous(limits = c(0.8, 3.6), breaks = c(1, 2, 3)) +
  labs(title = panel_label(3, "Deer Park #2 SO2"), subtitle = "Censoring lands closer", x = "Expected \u00f7 actual days", y = NULL) +
  theme_paper() +
  theme(panel.grid.major.y = element_blank(), panel.grid.major.x = element_line(colour = chart_ink[["grid"]], linewidth = 0.25))

warm_group_rows <- tail_ranges %>%
  filter(site_set == "Warm season", !is.na(site_group))

warm_gamma_rows <- warm_group_rows %>%
  filter(measure == "gamma")

warm_lognormal_rows <- warm_group_rows %>%
  filter(measure == "lognormal")

warm_normal_rows <- warm_group_rows %>%
  filter(measure == "normal")

warm_check_rows <- case_tail_summary %>%
  filter(pollutant == "Ozone", test == "Limit", str_starts(site_set, "Warm season"))

warm_top_rows <- case_tail_summary %>%
  filter(pollutant == "Ozone", test == "P99", site_set == "Warm season")

year_gamma_rows <- tail_ranges %>%
  filter(site_set == "Ordinary days", !is.na(site_group), measure == "gamma")

year_gamma_dfw <- year_gamma_rows %>%
  filter(site_group == "Dallas-Fort Worth")

year_curve_tops <- tail_ranges %>%
  filter(site_set == "Ordinary days", !is.na(site_group), measure %in% names(curve_labels)) %>%
  slice_max(estimate, n = 1, by = measure)

deer_park_main_rows <- deer_park_panel_rows %>%
  filter(fit == "Main fit") %>%
  arrange(test)

deer_park_censored_rows <- deer_park_panel_rows %>%
  filter(fit == "Censored fit") %>%
  arrange(test)

stopifnot(
  "Gamma's warm-month range reaches 1 in all three groups" =
    all(warm_gamma_rows$range_low < 1 & warm_gamma_rows$range_high > 1) && nrow(warm_gamma_rows) == 3,
  "Gamma stays within a quarter of the actual days under every warm-month check" =
    all(between(warm_check_rows$ratio_total_gamma, 1, close_tail_ratio)),
  "The lognormal overcounts warm-month ozone in all three groups, with ranges above 1" =
    all(warm_lognormal_rows$range_low > 1) && nrow(warm_lognormal_rows) == 3,
  "The normal undercounts warm-month ozone in all three groups, with ranges below 1" =
    all(warm_normal_rows$range_high < 1) && nrow(warm_normal_rows) == 3,
  "Gamma overshoots the top 1% of warm days in all three groups" = all(warm_top_rows$ratio_total_gamma > close_tail_ratio),
  "Year-round gamma overcounts only in Dallas-Fort Worth, as panel (b) shows" =
    year_gamma_dfw$range_low > 1 && all(year_gamma_rows$range_low[year_gamma_rows$site_group != "Dallas-Fort Worth"] < 1),
  "Dallas-Fort Worth runs highest on every curve year-round, as panel (b) says" = all(year_curve_tops$site_group == "Dallas-Fort Worth"),
  "Censoring lands closer at Deer Park #2 at both percentiles, as panel (c) says" =
    all(abs(log(deer_park_censored_rows$ratio)) < abs(log(deer_park_main_rows$ratio)))
)

warm_tail_figure <- tagged_figure(
  list(
    warm_tail_panel("Houston Ship Channel", 1, "Ship Channel, warm"),
    warm_tail_panel("Houston other", 2, "Houston other, warm"),
    warm_tail_panel("Dallas-Fort Worth", 3, "Dallas-Fort Worth, warm")
  ),
  tribble(
    ~mark,    ~colour,                           ~label,
    "line",   tail_curve_colours[["Lognormal"]], "Lognormal",
    "line",   tail_curve_colours[["Gamma"]],     "Gamma",
    "line",   tail_curve_colours[["Weibull"]],   "Weibull",
    "line",   tail_curve_colours[["Normal"]],    "Normal",
    "thick",  chart_ink[["primary"]],            "Actual days, in the group's colour",
    "dashed", chart_ink[["axis"]],               "Limit"
  ),
  source_note = sprintf(
    str_c(
      "Source: EPA AQS daily data, %s to %s, ordinary days in April to October, case-study ozone sites. Curves are fitted per site ",
      "and pooled by group. Dashed line: 0.071 ppm, the first reading above the limit."
    ),
    min(study_years), max(study_years)
  ),
  ncol = 3
)

case_limit_figure <- tagged_figure(
  list(
    tail_range_panel("Warm season", 1, "At the limit, warm", "Gamma reaches 1"),
    tail_range_panel("Ordinary days", 2, "At the limit, year", "Dallas-Fort Worth runs higher"),
    deer_park_panel
  ),
  tribble(
    ~mark,   ~colour,                                      ~label,              ~shape,                                       ~row,
    "point", site_group_colours[["Houston Ship Channel"]], "Ship Channel",      site_group_shapes[["Houston Ship Channel"]], 1,
    "point", site_group_colours[["Houston other"]],        "Houston other",     site_group_shapes[["Houston other"]],        1,
    "point", site_group_colours[["Dallas-Fort Worth"]],    "Dallas-Fort Worth", site_group_shapes[["Dallas-Fort Worth"]],    1,
    "point", chart_fills[["accent"]],                      "(c) Main fit",      16,                                           1,
    "point", chart_ink[["muted"]],                         "(c) Censored fit",  16,                                           1
  ),
  source_note = sprintf(
    str_c(
      "Source: EPA AQS daily data, %s to %s, ordinary days. (a), (b) Each group's expected days over its actual days. ",
      "(c) Deer Park #2 SO2, readings below the limit censored (%.1f%% of days)."
    ),
    min(study_years), max(study_years), deer_park_censored_row$pct_censored
  ),
  ncol = 3
)

save_figure(warm_tail_figure, "3.08_warm_ozone_tails.png", 2.95)

save_figure(case_limit_figure, "3.09_case_study_limit.png", 3.1)

tail_site_record <- bind_rows(tail_site_rows, deer_park_tail_rows) %>%
  mutate(site_set = factor(site_set, levels = c(tail_summary_set_levels, "Readings below the limit censored"))) %>%
  mutate(test = factor(test, levels = tail_test_levels)) %>%
  select(
    pollutant, site_id, local_site_name, state_name, region, site_group, site_set, test, n_days, cut_value, curve_cut, actual_days,
    expected_lognormal, expected_gamma, expected_weibull, expected_normal, winner, expected_winner, closest_curve, is_judged
  ) %>%
  arrange(pollutant, site_id, site_set, test) %>%
  mutate(actual_days = as.integer(actual_days)) %>%
  mutate(across(where(is.double), \(x) signif(x, 4)))

tail_range_record <- tail_ranges %>%
  mutate(site_set = factor(site_set, levels = names(tail_range_sets))) %>%
  select(
    pollutant, test, site_set, measure, site_group, comparison, estimate, range_low, range_high, reference, is_clear_of_reference,
    range_low_check_seed, range_high_check_seed, seed_shift_share
  ) %>%
  arrange(site_set, measure, site_group, comparison) %>%
  mutate(across(where(is.double), \(x) signif(x, 4)))

stopifnot(
  "Every site record row has a set, a test and a winner" =
    !anyNA(tail_site_record$site_set) && !anyNA(tail_site_record$test) && !anyNA(tail_site_record$winner),
  "Three tests for each site and set" = all(count(tail_site_record, pollutant, site_id, site_set)$n == length(tail_test_levels)),
  "Every range row names a group or a comparison" = all(is.na(tail_range_record$site_group) != is.na(tail_range_record$comparison)),
  "Every summary row names its check and test" = !anyNA(tail_summary$site_set) && !anyNA(tail_summary$test)
)

tail_records <- list(
  distribution_tail_sites = tail_site_record,
  distribution_tail_summary = tail_summary %>%
    mutate(n_actual_days = as.integer(n_actual_days)) %>%
    mutate(across(where(is.double), \(x) signif(x, 4))),
  distribution_tail_ranges = tail_range_record,
  distribution_tail_curves = warm_ozone_curves %>%
    mutate(n_actual_days = as.integer(n_actual_days)) %>%
    mutate(across(where(is.double), \(x) signif(x, 4)))
)

save_records(tail_records, records_dir)

tail_curve_descriptions <- c(
  "lognormal" = "the lognormal curve",
  "gamma" = "the gamma curve",
  "weibull" = "the Weibull curve",
  "normal" = "the normal curve",
  "winner" = "each site's AIC winner"
)

tail_summary_curve_rows <- bind_rows(lapply(names(tail_curve_descriptions), \(curve) {
  tibble(
    table = "distribution_tail_summary",
    column = str_c(c("total_expected_", "ratio_total_", "median_ratio_", "pct_within_25_"), curve),
    description = str_c(
      c(
        "Days expected above the level, summed across sites, from ",
        "Total expected days / actual days, from ",
        "Median across judged sites of expected / actual days, from ",
        "% of judged sites with expected / actual between 0.8 and 1.25, from "
      ),
      tail_curve_descriptions[[curve]]
    )
  )
}))

tail_dictionary <- bind_rows(
  tribble(
    ~table,                     ~column,            ~description,
    "distribution_tail_sites", "pollutant",         "PM2.5, Ozone, NO2, SO2 or CO",
    "distribution_tail_sites", "site_id",           "AQS site ID; five-year sites outside the near-zero rule",
    "distribution_tail_sites", "local_site_name",   "Site name given by the reporting agency; can be NA",
    "distribution_tail_sites", "state_name",        "State or territory name",
    "distribution_tail_sites", "region",            "West (Census West region) or East (every other state or territory)",
    "distribution_tail_sites", "site_group",        "Case-study group; NA outside the case study",
    "distribution_tail_sites", "site_set",          "Ordinary days, All days, Warm season (ozone) or Deer Park #2's censored fit",
    "distribution_tail_sites", "test",              "Limit (the short-term standard), P98 or P99 (the site's own percentile)",
    "distribution_tail_sites", "n_days",            "Days measured in this set",
    "distribution_tail_sites", "cut_value",         "Limit: lowest reading above it after 2a's rounding. P98, P99: the site's percentile",
    "distribution_tail_sites", "curve_cut",         "Where curves are read: half a step below a limit, or midway between days beside a percentile",
    "distribution_tail_sites", "actual_days",       "Days above the level",
    "distribution_tail_sites", "expected_lognormal", "n_days x the lognormal curve's share above curve_cut",
    "distribution_tail_sites", "expected_gamma",    "n_days x the gamma curve's share above curve_cut",
    "distribution_tail_sites", "expected_weibull",  "n_days x the Weibull curve's share above curve_cut",
    "distribution_tail_sites", "expected_normal",   "n_days x the normal curve's share above curve_cut; NA in the censored fit",
    "distribution_tail_sites", "winner",            "The lowest-AIC curve of the three in this set, as in distribution_fits",
    "distribution_tail_sites", "expected_winner",   "Expected days from the site's winner",
    "distribution_tail_sites", "closest_curve",     "The curve of the three closest to actual_days, on a log scale; NA with no actual days",
    "distribution_tail_sites", "is_judged",         "TRUE when the site has 10+ actual days and 200+ days, so its own ratio is read",
    "distribution_tail_summary", "scope",           "National (all sites outside the near-zero rule) or Case study (per group)",
    "distribution_tail_summary", "pollutant",       "PM2.5, Ozone, NO2, SO2 or CO; CO is national only",
    "distribution_tail_summary", "site_group",      "Case-study group; NA in national rows",
    "distribution_tail_summary", "site_set",        "Ordinary days (main run) or a check; a check that changes no days has no row",
    "distribution_tail_summary", "test",            "Limit, P98 or P99",
    "distribution_tail_summary", "n_sites",         "Sites in the row",
    "distribution_tail_summary", "n_site_days",     "Site-days in the row",
    "distribution_tail_summary", "n_actual_days",   "Site-days above the level",
    "distribution_tail_summary", "pct_days_above",  "n_actual_days / n_site_days x 100",
    "distribution_tail_summary", "n_sites_with_actual_days", "Sites with at least one day above the level",
    "distribution_tail_summary", "pct_actual_in_top_sites", "% of actual days held by the 10 busiest sites; NA with 10 sites or fewer",
    "distribution_tail_summary", "n_judged_sites",  "Sites with 10+ actual days and 200+ days",
    "distribution_tail_summary", "q1_ratio_winner", "25th percentile across judged sites of expected / actual days, from the winner",
    "distribution_tail_summary", "q3_ratio_winner", "75th percentile across judged sites of expected / actual days, from the winner",
    "distribution_tail_summary", "pct_closest_lognormal", "% of judged sites where the lognormal is the closest of the three",
    "distribution_tail_summary", "pct_closest_gamma", "% of judged sites where the gamma curve is the closest of the three",
    "distribution_tail_summary", "pct_closest_weibull", "% of judged sites where the Weibull curve is the closest of the three",
    "distribution_tail_summary", "pct_winner_closest", "% of judged sites where the AIC winner is also the closest of the three"
  ),
  tail_summary_curve_rows,
  tribble(
    ~table,                      ~column,                 ~description,
    "distribution_tail_ranges", "pollutant",              "Ozone: the ranges cover case-study ozone only",
    "distribution_tail_ranges", "test",                   "Limit: days from 0.071 ppm",
    "distribution_tail_ranges", "site_set",               "Warm season or Ordinary days (year-round)",
    "distribution_tail_ranges", "measure",                "Days above the limit, %, or a curve's expected / actual days (winner: each site's own)",
    "distribution_tail_ranges", "site_group",             "Case-study group; NA in comparison rows",
    "distribution_tail_ranges", "comparison",             "Which group is subtracted from which; NA in group rows",
    "distribution_tail_ranges", "estimate",               "The measure, or the gap in the measure between the two groups",
    "distribution_tail_ranges", "range_low",              "2.5th percentile across 2,000 same-date two-week block resamples, curves refitted",
    "distribution_tail_ranges", "range_high",             "97.5th percentile across those resamples",
    "distribution_tail_ranges", "reference",              "1 for a group's ratio, 0 for a gap; NA for a group's share of days",
    "distribution_tail_ranges", "is_clear_of_reference",  "TRUE when the range leaves out the reference; NA without one",
    "distribution_tail_ranges", "range_low_check_seed",   "range_low under the second seed",
    "distribution_tail_ranges", "range_high_check_seed",  "range_high under the second seed",
    "distribution_tail_ranges", "seed_shift_share",       "Largest move of either end between seeds, as a share of the range's width",
    "distribution_tail_curves", "site_group",             "Case-study group",
    "distribution_tail_curves", "value_ppm",              "Warm-month ozone value, in ppm",
    "distribution_tail_curves", "n_site_days",            "Warm-month ordinary site-days in the group",
    "distribution_tail_curves", "n_actual_days",          "Site-days at or above value_ppm",
    "distribution_tail_curves", "pct_actual",             "n_actual_days / n_site_days x 100",
    "distribution_tail_curves", "pct_lognormal",          "% of site-days each site's lognormal puts above value_ppm less half a step, pooled",
    "distribution_tail_curves", "pct_gamma",              "% of site-days each site's gamma curve puts above value_ppm less half a step, pooled",
    "distribution_tail_curves", "pct_weibull",            "% of site-days each site's Weibull curve puts above value_ppm less half a step, pooled",
    "distribution_tail_curves", "pct_normal",             "% of site-days each site's normal curve puts above value_ppm less half a step, pooled"
  )
)

tail_dictionary <- document_tables(tail_records, tail_dictionary)

replace_own_rows(tail_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

national_tail_main %>%
  select(pollutant, test, n_sites, n_actual_days, starts_with("ratio_total_"), n_judged_sites, median_ratio_winner, pct_within_25_winner) %>%
  mutate(across(where(is.double), \(x) signif(x, 3))) %>%
  print(n = Inf, width = Inf)

rm(tail_source_days, tail_ordinary_days, case_warm_ozone_days, warm_ozone_tail_check_days, case_tail_check_days, tail_range_sets, warm_ozone_pieces)
invisible(gc())



# 6. OZONE DESIGN VALUE ----
# appendix U 3(e): design value = each year's 4th-highest daily max 8-hr ozone, averaged over 3 years and
# truncated to 3 decimals. 4(b): valid with valid days on 90% of the ozone season on avg and 75% each year,
# and anything over 0.070 ppm is always valid. worked for houston aldine, then every case-study ozone site, vs EPA
design_value_file_md5 <- unname(tools::md5sum(design_value_path))

stopifnot("EPA's design value file is the one saved on 2026-11-12" = tolower(design_value_file_md5) == design_value_md5)

read_design_value_sheet <- function(sheet, header_row) {
  readxl::read_excel(design_value_path, sheet = sheet, skip = header_row - 1, col_types = "text") %>%
    clean_names()
}

epa_site_status <- read_design_value_sheet("Table5. Site Status", 4)

epa_site_trends <- read_design_value_sheet("Table6. Site Trends", 4)

epa_monitors <- read_design_value_sheet("Appendix. Monitor Information", 2)

# case-study ozone on every day incl. events, since EPA only drops the event days it agreed to exclude
design_value_days <- case_fit_days %>%
  filter(pollutant == "Ozone") %>%
  mutate(site_group = as.character(site_group)) %>%
  mutate(epa_site_id = str_remove_all(site_id, "-")) %>%
  select(site_group, site_id, epa_site_id, local_site_name, date_local, year, value, event_class)

design_value_seasons <- epa_monitors %>%
  filter(aqs_parameter_code == "44201", aqs_site_id %in% design_value_days$epa_site_id) %>%
  transmute(
    epa_site_id = aqs_site_id,
    season_begin = monitoring_season_begin_date,
    season_end = monitoring_season_end_date,
    naaqs_exclusion = coalesce(naaqs_exclusion_begin_date, ""),
    combination_site = coalesce(combination_site_id, "")
  )

design_value_site_seasons <- design_value_days %>%
  distinct(site_group, site_id, epa_site_id) %>%
  left_join(design_value_seasons, by = "epa_site_id", relationship = "one-to-one")

stopifnot(
  "Every case-study ozone site has one ozone monitor in EPA's file" =
    nrow(design_value_site_seasons) == 22 && !anyNA(design_value_site_seasons$season_begin),
  "Houston sites run all year and Dallas-Fort Worth sites from March to November" =
    all(with(design_value_site_seasons, if_else(
      site_group == "Dallas-Fort Worth",
      season_begin == "03-01" & season_end == "11-30",
      season_begin == "01-01" & season_end == "12-31"
    ))),
  "No case-study monitor has a NAAQS exclusion or a combined site in EPA's file" =
    all(design_value_site_seasons$naaqs_exclusion == "" & design_value_site_seasons$combination_site == "")
)

# one row per site and year: the season, valid days inside it, and the 4 highest days. a valid day here = a day
# 1a kept, which needs 13 of its 17 8-hr periods. appendix U 3(d) also keeps a shorter day over 0.070 ppm, which 1a
# drops, so a few high days EPA counts can be missing here
design_value_site_years <- design_value_days %>%
  inner_join(select(design_value_site_seasons, epa_site_id, season_begin, season_end), by = "epa_site_id", relationship = "many-to-one") %>%
  mutate(season_start = ymd(str_c(year, "-", season_begin))) %>%
  mutate(season_stop = ymd(str_c(year, "-", season_end))) %>%
  mutate(is_in_season = between(date_local, season_start, season_stop)) %>%
  arrange(site_id, year, desc(value), date_local) %>%
  summarise(
    season_days = as.integer(first(season_stop) - first(season_start)) + 1L,
    valid_days = sum(is_in_season),
    days_outside_season = sum(!is_in_season),
    event_days = sum(event_class != "None"),
    highest_ppm = value[1],
    highest_date = date_local[1],
    second_ppm = value[2],
    second_date = date_local[2],
    third_ppm = value[3],
    third_date = date_local[3],
    fourth_ppm = value[4],
    fourth_date = date_local[4],
    top_four_in_season = all(is_in_season[1:4]),
    .by = c(site_group, site_id, epa_site_id, local_site_name, year)
  ) %>%
  mutate(completeness_pct = 100 * valid_days / season_days)

stopifnot(
  "Five years for each of the 22 sites" = nrow(design_value_site_years) == 22 * length(study_years),
  "Every top-four day falls inside its ozone season, so the season leaves the 4th-highest day as it is" =
    all(design_value_site_years$top_four_in_season)
)

epa_site_years <- epa_site_status %>%
  filter(aqs_site_id %in% design_value_days$epa_site_id) %>%
  select(epa_site_id = aqs_site_id, matches("^x20\\d\\d_data_completeness"), matches("^x20\\d\\d_4th_highest")) %>%
  pivot_longer(-epa_site_id, names_to = c("year", ".value"), names_pattern = "^x(\\d{4})_(data_completeness|4th_highest).*$") %>%
  transmute(epa_site_id, year = as.numeric(year), epa_completeness_pct = as.numeric(data_completeness), epa_fourth_ppm = as.numeric(`4th_highest`))

design_value_site_years <- design_value_site_years %>%
  left_join(epa_site_years, by = c("epa_site_id", "year"), relationship = "one-to-one") %>%
  mutate(completeness_matches_epa = round_half_up(completeness_pct) == epa_completeness_pct) %>%
  mutate(fourth_matches_epa = abs(fourth_ppm - epa_fourth_ppm) < 1e-9)

design_values <- design_value_site_years %>%
  cross_join(design_value_windows) %>%
  filter(between(year, first_year, last_year)) %>%
  summarise(
    n_years = n(),
    mean_fourth_ppm = mean(fourth_ppm),
    mean_completeness_pct = mean(completeness_pct),
    lowest_completeness_pct = min(completeness_pct),
    .by = c(site_group, site_id, epa_site_id, local_site_name, first_year, last_year)
  ) %>%
  mutate(design_value_ppm = truncate_to(mean_fourth_ppm, 3)) %>%
  mutate(is_complete = mean_completeness_pct >= design_value_completeness[["average"]]) %>%
  mutate(is_complete = is_complete & lowest_completeness_pct >= design_value_completeness[["each_year"]]) %>%
  mutate(is_valid = is_complete | design_value_ppm > ozone_standard_ppm) %>%
  mutate(is_above_standard = design_value_ppm > ozone_standard_ppm)

epa_design_values <- epa_site_trends %>%
  filter(aqs_site_id %in% design_value_days$epa_site_id) %>%
  select(epa_site_id = aqs_site_id, matches("^x20\\d\\d_20\\d\\d_design_value")) %>%
  pivot_longer(-epa_site_id, names_to = "window", values_to = "epa_design_value_ppm") %>%
  transmute(
    epa_site_id,
    first_year = as.numeric(str_extract(window, "(?<=^x)\\d{4}")),
    epa_design_value_ppm = as.numeric(epa_design_value_ppm)
  ) %>%
  filter(first_year %in% design_value_windows$first_year)

epa_validity <- epa_site_status %>%
  filter(aqs_site_id %in% design_value_days$epa_site_id) %>%
  select(epa_site_id = aqs_site_id, epa_valid_value = matches("^valid_\\d{4}_\\d{4}_design_value")) %>%
  transmute(epa_site_id, first_year = max(design_value_windows$first_year), epa_is_valid = !is.na(as.numeric(epa_valid_value)))

design_values <- design_values %>%
  left_join(epa_design_values, by = c("epa_site_id", "first_year"), relationship = "one-to-one") %>%
  left_join(epa_validity, by = c("epa_site_id", "first_year"), relationship = "one-to-one") %>%
  mutate(gap_to_epa_ppm = design_value_ppm - epa_design_value_ppm) %>%
  mutate(matches_epa = abs(gap_to_epa_ppm) < 1e-9)

aldine_years <- design_value_site_years %>%
  filter(site_id == aldine_id, year >= max(design_value_windows$first_year))

aldine_value <- design_values %>%
  filter(site_id == aldine_id, first_year == max(design_value_windows$first_year))

cat("\nHouston Aldine, 2023 to 2025, worked through Appendix U\n")
aldine_years %>%
  select(year, season_days, valid_days, completeness_pct, epa_completeness_pct, highest_ppm, fourth_ppm, fourth_date, epa_fourth_ppm) %>%
  as.data.frame() %>%
  print()
cat(sprintf(
  "(%.3f + %.3f + %.3f) / 3 = %.5f ppm, truncated to %.3f ppm; EPA %.3f ppm. Completeness %.1f%% on average, lowest %.1f%%.\n",
  aldine_years$fourth_ppm[1], aldine_years$fourth_ppm[2], aldine_years$fourth_ppm[3], aldine_value$mean_fourth_ppm, aldine_value$design_value_ppm,
  aldine_value$epa_design_value_ppm, aldine_value$mean_completeness_pct, aldine_value$lowest_completeness_pct
))

design_value_matches <- design_values %>%
  summarise(
    n_sites = n(),
    n_matching_epa = sum(matches_epa),
    n_above_standard = sum(is_above_standard),
    n_valid = sum(is_valid),
    lowest_ppm = min(design_value_ppm),
    highest_ppm = max(design_value_ppm),
    .by = c(first_year, last_year)
  )

design_value_groups <- design_values %>%
  summarise(
    n_sites = n(),
    n_above_standard = sum(is_above_standard),
    median_ppm = median(design_value_ppm),
    highest_ppm = max(design_value_ppm),
    .by = c(first_year, last_year, site_group)
  )

design_value_misses <- design_values %>%
  filter(!matches_epa)

print(as.data.frame(design_value_matches))

print(as.data.frame(design_value_groups))

print(as.data.frame(select(design_value_misses, local_site_name, first_year, last_year, design_value_ppm, epa_design_value_ppm, gap_to_epa_ppm)))

# misses vs EPA fit the days 1a drops: it keeps a day with 18 of 24 hourly periods, while appendix U
# 3(d) keeps a day with 13 of its 17 daytime periods, or any day over 0.070 ppm. so EPA can count a few more days
checked_site_years <- design_value_site_years %>%
  filter(!is.na(epa_fourth_ppm))

completeness_gaps <- checked_site_years$epa_completeness_pct - round_half_up(checked_site_years$completeness_pct)

latest_window <- max(design_value_windows$first_year)

latest_values <- design_values %>%
  filter(first_year == latest_window)

stopifnot(
  "Aldine's completeness and 4th-highest day match EPA in 2023, 2024 and 2025" =
    nrow(aldine_years) == 3 && all(aldine_years$completeness_matches_epa) && all(aldine_years$fourth_matches_epa),
  "Aldine's 2023-2025 design value is 0.082 ppm, valid and above the standard, as in EPA's file" =
    isTRUE(all.equal(aldine_value$design_value_ppm, 0.082)) && aldine_value$matches_epa && aldine_value$is_valid && aldine_value$is_above_standard,
  "Design values match EPA at 20, 20 and 21 of 22 sites for 2021-2023, 2022-2024 and 2023-2025" =
    identical(design_value_matches$n_matching_epa, c(20L, 20L, 21L)),
  "Every miss is 0.001 ppm below EPA, as missing high days would make it" =
    nrow(design_value_misses) == 5 && all(abs(design_value_misses$gap_to_epa_ppm + 0.001) < 1e-9),
  "No miss changes whether a site is above the standard" =
    all((design_value_misses$design_value_ppm > ozone_standard_ppm) == (design_value_misses$epa_design_value_ppm > ozone_standard_ppm)),
  "The 4th-highest day matches EPA at 64 of 66 site-years, and EPA's is higher at the other two" =
    sum(checked_site_years$fourth_matches_epa) == 64 && all(checked_site_years$epa_fourth_ppm >= checked_site_years$fourth_ppm - 1e-9),
  "Completeness matches EPA or sits 1 point below it at every site-year, never above" =
    length(completeness_gaps) == 66 && all(completeness_gaps %in% c(0, 1)),
  "Validity matches EPA for 2023-2025 at every site" = all(latest_values$is_valid == latest_values$epa_is_valid),
  "All 22 case-study ozone sites are above the standard for 2023-2025" = all(latest_values$is_above_standard) && nrow(latest_values) == 22
)

cat(
  "Completeness equal to EPA at", sum(completeness_gaps == 0), "of", length(completeness_gaps), "site-years and 1 point below at",
  sum(completeness_gaps == 1), "\n"
)

design_value_year_record <- design_value_site_years %>%
  mutate(site_group = factor(site_group, levels = names(site_group_colours))) %>%
  select(
    site_group, site_id, local_site_name, year, season_days, valid_days, completeness_pct, epa_completeness_pct, completeness_matches_epa,
    days_outside_season, event_days, highest_ppm, highest_date, second_ppm, second_date, third_ppm, third_date, fourth_ppm, fourth_date,
    epa_fourth_ppm, fourth_matches_epa
  ) %>%
  arrange(site_group, site_id, year) %>%
  mutate(completeness_pct = round(completeness_pct, 2))

design_value_record <- design_values %>%
  mutate(site_group = factor(site_group, levels = names(site_group_colours))) %>%
  select(
    site_group, site_id, local_site_name, first_year, last_year, mean_fourth_ppm, design_value_ppm, mean_completeness_pct, lowest_completeness_pct,
    is_complete, is_valid, is_above_standard, epa_design_value_ppm, epa_is_valid, gap_to_epa_ppm, matches_epa
  ) %>%
  arrange(site_group, site_id, first_year) %>%
  mutate(mean_fourth_ppm = round(mean_fourth_ppm, 5)) %>%
  mutate(across(c(mean_completeness_pct, lowest_completeness_pct), \(x) round(x, 2))) %>%
  mutate(gap_to_epa_ppm = round(gap_to_epa_ppm, 3))

stopifnot(
  "One year row per site and year" = !anyDuplicated(select(design_value_year_record, site_id, year)) && nrow(design_value_year_record) == 110,
  "One window row per site and window" = !anyDuplicated(select(design_value_record, site_id, first_year)) && nrow(design_value_record) == 66,
  "EPA's numbers fill the years and windows its file covers" =
    sum(!is.na(design_value_year_record$epa_fourth_ppm)) == 66 && !anyNA(design_value_record$epa_design_value_ppm)
)

design_value_records <- list(
  distribution_design_value_years = design_value_year_record,
  distribution_design_values = design_value_record
)

save_records(design_value_records, records_dir)

design_value_dictionary <- tribble(
  ~table,                            ~column,                    ~description,
  "distribution_design_value_years", "site_group",               "Case-study group",
  "distribution_design_value_years", "site_id",                  "AQS site ID of a five-year case-study ozone site",
  "distribution_design_value_years", "local_site_name",          "Site name given by the reporting agency",
  "distribution_design_value_years", "year",                     "Calendar year",
  "distribution_design_value_years", "season_days",              "Ozone-season days in EPA's file: all year in Houston, Mar to Nov in DFW",
  "distribution_design_value_years", "valid_days",               "Days in the season with a daily maximum 8-hour value after 1a's cleaning",
  "distribution_design_value_years", "completeness_pct",         "valid_days / season_days x 100 (Appendix U 4(b))",
  "distribution_design_value_years", "epa_completeness_pct",     "EPA's completeness for the year, whole percent; NA before 2023",
  "distribution_design_value_years", "completeness_matches_epa", "TRUE when completeness_pct rounded half up equals EPA's; NA before 2023",
  "distribution_design_value_years", "days_outside_season",      "Days with data outside the season; in the top four days, out of completeness",
  "distribution_design_value_years", "event_days",               "Days in an events.csv window, kept as EPA keeps them",
  "distribution_design_value_years", "highest_ppm",              "Highest daily maximum 8-hour ozone of the year, ppm",
  "distribution_design_value_years", "highest_date",             "Date of highest_ppm; the earliest on a tie",
  "distribution_design_value_years", "second_ppm",               "Second-highest daily maximum 8-hour ozone, ppm",
  "distribution_design_value_years", "second_date",              "Date of second_ppm",
  "distribution_design_value_years", "third_ppm",                "Third-highest daily maximum 8-hour ozone, ppm",
  "distribution_design_value_years", "third_date",               "Date of third_ppm",
  "distribution_design_value_years", "fourth_ppm",               "Fourth-highest daily maximum 8-hour ozone (Appendix U 3(e)), ppm",
  "distribution_design_value_years", "fourth_date",              "Date of fourth_ppm",
  "distribution_design_value_years", "epa_fourth_ppm",           "EPA's fourth-highest value for the year, ppm; NA before 2023",
  "distribution_design_value_years", "fourth_matches_epa",       "TRUE when fourth_ppm equals EPA's; NA before 2023",
  "distribution_design_values",      "site_group",               "Case-study group",
  "distribution_design_values",      "site_id",                  "AQS site ID of a five-year case-study ozone site",
  "distribution_design_values",      "local_site_name",          "Site name given by the reporting agency",
  "distribution_design_values",      "first_year",               "First year of the three-year window",
  "distribution_design_values",      "last_year",                "Last year of the three-year window",
  "distribution_design_values",      "mean_fourth_ppm",          "Mean of the three yearly fourth-highest values, before truncation, ppm",
  "distribution_design_values",      "design_value_ppm",         "mean_fourth_ppm truncated to three decimals (Appendix U 3(e)), ppm",
  "distribution_design_values",      "mean_completeness_pct",    "Mean of the three yearly completeness_pct values",
  "distribution_design_values",      "lowest_completeness_pct",  "Lowest yearly completeness_pct in the window",
  "distribution_design_values",      "is_complete",              "TRUE with a mean of 90% or more and every year at 75% or more (Appendix U 4(b))",
  "distribution_design_values",      "is_valid",                 "TRUE when is_complete or the design value is above 0.070 ppm (Appendix U 4(b))",
  "distribution_design_values",      "is_above_standard",        "TRUE above 0.070 ppm: the site misses the standard (Appendix U 4(a))",
  "distribution_design_values",      "epa_design_value_ppm",     "EPA's design value for the window from its 2023-2025 file, ppm",
  "distribution_design_values",      "epa_is_valid",             "TRUE when EPA lists the value as valid; NA before 2023-2025",
  "distribution_design_values",      "gap_to_epa_ppm",           "design_value_ppm - epa_design_value_ppm",
  "distribution_design_values",      "matches_epa",              "TRUE when design_value_ppm equals EPA's"
)

design_value_dictionary <- document_tables(design_value_records, design_value_dictionary)

replace_own_rows(design_value_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(epa_site_status, epa_site_trends, epa_monitors, design_value_days)
invisible(gc())



# 7. VALIDATE AND SAVE ----
# last step: each figure claim from sections 3 to 5 under every check (fig 3.10), one table of headline
# numbers for the report read from the saved records, and a final observed / expected / passed table
phase3_records <- c(inventory_records, summary_records, shape_records, fit_records, tail_records, design_value_records)

stopifnot("Fifteen Phase 3 records before this section, each named once" = length(phase3_records) == 15 && !anyDuplicated(names(phase3_records)))

# findings tested under every check. each is a claim a phase 3 figure makes, a check that wasn't run for a finding or
# that changes nothing it uses has no row and doesn't apply
robustness_findings <- tribble(
  ~finding_id, ~scope,        ~figure, ~finding,
  "R01",       "National",    "3.1",   "PM2.5, SO2 and CO sit closer to a lognormal",
  "R02",       "National",    "3.2",   "Ozone sits closer to a normal curve",
  "R03",       "National",    "3.5",   "A lognormal wins the most SO2 and CO sites",
  "R04",       "National",    "3.5",   "Ozone leans normal once it may compete",
  "R05",       "National",    "3.7",   "PM2.5's winner runs short at the top 1%",
  "R06",       "National",    "3.7",   "NO2's winner runs long at the top 1%",
  "R07",       "National",    "3.7",   "Under half of sites land within 25%",
  "R08",       "National",    "3.7",   "The lognormal overcounts ozone at the limit",
  "R09",       "Case study",  "3.6",   "Warm ozone swings wider in Houston",
  "R10",       "Case study",  "3.9",   "Gamma lands within 25% at the warm limit",
  "R11",       "Case study",  "3.9",   "Lognormal runs high, normal low, warm limit",
  "R12",       "Case study",  "3.8",   "Gamma overshoots the warm top 1%"
)

national_check_labels <- c(
  "Ordinary days" = "Main",
  "All days" = "All days",
  "Warm season" = "Warm season",
  "Cool season" = "Cool season",
  "Without values at or below zero" = "Without values at or below zero",
  "Year-round sites" = "Year-round ozone sites",
  "Sites on daily sampling" = "PM2.5 sites on daily sampling",
  "Sites without a method change" = "Sites with and without a method change",
  "Sites with a method change" = "Sites with and without a method change",
  "Western PM2.5 sites" = "Western and eastern PM2.5 sites",
  "Eastern PM2.5 sites" = "Western and eastern PM2.5 sites",
  "SO2 sites with a lower limit" = "SO2 sites with a lower limit",
  "Without the half-step" = "Without the half-step"
)

case_check_labels <- c(
  "Main" = "Main",
  "All days" = "All days",
  "Without values at or below zero" = "Without values at or below zero",
  "Without readings below the limit" = "Without readings below the limit",
  "Without the transition band" = "Without the transition band",
  "Without days after method changes" = "Without days after method changes",
  "Without Deer Park #2 after its move" = "Without Deer Park #2 after its move",
  "Without each group's busiest site" = "Without each group's busiest site",
  "Second seed" = "Second seed"
)

check_plot_labels <- c(
  "Main" = "Main",
  "All days" = "All\ndays",
  "Warm season" = "Warm\nmonths",
  "Cool season" = "Cool\nmonths",
  "Without values at or below zero" = "Values\nabove 0",
  "Year-round ozone sites" = "Year-\nround\nozone",
  "PM2.5 sites on daily sampling" = "Daily\nPM2.5",
  "Sites with and without a method change" = "Method\nchange\nsplit",
  "Western and eastern PM2.5 sites" = "PM2.5\nwest and\neast",
  "SO2 sites with a lower limit" = "Lower-\nlimit\nSO2",
  "Without the half-step" = "No half-\nstep",
  "Without readings below the limit" = "Readings\nabove\nlimit",
  "Without the transition band" = "No\ntransition\nband",
  "Without days after method changes" = "No post-\nchange\ndays",
  "Without Deer Park #2 after its move" = "No Deer\nPark #2\nmove",
  "Without each group's busiest site" = "No\nbusiest\nsite",
  "Second seed" = "Second\nseed"
)

shape_national <- phase3_records$distribution_shape_summary %>%
  filter(scope == "National")

fit_national <- phase3_records$distribution_fit_summary %>%
  filter(scope == "National")

tail_national <- phase3_records$distribution_tail_summary %>%
  filter(scope == "National")

national_robustness <- bind_rows(
  shape_national %>%
    filter(pollutant %in% c("PM2.5", "SO2", "CO")) %>%
    summarise(holds = all(pct_sites_lognormal_closer >= 75 & pct_sites_log_nearer_symmetry >= 75), .by = site_set) %>%
    mutate(finding_id = "R01"),
  shape_national %>%
    filter(pollutant == "Ozone") %>%
    summarise(holds = all(pct_sites_lognormal_closer <= 25), .by = site_set) %>%
    mutate(finding_id = "R02"),
  fit_national %>%
    filter(pollutant %in% c("SO2", "CO")) %>%
    summarise(holds = all(wins_lognormal > wins_gamma & wins_lognormal > wins_weibull), .by = site_set) %>%
    mutate(finding_id = "R03"),
  fit_national %>%
    filter(pollutant == "Ozone") %>%
    summarise(
      holds = all(wins_with_normal_normal > pmax(wins_with_normal_lognormal, wins_with_normal_gamma, wins_with_normal_weibull)),
      .by = site_set
    ) %>%
    mutate(finding_id = "R04"),
  tail_national %>%
    filter(pollutant == "PM2.5", test == "P99") %>%
    summarise(holds = all(ratio_total_winner < 1), .by = site_set) %>%
    mutate(finding_id = "R05"),
  tail_national %>%
    filter(pollutant == "NO2", test == "P99") %>%
    summarise(holds = all(ratio_total_winner > close_tail_ratio), .by = site_set) %>%
    mutate(finding_id = "R06"),
  tail_national %>%
    filter(test == "P99") %>%
    summarise(holds = all(pct_within_25_winner < 50), .by = site_set) %>%
    mutate(finding_id = "R07"),
  tail_national %>%
    filter(pollutant == "Ozone", test == "Limit") %>%
    summarise(holds = all(ratio_total_lognormal > 1.5), .by = site_set) %>%
    mutate(finding_id = "R08")
) %>%
  mutate(site_set = as.character(site_set)) %>%
  mutate(check = national_check_labels[site_set]) %>%
  summarise(holds = all(holds), .by = c(finding_id, check))

warm_check_names <- c(
  "Warm season" = "Main",
  "Warm season, all days" = "All days",
  "Warm season, without readings below the limit" = "Without readings below the limit",
  "Warm season, without the transition band" = "Without the transition band",
  "Warm season, without days after method changes" = "Without days after method changes",
  "Warm season, without Deer Park #2 after its move" = "Without Deer Park #2 after its move",
  "Warm season, without each group's busiest site" = "Without each group's busiest site"
)

warm_tail_sets <- phase3_records$distribution_tail_summary %>%
  filter(scope == "Case study", pollutant == "Ozone", as.character(site_set) %in% names(warm_check_names)) %>%
  mutate(check_set = warm_check_names[as.character(site_set)])

warm_spread_seed <- phase3_records$distribution_fit_checks %>%
  filter(check == "Group spread", version == "Warm season", pollutant == "Ozone", str_ends(comparison, "Dallas-Fort Worth"))

warm_limit_ranges <- phase3_records$distribution_tail_ranges %>%
  filter(site_set == "Warm season", !is.na(site_group))

warm_lognormal_seed <- warm_limit_ranges %>%
  filter(measure == "lognormal")

warm_normal_seed <- warm_limit_ranges %>%
  filter(measure == "normal")

case_robustness <- bind_rows(
  warm_ozone_check_gaps %>%
    filter(site_group != "Dallas-Fort Worth") %>%
    mutate(check_set = if_else(site_set == "Ordinary days", "Main", site_set)) %>%
    summarise(holds = all(gap_to_dfw > 0.05), .by = check_set) %>%
    mutate(finding_id = "R09"),
  tibble(finding_id = "R09", check_set = "Second seed", holds = all(warm_spread_seed$gap_low_check_seed > 0) && nrow(warm_spread_seed) == 2),
  warm_tail_sets %>%
    filter(test == "Limit") %>%
    summarise(holds = all(between(ratio_total_gamma, 1, close_tail_ratio)), .by = check_set) %>%
    mutate(finding_id = "R10"),
  warm_limit_ranges %>%
    filter(measure == "gamma") %>%
    summarise(holds = all(range_low_check_seed < 1 & range_high_check_seed > 1) && n() == 3) %>%
    mutate(finding_id = "R10", check_set = "Second seed"),
  warm_tail_sets %>%
    filter(test == "Limit") %>%
    summarise(holds = all(ratio_total_lognormal > 1 & ratio_total_normal < 1), .by = check_set) %>%
    mutate(finding_id = "R11"),
  tibble(
    finding_id = "R11",
    check_set = "Second seed",
    holds = all(warm_lognormal_seed$range_low_check_seed > 1) && all(warm_normal_seed$range_high_check_seed < 1)
  ),
  warm_tail_sets %>%
    filter(test == "P99") %>%
    summarise(holds = all(ratio_total_gamma > close_tail_ratio), .by = check_set) %>%
    mutate(finding_id = "R12")
) %>%
  mutate(check = case_check_labels[check_set]) %>%
  select(finding_id, check, holds)

robustness_columns <- unique(c(national_check_labels, case_check_labels))

robustness_grid <- robustness_findings %>%
  cross_join(tibble(check = robustness_columns)) %>%
  filter(if_else(scope == "National", check %in% national_check_labels, check %in% case_check_labels))

robustness <- bind_rows(national_robustness, case_robustness) %>%
  right_join(robustness_grid, by = c("finding_id", "check"), relationship = "one-to-one") %>%
  mutate(result = case_when(is.na(holds) ~ "Does not apply", holds ~ "Holds", .default = "Fails")) %>%
  mutate(check = factor(check, levels = robustness_columns)) %>%
  select(finding_id, scope, figure, finding, check, result) %>%
  arrange(finding_id, check)

robustness %>%
  count(scope, result) %>%
  print()

n_failing <- sum(robustness$result == "Fails")

tested_beyond_main <- robustness %>%
  filter(result != "Does not apply", check != "Main") %>%
  count(finding_id)

stopifnot(
  "Every finding is tested in its main set" = all(robustness$result[robustness$check == "Main"] == "Holds"),
  "Every finding holds under every check that applies" = n_failing == 0,
  "Every finding is tested under at least two checks beyond its main set" =
    nrow(tested_beyond_main) == nrow(robustness_findings) && all(tested_beyond_main$n >= 2)
)

robustness_fills <- c(
  "Holds" = chart_fills[["accent"]],
  "Fails" = site_group_colours[["Houston Ship Channel"]],
  "Does not apply" = chart_fills[["band"]]
)

robustness_panel <- function(scope_name, panel_number, panel_title, panel_subtitle) {
  scope_rows <- robustness_findings %>%
    filter(scope == scope_name)
  scope_columns <- if (scope_name == "National") unique(national_check_labels) else unique(case_check_labels)
  row_levels <- rev(pretty_text(str_c(scope_rows$figure, "  ", scope_rows$finding)))
  robustness %>%
    filter(scope == scope_name) %>%
    mutate(row_label = factor(pretty_text(str_c(figure, "  ", finding)), levels = row_levels)) %>%
    mutate(check = factor(check_plot_labels[as.character(check)], levels = check_plot_labels[scope_columns])) %>%
    mutate(cell_text = if_else(result == "Does not apply", "", result)) %>%
    ggplot(aes(check, row_label, fill = result)) +
    geom_tile(colour = "white", linewidth = 0.8) +
    geom_text(aes(label = cell_text), colour = "white", family = chart_fonts[["text"]], size = 5.6 / .pt) +
    scale_fill_manual(values = robustness_fills, guide = "none") +
    scale_x_discrete(position = "top", labels = pretty_text) +
    labs(title = panel_label(panel_number, panel_title), subtitle = panel_subtitle, x = NULL, y = NULL) +
    theme_paper() +
    theme(
      panel.grid = element_blank(),
      axis.ticks = element_blank(),
      axis.text.x.top = element_text(colour = chart_ink[["secondary"]], size = 5.8, lineheight = 0.95),
      axis.text.y = element_text(colour = chart_ink[["primary"]], size = 6.4, hjust = 0, margin = margin(r = 6))
    )
}

national_tested <- sum(robustness$result != "Does not apply" & robustness$scope == "National")

case_tested <- sum(robustness$result != "Does not apply" & robustness$scope == "Case study")

robustness_row_weights <- c(
  sum(robustness_findings$scope == "National") + 2.2,
  sum(robustness_findings$scope == "Case study") + 2.2
)

robustness_figure <- tagged_figure(
  list(
    robustness_panel("National", 1, "National findings", sprintf("All %d finding and check pairs hold", national_tested)),
    robustness_panel("Case study", 2, "Houston and Dallas-Fort Worth", sprintf("All %d finding and check pairs hold", case_tested))
  ),
  tribble(
    ~mark,    ~colour,                              ~label,
    "square", robustness_fills[["Holds"]],          "Holds",
    "square", robustness_fills[["Fails"]],          "Fails",
    "square", robustness_fills[["Does not apply"]], "Check does not apply to the finding"
  ),
  source_note = sprintf(
    str_c(
      "Source: Phase 3 records, EPA AQS daily data %s to %s. (a) five-year sites outside the near-zero rule; (b) warm-month case-study ozone. ",
      "Second seed: the 95%% ranges redrawn with seed %s."
    ),
    min(study_years), max(study_years), group_range_check_seed
  ),
  ncol = 1,
  row_weights = robustness_row_weights
)

save_figure(robustness_figure, "3.10_checks.png", 5)

# headline numbers for the report: one row per number the text quotes, with unit, 95% range if any, and
# the record it comes from. every value's read from a saved record so the report never retypes a number
record_row <- function(table, ...) {
  rows <- filter(phase3_records[[table]], ...)
  stopifnot("Each headline reads exactly one row of its record" = nrow(rows) == 1)
  rows
}

headline <- function(figure, finding, subject, value, unit, source_table, ci_low = NA_real_, ci_high = NA_real_) {
  tibble(
    figure = figure,
    finding = finding,
    subject = subject,
    value = value,
    unit = unit,
    ci_low = ci_low,
    ci_high = ci_high,
    source_table = source_table
  )
}

national_shape <- function(pollutant_name) {
  record_row("distribution_shape_summary", scope == "National", site_set == "Ordinary days", pollutant == pollutant_name)
}

national_fit <- function(pollutant_name) {
  record_row("distribution_fit_summary", scope == "National", site_set == "Ordinary days", pollutant == pollutant_name)
}

national_tail <- function(pollutant_name, test_name) {
  record_row("distribution_tail_summary", scope == "National", site_set == "Ordinary days", pollutant == pollutant_name, test == test_name)
}

national_pooled <- function(pollutant_name) {
  record_row("distribution_summary", scope == "National", site_set == "Ordinary days", pollutant == pollutant_name)
}

instrument_share <- function(version_name) {
  rows <- phase3_records$distribution_fit_checks %>%
    filter(check == "Instrument", version == version_name)
  tibble(n_sites = nrow(rows), pct_lognormal = 100 * mean(rows$winner == "lognormal"))
}

warm_spread <- function(comparison_name) {
  record_row("distribution_fit_checks", check == "Group spread", version == "Warm season", pollutant == "Ozone", comparison == comparison_name)
}

warm_gamma <- function(group) {
  record_row("distribution_tail_ranges", site_set == "Warm season", measure == "gamma", site_group == group)
}

warm_top <- function(group) {
  record_row("distribution_tail_summary", scope == "Case study", site_set == "Warm season", pollutant == "Ozone", test == "P99", site_group == group)
}

deer_park_p99_ratio <- function(set_name) {
  row <- record_row("distribution_tail_sites", pollutant == "SO2", site_id == deer_park_id, site_set == set_name, test == "P99")
  row$expected_winner / row$actual_days
}

latest_design_values <- phase3_records$distribution_design_values %>%
  filter(first_year == max(design_value_windows$first_year))

aldine_design_value <- record_row("distribution_design_values", site_id == aldine_id, first_year == max(design_value_windows$first_year))

highest_design_value <- latest_design_values %>%
  slice_max(design_value_ppm, n = 1)

lowest_design_value <- latest_design_values %>%
  slice_min(design_value_ppm, n = 1)

t640_alone <- instrument_share("T640 alone")

without_t640 <- instrument_share("Without T640")

ozone_main_fit <- national_fit("Ozone")

ozone_limit <- national_tail("Ozone", "Limit")

log_suited <- c("PM2.5", "SO2", "CO")

ship_channel_spread <- warm_spread("Ship Channel minus Dallas-Fort Worth")

houston_other_spread <- warm_spread("Houston other minus Dallas-Fort Worth")

group_names <- names(site_group_colours)

p99_rows <- bind_rows(lapply(pollutant_levels, \(pollutant_name) national_tail(pollutant_name, "P99")))

within_rows <- p99_rows %>%
  filter(pct_within_25_winner %in% range(pct_within_25_winner))

inventory <- phase3_records$distribution_site_inventory

headline_rows <- list(
  headline(
    NA_character_, "Five-year sites fitted, outside the near-zero rule", "All pollutants",
    nrow(phase3_records$distribution_shape_sites), "sites", "distribution_shape_sites"
  ),
  headline(
    NA_character_, "Site-days in the fit table, collocated instruments averaged", "All pollutants",
    sum(inventory$n_site_days), "site-days", "distribution_site_inventory"
  ),
  headline(
    NA_character_, "Sites left out of the fits as near zero", "SO2",
    sum(inventory$is_near_zero_site & inventory$pollutant == "SO2"), "sites", "distribution_site_inventory"
  ),
  headline(NA_character_, "Skewness of the pooled ordinary days", "SO2", national_pooled("SO2")$skewness, "skewness", "distribution_summary"),
  headline(NA_character_, "Skewness of the typical site", "SO2", national_pooled("SO2")$median_site_skewness, "skewness", "distribution_summary"),
  headline(
    NA_character_, "Share of the pooled variance that lies between sites", "NO2",
    national_pooled("NO2")$pct_variance_between_sites, "%", "distribution_summary"
  ),
  headline(
    "3.1", "Sites where a lognormal is closer than a normal curve", log_suited,
    vapply(log_suited, \(p) national_shape(p)$pct_sites_lognormal_closer, numeric(1)), "% of sites", "distribution_shape_summary"
  ),
  headline(
    "3.2", "Sites where a normal curve is closer than a lognormal", "Ozone",
    100 - national_shape("Ozone")$pct_sites_lognormal_closer, "% of sites", "distribution_shape_summary"
  ),
  headline(
    "3.2", "Sites where a lognormal is closer than a normal curve", "NO2",
    national_shape("NO2")$pct_sites_lognormal_closer, "% of sites", "distribution_shape_summary"
  ),
  headline(
    "3.5", "Sites a lognormal wins by AIC", c("SO2", "CO"),
    c(national_fit("SO2")$wins_lognormal, national_fit("CO")$wins_lognormal),
    str_c("of ", c(national_fit("SO2")$n_sites, national_fit("CO")$n_sites), " sites"), "distribution_fit_summary"
  ),
  headline(
    "3.5", "Sites a normal curve wins when it may compete", "Ozone",
    ozone_main_fit$wins_with_normal_normal, str_c("of ", ozone_main_fit$n_sites, " sites"), "distribution_fit_summary"
  ),
  headline("3.5", "Sites with an AIC gap of 10 or more", "Ozone", ozone_main_fit$pct_sites_gap_decisive, "% of sites", "distribution_fit_summary"),
  headline(
    "3.5", "Sites with an AIC gap of 10 or more after scaling for linked days", "Ozone",
    ozone_main_fit$pct_sites_scaled_gap_decisive, "% of sites", "distribution_fit_summary"
  ),
  headline(
    "3.5", "Sampled sites whose winner holds in 90% of block resamples", "Ozone",
    ozone_main_fit$pct_resampled_clear, "% of sites", "distribution_fit_summary"
  ),
  headline(
    "3.5", "Lognormal wins at the same PM2.5 sites, by instrument", c("T640 alone", "Other monitors"),
    c(t640_alone$pct_lognormal, without_t640$pct_lognormal), "% of fits", "distribution_fit_checks"
  ),
  headline(
    "3.6", "Warm-month ozone spread factor, median site", group_names,
    c(ship_channel_spread$spread_first_group, houston_other_spread$spread_first_group, houston_other_spread$spread_second_group),
    "spread factor", "distribution_fit_checks"
  ),
  headline(
    "3.6", "Warm-month ozone spread factor gap to Dallas-Fort Worth", group_names[1:2],
    c(ship_channel_spread$spread_gap, houston_other_spread$spread_gap), "spread factor", "distribution_fit_checks",
    ci_low = c(ship_channel_spread$gap_low, houston_other_spread$gap_low),
    ci_high = c(ship_channel_spread$gap_high, houston_other_spread$gap_high)
  ),
  headline(
    "3.7", "Winner's expected / actual days above each site's P99, totals", as.character(p99_rows$pollutant),
    p99_rows$ratio_total_winner, "ratio", "distribution_tail_summary"
  ),
  headline(
    "3.7", "Judged sites where the winner lands within 25% at P99, lowest and highest", as.character(within_rows$pollutant),
    within_rows$pct_within_25_winner, "% of judged sites", "distribution_tail_summary"
  ),
  headline("3.7", "Ordinary ozone days above the limit", "Ozone", ozone_limit$n_actual_days, "site-days", "distribution_tail_summary"),
  headline(
    "3.7", "Expected / actual ozone days above the limit, totals", c("Winner", "Lognormal"),
    c(ozone_limit$ratio_total_winner, ozone_limit$ratio_total_lognormal), "ratio", "distribution_tail_summary"
  ),
  headline(
    "3.9", "Gamma's expected / actual warm-month ozone days above the limit", group_names,
    vapply(group_names, \(g) warm_gamma(g)$estimate, numeric(1)), "ratio", "distribution_tail_ranges",
    ci_low = vapply(group_names, \(g) warm_gamma(g)$range_low, numeric(1)),
    ci_high = vapply(group_names, \(g) warm_gamma(g)$range_high, numeric(1))
  ),
  headline(
    "3.8", "Gamma's expected / actual days in each site's warm top 1%", group_names,
    vapply(group_names, \(g) warm_top(g)$ratio_total_gamma, numeric(1)), "ratio", "distribution_tail_summary"
  ),
  headline(
    "3.9", "Deer Park #2 SO2 expected / actual days above P99", c("Main lognormal fit", "Censored Weibull fit"),
    c(deer_park_p99_ratio("Ordinary days"), deer_park_p99_ratio("Readings below the limit censored")), "ratio", "distribution_tail_sites"
  ),
  headline(
    NA_character_, "Ozone design value, 2023 to 2025", c("Houston Aldine", "Houston Aldine, EPA's file"),
    c(aldine_design_value$design_value_ppm, aldine_design_value$epa_design_value_ppm), "ppm", "distribution_design_values"
  ),
  headline(
    NA_character_, "Site-windows whose design value matches EPA's", "22 sites, 3 windows",
    sum(phase3_records$distribution_design_values$matches_epa), str_c("of ", nrow(phase3_records$distribution_design_values)),
    "distribution_design_values"
  ),
  headline(
    NA_character_, "Case-study ozone sites above the 0.070 ppm standard, 2023 to 2025", "All groups",
    sum(latest_design_values$is_above_standard), str_c("of ", nrow(latest_design_values), " sites"), "distribution_design_values"
  ),
  headline(
    NA_character_, "Highest and lowest 2023 to 2025 design value", c(highest_design_value$local_site_name, lowest_design_value$local_site_name),
    c(highest_design_value$design_value_ppm, lowest_design_value$design_value_ppm), "ppm", "distribution_design_values"
  ),
  headline(
    "3.10", "Findings that hold under every check that applies", "All findings",
    nrow(robustness_findings) - n_distinct(robustness$finding_id[robustness$result == "Fails"]), str_c("of ", nrow(robustness_findings)),
    "distribution_robustness"
  )
)

distribution_headlines <- bind_rows(headline_rows) %>%
  mutate(headline_id = sprintf("F%02d", row_number())) %>%
  mutate(digits = if_else(unit %in% c("ppm", "spread factor"), 3, 2)) %>%
  mutate(across(c(value, ci_low, ci_high), \(x) round_half_up(x, digits))) %>%
  select(headline_id, figure, finding, subject, value, unit, ci_low, ci_high, source_table)

print(distribution_headlines, n = Inf, width = Inf)

headline_ranges <- distribution_headlines %>%
  filter(!is.na(ci_low))

stopifnot(
  "Every headline has a value" = !anyNA(distribution_headlines$value),
  "Every headline range holds its value" = all(headline_ranges$ci_low <= headline_ranges$value & headline_ranges$value <= headline_ranges$ci_high),
  "Highest and lowest design values each belong to one site" = nrow(highest_design_value) == 1 && nrow(lowest_design_value) == 1,
  "The T640 comparison covers the same 67 sites on both sides" = t640_alone$n_sites == 67 && without_t640$n_sites == 67
)

range_rows <- bind_rows(
  phase3_records$distribution_fit_checks %>%
    filter(check == "Group spread") %>%
    transmute(estimate = spread_gap, range_low = gap_low, range_high = gap_high, seed_shift_share),
  phase3_records$distribution_tail_ranges %>%
    select(estimate, range_low, range_high, seed_shift_share)
)

figure_paths <- file.path(figures_dir, c(
  "3.01_shape_log_scale.png", "3.02_shape_ozone_no2.png", "3.03_case_study_shape.png", "3.04_case_study_qq.png", "3.05_fits.png",
  "3.06_ozone_spread.png", "3.07_tails.png", "3.08_warm_ozone_tails.png", "3.09_case_study_limit.png", "3.10_checks.png"
))

final_records <- list(
  distribution_robustness = mutate(robustness, check = as.character(check)),
  distribution_headlines = distribution_headlines
)

save_records(final_records, records_dir)

all_records <- c(phase3_records, final_records)

record_paths <- file.path(records_dir, str_c(names(all_records), ".csv"))

documented_tables <- read_csv(data_dictionary_path, col_types = cols(.default = col_character())) %>%
  distinct(table) %>%
  pull(table)

fitted_site_counts <- phase3_records$distribution_shape_sites %>%
  count(pollutant) %>%
  arrange(pollutant)

case_ozone_counts <- latest_design_values %>%
  count(site_group) %>%
  arrange(match(site_group, group_names))

design_values_record <- phase3_records$distribution_design_values

ours_above_standard <- design_values_record$design_value_ppm > ozone_standard_ppm

epa_above_standard <- design_values_record$epa_design_value_ppm > ozone_standard_ppm

verdict_changes <- sum(ours_above_standard != epa_above_standard)

near_zero_sites <- sum(inventory$is_near_zero_site)

inputs_matching <- sum(input_check$md5 == input_check$md5_on_disk)

duplicate_fits <- sum(duplicated(select(phase3_records$distribution_fits, pollutant, site_id, site_set)))

fits_off_fitdistrplus <- sum(fit_agreement$largest_gap >= fit_agreement_tolerance)

ranges_missing_estimate <- sum(range_rows$estimate < range_rows$range_low | range_rows$estimate > range_rows$range_high)

ranges_moved_by_seed <- sum(range_rows$seed_shift_share > group_range_seed_tolerance)

headline_sources_missing <- sum(!distribution_headlines$source_table %in% names(all_records))

undocumented_tables <- sum(!names(phase3_records) %in% documented_tables)

tables_over_limit <- sum(file.size(record_paths) / 2^20 >= github_limit_mib)

sites_fitted <- nrow(phase3_records$distribution_shape_sites)

inventory_sites_expected <- sum(five_year_site_counts)

count_checks <- tribble(
  ~check,                                                                   ~observed,                             ~expected,
  "Inputs whose MD5 matches the manifest",                                  inputs_matching,                       length(input_files),
  "Five-year site-days after collocated instruments are averaged",          sum(inventory$n_site_days),            five_year_site_days,
  "Five-year sites in the inventory",                                       nrow(inventory),                       inventory_sites_expected,
  "Sites left out of the fits as near zero",                                near_zero_sites,                       56,
  "Sites fitted",                                                           sites_fitted,                          inventory_sites_expected - 56,
  "Duplicate fits (pollutant, site and set)",                               duplicate_fits,                        0,
  "Sites where the fast fit misses fitdistrplus by 0.001 AIC or more",      fits_off_fitdistrplus,                 0,
  "95% ranges with a second seed: group spread gaps and tail ranges",       nrow(range_rows),                      27 + 72,
  "95% ranges that leave out their own estimate",                           ranges_missing_estimate,               0,
  "95% ranges whose ends move over 10% of their width with a second seed",  ranges_moved_by_seed,                  0,
  "Finding and check pairs that fail",                                      n_failing,                             0,
  "Site-windows whose design value matches EPA's",                          sum(design_values_record$matches_epa), 61,
  "Design value misses that change whether a site is above the standard",  verdict_changes,                       0,
  "Headlines whose source table is not saved",                              headline_sources_missing,              0,
  "Phase 3 figures on disk",                                                sum(file.exists(figure_paths)),        length(figure_paths),
  "Saved Phase 3 tables without data dictionary rows (this section aside)", undocumented_tables,                   0,
  "Saved Phase 3 tables at or over the GitHub limit",                       tables_over_limit,                     0
) %>%
  mutate(observed = as.character(observed)) %>%
  mutate(expected = as.character(expected))

aldine_values_text <- str_c(sprintf("%.3f", aldine_design_value$design_value_ppm), "/", sprintf("%.3f", aldine_design_value$epa_design_value_ppm))

text_checks <- tribble(
  ~check,                                                        ~observed,                                         ~expected,
  "Sites fitted per pollutant: PM2.5, ozone, NO2, SO2, CO",      str_flatten(fitted_site_counts$n, collapse = "/"), "769/964/311/249/132",
  "Case-study ozone sites: Ship Channel, Houston other, DFW",    str_flatten(case_ozone_counts$n, collapse = "/"),  "6/10/6",
  "Houston Aldine 2023-2025 design value: ours and EPA's, ppm",  aldine_values_text,                                "0.082/0.082"
)

distribution_validation <- bind_rows(count_checks, text_checks) %>%
  mutate(passed = observed == expected)

print(distribution_validation, n = Inf, width = Inf)

stopifnot("Every Phase 3 validation check passed" = all(distribution_validation$passed))

# validation table gets saved last so it covers every other file
validation_records <- list(
  distribution_validation = distribution_validation
)

save_records(validation_records, records_dir)

final_dictionary <- tribble(
  ~table,                    ~column,         ~description,
  "distribution_robustness", "finding_id",    "R01 to R12, one per finding a Phase 3 figure makes",
  "distribution_robustness", "scope",         "National (five-year sites outside the near-zero rule) or Case study (warm-month ozone)",
  "distribution_robustness", "figure",        "Figure that shows the finding",
  "distribution_robustness", "finding",       "The finding in plain words",
  "distribution_robustness", "check",         "Main, a check from the summary records, or Second seed; a split check holds when both halves do",
  "distribution_robustness", "result",        "Holds, Fails, or Does not apply (not run for the finding, or changes nothing it uses)",
  "distribution_headlines",  "headline_id",   "F01 onward, in section order",
  "distribution_headlines",  "figure",        "Figure that shows the number; NA for sections 1, 2 and 6, which have no figure for it",
  "distribution_headlines",  "finding",       "What the number measures, in plain words",
  "distribution_headlines",  "subject",       "Pollutant, group, site, curve or set the number belongs to",
  "distribution_headlines",  "value",         "The number: 3 decimals for ppm and spread factors, 2 otherwise, halves rounded up",
  "distribution_headlines",  "unit",          "Unit of value",
  "distribution_headlines",  "ci_low",        "Lower end of the 95% range where the record gives one; NA otherwise",
  "distribution_headlines",  "ci_high",       "Upper end of the 95% range where the record gives one; NA otherwise",
  "distribution_headlines",  "source_table",  "CSV record in data/processed/phase3 the number comes from",
  "distribution_validation", "check",         "What section 7 checks: inputs, counts, fits, ranges, findings, design values or saved files",
  "distribution_validation", "observed",      "Value found in this run",
  "distribution_validation", "expected",      "Value the check requires",
  "distribution_validation", "passed",        "TRUE when observed equals expected; the script stops otherwise"
)

final_dictionary <- document_tables(c(final_records, validation_records), final_dictionary)

replace_own_rows(final_dictionary, data_dictionary_path, key = "table", col_types = cols(.default = col_character()))

rm(fit_agreement, warm_ozone_check_gaps)
invisible(gc())
