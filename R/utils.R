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

# AQS local times skip daylight saving, so Texas is always UTC-6. "Etc/GMT+6" is that fixed offset (the name
# reverses the sign). "America/Chicago" would add daylight saving and shift every summer hour
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



# NAAQS ROUNDING ----
# EPA rounds halves up (12.05 becomes 12.1), while round() rounds them to the nearest even digit. The small offset
# stops a value stored as 12.0499999 from rounding down
round_half_up <- function(x, digits = 0) {
  floor(x * 10^digits + 0.5 + 1e-9) / 10^digits
}

truncate_to <- function(x, digits = 0) {
  floor(x * 10^digits + 1e-9) / 10^digits
}



# NAAQS-FORM VALUES (2a AND 2b) ----
# The value of each standard per site-year: the ranked daily value for the short-term standards and the mean of the
# quarterly means for annual PM2.5, rounded as the standard specifies and compared with its level. Annual PM2.5
# keeps only site-years with data in all four quarters, since Appendix N needs every quarter for a complete year.
# naaqs, naaqs_ranks and percentile_ranks are the tables in 2a's CONFIG
naaqs_statistics <- function(site_days, naaqs, naaqs_ranks, percentile_ranks) {
  site_year_ranks <- site_days %>%
    count(pollutant, site_id, year, name = "n_days") %>%
    left_join(naaqs_ranks, by = "pollutant", relationship = "many-to-one") %>%
    left_join(percentile_ranks, by = join_by(percentile, between(n_days, min_days, max_days)), relationship = "many-to-one") %>%
    mutate(value_rank = coalesce(fixed_rank, rank)) %>%
    select(pollutant, site_id, year, n_days, value_rank)

  stopifnot(
    "Every site-year has a rank" = !anyNA(site_year_ranks$value_rank),
    "No rank is beyond the site-year's days" = all(site_year_ranks$value_rank <= site_year_ranks$n_days)
  )

  short_term <- site_days %>%
    arrange(pollutant, site_id, year, desc(value)) %>%
    mutate(value_order = row_number(), .by = c(pollutant, site_id, year)) %>%
    inner_join(site_year_ranks, by = c("pollutant", "site_id", "year"), relationship = "many-to-one") %>%
    filter(value_order == value_rank) %>%
    inner_join(filter(naaqs, standard != "Annual") %>% select(pollutant, standard), by = "pollutant", relationship = "many-to-one") %>%
    select(pollutant, standard, site_id, year, n_days, value)

  pm25_annual <- site_days %>%
    filter(pollutant == "PM2.5") %>%
    mutate(quarter = quarter(date_local)) %>%
    summarise(quarter_mean = mean(value), .by = c(pollutant, site_id, year, quarter)) %>%
    summarise(n_quarters = n(), value = mean(quarter_mean), .by = c(pollutant, site_id, year)) %>%
    mutate(standard = "Annual") %>%
    left_join(select(site_year_ranks, pollutant, site_id, year, n_days), by = c("pollutant", "site_id", "year"), relationship = "one-to-one")

  stopifnot(
    "One short-term value per site-year" = nrow(short_term) == nrow(site_year_ranks),
    "Annual PM2.5 has 1 to 4 quarters per site-year" = all(between(pm25_annual$n_quarters, 1, 4))
  )

  pm25_annual <- pm25_annual %>%
    filter(n_quarters == 4)

  bind_rows(short_term, pm25_annual) %>%
    left_join(select(naaqs, pollutant, standard, level, digits, rounding), by = c("pollutant", "standard"), relationship = "many-to-one") %>%
    mutate(value_rounded = if_else(rounding == "truncate", truncate_to(value, digits), round_half_up(value, digits))) %>%
    mutate(is_above = value_rounded > level) %>%
    select(pollutant, standard, site_id, year, n_days, n_quarters, value, value_rounded, level, is_above)
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



# MONTHLY PROFILES (2a AND 2b) ----
# Typical year from one row per site and calendar month (mean_value, mean_ordinary): the median and middle half across
# sites for each month. group_cols adds groups such as site_group, so the case study and the nation share one rule
monthly_profile <- function(site_calendar_months, group_cols = "pollutant") {
  site_calendar_months %>%
    summarise(
      n_sites = n(),
      median_value = median(mean_value),
      q25_value = quantile(mean_value, 0.25),
      q75_value = quantile(mean_value, 0.75),
      median_ordinary = median(mean_ordinary, na.rm = TRUE),
      .by = all_of(c(group_cols, "month"))
    ) %>%
    arrange(across(all_of(c(group_cols, "month"))))
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

# AQS local times skip daylight saving, so Texas is always 6 hours behind GMT. A 5-hour gap in summer would
# mean daylight saving had been applied
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

# Every script that saves files shares data_dictionary.csv, and 1a, 1d, 1e and 2a share checkpoint_manifest.csv. Each replaces only its own rows
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
# Shared look for every figure: white background, faint horizontal grid, quiet axes, numbers in a monospace face.
# Text uses these ink colours; data colours are kept for the marks
chart_ink <- c(
  primary   = "#0b0b0b",
  secondary = "#52514e",
  muted     = "#898781",
  grid      = "#ecebe6",
  axis      = "#c3c2b7"
)

# National figures: one teal accent for the series the title is about, grey for the rest, and a light band for a
# highlighted period. Case-study figures use site_group_colours instead
chart_fills <- c(
  accent = "#0e7c86",
  other  = "#b9b8b1",
  band   = "#f4f3ef"
)

# One fixed colour per case-study group, so a group keeps its colour in every figure
site_group_colours <- c(
  "Houston Ship Channel" = "#eb6834",
  "Houston other"        = "#2a78d6",
  "Dallas-Fort Worth"    = "#1baf7a"
)

# Typefaces, bundled in fonts/ under the SIL Open Font Licence: Inter Tight SemiBold for titles, Inter for text and
# IBM Plex Mono for numbers and small labels. The "AQS" names keep them apart from any installed copy, which
# systemfonts would refuse to shadow
chart_fonts <- c(
  title = "AQS Inter Tight",
  text  = "AQS Inter",
  mono  = "AQS Plex Mono"
)

# Vertical spacing in points, shared by every figure so headers, panels and footers keep the same rhythm
chart_spacing <- c(
  kicker_to_title    = 8,
  title_to_subtitle  = 5,
  subtitle_to_key    = 10,
  subtitle_to_rule   = 12,
  rule_to_panels     = 18,
  panel_kicker_gap   = 3,
  panel_title_gap    = 10,
  panel_row_gap      = 18,
  panels_to_footer   = 0,
  footer_rule_to_text = 7
)

# Text sizes in points
chart_sizes <- c(
  kicker      = 7,
  title       = 18,
  subtitle    = 9,
  key         = 7.5,
  panel_title = 10.5,
  axis        = 6.8,
  label       = 7,
  footer      = 6.6
)

# Call once before drawing. Registers the bundled font files, then checks that each name resolves to them rather than
# to a fallback. Registered fonts only draw on ragg devices: ggsave() uses ragg, and RStudio needs Graphics backend AGG
load_chart_fonts <- function() {
  stopifnot("ragg is installed, since the bundled fonts only draw on ragg devices" = requireNamespace("ragg", quietly = TRUE))
  font_files <- c(
    title_plain = here("fonts", "inter-tight", "InterTight-SemiBold.ttf"),
    title_bold  = here("fonts", "inter-tight", "InterTight-Bold.ttf"),
    text_plain  = here("fonts", "inter", "Inter-Regular.ttf"),
    text_bold   = here("fonts", "inter", "Inter-SemiBold.ttf"),
    text_italic = here("fonts", "inter", "Inter-Italic.ttf"),
    text_bolditalic = here("fonts", "inter", "Inter-SemiBoldItalic.ttf"),
    mono_plain  = here("fonts", "ibm-plex-mono", "IBMPlexMono-Regular.ttf"),
    mono_bold   = here("fonts", "ibm-plex-mono", "IBMPlexMono-Medium.ttf")
  )
  stopifnot("Chart font files are in fonts/" = all(file.exists(font_files)))
  systemfonts::register_font(chart_fonts[["title"]], plain = font_files[["title_plain"]], bold = font_files[["title_bold"]])
  systemfonts::register_font(
    chart_fonts[["text"]],
    plain = font_files[["text_plain"]],
    bold = font_files[["text_bold"]],
    italic = font_files[["text_italic"]],
    bolditalic = font_files[["text_bolditalic"]]
  )
  systemfonts::register_font(chart_fonts[["mono"]], plain = font_files[["mono_plain"]], bold = font_files[["mono_bold"]])
  resolved <- c(
    title = systemfonts::match_fonts(chart_fonts[["title"]])$path,
    text = systemfonts::match_fonts(chart_fonts[["text"]])$path,
    mono = systemfonts::match_fonts(chart_fonts[["mono"]])$path
  )
  stopifnot(
    "Each chart font resolves to its bundled file" =
      identical(normalizePath(unname(resolved)), normalizePath(unname(font_files[c("title_plain", "text_plain", "mono_plain")])))
  )
}

# Add to any ggplot with + theme_aqs(). The plot title is styled as a small teal kicker ("01  SITES REPORTING") and
# the subtitle as the panel title. Needs ggplot2 loaded by the calling script
theme_aqs <- function(base_size = 9) {
  theme_minimal(base_size = base_size, base_family = chart_fonts[["text"]]) +
    theme(
      text = element_text(colour = chart_ink[["secondary"]]),
      plot.background = element_rect(fill = "white", colour = NA),
      panel.background = element_rect(fill = "white", colour = NA),
      plot.margin = margin(0, 14, chart_spacing[["panel_row_gap"]], 0),
      plot.title.position = "plot",
      plot.caption.position = "plot",
      plot.title = element_text(
        family = chart_fonts[["mono"]], colour = chart_fills[["accent"]], size = chart_sizes[["kicker"]],
        margin = margin(b = chart_spacing[["panel_kicker_gap"]])
      ),
      plot.subtitle = element_text(
        family = chart_fonts[["title"]], colour = chart_ink[["primary"]], size = chart_sizes[["panel_title"]],
        margin = margin(b = chart_spacing[["panel_title_gap"]])
      ),
      plot.caption = element_text(colour = chart_ink[["muted"]], size = chart_sizes[["footer"]], hjust = 0, margin = margin(t = 12)),
      panel.grid.major = element_line(colour = chart_ink[["grid"]], linewidth = 0.25),
      panel.grid.major.x = element_blank(),
      panel.grid.minor = element_blank(),
      panel.spacing = unit(22, "pt"),
      axis.line = element_blank(),
      axis.ticks = element_blank(),
      axis.text = element_text(family = chart_fonts[["mono"]], colour = chart_ink[["muted"]], size = chart_sizes[["axis"]]),
      axis.title = element_text(colour = chart_ink[["secondary"]], size = rel(0.9)),
      axis.title.x = element_text(margin = margin(t = 8)),
      axis.title.y = element_text(margin = margin(r = 8)),
      legend.position = "top",
      legend.justification = "left",
      legend.location = "plot",
      legend.direction = "horizontal",
      legend.title = element_text(colour = chart_ink[["muted"]], size = rel(0.85)),
      legend.text = element_text(colour = chart_ink[["secondary"]], size = rel(0.9)),
      legend.key.size = unit(10, "pt"),
      legend.margin = margin(0, 0, 4, 0),
      strip.text = element_text(
        family = chart_fonts[["title"]], colour = chart_ink[["primary"]], size = rel(1.05), hjust = 0, margin = margin(b = 8)
      ),
      strip.background = element_blank()
    )
}

# Top row of a figure: a teal monospace kicker, the title, an optional grey subtitle (use "\n" to break lines), an
# optional key and a hairline rule. The key is a table with columns mark ("dot", "square" or "bar"), colour and label,
# drawn as one row under the subtitle. Its height is fixed in points from chart_spacing, so chart_compose() can give it
# exactly that space. Its own plot margin is zero, since a margin on a full-width row would widen the edges of every panel
chart_header <- function(kicker, title, subtitle = NULL, key = NULL) {
  line_pt <- function(size, lines = 1, leading = 1.25) size * (1 + leading * (lines - 1))
  subtitle_lines <- if (is.null(subtitle)) 0 else lengths(strsplit(subtitle, "\n"))
  title_top <- line_pt(chart_sizes[["kicker"]]) + chart_spacing[["kicker_to_title"]]
  subtitle_top <- title_top + line_pt(chart_sizes[["title"]]) + chart_spacing[["title_to_subtitle"]]
  text_bottom <- if (subtitle_lines == 0) title_top + line_pt(chart_sizes[["title"]]) else
    subtitle_top + line_pt(chart_sizes[["subtitle"]], subtitle_lines)
  key_top <- text_bottom + chart_spacing[["subtitle_to_key"]]
  if (!is.null(key)) {
    text_bottom <- key_top + chart_sizes[["key"]]
  }
  rule_y <- text_bottom + chart_spacing[["subtitle_to_rule"]]
  text_grob <- function(label, top, family, size, colour) {
    grid::textGrob(
      label, x = grid::unit(0, "pt"), y = grid::unit(1, "npc") - grid::unit(top, "pt"), just = c("left", "top"),
      gp = grid::gpar(fontfamily = family, fontsize = size, col = colour, lineheight = 1.25)
    )
  }
  header_parts <- list(
    text_grob(kicker, 0, chart_fonts[["mono"]], chart_sizes[["kicker"]], chart_fills[["accent"]]),
    text_grob(title, title_top, chart_fonts[["title"]], chart_sizes[["title"]], chart_ink[["primary"]]),
    grid::segmentsGrob(
      x0 = grid::unit(0, "npc"), x1 = grid::unit(1, "npc"),
      y0 = grid::unit(1, "npc") - grid::unit(rule_y, "pt"), y1 = grid::unit(1, "npc") - grid::unit(rule_y, "pt"),
      gp = grid::gpar(col = chart_ink[["primary"]], lwd = 0.6)
    )
  )
  if (subtitle_lines > 0) {
    header_parts <- c(header_parts, list(
      text_grob(subtitle, subtitle_top, chart_fonts[["text"]], chart_sizes[["subtitle"]], chart_ink[["secondary"]])
    ))
  }
  if (!is.null(key)) {
    header_parts <- c(header_parts, chart_key_parts(key, key_top))
  }
  header <- patchwork::wrap_elements(full = do.call(grid::grobTree, header_parts)) + theme(plot.margin = margin(0, 0, 0, 0))
  attr(header, "height_pt") <- rule_y + chart_spacing[["rule_to_panels"]]
  header
}

# The key row of chart_header(): each item is a mark (a dot, or a short vertical bar for a range) and its label, set one
# after another from the left edge. Positions are grid units, so each label's width is measured in its own font
chart_key_parts <- function(key, top) {
  key_y <- grid::unit(1, "npc") - grid::unit(top + chart_sizes[["key"]] / 2, "pt")
  item_x <- grid::unit(0, "pt")
  parts <- list()
  for (i in seq_len(nrow(key))) {
    mark_x <- item_x + grid::unit(3, "pt")
    mark <- if (key$mark[i] == "dot") {
      grid::pointsGrob(mark_x, key_y, pch = 16, size = grid::unit(7, "pt"), gp = grid::gpar(col = key$colour[i]))
    } else if (key$mark[i] == "square") {
      grid::rectGrob(mark_x, key_y, width = grid::unit(7, "pt"), height = grid::unit(7, "pt"), gp = grid::gpar(fill = key$colour[i], col = NA))
    } else {
      grid::segmentsGrob(
        mark_x, key_y - grid::unit(4, "pt"), mark_x, key_y + grid::unit(4, "pt"),
        gp = grid::gpar(col = key$colour[i], lwd = 1.8, lineend = "butt")
      )
    }
    label <- grid::textGrob(
      key$label[i], x = item_x + grid::unit(11, "pt"), y = key_y, just = c("left", "centre"),
      gp = grid::gpar(fontfamily = chart_fonts[["text"]], fontsize = chart_sizes[["key"]], col = chart_ink[["secondary"]])
    )
    parts <- c(parts, list(mark, label))
    item_x <- item_x + grid::unit(11, "pt") + grid::grobWidth(label) + grid::unit(20, "pt")
  }
  parts
}

# Bottom row of a figure: a hairline rule, a teal "SOURCE" label and the source note (use "\n" to break lines)
chart_footer <- function(note) {
  note_lines <- lengths(strsplit(note, "\n"))
  text_top <- chart_spacing[["panels_to_footer"]] + chart_spacing[["footer_rule_to_text"]]
  footer_parts <- list(
    grid::segmentsGrob(
      x0 = grid::unit(0, "npc"), x1 = grid::unit(1, "npc"),
      y0 = grid::unit(1, "npc") - grid::unit(chart_spacing[["panels_to_footer"]], "pt"),
      y1 = grid::unit(1, "npc") - grid::unit(chart_spacing[["panels_to_footer"]], "pt"),
      gp = grid::gpar(col = chart_ink[["axis"]], lwd = 0.5)
    ),
    grid::textGrob(
      "SOURCE", x = grid::unit(0, "pt"), y = grid::unit(1, "npc") - grid::unit(text_top, "pt"), just = c("left", "top"),
      gp = grid::gpar(fontfamily = chart_fonts[["mono"]], fontsize = chart_sizes[["kicker"]] - 0.5, col = chart_fills[["accent"]])
    ),
    grid::textGrob(
      note, x = grid::unit(42, "pt"), y = grid::unit(1, "npc") - grid::unit(text_top, "pt"), just = c("left", "top"),
      gp = grid::gpar(fontfamily = chart_fonts[["text"]], fontsize = chart_sizes[["footer"]], col = chart_ink[["muted"]], lineheight = 1.35)
    )
  )
  footer <- patchwork::wrap_elements(full = do.call(grid::grobTree, footer_parts)) + theme(plot.margin = margin(0, 0, 0, 0))
  attr(footer, "height_pt") <- text_top + chart_sizes[["footer"]] * (1 + 1.35 * (note_lines - 1)) + 4
  footer
}

# Lays out a figure as one flat grid: the header across the top, the panels in rows of ncol, and the footer across the
# bottom. Header and footer get their exact heights and the panels share the rest. A flat grid is used because
# patchwork gives nested layouts their own default margin, which would break the shared spacing
chart_compose <- function(header, panels, footer, ncol = 2, widths = NULL) {
  n_rows <- ceiling(length(panels) / ncol)
  panel_letters <- LETTERS[seq_along(panels) + 1]
  panel_rows <- vapply(seq_len(n_rows), \(r) {
    row_letters <- panel_letters[(r - 1) * ncol + seq_len(ncol)]
    paste(ifelse(is.na(row_letters), "#", row_letters), collapse = "")
  }, character(1))
  design <- paste(c(strrep("A", ncol), panel_rows, strrep(LETTERS[length(panels) + 2], ncol)), collapse = "\n")
  row_heights <- grid::unit(
    c(attr(header, "height_pt"), rep(1, n_rows), attr(footer, "height_pt")),
    c("pt", rep("null", n_rows), "pt")
  )
  wrap_plots(c(list(header), panels, list(footer)), design = design) +
    plot_layout(heights = row_heights, widths = widths) +
    plot_annotation(theme = theme(plot.margin = margin(22, 22, 14, 22), plot.background = element_rect(fill = "white", colour = NA)))
}

# End-of-line marker: a dot with a white ring and a monospace value beside it. Needs ggplot2 loaded
chart_end_label <- function(data, x, y, label, colour = chart_fills[["accent"]], hjust = 1, vjust = -1.1) {
  list(
    geom_point(data = data, mapping = aes(.data[[x]], .data[[y]]), inherit.aes = FALSE, size = 1.9, colour = "white"),
    geom_point(data = data, mapping = aes(.data[[x]], .data[[y]]), inherit.aes = FALSE, size = 1.2, colour = colour),
    geom_text(
      data = data, mapping = aes(.data[[x]], .data[[y]], label = .data[[label]]), inherit.aes = FALSE,
      family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt, colour = colour, hjust = hjust, vjust = vjust
    )
  )
}
