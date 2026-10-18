# Logs rows remaining and rows removed ----
log_step <- function(log, step, data) {
  log %>%
    add_row(
      step = step,
      rows = nrow(data),
      rows_removed = last(log$rows) - nrow(data)
    )
}



# STUDY PERIOD AND TIME ZONE ----
study_years <- 2021:2025

# AQS local times are local standard time all year, so Texas sits at a fixed UTC-6. "Etc/GMT+6" is that fixed
# offset (this naming scheme reverses the sign). A zone such as "America/Chicago" would apply daylight saving time
# and shift every summer hour
standard_time_zone <- "Etc/GMT+6"



# HOUSTON VS DALLAS-FORT WORTH CASE-STUDY COUNTIES ----
region_lookup <- tribble(
  ~county_id, ~region,
  "48-201",   "Houston",
  "48-113",   "Dallas-Fort Worth",
  "48-439",   "Dallas-Fort Worth"
)



# CALENDAR COLUMNS ----
# Weekday, weekend and meteorological season from date_local, so the daily, hourly and weather tables group the
# same way. Winter is December to February
add_calendar_columns <- function(data) {
  data <- data %>%
    mutate(day_of_week = wday(date_local, label = TRUE, week_start = 1, locale = "C"))

  data <- data %>%
    mutate(is_weekend = day_of_week %in% c("Sat", "Sun"))

  data <- data %>%
    mutate(month_num = month(date_local))

  data <- data %>%
    mutate(
      season = case_when(
        month_num %in% c(12, 1, 2) ~ "Winter",
        month_num %in% 3:5 ~ "Spring",
        month_num %in% 6:8 ~ "Summer",
        month_num %in% 9:11 ~ "Autumn"
      )
    )

  data <- data %>%
    mutate(season = factor(season, levels = c("Winter", "Spring", "Summer", "Autumn")))

  data <- data %>%
    select(-month_num)

  first_day_of_week <- data %>%
    filter(date_local == make_date(min(study_years), 1, 1)) %>%
    distinct(day_of_week) %>%
    pull(day_of_week)

  stopifnot(
    "No missing calendar fields" = !anyNA(data$day_of_week) && !anyNA(data$season),
    "Weekday labels run Mon to Sun" =
      identical(levels(data$day_of_week), c("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")),
    "2021-01-01 is a Friday" = identical(as.character(first_day_of_week), "Fri")
  )

  data
}



# GAS UNIT CONVERSION ----
# Ideal-gas molar volume at 25 °C and 1 atm, used to convert ppb to µg/m³
r_gas <- 8.31446261815324 # J/(mol K), CODATA 2017
t_ref <- 298.15           # K
p_ref <- 101325           # Pa

molar_volume <- 1000 * r_gas * t_ref / p_ref # L/mol



# EPA REFERENCE TABLES ----
# EPA AQS methods reference table (FRM/FEM designations, instrument ranges, units). Method codes are padded to
# 3 characters so leading zeros survive. Needs janitor loaded by the calling script
read_methods_ref <- function() {
  here("data", "reference", "methods_all.csv") %>%
    read_csv(col_types = cols(.default = col_character())) %>%
    clean_names() %>%
    mutate(parameter_code = as.integer(parameter_code)) %>%
    mutate(method_code = str_pad(method_code, width = 3, pad = "0"))
}

# AQS qualifier codes by type, from EPA's qualifier table
aqs_qualifier_types <- bind_rows(
  tibble(
    qualifier = c(as.character(1:9), "MD", "ND", "SQ", "V", "LJ"),
    qualifier_type = "Quality assurance"
  ),
  tibble(
    qualifier = c("RA", "RB", "RC", "RF", "RT", "E"),
    qualifier_type = "Request exclusion"
  ),
  tibble(
    qualifier = c("IA", "IB", "IL", "J", "A"),
    qualifier_type = "Informational"
  )
)



# EVENT WINDOWS ----
# events.csv with its dates parsed and checked, one row per event row. Read as text so Excel-stripped leading
# zeros in the state and county codes are caught
read_events <- function() {
  events_raw <- here("data", "reference", "events.csv") %>%
    read_csv(col_types = cols(.default = col_character()))

  events <- events_raw %>%
    mutate(start_date = ymd(start_date)) %>%
    mutate(end_date = ymd(end_date))

  stopifnot(
    "readr reported problems in events.csv" = nrow(problems(events_raw)) == 0,
    "Event dates parse as yyyy-mm-dd" = !anyNA(events$start_date) && !anyNA(events$end_date),
    "Event windows end on or after they start" = all(events$end_date >= events$start_date),
    "Event state codes are 2 digits (check for Excel-stripped zeros)" =
      all(str_detect(events$state_code, "^\\d{2}$")),
    "Event county codes are 3 digits (check for Excel-stripped zeros)" =
      all(str_detect(events$event_county, "^\\d{3}$"), na.rm = TRUE)
  )

  events
}

# One row per event row and pollutant, from the semicolon-separated pollutants column. "all" stands for every pollutant
split_event_pollutants <- function(events) {
  events %>%
    separate_longer_delim(pollutants, delim = ";") %>%
    mutate(event_pollutant = str_trim(pollutants)) %>%
    select(-pollutants)
}



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

# The same medians as a table with one column per area, for reading an event day by day
event_median_table <- function(data, area_col, areas, pollutants, start, end) {
  data %>%
    event_medians(area_col, areas, pollutants, start, end) %>%
    select(-n_sites) %>%
    pivot_wider(names_from = area, values_from = median_value) %>%
    arrange(pollutant, date_local)
}



# HOURLY ZIP FILES (1d AND 1e) ----
# The 24 columns EPA documents for hourly files (AirData file formats, section 6.2), shared by the pollutant
# and weather files
aqs_hourly_columns <- c(
  "State Code",
  "County Code",
  "Site Num",
  "Parameter Code",
  "POC",
  "Latitude",
  "Longitude",
  "Datum",
  "Parameter Name",
  "Date Local",
  "Time Local",
  "Date GMT",
  "Time GMT",
  "Sample Measurement",
  "Units of Measure",
  "MDL",
  "Uncertainty",
  "Qualifier",
  "Method Type",
  "Method Code",
  "Method Name",
  "State Name",
  "County Name",
  "Date of Last Change"
)

# The 16 columns later steps use (8 of 24 are never parsed); codes stay text so leading zeros survive.
# Latitude, longitude and the GMT columns are needed for the location and time-zone checks
aqs_hourly_col_spec <- cols_only(
  `State Code`         = col_character(),
  `County Code`        = col_character(),
  `Site Num`           = col_character(),
  `Parameter Code`     = col_integer(),
  `POC`                = col_integer(),
  `Latitude`           = col_double(),
  `Longitude`          = col_double(),
  `Date Local`         = col_date(),
  `Time Local`         = col_character(),
  `Date GMT`           = col_date(),
  `Time GMT`           = col_character(),
  `Sample Measurement` = col_double(),
  `Units of Measure`   = col_character(),
  `MDL`                = col_double(),
  `Qualifier`          = col_character(),
  `Method Code`        = col_character()
)

# Read the first lines of a zipped CSV without unzipping the whole file
read_first_lines <- function(zip_path, n) {
  csv_name <- str_replace(basename(zip_path), "\\.zip$", ".csv")
  con <- unz(zip_path, csv_name)
  on.exit(close(con))
  readLines(con, n = n)
}

read_header <- function(zip_path) {
  zip_path %>%
    read_first_lines(n = 1) %>%
    scan(text = ., what = "", sep = ",", quiet = TRUE)
}

# Keep the rows of the case-study monitors (site_id and parameter_code). Non-Texas rows are dropped first
# (cheap text comparison) so site IDs are only built for Texas rows
keep_case_study_rows <- function(chunk, monitors) {
  chunk %>%
    filter(`State Code` == "48") %>%
    mutate(site_id = str_c(`State Code`, `County Code`, `Site Num`, sep = "-")) %>%
    semi_join(monitors, by = c("site_id", "Parameter Code" = "parameter_code"))
}

# Read one zip in 1-million-row chunks, keep only the case-study rows and save them to out_dir with the number of
# rows read and the zip's size and modification time. The saved file is reused while the zip is unchanged, so a
# crash resumes where it stopped and a rerun skips the full read. A changed zip is read again
filter_case_study_zip <- function(zip_path, out_dir, monitors) {
  out_path <- file.path(out_dir, str_replace(basename(zip_path), "\\.zip$", ".rds"))

  zip_size <- file.size(zip_path)

  zip_mtime <- as.numeric(file.mtime(zip_path))

  if (file.exists(out_path)) {
    saved <- read_rds(out_path)
    if (identical(saved$zip_size, zip_size) && identical(saved$zip_mtime, zip_mtime)) {
      return(out_path)
    }
  }

  rows_read <- 0

  filtered_rows <- read_csv_chunked(
    zip_path,
    DataFrameCallback$new(\(chunk, pos) {
      stopifnot("readr reported parsing problems" = nrow(problems(chunk)) == 0)
      rows_read <<- rows_read + nrow(chunk)
      keep_case_study_rows(chunk, monitors)
    }),
    chunk_size = 1e6,
    col_types = aqs_hourly_col_spec
  )

  write_rds(
    list(rows_read = rows_read, data = filtered_rows, zip_size = zip_size, zip_mtime = zip_mtime),
    out_path,
    compress = "gz"
  )

  rm(filtered_rows)
  invisible(gc())

  out_path
}

# Under local standard time, Texas (UTC-6) is always 6 hours behind GMT. Daylight saving time would show up as a
# 5-hour gap in summer
check_local_standard_time <- function(data) {
  time_check <- data %>%
    select(date_local, time_local, date_gmt, time_gmt) %>%
    mutate(
      local_time = ymd_hm(str_c(date_local, " ", time_local), tz = "UTC"),
      gmt_time = ymd_hm(str_c(date_gmt, " ", time_gmt), tz = "UTC"),
      gmt_minus_local_hours = as.numeric(difftime(gmt_time, local_time, units = "hours"))
    )

  time_check %>%
    count(gmt_minus_local_hours) %>%
    print()

  stopifnot(
    "Every timestamp parses" = !anyNA(time_check$local_time) && !anyNA(time_check$gmt_time),
    "Every time is on the hour" = all(str_detect(data$time_local, "^\\d{2}:00$")),
    "GMT is always 6 hours ahead (local standard time, no daylight saving)" =
      all(time_check$gmt_minus_local_hours == 6)
  )

  invisible(NULL)
}



# SAVE CHECKPOINTS, RECORDS, DICTIONARY AND MANIFEST ----
# Each table in a named list goes to dir as <name>.rds (gz), is read back and must be identical to the object in
# memory. Returns the file paths
save_checkpoints <- function(checkpoint, dir) {
  paths <- file.path(dir, str_c(names(checkpoint), ".rds"))

  for (i in seq_along(checkpoint)) {
    write_rds(checkpoint[[i]], paths[i], compress = "gz")
  }

  reloaded <- lapply(paths, read_rds)

  stopifnot(
    "Saved files reload identical to the objects in memory" = identical(unname(reloaded), unname(checkpoint))
  )

  paths
}

# Records of a run that no later script reads are saved as CSV, so they open in any editor and on GitHub
save_records <- function(records, dir) {
  paths <- file.path(dir, str_c(names(records), ".csv"))

  for (i in seq_along(records)) {
    write_csv(records[[i]], paths[i])
  }

  rows_on_disk <- vapply(
    paths,
    \(path) nrow(read_csv(path, col_types = cols(.default = col_character()))),
    integer(1)
  )

  stopifnot(
    "Every record file holds all of its rows" = all(rows_on_disk == vapply(records, nrow, integer(1)))
  )

  invisible(paths)
}

# One dictionary row per saved column, with its type and description. A saved column without a description, or
# a description of a column that was not saved, stops the script
document_tables <- function(saved_tables, descriptions) {
  saved_columns <- tibble(
    table = rep(names(saved_tables), times = lengths(saved_tables)),
    column = unlist(lapply(saved_tables, names), use.names = FALSE),
    type = unlist(lapply(saved_tables, \(df) vapply(df, \(x) class(x)[1], character(1))), use.names = FALSE)
  )

  undocumented_columns <- saved_columns %>%
    anti_join(descriptions, by = c("table", "column"))

  stale_descriptions <- descriptions %>%
    anti_join(saved_columns, by = c("table", "column"))

  if (nrow(undocumented_columns) > 0 || nrow(stale_descriptions) > 0) {
    print(undocumented_columns)
    print(stale_descriptions)
  }

  stopifnot(
    "Every saved column is in the data dictionary" = nrow(undocumented_columns) == 0,
    "The data dictionary lists no columns that were not saved" = nrow(stale_descriptions) == 0
  )

  saved_columns %>%
    left_join(descriptions, by = c("table", "column"), relationship = "one-to-one")
}

# File size and checksum of each checkpoint. GitHub rejects files over 100 MiB. The CSV records stay out of the
# manifest, since Git may change their line endings and with them the checksum
github_limit_mib <- 100

manifest_rows <- function(checkpoint, paths) {
  tibble(
    file = basename(paths),
    rows = vapply(checkpoint, nrow, integer(1)),
    columns = vapply(checkpoint, ncol, integer(1)),
    size_mib = round(file.size(paths) / 2^20, 1),
    md5 = unname(tools::md5sum(paths))
  ) %>%
    mutate(under_github_limit = size_mib < github_limit_mib)
}

data_dictionary_path <- here("data", "processed", "data_dictionary.csv")

manifest_path <- here("data", "processed", "checkpoint_manifest.csv")

manifest_col_types <- cols(
  file               = col_character(),
  rows               = col_integer(),
  columns            = col_integer(),
  size_mib           = col_double(),
  md5                = col_character(),
  under_github_limit = col_logical()
)

# 1a, 1d and 1e share data_dictionary.csv and checkpoint_manifest.csv. Each script replaces only its own rows
# (matched on key: table or file) and keeps the rows the others wrote, so rerunning one script never removes
# another's rows. Replaced rows keep their place in the file; a script writing for the first time adds its rows
# at the end. Returns the whole updated file
replace_own_rows <- function(new_rows, path, key, col_types) {
  if (!file.exists(path)) {
    write_csv(new_rows, path)
    return(invisible(new_rows))
  }

  old_rows <- read_csv(path, col_types = col_types)

  first_own_row <- match(TRUE, old_rows[[key]] %in% new_rows[[key]])

  if (is.na(first_own_row)) {
    updated_rows <- bind_rows(old_rows, new_rows)
  } else {
    rows_before <- old_rows %>%
      slice_head(n = first_own_row - 1)
    rows_after <- old_rows %>%
      slice_tail(n = nrow(old_rows) - first_own_row) %>%
      filter(!.data[[key]] %in% new_rows[[key]])
    updated_rows <- bind_rows(rows_before, new_rows, rows_after)
  }

  write_csv(updated_rows, path)

  invisible(updated_rows)
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
