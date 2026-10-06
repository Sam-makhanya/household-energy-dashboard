/* =====================================================================================
   02_build_star_schema.sql

   Builds the household-energy star schema from the two raw source tables:
       dbo.Energy_Use_Full  (Date, Hour, Energy Type, Consumption)
       dbo.Temperature      (Date, Hour, Temperature C)

   Output is eight tables in schema dw, matching energy_model.R:
       dw.DimDate  dw.DimHour  dw.DimEnergyType
       dw.FactEnergyHourly  dw.FactEnergyDaily
       dw.FactTemperatureHourly  dw.FactTemperatureDaily
       dw.DataQualityLog

   Requires SQL Server 2017+ (uses STRING_AGG). Run the whole thing as one batch -
   don't split it up with GO, since the business-rule parameters declared in
   section 0 need to stay in scope for the rest of the script.

   Design rules
     * Build a complete Date x Hour x Fuel grid. A gap in the source data becomes
       a flagged NULL row - it is never filled in with a guess.
     * A month only counts as "complete" for a fuel if every calendar day in it
       has at least one reading. Only complete months get a daily-% figure.
     * Raw temperature is always kept. Readings that look like the sensor caught
       direct sun are flagged and treated as missing; short gaps (<= 6 hours) are
       linearly interpolated from the nearest good readings either side.
   ===================================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* ------------------------------------------------------------------ 0a. loading the source tables --
   Create and load these once, however suits you (SSMS Import Flat File wizard, bcp,
   BULK INSERT). Left commented out since most environments will load these differently.

IF OBJECT_ID('dbo.Energy_Use_Full') IS NULL
    CREATE TABLE dbo.Energy_Use_Full (
        [Date] date NOT NULL, [Hour] varchar(2) NOT NULL,
        [Energy Type] varchar(20) NOT NULL, [Consumption] decimal(12,3) NOT NULL);
IF OBJECT_ID('dbo.Temperature') IS NULL
    CREATE TABLE dbo.Temperature (
        [Date] date NOT NULL, [Hour] varchar(2) NOT NULL, [Temperature C] decimal(5,1) NOT NULL);

BULK INSERT dbo.Energy_Use_Full FROM 'C:\data\Energy Use Full.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', ROWTERMINATOR = '0x0d0a');
BULK INSERT dbo.Temperature     FROM 'C:\data\Temperature.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', ROWTERMINATOR = '0x0d0a');
   ------------------------------------------------------------------------------------------------- */

/* ------------------------------------------------------------------ 0. business-rule parameters -- */
DECLARE @GasKwhPerUnit  decimal(9,4) = 11.2;    -- assumed m3 -> kWh conversion for gas (unit isn't stated in the source)
DECLARE @HighLoadKwh    decimal(9,3) = 5.0;     -- an hourly electricity reading at/above this counts as "high load"
DECLARE @MorningFrom    int          = 5;       -- hours checked for sun hitting the temperature sensor
DECLARE @MorningTo      int          = 11;
DECLARE @AfternoonFrom  int          = 12;      -- reference window used to spot a sun-inflated morning reading
DECLARE @AfternoonTo    int          = 17;
DECLARE @SunBufferC     decimal(5,2) = 2.0;     -- morning reading has to be this many degrees above the afternoon max to be flagged
DECLARE @MaxInterpHours int          = 6;       -- longest temperature gap we're willing to interpolate across
DECLARE @MinUsableHours int          = 20;      -- need at least this many clean hours in a day to trust its daily average
DECLARE @HddBaseC       decimal(5,2) = 15.5;    -- base temperature for heating degree days

DECLARE @EnergyFrom date = (SELECT MIN([Date]) FROM dbo.Energy_Use_Full);
DECLARE @EnergyTo   date = (SELECT MAX([Date]) FROM dbo.Energy_Use_Full);
DECLARE @TempFrom   date = (SELECT MIN([Date]) FROM dbo.Temperature);
DECLARE @TempTo     date = (SELECT MAX([Date]) FROM dbo.Temperature);
DECLARE @Deg nchar(1) = NCHAR(176);              -- degree sign, built with NCHAR to avoid any file-encoding issues

/* ------------------------------------------------------------------ 1. schema and table definitions -- */
IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');

DROP TABLE IF EXISTS dw.DataQualityLog;
DROP TABLE IF EXISTS dw.FactTemperatureDaily;
DROP TABLE IF EXISTS dw.FactTemperatureHourly;
DROP TABLE IF EXISTS dw.FactEnergyDaily;
DROP TABLE IF EXISTS dw.FactEnergyHourly;
DROP TABLE IF EXISTS dw.DimEnergyType;
DROP TABLE IF EXISTS dw.DimHour;
DROP TABLE IF EXISTS dw.DimDate;
DROP TABLE IF EXISTS #TempWorking;

CREATE TABLE dw.DimDate (
    DateKey int NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,
    [Date] date NOT NULL, [Year] int NOT NULL, Quarter char(2) NOT NULL, MonthNumber int NOT NULL,
    MonthName varchar(9) NOT NULL, MonthShort char(3) NOT NULL, YearMonth char(7) NOT NULL, YearMonthLabel varchar(8) NOT NULL,
    MonthStartDate date NOT NULL, DaysInMonth int NOT NULL, DayOfMonth int NOT NULL, DayOfWeekNumber int NOT NULL,
    DayName varchar(9) NOT NULL, DayShort char(3) NOT NULL, IsWeekend tinyint NOT NULL, IsBankHoliday tinyint NOT NULL,
    DayType varchar(12) NOT NULL, Season varchar(6) NOT NULL, SeasonOrder int NOT NULL, SeasonMonth char(3) NOT NULL,
    SeasonMonthOrder int NOT NULL, ComparisonPeriod varchar(30) NOT NULL, HasTemperature tinyint NOT NULL,
    IsClockChangeDay tinyint NOT NULL, TempBand nvarchar(20) NOT NULL, TempBandOrder int NOT NULL);

CREATE TABLE dw.DimHour (
    HourKey int NOT NULL CONSTRAINT PK_DimHour PRIMARY KEY, HourLabel char(5) NOT NULL,
    TimeBand varchar(20) NOT NULL, TimeBandOrder int NOT NULL);

CREATE TABLE dw.DimEnergyType (
    EnergyTypeKey int NOT NULL CONSTRAINT PK_DimEnergyType PRIMARY KEY, EnergyType varchar(20) NOT NULL,
    SourceUnit varchar(20) NOT NULL, KwhPerUnit decimal(9,4) NOT NULL, UnitNote nvarchar(300) NOT NULL);

CREATE TABLE dw.FactEnergyHourly (
    DateKey int NOT NULL, HourKey int NOT NULL, EnergyTypeKey int NOT NULL,
    Consumption decimal(12,3) NULL, ConsumptionKwh decimal(14,3) NULL,
    IsMissing tinyint NOT NULL, MissingReason varchar(12) NULL, IsHighLoadHour tinyint NOT NULL,
    CONSTRAINT PK_FactEnergyHourly PRIMARY KEY (DateKey, HourKey, EnergyTypeKey),
    CONSTRAINT FK_FEH_Date FOREIGN KEY (DateKey) REFERENCES dw.DimDate (DateKey),
    CONSTRAINT FK_FEH_Hour FOREIGN KEY (HourKey) REFERENCES dw.DimHour (HourKey),
    CONSTRAINT FK_FEH_Type FOREIGN KEY (EnergyTypeKey) REFERENCES dw.DimEnergyType (EnergyTypeKey));

CREATE TABLE dw.FactEnergyDaily (
    DateKey int NOT NULL, EnergyTypeKey int NOT NULL,
    Consumption decimal(14,3) NULL, ConsumptionKwh decimal(14,3) NULL,
    ReadingsCount int NOT NULL, MissingReadings int NOT NULL, HasData tinyint NOT NULL,
    MonthConsumption decimal(14,3) NOT NULL, DaysInMonth int NOT NULL, DaysWithData int NOT NULL,
    IsCompleteMonth tinyint NOT NULL, DailyPctOfMonth decimal(9,6) NULL,
    CONSTRAINT PK_FactEnergyDaily PRIMARY KEY (DateKey, EnergyTypeKey),
    CONSTRAINT FK_FED_Date FOREIGN KEY (DateKey) REFERENCES dw.DimDate (DateKey),
    CONSTRAINT FK_FED_Type FOREIGN KEY (EnergyTypeKey) REFERENCES dw.DimEnergyType (EnergyTypeKey));

CREATE TABLE dw.FactTemperatureHourly (
    DateKey int NOT NULL, HourKey int NOT NULL,
    TemperatureRawC decimal(5,1) NULL, TemperatureCleanC decimal(6,2) NULL,
    IsMissing tinyint NOT NULL, IsSunAffected tinyint NOT NULL, IsRepaired tinyint NOT NULL, DataQuality varchar(12) NOT NULL,
    CONSTRAINT PK_FactTemperatureHourly PRIMARY KEY (DateKey, HourKey),
    CONSTRAINT FK_FTH_Date FOREIGN KEY (DateKey) REFERENCES dw.DimDate (DateKey),
    CONSTRAINT FK_FTH_Hour FOREIGN KEY (HourKey) REFERENCES dw.DimHour (HourKey));

CREATE TABLE dw.FactTemperatureDaily (
    DateKey int NOT NULL CONSTRAINT PK_FactTemperatureDaily PRIMARY KEY,
    MeanTempRawC decimal(6,2) NULL, MaxTempRawC decimal(5,1) NULL,
    MeanTempCleanC decimal(6,2) NULL, MinTempCleanC decimal(6,2) NULL, MaxTempCleanC decimal(6,2) NULL,
    RawHours int NOT NULL, CleanHours int NOT NULL, IsUsableDay tinyint NOT NULL, HeatingDegreeDays decimal(6,2) NULL,
    CONSTRAINT FK_FTD_Date FOREIGN KEY (DateKey) REFERENCES dw.DimDate (DateKey));

CREATE TABLE dw.DataQualityLog (
    IssueNo int NOT NULL CONSTRAINT PK_DataQualityLog PRIMARY KEY, Dataset varchar(20) NOT NULL,
    Issue nvarchar(200) NOT NULL, RecordsAffected int NOT NULL, Evidence nvarchar(max) NOT NULL, Treatment nvarchar(max) NOT NULL);

/* ------------------------------------------------------------------ 2. DimDate -- */
WITH seq AS (
    SELECT TOP (DATEDIFF(DAY, @EnergyFrom, @EnergyTo) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
), calendar_days AS (
    SELECT DATEADD(DAY, n, @EnergyFrom) AS [Date] FROM seq
), day_calc AS (
    SELECT [Date],
           CONVERT(int, CONVERT(char(8), [Date], 112)) AS DateKey,
           YEAR([Date]) AS Yr, MONTH([Date]) AS Mo, DAY([Date]) AS Dy, DAY(EOMONTH([Date])) AS LastDayOfMonth,
           (DATEDIFF(DAY, '19000101', [Date]) % 7) + 1 AS DowNumber,     -- Monday = 1 ... Sunday = 7, regardless of DATEFIRST
           CASE WHEN [Date] IN ('2022-12-26','2022-12-27','2023-01-02','2023-04-07','2023-04-10','2023-05-01','2023-05-08','2023-05-29',
                                '2023-08-28','2023-12-25','2023-12-26','2024-01-01','2024-03-29','2024-04-01','2024-05-06','2024-05-27')
                THEN 1 ELSE 0 END AS IsBank                              -- England & Wales bank holidays in the period
    FROM calendar_days
)
INSERT INTO dw.DimDate
SELECT
    day_calc.DateKey, day_calc.[Date], day_calc.Yr,
    'Q' + CAST((day_calc.Mo - 1) / 3 + 1 AS char(1)), day_calc.Mo,
    names.MonthName, LEFT(names.MonthName, 3),
    CAST(day_calc.Yr AS char(4)) + '-' + RIGHT('0' + CAST(day_calc.Mo AS varchar(2)), 2),
    LEFT(names.MonthName, 3) + ' ' + CAST(day_calc.Yr AS char(4)),
    DATEFROMPARTS(day_calc.Yr, day_calc.Mo, 1),
    day_calc.LastDayOfMonth, day_calc.Dy, day_calc.DowNumber, names.DayName, LEFT(names.DayName, 3),
    CASE WHEN day_calc.DowNumber >= 6 THEN 1 ELSE 0 END, day_calc.IsBank,
    CASE WHEN day_calc.IsBank = 1 THEN 'Bank holiday' WHEN day_calc.DowNumber >= 6 THEN 'Weekend' ELSE 'Weekday' END,
    CASE WHEN day_calc.Mo IN (12,1,2) THEN 'Winter' WHEN day_calc.Mo IN (3,4,5) THEN 'Spring'
         WHEN day_calc.Mo IN (6,7,8) THEN 'Summer' ELSE 'Autumn' END,
    CASE WHEN day_calc.Mo IN (12,1,2) THEN 1 WHEN day_calc.Mo IN (3,4,5) THEN 2 WHEN day_calc.Mo IN (6,7,8) THEN 3 ELSE 4 END,
    LEFT(names.MonthName, 3), (day_calc.Mo + 1) % 12 + 1,                -- a "season year" that starts in November
    CASE WHEN day_calc.[Date] BETWEEN @TempFrom AND @TempTo THEN 'Winter-spring 2023/24'
         WHEN day_calc.[Date] BETWEEN DATEADD(YEAR, -1, @TempFrom) AND DATEADD(YEAR, -1, @TempTo) THEN 'Winter-spring 2022/23'
         ELSE 'Other months' END,
    CASE WHEN day_calc.[Date] BETWEEN @TempFrom AND @TempTo THEN 1 ELSE 0 END,
    CASE WHEN day_calc.DowNumber = 7 AND day_calc.Mo IN (3, 10) AND day_calc.Dy > day_calc.LastDayOfMonth - 7 THEN 1 ELSE 0 END,
    N'No temperature', 0                                                 -- filled in once we know each day's average temperature, see section 7
FROM day_calc
CROSS APPLY (
    SELECT CHOOSE(day_calc.Mo, 'January','February','March','April','May','June','July','August','September','October','November','December') AS MonthName,
           CHOOSE(day_calc.DowNumber, 'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday') AS DayName
) names;

/* ------------------------------------------------------------------ 3. DimHour, DimEnergyType -- */
INSERT INTO dw.DimHour
SELECT h, RIGHT('0' + CAST(h AS varchar(2)), 2) + ':00',
       CASE WHEN h <= 5 THEN 'Overnight 00-05' WHEN h <= 8 THEN 'Morning 06-08' WHEN h <= 15 THEN 'Daytime 09-15'
            WHEN h <= 20 THEN 'Evening 16-20' ELSE 'Late evening 21-23' END,
       CASE WHEN h <= 5 THEN 1 WHEN h <= 8 THEN 2 WHEN h <= 15 THEN 3 WHEN h <= 20 THEN 4 ELSE 5 END
FROM (SELECT TOP (24) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS h FROM sys.all_objects) hours;

INSERT INTO dw.DimEnergyType VALUES
    (1, 'Electricity', 'kWh',          1.0,           N'Consumption assumed to be kWh (unit not stated in the source).'),
    (2, 'Gas',         'm3 (assumed)', @GasKwhPerUnit, N'Unit not stated in the source. Volume in m3 assumed; converted to kWh at the factor shown (editable parameter).');

/* ------------------------------------------------------------------ 4. FactEnergyHourly --
   Every date x hour x fuel combination that should exist gets a row here, whether or not
   there's a matching reading. A gap is never filled in with a guess - it's flagged instead,
   so nobody downstream mistakes an absent reading for a genuine zero. */
DECLARE @FuelCount int = (SELECT COUNT(*) FROM dw.DimEnergyType);

WITH expected_rows AS (
    SELECT dd.DateKey, h.HourKey, et.EnergyTypeKey, et.EnergyType, et.KwhPerUnit
    FROM dw.DimDate dd CROSS JOIN dw.DimHour h CROSS JOIN dw.DimEnergyType et
), source_rows AS (
    SELECT CONVERT(int, CONVERT(char(8), [Date], 112)) AS DateKey, CAST([Hour] AS int) AS HourKey,
           LTRIM(RTRIM([Energy Type])) AS EnergyType, [Consumption] AS Consumption
    FROM dbo.Energy_Use_Full
), matched AS (
    SELECT expected_rows.*, source_rows.Consumption
    FROM expected_rows
    LEFT JOIN source_rows
        ON source_rows.DateKey = expected_rows.DateKey
       AND source_rows.HourKey = expected_rows.HourKey
       AND source_rows.EnergyType = expected_rows.EnergyType
), flagged AS (
    SELECT matched.*,
           CASE WHEN Consumption IS NULL THEN 1 ELSE 0 END AS IsMissing,
           -- how many readings that date/fuel has in total, and whether the same hour is missing for both fuels at once
           SUM(CASE WHEN Consumption IS NOT NULL THEN 1 ELSE 0 END) OVER (PARTITION BY DateKey, EnergyTypeKey) AS ReadingsThatDay,
           SUM(CASE WHEN Consumption IS NULL     THEN 1 ELSE 0 END) OVER (PARTITION BY DateKey, HourKey)      AS FuelsMissingThatHour
    FROM matched
)
INSERT INTO dw.FactEnergyHourly (DateKey, HourKey, EnergyTypeKey, Consumption, ConsumptionKwh, IsMissing, MissingReason, IsHighLoadHour)
SELECT
    DateKey, HourKey, EnergyTypeKey,
    Consumption,
    CAST(CAST(Consumption AS decimal(12,4)) * KwhPerUnit AS decimal(14,3)),   -- decimal casts round halves away from zero, same rule as the R build
    IsMissing,
    CASE WHEN IsMissing = 0 THEN NULL
         WHEN ReadingsThatDay = 0 THEN 'Whole day'
         WHEN FuelsMissingThatHour = @FuelCount THEN 'Both fuels'
         ELSE 'Single fuel' END,
    CASE WHEN EnergyTypeKey = 1 AND IsMissing = 0 AND Consumption >= @HighLoadKwh THEN 1 ELSE 0 END
FROM flagged
ORDER BY DateKey, HourKey, EnergyTypeKey;

/* ------------------------------------------------------------------ 5. FactEnergyDaily --
   Rolls the hourly table up to one row per date/fuel, then works out the client's requirement:
   daily use as a % of the monthly total. That figure is only filled in for months where every
   single day has at least one reading - a month with a gap would otherwise understate its total
   and make every other day's share look artificially high. */
WITH daily_totals AS (
    SELECT DateKey, EnergyTypeKey,
           SUM(CASE WHEN IsMissing = 0 THEN 1 ELSE 0 END) AS ReadingsCount,
           SUM(Consumption)    AS DailyConsumption,        -- SUM ignores NULLs, which does the job of R's ifelse(missing, 0, x)
           SUM(ConsumptionKwh) AS DailyConsumptionKwh
    FROM dw.FactEnergyHourly
    GROUP BY DateKey, EnergyTypeKey
), with_month AS (
    SELECT daily_totals.DateKey, daily_totals.EnergyTypeKey, daily_totals.ReadingsCount,
           CASE WHEN daily_totals.ReadingsCount > 0 THEN CAST(daily_totals.DailyConsumption    AS decimal(14,3)) END AS Consumption,
           CASE WHEN daily_totals.ReadingsCount > 0 THEN CAST(daily_totals.DailyConsumptionKwh AS decimal(14,3)) END AS ConsumptionKwh,
           CASE WHEN daily_totals.ReadingsCount > 0 THEN 1 ELSE 0 END AS HasData,
           daily_totals.DateKey / 100 AS YearMonth, dd.DaysInMonth
    FROM daily_totals
    JOIN dw.DimDate dd ON dd.DateKey = daily_totals.DateKey
), with_month_totals AS (
    SELECT with_month.*,
           SUM(ISNULL(Consumption, 0)) OVER (PARTITION BY YearMonth, EnergyTypeKey) AS MonthConsumption,
           SUM(HasData)                OVER (PARTITION BY YearMonth, EnergyTypeKey) AS DaysWithData
    FROM with_month
)
INSERT INTO dw.FactEnergyDaily
SELECT
    DateKey, EnergyTypeKey, Consumption, ConsumptionKwh,
    ReadingsCount, 24 - ReadingsCount, HasData,
    CAST(MonthConsumption AS decimal(14,3)), DaysInMonth, DaysWithData,
    CASE WHEN DaysWithData = DaysInMonth THEN 1 ELSE 0 END,
    CASE WHEN DaysWithData = DaysInMonth AND MonthConsumption > 0
         THEN CAST(CAST(Consumption AS decimal(18,9)) / MonthConsumption AS decimal(9,6)) END
FROM with_month_totals
ORDER BY DateKey, EnergyTypeKey;

/* ------------------------------------------------------------------ 6. FactTemperatureHourly --
   The sensor sometimes sits in direct sun, which spikes mid-morning readings well above what
   the same day's afternoon shows. Those are flagged, treated like a missing reading, and then
   short gaps (up to @MaxInterpHours) are linearly interpolated using the nearest good reading
   on each side. */
WITH expected_hours AS (
    SELECT dd.DateKey, h.HourKey, ROW_NUMBER() OVER (ORDER BY dd.DateKey, h.HourKey) - 1 AS Position
    FROM dw.DimDate dd CROSS JOIN dw.DimHour h
    WHERE dd.[Date] BETWEEN @TempFrom AND @TempTo
), with_raw AS (
    SELECT expected_hours.*, source_temp.[Temperature C] AS Raw
    FROM expected_hours
    LEFT JOIN (
        SELECT CONVERT(int, CONVERT(char(8), [Date], 112)) AS DateKey, CAST([Hour] AS int) AS HourKey, [Temperature C]
        FROM dbo.Temperature
    ) source_temp ON source_temp.DateKey = expected_hours.DateKey AND source_temp.HourKey = expected_hours.HourKey
), with_afternoon_max AS (
    SELECT with_raw.*,
           MAX(CASE WHEN HourKey BETWEEN @AfternoonFrom AND @AfternoonTo THEN Raw END) OVER (PARTITION BY DateKey) AS AfternoonMax
    FROM with_raw
), with_sun_flag AS (
    SELECT with_afternoon_max.*,
           CASE WHEN Raw IS NOT NULL AND AfternoonMax IS NOT NULL AND HourKey BETWEEN @MorningFrom AND @MorningTo
                 AND Raw > AfternoonMax + @SunBufferC THEN 1 ELSE 0 END AS IsSunAffected
    FROM with_afternoon_max
), with_kept_value AS (
    -- "Kept" readings are the ones we trust: not missing, not sun-affected
    SELECT with_sun_flag.*, CASE WHEN Raw IS NULL OR IsSunAffected = 1 THEN NULL ELSE Raw END AS Kept
    FROM with_sun_flag
)
SELECT with_kept_value.*,
       MAX(CASE WHEN Kept IS NOT NULL THEN Position END)
           OVER (ORDER BY Position ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS PrevGoodPosition,
       MIN(CASE WHEN Kept IS NOT NULL THEN Position END)
           OVER (ORDER BY Position ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS NextGoodPosition
INTO #TempWorking
FROM with_kept_value;

INSERT INTO dw.FactTemperatureHourly
SELECT
    working.DateKey, working.HourKey, working.Raw,
    CAST(
        CASE WHEN working.Kept IS NOT NULL THEN working.Kept
             WHEN working.PrevGoodPosition IS NOT NULL AND working.NextGoodPosition IS NOT NULL
                  AND (working.NextGoodPosition - working.PrevGoodPosition) <= @MaxInterpHours + 1
             THEN ROUND(
                    prev_reading.Kept +
                    (next_reading.Kept - prev_reading.Kept) *
                    CAST(working.Position - working.PrevGoodPosition AS int) /
                    CAST(working.NextGoodPosition - working.PrevGoodPosition AS int),
                    2)
        END AS decimal(6,2)),
    CASE WHEN working.Raw IS NULL THEN 1 ELSE 0 END,
    working.IsSunAffected,
    CASE WHEN working.Kept IS NULL AND working.PrevGoodPosition IS NOT NULL AND working.NextGoodPosition IS NOT NULL
              AND (working.NextGoodPosition - working.PrevGoodPosition) <= @MaxInterpHours + 1 THEN 1 ELSE 0 END,
    CASE WHEN working.Raw IS NULL THEN 'Missing' WHEN working.IsSunAffected = 1 THEN 'Sun-affected' ELSE 'OK' END
FROM #TempWorking working
LEFT JOIN #TempWorking prev_reading ON prev_reading.Position = working.PrevGoodPosition
LEFT JOIN #TempWorking next_reading ON next_reading.Position = working.NextGoodPosition
ORDER BY working.DateKey, working.HourKey;

/* ------------------------------------------------------------------ 6b. FactTemperatureDaily -- */
WITH daily_stats AS (
    SELECT DateKey,
           COUNT(TemperatureRawC)   AS RawHours,
           COUNT(TemperatureCleanC) AS CleanHours,
           AVG(CAST(TemperatureRawC   AS decimal(18,8))) AS MeanRaw,     -- cast first, or AVG on decimal(6,2) truncates to 2 dp
           MAX(TemperatureRawC)                          AS MaxRaw,
           AVG(CAST(TemperatureCleanC AS decimal(18,8))) AS MeanClean,
           MIN(TemperatureCleanC) AS MinClean, MAX(TemperatureCleanC) AS MaxClean
    FROM dw.FactTemperatureHourly
    GROUP BY DateKey
)
INSERT INTO dw.FactTemperatureDaily
SELECT
    DateKey,
    CAST(ROUND(MeanRaw, 2) AS decimal(6,2)), MaxRaw,
    CASE WHEN CleanHours >= @MinUsableHours THEN CAST(ROUND(MeanClean, 2) AS decimal(6,2)) END,
    CASE WHEN CleanHours >= @MinUsableHours THEN MinClean END,
    CASE WHEN CleanHours >= @MinUsableHours THEN MaxClean END,
    RawHours, CleanHours,
    CASE WHEN CleanHours >= @MinUsableHours THEN 1 ELSE 0 END,
    CASE WHEN CleanHours >= @MinUsableHours
         THEN CASE WHEN @HddBaseC > MeanClean THEN CAST(ROUND(@HddBaseC - MeanClean, 2) AS decimal(6,2)) ELSE 0 END END
FROM daily_stats
ORDER BY DateKey;

/* ------------------------------------------------------------------ 7. temperature band on DimDate --
   Lets the energy facts be sliced by "how cold was it", without a fact-to-fact join. */
UPDATE dd
SET TempBand = CASE WHEN td.MeanTempCleanC IS NULL THEN N'No temperature'
                    WHEN td.MeanTempCleanC <  0  THEN N'Below 0' + @Deg + N'C'
                    WHEN td.MeanTempCleanC <  5  THEN N'0 to 5'  + @Deg + N'C'
                    WHEN td.MeanTempCleanC < 10  THEN N'5 to 10' + @Deg + N'C'
                    WHEN td.MeanTempCleanC < 15  THEN N'10 to 15' + @Deg + N'C'
                    WHEN td.MeanTempCleanC < 20  THEN N'15 to 20' + @Deg + N'C'
                    ELSE N'20' + @Deg + N'C and above' END,
    TempBandOrder = CASE WHEN td.MeanTempCleanC IS NULL THEN 0 WHEN td.MeanTempCleanC < 0 THEN 1 WHEN td.MeanTempCleanC < 5 THEN 2
                         WHEN td.MeanTempCleanC < 10 THEN 3 WHEN td.MeanTempCleanC < 15 THEN 4 WHEN td.MeanTempCleanC < 20 THEN 5 ELSE 6 END
FROM dw.DimDate dd
LEFT JOIN dw.FactTemperatureDaily td ON td.DateKey = dd.DateKey;

/* ------------------------------------------------------------------ 8. DataQualityLog --
   A plain-English record of what was found in the source files and how it was handled,
   so a reviewer doesn't have to reverse-engineer the rules from the code above. */

-- energy: missing readings, by fuel and by reason
DECLARE @TotalHourlyRows int = (SELECT COUNT(*) FROM dw.FactEnergyHourly);
DECLARE @TotalMissingHours int = (SELECT SUM(IsMissing) FROM dw.FactEnergyHourly);
DECLARE @MissingGasHours int = (SELECT COUNT(*) FROM dw.FactEnergyHourly WHERE IsMissing = 1 AND EnergyTypeKey = 2);
DECLARE @MissingElecHours int = (SELECT COUNT(*) FROM dw.FactEnergyHourly WHERE IsMissing = 1 AND EnergyTypeKey = 1);
DECLARE @WholeMissingDayCount int = (SELECT COUNT(*) FROM (SELECT DISTINCT DateKey, EnergyTypeKey FROM dw.FactEnergyHourly WHERE MissingReason = 'Whole day') x);
DECLARE @BothFuelsMissingHours int = (SELECT COUNT(*) FROM dw.FactEnergyHourly WHERE MissingReason = 'Both fuels');
DECLARE @SingleFuelGapHours int = (SELECT COUNT(*) FROM dw.FactEnergyHourly WHERE MissingReason = 'Single fuel');
DECLARE @SingleFuelGapDays int = (SELECT COUNT(DISTINCT DateKey) FROM dw.FactEnergyHourly WHERE MissingReason = 'Single fuel');
DECLARE @SourceEnergyRowCount int = (SELECT COUNT(*) FROM dbo.Energy_Use_Full);

DECLARE @WholeMissingDayList varchar(max) = (
    SELECT STRING_AGG(CAST(CONVERT(char(10), dd.[Date], 23) + ' (' + et.EnergyType + ')' AS varchar(max)), ', ')
           WITHIN GROUP (ORDER BY missing_days.DateKey, missing_days.EnergyTypeKey)
    FROM (SELECT DISTINCT DateKey, EnergyTypeKey FROM dw.FactEnergyHourly WHERE MissingReason = 'Whole day') missing_days
    JOIN dw.DimDate dd ON dd.DateKey = missing_days.DateKey
    JOIN dw.DimEnergyType et ON et.EnergyTypeKey = missing_days.EnergyTypeKey
);
DECLARE @BothFuelsMissingDayList varchar(max) = (
    SELECT STRING_AGG(CAST(CONVERT(char(10), dd.[Date], 23) AS varchar(max)), ', ') WITHIN GROUP (ORDER BY missing_days.DateKey)
    FROM (SELECT DISTINCT DateKey FROM dw.FactEnergyHourly WHERE MissingReason = 'Both fuels') missing_days
    JOIN dw.DimDate dd ON dd.DateKey = missing_days.DateKey
);

-- energy: incomplete months, e.g. "Electricity: Nov 2022 (11/30 days); Gas: Nov 2022 (11/30 days), Mar 2023 (30/31 days)"
DECLARE @IncompleteMonthDayCount int = (SELECT COUNT(*) FROM dw.FactEnergyDaily WHERE IsCompleteMonth = 0 AND HasData = 1);
DECLARE @IncompleteMonthList varchar(max) = (
    SELECT STRING_AGG(CAST(per_fuel.Summary AS varchar(max)), '; ') WITHIN GROUP (ORDER BY per_fuel.EnergyTypeKey)
    FROM (
        SELECT et.EnergyTypeKey,
               et.EnergyType + ': ' + STRING_AGG(
                   CAST(label.YearMonthLabel + ' (' + CAST(months.DaysWithData AS varchar(3)) + '/' + CAST(months.DaysInMonth AS varchar(3)) + ' days)' AS varchar(max)),
                   ', ') WITHIN GROUP (ORDER BY months.YearMonth) AS Summary
        FROM (
            SELECT DISTINCT DateKey / 100 AS YearMonth, EnergyTypeKey, DaysWithData, DaysInMonth
            FROM dw.FactEnergyDaily WHERE IsCompleteMonth = 0 AND HasData = 1
        ) months
        JOIN (SELECT DISTINCT DateKey / 100 AS YearMonth, YearMonthLabel FROM dw.DimDate) label ON label.YearMonth = months.YearMonth
        JOIN dw.DimEnergyType et ON et.EnergyTypeKey = months.EnergyTypeKey
        GROUP BY et.EnergyTypeKey, et.EnergyType
    ) per_fuel
);

DECLARE @AvgDailyElectricity varchar(20) = (SELECT CONVERT(varchar(20), CAST(AVG(CAST(Consumption AS decimal(18,6))) AS decimal(12,1))) FROM dw.FactEnergyDaily WHERE EnergyTypeKey = 1 AND ReadingsCount = 24);
DECLARE @AvgDailyGas varchar(20) = (SELECT CONVERT(varchar(20), CAST(AVG(CAST(Consumption AS decimal(18,6))) AS decimal(12,1))) FROM dw.FactEnergyDaily WHERE EnergyTypeKey = 2 AND ReadingsCount = 24);

DECLARE @ZeroGasDayCount int = (SELECT COUNT(*) FROM dw.FactEnergyDaily WHERE EnergyTypeKey = 2 AND ReadingsCount = 24 AND Consumption = 0);
DECLARE @ZeroGasDayList varchar(max) = (
    SELECT STRING_AGG(CAST(CONVERT(char(10), dd.[Date], 23) AS varchar(max)), ', ') WITHIN GROUP (ORDER BY zero_days.DateKey)
    FROM dw.FactEnergyDaily zero_days JOIN dw.DimDate dd ON dd.DateKey = zero_days.DateKey
    WHERE zero_days.EnergyTypeKey = 2 AND zero_days.ReadingsCount = 24 AND zero_days.Consumption = 0
);

DECLARE @HighLoadHourCount int = (SELECT COUNT(*) FROM dw.FactEnergyHourly WHERE IsHighLoadHour = 1);
DECLARE @HighLoadDayCount int = (SELECT COUNT(DISTINCT DateKey) FROM dw.FactEnergyHourly WHERE IsHighLoadHour = 1);
DECLARE @HighLoadSharePct varchar(20) = (
    SELECT CONVERT(varchar(20), CAST(100.0 * SUM(CASE WHEN IsHighLoadHour = 1 THEN Consumption END) / NULLIF(SUM(Consumption), 0) AS decimal(9,1)))
    FROM dw.FactEnergyHourly WHERE EnergyTypeKey = 1
);
DECLARE @HighLoadOvernightPct varchar(20) = (
    SELECT CONVERT(varchar(20), CAST(100.0 * SUM(CASE WHEN HourKey >= 23 OR HourKey <= 6 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS decimal(9,1)))
    FROM dw.FactEnergyHourly WHERE IsHighLoadHour = 1
);

-- temperature: missing / sun-affected / unusable days
DECLARE @TotalTempRows int = (SELECT COUNT(*) FROM dw.FactTemperatureHourly);
DECLARE @MissingTempHours int = (SELECT SUM(IsMissing) FROM dw.FactTemperatureHourly);
DECLARE @MissingTempDayCount int = (SELECT COUNT(DISTINCT DateKey) FROM dw.FactTemperatureHourly WHERE IsMissing = 1);
DECLARE @LongestTempGap int = (SELECT MAX(gap_length) FROM (SELECT COUNT(*) AS gap_length FROM dw.FactTemperatureHourly WHERE IsMissing = 1 GROUP BY DateKey) gaps);
DECLARE @SunAffectedHours int = (SELECT SUM(IsSunAffected) FROM dw.FactTemperatureHourly);
DECLARE @SunAffectedDayCount int = (SELECT COUNT(DISTINCT DateKey) FROM dw.FactTemperatureHourly WHERE IsSunAffected = 1);

DECLARE @HottestRawReading varchar(20), @HottestReadingHour varchar(2);
SELECT TOP (1) @HottestRawReading = CONVERT(varchar(20), TemperatureRawC), @HottestReadingHour = RIGHT('0' + CAST(HourKey AS varchar(2)), 2)
FROM dw.FactTemperatureHourly WHERE TemperatureRawC IS NOT NULL ORDER BY TemperatureRawC DESC, DateKey, HourKey;
DECLARE @MaxCleanTemperature varchar(20) = (SELECT CONVERT(varchar(20), MAX(TemperatureCleanC)) FROM dw.FactTemperatureHourly);

DECLARE @UnusableDayCount int = (SELECT COUNT(*) FROM dw.FactTemperatureDaily WHERE IsUsableDay = 0);
DECLARE @UnusableDayList varchar(max) = (
    SELECT STRING_AGG(CAST(CONVERT(char(10), dd.[Date], 23) AS varchar(max)), ', ') WITHIN GROUP (ORDER BY td.DateKey)
    FROM dw.FactTemperatureDaily td JOIN dw.DimDate dd ON dd.DateKey = td.DateKey WHERE td.IsUsableDay = 0
);
DECLARE @DaysWithNoTemperature int = (SELECT COUNT(*) FROM dw.DimDate WHERE HasTemperature = 0);
DECLARE @TotalDayCount int = (SELECT COUNT(*) FROM dw.DimDate);

-- both sources: duplicates and out-of-range values
DECLARE @DuplicateKeyCount int =
      (SELECT ISNULL(SUM(occurrences - 1), 0) FROM (SELECT COUNT(*) AS occurrences FROM dbo.Energy_Use_Full GROUP BY [Date], CAST([Hour] AS int), [Energy Type]) e WHERE occurrences > 1)
    + (SELECT ISNULL(SUM(occurrences - 1), 0) FROM (SELECT COUNT(*) AS occurrences FROM dbo.Temperature     GROUP BY [Date], CAST([Hour] AS int)) t WHERE occurrences > 1);
DECLARE @OutOfRangeValueCount int =
      (SELECT COUNT(*) FROM dbo.Energy_Use_Full WHERE [Consumption] < 0)
    + (SELECT COUNT(*) FROM dbo.Temperature WHERE [Temperature C] < -30 OR [Temperature C] > 45);

INSERT INTO dw.DataQualityLog (IssueNo, Dataset, Issue, RecordsAffected, Evidence, Treatment) VALUES
(1, 'Energy', N'Missing hourly readings (gaps in the Date x Hour x Energy Type grid)', @TotalMissingHours,
 CONCAT(@MissingGasHours, N' gas and ', @MissingElecHours, N' electricity readings absent from ', @TotalHourlyRows, N' expected (',
        CONVERT(varchar(20), CAST(100.0 * @TotalMissingHours / @TotalHourlyRows AS decimal(9,2))), N'%). Electricity is almost complete; gas carries nearly all gaps.'),
 N'Load onto a complete grid and keep each gap as a row with NULL consumption, IsMissing = 1 and a reason. Do NOT impute: invented usage would corrupt daily and monthly totals. Affected days carry MissingReadings > 0 so totals can be read as "at least".'),
(2, 'Energy', N'A whole day with no readings for one fuel', @WholeMissingDayCount,
 ISNULL(@WholeMissingDayList, 'none'),
 N'Keep the day as 24 flagged rows. The month is then NOT complete for that fuel, so it is excluded from the "% of monthly total" view for that fuel only.'),
(3, 'Energy', N'Same hour missing for both fuels (clock-change / timestamp handling)', @BothFuelsMissingHours,
 CONCAT(ISNULL(@BothFuelsMissingDayList, ''), N'. Spring clock changes legitimately lose hour 01; the autumn change shows no repeated hour and a missing hour 00 on 28-29 Oct 2023.'),
 N'Flag, do not fill. Root cause is an hour-of-day key with no time zone: ask the source to supply UTC timestamps. Days with 23 readings are marked via ReadingsCount.'),
(4, 'Energy', N'Isolated single-fuel gaps (gas meter drop-outs)', @SingleFuelGapHours,
 CONCAT(@SingleFuelGapHours, N' single hours or short runs, all gas, scattered over ', @SingleFuelGapDays, N' days.'),
 N'Keep as flagged NULLs. Effect on a day is small (typically 1 hour of 24), but the day''s total is understated by whatever was used in that hour.'),
(5, 'Energy', N'Incomplete months (excluded from the daily % of the monthly total)', @IncompleteMonthDayCount,
 ISNULL(@IncompleteMonthList, 'none'),
 N'A month is complete for a fuel when every calendar day has at least one reading. Only complete months get DailyPctOfMonth (NULL otherwise); totals and trends still use whatever data exists, and days with a few missing hours stay in (flagged). Requiring all 24 hours every day would discard about half of the gas months.'),
(6, 'Energy', N'Consumption unit is not stated (electricity vs gas are different units)', @SourceEnergyRowCount,
 CONCAT(N'Average per day: electricity ', @AvgDailyElectricity, N', gas ', @AvgDailyGas, N'. Those magnitudes only make sense as kWh and m3 (a gas figure this small cannot be kWh for a family home).'),
 N'Confirm with the client. Electricity treated as kWh; gas assumed to be m3 and converted at 11.2 kWh/m3 in DimEnergyType.KwhPerUnit (editable) so a combined kWh view is possible. The daily % of month view is unit-free and unaffected.'),
(7, 'Energy', N'Whole days of zero gas', @ZeroGasDayCount,
 ISNULL(@ZeroGasDayList, 'none'),
 N'Retained. Plausible when the house is empty or in summer, but a zero in the heating season (late October) may be a meter drop-out - flagged for the client to confirm.'),
(8, 'Energy', N'Very large hourly electricity readings (>= 5 kWh in one hour)', @HighLoadHourCount,
 CONCAT(@HighLoadHourCount, N' hours on ', @HighLoadDayCount, N' days carry ', @HighLoadSharePct, N'% of all electricity; ', @HighLoadOvernightPct, N'% fall between 23:00 and 07:00.'),
 N'Not errors: a repeatable overnight pattern of 7-9 kWh per hour, consistent with EV charging. Kept and flagged with IsHighLoadHour so it can be isolated or excluded from base-load analysis.'),
(9, 'Energy', N'Hour stored as text, no timestamp or time zone', @SourceEnergyRowCount,
 N'Hour is a zero-padded text field (''00''..''23'') and Date a separate text-like date; the local time zone is not recorded.',
 N'Converted to a numeric HourKey and a DateKey; both are dimension keys. Recommend the source delivers UTC timestamps.'),
(10, 'Temperature', N'Missing hourly readings', @MissingTempHours,
 CONCAT(@MissingTempHours, N' of ', @TotalTempRows, N' expected hours on ', @MissingTempDayCount, N' dates; the longest single-day gap is ', @LongestTempGap, N' hours.'),
 N'Gaps of up to 6 consecutive hours are linearly interpolated (IsRepaired = 1); longer gaps stay NULL rather than inventing a temperature.'),
(11, 'Temperature', N'Sun-affected readings (sensor in direct sunlight overstates temperature)', @SunAffectedHours,
 CONCAT(@SunAffectedHours, N' readings on ', @SunAffectedDayCount, N' days, all between 05:00 and 11:59. Highest raw reading ', @HottestRawReading, N' C (at ', @HottestReadingHour, N':00), cleansed maximum ', @MaxCleanTemperature, N' C.'),
 N'Rule: a reading between 05:00 and 11:59 more than 2.0 C above that day''s 12:00-17:59 maximum is flagged, blanked and interpolated; the raw value stays in TemperatureRawC. Limitation: sustained overstatement on hot clear days cannot be told from real heat without a reference weather station.'),
(12, 'Temperature', N'Days without enough usable hours for daily statistics', @UnusableDayCount,
 ISNULL(@UnusableDayList, 'none'),
 N'Daily mean, minimum, maximum and heating degree days are set to NULL when fewer than 20 usable hours remain, so a half-observed day cannot distort weather comparisons.'),
(13, 'Temperature', N'Temperature starts one year after the energy data', @DaysWithNoTemperature,
 CONCAT(@DaysWithNoTemperature, N' of ', @TotalDayCount, N' energy days (', CONVERT(char(10), @EnergyFrom, 23), N' to ', CONVERT(char(10), DATEADD(DAY, -1, @TempFrom), 23), N') have no temperature.'),
 N'Weather analysis is limited to the overlap. DimDate.ComparisonPeriod aligns the two 20 Nov - 30 Jun windows for year-on-year comparison; that comparison cannot be weather-adjusted because year one has no temperatures.'),
(14, 'Both', N'Duplicate keys (Date, Hour, Energy Type)', @DuplicateKeyCount,
 N'None found in either table.',
 N'The composite primary keys on the fact tables make the load fail loudly if duplicates ever appear.'),
(15, 'Both', N'NULL, negative or out-of-range values', @OutOfRangeValueCount,
 N'None found (temperatures span a plausible UK range apart from the sun artefact above).',
 N'Column types and NOT NULL constraints on the input tables reject bad values at load time.');

DROP TABLE IF EXISTS #TempWorking;

/* ------------------------------------------------------------------ 9. sanity checks -- */
-- row counts (expected on the supplied files: 589 / 24 / 2 / 28,272 / 1,178 / 5,376 / 224 / 15)
SELECT 'DimDate' AS TableName, COUNT(*) AS RowCount FROM dw.DimDate
UNION ALL SELECT 'DimHour',               COUNT(*) FROM dw.DimHour
UNION ALL SELECT 'DimEnergyType',         COUNT(*) FROM dw.DimEnergyType
UNION ALL SELECT 'FactEnergyHourly',      COUNT(*) FROM dw.FactEnergyHourly
UNION ALL SELECT 'FactEnergyDaily',       COUNT(*) FROM dw.FactEnergyDaily
UNION ALL SELECT 'FactTemperatureHourly', COUNT(*) FROM dw.FactTemperatureHourly
UNION ALL SELECT 'FactTemperatureDaily',  COUNT(*) FROM dw.FactTemperatureDaily
UNION ALL SELECT 'DataQualityLog',        COUNT(*) FROM dw.DataQualityLog;

-- missing-energy breakdown (expected: Whole day 24, Both fuels 8, Single fuel 19 -> 51 missing overall)
SELECT MissingReason, COUNT(*) AS RowCount FROM dw.FactEnergyHourly WHERE IsMissing = 1 GROUP BY MissingReason;

-- temperature cleansing (expected: 90 missing, 128 sun-affected, 139 repaired, 5 unusable days)
SELECT SUM(IsMissing) AS Missing, SUM(IsSunAffected) AS SunAffected, SUM(IsRepaired) AS Repaired FROM dw.FactTemperatureHourly;
SELECT COUNT(*) AS UnusableDays FROM dw.FactTemperatureDaily WHERE IsUsableDay = 0;

-- complete months per fuel (expected: Electricity 19, Gas 18 - Mar 2023 gas has a whole missing day)
SELECT et.EnergyType, COUNT(DISTINCT f.DateKey / 100) AS CompleteMonths
FROM dw.FactEnergyDaily f JOIN dw.DimEnergyType et ON et.EnergyTypeKey = f.EnergyTypeKey
WHERE f.IsCompleteMonth = 1 GROUP BY et.EnergyType;

-- every complete month's daily shares should add up to 100% - this should return no rows
SELECT f.DateKey / 100 AS YearMonth, f.EnergyTypeKey, SUM(f.DailyPctOfMonth) AS TotalShare
FROM dw.FactEnergyDaily f WHERE f.IsCompleteMonth = 1
GROUP BY f.DateKey / 100, f.EnergyTypeKey
HAVING ABS(SUM(f.DailyPctOfMonth) - 1) > 0.0001;

/* ------------------------------------------------------------------ 10. the client's headline view -- */
-- daily energy use as a % of the monthly total, complete months only
SELECT dd.[Date], dd.YearMonthLabel, et.EnergyType, f.Consumption, f.MonthConsumption, f.DailyPctOfMonth, 1.0 / dd.DaysInMonth AS EvenShare
FROM dw.FactEnergyDaily f
JOIN dw.DimDate dd ON dd.DateKey = f.DateKey
JOIN dw.DimEnergyType et ON et.EnergyTypeKey = f.EnergyTypeKey
WHERE f.IsCompleteMonth = 1
ORDER BY dd.[Date], et.EnergyType;

-- the full data-quality log, for the write-up
SELECT * FROM dw.DataQualityLog ORDER BY IssueNo;
