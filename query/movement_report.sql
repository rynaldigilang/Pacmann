-- BASE_RESELLER
-- Standardizes reseller dimension data into reporting-friendly structure.
-- Main purposes:
-- 1) Map reseller REGION_ID into business reporting regions (Americas / EMEA / APAC)
-- 2) Resolve distributor hierarchy (parent reseller vs direct-selling distributor)
-- 3) Normalize reseller channel naming
-- 4) Attach currency and activation metadata with valid time joins

WITH BASE_RESELLER AS (
SELECT
    -- Reporting region mapping:
    -- Applies manual overrides for specific reseller/distributor cases
    -- where ownership differs from default REGION_ID grouping.
    CASE
        WHEN RES.REGION_ID = 1 AND RES.RESELLER_ID = 4625 THEN 'EMEA'
        WHEN RES.REGION_ID = 6 AND RES.RESELLER_ID = 1103 THEN 'EMEA'
        WHEN RES.REGION_ID = 8 AND RES.RESELLER_ID = 274 THEN 'AMERICAS'
        WHEN RES.REGION_ID = 2 AND PARENT_RESELLER_ID = 10649 THEN 'EMEA'
        WHEN RES.REGION_ID = 2 AND PARENT_RESELLER_ID = 10318 THEN 'EMEA'
        WHEN RES.REGION_ID = 6 AND PARENT_RESELLER_ID = 1103 THEN 'EMEA'
        WHEN RES.REGION_ID IN (1,2,3,5,11,13,14) THEN 'AMERICAS'
        WHEN RES.REGION_ID IN (7,8,10,12) THEN 'EMEA'
        WHEN RES.REGION_ID IN (4,6,9) THEN 'APAC'
    END AS REGION,

    -- Original region/server code from source system.
    REGION_CODE AS SERVER,

    -- Distributor resolution:
    -- Priority: parent reseller → direct-selling distributor → none.
    -- Ensures every reseller is mapped to a top-level distributor when possible.
    CASE 
        WHEN PARENT_RESELLER_ID IS NULL AND DISTI_SELLING_DIRECT_ID IS NULL THEN 'No Distributor'  
        WHEN PARENT_RESELLER_ID IS NULL THEN CONCAT(RES.REGION_ID,'_',DISTI_SELLING_DIRECT_ID)
        ELSE CONCAT(RES.REGION_ID,'_',PARENT_RESELLER_ID)
    END AS DISTRIBUTOR_ID,

    CASE 
        WHEN PARENT_RESELLER_NAME IS NULL AND DISTI_SELLING_DIRECT_NAME IS NULL THEN 'No Distributor'  
        WHEN PARENT_RESELLER_NAME IS NULL THEN DISTI_SELLING_DIRECT_NAME
        ELSE PARENT_RESELLER_NAME
    END AS DISTRIBUTOR_NAME,

    -- Unique reseller identifier (region-scoped).
    CONCAT(RES.REGION_ID,'_',RES.RESELLER_ID) AS RESELLER_ID,

    RESELLER_NAME,

    -- Channel normalization:
    -- Standardizes key strategic channels for consistent reporting.
    CASE
        WHEN RES.CHANNEL IN ('ninjaone','ninja_one') THEN 'NinjaOne'
        WHEN RES.CHANNEL IN ('elite_msp','msp') THEN 'MSP'
        WHEN RES.CHANNEL IN ('hycu','uol') THEN UPPER(RES.CHANNEL)
        ELSE INITCAP(RES.CHANNEL)
    END AS CHANNEL,

    -- Activation flags from reseller and parent hierarchy.
    ACTIVATED AS RESELLER_ACTIVATED,
    PARENT_RESELLER_ACTIVATED,

    -- Effective date of reseller record (SCD reference point).
    RES.DBT_VALID_FROM::DATE,

    -- Currency derived from reseller settings (time-valid join).
    RS.CURRENCY

FROM ANALYTICS.DIM_RESELLERS RES

-- Region lookup for additional metadata.
JOIN DM.DIM_REGION REG USING(REGION_ID)

-- Time-aware join to reseller settings (SCD logic):
-- Ensures correct currency is selected based on reseller validity period.
LEFT JOIN ANALYTICS.SCD_RESELLER_SETTINGS AS RS
        ON RS.RESELLER_ID = RES.RESELLER_ID
       AND RS.REGION_ID = RES.REGION_ID
       AND RES.DBT_VALID_FROM::DATE >= RS.DBT_VALID_FROM::DATE
       AND (RS.DBT_VALID_TO::DATE IS NULL OR RES.DBT_VALID_FROM::DATE < RS.DBT_VALID_TO::DATE)

-- Exclude test resellers from reporting layer.
WHERE IS_TEST_RESELLER = FALSE
),

-- MOVEMENT
-- Detects reseller-level attribute changes over time.
-- Main purposes:
-- 1) Compare each reseller record against its previous historical version
-- 2) Capture prior reseller, distributor, channel, activation, and currency values
-- 3) Flag meaningful reseller/distributor movement events
-- 4) Return only records where a movement or currency change occurred

MOVEMENT AS (
SELECT
    *,

    -- Previous reseller attributes:
    -- Used to compare the current SCD row against the prior version
    -- for the same region-scoped reseller.
    LAG(RESELLER_NAME) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM) AS PREV_RESELLER_NAME,
    LAG(DISTRIBUTOR_ID) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM) AS PREV_DISTRIBUTOR_ID,
    LAG(DISTRIBUTOR_NAME) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM) AS PREV_DISTRIBUTOR_NAME,
    LAG(CHANNEL) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM) AS PREV_CHANNEL,
    LAG(ACTIVATED) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM) AS PREV_ACTIVATED,
    LAG(PARENT_RESELLER_ACTIVATED) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM) AS PREV_PARENT_ACTIVATED,
    LAG(CURRENCY) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM) AS PREV_CURRENCY,

    -- Movement classification:
    -- Flags the first detected business-relevant attribute change
    -- compared with the prior reseller version.
    -- Priority order matters: distributor movement is classified before
    -- name, channel, or activation changes.
    CASE
        WHEN DISTRIBUTOR_ID <> LAG(DISTRIBUTOR_ID) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM)
             AND DISTRIBUTOR_ID = 'No Distributor'
            THEN 'become direct'

        WHEN DISTRIBUTOR_ID <> LAG(DISTRIBUTOR_ID) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM)
            THEN 'disti change'

        WHEN RESELLER_NAME <> LAG(RESELLER_NAME) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM)
            THEN 'reseller name change'

        WHEN DISTRIBUTOR_NAME <> LAG(DISTRIBUTOR_NAME) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM)
            THEN 'disti name change'

        WHEN CHANNEL <> LAG(CHANNEL) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM)
            THEN 'channel change'

        WHEN ACTIVATED <> LAG(ACTIVATED) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM)
            THEN 'reseller active change'

        WHEN PARENT_RESELLER_ACTIVATED <> LAG(PARENT_RESELLER_ACTIVATED) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM)
            THEN 'disti active change'
    END AS MOVEMENT_REMARKS,

    -- Currency movement:
    -- Tracked separately from business movement so currency-only changes
    -- are still included in the final output.
    CASE 
        WHEN CURRENCY <> LAG(CURRENCY) OVER (PARTITION BY RESELLER_ID ORDER BY DBT_VALID_FROM)
            THEN 'currency change'  
    END AS CURRENCY_CHANGE

FROM BASE_RESELLER
)

-- Final movement output:
-- Keeps only reseller history rows where at least one tracked change occurred.
SELECT
    *
FROM MOVEMENT
WHERE MOVEMENT_REMARKS IS NOT NULL
   OR CURRENCY_CHANGE IS NOT NULL