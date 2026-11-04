# RWE tutorial

A hands-on tutorial on real-world evidence (RWE) analysis in R and SQL, built on
synthetic electronic health record data.

**Who is it for?** Anyone interested in RWE analysis: programmers and data
analysts who want to explore this field, biostatisticians who want to strengthen
their programming skills, and epidemiologists who want to understand the data and
programming aspects and nuances of observational database studies.

**The data.** The records come from [Synthea](https://github.com/synthetichealth/synthea)
and were then modified for teaching purposes so that the dataset supports
reproducing the analysis of a published study.

**The analysis.** The tutorial follows a typical industry workflow for RWE
database studies, from raw data to publication-ready tables, listings and figures
(TLFs): build a cohort, apply inclusion and exclusion criteria, identify
exposure, derive patient demographic and clinical characteristics, define an
outcome variable, and reproduce publication outputs. The worked example is
inspired by *Incidence, risk factors, and outcomes of respiratory related
hospitalizations in older patients with COPD, asthma, and bronchiectasis*
([PMC12216934](https://pmc.ncbi.nlm.nih.gov/articles/PMC12216934/)). It is a
teaching reconstruction, not a replication of the study's results.

**The working environment.** Analyses are written in SQL and run from R, the way
real-world data are typically stored and queried in industry: in a relational
database rather than in flat files in memory. You can use either:

- a **self-hosted PostgreSQL database on Aiven** (free plan), loaded with the
  provided script, or
- a **local DuckDB** database that reads the CSV files directly, with no account
  or setup.

Both paths use the same data and the same cohort logic, so you can start locally
and move to a server database later.

All data are **synthetic**. No real patient is represented, and results must not
be interpreted clinically.

## Repository layout

```text
rwe-tutorial/
|-- load_to_aiven.R   # loads the CSV files into the Aiven PostgreSQL database
|-- raw_data/         # CSV files (download from the Releases page, see below)
|-- instruction/      # setup and loading instructions
|-- analysis_files/   # analysis scripts
|   |-- 01_cohort.R       # cohort and outcome on Aiven (SQL via ODBC)
|   `-- 01_cohort_csv.R   # the same analysis on the CSV files (DuckDB)
`-- output/           # reference and user-generated outputs
```

## Getting started

1. Download `rwe-tutorial-v1.0.zip` from the
   [Releases page](https://github.com/tommi017/rwe-tutorial/releases/latest)
   and unzip it. It contains the whole project, including the CSV files in
   `raw_data/`, so it is ready to use. (If you prefer `git clone`, also unzip
   the data into `raw_data/` - the CSVs are not in git because some exceed
   GitHub's 100 MB file limit.)
2. Follow [instruction/AIVEN_TUTORIAL.md](instruction/AIVEN_TUTORIAL.md) to
   create a free Aiven database and load the data.
3. Open `analysis_files/01_cohort.R` in RStudio and run it step by step.

To work without a database, run `analysis_files/01_cohort_csv.R`. It needs the
`DBI`, `duckdb` and `glue` R packages.

## License and attribution

- Code (R scripts, SQL) is licensed under the
  [PolyForm Noncommercial License 1.0.0](LICENSE).
- Documentation and the synthetic data are licensed under
  [Creative Commons Attribution-NonCommercial 4.0 International](LICENSE-CC-BY-NC-4.0.txt).
- You may copy, adapt and redistribute this material for **noncommercial**
  purposes (e.g. personal learning, teaching, research), provided that you keep
  the copyright notice and give appropriate credit, for example:

  > Based on "RWE tutorial" by Tomasz Mikołajczyk,
  > https://github.com/tommi017/rwe-tutorial, licensed under PolyForm
  > Noncommercial 1.0.0 / CC BY-NC 4.0.
- Commercial use requires a separate license. Please contact me via
  [GitHub](https://github.com/tommi017).
- This is a source-available license, not an OSI-approved open source license.

### Third-party material

- The synthetic patient records were generated with
  [Synthea](https://github.com/synthetichealth/synthea) (Apache License 2.0)
  and then curated and adjusted for teaching purposes.
- `icd10cm_dictionary.csv` is based on ICD-10-CM published by the
  U.S. National Center for Health Statistics / CDC.
- `atc_dictionary.csv` and the `atc_code*` columns use the WHO ATC
  classification and RxNorm, obtained through OHDSI Athena. These remain
  subject to the terms of their owners ([WHO Collaborating Centre for Drug
  Statistics Methodology](https://atcddd.fhi.no/), [NLM RxNorm](https://www.nlm.nih.gov/research/umls/rxnorm/)),
  and the licenses above do not apply to them.
