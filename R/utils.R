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



# POLLUTANTS ----
pollutant_levels <- c("PM2.5", "Ozone", "NO2", "SO2", "CO")



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



# NAAQS STANDARDS (2a AND 2b) ----
# Primary standards in their own units and forms, shared so 2a and 2b screen with the same levels, rounding and ranks.
# Each site-year is screened on its own, which is not an EPA design value (those average three years). Values are
# rounded as the standard specifies before comparing: ozone truncated to 3 decimals (Appendix U 3(e)), PM2.5 to 0.1
# and 1 (Appendix N 4.3), NO2 and SO2 to whole ppb (Appendices S 4.2(c) and T 4.1(c)) and CO to whole ppm (50.8(d)),
# with halves rounded up
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

stopifnot(
  "Every pollutant has a NAAQS row" = setequal(naaqs$pollutant, pollutant_levels),
  "Each percentile rank table covers 1 to 366 days without gaps" = all(vapply(
    split(percentile_ranks, percentile_ranks$percentile),
    \(t) identical(as.numeric(unlist(Map(seq, t$min_days, t$max_days))), as.numeric(1:366)),
    logical(1)
  )),
  "Every pollutant has one short-term rank rule" =
    setequal(naaqs_ranks$pollutant, pollutant_levels) && all(is.na(naaqs_ranks$fixed_rank) != is.na(naaqs_ranks$percentile))
)



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
# naaqs, naaqs_ranks and percentile_ranks are the tables in NAAQS STANDARDS above
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

# Every script that saves files shares data_dictionary.csv, and 1a, 1d, 1e and 2a share checkpoint_manifest.csv.
# Each replaces only its own rows (matched on key: table or file) and keeps the rows the others wrote, so rerunning
# one script never removes another's rows. Replaced rows keep their place in the file; a script writing for the
# first time adds its rows at the end. Returns the whole updated file
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



# CHART COLOURS, FONTS AND SIZES ----
# Base values for the figure helpers below. Each figure script sets its own fonts and colours in its FIGURE STYLE
# section before drawing. Text uses the ink colours; data colours are kept for the marks
chart_ink <- c(
  primary   = "#0b0b0b",
  secondary = "#52514e",
  muted     = "#898781",
  grid      = "#ecebe6",
  axis      = "#c3c2b7"
)

# National figures: one accent for the series a panel is about, grey for the rest, and a light band for a
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

# One marker shape per group in every figure, so the groups read without colour too: a circle, a square and a triangle.
# Solid marks are the main reading; the open version of the same shape carries a second meaning, such as a site with
# four of five years or weekend hours
site_group_shapes <- c("Houston Ship Channel" = 16, "Houston other" = 15, "Dallas-Fort Worth" = 17)

site_group_open_shapes <- c("Houston Ship Channel" = 1, "Houston other" = 0, "Dallas-Fort Worth" = 2)

# Every figure draws in Arial, checked at the top of each figure script
chart_fonts <- c(
  title = "Arial",
  text  = "Arial",
  mono  = "Arial"
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

# End-of-line marker: a dot with a white ring and its value beside it; shape takes a group's marker. Needs ggplot2
# loaded
chart_end_label <- function(data, x, y, label, colour = chart_fills[["accent"]], hjust = 1, vjust = -1.1, shape = 19) {
  list(
    geom_point(data = data, mapping = aes(.data[[x]], .data[[y]]), inherit.aes = FALSE, size = 1.9, colour = "white", shape = shape),
    geom_point(data = data, mapping = aes(.data[[x]], .data[[y]]), inherit.aes = FALSE, size = 1.2, colour = colour, shape = shape),
    geom_text(
      data = data, mapping = aes(.data[[x]], .data[[y]], label = .data[[label]]), inherit.aes = FALSE,
      family = chart_fonts[["mono"]], size = chart_sizes[["label"]] / .pt, colour = colour, hjust = hjust, vjust = vjust
    )
  )
}



# JOURNAL FIGURE STYLE ----
# Figures laid out like a journal's: boxed panels tagged a, b and so on, a key and a short source line under the
# panels, and no caption, since the report text gives each finding. A script that uses them first sets chart_fonts
# and the colour palettes above to its own values. Needs ggplot2, patchwork and stringr loaded by the calling script

# Printed width a source line may fill: 6.5 inches less the figure margins
caption_width_points <- 448

panel_label <- function(panel_number, panel_name) sprintf("(%s) %s", letters[panel_number], panel_name)

theme_paper <- function() {
  theme_bw(base_size = 8, base_family = chart_fonts[["text"]]) +
    theme(
      text = element_text(colour = chart_ink[["primary"]]),
      plot.background = element_rect(fill = "white", colour = NA),
      plot.margin = margin(0, 8, 10, 0),
      plot.title = element_text(size = 8, face = "bold", hjust = 0, margin = margin(b = 1)),
      plot.subtitle = element_text(size = 7, colour = chart_ink[["secondary"]], hjust = 0, margin = margin(b = 3)),
      panel.border = element_rect(colour = chart_ink[["primary"]], linewidth = 0.4, fill = NA),
      panel.grid.major = element_line(colour = chart_ink[["grid"]], linewidth = 0.2),
      panel.grid.minor = element_blank(),
      axis.ticks = element_line(colour = chart_ink[["primary"]], linewidth = 0.3),
      axis.ticks.length = unit(2, "pt"),
      axis.text = element_text(colour = chart_ink[["primary"]], size = 6.5),
      axis.title = element_text(size = 7),
      strip.background = element_blank(),
      strip.text = element_text(size = 7),
      legend.position = "top",
      legend.justification = "left",
      legend.direction = "horizontal",
      legend.title = element_blank(),
      legend.text = element_text(size = 6.5),
      legend.key.size = unit(8, "pt"),
      legend.margin = margin(0, 0, 2, 0)
    )
}

# One key row per value of row, centred. Marks: square, point (pch in shape; 21 to 25 are outlined), line, thick, dashed,
# tick (a vertical bar) and range (a line through a point)
key_row_points <- 12

figure_key <- function(key) {
  if (!"row" %in% names(key)) key$row <- 1
  if (!"shape" %in% names(key)) key$shape <- 16
  key_rows <- split(key, key$row)
  row_grobs <- lapply(seq_along(key_rows), \(r) {
    items <- key_rows[[r]]
    y <- grid::unit(1, "npc") - grid::unit((r - 0.5) * key_row_points, "pt")
    item_x <- grid::unit(0, "pt")
    parts <- list()
    for (i in seq_len(nrow(items))) {
      left <- item_x
      right <- item_x + grid::unit(12, "pt")
      centre <- item_x + grid::unit(6, "pt")
      line_at <- \(lwd, lty = "solid") {
        grid::segmentsGrob(left, y, right, y, gp = grid::gpar(col = items$colour[i], lwd = lwd, lty = lty, lineend = "butt"))
      }
      point_at <- \(x) grid::pointsGrob(
        x, y, pch = items$shape[i], size = grid::unit(5, "pt"),
        gp = if (items$shape[i] >= 21) {
          grid::gpar(col = chart_ink[["primary"]], fill = items$colour[i], lwd = 0.8)
        } else {
          grid::gpar(col = items$colour[i])
        }
      )
      mark <- switch(
        items$mark[i],
        square = list(grid::rectGrob(
          centre, y, width = grid::unit(7, "pt"), height = grid::unit(7, "pt"), gp = grid::gpar(fill = items$colour[i], col = NA)
        )),
        point = list(point_at(centre)),
        line = list(line_at(1.3)),
        thick = list(line_at(3)),
        dashed = list(line_at(1, "22")),
        tick = list(grid::segmentsGrob(
          centre, y - grid::unit(4, "pt"), centre, y + grid::unit(4, "pt"), gp = grid::gpar(col = items$colour[i], lwd = 1.6)
        )),
        range = list(line_at(1.1), point_at(centre))
      )
      stopifnot("Every key mark is a known kind" = !is.null(mark))
      label <- grid::textGrob(
        items$label[i], x = item_x + grid::unit(16, "pt"), y = y, just = c("left", "centre"),
        gp = grid::gpar(fontfamily = chart_fonts[["text"]], fontsize = chart_sizes[["key"]], col = chart_ink[["primary"]])
      )
      parts <- c(parts, mark, list(label))
      item_x <- item_x + grid::unit(16, "pt") + grid::grobWidth(label) + grid::unit(16, "pt")
    }
    grid::gTree(children = do.call(grid::gList, parts), vp = grid::viewport(x = 0.5, width = item_x - grid::unit(16, "pt")))
  })
  key_row <- patchwork::wrap_elements(full = do.call(grid::grobTree, row_grobs)) + theme(plot.margin = margin(0, 0, 0, 0))
  attr(key_row, "height_pt") <- key_row_points * length(key_rows) + 2
  key_row
}

# Text the reader sees: chemical formulas with subscripts, and true minus signs on negative numbers
pretty_text <- function(x) str_replace_all(x, c("NO2" = "NO₂", "SO2" = "SO₂"))

minus_sign <- function(x) str_replace(x, "^-", "−")

# The panel letter moves out of the title into a bold blue tag on the title line, and the subtitle turns italic. A figure
# with one panel has no letter, and boxed = FALSE leaves round panels such as wind roses without a frame
tag_panel <- function(panel, panel_number, show_tag = TRUE, boxed = TRUE) {
  panel_labs <- get_labs(panel)
  title <- panel_labs$title
  if (show_tag) {
    stopifnot("Each panel title starts with its own letter, in order" = str_starts(title, fixed(sprintf("(%s) ", letters[panel_number]))))
  }
  text_labs <- lapply(Filter(is.character, panel_labs[c("subtitle", "caption")]), pretty_text)
  panel +
    do.call(labs, c(list(title = pretty_text(str_remove(title, "^\\([a-z]\\) ")), tag = if (show_tag) letters[panel_number] else NULL), text_labs)) +
    theme(
      plot.tag = element_text(face = "bold", colour = chart_fills[["accent"]], size = 11, hjust = 0, vjust = 1),
      plot.tag.position = c(0, 1),
      plot.tag.location = "plot",
      plot.title.position = "plot",
      plot.title = element_text(size = 8.5, face = "bold", hjust = 0, margin = margin(t = 1, b = 1, l = 12)),
      plot.subtitle = element_text(size = 7, face = "italic", colour = chart_ink[["secondary"]], hjust = 0, margin = margin(b = 3, l = 12)),
      panel.border = if (boxed) element_rect(colour = "#3A3A3A", linewidth = 0.35, fill = NA) else element_blank()
    )
}

# Text kept a fixed number of points inside the panel frame, whatever its length. x is "left", "right" or a data value,
# y is "top", "bottom" or a data value; at a data value, hjust and vjust place the text as in geom_text. facet, a one-row
# table of facet values, limits the text to that panel
edge_text_pad <- 4

edge_text <- function(label, x, y, hjust = 0.5, vjust = 0.5, size = chart_sizes[["label"]], colour = chart_ink[["secondary"]],
                      fontface = "plain", lineheight = 0.95, pad = edge_text_pad, facet = NULL) {
  purrr::pmap(list(label, x, y, hjust, vjust, colour), \(label, x, y, hjust, vjust, colour) {
    at_edge_x <- is.character(x)
    at_edge_y <- is.character(y)
    stopifnot(
      "x is left, right or a number" = !at_edge_x || x %in% c("left", "right"),
      "y is top, bottom or a number" = !at_edge_y || y %in% c("top", "bottom")
    )
    grob_x <- if (!at_edge_x) grid::unit(0.5, "npc") else if (x == "left") grid::unit(pad, "pt") else grid::unit(1, "npc") - grid::unit(pad, "pt")
    grob_y <- if (!at_edge_y) grid::unit(0.5, "npc") else if (y == "bottom") grid::unit(pad, "pt") else grid::unit(1, "npc") - grid::unit(pad, "pt")
    text_grob <- grid::textGrob(
      label, x = grob_x, y = grob_y,
      hjust = if (!at_edge_x) hjust else if (x == "left") 0 else 1,
      vjust = if (!at_edge_y) vjust else if (y == "bottom") 0 else 1,
      gp = grid::gpar(
        fontfamily = chart_fonts[["text"]], fontsize = size, col = colour, fontface = fontface, lineheight = lineheight
      )
    )
    corners <- list(
      xmin = if (at_edge_x) -Inf else x, xmax = if (at_edge_x) Inf else x,
      ymin = if (at_edge_y) -Inf else y, ymax = if (at_edge_y) Inf else y
    )
    if (is.null(facet)) {
      do.call(annotation_custom, c(list(grob = text_grob), corners))
    } else {
      stopifnot("facet is one row of facet values" = is.data.frame(facet) && nrow(facet) == 1)
      layer(
        data = facet, stat = "identity", position = "identity", geom = GeomCustomAnn, inherit.aes = FALSE,
        params = c(list(grob = text_grob), corners)
      )
    }
  })
}

# A one or two line source note in small grey type, broken where the printed line would pass the figure width
source_points <- 6.5

source_line_points <- 7.8

source_row <- function(note, width_points = caption_width_points) {
  text_width <- \(x) systemfonts::string_width(x, family = chart_fonts[["text"]], size = source_points, res = 72)
  lines <- character(0)
  current <- ""
  for (word in str_split_1(pretty_text(note), " ")) {
    candidate <- if (current == "") word else str_c(current, " ", word)
    if (current != "" && text_width(candidate) > width_points) {
      lines <- c(lines, current)
      current <- word
    } else {
      current <- candidate
    }
  }
  lines <- c(lines, current)
  stopifnot("A source note runs to two lines at most" = length(lines) <= 2)
  row <- wrap_elements(full = grid::textGrob(
    str_c(lines, collapse = "\n"), x = grid::unit(0, "pt"), y = grid::unit(1, "npc"), just = c("left", "top"),
    gp = grid::gpar(
      fontfamily = chart_fonts[["text"]], fontsize = source_points, col = chart_ink[["secondary"]],
      lineheight = source_line_points / (1.2 * source_points)
    )
  )) +
    theme(plot.margin = margin(0, 0, 0, 0))
  attr(row, "height_pt") <- source_line_points * length(lines) + 2
  row
}

# Tagged panels in rows of ncol, then the key if there is one, then the source note. There is no caption: the report text
# gives each finding. Panels listed in free_panels keep their own axis widths; widths sets the column widths
tagged_figure <- function(panels, key = NULL, source_note, ncol = 2, row_weights = NULL, free_panels = integer(0), widths = NULL,
                          width_points = caption_width_points, boxed = TRUE) {
  tagged <- lapply(seq_along(panels), \(i) tag_panel(panels[[i]], i, show_tag = length(panels) > 1, boxed = boxed))
  tagged[free_panels] <- lapply(tagged[free_panels], free)
  n_rows <- ceiling(length(panels) / ncol)
  weights <- if (is.null(row_weights)) rep(1, n_rows) else row_weights
  panel_letters <- LETTERS[seq_along(panels)]
  panel_rows <- vapply(seq_len(n_rows), \(r) {
    row_letters <- panel_letters[(r - 1) * ncol + seq_len(ncol)]
    paste(ifelse(is.na(row_letters), "#", row_letters), collapse = "")
  }, character(1))
  bottom_rows <- list(source_row(source_note, width_points))
  if (!is.null(key)) {
    key$label <- pretty_text(key$label)
    bottom_rows <- c(list(figure_key(key)), bottom_rows)
  }
  bottom_heights <- vapply(bottom_rows, \(row) attr(row, "height_pt"), numeric(1)) + c(rep(4, length(bottom_rows) - 1), 0)
  design <- paste(c(panel_rows, strrep(LETTERS[length(panels) + seq_along(bottom_rows)], ncol)), collapse = "\n")
  wrap_plots(c(tagged, bottom_rows), design = design) +
    plot_layout(heights = grid::unit(c(weights, bottom_heights), c(rep("null", n_rows), rep("pt", length(bottom_rows)))), widths = widths) +
    plot_annotation(theme = theme(plot.margin = margin(8, 8, 6, 8), plot.background = element_rect(fill = "white", colour = NA)))
}

# Saves at the report text width and checks the write, since ragg only warns when a viewer or OneDrive holds the file
save_figure <- function(figure, file_name, height, directory = figures_dir) {
  path <- file.path(directory, file_name)
  started <- Sys.time()
  ggsave(path, figure, width = 6.5, height = height, dpi = 300)
  stopifnot("Each figure was written (close any viewer of it and rerun this step)" = file.mtime(path) >= started - 2)
  invisible(path)
}
