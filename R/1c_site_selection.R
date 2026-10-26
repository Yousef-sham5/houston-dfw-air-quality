# SETUP ----
library(dplyr)
library(readr)
library(stringr)
library(lubridate)
library(ggplot2)
library(patchwork)
library(jsonlite)
library(here)

source(here("R", "utils.R")) # study_years, region_lookup, chart theme



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
hourly_pollutants <- c("Ozone", "NO2", "SO2")

houston_county <- "48-201"

case_regions <- region_lookup %>%
  filter(county_id %in% c("48-201", "48-113", "48-439")) %>%
  select(county_id, region)

stopifnot("region_lookup holds Harris, Dallas and Tarrant" = nrow(case_regions) == 3)

# Sites in TCEQ's 2024 Region 12 air toxics memo, plus Park Place and Baytown Garth. The groups no longer come from
# this list; 2b reruns its comparisons with it as a check
memo_list_ids <- c(
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

# Land-cut reach of the Houston Ship Channel, from Morgan's Point to the Turning Basin: 12 sections of the USACE
# National Channel Framework (ChannelArea layer)
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

# A Harris site within ship_channel_km of the land-cut channel is a Ship Channel site; every other Harris site is
# Houston other. 7.5 km falls between Deer Park #2 (6.9 km) and North Wayside (8.5 km). Sites up to transition_km form a
# transition band that 2b leaves out as a check
ship_channel_km <- 7.5

transition_km <- 15

stopifnot(
  "Memo-list IDs are Harris County site IDs" = all(str_detect(memo_list_ids, "^48-201-\\d{4}$")),
  "Memo-list IDs are unique" = !anyDuplicated(memo_list_ids),
  "Bayport-adjacent IDs are Harris County site IDs" = all(str_detect(bayport_adjacent_ids, "^48-201-\\d{4}$")),
  "No site is both on the memo list and Bayport-adjacent" = !any(bayport_adjacent_ids %in% memo_list_ids),
  "Twelve unique land-cut sections" = length(unique(land_cut_sections)) == 12,
  "The transition band starts at the Ship Channel cutoff" = ship_channel_km < transition_km
)

study_days <- as.numeric(make_date(max(study_years), 12, 31) - make_date(min(study_years), 1, 1)) + 1

stopifnot("Study window is 1826 days" = study_days == 1826)



# 3. MEASURE DISTANCE TO THE SHIP CHANNEL ----
# Outer ring of each land-cut section, one row per vertex
channel_features <- read_json(channel_path)$features

feature_sections <- vapply(channel_features, \(feature) feature$properties$channelareaidpk, character(1))

feature_types <- vapply(channel_features, \(feature) feature$geometry$type, character(1))

stopifnot(
  "Every land-cut section is in the channel file" = all(land_cut_sections %in% feature_sections),
  "Each land-cut section is one polygon" = all(feature_types[feature_sections %in% land_cut_sections] == "Polygon")
)

channel_vertices <- bind_rows(lapply(channel_features[feature_sections %in% land_cut_sections], \(feature) {
  ring <- feature$geometry$coordinates[[1]]
  tibble(
    section = feature$properties$channelareaidpk,
    vertex = seq_along(ring),
    longitude = vapply(ring, \(point) point[[1]], numeric(1)),
    latitude = vapply(ring, \(point) point[[2]], numeric(1))
  )
}))

ring_ends <- channel_vertices %>%
  summarise(is_closed = first(longitude) == last(longitude) & first(latitude) == last(latitude), .by = section)

stopifnot("Each section's ring closes on its first vertex" = all(ring_ends$is_closed))

# Kilometres on a flat map centred on Houston's latitude (29.7°)
km_per_lat_degree <- 110.574

km_per_lon_degree_houston <- 111.320 * cos(29.7 * pi / 180)

channel_edges <- channel_vertices %>%
  mutate(x0 = longitude * km_per_lon_degree_houston, y0 = latitude * km_per_lat_degree) %>%
  mutate(x1 = lead(x0), y1 = lead(y0), .by = section) %>%
  filter(!is.na(x1)) %>%
  filter(x0 != x1 | y0 != y1) %>%
  select(section, x0, y0, x1, y1)

harris_sites <- sites %>%
  filter(str_sub(site_id, 1, 6) == houston_county) %>%
  select(site_id, local_site_name, latitude, longitude) %>%
  mutate(site_x = longitude * km_per_lon_degree_houston, site_y = latitude * km_per_lat_degree)

# Shortest distance from each site to any edge of a section, and whether the site sits inside it (an odd number of edge
# crossings on a ray running east)
section_distances <- harris_sites %>%
  select(site_id, site_x, site_y) %>%
  cross_join(channel_edges) %>%
  mutate(dx = x1 - x0, dy = y1 - y0) %>%
  mutate(t = pmin(pmax(((site_x - x0) * dx + (site_y - y0) * dy) / (dx^2 + dy^2), 0), 1)) %>%
  mutate(edge_km = sqrt((site_x - x0 - t * dx)^2 + (site_y - y0 - t * dy)^2)) %>%
  mutate(crosses_edge = (y0 > site_y) != (y1 > site_y) & site_x < x0 + dx * (site_y - y0) / dy) %>%
  summarise(edge_km = min(edge_km), is_inside = sum(crosses_edge) %% 2 == 1, .by = c(site_id, section))

channel_distances <- section_distances %>%
  summarise(km_to_channel = if_else(any(is_inside), 0, min(edge_km)), .by = site_id)

# Every Harris site with its distance, distance band, group, and its group under the memo list
harris_channel_distance <- harris_sites %>%
  select(site_id, local_site_name, latitude, longitude) %>%
  inner_join(channel_distances, by = "site_id", relationship = "one-to-one") %>%
  mutate(
    distance_band = case_when(
      km_to_channel <= ship_channel_km ~ str_c("Within ", ship_channel_km, " km"),
      km_to_channel <= transition_km ~ str_c(ship_channel_km, " to ", transition_km, " km"),
      .default = str_c("Over ", transition_km, " km")
    )
  ) %>%
  mutate(
    site_group = case_when(
      site_id %in% bayport_adjacent_ids ~ "Excluded: Bayport-adjacent",
      km_to_channel <= ship_channel_km ~ "Houston Ship Channel",
      .default = "Houston other"
    )
  ) %>%
  mutate(in_memo_list = site_id %in% memo_list_ids) %>%
  mutate(
    memo_site_group = case_when(
      site_id %in% bayport_adjacent_ids ~ "Excluded: Bayport-adjacent",
      in_memo_list ~ "Houston Ship Channel",
      .default = "Houston other"
    )
  ) %>%
  mutate(km_to_channel = round(km_to_channel, 3)) %>%
  arrange(km_to_channel)

print(harris_channel_distance, n = Inf, width = Inf)

memo_sites_beyond_cutoff <- harris_channel_distance %>%
  filter(in_memo_list, km_to_channel > ship_channel_km)

sites_near_a_cutoff <- harris_channel_distance %>%
  filter(abs(km_to_channel - ship_channel_km) < 0.5 | abs(km_to_channel - transition_km) < 0.5)

stopifnot(
  "Every Harris site has a distance" = nrow(harris_channel_distance) == nrow(harris_sites),
  "No Harris site lies within 0.5 km of a cutoff, so small coordinate errors cannot change a group" =
    nrow(sites_near_a_cutoff) == 0,
  "Every memo-list site with data is within the cutoff except Baytown Garth" = identical(memo_sites_beyond_cutoff$site_id, "48-201-1017")
)



# 4. COUNT VALID DAYS PER SITE AND POLLUTANT ----
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



# 5. BUILD CANDIDATE TABLE ----
# Eligible pool: 5-year monitors of the three pollutants in the case-study counties, each placed in one group. Houston
# sites take the group set by their distance to the channel
candidates <- site_coverage %>%
  filter(pollutant %in% hourly_pollutants) %>%
  filter(n_years_active == length(study_years)) %>%
  mutate(county_id = str_sub(site_id, 1, 6)) %>%
  inner_join(case_regions, by = "county_id", relationship = "many-to-one") %>%
  inner_join(day_counts, by = c("pollutant", "site_id"), relationship = "one-to-one") %>%
  left_join(sites, by = "site_id", relationship = "many-to-one") %>%
  left_join(
    select(harris_channel_distance, site_id, houston_group = site_group, km_to_channel, in_memo_list),
    by = "site_id",
    relationship = "many-to-one"
  ) %>%
  mutate(site_group = if_else(county_id == houston_county, houston_group, "Dallas-Fort Worth")) %>%
  select(-houston_group)

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
  "Every candidate has site metadata" = !anyNA(candidates$latitude),
  "Every Houston candidate has a group from its channel distance" = !anyNA(candidates$site_group)
)

candidates %>%
  count(site_group, pollutant) %>%
  print(n = Inf)



# 6. APPLY SELECTION RULES ----
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



# 7. SAVE ----
# The full pool and the picks; 1d reads case_study_sites.csv. 2a and 2b take the Houston groups from
# harris_site_channel_distance.csv
write_csv(harris_channel_distance, here("data", "reference", "harris_site_channel_distance.csv"))
write_csv(candidates, here("data", "reference", "case_study_candidates.csv"))
write_csv(case_study_sites, here("data", "reference", "case_study_sites.csv"))



# 8. MAP PICKED SITES ----
# Visual check that each group sits where expected
# One row per site, labelled with a short name and the pollutants picked there
pollutant_symbols <- c(Ozone = "O₃", NO2 = "NO₂", SO2 = "SO₂")

map_sites <- case_study_sites %>%
  mutate(pollutant_symbol = recode_values(
    as.character(pollutant),
    from = names(pollutant_symbols),
    to = unname(pollutant_symbols),
    unmatched = "error"
  )) %>%
  group_by(site_id, region, site_group, local_site_name, latitude, longitude) %>%
  summarise(
    pollutants = str_flatten(sort(unique(pollutant_symbol)), collapse = " · "),
    .groups = "drop"
  ) %>%
  mutate(site_label = str_remove(local_site_name, " Airport Executive$")) %>%
  mutate(site_label = if_else(site_label == "Houston East", site_label, str_remove(site_label, "^Houston "))) %>%
  mutate(label_side = case_when(
    site_label %in% c("Clinton", "Grapevine Fairway") ~ "right",
    site_label %in% c("Park Place", "Deer Park #2") ~ "below",
    .default = "above"
  ))

# Label offsets from each point, in degrees, for a figure printed 6.5 inches wide
label_offsets <- tribble(
  ~label_side, ~name_dx, ~name_dy, ~name_hjust, ~name_vjust, ~pollutant_dx, ~pollutant_dy, ~pollutant_hjust, ~pollutant_vjust,
  "above",     0,        0.036,    0.5,         0,           0,             0.017,         0.5,              0,
  "below",     0,        -0.017,   0.5,         1,           0,             -0.036,        0.5,              1,
  "right",     0.025,    0.003,    0,           0,           0.025,         -0.004,        0,                1
)

map_sites <- map_sites %>%
  left_join(label_offsets, by = "label_side", relationship = "many-to-one")

# Text sizes in mm (1 mm is about 2.85 pt); none prints below 7 pt
map_text_mm <- c(region = 3.8, site = 2.8, detail = 2.5)

# Reference points for orientation only
map_landmarks <- tribble(
  ~region,             ~landmark,          ~latitude, ~longitude,
  "Houston",           "Downtown",         29.7604,   -95.3698,
  "Dallas-Fort Worth", "Downtown Dallas",  32.7767,   -96.7970,
  "Dallas-Fort Worth", "DFW Airport",      32.8998,   -97.0403
)

# Both frames span 0.46 degrees of latitude, so the two maps share one scale
map_frames <- tribble(
  ~region,             ~lon_min, ~lon_max, ~lat_min, ~lat_max,
  "Houston",           -95.585,  -95.035,  29.525,   29.985,
  "Dallas-Fort Worth", -97.150,  -96.710,  32.635,   33.095
)

sites_outside_frame <- map_sites %>%
  inner_join(map_frames, by = "region", relationship = "many-to-one") %>%
  filter(!between(longitude, lon_min, lon_max) | !between(latitude, lat_min, lat_max))

stopifnot(
  "One map point per case-study site" = nrow(map_sites) == n_distinct(case_study_sites$site_id),
  "Every region has a map frame" = all(map_sites$region %in% map_frames$region),
  "Every site sits inside its map frame" = nrow(sites_outside_frame) == 0,
  "Both frames span the same latitude" = n_distinct(round(map_frames$lat_max - map_frames$lat_min, 6)) == 1,
  "Every site has label offsets" = !anyNA(map_sites$name_dx)
)

km_per_lon_degree <- function(lat) 111.32 * cos(lat * pi / 180)

draw_region_map <- function(region_name, bar_km = 10) {
  frame <- filter(map_frames, region == region_name)
  region_sites <- filter(map_sites, region == region_name)
  region_landmarks <- filter(map_landmarks, region == region_name)
  bar_start <- frame$lon_min + 0.03
  bar_end <- bar_start + bar_km / km_per_lon_degree((frame$lat_min + frame$lat_max) / 2)
  bar_y <- frame$lat_min + 0.03

  region_map <- ggplot() +
    annotate("text", x = (frame$lon_min + frame$lon_max) / 2, y = frame$lat_max - 0.025, label = region_name, family = chart_fonts[["title"]], fontface = "bold", size = map_text_mm[["region"]], colour = chart_ink[["primary"]], hjust = 0.5, vjust = 1) +
    annotate("segment", x = bar_start, xend = bar_end, y = bar_y, yend = bar_y, colour = chart_ink[["secondary"]], linewidth = 0.5) +
    annotate("segment", x = c(bar_start, bar_end), xend = c(bar_start, bar_end), y = bar_y - 0.008, yend = bar_y + 0.008, colour = chart_ink[["secondary"]], linewidth = 0.5) +
    annotate("text", x = (bar_start + bar_end) / 2, y = bar_y + 0.024, label = str_c(bar_km, " km"), family = chart_fonts[["text"]], size = map_text_mm[["detail"]], colour = chart_ink[["secondary"]]) +
    geom_point(data = region_landmarks, aes(longitude, latitude), shape = 3, size = 1.8, stroke = 0.6, colour = chart_ink[["muted"]]) +
    geom_text(data = region_landmarks, aes(longitude, latitude, label = landmark), family = chart_fonts[["text"]], fontface = "italic", size = map_text_mm[["detail"]], colour = chart_ink[["muted"]], vjust = 1, nudge_y = -0.015) +
    geom_point(data = region_sites, aes(longitude, latitude, fill = site_group), shape = 21, size = 3.6, colour = "white", stroke = 1.1, show.legend = TRUE) +
    geom_text(data = region_sites, aes(longitude + name_dx, latitude + name_dy, label = site_label, hjust = name_hjust, vjust = name_vjust), family = chart_fonts[["text"]], fontface = "bold", size = map_text_mm[["site"]], colour = chart_ink[["primary"]]) +
    geom_text(data = region_sites, aes(longitude + pollutant_dx, latitude + pollutant_dy, label = pollutants, hjust = pollutant_hjust, vjust = pollutant_vjust), family = chart_fonts[["text"]], size = map_text_mm[["detail"]], colour = chart_ink[["secondary"]]) +
    scale_fill_manual(values = site_group_colours, breaks = names(site_group_colours), limits = names(site_group_colours), name = NULL) +
    coord_quickmap(xlim = c(frame$lon_min, frame$lon_max), ylim = c(frame$lat_min, frame$lat_max), expand = FALSE) +
    labs(x = NULL, y = NULL) +
    theme_aqs(base_size = 10) +
    theme(
      panel.background = element_rect(fill = "#f6f5f0", colour = NA),
      panel.grid.major = element_line(colour = "#e8e6de", linewidth = 0.3),
      panel.grid.major.x = element_line(colour = "#e8e6de", linewidth = 0.3),
      axis.text = element_blank(),
      legend.text = element_text(size = 9, margin = margin(l = 3, r = 12)),
      legend.margin = margin(0, 0, 0, 0),
      legend.box.spacing = unit(8, "pt"),
      plot.margin = margin(0, 10, chart_spacing[["panel_row_gap"]], 0)
    )

  # The group legend sits above the Houston map only, so the two maps keep the same top edge
  if (region_name == "Houston") {
    region_map <- region_map +
      annotate("text", x = frame$lon_max - 0.015, y = 29.6, label = "Galveston Bay →", family = chart_fonts[["text"]], fontface = "italic", size = map_text_mm[["detail"]], colour = chart_ink[["muted"]], hjust = 1)
  } else {
    region_map <- region_map +
      theme(legend.position = "none")
  }

  region_map
}

# Panel widths in km, so both maps keep the same scale side by side
frame_widths_km <- map_frames %>%
  mutate(width_km = (lon_max - lon_min) * km_per_lon_degree((lat_min + lat_max) / 2))

load_chart_fonts()

site_map_header <- chart_header(
  "FIGURE 1C.1  /  CASE-STUDY SITES  /  HARRIS, DALLAS AND TARRANT COUNTIES",
  "Nine monitoring sites in Houston and DFW",
  str_c("16 hourly monitors in three groups. Ship Channel sites are within ", ship_channel_km, " km of the land-cut channel.")
)

site_map_footer <- chart_footer("EPA AQS site coordinates. Both maps use the same scale. Crosses mark landmarks for orientation.")

site_map <- chart_compose(
  site_map_header,
  list(draw_region_map("Houston"), draw_region_map("Dallas-Fort Worth")),
  site_map_footer,
  widths = frame_widths_km$width_km[match(c("Houston", "Dallas-Fort Worth"), frame_widths_km$region)]
)

dir.create(here("figures", "phase1"), recursive = TRUE, showWarnings = FALSE)

site_map_path <- here("figures", "phase1", "case_study_sites.png")

save_started <- Sys.time()

# Saved at the report text width, so the sizes above are the printed sizes
ggsave(site_map_path, site_map, width = 6.5, height = 5.4, dpi = 300)

# ragg only warns when the file is locked (an open viewer or OneDrive syncing), so check the write
stopifnot(
  "case_study_sites.png was written (close any viewer of it and rerun this step)" =
    file.mtime(site_map_path) >= save_started - 2
)