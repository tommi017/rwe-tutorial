# RWE tutorial

A hands-on tutorial on real-world evidence (RWE) analysis in R using a
synthetic electronic health record dataset in PostgreSQL (Aiven). The worked
example is inspired by the study *Incidence, risk factors, and outcomes of
respiratory related hospitalizations in older patients with COPD, asthma, and
bronchiectasis* ([PMC12216934](https://pmc.ncbi.nlm.nih.gov/articles/PMC12216934/)):
build a cohort of patients aged 60+ with COPD, asthma or bronchiectasis, apply
inclusion criteria with a one-year baseline and one-year follow-up, define the
hospitalization outcome, and reproduce part of the article's Table 1.

All data are **synthetic**. No real patient is represented, and results must not
be interpreted clinically.

## Repository layout

```text
rwe-tutorial/
â”śâ”€â”€ load_to_aiven.R   # loads the CSV files into the Aiven PostgreSQL database
â”śâ”€â”€ raw_data/         # CSV files (download from the Releases page, see below)
â”śâ”€â”€ instruction/      # setup and loading instructions
â”śâ”€â”€ analysis_files/   # analysis scripts
â”‚   â”śâ”€â”€ 01_cohort.R       # cohort and outcome on Aiven (SQL via ODBC)
â”‚   â””â”€â”€ 01_cohort_csv.R   # the same analysis on the CSV files (DuckDB)
â””â”€â”€ output/           # reference and user-generated outputs
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

  > Based on "RWE tutorial" by Tomasz MikoĹ‚ajczyk,
  > https://github.com/tommi017/rwe-tutorial, licensed under PolyForm
  > Noncommercial 1.0.0 / CC BY-NC 4.0.
- Commercial use requires a separate license. Please contact me via
  [GitHub](https://github.com/tommi017).
- This is a source-available license, not an OSI-approved open source license.

### Third-party material

- The synthetic patient records were generated with
  [Synthea](https://github.com/synthetichealth/synthea) (Apache License 2.0)
  and then curated and adjusted for teaching purposes.
- `icd10cm_dictionary.csv` is based on ICD-10-CM and SNOMED CT to ICD-10-CM
  mappings published by the U.S. National Library of Medicine / CDC.
- `atc_dictionary.csv` and the `atc_code*` columns use the WHO ATC
  classification and RxNorm, obtained through OHDSI Athena. These remain
  subject to the terms of their owners ([WHO Collaborating Centre for Drug
  Statistics Methodology](https://atcddd.fhi.no/), [NLM RxNorm](https://www.nlm.nih.gov/research/umls/rxnorm/)),
  and the licenses above do not apply to them.
