# Environment setup
  # Library imports
  library(DBI)
  library(odbc)
  library(glue)

  # Set up the environment variables for the connection.
  schema <- "rwe"
  dsn <- "RWE_AIVEN_POSTGRES"

  # Define the connection to the database in Aiven.
  con <- dbConnect(odbc(), dsn = dsn)

  # Study design parameters.
  min_age <- 60            # minimum age at index
  baseline_days <- 365     # required coverage before the index date
  follow_up_days <- 365    # length of follow-up after the index date
  min_stay_days <- 2       # minimum length of a qualifying hospital stay


# ETL
  # Prepare the exposure codelist table based on ICD-10-CM codes for COPD, asthma, and bronchiectasis.
  dbExecute(con, glue("
    drop table if exists exposure_codelist;
    create temporary table exposure_codelist as 
      SELECT *
      FROM(
        SELECT * 
          ,case when icd10cm_code LIKE any(array['J41%','J42%','J43%','J44%']) then 1 else 0 end as copd
          ,case when icd10cm_code LIKE any(array['J45%','J46%'])  then 1 else 0 end as asthma
          ,case when icd10cm_code LIKE any(array['J47%'])  then 1 else 0 end as bronchiectasis
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
        ,substring(repeat('+COPD', max(a.copd))||repeat('+Asthma', max(a.asthma))||repeat('+Bronchiectasis', max(a.bronchiectasis)) from 2) as exposure_details
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
          ,case when icd10cm_code LIKE any(array['J41%','J42%','J43%','J44%','J45%','J46%','J47%']) then 1 else 0 end as exacerbation
          ,case when icd10cm_code LIKE any(array['J09%','J10%','J11%','J12%','J13%','J14%','J15%','J16%','J17%','J18%',
                                                  'J02.8%','J03.8%','J20.0%','J20.1%','J20.4%','J20.5%','J20.6%','J20.8%','J21.1%','J21.8%']) then 1 else 0 end as ari
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
          SELECT distinct encounter_id
          FROM {schema}.medications
          WHERE 'J05AH' = any(array[left(atc_code1,5),left(atc_code2,5),left(atc_code3,5),left(atc_code4,5),
                                    left(atc_code5,5),left(atc_code6,5),left(atc_code7,5)])
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

  # Apply eligibility criteria to each patient with an index exposure. Each criterion is kept as a 0/1 flag
  # so that the attrition can be counted below.
  dbExecute(con, glue("
    drop table if exists cohort_eligibility;
    create temporary table cohort_eligibility as 
      SELECT a.*
        ,p.sex
        ,p.race
        ,p.birth_date
        ,extract(year from age(a.index_date, p.birth_date)) as age_at_index
        ,d.death_date
        ,case when a.index_date-{baseline_days} >= x.data_start and a.index_date+{follow_up_days} <= x.data_end then 1 else 0 end as elig_data
        ,case when extract(year from age(a.index_date, p.birth_date)) >= {min_age} then 1 else 0 end as elig_age
        ,case when d.death_date is null or d.death_date > a.index_date then 1 else 0 end as elig_alive
        ,case when exists (
                SELECT 1 FROM {schema}.payer_transitions as t
                WHERE t.patient_id = a.patient_id
                  and t.start_date::date <= a.index_date - {baseline_days}
                  and t.end_date::date >= a.index_date - {baseline_days}
              ) and exists (
                SELECT 1 FROM {schema}.payer_transitions as t
                WHERE t.patient_id = a.patient_id
                  and t.start_date::date <= a.index_date
                  and t.end_date::date >= a.index_date
              ) then 1 else 0 end as elig_lookback
      FROM index_exposure as a
        INNER JOIN {schema}.patients as p ON a.patient_id = p.patient_id
        LEFT JOIN {schema}.death as d ON a.patient_id = d.patient_id
        CROSS JOIN (
          SELECT min(start_date) as data_start, max(coalesce(end_date, start_date)) as data_end FROM {schema}.encounters
        ) as x
    ;
  "))

  # Attrition: number of patients remaining after each criterion is applied in sequence.
  dbGetQuery(con, glue("
    SELECT 1 as step, 'Patients with an index exposure' as criterion, count(*) as n_patients FROM cohort_eligibility
    UNION ALL
    SELECT 2, '{baseline_days} days of data before and {follow_up_days} days after index', count(*) FROM cohort_eligibility WHERE elig_data = 1
    UNION ALL
    SELECT 3, 'Age >= {min_age} at index', count(*) FROM cohort_eligibility WHERE elig_data = 1 and elig_age = 1
    UNION ALL
    SELECT 4, 'Alive at index', count(*) FROM cohort_eligibility WHERE elig_data = 1 and elig_age = 1 and elig_alive = 1
    UNION ALL
    SELECT 5, 'Continuous coverage {baseline_days} days before index', count(*) FROM cohort_eligibility WHERE elig_data = 1 and elig_age = 1 and elig_alive = 1 and elig_lookback = 1
    ORDER BY step;
  "))

  # Create the final patient-level dataset: one row per eligible patient with the outcome and follow-up time.
  # Follow-up starts at the index date and ends at the first qualifying hospitalization, death, or after follow_up_days.
  dbExecute(con, glue("
    drop table if exists cohort_final;
    create temporary table cohort_final as 
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
        ,a.death_date
        ,least(a.index_date + {follow_up_days}, a.index_date + h.days_to_hospitalization, a.death_date) as follow_up_end_date
        ,least(a.index_date + {follow_up_days}, a.index_date + h.days_to_hospitalization, a.death_date) - a.index_date as follow_up_time
        ,case when h.days_to_hospitalization is not null 
                and (a.death_date is null or a.index_date + h.days_to_hospitalization <= a.death_date) then 'Hospitalization'
              when a.death_date is not null and a.death_date <= a.index_date + {follow_up_days} then 'Death'
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
      WHERE a.elig_data = 1 and a.elig_age = 1 and a.elig_alive = 1 and a.elig_lookback = 1
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


