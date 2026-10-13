# Logs rows remaining and rows removed ----
log_step <- function(log, step, data) {
  log %>%
    add_row(
      step = step,
      rows = nrow(data),
      rows_removed = last(log$rows) - nrow(data)
    )
}



# HOUSTON VS DALLAS-FORT WORTH CASE-STUDY COUNTIES ----
region_lookup <- tribble(
  ~county_id, ~region,
  "48-201",   "Houston",
  "48-113",   "Dallas-Fort Worth",
  "48-439",   "Dallas-Fort Worth"
)



# DAILY EVENT MEDIANS ----
# Median value per pollutant, area and day within an event window.
# PM2.5 uses the daily mean; gases use the daily max (both in µg/m³).
event_medians <- function(data, area_col, areas, pollutants, start, end) {
  area_col <- match.arg(area_col, c("state_code", "county_id"))
  
  data %>%
    filter(
      between(date_local, ymd(start), ymd(end)),
      pollutant %in% pollutants
    ) %>%
    mutate(
      county_id = str_sub(site_id, 1, 6),
      area = .data[[area_col]],
      value = if_else(pollutant == "PM2.5", mean_ugm3, max_ugm3)
    ) %>%
    filter(area %in% areas) %>%
    group_by(pollutant, area, date_local) %>%
    summarise(
      median_value = round(median(value), 1),
      n_sites = n_distinct(site_id),
      .groups = "drop"
    )
}



# CHART THEME ----
# Shared look for every figure: white background, hairline grid, left-aligned titles, quiet axes.
# Text uses these ink colours; data colours are kept for the marks
chart_ink <- c(
  primary   = "#0b0b0b",
  secondary = "#52514e",
  muted     = "#898781",
  grid      = "#e1e0d9",
  axis      = "#c3c2b7"
)

# One fixed colour per case-study group, so a group keeps its colour in every figure
site_group_colours <- c(
  "Houston Ship Channel" = "#eb6834",
  "Houston other"        = "#2a78d6",
  "Dallas-Fort Worth"    = "#1baf7a"
)

# Typefaces: Inter Tight for titles, Inter for text, IBM Plex Mono for axis values and small labels
chart_fonts <- c(
  title = "Inter Tight",
  text  = "Inter",
  mono  = "IBM Plex Mono"
)

# Call once before drawing. The fonts are fetched from Google Fonts on first use and kept in the
# user's R cache, so later runs work offline. A font that cannot be fetched falls back to the system sans.
# Saving with these fonts needs the ragg package, which ggsave() uses when it is installed
load_chart_fonts <- function() {
  font_dir <- tools::R_user_dir("epa-aqs-fonts", which = "cache")
  dir.create(font_dir, recursive = TRUE, showWarnings = FALSE)
  cached_fonts <- list.files(font_dir, pattern = "\\.ttf$", full.names = TRUE)
  if (length(cached_fonts) > 0) {
    systemfonts::add_fonts(cached_fonts)
  }
  for (family in chart_fonts) {
    systemfonts::require_font(family, fallback = "sans", dir = font_dir, verbose = FALSE)
  }
}

# Add to any ggplot with + theme_aqs(). Needs ggplot2 loaded by the calling script
theme_aqs <- function(base_size = 11) {
  theme_minimal(base_size = base_size, base_family = chart_fonts[["text"]]) +
    theme(
      text = element_text(colour = chart_ink[["secondary"]]),
      plot.background = element_rect(fill = "white", colour = NA),
      panel.background = element_rect(fill = "white", colour = NA),
      plot.margin = margin(18, 22, 14, 18),
      plot.title.position = "plot",
      plot.caption.position = "plot",
      plot.title = element_text(family = chart_fonts[["title"]], colour = chart_ink[["primary"]], face = "bold", size = rel(1.5), margin = margin(b = 5)),
      plot.subtitle = element_text(colour = chart_ink[["secondary"]], size = rel(0.95), margin = margin(b = 14)),
      plot.caption = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["muted"]], size = rel(0.72), hjust = 0, margin = margin(t = 12)),
      panel.grid.major = element_line(colour = chart_ink[["grid"]], linewidth = 0.3),
      panel.grid.minor = element_blank(),
      panel.spacing = unit(22, "pt"),
      axis.line = element_blank(),
      axis.ticks = element_blank(),
      axis.text = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["muted"]], size = rel(0.8)),
      axis.title = element_text(colour = chart_ink[["secondary"]], size = rel(0.85)),
      axis.title.x = element_text(margin = margin(t = 8)),
      axis.title.y = element_text(margin = margin(r = 8)),
      legend.position = "top",
      legend.justification = "left",
      legend.location = "plot",
      legend.direction = "horizontal",
      legend.title = element_text(colour = chart_ink[["muted"]], size = rel(0.8)),
      legend.text = element_text(colour = chart_ink[["secondary"]], size = rel(0.85)),
      legend.key.size = unit(10, "pt"),
      legend.margin = margin(0, 0, 4, 0),
      strip.text = element_text(colour = chart_ink[["primary"]], face = "bold", size = rel(0.9), hjust = 0, margin = margin(b = 8)),
      strip.background = element_blank()
    )
}
