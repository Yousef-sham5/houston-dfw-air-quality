# SETUP ----
library(dplyr)
library(readr)
library(stringr)
library(lubridate)
library(ggplot2)
library(here)

source(here("R", "utils.R")) # region_lookup



# 1. LOAD CHECKPOINTS ----
processed_dir <- here("data", "processed")

site_coverage <- read_rds(file.path(processed_dir, "site_coverage.rds"))
sites <- read_rds(file.path(processed_dir, "sites.rds"))
aqs_long_clean <- read_rds(file.path(processed_dir, "aqs_long_clean.rds"))

stopifnot(
  "site_coverage needs pollutant, site_id, n_years_active" =
    all(c("pollutant", "site_id", "n_years_active") %in% names(site_coverage)),
  "sites needs site_id, local_site_name, latitude, longitude" =
    all(c("site_id", "local_site_name", "latitude", "longitude") %in% names(sites)),
  "aqs_long_clean needs pollutant, site_id, date_local" =
    all(c("pollutant", "site_id", "date_local") %in% names(aqs_long_clean))
)



# 2. DEFINE SCOPE ----
study_years <- 2021:2025

hourly_pollutants <- c("Ozone", "NO2", "SO2")

houston_county <- "48-201"

case_regions <- region_lookup %>%
  filter(county_id %in% c("48-201", "48-113", "48-439")) %>%
  select(county_id, region)

stopifnot("region_lookup holds Harris, Dallas and Tarrant" = nrow(case_regions) == 3)

# Industrial east-side sites: the TCEQ Region 12 memo list, plus Park Place and Baytown Garth
ship_channel_ids <- c(
  "48-201-0026",
  "48-201-0036",
  "48-201-0057",
  "48-201-0069",
  "48-201-0307",
  "48-201-0416",
  "48-201-0617",
  "48-201-0803",
  "48-201-0807",
  "48-201-1015",
  "48-201-1017",
  "48-201-1034",
  "48-201-1035",
  "48-201-1039",
  "48-201-1049",
  "48-201-1614",
  "48-201-6000"
)

# Next to the Bayport Industrial District, so kept out of both Houston groups
bayport_adjacent_ids <- c(
  "48-201-1050"
)

stopifnot(
  "Ship Channel IDs are Harris County site IDs" = all(str_detect(ship_channel_ids, "^48-201-\\d{4}$")),
  "Ship Channel IDs are unique" = !anyDuplicated(ship_channel_ids),
  "Bayport-adjacent IDs are Harris County site IDs" = all(str_detect(bayport_adjacent_ids, "^48-201-\\d{4}$")),
  "No site is both Ship Channel and Bayport-adjacent" = !any(bayport_adjacent_ids %in% ship_channel_ids)
)

study_days <- as.numeric(make_date(max(study_years), 12, 31) - make_date(min(study_years), 1, 1)) + 1

stopifnot("Study window is 1826 days" = study_days == 1826)



# 3. COUNT VALID DAYS PER SITE AND POLLUTANT ----
# Days with data per site and pollutant (instruments pooled), as a share of the 1,826 study days
day_counts <- aqs_long_clean %>%
  filter(pollutant %in% hourly_pollutants) %>%
  filter(str_sub(site_id, 1, 6) %in% case_regions$county_id) %>%
  distinct(pollutant, site_id, date_local) %>%
  count(pollutant, site_id, name = "n_days") %>%
  mutate(pct_days = n_days / study_days)

# The daily table is no longer needed, so free its memory
rm(aqs_long_clean)
invisible(gc())



# 4. BUILD CANDIDATE TABLE ----
# Eligible pool: 5-year monitors of the three pollutants in the case-study counties, each placed in one group
candidates <- site_coverage %>%
  filter(pollutant %in% hourly_pollutants) %>%
  filter(n_years_active == length(study_years)) %>%
  mutate(county_id = str_sub(site_id, 1, 6)) %>%
  inner_join(case_regions, by = "county_id", relationship = "many-to-one") %>%
  inner_join(day_counts, by = c("pollutant", "site_id"), relationship = "one-to-one") %>%
  left_join(sites, by = "site_id", relationship = "many-to-one") %>%
  mutate(site_group = case_when(
    site_id %in% ship_channel_ids ~ "Houston Ship Channel",
    site_id %in% bayport_adjacent_ids ~ "Excluded: Bayport-adjacent",
    county_id == houston_county ~ "Houston other",
    .default = "Dallas-Fort Worth"
  ))

# Flag sites that measure both ozone and NO2, since the NO2-ozone lag needs both at one place
collocation <- candidates %>%
  group_by(site_id) %>%
  summarise(
    has_ozone = any(pollutant == "Ozone"),
    has_no2 = any(pollutant == "NO2"),
    .groups = "drop"
  ) %>%
  mutate(o3_no2_pair = has_ozone & has_no2)

candidates <- candidates %>%
  left_join(collocation, by = "site_id", relationship = "many-to-one")

duplicate_candidates <- candidates %>%
  count(pollutant, site_id) %>%
  filter(n > 1)

stopifnot(
  "Candidate monitors found" = nrow(candidates) > 0,
  "One candidate row per site and pollutant" = nrow(duplicate_candidates) == 0,
  "Every candidate has site metadata" = !anyNA(candidates$latitude)
)

candidates %>%
  count(site_group, pollutant) %>%
  print(n = Inf)



# 5. APPLY SELECTION RULES ----
eligible <- candidates %>%
  filter(!str_starts(site_group, "Excluded"))

# SO2: keep every full-coverage monitor
so2_picks <- eligible %>%
  filter(pollutant == "SO2") %>%
  mutate(selection_reason = "All full-coverage SO2")

# Ozone and NO2: score each paired site by its less complete pollutant.
# Keep the top 2 in each Houston group and the top 1 in each Dallas-Fort Worth county
pair_ranking <- eligible %>%
  filter(pollutant %in% c("Ozone", "NO2")) %>%
  filter(o3_no2_pair) %>%
  group_by(site_group, county_id, site_id) %>%
  summarise(pair_pct = min(pct_days), .groups = "drop") %>%
  mutate(
    rank_group = if_else(site_group == "Dallas-Fort Worth", str_c(site_group, " ", county_id), site_group),
    n_slots = if_else(site_group == "Dallas-Fort Worth", 1L, 2L)
  )

pair_sites <- pair_ranking %>%
  arrange(rank_group, desc(pair_pct)) %>%
  group_by(rank_group) %>%
  filter(row_number() <= n_slots) %>%
  ungroup() %>%
  mutate(selection_reason = if_else(
    site_group == "Dallas-Fort Worth",
    "Top O3/NO2 completeness in county",
    "Top O3/NO2 completeness in group"
  ))

# Expand the picked sites back to one row per monitor
pair_picks <- eligible %>%
  filter(pollutant %in% c("Ozone", "NO2")) %>%
  inner_join(
    pair_sites %>% select(site_id, selection_reason),
    by = "site_id",
    relationship = "many-to-one"
  )

case_study_sites <- bind_rows(so2_picks, pair_picks) %>%
  distinct(pollutant, site_id, .keep_all = TRUE) %>%
  select(site_id, pollutant, region, site_group, local_site_name, latitude, longitude, n_days, pct_days, o3_no2_pair, selection_reason) %>%
  arrange(region, site_group, site_id, pollutant)

stopifnot(
  "Ship Channel monitors picked" = any(case_study_sites$site_group == "Houston Ship Channel"),
  "Dallas-Fort Worth monitors picked" = any(case_study_sites$site_group == "Dallas-Fort Worth"),
  "Houston other monitors picked" = any(case_study_sites$site_group == "Houston other"),
  "No excluded site was picked" = !any(case_study_sites$site_id %in% bayport_adjacent_ids),
  "At most 2 ozone and NO2 sites per group" = all(count(pair_sites, site_group)$n <= 2),
  "Dallas-Fort Worth has one pair site per county" =
    all(count(filter(pair_sites, site_group == "Dallas-Fort Worth"), county_id)$n == 1),
  "Dallas-Fort Worth has an ozone and NO2 pair" =
    any(case_study_sites$site_group == "Dallas-Fort Worth" & case_study_sites$o3_no2_pair)
)

print(case_study_sites, n = Inf, width = Inf)

case_study_sites %>%
  count(site_group, pollutant) %>%
  print(n = Inf)



# 6. SAVE ----
# The full pool and the picks; 1d reads case_study_sites.csv
write_csv(candidates, here("data", "reference", "case_study_candidates.csv"))
write_csv(case_study_sites, here("data", "reference", "case_study_sites.csv"))



# 7. MAP PICKED SITES ----
# Visual check that each group sits where expected
site_map <- case_study_sites %>%
  distinct(site_id, region, site_group, latitude, longitude) %>%
  ggplot(aes(x = longitude, y = latitude, colour = site_group)) +
  geom_point(size = 3) +
  geom_text(aes(label = site_id), size = 2.5, vjust = -1, show.legend = FALSE) +
  facet_wrap(~ region, scales = "free") +
  scale_x_continuous(n.breaks = 4, expand = expansion(mult = 0.3)) +
  scale_y_continuous(expand = expansion(mult = 0.15)) +
  labs(
    title = "Case-study monitors for hourly analysis",
    x = "Longitude",
    y = "Latitude",
    colour = "Site group"
  ) +
  theme_minimal()

dir.create(here("figures"), showWarnings = FALSE)

ggsave(here("figures", "case_study_sites.png"), site_map, width = 9, height = 5, dpi = 300)