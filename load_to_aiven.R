# Load the published CSV subset into an Aiven PostgreSQL database through a
# manually configured Windows ODBC data source.

# Find the path of this file in the three supported execution modes:
# Rscript exposes --file=, source() stores the path as `ofile`, and RStudio's
# Run/Source commands expose the active saved document through rstudioapi.
script_path <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) == 1) return(sub("^--file=", "", file_arg))

  # This is the most reliable path when the script is called by source().
  source_paths <- vapply(
    sys.frames(),
    function(frame) if (is.null(frame$ofile)) "" else frame$ofile,
    character(1)
  )
  source_paths <- source_paths[nzchar(source_paths)]
  if (length(source_paths)) return(tail(source_paths, 1))

  # When RStudio evaluates a line or the whole document with Run, there may
  # be no source frame. Ask the active RStudio document for its saved path.
  if (requireNamespace("rstudioapi", quietly = TRUE) &&
      rstudioapi::isAvailable()) {
    active_path <- rstudioapi::getActiveDocumentContext()$path
    if (length(active_path) == 1 && !is.na(active_path) &&
        nzchar(active_path)) {
      return(active_path)
    }
  }

  stop(
    "Cannot determine the script location. Save load_to_aiven.R first, ",
    "then use Source or Run from RStudio, or run it with Rscript."
  )
}

# The downloaded rwe_tutorial folder is self-contained. All paths below are
# resolved relative to the folder containing this script, not the user's
# current working directory.
project_root <- dirname(normalizePath(script_path(), mustWork = TRUE))

# CSV files are distributed in the raw_data folder next to this script.
data_dir <- file.path(project_root, "raw_data")

# All users load into the same teaching schema.
schema_name <- "rwe"

# This is the fixed Windows ODBC User DSN configured in the instructions.
# The DSN stores the Aiven host, port, database, TLS mode, and CA certificate.
dsn_name <- "RWE_AIVEN_POSTGRES"

# When TRUE, every table in the teaching schema is dropped before loading, so
# all tables are reloaded from the CSV files. Keep FALSE for normal use.
delete_all_existing_tables <- FALSE

# Fail early with a clear message if the downloaded data folder is missing.
if (!dir.exists(data_dir)) stop("CSV directory not found: ", data_dir)

# Check that the packages needed for database access are installed.
if (!requireNamespace("DBI", quietly = TRUE)) {
  stop("Package DBI is required. Install it with install.packages('DBI').")
}
if (!requireNamespace("odbc", quietly = TRUE)) {
  stop("Package odbc is required. Install it with install.packages('odbc').")
}

# These are the tables included in the published teaching subset. The order
# loads dimensions before event tables and makes the console output easier to
# follow; no foreign keys are created by this loader.
table_order <- c(
  "patients.csv", "icd10cm_dictionary.csv", "death.csv", "payers.csv", "encounters.csv",
  "conditions.csv", "observations.csv", "medications.csv",
  "payer_transitions.csv", "atc_dictionary.csv"
)
files <- file.path(data_dir, table_order)

# Stop before connecting if the download is incomplete.
missing_files <- files[!file.exists(files)]
if (length(missing_files)) {
  stop("Missing expected CSV files: ", paste(basename(missing_files), collapse = ", "))
}

# Read one CSV and convert columns ending in _date or _datetime to native R
# date/time values. This lets DBI create useful PostgreSQL date/time columns
# instead of storing every field as text.
read_table <- function(path) {
  data <- utils::read.csv(
    path, check.names = FALSE, stringsAsFactors = FALSE,
    na.strings = c("", "NA"), colClasses = "character"
  )

  date_columns <- grep("(^|_)date$", names(data), value = TRUE)
  datetime_columns <- grep("(^|_)datetime$", names(data), value = TRUE)
  for (column in date_columns) {
    # Most tables use YYYY-MM-DD; the ICD-10-CM dictionary uses YYYYMMDD.
    values <- data[[column]]
    parsed <- as.Date(values, format = "%Y-%m-%d")
    compact <- !is.na(values) & is.na(parsed)
    parsed[compact] <- as.Date(values[compact], format = "%Y%m%d")
    if (any(!is.na(values) & is.na(parsed))) {
      stop("Unrecognized date values in column ", column)
    }
    data[[column]] <- parsed
  }
  for (column in datetime_columns) {
    data[[column]] <- as.POSIXct(data[[column]], format = "%Y-%m-%dT%H:%M:%OS",
                                 tz = "UTC")
  }
  data
}

# Open the connection through the fixed local DSN. The DSN contains the Aiven
# host, port, database, TLS settings, username, and password.
message("Connecting through ODBC data source ", dsn_name, "...")
connection <- DBI::dbConnect(odbc::odbc(), dsn = dsn_name)
on.exit(DBI::dbDisconnect(connection), add = TRUE)

# Create the teaching schema if necessary. Existing schemas outside `rwe` are
# not touched.
DBI::dbExecute(
  connection,
  paste0("CREATE SCHEMA IF NOT EXISTS ", DBI::dbQuoteIdentifier(connection, schema_name))
)

if (delete_all_existing_tables) {
  existing <- DBI::dbGetQuery(
    connection,
    paste0("SELECT table_name FROM information_schema.tables WHERE table_schema = ",
           DBI::dbQuoteString(connection, schema_name), " AND table_type = 'BASE TABLE'")
  )$table_name
  for (table_name in existing) {
    message("Dropping ", table_name, "...")
    DBI::dbExecute(
      connection,
      paste0("DROP TABLE ", DBI::dbQuoteIdentifier(connection, DBI::Id(schema = schema_name, table = table_name)))
    )
  }
}

# Load each CSV into a table with the same base name. Tables that already exist
# in the schema are skipped, so rerunning the script only adds missing tables.
# To reload everything, set delete_all_existing_tables to TRUE.
for (path in files) {
  table_name <- sub("\\.csv$", "", basename(path))
  table_id <- DBI::Id(schema = schema_name, table = table_name)
  if (DBI::dbExistsTable(connection, table_id)) {
    message("Skipping ", table_name, " (already exists)")
    next
  }
  message("Loading ", table_name, "...")
  data <- read_table(path)
  DBI::dbWriteTable(
    connection, table_id, data, overwrite = FALSE, row.names = FALSE
  )
  message("  ", nrow(data), " rows")
}

message("Load completed. Tables are available in schema: ", schema_name)
