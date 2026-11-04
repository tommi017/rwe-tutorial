# Loading the RWE tutorial data into Aiven

## Who this tutorial is for and what it teaches

This tutorial is for students, analysts, and researchers who know basic R or
SAS and want a practical introduction to real-world evidence (RWE) workflows.
It is not a production database or a replacement for formal clinical,
statistical, or cloud-engineering training.

By completing the tutorial, users will:

- become familiar with storing and processing a larger synthetic dataset in a
  cloud PostgreSQL environment;
- practice using SQL to inspect, filter, join, and aggregate RWE-style data;
- connect to the same database from R and SAS-compatible ODBC tooling;
- learn basic RWE concepts such as cohorts, index dates, follow-up, outcomes,
  censoring, incidence, and risk factors;
- reproduce a simplified version of selected results from an RWE respiratory
  hospitalization study using synthetic data; and
- understand the practical differences between local files, database
  processing, and analysis performed in R or SAS.

The tutorial uses synthetic Synthea data for teaching. Its results are
illustrative and must not be interpreted as clinical evidence.

This guide loads the small teaching subset into a free Aiven PostgreSQL
service. It uses a manually configured Windows ODBC data source and the R
packages `DBI` and `odbc`. The full local curated dataset is not changed.

The data are synthetic. Do not use this workflow for confidential or
identifiable data without an appropriate security review.

## 1. Download the teaching data and scripts

1. Download `rwe-tutorial-v1.0.zip` from the
   [Releases page](https://github.com/tommi017/rwe-tutorial/releases/latest)
   and unzip it. It contains the scripts and the CSV files in `raw_data/`.
2. (Only if you used `git clone` instead) unzip the data into the `raw_data/`
   folder. The CSV files are not stored in git because some of them are larger
   than GitHub's 100 MB file limit.

The loader only needs the CSV files to be present in the `raw_data/` folder
next to `load_to_aiven.R`.

Keep all ten CSV files in the same directory. The loader expects these names:

```text
patients.csv
icd10cm_dictionary.csv
death.csv
payers.csv
encounters.csv
conditions.csv
observations.csv
medications.csv
payer_transitions.csv
atc_dictionary.csv
```

The repository has this layout:

```text
rwe-tutorial/
|-- load_to_aiven.R
|-- raw_data/
|   |-- patients.csv
|   |-- encounters.csv
|   `-- ...
|-- instruction/
|-- analysis_files/
`-- output/
```

The loader finds its own location and uses the sibling `raw_data/` folder.
Therefore the package can be moved anywhere on the user's computer; it does
not depend on the current working directory.

## 2. Create an Aiven PostgreSQL service

1. Create an account at [Aiven](https://console.aiven.io/).
2. Create a PostgreSQL service.
3. Select the free plan if it is available for your account and region.
4. Choose a region close to the tutorial users.
5. Wait until the service is running.
6. Open the service's **Connection information** page.
7. Download the PostgreSQL CA certificate. Save it outside the Git repository,
   for example as `C:\Users\yourname\Documents\aiven-ca.pem`.

The free plan and its limits can change. The subset is approximately 500 MiB
as CSV, but PostgreSQL also needs space for table storage and future indexes.

## 3. Install PostgreSQL ODBC and R packages

Install the PostgreSQL Unicode ODBC driver from the
[official PostgreSQL ODBC downloads](https://odbc.postgresql.org/).
On 64-bit Windows, install the 64-bit driver and use the exact driver name
shown in **ODBC Data Sources (64-bit)**. In the screenshots and this tutorial
we use `PostgreSQL Unicode(x64)`.

In R, install the client packages once:

```r
install.packages(c("DBI", "odbc"))
```

Run the loader in RStudio so it can display a password dialog. If you use
plain R from a terminal, install `getPass` as well:

```r
install.packages("getPass")
```

The loader uses ODBC rather than a hard-coded database-specific R driver, so
the same approach can later be used from SAS through its PostgreSQL/ODBC
configuration.

## 4. Create the Windows ODBC data source

Open **ODBC Data Sources (64-bit)** from the Windows Start menu and create a
new **User DSN** using the PostgreSQL Unicode driver. Use this fixed name:

```text
RWE_AIVEN_POSTGRES
```

Enter the following values from Aiven's **Connection information** page:

| ODBC field | Value |
|---|---|
| Data Source | `RWE_AIVEN_POSTGRES` |
| Server | Aiven host |
| Port | Aiven port |
| Database | Aiven database name |
| User name | `avnadmin` |
| Password | Aiven service password |
| SSL mode | `verify-full` |
| Root certificate | Path to the downloaded Aiven CA `.pem` file |

Save the password in the local ODBC DSN configuration. Do not include it in
screenshots, the GitHub repository, or tutorial files. Save and test the DSN
in the ODBC configuration window before continuing.

The loader refers only to the DSN name `RWE_AIVEN_POSTGRES`; server, port,
database, TLS certificate, and driver details are all held by the local ODBC
configuration.

## 5. Run the loader

From the downloaded `rwe-tutorial` folder:

```powershell
Rscript .\load_to_aiven.R
```

The script uses all connection details saved in the ODBC DSN. No Aiven
connection fields or passwords need to be pasted into PowerShell or R. It
automatically uses the `raw_data/` folder next to the script.

When using RStudio, first open and save `load_to_aiven.R` from the downloaded
package. You can then use **Source** or **Run**. The script uses RStudio's
active document path to find the sibling `raw_data/` folder, so changing the
working directory is not required. An unsaved copied script cannot be located
reliably; save it before running.

The script:

1. connects through the `RWE_AIVEN_POSTGRES` DSN,
2. creates the `rwe` schema if it does not exist,
3. replaces only the ten tables in that schema,
4. loads date and datetime columns with PostgreSQL-compatible types,
5. never creates or changes tables outside the `rwe` schema.

## 7. Inspect conditions in scope

After the loader finishes, open `analysis_files/01_cohort.R` in RStudio and
run the complete script. This is intentionally the first small analysis step:
it uses SQL inside Aiven to show condition records with COPD or asthma ICD-10-CM
codes.

```text
SELECT patient_id, condition_date, icd10cm_code, condition_description
FROM rwe.conditions
WHERE icd10cm_code LIKE 'J44%'
   OR icd10cm_code LIKE 'J45%';
```

The R script builds this query with the `glue` package and displays the first
20 rows in the RStudio console. At this stage no cohort table is created and
no source table is changed.

## 8. Check the loaded data

In an SQL client connected to Aiven, run:

```sql
SELECT COUNT(*) FROM rwe.conditions
WHERE icd10cm_code LIKE 'J44%'
   OR icd10cm_code LIKE 'J45%';
```

The next step will use these condition records to define a patient-level
cohort for the article-inspired respiratory hospitalization analysis:

- age 65 or older,
- COPD and asthma disease groups,
- first qualifying diagnosis as cohort entry,
- first respiratory inpatient hospitalization as the primary outcome,
- death and end of follow-up as censoring events.

That analytic table will be created separately from the source tables so that
the loaded teaching data remain auditable and reusable.
