# SETUP ----
library(dplyr)
library(readr)
library(stringr)
library(lubridate)
library(ggplot2)
library(patchwork)
library(here)

source(here("R", "utils.R")) # study_years, region_lookup



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
    site_label == "Park Place" ~ "below",
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
      axis.text = element_blank(),
      plot.margin = margin(0, 4, 0, 4)
    )

  if (region_name == "Houston") {
    region_map <- region_map +
      annotate("text", x = frame$lon_max - 0.015, y = 29.6, label = "Galveston Bay →", family = chart_fonts[["text"]], fontface = "italic", size = map_text_mm[["detail"]], colour = chart_ink[["muted"]], hjust = 1)
  }

  region_map
}

# Panel widths in km, so both maps keep the same scale side by side
frame_widths_km <- map_frames %>%
  mutate(width_km = (lon_max - lon_min) * km_per_lon_degree((lat_min + lat_max) / 2))

load_chart_fonts()

site_map <- (draw_region_map("Houston") + draw_region_map("Dallas-Fort Worth")) +
  plot_layout(
    widths = frame_widths_km$width_km[match(c("Houston", "Dallas-Fort Worth"), frame_widths_km$region)],
    guides = "collect"
  ) +
  plot_annotation(
    title = "Nine monitoring sites in Houston and Dallas-Fort Worth",
    subtitle = "16 hourly monitors in three groups. The Ship Channel sites sit on Houston's industrial east side.",
    caption = "Source: EPA AQS site coordinates. Both maps use the same scale. Crosses mark landmarks for orientation.",
    theme = theme_aqs(base_size = 10) +
      theme(
        plot.title = element_text(margin = margin(b = 3)),
        plot.subtitle = element_text(margin = margin(b = 9)),
        plot.caption = element_text(margin = margin(t = 8)),
        plot.margin = margin(10, 10, 8, 10)
      )
  ) &
  theme(
    legend.position = "top",
    legend.justification = "left",
    legend.text = element_text(size = 9, margin = margin(l = 3, r = 12)),
    legend.margin = margin(0, 0, 0, 0),
    legend.box.spacing = unit(8, "pt")
  )

dir.create(here("figures"), showWarnings = FALSE)

site_map_path <- here("figures", "case_study_sites.png")

save_started <- Sys.time()

# Saved at the report text width, so the sizes above are the printed sizes
ggsave(site_map_path, site_map, width = 6.5, height = 4.25, dpi = 300)

# ragg only warns when the file is locked (an open viewer or OneDrive syncing), so check the write
stopifnot(
  "case_study_sites.png was written (close any viewer of it and rerun this step)" =
    file.mtime(site_map_path) >= save_started - 2
)