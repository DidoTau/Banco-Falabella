

/*
**************************************************************************
***************************  PRINCIPALIDAD  ******************************
**************************************************************************

Se declara el periodo de cierre de forma tal que cuando se corra el proceso se considere:
- La fechaCarga del último día del mes anterior en caso de ser una tabla que se carga diariamente
- La fechaPeriodo en caso de ser una tabla que se carga mensualmente 

Por lo que hay que considerar cuando se actualiza cada tabla en cada consulta (recurrencia).

*/
DECLARE DIA INT64;
DECLARE FECHA_EJECUCION DATE;
DECLARE FECHA_PERIODO DATE;

-- Extrae el dia de ejecución
SET DIA = (SELECT EXTRACT(DAY FROM DATE '{{ds}}'));

/* FUNCIONES */
IF(DIA = 4) THEN
    --- Fecha en que se carga el proceso se reemplaza por {{ds}}
    SET FECHA_EJECUCION = DATE('{{ds}}');
    --- Fecha periodo es el mes anterior al mes de ejecución
    SET FECHA_PERIODO = DATE_TRUNC(DATE_SUB(FECHA_EJECUCION, INTERVAL 1 MONTH), MONTH);

    --- TENENCIA INTEGRADA

    CREATE TEMP TABLE TEMP_TENENCIA_INT AS 
    /*
    RECURRENCIA: DIARIA (DESDE SEPT 2021)

    */
        SELECT 
        A.*, 
        IF(FullProteccionContratado + Cesantia+ Desgravamen >=1, 1, 0) AS SegurosIntegral,
        IF(PacEfectivo  >=1, 1, 0) AS PAC
        FROM 
            {{ project_bi }}.{{ ds_trf_bfa_cl_bi }}.trf_cbi_tenencia_integrada as A
        WHERE 
        FechaCarga >=FECHA_EJECUCION-60 
        and
        FechaCarga = (SELECT MAX(fechaCarga) 
                FROM {{ project_bi }}.{{ ds_trf_bfa_cl_bi }}.trf_cbi_tenencia_integrada
                WHERE fechacarga between FECHA_PERIODO  and 
                LAST_DAY(FECHA_PERIODO))  --- ULTIMO DÍA CON DATOS DEL MES ANTERIOR
    ;



    --- DEUDA R04
    CREATE TEMP TABLE TEMP_R04 AS 
    /*
    RECURRENCIA: MENSUAL
    */
    SELECT 
    FECHA_PERIODO AS Periodo,
    id_cliente AS IdCliente,
    (IF(IFNULL(SUM(dconsumo),0)< 10, 0,IFNULL(SUM(dconsumo),0)))*1000 AS DeudaR04
    FROM {{ project_fif_corp }}.{{ ds_shr_bfa_cl_datalake_fif_corp }}.svw_trf_btd_vw_ptt_r04
    where 
        fecha_foto = DATE_SUB(FECHA_PERIODO, INTERVAL 1 MONTH) -- DESFASE DE 1 MES
    GROUP BY  id_cliente
    ;



    -- REPORTE D10 (DEUDA D10)
    CREATE TEMP TABLE TEMP_REPORTE_D10 AS 

    SELECT 
    --- RECURRENCIA: MENSUAL 
        IdCliente, 
        IF(IFNULL(SUM(IF(Empresa = 'BANCO' , Monto, 0)),0)< 10, 0,IFNULL(SUM(IF(Empresa = 'BANCO' , Monto, 0)),0)) AS DeudaBfD10,
        IF(IFNULL(SUM(IF(Empresa = 'CMR' , Monto, 0)),0)< 10, 0,IFNULL(SUM(IF(Empresa = 'CMR' , Monto, 0)),0)) AS DeudaCMRD10

    --- RECURRENCIA: MENSUAL 
    FROM 
        {{ project_dl }}.{{ ds_shr_bfa_cl_datalake }}.vw_trf_reporte_d10
    WHERE 
    TipoDeDeudor = 1
    AND 
    TipoDeCredito = 2 
    AND
    FECHAPERIODO = DATE_SUB(FECHA_PERIODO, INTERVAL 1 MONTH) --- DESFASE DE 2 MESES
    GROUP BY IdCliente 
    ;

  
    -- USO CTA CTE Y CTA VISTA 
    CREATE TEMP TABLE TEMP_USO_CTA AS 

    WITH CLTE_TRX AS (
    SELECT
    -- RECURRENCIA: DIARIA 
        DISTINCT
            DATE_TRUNC(FechaOperacion, MONTH) FechaPeriodo,
            B.IdBanco IdCliente,
            SUM(A.Monto) AS Monto,
            COUNT(1) AS TrxCta
            FROM {{ project_dl }}.{{ ds_shr_bfa_cl_datalake }}.vw_trf_evento_finan_transaccion A INNER JOIN

            {{ project_dl }}.{{ ds_shr_bfa_cl_datalake }}.vw_trf_contrato_pasivo_cuenta B
        ON
            CAST(A.NumeroCuenta AS NUMERIC) = CAST(B.Contrato AS NUMERIC)
        WHERE
        DATE_TRUNC(FechaOperacion, MONTH) BETWEEN DATE_SUB(FECHA_PERIODO, INTERVAL 2 MONTH) AND FECHA_PERIODO -- ÚLTIMOS 3 MESES
            AND B.FechaCarga >=FECHA_PERIODO-60 
        AND B.FechaCarga =(SELECT MAX(fechaCarga) 
                FROM {{ project_dl }}.{{ ds_shr_bfa_cl_datalake }}.vw_trf_contrato_pasivo_cuenta
                WHERE fechacarga BETWEEN DATE_SUB(FECHA_PERIODO, INTERVAL 2 MONTH) AND FECHA_PERIODO)
            AND A.Esreversa = 'N'       
            AND (SAFE_CAST(A.IdTransaccion AS NUMERIC) IN (9,46,49,67,68,69,70,74,77,78,86,87,92,127,128,129,131,142,147,153,154,156,164,165,168,169,170,171,172,173,174,175,178,
                                                        181,183,184,186,187,192,194,195,196,197,198,201,205,215,216,223,224,231,233,235,236,241,245,250,264,269,289,313,347,348,349,
                                                        357,358,375,378,383,384,406,849,858,868,869,872,873,877,878,891,895,916,917,918,925,930,937,943,953,954,960,969,971)
            OR (SAFE_CAST(A.IdTransaccion AS NUMERIC) = 139  AND  NOT (
                                                                                UPPER(A.GLOSA) LIKE '%EMUNERAC%'
                                                                                OR UPPER(A.GLOSA) LIKE '%ENSION%'
                                                                                OR UPPER(A.GLOSA) LIKE '%SUELDO%'
                                                                                OR UPPER(A.GLOSA) LIKE '%HONORARIO%'
                                                                                OR UPPER(A.GLOSA) LIKE '%LICENCIA%'
                                                                                OR UPPER(A.GLOSA) LIKE '%ANTICIPO%'
                                                                                OR UPPER(A.GLOSA) LIKE '%REVISIO%'
                                                                            )     )   )                         
        GROUP BY
            FechaPeriodo,
            IdCliente
    )

    SELECT 
    IdCliente, 
    IF(AVG(TrxCta)>20, 20, FLOOR(AVG(TrxCta))) AS TrxCta
    FROM CLTE_TRX
    group by IdCliente
    order by IdCliente,TrxCta desc
    ;


    --- MEDIOS DE PAGO 

    -- DEBITO
    CREATE TEMP TABLE TEMP_MEDIOS_DE_PAGO AS 
    WITH 
    DEBITO AS (
    SELECT
        DATE_TRUNC(RespFechaInicio, MONTH) AS PeriodoOperacion, 
        A.IdCliente AS IdCliente,
        CASE WHEN SAFE_CAST(A.IdRubro AS NUMERIC) IN( SELECT 
                                DISTINCT IdRubro
                                FROM {{ project_bi }}.{{ ds_trf_bfa_cl_bi }}.trf_comercio_gestion
                                WHERE
                                UPPER(Descripcion) LIKE "EASY")
                THEN 'MEJORAMIENTO HOGAR' 
            ELSE C.RubroGestion END AS RubroGestion,
        SUM(CASE WHEN UltimoPaso = 'RV' THEN -1*ValorOriginal ELSE ValorOriginal END ) AS Monto,
        SUM(CASE WHEN UltimoPaso = 'RV' THEN -1 ELSE 1 END) AS NTrx 
    FROM   {{ project_dl }}.{{ ds_shr_bfa_cl_datalake }}.vw_trf_evento_finan_debito A
    LEFT JOIN {{ project_bi }}.{{ ds_trf_bfa_cl_bi }}.trf_rubro_gestion C
        ON TRIM(A.IdRubro)=CAST(C.IdRubroUnico AS STRING)
    WHERE  a.RespFechaInicio  BETWEEN DATE_TRUNC(DATE_SUB(FECHA_PERIODO,INTERVAL 2 MONTH),MONTH) AND LAST_DAY(FECHA_PERIODO,MONTH)
            AND  ultimopaso IN ('OK', 'RV')
    GROUP BY
        PeriodoOperacion,   
        IdCliente,
        RubroGestion
    ),
    -- CMR 
    CMR AS (
  SELECT
    DATE_TRUNC(FechaOperacion, MONTH) PeriodoOperacion,   
    A.IdClienteTitular AS IdCliente,
          CASE WHEN SAFE_CAST(A.IdRubro AS NUMERIC) IN( SELECT 
                              DISTINCT IdRubro
                              FROM {{ project_bi }}.{{ ds_trf_bfa_cl_bi }}.trf_comercio_gestion
                              WHERE
                              UPPER(Descripcion) LIKE "EASY")
            THEN 'MEJORAMIENTO HOGAR' 
           ELSE C.RubroGestion END AS RubroGestion,
    SUM(CASE WHEN SignoSat = '-' THEN -1*MontoLiquido ELSE MontoLiquido END ) AS Monto,
    SUM(CASE WHEN SignoSat = '-' THEN -1 ELSE 1 END ) AS NTrx
  FROM   {{ project_dl }}.{{ ds_shr_bfa_cl_datalake }}.vw_trf_evento_finan_transacc_cmr A
  LEFT JOIN {{ project_bi }}.{{ ds_trf_bfa_cl_bi }}.trf_rubro_gestion C
      ON A.IdRubro=C.IdRubroUnico 
  WHERE  a.FechaOperacion  BETWEEN DATE_TRUNC(DATE_SUB(FECHA_PERIODO,INTERVAL 2 MONTH),MONTH) AND LAST_DAY(FECHA_PERIODO,MONTH)
  AND SAFE_CAST(Codcomred AS NUMERIC) NOT IN (
          10005002,10000004,10008906,10001561,10009907,10001722,10001721,10001554,10002000,10002001,10001553,10001728,
          10001741,31715083,31720117,31720001,31720052,31715113,31719976,31715164,10001781,30916778,30108701,30587901,
          29524424,29290776,29403988,29640947,29518122,29743479,29431566,29370869,30301277,30242750,29654514,29678936,
          29730040,29621772,29391580,30192729,29602115,29594937,29868298,29690332,31720028,31720060,31720095,31720036,
          31715032,31719984,31720125,31715180,31715210,31715369,31720133,31995906,29654492,29444382) -- filtro proceso
  AND TRIM(DesTipfac) IN ('COMPRAS','ANULACION DE COMPRAS','DEVOLUCION DE DINERO','ANULACION DEVOLUCION','CAMBIO')
  GROUP BY
    PeriodoOperacion,   
    IdCliente,
    RubroGestion
    ),
    -- QUICKPAY
    QP AS (
    SELECT
    DATE_TRUNC(FechaOperacion, MONTH) PeriodoOperacion,
    ReqDiiddocumento as IdCliente,
    CASE WHEN ReqCommerceDescripcion='Falabella' THEN 'TIENDAS POR DEPARTAMENTO'
        WHEN ReqCommerceDescripcion='Sodimac' THEN 'MEJORAMIENTO HOGAR'
        WHEN ReqCommerceDescripcion='Tottus' THEN 'SUPERMERCADOS'
        WHEN ReqCommerceDescripcion='Viajes' THEN 'VIAJES'
        WHEN ReqCommerceDescripcion='Seguros' THEN 'SEGUROS'
        ELSE 'OTROS'
        END AS RubroGestion,
    SUM(
        CASE WHEN IdMensaje = '0210' THEN ReqMontototal
                WHEN IdMensaje = '0430' THEN -1*ReqMontototal
                WHEN IdMensaje = '5210' THEN -1*CAST(ReqMontoanulacion AS NUMERIC)
                END
    ) AS Monto, 
    SUM(
            CASE WHEN IdMensaje = '0210' THEN 1
                WHEN IdMensaje = '0430' THEN -1
                WHEN IdMensaje = '5210' THEN -1
                END 
    ) AS NTrx
    FROM
        {{ project_dl }}.{{ ds_shr_bfa_cl_datalake }}.vw_trf_evento_finan_transacc_quickpay
    WHERE FechaOperacion  BETWEEN DATE_TRUNC(DATE_SUB(FECHA_PERIODO,INTERVAL 2 MONTH),MONTH) AND LAST_DAY(FECHA_PERIODO,MONTH)
    AND ResCodigorespuesta = '000'
    AND (IdMensaje = '0210' or IdMensaje='5210' or IdMensaje='0430')
    AND  ReqCommerce in ('003', '002','001', '004', '005','006','007')
    GROUP BY
    PeriodoOperacion,   
    IdCliente,
    RubroGestion
    ),
    MEDIO_PAGO_UNION AS ( 
    SELECT 
        *
    FROM DEBITO
    UNION ALL 
    SELECT 
        *
    FROM CMR 
    UNION ALL 
    SELECT 
        *
    FROM QP 
    )
    SELECT 
    IdCliente,
    AVG(Rubros) AS RubroProm3M,
    AVG(Monto) AS MontoProm3M,
    IF(AVG(NTrx) > 12, 12, AVG(NTrx)) AS NTrx3M
    FROM ( SELECT 
            IdCliente, 
            PeriodoOperacion,
            COUNT(DISTINCT RubroGestion) AS Rubros,
            SUM(Monto) AS Monto,
            SUM(NTrx) as NTrx
            FROM MEDIO_PAGO_UNION
                GROUP BY IdCliente, 
                PeriodoOperacion)
    GROUP BY IdCliente
    ; 


    -- RENTA


    CREATE TEMP TABLE TEMP_RENTA AS 
    /*
    RECURRENCIA: MENSUAL
    */
    SELECT
        Id_Cliente as IdCliente, 
        CASE 
        WHEN RENTA_FINAL<=150000 THEN 150000 
        WHEN RENTA_FINAL>=15000000 THEN 15000000
        ELSE RENTA_FINAL END as Renta
    FROM
        bfa-cl-risk-dev.shr_bfa_cl_risk_dev_bfa_cl_bi_prd.vw_trf_logica_renta
    WHERE
        fecha_foto = FECHA_PERIODO
    ;


    DELETE FROM {{ project_bi }}.{{ ds_trf_bfa_cl_bi }}.trf_principalidad_integrada
    WHERE FechaPeriodo = FECHA_PERIODO
    ;


    /* SELECT FINAL*/
    
    INSERT INTO {{ project_bi }}.{{ ds_trf_bfa_cl_bi }}.trf_principalidad_integrada

    WITH TEMP_PRINC_1 AS (
        SELECT
        DISTINCT
        
            FECHA_PERIODO , 
            A.IdCliente,
            IFNULL(A.TieneCmrPpal,0) AS TieneCmrPpal,
            IFNULL(A.BIP,0) AS BIP, 
            IFNULL(A.PAT,0) AS PAT, 
            IFNULL(A.AdicionalCmr,0) AS AdicionalCmr, 
            IFNULL(A.CtaVta,0) CtaVta, 
            IFNULL(A.Hipotecario,0) Hipotecario,
            IFNULL(A.DAP,0) DAP,
            IFNULL(A.Ahorro,0) Ahorro, 
            IFNULL(A.FFMM,0) FFMM, 
            IFNULL(A.CtaCte,0) CtaCte, 
            IFNULL(A.ABR,0) ABR,
            A.PAC, 
            A.SegurosIntegral, 
            IFNULL(R04.DeudaR04,0) AS DeudaR04,
            IFNULL(REPORTE_D10.DeudaBfD10,0) AS DeudaBfD10,
            IFNULL(REPORTE_D10.DeudaCMRD10,0) AS DeudaCMRD10,
            IF(IFNULL(R04.DeudaR04,0)  <> 0 , 
                CASE 
                WHEN (IFNULL(REPORTE_D10.DeudaBfD10,0) + IFNULL(REPORTE_D10.DeudaCMRD10,0))/DeudaR04<=1 AND (IFNULL(REPORTE_D10.DeudaBfD10,0) + IFNULL(REPORTE_D10.DeudaCMRD10,0))/DeudaR04 >0
                        THEN (IFNULL(REPORTE_D10.DeudaBfD10,0) + IFNULL(REPORTE_D10.DeudaCMRD10,0))/DeudaR04 
                WHEN (IFNULL(REPORTE_D10.DeudaBfD10,0) + IFNULL(REPORTE_D10.DeudaCMRD10,0))/DeudaR04 > 1 
                        THEN 1
                ELSE 0 END,
            0) AS ShareOfDeuda, 
            IFNULL(USO_CTA.TrxCta,0) AS TrxCta,
            IFNULL(NTrx3M, 0) AS NTrx3M,
            IFNULL(MontoProm3M, 0)  AS MontoProm3M, 
            IFNULL(MEDIOS_DE_PAGO.RubroProm3M, 0)  AS RubroProm3M,
            IFNULL(RENTA.Renta,0) AS Renta, 
            IF(IFNULL(RENTA.Renta,0)= 0, 0, 
                IF(IFNULL(MontoProm3M, 0)/IFNULL(RENTA.Renta,0)<=1, IFNULL(MontoProm3M, 0)/IFNULL(RENTA.Renta,0), 1 )
            ) AS SOW,
            IFNULL((TrxCta - (SELECT MIN(TrxCta) FROM TEMP_USO_CTA))/((SELECT MAX(TrxCta) FROM TEMP_USO_CTA)-(SELECT MIN(TrxCta) FROM TEMP_USO_CTA)),0) AS TrxCtaNorm ,
            IFNULL((NTrx3M - (SELECT MIN(NTrx3M) FROM TEMP_MEDIOS_DE_PAGO))/((SELECT MAX(NTrx3M) FROM TEMP_MEDIOS_DE_PAGO)-(SELECT MIN(NTrx3M) FROM TEMP_MEDIOS_DE_PAGO)),0) AS NTrx3MNorm ,
            IFNULL((RubroProm3M - (SELECT MIN(RubroProm3M) FROM TEMP_MEDIOS_DE_PAGO))/((SELECT MAX(RubroProm3M) FROM TEMP_MEDIOS_DE_PAGO)-(SELECT MIN(RubroProm3M) FROM TEMP_MEDIOS_DE_PAGO)),0) AS RubroProm3MNorm 
        
        FROM
            TEMP_TENENCIA_INT AS A
        LEFT JOIN 
            TEMP_R04 AS R04
        ON 
            R04.idCliente = A.IdCliente
        LEFT JOIN 
            TEMP_REPORTE_D10 AS REPORTE_D10  
        ON
            A.IdCliente = REPORTE_D10.IdCliente
        LEFT JOIN
            TEMP_USO_CTA AS USO_CTA
        ON 
            A.IdCliente = USO_CTA.IdCliente
        LEFT JOIN 
            TEMP_MEDIOS_DE_PAGO AS MEDIOS_DE_PAGO
        ON 
            A.IdCliente = MEDIOS_DE_PAGO.IdCliente
        LEFT JOIN 
            TEMP_RENTA AS RENTA
        ON 
            A.IdCliente = RENTA.IdCliente
        
    ),

    TEMP_PRINC_2 AS (
        SELECT
        P.*,  
        (CtaCte + CtaVta + TieneCmrPpal + ABR) * 130 +
        (DAP+FFMM+AdicionalCmr+SegurosIntegral+PAC+PAT+Hipotecario) * 60 +
        (BIP+Ahorro) * 30 AS PTJETenencia ,
        ShareOfDeuda * 1000 AS PTJEShareDeuda,
        TrxCtaNorm * 1000 AS PTJEUsoCta ,
        NTrx3MNorm* 200 + RubroProm3MNorm*400 AS PTJEMediosDePago ,
        (CtaCte + CtaVta + TieneCmrPpal + ABR) * 50 +  
        (DAP+FFMM+AdicionalCmr+SegurosIntegral+PAC+PAT+Hipotecario)* 20 + 
        (BIP+Ahorro)*10 +
        ShareOfDeuda * 160 + 
        TrxCtaNorm * 80 + 
        SOW * 160 + 
        NTrx3MNorm * 80 + 
        RubroProm3MNorm * 160 AS PTJEPrincipalidad 
        FROM TEMP_PRINC_1 AS P
    )

    SELECT 
    PP.*,
    CASE 
        WHEN PTJEPrincipalidad <= 100 THEN 'BAJA'
        WHEN PTJEPrincipalidad > 100 AND PTJEPrincipalidad <= 250 THEN 'MEDIA'
        WHEN PTJEPrincipalidad > 250 AND PTJEPrincipalidad <= 400 THEN 'ALTA'
        ELSE 'MUY ALTA' END AS Principalidad
    FROM TEMP_PRINC_2 PP
    ;

END IF;