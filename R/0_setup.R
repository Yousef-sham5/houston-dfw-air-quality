# Installs/Updates required packages
pkgs <- c(
  "dplyr", "readr", "tidyr", "stringr", "purrr", "janitor", "lubridate", "here", "lobstr",
  "ggplot2", "scales", "naniar", "patchwork", "corrplot", "ragg", "systemfonts", "openair",
  "MASS", "moments", "nortest", "fitdistrplus", "extRemes", "trend",
  "broom", "car",
  "knitr", "rmarkdown", "tinytex", "kableExtra", "renv"
)

missing_pkgs <- setdiff(pkgs, rownames(installed.packages()))

if (length(missing_pkgs) > 0) {
  install.packages(missing_pkgs)
}

min_versions <- c(dplyr = "1.2.0", tidyr = "1.3.0", ggplot2 = "3.5.0", systemfonts = "1.2.0")

outdated_pkgs <- names(min_versions)[
  vapply(names(min_versions), \(pkg) packageVersion(pkg) < min_versions[[pkg]], logical(1))
]

if (length(outdated_pkgs) > 0) {
  install.packages(outdated_pkgs)
}

if (!tinytex::is_tinytex()) {
  tinytex::install_tinytex()
}
