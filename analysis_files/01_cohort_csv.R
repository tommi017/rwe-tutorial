# Environment setup
  # Library imports
  library(DBI)
  library(duckdb)
  library(glue)

  # This is a copy of 01_cohort.R that runs on the CSV files instead of Aiven. The SQL is the same, but it uses
  # only syntax that works in both PostgreSQL and DuckDB, so the final version can be moved back to Aiven.
  schema <- "rwe"
  data_dir <- Sys.getenv("RWE_DATA_DIR", unset = c("raw_data", "../raw_data", "rwe_tutorial/raw_data")[
    dir.exists(c("raw_data", "../raw_data", "rwe_tutorial/raw_data"))][1])

  # Define the connection to a temporary DuckDB database in memory.
  con <- dbConnect(duckdb())

  # Study design parameters.
  min_age <- 60            # minimum age at index
  baseline_days <- 365     # required baseline before the index date
  follow_up_days <- 365    # required and maximum follow-up after the index date
  min_stay_days <- 2       # minimum length of a qualifying hospital stay

  # Helper that builds a condition on the seven ATC columns of the medications table, e.g. atc_in('J05AH')
  atc_in <- function(prefix, alias = "m") {
    paste0("(", paste0("left(", alias, ".atc_code", 1:7, ", ", nchar(prefix), ") = '", prefix, "'", collapse = " or "), ")")
  }


# Load the CSV files into tables with the same names as in Aiven.
  dbExecute(con, glue("create schema {schema};"))
  csv_path <- function(name) file.path(data_dir, paste0(name, ".csv"))
  for (table in c("patients", "death", "encounters", "conditions")) {
    dbExecute(con, glue("create table {schema}.{table} as select * from read_csv('{csv_path(table)}', header = true);"))
  }
  # Dates and times with a time zone suffix are read as text and converted so that they behave like in Aiven.
  dbExecute(con, glue("
    create table {schema}.icd10cm_dictionary as 
      SELECT * FROM read_csv('{csv_path('icd10cm_dictionary')}', header = true, all_varchar = true);
    create table {schema}.medications as 
      SELECT * REPLACE (
        cast(replace(replace(start_datetime, 'T', ' '), 'Z', '') as timestamp) as start_datetime,
        cast(replace(replace(end_datetime, 'T', ' '), 'Z', '') as timestamp) as end_datetime
      )
      FROM read_csv('{csv_path('medications')}', header = true, types = {{'start_datetime': 'VARCHAR', 'end_datetime': 'VARCHAR'}});
    create table {schema}.payer_transitions as 
      SELECT * REPLACE (
        cast(left(start_date, 10) as date) as start_date,
        cast(left(end_date, 10) as date) as end_date
      )
      FROM read_csv('{csv_path('payer_transitions')}', header = true, types = {{'start_date': 'VARCHAR', 'end_date': 'VARCHAR'}});
  "))


# ETL
  # Prepare the exposure codelist table based on ICD-10-CM codes for COPD, asthma, and bronchiectasis.
  dbExecute(con, glue("
    drop table if exists exposure_codelist;
    create temporary table exposure_codelist as 
      SELECT *
      FROM(
        SELECT * 
          ,case when left(icd10cm_code,3) in ('J41','J42','J43','J44') then 1 else 0 end as copd
          ,case when left(icd10cm_code,3) in ('J45','J46') then 1 else 0 end as asthma
          ,case when left(icd10cm_code,3) in ('J47') then 1 else 0 end as bronchiectasis
        FROM {schema}.icd10cm_dictionary
      ) as a
      where copd+asthma+bronchiectasis>0
    ;
  "))

  # Find patients with the exposure of interest by joining the conditions table with the exposure codelist prepared above.
  dbExecute(con, glue("
    drop table if exists exposure_all;
    create temporary table exposure_all as 
      SELECT a.*
        ,b.copd
        ,b.asthma
        ,b.bronchiectasis
        ,min(condition_date) over (partition by patient_id) as first_condition_date
      FROM {schema}.conditions as a
        INNER JOIN exposure_codelist as b ON a.icd10cm_code = b.icd10cm_code
    ;
  "))

  # Identify the index exposure for each patient
  dbExecute(con, glue("
    drop table if exists index_exposure;
    create temporary table index_exposure as 
      SELECT a.patient_id
        ,min(a.encounter_id) as index_encounter_id
        ,a.condition_date as index_date
        ,max(a.copd) as copd
        ,max(a.asthma) as asthma
        ,max(a.bronchiectasis) as bronchiectasis
        ,case when max(a.copd)+max(a.asthma)+max(a.bronchiectasis) = 1 and max(a.copd) = 1 then 'COPD'
              when max(a.copd)+max(a.asthma)+max(a.bronchiectasis) = 1 and max(a.asthma) = 1 then 'Asthma'
              when max(a.copd)+max(a.asthma)+max(a.bronchiectasis) = 1 and max(a.bronchiectasis) = 1 then 'Bronchiectasis'
              when max(a.copd)+max(a.asthma)+max(a.bronchiectasis) > 1 then 'Multiple'
              else NULL
        end as exposure
        ,substr(repeat('+COPD', max(a.copd))||repeat('+Asthma', max(a.asthma))||repeat('+Bronchiectasis', max(a.bronchiectasis)), 2) as exposure_details
      FROM exposure_all as a
      WHERE condition_date = first_condition_date
      GROUP BY 1,3
    ;
  "))

  # Check: there must be exactly one index row per patient (both numbers should be equal).
  dbGetQuery(con, "
    SELECT count(*) as n_rows, count(distinct patient_id) as n_patients FROM index_exposure;
  ")

  # Prepare the outcome codelist. As in the article, a hospitalization counts if the diagnosis is an exacerbation of
  # COPD, asthma, or bronchiectasis (J41-J47) or an acute respiratory infection (influenza, pneumonia, selected
  # pharyngitis, tonsillitis, bronchitis, and bronchiolitis codes).
  dbExecute(con, glue("
    drop table if exists outcome_codelist;
    create temporary table outcome_codelist as 
      SELECT *
      FROM(
        SELECT icd10cm_code
          ,case when left(icd10cm_code,3) in ('J41','J42','J43','J44','J45','J46','J47') then 1 else 0 end as exacerbation
          ,case when left(icd10cm_code,3) in ('J09','J10','J11','J12','J13','J14','J15','J16','J17','J18')
                  or left(icd10cm_code,5) in ('J02.8','J03.8','J20.0','J20.1','J20.4','J20.5','J20.6','J20.8','J21.1','J21.8') then 1 else 0 end as ari
        FROM {schema}.icd10cm_dictionary
      ) as a
      where exacerbation+ari>0
    ;
  "))

  # Find qualifying hospitalizations: inpatient encounters lasting at least min_stay_days with an outcome diagnosis
  # recorded on the encounter, or with a neuraminidase inhibitor (ATC J05AH) given during the stay.
  dbExecute(con, glue("
    drop table if exists qualifying_hospitalizations;
    create temporary table qualifying_hospitalizations as 
      SELECT e.patient_id
        ,e.encounter_id
        ,e.start_date
        ,e.end_date
        ,e.end_date-e.start_date as length_of_stay
        ,coalesce(max(o.exacerbation),0) as exacerbation
        ,coalesce(max(o.ari),0) as ari
        ,max(case when m.encounter_id is not null then 1 else 0 end) as neuraminidase_inhibitor
      FROM {schema}.encounters as e
        LEFT JOIN {schema}.conditions as c ON e.encounter_id = c.encounter_id
        LEFT JOIN outcome_codelist as o ON c.icd10cm_code = o.icd10cm_code
        LEFT JOIN (
          SELECT distinct m.encounter_id
          FROM {schema}.medications as m
          WHERE {atc_in('J05AH')}
        ) as m ON e.encounter_id = m.encounter_id
      WHERE e.encounter_class = 'inpatient'
        and e.end_date-e.start_date >= {min_stay_days}
      GROUP BY 1,2,3,4
      HAVING coalesce(max(o.exacerbation),0)+coalesce(max(o.ari),0)+max(case when m.encounter_id is not null then 1 else 0 end) > 0
    ;
  "))

  # Find follow-up hospitalizations for each patient within the follow-up period after the index exposure
  dbExecute(con, glue("
    drop table if exists hospitalizations_all;
    create temporary table hospitalizations_all as 
      SELECT a.*
        ,b.encounter_id as hospitalization_encounter_id
        ,b.start_date-a.index_date as time_to_hospitalization
        ,b.length_of_stay
        ,b.exacerbation
        ,b.ari
        ,b.neuraminidase_inhibitor
      FROM index_exposure as a
        LEFT JOIN qualifying_hospitalizations as b ON a.patient_id = b.patient_id 
          and a.index_encounter_id<>b.encounter_id
          and b.start_date>a.index_date
          and b.start_date<=a.index_date+{follow_up_days}
    ;
  "))

  # Find follow-up hospitalizations of any cause (any inpatient encounter) for a secondary outcome
  dbExecute(con, glue("
    drop table if exists hospitalizations_any_cause;
    create temporary table hospitalizations_any_cause as 
      SELECT a.patient_id
        ,min(b.start_date-a.index_date) as time_to_hospitalization_any
      FROM index_exposure as a
        INNER JOIN {schema}.encounters as b ON a.patient_id = b.patient_id 
          and b.encounter_class = 'inpatient'
          and b.start_date>a.index_date
          and b.start_date<=a.index_date+{follow_up_days}
      GROUP BY 1
    ;
  "))

  # Find patients with continuous payer coverage from baseline_days before to follow_up_days after the index date.
  # Coverage periods overlapping this window are ordered, and a gap is a period starting after all earlier periods ended.
  dbExecute(con, glue("
    drop table if exists continuous_coverage;
    create temporary table continuous_coverage as 
      SELECT patient_id
      FROM(
        SELECT a.patient_id
          ,a.index_date-{baseline_days} as window_start
          ,a.index_date+{follow_up_days} as window_end
          ,cast(t.start_date as date) as period_start
          ,coalesce(cast(t.end_date as date), cast('2999-12-31' as date)) as period_end
          ,max(coalesce(cast(t.end_date as date), cast('2999-12-31' as date))) over (
             partition by a.patient_id order by t.start_date rows between unbounded preceding and 1 preceding
           ) as previous_end
        FROM index_exposure as a
          INNER JOIN {schema}.payer_transitions as t ON a.patient_id = t.patient_id
        WHERE cast(t.start_date as date) <= a.index_date+{follow_up_days}
          and coalesce(cast(t.end_date as date), cast('2999-12-31' as date)) >= a.index_date-{baseline_days}
      ) as a
      GROUP BY patient_id, window_start, window_end
      HAVING min(period_start) <= window_start
        and max(period_end) >= window_end
        and sum(case when previous_end is not null and period_start > previous_end+1 then 1 else 0 end) = 0
    ;
  "))

  # Apply eligibility criteria to each patient with an index exposure. Each criterion is kept as a 0/1 flag
  # so that the attrition can be counted below.
  dbExecute(con, glue("
    drop table if exists cohort_eligibility;
    create temporary table cohort_eligibility as 
      SELECT a.*
        ,p.sex
        ,p.race
        ,p.birth_date
        ,date_part('year', age(a.index_date, p.birth_date)) as age_at_index
        ,d.death_date
        ,case when date_part('year', age(a.index_date, p.birth_date)) >= {min_age} then 1 else 0 end as elig_age
        ,case when a.index_date-{baseline_days} >= x.data_start then 1 else 0 end as elig_baseline
        ,case when a.index_date+{follow_up_days} <= x.data_end then 1 else 0 end as elig_follow_up
        ,case when c.patient_id is not null then 1 else 0 end as elig_coverage
        ,case when exists (
                SELECT 1 FROM {schema}.encounters as e
                WHERE e.patient_id = a.patient_id
                  and e.start_date > a.index_date
                  and e.start_date <= a.index_date+{follow_up_days}
              ) then 1 else 0 end as elig_follow_up_encounter
      FROM index_exposure as a
        INNER JOIN {schema}.patients as p ON a.patient_id = p.patient_id
        LEFT JOIN {schema}.death as d ON a.patient_id = d.patient_id
        LEFT JOIN continuous_coverage as c ON a.patient_id = c.patient_id
        CROSS JOIN (
          SELECT min(start_date) as data_start, max(coalesce(end_date, start_date)) as data_end FROM {schema}.encounters
        ) as x
    ;
  "))

  # Attrition: number of patients remaining after each criterion is applied in sequence.
  dbGetQuery(con, glue("
    SELECT 1 as step, 'Patients with an index exposure' as criterion, count(*) as n_patients FROM cohort_eligibility
    UNION ALL
    SELECT 2, 'Age >= {min_age} at index', count(*) FROM cohort_eligibility 
      WHERE elig_age = 1
    UNION ALL
    SELECT 3, '>= {baseline_days} days of baseline', count(*) FROM cohort_eligibility 
      WHERE elig_age = 1 and elig_baseline = 1
    UNION ALL
    SELECT 4, '>= {follow_up_days} days of follow-up', count(*) FROM cohort_eligibility 
      WHERE elig_age = 1 and elig_baseline = 1 and elig_follow_up = 1
    UNION ALL
    SELECT 5, 'Continuous coverage during baseline and follow-up', count(*) FROM cohort_eligibility 
      WHERE elig_age = 1 and elig_baseline = 1 and elig_follow_up = 1 and elig_coverage = 1
    UNION ALL
    SELECT 6, '>= 1 follow-up encounter', count(*) FROM cohort_eligibility 
      WHERE elig_age = 1 and elig_baseline = 1 and elig_follow_up = 1 and elig_coverage = 1 and elig_follow_up_encounter = 1
    ORDER BY step;
  "))

  # Create the outcome dataset: one row per eligible patient with the outcomes and follow-up time.
  # Follow-up starts at the index date and ends at the first qualifying hospitalization, death, or after follow_up_days.
  dbExecute(con, glue("
    drop table if exists cohort_outcomes;
    create temporary table cohort_outcomes as 
      SELECT a.patient_id
        ,a.exposure
        ,a.exposure_details
        ,a.copd
        ,a.asthma
        ,a.bronchiectasis
        ,a.sex
        ,a.race
        ,a.age_at_index
        ,a.index_date
        ,case when h.days_to_hospitalization is not null then 1 else 0 end as hospitalization
        ,h.days_to_hospitalization
        ,case when h.exacerbation = 1 then 'Exacerbation'
              when h.ari = 1 then 'ARI'
              when h.neuraminidase_inhibitor = 1 then 'Neuraminidase inhibitor'
              else NULL
        end as hospitalization_type
        ,h.length_of_stay as hospitalization_length_of_stay
        ,case when ha.time_to_hospitalization_any is not null then 1 else 0 end as hospitalization_any_cause
        ,ha.time_to_hospitalization_any as days_to_hospitalization_any_cause
        ,a.death_date
        ,least({follow_up_days}, coalesce(h.days_to_hospitalization, {follow_up_days}), coalesce(a.death_date-a.index_date, {follow_up_days})) as follow_up_time
        ,case when h.days_to_hospitalization is not null 
                and (a.death_date is null or h.days_to_hospitalization <= a.death_date-a.index_date) then 'Hospitalization'
              when a.death_date is not null and a.death_date-a.index_date <= {follow_up_days} then 'Death'
              else 'End of follow-up'
        end as follow_up_end_reason
      FROM cohort_eligibility as a
        LEFT JOIN (
          SELECT distinct on (patient_id) patient_id
            ,time_to_hospitalization as days_to_hospitalization
            ,length_of_stay
            ,exacerbation
            ,ari
            ,neuraminidase_inhibitor
          FROM hospitalizations_all
          WHERE hospitalization_encounter_id is not null
          ORDER BY patient_id, time_to_hospitalization
        ) as h ON a.patient_id = h.patient_id
        LEFT JOIN hospitalizations_any_cause as ha ON a.patient_id = ha.patient_id
      WHERE a.elig_age = 1 and a.elig_baseline = 1 and a.elig_follow_up = 1 and a.elig_coverage = 1 and a.elig_follow_up_encounter = 1
    ;
  "))

  # Baseline comorbidities: any diagnosis recorded before the index date (the data starts in 2018, and chronic
  # conditions active at the start of the data are recorded at that date). The flags are used as covariates.
  dbExecute(con, glue("
    drop table if exists cohort_comorbidities;
    create temporary table cohort_comorbidities as 
      SELECT a.patient_id
        ,max(case when left(c.icd10cm_code,3) in ('E10','E11','E12','E13','E14') then 1 else 0 end) as diabetes
        ,max(case when left(c.icd10cm_code,3) in ('G45','I60','I61','I62','I63','I64') then 1 else 0 end) as stroke
        ,max(case when left(c.icd10cm_code,3) in ('I43','I50') or left(c.icd10cm_code,5) in ('I11.0','I13.0','I25.5','I42.0','I42.5','I42.6','I42.7','I42.8','I42.9','P29.0') then 1 else 0 end) as heart_failure
        ,max(case when left(c.icd10cm_code,3) in ('I21','I22') or c.icd10cm_code = 'I25.2' then 1 else 0 end) as myocardial_infarction
        ,max(case when left(c.icd10cm_code,3) in ('I44','I45','I46','I47','I48','I49') then 1 else 0 end) as arrhythmia
        ,max(case when left(c.icd10cm_code,3) in ('M05','M06','M32','M33','M34') or left(c.icd10cm_code,5) in ('M31.5','M35.1','M35.3','M36.0') then 1 else 0 end) as rheumatoid_disease
        ,max(case when left(c.icd10cm_code,3) in ('M80','M81') then 1 else 0 end) as osteoporosis
        ,max(case when left(c.icd10cm_code,3) in ('F32','F33','F38','F39') or left(c.icd10cm_code,5) in ('F31.3','F31.4','F31.5','F31.6','F31.9','F34.1','F34.8','F34.9','F41.2','F43.2') then 1 else 0 end) as depression
        ,max(case when left(c.icd10cm_code,3) in ('F00','F01','F02','F03','F04','F05','G30','G94') or left(c.icd10cm_code,5) in ('F06.1','F06.8','G13.2','G13.8','G31.0','G31.1','G31.2','R41.8') then 1 else 0 end) as dementia
        ,max(case when left(c.icd10cm_code,3) = 'I10' then 1 else 0 end) as hypertension
        ,max(case when left(c.icd10cm_code,1) = 'C' then 1 else 0 end) as cancer
      FROM cohort_outcomes as a
        LEFT JOIN {schema}.conditions as c ON a.patient_id = c.patient_id and c.condition_date < a.index_date
      GROUP BY 1
    ;
  "))

  # Baseline medication use: drugs active at any time during the 30 days before the index date, by ATC class.
  dbExecute(con, glue("
    drop table if exists cohort_medications;
    create temporary table cohort_medications as 
      SELECT a.patient_id
        ,max(case when {atc_in('R03')} then 1 else 0 end) as obstructive_airway_drugs
        ,max(case when {atc_in('R03BA')} or {atc_in('R03AK')} then 1 else 0 end) as inhaled_corticosteroids
        ,max(case when {atc_in('R03AC12')} or {atc_in('R03AC13')} or {atc_in('R03AC18')} or {atc_in('R03BB')} or {atc_in('R03AK')} or {atc_in('R03AL')} then 1 else 0 end) as long_acting_bronchodilators
        ,max(case when {atc_in('R03DA')} then 1 else 0 end) as methylxanthines
        ,max(case when {atc_in('R03DC')} then 1 else 0 end) as leukotriene_modifiers
        ,max(case when {atc_in('H02AB')} then 1 else 0 end) as systemic_corticosteroids
        ,max(case when {atc_in('N05A')} then 1 else 0 end) as antipsychotics
        ,max(case when {atc_in('N05BA')} then 1 else 0 end) as anxiolytics
        ,max(case when {atc_in('N05CF')} then 1 else 0 end) as hypnotics
        ,max(case when {atc_in('N02A')} then 1 else 0 end) as opioids
        ,max(case when {atc_in('N06A')} then 1 else 0 end) as antidepressants
        ,max(case when {atc_in('N06D')} then 1 else 0 end) as anti_dementia_drugs
        ,max(case when {atc_in('C07')} then 1 else 0 end) as beta_blockers
        ,max(case when {atc_in('A02BC')} then 1 else 0 end) as proton_pump_inhibitors
      FROM cohort_outcomes as a
        LEFT JOIN {schema}.medications as m ON a.patient_id = m.patient_id
          and cast(m.start_datetime as date) <= a.index_date
          and (m.end_datetime is null or cast(m.end_datetime as date) >= a.index_date-30)
      GROUP BY 1
    ;
  "))

  # Hospitalizations during the baseline year: any inpatient stay, and prior acute respiratory infection and
  # exacerbation, defined as the outcome (qualifying hospitalizations before the index date)
  dbExecute(con, glue("
    drop table if exists cohort_prior_hospitalizations;
    create temporary table cohort_prior_hospitalizations as 
      SELECT a.patient_id
        ,max(case when e.encounter_id is not null then 1 else 0 end) as prior_hospitalization
        ,max(case when q.ari = 1 then 1 else 0 end) as prior_ari
        ,max(case when q.exacerbation = 1 then 1 else 0 end) as prior_exacerbation
      FROM cohort_outcomes as a
        LEFT JOIN {schema}.encounters as e ON a.patient_id = e.patient_id
          and e.encounter_class = 'inpatient'
          and e.start_date < a.index_date
          and e.start_date >= a.index_date-{baseline_days}
        LEFT JOIN qualifying_hospitalizations as q ON e.encounter_id = q.encounter_id
      GROUP BY 1
    ;
  "))

  # Create the final patient-level dataset: outcomes, follow-up, and baseline characteristics.
  dbExecute(con, glue("
    drop table if exists cohort_final;
    create temporary table cohort_final as 
      SELECT a.*
        ,case when a.age_at_index < 65 then '60-64'
              when a.age_at_index < 70 then '65-69'
              when a.age_at_index < 75 then '70-74'
              when a.age_at_index < 80 then '75-79'
              when a.age_at_index < 85 then '80-84'
              else '85+'
        end as age_group
        ,a.index_date + cast(a.follow_up_time as integer) as follow_up_end_date
        ,b.diabetes, b.stroke, b.heart_failure, b.myocardial_infarction, b.arrhythmia
        ,b.rheumatoid_disease, b.osteoporosis, b.depression, b.dementia, b.hypertension, b.cancer
        ,c.obstructive_airway_drugs, c.inhaled_corticosteroids, c.long_acting_bronchodilators, c.methylxanthines
        ,c.leukotriene_modifiers, c.systemic_corticosteroids, c.antipsychotics, c.anxiolytics, c.hypnotics, c.opioids
        ,c.antidepressants, c.anti_dementia_drugs, c.beta_blockers, c.proton_pump_inhibitors
        ,d.prior_hospitalization, d.prior_ari, d.prior_exacerbation
      FROM cohort_outcomes as a
        LEFT JOIN cohort_comorbidities as b ON a.patient_id = b.patient_id
        LEFT JOIN cohort_medications as c ON a.patient_id = c.patient_id
        LEFT JOIN cohort_prior_hospitalizations as d ON a.patient_id = d.patient_id
    ;
  "))

  # Crude summary of the outcome by exposure group (incidence per 100 person-years).
  dbGetQuery(con, "
    SELECT coalesce(exposure, 'All') as exposure
      ,count(*) as n_patients
      ,sum(hospitalization) as n_hospitalized
      ,round(100.0*sum(hospitalization)/count(*), 1) as pct_hospitalized
      ,round(sum(follow_up_time)/365.25, 1) as person_years
      ,round(100*sum(hospitalization)/(sum(follow_up_time)/365.25), 1) as rate_per_100py
    FROM cohort_final
    GROUP BY ROLLUP(exposure)
    ORDER BY 1;
  ")

  # Pull the final patient-level dataset into R for the analysis.
  cohort <- dbGetQuery(con, "SELECT * FROM cohort_final;")


# Table 1: baseline characteristics by index disease group and overall, in the style of the article.
  # n (%) for a 0/1 variable and mean (SD) for a numeric variable.
  n_pct <- function(x) sprintf("%d (%.1f%%)", sum(x == 1), 100 * mean(x == 1))
  mean_sd <- function(x) sprintf("%.1f (%.1f)", mean(x), sd(x))
  groups <- c(list(Total = cohort), split(cohort, factor(cohort$exposure, levels = c("COPD", "Asthma", "Bronchiectasis", "Multiple"))))
  groups <- groups[vapply(groups, nrow, integer(1)) > 0]
  table_row <- function(label, fun, variable, value = NULL) {
    cells <- vapply(groups, function(d) fun(if (is.null(value)) d[[variable]] else as.integer(d[[variable]] == value)), character(1))
    data.frame(Characteristic = label, t(cells), check.names = FALSE, row.names = NULL)
  }
  table1 <- do.call(rbind, c(
    list(data.frame(Characteristic = "Patients, N", t(vapply(groups, function(d) as.character(nrow(d)), character(1))), check.names = FALSE)),
    list(table_row("Age at index, mean (SD)", mean_sd, "age_at_index")),
    lapply(c("60-64", "65-69", "70-74", "75-79", "80-84", "85+"), function(g) table_row(paste0("  Age ", g), n_pct, "age_group", g)),
    list(table_row("Female sex", n_pct, "sex", "F")),
    list(table_row("Comorbidities (before index)", function(x) "", "diabetes")),
    lapply(c("hypertension", "diabetes", "stroke", "heart_failure", "myocardial_infarction", "arrhythmia", "rheumatoid_disease", "osteoporosis", "cancer", "depression", "dementia"),
           function(v) table_row(paste0("  ", gsub("_", " ", v)), n_pct, v)),
    list(table_row("Medication use (30 days before index)", function(x) "", "diabetes")),
    lapply(c("obstructive_airway_drugs", "inhaled_corticosteroids", "long_acting_bronchodilators", "methylxanthines", "leukotriene_modifiers",
             "systemic_corticosteroids", "antipsychotics", "anxiolytics", "hypnotics", "antidepressants",
             "anti_dementia_drugs", "opioids", "beta_blockers", "proton_pump_inhibitors"),
           function(v) table_row(paste0("  ", gsub("_", " ", v)), n_pct, v)),
    list(table_row("Prior acute respiratory infection (baseline year)", n_pct, "prior_ari")),
    list(table_row("Prior exacerbation (baseline year)", n_pct, "prior_exacerbation")),
    list(table_row("Hospitalization in the baseline year", n_pct, "prior_hospitalization")),
    list(table_row("Outcome: respiratory hospitalization", n_pct, "hospitalization")),
    list(table_row("Outcome: hospitalization of any cause", n_pct, "hospitalization_any_cause"))
  ))
  print(table1, row.names = FALSE)
