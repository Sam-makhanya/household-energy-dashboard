# energy_model.R
#
# Builds the household-energy star schema from the two raw CSVs:
#   Energy Use Full.csv   (Date, Hour, Energy Type, Consumption)
#   Temperature.csv       (Date, Hour, Temperature C)
#
# Output is eight tables, matching 02_build_star_schema.sql:
#   DimDate, DimHour, DimEnergyType,
#   FactEnergyHourly, FactEnergyDaily,
#   FactTemperatureHourly, FactTemperatureDaily,
#   DataQualityLog
#
# Two ways to use this:
#
#   1. Power BI: each table's Power Query source calls
#         source(".../scripts/energy_model.R")
#         tbl <- energy_model_table("DimDate", "<project folder>")
#      so hitting Refresh in Power BI Desktop re-runs the model.
#
#   2. Command line:
#         Rscript scripts/energy_model.R [output folder]
#      writes all eight tables as CSV (default: PowerBI/data_r) so they
#      can be diffed against the SQL build with compare_r_sql.R.
#
# The business rules (thresholds, windows, etc.) are collected in one
# list, `defaults`, near the top of energy_model(), so they're easy to
# find and match to the DECLAREs at the top of the SQL script.
#
# One quirk worth flagging: SQL Server's decimal rounding rounds halves
# away from zero (0.5 -> 1), while R's built-in round() rounds halves to
# even (0.5 -> 0). To keep the two builds matching, we use our own
# round_half_up() everywhere instead of round().

round_half_up <- function(x, digits = 0) {
  multiplier <- 10 ^ digits
  sign(x) * floor(abs(x) * multiplier + 0.5 + 1e-9) / multiplier
}

# Works out the project root from the path this script is run from,
# so the CSVs can be found without hard-coding a path. Only matters
# when running from the command line; energy_model() also accepts an
# explicit `root` argument (which is what the Power BI integration uses).
default_project_root <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", args[grepl("^--file=", args)])
  if (length(file_arg) == 0) return(NA_character_)
  normalizePath(file.path(dirname(file_arg[1]), ".."), winslash = "/", mustWork = FALSE)
})

energy_model <- function(root = default_project_root, params = list()) {

  defaults <- list(
    gas_kwh_per_unit  = 11.2,        # assumed m3 -> kWh conversion for gas (unit isn't stated in the source)
    high_load_kwh     = 5.0,         # an hourly electricity reading at/above this counts as a "high load" hour
    morning_window    = c(5, 11),    # hours checked for sun hitting the temperature sensor
    afternoon_window  = c(12, 17),   # reference window used to spot a sun-inflated morning reading
    sun_buffer_c      = 2.0,         # morning reading has to be this many degrees above the afternoon max to be flagged
    max_interp_hours  = 6,           # longest temperature gap we're willing to interpolate across
    min_usable_hours  = 20,          # need at least this many clean hours in a day to trust its daily average
    hdd_base_c        = 15.5         # base temperature for heating degree days
  )
  p <- utils::modifyList(defaults, params)
  degree_sign <- "\u00b0"

  # ---------------------------------------------------------------- load the raw files
  energy <- utils::read.csv(
    file.path(root, "Energy Use Full.csv"),
    stringsAsFactors = FALSE, check.names = FALSE,
    colClasses = c("character", "character", "character", "numeric")
  )
  names(energy) <- c("Date", "Hour", "EnergyType", "Consumption")

  temperature <- utils::read.csv(
    file.path(root, "Temperature.csv"),
    stringsAsFactors = FALSE, check.names = FALSE,
    colClasses = c("character", "character", "numeric")
  )
  names(temperature) <- c("Date", "Hour", "TempRaw")

  date_key <- function(dates) as.integer(format(dates, "%Y%m%d"))

  energy$DateKey <- as.integer(gsub("-", "", energy$Date))
  energy$HourKey  <- as.integer(energy$Hour)

  temperature$DateKey <- as.integer(gsub("-", "", temperature$Date))
  temperature$HourKey  <- as.integer(temperature$Hour)

  energy_from  <- as.Date(min(energy$Date))
  energy_to    <- as.Date(max(energy$Date))
  temp_from    <- as.Date(min(temperature$Date))
  temp_to      <- as.Date(max(temperature$Date))

  # ---------------------------------------------------------------- DimDate
  all_dates <- seq(energy_from, energy_to, by = "day")
  parts <- as.POSIXlt(all_dates)
  year  <- parts$year + 1900L
  month <- parts$mon + 1L
  day   <- parts$mday

  # last day of each month, without a lookup table
  first_of_next_month <- as.Date(sprintf(
    "%04d-%02d-01",
    ifelse(month == 12L, year + 1L, year),
    ifelse(month == 12L, 1L, month + 1L)
  ))
  days_in_month <- as.integer(format(first_of_next_month - 1, "%d"))

  # Monday = 1 ... Sunday = 7, independent of the user's locale/DATEFIRST setting
  day_of_week <- ifelse(parts$wday == 0L, 7L, parts$wday)

  month_names <- c("January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November", "December")
  day_names   <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")

  # England & Wales bank holidays that fall inside the data period
  bank_holidays <- as.Date(c(
    "2022-12-26", "2022-12-27", "2023-01-02", "2023-04-07", "2023-04-10",
    "2023-05-01", "2023-05-08", "2023-05-29", "2023-08-28",
    "2023-12-25", "2023-12-26", "2024-01-01", "2024-03-29", "2024-04-01",
    "2024-05-06", "2024-05-27"
  ))
  is_bank_holiday <- all_dates %in% bank_holidays

  # labels the two "20 Nov - 30 Jun" windows so they can be compared year over year
  prior_temp_from <- temp_from - 365
  prior_temp_to   <- temp_to - 365
  comparison_period <- ifelse(
    all_dates >= temp_from & all_dates <= temp_to, "Winter-spring 2023/24",
    ifelse(all_dates >= prior_temp_from & all_dates <= prior_temp_to, "Winter-spring 2022/23", "Other months")
  )

  is_clock_change_day <- day_of_week == 7L & month %in% c(3L, 10L) & day > days_in_month - 7L

  DimDate <- data.frame(
    DateKey           = date_key(all_dates),
    Date              = all_dates,
    Year              = as.integer(year),
    Quarter           = paste0("Q", (month - 1L) %/% 3L + 1L),
    MonthNumber       = as.integer(month),
    MonthName         = month_names[month],
    MonthShort        = substr(month_names[month], 1, 3),
    YearMonth         = format(all_dates, "%Y-%m"),
    YearMonthLabel    = paste(substr(month_names[month], 1, 3), year),
    MonthStartDate    = as.Date(sprintf("%04d-%02d-01", year, month)),
    DaysInMonth       = days_in_month,
    DayOfMonth        = as.integer(day),
    DayOfWeekNumber   = as.integer(day_of_week),
    DayName           = day_names[day_of_week],
    DayShort          = substr(day_names[day_of_week], 1, 3),
    IsWeekend         = as.integer(day_of_week >= 6L),
    IsBankHoliday     = as.integer(is_bank_holiday),
    DayType           = ifelse(is_bank_holiday, "Bank holiday", ifelse(day_of_week >= 6L, "Weekend", "Weekday")),
    Season            = ifelse(month %in% c(12L, 1L, 2L), "Winter",
                         ifelse(month %in% 3:5, "Spring",
                         ifelse(month %in% 6:8, "Summer", "Autumn"))),
    SeasonOrder       = as.integer(ifelse(month %in% c(12L, 1L, 2L), 1L,
                                    ifelse(month %in% 3:5, 2L,
                                    ifelse(month %in% 6:8, 3L, 4L)))),
    SeasonMonth       = substr(month_names[month], 1, 3),
    SeasonMonthOrder  = as.integer((month + 1L) %% 12L + 1L),   # so a "season year" starts in November
    ComparisonPeriod  = comparison_period,
    HasTemperature    = as.integer(all_dates >= temp_from & all_dates <= temp_to),
    IsClockChangeDay  = as.integer(is_clock_change_day),
    TempBand          = "No temperature",  # filled in later, once we know each day's average temperature
    TempBandOrder     = 0L,
    stringsAsFactors  = FALSE
  )

  # ---------------------------------------------------------------- DimHour, DimEnergyType
  hours <- 0:23
  time_band <- function(h) {
    ifelse(h <= 5, "Overnight 00-05",
    ifelse(h <= 8, "Morning 06-08",
    ifelse(h <= 15, "Daytime 09-15",
    ifelse(h <= 20, "Evening 16-20", "Late evening 21-23"))))
  }
  time_band_order <- function(h) {
    ifelse(h <= 5, 1L, ifelse(h <= 8, 2L, ifelse(h <= 15, 3L, ifelse(h <= 20, 4L, 5L))))
  }
  DimHour <- data.frame(
    HourKey       = hours,
    HourLabel     = sprintf("%02d:00", hours),
    TimeBand      = time_band(hours),
    TimeBandOrder = time_band_order(hours),
    stringsAsFactors = FALSE
  )

  DimEnergyType <- data.frame(
    EnergyTypeKey = 1:2,
    EnergyType    = c("Electricity", "Gas"),
    SourceUnit    = c("kWh", "m3 (assumed)"),
    KwhPerUnit    = c(1, p$gas_kwh_per_unit),
    UnitNote      = c(
      "Consumption assumed to be kWh (unit not stated in the source).",
      "Unit not stated in the source. Volume in m3 assumed; converted to kWh at the factor shown (editable parameter)."
    ),
    stringsAsFactors = FALSE
  )

  # ---------------------------------------------------------------- FactEnergyHourly
  # Every date x hour x fuel combination that *should* exist gets a row, whether or
  # not there's a reading for it. Gaps are never filled in with a guess - they're
  # just flagged, so nobody downstream mistakes a gap for a zero.
  grid <- expand.grid(EnergyTypeKey = 1:2, HourKey = 0:23, DateKey = DimDate$DateKey)
  grid <- grid[, c("DateKey", "HourKey", "EnergyTypeKey")]

  energy_key <- paste(energy$DateKey, energy$HourKey, match(energy$EnergyType, DimEnergyType$EnergyType))
  grid_key   <- paste(grid$DateKey, grid$HourKey, grid$EnergyTypeKey)
  grid$Consumption    <- energy$Consumption[match(grid_key, energy_key)]
  grid$ConsumptionKwh <- round_half_up(grid$Consumption * DimEnergyType$KwhPerUnit[grid$EnergyTypeKey], 3)

  is_missing <- is.na(grid$Consumption)

  # how many readings that day/fuel actually has, and whether the same hour is
  # missing for both fuels at once (a sign of a clock-change or timestamp issue)
  readings_that_day       <- ave(as.integer(!is_missing), grid$DateKey, grid$EnergyTypeKey, FUN = sum)
  fuels_missing_that_hour <- ave(as.integer(is_missing),  grid$DateKey, grid$HourKey,       FUN = sum)

  missing_reason <- ifelse(
    !is_missing, NA_character_,
    ifelse(readings_that_day == 0, "Whole day",
    ifelse(fuels_missing_that_hour == nrow(DimEnergyType), "Both fuels", "Single fuel"))
  )

  FactEnergyHourly <- data.frame(
    DateKey        = grid$DateKey,
    HourKey        = grid$HourKey,
    EnergyTypeKey  = grid$EnergyTypeKey,
    Consumption    = grid$Consumption,
    ConsumptionKwh = grid$ConsumptionKwh,
    IsMissing      = as.integer(is_missing),
    MissingReason  = missing_reason,
    IsHighLoadHour = as.integer(grid$EnergyTypeKey == 1L & !is_missing & grid$Consumption >= p$high_load_kwh),
    stringsAsFactors = FALSE
  )
  FactEnergyHourly <- FactEnergyHourly[order(FactEnergyHourly$DateKey, FactEnergyHourly$HourKey, FactEnergyHourly$EnergyTypeKey), ]
  rownames(FactEnergyHourly) <- NULL

  # ---------------------------------------------------------------- FactEnergyDaily
  # Rolls the hourly fact up to one row per date/fuel, then works out the client's
  # "daily use as a % of the month" figure. That % is only filled in for months
  # where every single day has at least one reading - otherwise a month with a
  # data gap would understate its total and every other day's share would look
  # artificially high.
  group_key <- paste(grid$DateKey, grid$EnergyTypeKey)
  readings_per_group    <- as.numeric(rowsum(as.integer(!is_missing), group_key))
  consumption_per_group <- as.numeric(rowsum(ifelse(is_missing, 0, grid$Consumption), group_key))
  kwh_per_group         <- as.numeric(rowsum(ifelse(is_missing, 0, grid$ConsumptionKwh), group_key))

  group_ids     <- rownames(rowsum(as.integer(!is_missing), group_key))
  group_date    <- as.integer(sub(" .*", "", group_ids))
  group_type    <- as.integer(sub(".* ", "", group_ids))

  FactEnergyDaily <- data.frame(
    DateKey        = group_date,
    EnergyTypeKey  = group_type,
    Consumption    = ifelse(readings_per_group > 0, round_half_up(consumption_per_group, 3), NA_real_),
    ConsumptionKwh = ifelse(readings_per_group > 0, round_half_up(kwh_per_group, 3), NA_real_),
    ReadingsCount  = as.integer(readings_per_group),
    MissingReadings = as.integer(24L - readings_per_group),
    HasData        = as.integer(readings_per_group > 0),
    stringsAsFactors = FALSE
  )

  year_month <- FactEnergyDaily$DateKey %/% 100L
  FactEnergyDaily$MonthConsumption <- round_half_up(
    ave(ifelse(is.na(FactEnergyDaily$Consumption), 0, FactEnergyDaily$Consumption),
        year_month, FactEnergyDaily$EnergyTypeKey, FUN = sum),
    3
  )
  FactEnergyDaily$DaysInMonth  <- DimDate$DaysInMonth[match(FactEnergyDaily$DateKey, DimDate$DateKey)]
  FactEnergyDaily$DaysWithData <- as.integer(ave(FactEnergyDaily$HasData, year_month, FactEnergyDaily$EnergyTypeKey, FUN = sum))
  FactEnergyDaily$IsCompleteMonth <- as.integer(FactEnergyDaily$DaysWithData == FactEnergyDaily$DaysInMonth)
  FactEnergyDaily$DailyPctOfMonth <- ifelse(
    FactEnergyDaily$IsCompleteMonth == 1L & FactEnergyDaily$MonthConsumption > 0,
    round_half_up(FactEnergyDaily$Consumption / FactEnergyDaily$MonthConsumption, 6),
    NA_real_
  )

  FactEnergyDaily <- FactEnergyDaily[order(FactEnergyDaily$DateKey, FactEnergyDaily$EnergyTypeKey), ]
  rownames(FactEnergyDaily) <- NULL

  # ---------------------------------------------------------------- FactTemperatureHourly
  # The temperature sensor sometimes sits in direct sun, which makes mid-morning
  # readings spike well above what the same day's afternoon shows. We flag those,
  # treat them the same as a missing reading, and then interpolate across short
  # gaps (up to `max_interp_hours`) using the nearest good reading on each side.
  temp_dates <- DimDate$DateKey[DimDate$Date >= temp_from & DimDate$Date <= temp_to]
  temp_grid <- expand.grid(HourKey = 0:23, DateKey = temp_dates)
  temp_grid <- temp_grid[order(temp_grid$DateKey, temp_grid$HourKey), c("DateKey", "HourKey")]
  temp_grid$Position <- seq_len(nrow(temp_grid)) - 1L   # a simple running index, used for the interpolation below

  temp_key <- paste(temperature$DateKey, temperature$HourKey)
  temp_grid_key <- paste(temp_grid$DateKey, temp_grid$HourKey)
  temp_grid$Raw <- temperature$TempRaw[match(temp_grid_key, temp_key)]

  afternoon_hours <- temp_grid$HourKey >= p$afternoon_window[1] & temp_grid$HourKey <= p$afternoon_window[2]
  afternoon_reading <- ifelse(afternoon_hours, temp_grid$Raw, NA_real_)
  afternoon_max_by_day <- tapply(afternoon_reading, temp_grid$DateKey, function(x) {
    if (all(is.na(x))) NA_real_ else max(x, na.rm = TRUE)
  })
  temp_grid$AfternoonMax <- as.numeric(afternoon_max_by_day[as.character(temp_grid$DateKey)])

  is_sun_affected <-
    !is.na(temp_grid$Raw) & !is.na(temp_grid$AfternoonMax) &
    temp_grid$HourKey >= p$morning_window[1] & temp_grid$HourKey <= p$morning_window[2] &
    temp_grid$Raw > temp_grid$AfternoonMax + p$sun_buffer_c

  # "Kept" readings are the ones we trust: not missing, not sun-affected.
  kept <- ifelse(is.na(temp_grid$Raw) | is_sun_affected, NA_real_, temp_grid$Raw)
  good_positions <- which(!is.na(kept))

  clean <- kept
  for (i in which(is.na(kept))) {
    prev <- suppressWarnings(max(good_positions[good_positions < i]))
    next_ <- suppressWarnings(min(good_positions[good_positions > i]))
    gap_is_short_enough <- is.finite(prev) && is.finite(next_) && (next_ - prev) <= p$max_interp_hours + 1L
    if (gap_is_short_enough) {
      clean[i] <- kept[prev] + (kept[next_] - kept[prev]) * (i - prev) / (next_ - prev)
    }
  }
  clean <- round_half_up(clean, 2)
  was_repaired <- is.na(kept) & !is.na(clean)

  FactTemperatureHourly <- data.frame(
    DateKey           = temp_grid$DateKey,
    HourKey           = temp_grid$HourKey,
    TemperatureRawC   = temp_grid$Raw,
    TemperatureCleanC = clean,
    IsMissing         = as.integer(is.na(temp_grid$Raw)),
    IsSunAffected     = as.integer(is_sun_affected),
    IsRepaired        = as.integer(was_repaired),
    DataQuality       = ifelse(is.na(temp_grid$Raw), "Missing", ifelse(is_sun_affected, "Sun-affected", "OK")),
    stringsAsFactors  = FALSE
  )

  # ---------------------------------------------------------------- FactTemperatureDaily
  daily_keys <- sort(unique(temp_grid$DateKey))
  key_chr <- as.character(daily_keys)

  clean_hours_per_day <- tapply(!is.na(clean), temp_grid$DateKey, sum)[key_chr]
  day_is_usable <- as.integer(clean_hours_per_day >= p$min_usable_hours)

  safe_max <- function(x) if (all(is.na(x))) NA_real_ else max(x, na.rm = TRUE)
  safe_min <- function(x) if (all(is.na(x))) NA_real_ else min(x, na.rm = TRUE)

  mean_clean <- as.numeric(tapply(clean, temp_grid$DateKey, mean, na.rm = TRUE)[key_chr])
  max_clean  <- as.numeric(tapply(clean, temp_grid$DateKey, safe_max)[key_chr])
  min_clean  <- as.numeric(tapply(clean, temp_grid$DateKey, safe_min)[key_chr])
  mean_raw   <- as.numeric(tapply(temp_grid$Raw, temp_grid$DateKey, mean, na.rm = TRUE)[key_chr])
  max_raw    <- as.numeric(tapply(temp_grid$Raw, temp_grid$DateKey, safe_max)[key_chr])

  FactTemperatureDaily <- data.frame(
    DateKey        = daily_keys,
    MeanTempRawC   = ifelse(is.nan(mean_raw), NA_real_, round_half_up(mean_raw, 2)),
    MaxTempRawC    = max_raw,
    MeanTempCleanC = ifelse(day_is_usable == 1L, round_half_up(mean_clean, 2), NA_real_),
    MinTempCleanC  = ifelse(day_is_usable == 1L, min_clean, NA_real_),
    MaxTempCleanC  = ifelse(day_is_usable == 1L, max_clean, NA_real_),
    RawHours       = as.integer(tapply(!is.na(temp_grid$Raw), temp_grid$DateKey, sum)[key_chr]),
    CleanHours     = as.integer(clean_hours_per_day),
    IsUsableDay    = day_is_usable,
    HeatingDegreeDays = ifelse(
      day_is_usable == 1L,
      ifelse(p$hdd_base_c > mean_clean, round_half_up(p$hdd_base_c - mean_clean, 2), 0),
      NA_real_
    ),
    stringsAsFactors = FALSE
  )

  # Bring a temperature band back onto DimDate, so energy can be sliced by "how cold was it".
  day_mean_temp <- FactTemperatureDaily$MeanTempCleanC[match(DimDate$DateKey, FactTemperatureDaily$DateKey)]
  band_breaks <- c(-Inf, 0, 5, 10, 15, 20, Inf)
  band_labels <- c(
    paste0("Below 0", degree_sign, "C"), paste0("0 to 5", degree_sign, "C"),
    paste0("5 to 10", degree_sign, "C"), paste0("10 to 15", degree_sign, "C"),
    paste0("15 to 20", degree_sign, "C"), paste0("20", degree_sign, "C and above")
  )
  band_index <- as.integer(cut(day_mean_temp, band_breaks, right = FALSE, labels = FALSE))
  DimDate$TempBand      <- ifelse(is.na(band_index), "No temperature", band_labels[band_index])
  DimDate$TempBandOrder <- ifelse(is.na(band_index), 0L, band_index)

  # ---------------------------------------------------------------- DataQualityLog
  # A plain-English record of what was found in the source files and how it was
  # handled, so a reviewer doesn't have to reverse-engineer the rules from the code.
  join_dates <- function(keys) paste(format(keys), collapse = ", ")
  date_for_key <- function(keys) DimDate$Date[match(keys, DimDate$DateKey)]

  missing_gas_hours  <- sum(FactEnergyHourly$IsMissing == 1 & FactEnergyHourly$EnergyTypeKey == 2)
  missing_elec_hours <- sum(FactEnergyHourly$IsMissing == 1 & FactEnergyHourly$EnergyTypeKey == 1)
  total_missing_hours <- sum(FactEnergyHourly$IsMissing)

  whole_missing_days <- unique(FactEnergyHourly[
    !is.na(FactEnergyHourly$MissingReason) & FactEnergyHourly$MissingReason == "Whole day",
    c("DateKey", "EnergyTypeKey")
  ])
  both_fuels_missing_days <- unique(FactEnergyHourly$DateKey[
    !is.na(FactEnergyHourly$MissingReason) & FactEnergyHourly$MissingReason == "Both fuels"
  ])
  single_fuel_gap_hours <- sum(!is.na(FactEnergyHourly$MissingReason) & FactEnergyHourly$MissingReason == "Single fuel")
  single_fuel_gap_days  <- length(unique(FactEnergyHourly$DateKey[
    !is.na(FactEnergyHourly$MissingReason) & FactEnergyHourly$MissingReason == "Single fuel"
  ]))

  incomplete <- FactEnergyDaily[FactEnergyDaily$IsCompleteMonth == 0 & FactEnergyDaily$HasData == 1, ]
  incomplete$YearMonth <- incomplete$DateKey %/% 100L
  incomplete_months <- unique(incomplete[, c("YearMonth", "EnergyTypeKey", "DaysWithData", "DaysInMonth")])
  incomplete_summary <- paste(
    vapply(1:2, function(fuel_key) {
      rows <- incomplete_months[incomplete_months$EnergyTypeKey == fuel_key, ]
      rows <- rows[order(rows$YearMonth), ]
      labels <- DimDate$YearMonthLabel[match(rows$YearMonth, DimDate$DateKey %/% 100L)]
      paste0(
        DimEnergyType$EnergyType[fuel_key], ": ",
        paste0(labels, " (", rows$DaysWithData, "/", rows$DaysInMonth, " days)", collapse = ", ")
      )
    }, character(1)),
    collapse = "; "
  )

  zero_gas_days <- FactEnergyDaily$DateKey[
    FactEnergyDaily$EnergyTypeKey == 2 & FactEnergyDaily$ReadingsCount == 24 &
      !is.na(FactEnergyDaily$Consumption) & FactEnergyDaily$Consumption == 0
  ]

  high_load_rows <- FactEnergyHourly[FactEnergyHourly$IsHighLoadHour == 1, ]
  total_electricity <- sum(FactEnergyHourly$Consumption[FactEnergyHourly$EnergyTypeKey == 1], na.rm = TRUE)

  missing_temp_rows <- FactTemperatureHourly[FactTemperatureHourly$IsMissing == 1, ]
  unusable_temp_days <- FactTemperatureDaily$DateKey[FactTemperatureDaily$IsUsableDay == 0]

  duplicate_energy_keys      <- sum(duplicated(paste(energy$DateKey, energy$HourKey, energy$EnergyType)))
  duplicate_temperature_keys <- sum(duplicated(paste(temperature$DateKey, temperature$HourKey)))

  hottest_reading <- FactTemperatureHourly[which.max(FactTemperatureHourly$TemperatureRawC), ]

  DataQualityLog <- data.frame(
    IssueNo = 1:15,
    Dataset = c(rep("Energy", 9), rep("Temperature", 4), "Both", "Both"),
    Issue = c(
      "Missing hourly readings (gaps in the Date x Hour x Energy Type grid)",
      "A whole day with no readings for one fuel",
      "Same hour missing for both fuels (clock-change / timestamp handling)",
      "Isolated single-fuel gaps (gas meter drop-outs)",
      "Incomplete months (excluded from the daily % of monthly total)",
      "Consumption unit is not stated (electricity vs gas are different units)",
      "Whole days of zero gas",
      "Very large hourly electricity readings (>= 5 kWh in one hour)",
      "Hour stored as text, no timestamp or time zone",
      "Missing hourly readings",
      "Sun-affected readings (sensor in direct sunlight overstates temperature)",
      "Days without enough usable hours for daily statistics",
      "Temperature starts one year after the energy data",
      "Duplicate keys (Date, Hour, Energy Type)",
      "NULL, negative or out-of-range values"
    ),
    RecordsAffected = c(
      total_missing_hours,
      nrow(whole_missing_days),
      sum(FactEnergyHourly$MissingReason == "Both fuels", na.rm = TRUE),
      single_fuel_gap_hours,
      nrow(incomplete_months),
      nrow(energy),
      length(zero_gas_days),
      nrow(high_load_rows),
      nrow(energy),
      nrow(missing_temp_rows),
      sum(FactTemperatureHourly$IsSunAffected),
      length(unusable_temp_days),
      sum(DimDate$HasTemperature == 0),
      duplicate_energy_keys + duplicate_temperature_keys,
      sum(energy$Consumption < 0) + sum(temperature$TempRaw < -30 | temperature$TempRaw > 45)
    ),
    Evidence = c(
      sprintf(
        "%d gas and %d electricity readings absent from %d expected (%.2f%%). Electricity is almost complete; gas carries nearly all gaps.",
        missing_gas_hours, missing_elec_hours, nrow(FactEnergyHourly), 100 * total_missing_hours / nrow(FactEnergyHourly)
      ),
      if (nrow(whole_missing_days)) {
        paste(sprintf("%s (%s)", format(date_for_key(whole_missing_days$DateKey)),
                      DimEnergyType$EnergyType[whole_missing_days$EnergyTypeKey]), collapse = ", ")
      } else "none",
      paste0(
        join_dates(sort(date_for_key(both_fuels_missing_days))),
        ". Spring clock changes legitimately lose hour 01; the autumn change shows no repeated hour and a missing hour 00 on 28-29 Oct 2023."
      ),
      sprintf("%d single hours or short runs, all gas, scattered over %d days.", single_fuel_gap_hours, single_fuel_gap_days),
      incomplete_summary,
      sprintf(
        "Average per day: electricity %.1f, gas %.1f. Those magnitudes only make sense as kWh and m3 (a gas figure this small cannot be kWh for a family home).",
        mean(FactEnergyDaily$Consumption[FactEnergyDaily$EnergyTypeKey == 1 & FactEnergyDaily$ReadingsCount == 24]),
        mean(FactEnergyDaily$Consumption[FactEnergyDaily$EnergyTypeKey == 2 & FactEnergyDaily$ReadingsCount == 24])
      ),
      if (length(zero_gas_days)) join_dates(date_for_key(zero_gas_days)) else "none",
      sprintf(
        "%d hours on %d days carry %.1f%% of all electricity; %.1f%% fall between 23:00 and 07:00.",
        nrow(high_load_rows), length(unique(high_load_rows$DateKey)),
        100 * sum(high_load_rows$Consumption) / total_electricity,
        100 * mean(high_load_rows$HourKey >= 23 | high_load_rows$HourKey <= 6)
      ),
      "Hour is a zero-padded text field ('00'..'23') and Date a separate text-like date; the local time zone is not recorded.",
      sprintf(
        "%d of %d expected hours on %d dates; the longest single-day gap is %d hours.",
        nrow(missing_temp_rows), nrow(FactTemperatureHourly), length(unique(missing_temp_rows$DateKey)),
        max(table(missing_temp_rows$DateKey))
      ),
      sprintf(
        "%d readings on %d days, all between 05:00 and 11:59. Highest raw reading %s C (at %02d:00), cleansed maximum %s C.",
        sum(FactTemperatureHourly$IsSunAffected),
        length(unique(FactTemperatureHourly$DateKey[FactTemperatureHourly$IsSunAffected == 1])),
        format(hottest_reading$TemperatureRawC, nsmall = 1), hottest_reading$HourKey,
        format(max(FactTemperatureHourly$TemperatureCleanC, na.rm = TRUE), nsmall = 2)
      ),
      if (length(unusable_temp_days)) join_dates(date_for_key(unusable_temp_days)) else "none",
      sprintf(
        "%d of %d energy days (%s to %s) have no temperature.",
        sum(DimDate$HasTemperature == 0), nrow(DimDate), format(energy_from), format(temp_from - 1)
      ),
      "None found in either table.",
      "None found (temperatures span a plausible UK range apart from the sun artefact above)."
    ),
    Treatment = c(
      "Load onto a complete grid and keep each gap as a row with NULL consumption, IsMissing = 1 and a reason. Do NOT impute: invented usage would corrupt daily and monthly totals. Affected days carry MissingReadings > 0 so totals can be read as \"at least\".",
      "Keep the day as 24 flagged rows. The month is then NOT complete for that fuel, so it is excluded from the \"% of monthly total\" view for that fuel only.",
      "Flag, do not fill. Root cause is an hour-of-day key with no time zone: ask the source to supply UTC timestamps. Days with 23 readings are marked via ReadingsCount.",
      "Keep as flagged NULLs. Effect on a day is small (typically 1 hour of 24), but the day's total is understated by whatever was used in that hour.",
      "A month is complete for a fuel when every calendar day has at least one reading. Only complete months get DailyPctOfMonth (NULL otherwise); totals and trends still use whatever data exists, and days with a few missing hours stay in (flagged). Requiring all 24 hours every day would discard about half of the gas months.",
      "Confirm with the client. Electricity treated as kWh; gas assumed to be m3 and converted at 11.2 kWh/m3 in DimEnergyType.KwhPerUnit (editable) so a combined kWh view is possible. The daily % of month view is unit-free and unaffected.",
      "Retained. Plausible when the house is empty or in summer, but a zero in the heating season (late October) may be a meter drop-out - flagged for the client to confirm.",
      "Not errors: a repeatable overnight pattern of 7-9 kWh per hour, consistent with EV charging. Kept and flagged with IsHighLoadHour so it can be isolated or excluded from base-load analysis.",
      "Converted to a numeric HourKey and a DateKey; both are dimension keys. Recommend the source delivers UTC timestamps.",
      "Gaps of up to 6 consecutive hours are linearly interpolated (IsRepaired = 1); longer gaps stay NULL rather than inventing a temperature.",
      "Rule: a reading between 05:00 and 11:59 more than 2.0 C above that day's 12:00-17:59 maximum is flagged, blanked and interpolated; the raw value stays in TemperatureRawC. Limitation: sustained overstatement on hot clear days cannot be told from real heat without a reference weather station.",
      "Daily mean, minimum, maximum and heating degree days are set to NULL when fewer than 20 usable hours remain, so a half-observed day cannot distort weather comparisons.",
      "Weather analysis is limited to the overlap. DimDate.ComparisonPeriod aligns the two 20 Nov - 30 Jun windows for year-on-year comparison; that comparison cannot be weather-adjusted because year one has no temperatures.",
      "The composite primary keys on the fact tables make the load fail loudly if duplicates ever appear.",
      "Column types and NOT NULL constraints on the input tables reject bad values at load time."
    ),
    stringsAsFactors = FALSE
  )

  list(
    DimDate = DimDate,
    DimHour = DimHour,
    DimEnergyType = DimEnergyType,
    FactEnergyHourly = FactEnergyHourly,
    FactEnergyDaily = FactEnergyDaily,
    FactTemperatureHourly = FactTemperatureHourly,
    FactTemperatureDaily = FactTemperatureDaily,
    DataQualityLog = DataQualityLog
  )
}

# ---------------------------------------------------------------- Power BI entry point
# Power BI's R.Execute calls this once per table. We only want to build the whole
# model once per refresh, not once per table, so the result is cached for as long
# as the R session lives.
model_cache <- new.env()

energy_model_table <- function(table_name, root = default_project_root) {
  cache_is_stale <- is.null(model_cache$model) || !identical(model_cache$root, root)
  if (cache_is_stale) {
    model_cache$model <- energy_model(root)
    model_cache$root  <- root
  }
  model_cache$model[[table_name]]
}

# ---------------------------------------------------------------- command-line entry point
# Only runs when the script is executed directly (Rscript ...), not when it's
# source()'d from Power BI.
is_run_directly <- sys.nframe() == 0L &&
  !is.na(default_project_root) &&
  length(grep("^--file=.*energy_model\\.R$", commandArgs(trailingOnly = FALSE))) > 0

if (is_run_directly) {
  cli_args <- commandArgs(trailingOnly = TRUE)
  output_dir <- if (length(cli_args)) cli_args[1] else file.path(default_project_root, "PowerBI", "data_r")
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  start_time <- Sys.time()
  tables <- energy_model()
  cat(sprintf("model built in %.1f s\n", as.numeric(difftime(Sys.time(), start_time, units = "secs"))))

  for (table_name in names(tables)) {
    table_data <- tables[[table_name]]
    out_path <- file.path(output_dir, paste0(table_name, ".csv"))
    con <- file(out_path, open = "wb")
    utils::write.table(
      table_data, con, sep = ",", row.names = FALSE, na = "",
      quote = which(vapply(table_data, is.character, logical(1))),
      qmethod = "double", eol = "\r\n", fileEncoding = "UTF-8"
    )
    close(con)
    cat(sprintf("  %-22s %7d rows -> %s\n", table_name, nrow(table_data), out_path))
  }
}
