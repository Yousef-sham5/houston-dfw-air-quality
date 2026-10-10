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
