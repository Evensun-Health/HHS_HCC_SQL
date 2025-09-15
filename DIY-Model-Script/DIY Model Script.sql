--use riskadjustment --- change this to whatever database you are using
declare @benefityear int = 2025 ---- set this value to the model year you want to run your data through. Does not need to align with
declare @startdate date = '2025-01-01' -- should generally be January 1
declare @enddate date = '2025-12-31' --- last date of incurred dates you want to use
declare @paidthrough date = '2026-04-30' --- paid through date

declare @state varchar(2) = 'NY'
declare @market int = 1 --- leave null to ignore 
declare @droptemp bit = 1 --- set to 0 to retain temp tables at end. Useful for troubleshooting
declare @issuer_hios varchar(5) = '99999' -- leave null to ignore and treat all records as part of same HIOS
declare @output_table varchar(50) = 'hcc_list' --- set this to the name of the table you want the output set to be saved to.
declare @drop_existing bit = 0
/* set to 1 to delete the output table if it exists. If set to 0, script will still run and produce results to the hcc_list
table but will not drop the existing output_table specified above and will throw an error */
/***** End User Inputs; Do not edit below this line ******/

declare @model_year varchar(50)
	
if @benefityear = 2016 set @model_year = '2016_DIY_121916'
if @benefityear = 2017 set @model_year = '2017_DIY_112717'
if @benefityear = 2018 set @model_year = '2018_DIY_120418'
if @benefityear = 2019 set @model_year = '2019_DIY_071619'
if @benefityear = 2020 set @model_year = '2020_DIY_080320'
if @benefityear = 2021 set @model_year = '2021_DIY_033122'
if @benefityear = 2022 set @model_year = '2022_DIY_122022'
if @benefityear = 2023 set @model_year = '2023_NBPP_050622'
if @benefityear = 2024 set @model_year = '2024_DIY_090624'
if @benefityear = 2025 set @model_year = '2025_DIY_072325'
if @benefityear = 2026 set @model_year = '2026_NBPP_100524'

----- Updates HCC List table from the Enrollment tables ----
truncate table hcc_list

  insert into hcc_list
	  (MBR_ID,
	  eff_date, exp_date, dob, metal, hios, csr, sex, market, state, ratingarea, subscriberflag, subscribernumber, zip_code, race, ethnicity,
	  aptc_flag, statepremiumsubsidy_flag, statecsr_flag, ichra_qsehra, qsehra_spouse,
	  qsehra_medical, udf_1, udf_2, udf_3, udf_4, udf_5,
	  edge_memberid,
memberuid,
	  ssn, cmspolicyid, firstname, lastname, suffix,brokernpn, brokername, commissions, groupid,
	  premium,
	  issuer_hios
	  )
	  SELECT distinct [MemberID]
		  ,case when effdat < @startdate then @startdate else effdat end effdat
		  ,case when expdat > @enddate then @enddate else expdat end expdat
		  ,birthdate
				,[MetalLevel]
		  ,[HIOS_ID]
		  ,case when right(hios_ID, 2) = '06' then 1
		  when right(hios_id,2) = '05' then 2
		  when right(hios_id, 2) = '04' then 3
		  when right(hios_id, 2) in ('00','01') then 4
		  when right(hios_id,2) = '02' and metallevel = 'bronze' then 7
		  when right(hios_id, 2) = '02' and metallevel = 'silver' then 6
		  when right(hios_id, 2) = '02' and metallevel = 'gold' then 5
		  when right(hios_id,2) = '02' and metallevel = 'platinum' then 12
		  when right(hios_id,2) = '03' and metallevel = 'bronze' then 11
		  when right(hios_id, 2) = '03' and metallevel = 'silver' then 10
		  when right(hios_id, 2) = '03' and metallevel = 'gold' then 9
		  when right(hios_id,2) = '03' and metallevel = 'platinum' then 8
		  else 4 end CSR


		  ,[Gender]
		  ,[Market],state,
		  ratingarea, subscriberflag, subscribernumber, zip_code, race, ethnicity,
	  aptc_flag, statepremiumsubsidy_flag, statecsr_flag, ichra_qsehra, qsehra_spouse, 
	  qsehra_medical, udf_1, udf_2, udf_3, udf_4, udf_5,edge_memberid,	  coalesce(memberuid, edge_memberid, memberid),
	  	  ssn, cmspolicyid, firstname, lastname, suffix,brokernpn, brokername, commissionpaid,
		  groupid,
		  premium,
		  issuer_hios
	  FROM [Enrollment]
  where effdat <= @enddate and expdat >= @startdate
  and market = @market
  and state = @state
 and (@issuer_hios is null or issuer_hios = @issuer_hios)

	--- if memberuid is blank (rather than null), update with memberid
	update hcc_list set memberuid= mbr_id where memberuid = ''

  ---- aggregates enrollment for a member across the whole year so that the EDF and age at diagnosis are accurate if there are multiple enrollment spans ----

  if object_id('tempdb..#yearly_enrollment') is not null drop table #yearly_enrollment
  declare @cal_year int = year(@startdate)
  select memberuid, case when min(eff_date) < datefromparts(@cal_year,1,1) then datefromparts(@cal_year,1,1) else min(eff_date) end first_day, 
  case when max(exp_date) > datefromparts(@cal_year, 12, 31) then datefromparts(@cal_year, 12, 31) else max(exp_date) end last_day, year(exp_date) benefit_year, dob
  into #yearly_enrollment
  from hcc_list
  group by memberuid, year(exp_date), dob

    if object_id('tempdb..#age_last') is not null drop table #age_last
select memberuid, benefit_year, FLOOR(DATEDIFF(DAY, dob, last_day) / 365.25) age_last
into #age_last
  from #yearly_enrollment

      if object_id('tempdb..#age_first') is not null drop table #age_first
select memberuid,benefit_year, FLOOR(DATEDIFF(DAY, dob, first_day) / 365.25) age_first
into #age_first
  from #yearly_enrollment



      if object_id('tempdb..#enrollment_duration') is not null drop table #enrollment_duration
select memberuid, sum(datediff(d, eff_date, exp_date)) enr_dur, year(exp_date) benefit_year into #enrollment_duration from hcc_list
group by memberuid, year(exp_date)


  ----- determine enrollment duration for the given calendar year ----
  update hc
  set hc.age_last = age.age_last,
  hc.enr_dur = diff.enr_dur,
  hc.age_first = af.age_first
  from hcc_list hc
  join #age_last age on hc.MemberUID = age.MemberUID
  and year(hc.exp_date) = age.benefit_year
  join #enrollment_duration diff on hc.MemberUID = diff.MemberUID

  and year(hc.exp_date) = diff.benefit_year
  join #age_first af on hc.MemberUID = af.MemberUID

    
drop table #enrollment_duration
drop table #age_last
drop table #yearly_enrollment


  /******* Filter claims to acceptable records, then create a mapping table for each member to HCC mapping. Apply age/sex filter logic as necessary ****/

  if object_id('tempdb..#AcceptableClaims') is not null drop table #AcceptableClaims
create table #AcceptableClaims
(claimnumber varchar(50), 
acceptable_reason varchar(50))
CREATE NONCLUSTERED INDEX acceptable
ON [dbo].[#AcceptableClaims] ([claimnumber])

--- First insert inpatient claims where an allowable HCPCS isn't required

insert into #acceptableclaims
select distinct claimnumber, 'BillTypeIP'
from MedicalClaims where formtype = 'I' and  right(billtype,3) in ('111','117','112','113','114')
and coalesce(lineservicedateto, statementto, LineServiceDateFrom, statementfrom) between
@startdate and @enddate and paiddate <= @paidthrough
and (@issuer_hios is null or issuer_hios = @issuer_hios)
--- outpatient with acceptable servicecode
insert into #acceptableclaims
select distinct claimnumber, 'UBServiceCode'
from MedicalClaims mc
where formtype = 'I' and left(right(billtype,3),2) in ('13','71','76','77','85','87','73')
and exists (select 1 from ServiceCodeReference scref where mc.ServiceCode = scref.SRVC_CD
and scref.CPT_HCPCSELGBL_RISKADJSTMT_IND = 'Y'
and (coalesce(LineServiceDateFrom, statementfrom, lineservicedateto, statementto))  between scref.SRVC_CD_EFCTV_strt_DT and scref.SRVC_CD_EFCTV_END_DT)
and coalesce(lineservicedateto, statementto, LineServiceDateFrom, statementfrom) between
@startdate and @enddate and paiddate <= @paidthrough
	and (@issuer_hios is null or issuer_hios = @issuer_hios)
--- hcfa with acceptable servicecode
insert into #acceptableclaims
select distinct claimnumber, 'HCFAServiceCode'
from MedicalClaims mc
where formtype = 'P'
and exists (select 1 from ServiceCodeReference scref where mc.ServiceCode = scref.SRVC_CD
and scref.CPT_HCPCSELGBL_RISKADJSTMT_IND = 'Y'
and (coalesce(LineServiceDateFrom, statementfrom, lineservicedateto, statementto)) between scref.SRVC_CD_EFCTV_strt_DT and scref.SRVC_CD_EFCTV_END_DT)
and coalesce(lineservicedateto, statementto, LineServiceDateFrom, statementfrom) between
@startdate and @enddate and paiddate <= @paidthrough
and (@issuer_hios is null or issuer_hios = @issuer_hios)
--- joins acceptable claims to diagnosis codes and creates a list of member IDs and diagnoses

delete from #AcceptableClaims where claimnumber not in (select claimnumber from medicalclaims where deniedflag = 'A')

if object_id('tempdb..#MemberMapSvcDt') is not null drop table #memberMapSvcDt
select distinct 
memberid, diagnosis, clmno, svc_dt into #memberMapSvcDt
from (select memberid, clm.claimnumber clmno,coalesce(lineservicedateto, lineservicedatefrom, statementto) svc_dt, [DX1]     ,[DX2]      ,[DX3]      ,[DX4]      ,[DX5]      ,[DX6]      ,[DX7]      ,[DX8]      ,[DX9]      ,[DX10]      ,[DX11]      ,[DX12]      ,[DX13]      ,[DX14]      ,[DX15]      ,[DX16]      ,[DX17]      ,[DX18]      ,[DX19]
      ,[DX20],[DX21] ,[DX22] ,[DX23] ,[DX24] ,[DX25]
	  from medicalclaims clm join #acceptableclaims accept on clm.ClaimNumber = accept.claimnumber) p
unpivot (diagnosis for claimnumber in ([DX1]     ,[DX2]      ,[DX3]      ,[DX4]      ,[DX5]      ,[DX6]      ,[DX7]      ,[DX8]      ,[DX9]      ,[DX10]      ,[DX11]      ,[DX12]      ,[DX13]      ,[DX14]      ,[DX15]      ,[DX16]      ,[DX17]      ,[DX18]      ,[DX19]
      ,[DX20],[DX21] ,[DX22] ,[DX23] ,[DX24] ,[DX25]) )as unpvt

	  ----- Add and Delete Supplemental Diagnoses ----
	  delete from #memberMapSvcDt 
	  where exists (select 1 from Supplemental supp where #memberMapSvcDt.clmno = supp.ClaimNumber
	  and #memberMapSvcDt.diagnosis = supp.DX and supp.AddDeleteFlag = 'D'
	  and (@issuer_hios is null or supp.issuer_hios = @issuer_hios)
	  )

	  insert into #memberMapSvcDt
	  select distinct MemberID, supp.dx, clm.ClaimNumber, coalesce(lineservicedateto, lineservicedatefrom, statementto) from medicalclaims clm join #acceptableclaims accept on clm.ClaimNumber = accept.claimnumber join Supplemental supp on clm.ClaimNumber = supp.ClaimNumber
	  where AddDeleteFlag = 'A'
	  and (@issuer_hios is null or supp.issuer_hios = @issuer_hios)

	  if object_id('tempdb..#MemberDiagnosisMap') is not null drop table #MemberDiagnosisMap
	  select memberid, diagnosis, min(svc_dt) diag_dt 
	  into #MemberDiagnosisMap
	  from #memberMapSvcDt
	  group by memberid, diagnosis

	  --- Assign  HCCs and apply conditions ----

	  if object_id('tempdb..#MemberHCCMap') is not null drop table #MemberHCCMap

	  select distinct map.memberid, cc_cd HCC into #MemberHCCMap from #MemberDiagnosisMap map join enrollment enr on map.memberid = enr.memberid
	  join dx_mapping_table hcc on map.diagnosis = hcc.dgns_cd
	  where diag_dt between dgns_cd_eff_strt_dt and dgns_cd_eff_end_dt
	  and FLOOR(DATEDIFF(DAY, BirthDate, diag_dt))/365.25 between min_age_dgns_include and max_age_dgns_exclude and (CC_sex_split = 'X' or (gender = 'M' and cc_sex_split = 'male') or (gender = 'F' and cc_sex_split = 'female'))
	  	  and FLOOR(DATEDIFF(DAY, BirthDate, diag_dt))/365.25 between cc_age_split_min_age_inc and cc_age_split_max_age_exc
		  union
		  	  select map.memberid, acc_cd HCC from #MemberDiagnosisMap map join enrollment enr on map.memberid = enr.memberid
	  join dx_mapping_table hcc on map.diagnosis = hcc.dgns_cd
	  where diag_dt between dgns_cd_eff_strt_dt and dgns_cd_eff_end_dt
	  and FLOOR(DATEDIFF(DAY, BirthDate, diag_dt))/365.25 between min_age_dgns_include and max_age_dgns_exclude and (CC_sex_split = 'X' or (gender = 'M' and cc_sex_split = 'male') or (gender = 'F' and cc_sex_split = 'female'))
	  	  and FLOOR(DATEDIFF(DAY, BirthDate, diag_dt))/365.25 between cc_age_split_min_age_inc and cc_age_split_max_age_exc
		  and acc_cd <> '0'
		  CREATE NONCLUSTERED INDEX hcc_maP
ON [dbo].[#MemberHCCMap] ([HCC])
INCLUDE ([memberid])
/***** map each member to allowable RXCs *****/
			  if object_id('tempdb..#RXC_Mapping') is not null drop table #rxc_mapping
			  create table #rxc_mapping
			  (memberid varchar(50),
			  rxc varchar(10))
insert into #rxc_mapping
select distinct memberid, RXC from PharmacyClaims rx join NDC_RXC ndc
on rx.NDC = ndc.NDC
and FilledDate between @startdate and @enddate
and PaidDate <= @paidthrough
and deniedflag = 'A'
and (@issuer_hios is null or issuer_hios = @issuer_hios)
union
select distinct memberid, rxc from medicalclaims med join hcpcsrxc hcpcs on med.ServiceCode = hcpcs.hcpcs_code
where (formtype = 'P' or left(right(billtype,3),2) in ('11','13','71','76','77','85','87','73')) and coalesce(lineservicedateto, statementto, LineServiceDateFrom, statementfrom) between
@startdate and @enddate and paiddate <= @paidthrough
and deniedflag = 'A'
and (@issuer_hios is null or issuer_hios = @issuer_hios)


/***** Update the member hcc table based on the records in the mapping tables ****/


update hc
set HHS_HCC001 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '1')

update hc
set HHS_HCC002 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '2')

update hc
set HHS_HCC003 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '3')

update hc
set HHS_HCC004 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '4')


update hc
set HHS_HCC006 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '6')


update hc
set HHS_HCC008 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '8')

update hc
set HHS_HCC009 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '9')

update hc
set HHS_HCC010 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '10')


update hc
set HHS_HCC011 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '11')

update hc
set HHS_HCC012 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '12')

update hc
set HHS_HCC013 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '13')

update hc
set HHS_HCC018 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '18')

update hc
set HHS_HCC019 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '19')

update hc
set HHS_HCC020 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '20')

update hc
set HHS_HCC021 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '21')

update hc
set HHS_HCC022 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '22')

update hc
set HHS_HCC023 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '23')

update hc
set HHS_HCC026 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '26')


update hc
set HHS_HCC027 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '27')


update hc
set HHS_HCC028 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '28')

update hc
set HHS_HCC029 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '29')

update hc
set HHS_HCC030 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '30')

update hc
set HHS_HCC034 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '34')

update hc
set HHS_HCC035_1 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '351')

update hc
set HHS_HCC035_2 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '352')

update hc
set HHS_HCC036 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '36')

update hc
set HHS_HCC037_1 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '371')

update hc
set HHS_HCC037_2 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '372')

update hc
set HHS_HCC041 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '41')

update hc
set HHS_HCC042 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '42')

update hc
set HHS_HCC045 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '45')

update hc
set HHS_HCC046 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '46')

update hc
set HHS_HCC047 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '47')


update hc
set HHS_HCC048 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '48')


update hc
set HHS_HCC054 = 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '54')

update hc
set HHS_HCC055= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '55')

update hc
set HHS_HCC056= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '56')

update hc
set HHS_HCC057= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '57')

update hc
set HHS_HCC061= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '61')

update hc
set HHS_HCC062= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '62')

update hc
set HHS_HCC063= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '63')

update hc
set HHS_HCC066= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '66')

update hc
set HHS_HCC067= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '67')

update hc
set HHS_HCC068= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '68')

update hc
set HHS_HCC069= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '69')

update hc
set HHS_HCC070= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '70')

update hc
set HHS_HCC071= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '71')

update hc
set HHS_HCC073= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '73')

update hc
set HHS_HCC074= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '74')

update hc
set HHS_HCC075= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '75')

update hc
set HHS_HCC081= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '81')

update hc
set HHS_HCC082= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '82')

update hc
set HHS_HCC083= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '83')

update hc
set HHS_HCC084= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '84')

update hc
set HHS_HCC087_1= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '871')

update hc
set HHS_HCC087_2= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '872')


update hc
set HHS_HCC088= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '88')

update hc
set HHS_HCC090= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '90')

update hc
set HHS_HCC094= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '94')

update hc
set HHS_HCC096= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '96')

update hc
set HHS_HCC097= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '97')

update hc
set HHS_HCC102= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '102')

update hc
set HHS_HCC103= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '103')

update hc
set HHS_HCC106= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '106')


update hc
set HHS_HCC107= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '107')

update hc
set HHS_HCC108= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '108')

update hc
set HHS_HCC109= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '109')

update hc
set HHS_HCC110= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '110')

update hc
set HHS_HCC111= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '111')


update hc
set HHS_HCC112= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '112')

update hc
set HHS_HCC113= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '113')

update hc
set HHS_HCC114= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '114')

update hc
set HHS_HCC115= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '115')

update hc
set HHS_HCC117= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '117')

update hc
set HHS_HCC118= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '118')

update hc
set HHS_HCC119= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '119')

update hc
set HHS_HCC120= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '120')

update hc
set HHS_HCC121= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '121')

update hc
set HHS_HCC122= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '122')

update hc
set HHS_HCC123= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '123')

update hc
set HHS_HCC125= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '125')

update hc
set HHS_HCC126= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '126')

update hc
set HHS_HCC127= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '127')


update hc
set HHS_HCC128= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '128')

update hc
set HHS_HCC129= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '129')

update hc
set HHS_HCC130= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '130')

update hc
set HHS_HCC131= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '131')


update hc
set HHS_HCC132= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '132')

update hc
set HHS_HCC135= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '135')

update hc
set HHS_HCC137= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '137')

update hc
set HHS_HCC138= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '138')

update hc
set HHS_HCC139= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '139')

update hc
set HHS_HCC142= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '142')

update hc
set HHS_HCC145= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '145')



update hc
set HHS_HCC146= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '146')

update hc
set HHS_HCC149= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '149')


update hc
set HHS_HCC150= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '150')


update hc
set HHS_HCC151= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '151')


update hc
set HHS_HCC153= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '153')

update hc
set HHS_HCC154= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '154')

update hc
set HHS_HCC156= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '156')

update hc
set HHS_HCC158= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '158')

update hc
set HHS_HCC159= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '159')

update hc
set HHS_HCC160= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '160')


update hc
set HHS_HCC161_1= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '1611')


update hc
set HHS_HCC161_2= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '1612')


update hc
set HHS_HCC162= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '162')

update hc
set HHS_HCC163= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '163')

update hc
set HHS_HCC174= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '174')

update hc
set HHS_HCC183= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '183')

update hc
set HHS_HCC184= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '184')

update hc
set HHS_HCC187= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '187')


update hc
set HHS_HCC188= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '188')

update hc
set HHS_HCC203= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '203')

update hc
set HHS_HCC204= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '204')


update hc
set HHS_HCC205= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '205')

update hc
set HHS_HCC207= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '207')


update hc
set HHS_HCC208= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '208')


update hc
set HHS_HCC209= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '209')


update hc
set HHS_HCC210= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '210')

update hc
set HHS_HCC211= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '211')

update hc
set HHS_HCC212= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '212')

update hc
set HHS_HCC217= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '217')

update hc
set HHS_HCC218= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '218')

update hc
set HHS_HCC219= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '219')

update hc
set HHS_HCC223= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '223')

update hc
set HHS_HCC226= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '226')

update hc
set HHS_HCC228= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '228')

update hc
set HHS_HCC234= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '234')

update hc
set HHS_HCC251= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '251')

update hc
set HHS_HCC253= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '253')

update hc
set HHS_HCC254= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '254')


update hc
set HHS_HCC251= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '251')

update hc
set HHS_HCC242= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '242')

update hc
set HHS_HCC243= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '243')

update hc
set HHS_HCC244= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '244')

update hc
set HHS_HCC245= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '245')

update hc
set HHS_HCC246= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '246')
update hc
set HHS_HCC247= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '247')
update hc
set HHS_HCC248= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '248')
update hc
set HHS_HCC249= 1
from hcc_list hc 
where exists (select 1 from #MemberHCCMap mp where hc.mbr_id = mp.MemberID
and hcc = '249')
/** apply set to 0 logic **/
update hcc_list
set hhs_hcc004 = 0
where hhs_hcc003 = 1

update hcc_list
set hhs_hcc009 = 0, hhs_hcc010 = 0, hhs_hcc011 = 0, HHS_HCC012 = 0, HHS_HCC013 = 0
where HHS_HCC008 = 1

update hcc_list
set  hhs_hcc010 = 0, hhs_hcc011 = 0, HHS_HCC012 = 0, HHS_HCC013 = 0
where HHS_HCC009 = 1

update hcc_list
set hhs_hcc011 = 0, HHS_HCC012 = 0, HHS_HCC013 = 0
where HHS_HCC010 = 1

update hcc_list
set  HHS_HCC012 = 0, HHS_HCC013 = 0
where HHS_HCC011 = 1

update hcc_list
set  HHS_HCC013 = 0
where HHS_HCC012 = 1


update hcc_list
set hhs_hcc019 = 0, hhs_hcc020 = 0, hhs_hcc021 = 0, hhs_hcc022 = 0
where hhs_hcc018 = 1

update hcc_list
set hhs_hcc020 = 0, hhs_hcc021 = 0
where hhs_hcc019 = 1

update hcc_list
set hhs_hcc020 = 0, hhs_hcc021 = 0
where hhs_hcc019 = 1

update hcc_list
set hhs_hcc021 = 0
where hhs_hcc020 = 1

update hcc_list
set hhs_hcc035_1 = 0, hhs_hcc035_2 = 0, HHS_HCC036 = 0, hhs_hcc037_1 = 0, hhs_hcc037_2 = 0
where hhs_hcc034 = 1

update hcc_list
set hhs_hcc035_2 = 0, HHS_HCC036 = 0, hhs_hcc037_1 = 0, hhs_hcc037_2 = 0
where HHS_HCC035_1 = 1

update hcc_list
set  HHS_HCC036 = 0, hhs_hcc037_1 = 0, hhs_hcc037_2 = 0
where HHS_HCC035_2 = 1

update hcc_list
set   hhs_hcc037_1 = 0, hhs_hcc037_2 = 0
where HHS_HCC036 = 1

update hcc_list
set   hhs_hcc037_2 = 0
where HHS_HCC037_1 = 1

update hcc_list
set   HHS_HCC045 = 0, HHS_HCC048 = 0
where HHS_HCC041 = 1

update hcc_list
set   HHS_HCC045 = 0
where HHS_HCC042 = 1

update hcc_list
set   HHS_HCC047 = 0
where HHS_HCC046 = 1

update hcc_list
set   HHS_HCC055 = 0
where HHS_HCC054 = 1

update hcc_list
set   HHS_HCC057 = 0
where HHS_HCC056 = 1

update hcc_list
set   HHS_HCC075 = 0
where HHS_HCC066 = 1

update hcc_list
set   HHS_HCC075 = 0
where HHS_HCC067 = 1

update hcc_list
set   HHS_HCC069 = 0,  HHS_HCC074 = 0,  HHS_HCC075 = 0
where HHS_HCC068 = 1

update hcc_list
set   HHS_HCC071= 0
where HHS_HCC070 = 1

update hcc_list
set   HHS_HCC074= 0
where HHS_HCC073 = 1

update hcc_list
set   HHS_HCC082 = 0,  HHS_HCC083 = 0,  HHS_HCC084 = 0
where HHS_HCC081 = 1

update hcc_list
set   HHS_HCC083 = 0,  HHS_HCC084 = 0
where HHS_HCC082 = 1

update hcc_list
set   HHS_HCC084 = 0
where HHS_HCC083 = 1

update hcc_list
set   HHS_HCC087_2 = 0, HHS_HCC088 = 0, HHS_HCC090 = 0, HHS_HCC102 = 0, HHS_HCC103 = 0
where HHS_HCC087_1 = 1

update hcc_list
set   HHS_HCC088 = 0, HHS_HCC090 = 0, HHS_HCC102 = 0, HHS_HCC103 = 0
where HHS_HCC087_2 = 1

update hcc_list
set   HHS_HCC090 = 0, HHS_HCC102 = 0, HHS_HCC103 = 0
where HHS_HCC088 = 1

update hcc_list
set   HHS_HCC097 = 0
where HHS_HCC096 = 1

update hcc_list
set   HHS_HCC090 = 0, HHS_HCC103 = 0
where HHS_HCC102 = 1

update hcc_list
set   HHS_HCC090 = 0
where HHS_HCC103 = 1

update hcc_list
set   HHS_HCC107 = 0, HHS_HCC108 = 0, HHS_HCC109 = 0, HHS_HCC110 = 0, HHS_HCC150 = 0, HHS_HCC151 = 0, HHS_HCC228 = 0
where HHS_HCC106 = 1

update hcc_list
set   HHS_HCC109 = 0, HHS_HCC110 = 0, HHS_HCC150 = 0, HHS_HCC151 = 0, HHS_HCC228 = 0
where HHS_HCC107 = 1

update hcc_list
set   HHS_HCC109 = 0, HHS_HCC110 = 0,  HHS_HCC151 = 0, HHS_HCC228 = 0
where HHS_HCC108 = 1

update hcc_list
set   HHS_HCC110 = 0,  HHS_HCC151 = 0, HHS_HCC228 = 0
where HHS_HCC109 = 1

update hcc_list
set  HHS_HCC228 = 0
where HHS_HCC110 = 1

update hcc_list
set  HHS_HCC107 = 0, HHS_HCC109 = 0, HHS_HCC110 = 0, HHS_HCC113 = 0, HHS_HCC150 = 0, HHS_HCC151 = 0, HHS_HCC228 = 0
where HHS_HCC112 = 1

update hcc_list
set  HHS_HCC107 = 0, HHS_HCC109 = 0, HHS_HCC110 = 0, HHS_HCC150 = 0, HHS_HCC151 = 0, HHS_HCC228 = 0
where HHS_HCC113 = 1

update hcc_list
set  HHS_HCC121 = 0
where HHS_HCC114 = 1

update hcc_list
set  HHS_HCC126 = 0, HHS_HCC127 = 0
where HHS_HCC125 = 1

update hcc_list
set   HHS_HCC127 = 0
where HHS_HCC126 = 1

update hcc_list
set   HHS_HCC129 = 0, HHS_HCC130 = 0
where HHS_HCC128 = 1

update hcc_list
set  HHS_HCC130 = 0
where HHS_HCC129 = 1

update hcc_list
set  HHS_HCC132= 0
where HHS_HCC131 = 1

update hcc_list
set  HHS_HCC138= 0, HHS_HCC139= 0
where HHS_HCC137 = 1

update hcc_list
set HHS_HCC139= 0
where HHS_HCC138 = 1

update hcc_list
set HHS_HCC146= 0, HHS_HCC149= 0
where HHS_HCC145 = 1

update hcc_list
set HHS_HCC151= 0
where HHS_HCC150 = 1

update hcc_list
set HHS_HCC217= 0, HHS_HCC234= 0, HHS_HCC254= 0
where HHS_HCC153 = 1

update hcc_list
set HHS_HCC159= 0, HHS_HCC160= 0, HHS_HCC161_1= 0, HHS_HCC161_2= 0, HHS_HCC162= 0
where HHS_HCC158 = 1

update hcc_list
set HHS_HCC160= 0, HHS_HCC161_1= 0, HHS_HCC161_2= 0
where HHS_HCC159 = 1

update hcc_list
set HHS_HCC161_1= 0, HHS_HCC161_2= 0
where HHS_HCC160 = 1


update hcc_list
set  HHS_HCC161_2= 0
where HHS_HCC161_1 = 1

update hcc_list
set  HHS_HCC161_1= 0, HHS_HCC161_2= 0
where HHS_HCC162 = 1

update hcc_list
set  HHS_HCC184= 0, HHS_HCC187= 0, HHS_HCC188= 0
where HHS_HCC183 = 1

update hcc_list
set  HHS_HCC187= 0, HHS_HCC188= 0
where HHS_HCC184 = 1

update hcc_list
set   HHS_HCC188= 0
where HHS_HCC187 = 1

update hcc_list
set   HHS_HCC204= 0, HHS_HCC205= 0, HHS_HCC210= 0, HHS_HCC211= 0, HHS_HCC212= 0
where HHS_HCC203 = 1

update hcc_list
set   HHS_HCC205= 0, HHS_HCC210= 0, HHS_HCC211= 0, HHS_HCC212= 0
where HHS_HCC204 = 1

update hcc_list
set  HHS_HCC210= 0, HHS_HCC211= 0, HHS_HCC212= 0
where HHS_HCC205 = 1


update hcc_list
set HHS_HCC203= 0, HHS_HCC204= 0, HHS_HCC205= 0, HHS_HCC208= 0, HHS_HCC209= 0, HHS_HCC210= 0, HHS_HCC211= 0, HHS_HCC212= 0
where HHS_HCC207 = 1

update hcc_list
set HHS_HCC209= 0, HHS_HCC210= 0, HHS_HCC211= 0, HHS_HCC212= 0
where HHS_HCC208 = 1

update hcc_list
set  HHS_HCC210= 0, HHS_HCC211= 0, HHS_HCC212= 0
where HHS_HCC209 = 1

update hcc_list
set   HHS_HCC211= 0, HHS_HCC212= 0
where HHS_HCC210 = 1

update hcc_list
set   HHS_HCC212= 0
where HHS_HCC211 = 1

update hcc_list
set   HHS_HCC219= 0
where HHS_HCC218 = 1

update hcc_list
set   HHS_HCC122= 0
where HHS_HCC223 = 1

update hcc_list
set   HHS_HCC254= 0
where HHS_HCC234 = 1

update hcc_list
set   HHS_HCC243= 0, HHS_HCC244= 0, HHS_HCC245= 0, HHS_HCC246= 0, HHS_HCC247= 0, HHs_HCC248 = 0,
hhs_hcc249 = 0
where HHS_HCC242 = 1

update hcc_list
set   HHS_HCC244= 0, HHS_HCC245= 0, HHS_HCC246= 0, HHS_HCC247= 0, HHs_HCC248 = 0,
hhs_hcc249 = 0
where HHS_HCC243 = 1

update hcc_list
set    HHS_HCC245= 0, HHS_HCC246= 0, HHS_HCC247= 0, HHs_HCC248 = 0,
hhs_hcc249 = 0
where HHS_HCC244 = 1


update hcc_list
set    HHS_HCC246= 0, HHS_HCC247= 0, HHs_HCC248 = 0,
hhs_hcc249 = 0
where HHS_HCC245 = 1

update hcc_list
set    HHS_HCC247= 0, HHs_HCC248 = 0,
hhs_hcc249 = 0
where HHS_HCC246 = 1

update hcc_list
set    HHs_HCC248 = 0,
hhs_hcc249 = 0
where HHS_HCC247 = 1


update hcc_list
set  
hhs_hcc249 = 0
where HHS_HCC248 = 1

/**** Age/Sex Factors *****/
update hcc_list
set  
age0_male = 1
where age_last = 0 and sex = 'M'


update hcc_list
set  
age1_male = 1
where age_last = 1 and sex = 'M'

update hcc_list
set  
mage_last_2_4 = 1
where age_last between 2 and 4 and sex = 'M'

update hcc_list
set  
fage_last_2_4 = 1
where age_last between 2 and 4 and sex = 'F'

update hcc_list
set  
mage_last_5_9= 1
where age_last between 5 and 9 and sex = 'M'

update hcc_list
set  
fage_last_5_9= 1
where age_last between 5 and 9 and sex = 'F'

update hcc_list
set  
mage_last_10_14= 1
where age_last between 10 and 14 and sex = 'M'

update hcc_list
set  
Fage_last_10_14= 1
where age_last between 10 and 14 and sex = 'F'

update hcc_list
set  
mage_last_15_20= 1
where age_last between 15 and 20 and sex = 'M'

update hcc_list
set  
fage_last_15_20= 1
where age_last between 15 and 20 and sex = 'F'

update hcc_list
set  
mage_last_21_24= 1
where age_last between 21 and 24 and sex = 'M'

update hcc_list
set  
fage_last_21_24= 1
where age_last between 21 and 24 and sex = 'F'

update hcc_list
set  
mage_last_25_29= 1
where age_last between 25 and 29 and sex = 'M'

update hcc_list
set  
fage_last_25_29= 1
where age_last between 25 and 29 and sex = 'F'

update hcc_list
set  
mage_last_30_34= 1
where age_last between 30 and 34 and sex = 'M'

update hcc_list
set  
fage_last_30_34= 1
where age_last between 30 and 34 and sex = 'F'

update hcc_list
set  
mage_last_35_39= 1
where age_last between 35 and 39 and sex = 'M'

update hcc_list
set  
fage_last_35_39= 1
where age_last between 35 and 39 and sex = 'F'

update hcc_list
set  
mage_last_40_44= 1
where age_last between 40 and 44 and sex = 'M'

update hcc_list
set  
fage_last_40_44= 1
where age_last between 40 and 44 and sex = 'F'

update hcc_list
set  
mage_last_45_49= 1
where age_last between 45 and 49 and sex = 'M'

update hcc_list
set  
fage_last_45_49= 1
where age_last between 45 and 49 and sex = 'F'

update hcc_list
set  
mage_last_50_54= 1
where age_last between 50 and 54 and sex = 'M'

update hcc_list
set  
fage_last_50_54= 1
where age_last between 50 and 54 and sex = 'F'

update hcc_list
set  
mage_last_55_59= 1
where age_last between 55 and 59 and sex = 'M'

update hcc_list
set  
fage_last_55_59= 1
where age_last between 55 and 59 and sex = 'F'

update hcc_list
set  
mage_last_60_GT= 1
where age_last >= 60 and sex = 'M'

update hcc_list
set  
fage_last_60_GT= 1
where age_last >= 60 and sex = 'F'



/****** Apply RXC Flags and set RXC / HCC interaction factors *****/


update hc set RXC_01 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '1')

update hc set RXC_02 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '2')

update hc set RXC_03 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '3')

update hc set RXC_04 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '4')

update hc set RXC_05 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '5')


update hc set RXC_06 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '6')

update hc set RXC_07 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '7')



update hc set RXC_08 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '8')


update hc set RXC_09 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '9')

update hc set RXC_10 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = '10')

update hc set ACF_01 = 1
from hcc_list hc 
where exists (select 1 from #rxc_mapping mp where hc.mbr_id = mp.MemberID
and rxc = 'ACF_01')


---- set to 0 RXC

update hc set RXC_07 = 0
from hcc_list hc 
where rxc_06 = 1

--- Proposed change where if someone was taking PrEP but also had an HIV DX, give themc redit for RXC01 rather than ACF
update hc set rxc_01 = 1, acf_01 = 0 from hcc_list hc  where acf_01 = 1 and hhs_hcc001 = 1

--- RXC HCC interaction factors ---
update hcc_list set
RXC_01_X_HCC001 = 1
where rxc_01 = 1 and hhs_hcc001 = 1

update hcc_list set
RXC_02_X_HCC037_1_036_035_2_035_1_034 = 1
where  RXC_02 = 1 and (HHS_HCC037_1 = 1 or HHS_HCC036 = 1 or HHS_HCC035_2 = 1 or HHS_HCC035_1 = 1 or HHS_HCC034 = 1) 

update hcc_list set
RXC_03_X_HCC142 = 1
where RXC_03 = 1 and HHS_HCC142 = 1

update hcc_list set
RXC_04_X_HCC184_183_187_188 = 1
where 
RXC_04 = 1 and (HHS_HCC184 = 1 or HHS_HCC183 = 1 or HHS_HCC187 = 1 or HHS_HCC188 = 1)

update hcc_list set
RXC_05_X_HCC048_041 = 1
where RXC_05 = 1 and (HHS_HCC048 = 1 or HHS_HCC041 = 1)

update hcc_list set
RXC_06_X_HCC018_019_020_021 = 1
where RXC_06 = 1 and (HHS_HCC018 = 1 or HHS_HCC019 = 1 or HHS_HCC020 = 1 or HHS_HCC021 = 1) 

update hcc_list
set RXC_07_X_HCC018_019_020_021 = 1
where RXC_07 = 1 and (HHS_HCC018 = 1 or HHS_HCC019 = 1 or HHS_HCC020 = 1 or HHS_HCC021 = 1)

update hcc_list
set RXC_08_X_HCC118 = 1
where RXC_08 = 1 and HHS_HCC118 = 1 

update hcc_list
set RXC_09_X_HCC056 = 1
where RXC_09 = 1 and HHS_HCC056 = 1

update hcc_list set
RXC_09_X_HCC057 = 1
where RXC_09 = 1 and HHS_HCC057 = 1

update hcc_list
set RXC_09_x_HCC056_057_and_048_041 = 1
where rxc_09 = 1 and (HHS_HCC056 = 1 or HHS_HCC057 = 1) and (HHS_HCC048 = 1 or HHS_HCC041 = 1)

update hcc_list
set
RXC_09_X_HCC048_041  = 1
where RXC_09 = 1 and (HHS_HCC048 = 1 or HHS_HCC041 = 1)

update hcc_list
set RXC_10_X_HCC159_158 = 1
where RXC_10 = 1 and (HHS_HCC159 = 1 or HHS_HCC158 = 1) 



/*** set enrollment duration factors for 2022 and prior years ***/
IF @benefityear <= 2022
--- for 2023, EDF is calculated based on payment HCC count further below ---
BEGIN
update hcc_list
set ed_1 = 1 where
enr_dur between  1 and 31
update hcc_list
set ed_2 = 1 where enr_dur between 32 and 62
update hcc_list
set ed_3 = 1 where enr_dur between 63 and 92
update hcc_list
set ed_4 = 1 where enr_dur between 93 and 123
update hcc_list
set ed_5 = 1
where enr_dur between 124 and 153
update hcc_list
set ed_6 = 1
where enr_dur between 154 and 184
update hcc_list set ed_7 = 1
where enr_dur between 185 and 214
update hcc_list set ed_8 = 1
where enr_dur between 215 and 245
update hcc_list set ed_9 = 1
where enr_dur between 246 and 275
update hcc_list set ed_10 = 1 
where enr_dur between 276 and 306
update hcc_list set ed_11 = 1
where enr_dur between 307 and 335
END

/**** Set Severity indicator and HCC Groupers*****/
---- Adult Model ----
IF @benefityear <= 2022 ---- Severity model change for 2023 ----
BEGIN
UPDATE HCC_LIST
SET SEVERE_V3 = 1
WHERE (HHS_HCC002 = 1 OR
HHS_HCC042 = 1 OR
HHS_HCC120 = 1 OR
HHS_HCC122 = 1 OR
HHS_HCC125 = 1 OR
HHS_HCC126 = 1 OR
HHS_HCC127 = 1  OR
HHS_HCC156 = 1)
and age_last >= 21
END

update hcc_list set G01 =1, hhs_hcc019 =0, hhs_hcc020 = 0, hhs_hcc021 = 0
where  (hhs_hcc019 =1 or hhs_hcc020 = 1 or hhs_hcc021 = 1)
and age_last >= 21

update hcc_list set G02b =1, hhs_hcc026 =0, hhs_hcc027 = 0
where  (hhs_hcc026 =1 or hhs_hcc027 = 1)
and age_last >= 21

update hcc_list set G04 =1, hhs_hcc061 =0, hhs_hcc062 = 0
where  (HHS_HCC061 =1 or HHS_HCC062 = 1)
and age_last >= 21

update hcc_list set G06A =1, HHS_HCC067 =0, HHS_HCC068   = 0, HHS_HCC069   = 0
where  (HHS_HCC067 =1 or HHS_HCC068 = 1 or HHS_HCC069   = 1)
and age_last >= 21

update hcc_list set G07A =1, HHS_HCC070 =0, HHS_HCC071   = 0
where  (HHS_HCC070 =1 or HHS_HCC071 = 1)
and age_last >= 21

update hcc_list set G08 =1, HHS_HCC073 =0, HHS_HCC074   = 0
where  (HHS_HCC073 =1 or HHS_HCC074 = 1)
and age_last >= 21

update hcc_list set G09A =1, HHS_HCC081 =0, HHS_HCC082   = 0
where  (HHS_HCC081 =1 or HHS_HCC082 = 1)
and age_last >= 21

update hcc_list set G09C =1, HHS_HCC083 =0, HHS_HCC084   = 0
where  (HHS_HCC083 =1 or HHS_HCC084 = 1)
and age_last >= 21

update hcc_list set G10 =1, HHS_HCC106 =0, HHS_HCC107   = 0
where  (HHS_HCC106 =1 or HHS_HCC107 = 1)
and age_last >= 21

update hcc_list set G11 =1, HHS_HCC108 =0, HHS_HCC109   = 0
where  HHS_HCC108 =1 or HHS_HCC109 = 1

update hcc_list set G12 =1, HHS_HCC117 =0, HHS_HCC119   = 0
where  (HHS_HCC117 =1 or HHS_HCC119 = 1)
and age_last >= 21

update hcc_list set G13 =1, HHS_HCC126 =0, HHS_HCC127   = 0
where  (HHS_HCC126 =1 or HHS_HCC127 = 1)
and age_last >= 21

update hcc_list set G14 =1, HHS_HCC128 =0, HHS_HCC129   = 0
where  (HHS_HCC128 =1 or HHS_HCC129 = 1)
and age_last >= 21

update hcc_list set G21 =1, HHS_HCC137 =0, HHS_HCC138   = 0, HHS_HCC139 = 0
where  (HHS_HCC137 =1 or HHS_HCC138 = 1 OR  HHS_HCC139 = 1)
and age_last >= 21

update hcc_list set G15A =1, HHS_HCC160 =0, HHS_HCC161_1   = 0, HHS_HCC161_2 = 0
where  (HHS_HCC160 =1 or HHS_HCC161_1 = 1 OR  HHS_HCC161_2 = 1)
and age_last >= 21

update hcc_list set G16 =1, HHS_HCC187 =0, HHS_HCC188   = 0
where  (HHS_HCC187 =1 or HHS_HCC188 = 1)
and age_last >= 21

update hcc_list set G17A =1, HHS_HCC204 =0, HHS_HCC205   = 0
where  (HHS_HCC204 =1 or HHS_HCC205 = 1)
and age_last >= 21

update hcc_list set G18A =1, HHS_HCC207 =0, HHS_HCC208   = 0
where  (HHS_HCC207 =1 or HHS_HCC208 = 1)
and age_last >= 21

if @benefityear >= 2024
begin
update hcc_list set G24 = 1, hhs_hcc018 = 0, hhs_hcc183 = 0
where (hhs_hcc183 = 1 or hhs_hcc018 = 1)
and age_last >= 21
end

UPDATE HCC_LIST SET INT_GROUP_H = 1 WHERE 
(SEVERE_V3 = 1 and HHS_HCC006 = 1) OR  (
SEVERE_V3 = 1 and HHS_HCC008 = 1) or
(SEVERE_V3 = 1 and HHS_HCC009 = 1) or
(SEVERE_V3 = 1 and HHS_HCC010 = 1 ) or
(SEVERE_V3 = 1 and HHS_HCC115 = 1) or
(SEVERE_V3 = 1 and HHS_HCC135 = 1 ) or
(SEVERE_V3 = 1 and HHS_HCC145 = 1) or
(SEVERE_V3 = 1 and G06A       = 1 ) or
(SEVERE_V3 = 1 and G08        = 1 )
and age_last >= 21
----- child model ----

update hcc_list set G01 =1, hhs_hcc019 =0, hhs_hcc020 = 0, hhs_hcc021 = 0
where  (hhs_hcc019 =1 or hhs_hcc020 = 1 or hhs_hcc021 = 1)
and age_last between 2 and 20

update hcc_list set G02b =1, hhs_hcc026 =0, hhs_hcc027 = 0
where  (hhs_hcc026 =1 or hhs_hcc027 = 1)
and age_last between 2 and 20

update hcc_list set G02d =1, hhs_hcc028 =0, hhs_hcc029 = 0
where  (hhs_hcc028 =1 or hhs_hcc029 = 1)
and age_last between 2 and 20


update hcc_list set G03 =1, hhs_hcc054 =0, hhs_hcc055 = 0
where  (hhs_hcc054 =1 or hhs_hcc055 = 1)
and age_last between 2 and 20

update hcc_list set G04 =1, hhs_hcc061 =0, hhs_hcc062 = 0
where  (HHS_HCC061 =1 or HHS_HCC062 = 1)
and age_last between 2 and 20

update hcc_list set G06A =1, HHS_HCC067 =0, HHS_HCC068   = 0, HHS_HCC069   = 0
where  (HHS_HCC067 =1 or HHS_HCC068 = 1 or HHS_HCC069   = 1)
and age_last between 2 and 20

update hcc_list set G07A =1, HHS_HCC070 =0, HHS_HCC071   = 0
where  (HHS_HCC070 =1 or HHS_HCC071 = 1)
and age_last between 2 and 20

update hcc_list set G08 =1, HHS_HCC073 =0, HHS_HCC074   = 0
where  (HHS_HCC073 =1 or HHS_HCC074 = 1)
and age_last between 2 and 20

update hcc_list set G09A =1, HHS_HCC081 =0, HHS_HCC082   = 0
where  (HHS_HCC081 =1 or HHS_HCC082 = 1)
and age_last between 2 and 20

update hcc_list set G09C =1, HHS_HCC083 =0, HHS_HCC084   = 0
where  (HHS_HCC083 =1 or HHS_HCC084 = 1)
and age_last between 2 and 20

update hcc_list set G10 =1, HHS_HCC106 =0, HHS_HCC107   = 0
where  (HHS_HCC106 =1 or HHS_HCC107 = 1)
and age_last between 2 and 20

update hcc_list set G11 =1, HHS_HCC108 =0, HHS_HCC109   = 0
where  HHS_HCC108 =1 or HHS_HCC109 = 1
and age_last between 2 and 20

update hcc_list set G12 =1, HHS_HCC117 =0, HHS_HCC119   = 0
where  (HHS_HCC117 =1 or HHS_HCC119 = 1)
and age_last between 2 and 20

update hcc_list set G13 =1, HHS_HCC126 =0, HHS_HCC127   = 0
where  (HHS_HCC126 =1 or HHS_HCC127 = 1)
and age_last between 2 and 20

update hcc_list set G14 =1, HHS_HCC128 =0, HHS_HCC129   = 0
where  (HHS_HCC128 =1 or HHS_HCC129 = 1)
and age_last between 2 and 20

update hcc_list set G23 =1, HHS_HCC131 =0, HHS_HCC132   = 0
where  ( HHS_HCC131 = 1 OR  HHS_HCC132 = 1)
and age_last between 2 and 20


update hcc_list set G16 =1, HHS_HCC187 =0, HHS_HCC188   = 0
where  (HHS_HCC187 =1 or HHS_HCC188 = 1)
and age_last between 2 and 20

update hcc_list set G17A =1, HHS_HCC204 =0, HHS_HCC205   = 0
where  (HHS_HCC204 =1 or HHS_HCC205 = 1)
and age_last between 2 and 20

update hcc_list set G18A =1, HHS_HCC207 =0, HHS_HCC208   = 0
where  (HHS_HCC207 =1 or HHS_HCC208 = 1)
and age_last between 2 and 20

update hcc_list set G19B =1, HHS_HCC210 =0, HHS_HCC211   = 0
where  (HHS_HCC210 =1 or HHS_HCC211 = 1)
and age_last between 2 and 20

update hcc_list set G22 =1, HHS_HCC234 =0, HHS_HCC254   = 0
where  (HHS_HCC234 =1 or HHS_HCC254 = 1)
and age_last between 2 and 20

---- infant model -----

/**** set infant severity level logic ****/

update hcc_list set ihcc_severity5 = 1 where age_last <= 1 and( HHS_HCC008 = 1 or
HHS_HCC018 = 1 or
HHS_HCC034 = 1 or
HHS_HCC041 = 1 or
HHS_HCC042 = 1 or
HHS_HCC125 = 1 or
HHS_HCC128 = 1 or
HHS_HCC129 = 1 or
HHS_HCC130 = 1 or
HHS_HCC137 = 1 or
HHS_HCC158 = 1 or
HHS_HCC183 = 1 or
HHS_HCC184 = 1 or
HHS_HCC251 = 1)

update hcc_list set ihcc_severity4 = 1 where age_last <= 1 and (HHS_HCC002 = 1 or
HHS_HCC009 = 1 or
HHS_HCC026 = 1 or
HHS_HCC030 = 1 or
HHS_HCC035_1 = 1 or
HHS_HCC035_2 = 1 or
HHS_HCC067 = 1 or
HHS_HCC068 = 1 or
HHS_HCC073 = 1 or
HHS_HCC106 = 1 or
HHS_HCC107 = 1 or
HHS_HCC111 = 1 or
HHS_HCC112 = 1 or
HHS_HCC115 = 1 or
HHS_HCC122 = 1 or
HHS_HCC126 = 1 or
HHS_HCC127 = 1 or
HHS_HCC131 = 1 or
HHS_HCC135 = 1 or
HHS_HCC138 = 1 or
HHS_HCC145 = 1 or
HHS_HCC146 = 1 or
HHS_HCC154 = 1 or
HHS_HCC156 = 1 or
HHS_HCC163 = 1 or
HHS_HCC187 = 1 or
HHS_HCC253 = 1)
update hcc_list set ihcc_severity3 = 1 where age_last <= 1 and (HHS_HCC001 = 1 or
HHS_HCC003 = 1 or
HHS_HCC006 = 1 or
HHS_HCC010 = 1 or
HHS_HCC011 = 1 or
HHS_HCC012 = 1 or
HHS_HCC027 = 1 or
HHS_HCC045 = 1 or
HHS_HCC054 = 1 or
HHS_HCC055 = 1 or
HHS_HCC061 = 1 or
HHS_HCC063 = 1 or
HHS_HCC066 = 1 or
HHS_HCC074 = 1 or
HHS_HCC075 = 1 or
HHS_HCC081 = 1 or
HHS_HCC082 = 1 or
HHS_HCC083 = 1 or
HHS_HCC084 = 1 or
HHS_HCC096 = 1 or
HHS_HCC108 = 1 or
HHS_HCC109 = 1 or
HHS_HCC110 = 1 or
HHS_HCC113 = 1 or
HHS_HCC114 = 1 or
HHS_HCC117 = 1 or
HHS_HCC119 = 1 or
HHS_HCC121 = 1 or
HHS_HCC132 = 1 or
HHS_HCC139 = 1 or
HHS_HCC142 = 1 or
HHS_HCC149 = 1 or
HHS_HCC150 = 1 or
HHS_HCC159 = 1 or
HHS_HCC218 = 1 or
HHS_HCC223 = 1 or
HHS_HCC226 = 1 or
HHS_HCC228 = 1)

update hcc_list set ihcc_severity2 = 1 where age_last <= 1 and (HHS_HCC004 = 1 or
HHS_HCC013 = 1 or
HHS_HCC019 = 1 or
HHS_HCC020 = 1 or
HHS_HCC021 = 1 or
HHS_HCC023 = 1 or
HHS_HCC029 = 1 or
HHS_HCC036 = 1 or
HHS_HCC046 = 1 or
HHS_HCC047 = 1 or
HHS_HCC048 = 1 or
HHS_HCC056 = 1 or
HHS_HCC057 = 1 or
HHS_HCC062 = 1 or
HHS_HCC069 = 1 or
HHS_HCC070 = 1 or
HHS_HCC097 = 1 or
HHS_HCC120 = 1 or
HHS_HCC151 = 1 or
HHS_HCC153 = 1 or
HHS_HCC160 = 1 or
HHS_HCC161_1 = 1 or
HHS_HCC162 = 1 or
HHS_HCC188 = 1 or
HHS_HCC217 = 1 or
HHS_HCC219 = 1)

update hcc_list set ihcc_severity1 = 1 where age_last <= 1 and (
HHS_HCC037_1 = 1 or
HHS_HCC037_2 = 1 or
HHS_HCC071 = 1 or
HHS_HCC102 = 1 or
HHS_HCC103 = 1 or
HHS_HCC118 = 1 or
HHS_HCC161_2 = 1 or
HHS_HCC234 = 1 or
HHS_HCC254 = 1)

--- assign maturity levels
update hcc_list set ihcc_age1 =1  where age_last = 1

update hcc_list set ihcc_extremely_immature = 1 where AGE_LAST = 0 and (HHS_HCC242 = 1 or HHS_HCC243 = 1 or HHS_HCC244 = 1) 

update hcc_list set IHCC_IMMATURE = 1 where AGE_LAST = 0 and (HHS_HCC245 = 1 or HHS_HCC246 = 1)

update hcc_list set IHCC_PREMATURE_MULTIPLES = 1 where AGE_LAST = 0 and (HHS_HCC247 = 1 or HHS_HCC248 = 1)

update hcc_list set ihcc_term = 1 where AGE_LAST = 0 and HHS_HCC249 = 1

update hcc_list set ihcc_age1 = 1 where AGE_LAST = 0 and (HHS_HCC242 = 0 and HHS_HCC243 = 0 and HHS_HCC244 = 0 and HHS_HCC245 = 0 and HHS_HCC246 = 0 and HHS_HCC247 = 0 and  HHS_HCC248 = 0 and HHS_HCC249 = 0)
--- impose maturity hiearchies

update hcc_list set ihcc_term = 0, ihcc_immature = 0, ihcc_premature_multiples = 0 where IHCC_EXTREMELY_IMMATURE  = 1

update hcc_list set  ihcc_term = 0, ihcc_premature_multiples = 0
where ihcc_immature = 1

update hcc_list set ihcc_term = 0
where ihcc_premature_multiples = 1



--- impose hierarchies for infant severity ---
update hcc_list set ihcc_severity4 = 0, ihcc_severity3 = 0, ihcc_severity2 = 0, ihcc_severity1 = 0
where ihcc_severity5 = 1

update hcc_list set ihcc_severity3 = 0, ihcc_severity2 = 0, ihcc_severity1 = 0
where ihcc_severity4 = 1


update hcc_list set  ihcc_severity2 = 0, ihcc_severity1 = 0
where ihcc_severity3 = 1

update hcc_list set ihcc_severity1 = 0
where ihcc_severity2 = 1

update hcc_list set ihcc_severity1 = 1
where IHCC_SEVERITY5 = 0 and IHCC_SEVERITY4 = 0 and IHCC_SEVERITY3 = 0 and IHCC_SEVERITY2 = 0
and  AGE_LAST between 0 and 1


--- set infant HCCs ---
	update hcc_list set EXTREMELY_IMMATURE_X_SEVERITY5  = 1 where IHCC_SEVERITY5 = 1 and IHCC_EXTREMELY_IMMATURE  = 1
update hcc_list set IMMATURE_X_SEVERITY5            = 1 where IHCC_SEVERITY5 = 1 and IHCC_IMMATURE            = 1
update hcc_list set PREMATURE_MULTIPLES_X_SEVERITY5 = 1 where IHCC_SEVERITY5 = 1 and IHCC_PREMATURE_MULTIPLES = 1
update hcc_list set TERM_X_SEVERITY5                = 1 where IHCC_SEVERITY5 = 1 and IHCC_TERM                = 1
update hcc_list set AGE1_X_SEVERITY5                = 1 where IHCC_SEVERITY5 = 1 and IHCC_AGE1                = 1
update hcc_list set EXTREMELY_IMMATURE_X_SEVERITY4  = 1 where IHCC_SEVERITY4 = 1 and IHCC_EXTREMELY_IMMATURE  = 1
update hcc_list set IMMATURE_X_SEVERITY4            = 1 where IHCC_SEVERITY4 = 1 and IHCC_IMMATURE            = 1
update hcc_list set PREMATURE_MULTIPLES_X_SEVERITY4 = 1 where IHCC_SEVERITY4 = 1 and IHCC_PREMATURE_MULTIPLES = 1
update hcc_list set TERM_X_SEVERITY4                = 1 where IHCC_SEVERITY4 = 1 and IHCC_TERM                = 1
update hcc_list set AGE1_X_SEVERITY4                = 1 where IHCC_SEVERITY4 = 1 and IHCC_AGE1                = 1
update hcc_list set EXTREMELY_IMMATURE_X_SEVERITY3  = 1 where IHCC_SEVERITY3 = 1 and IHCC_EXTREMELY_IMMATURE  = 1
update hcc_list set IMMATURE_X_SEVERITY3            = 1 where IHCC_SEVERITY3 = 1 and IHCC_IMMATURE            = 1
update hcc_list set PREMATURE_MULTIPLES_X_SEVERITY3 = 1 where IHCC_SEVERITY3 = 1 and IHCC_PREMATURE_MULTIPLES = 1
update hcc_list set TERM_X_SEVERITY3                = 1 where IHCC_SEVERITY3 = 1 and IHCC_TERM                = 1
update hcc_list set AGE1_X_SEVERITY3                = 1 where IHCC_SEVERITY3 = 1 and IHCC_AGE1                = 1
update hcc_list set EXTREMELY_IMMATURE_X_SEVERITY2  = 1 where IHCC_SEVERITY2 = 1 and IHCC_EXTREMELY_IMMATURE  = 1
update hcc_list set IMMATURE_X_SEVERITY2            = 1 where IHCC_SEVERITY2 = 1 and IHCC_IMMATURE            = 1
update hcc_list set PREMATURE_MULTIPLES_X_SEVERITY2 = 1 where IHCC_SEVERITY2 = 1 and IHCC_PREMATURE_MULTIPLES = 1
update hcc_list set TERM_X_SEVERITY2                = 1 where IHCC_SEVERITY2 = 1 and IHCC_TERM                = 1
update hcc_list set AGE1_X_SEVERITY2                = 1 where IHCC_SEVERITY2 = 1 and IHCC_AGE1                = 1
update hcc_list set EXTREMELY_IMMATURE_X_SEVERITY1  = 1 where IHCC_SEVERITY1 = 1 and IHCC_EXTREMELY_IMMATURE  = 1
update hcc_list set IMMATURE_X_SEVERITY1            = 1 where IHCC_SEVERITY1 = 1 and IHCC_IMMATURE            = 1
update hcc_list set PREMATURE_MULTIPLES_X_SEVERITY1 = 1 where IHCC_SEVERITY1 = 1 and IHCC_PREMATURE_MULTIPLES = 1
update hcc_list set TERM_X_SEVERITY1                = 1 where IHCC_SEVERITY1 = 1 and IHCC_TERM                = 1
update hcc_list set AGE1_X_SEVERITY1                = 1   where IHCC_SEVERITY1 = 1 and IHCC_AGE1                = 1

update hcc_list set age0_male = 0, age1_male = 1 where age_last = 0 and ihcc_age1 = 1 and age0_male = 1
/***** Calculate HCC Counts, Apply 2023 Model severity factors and transplant flags ***/
/****
Payment HCC Count is not used in 2022 and prior models, 
but count is still populated in the hcc_list table as a potentially useful indicator ****/
if object_id('tempdb..#paymentHCCcount') is not null drop table #paymentHCCcount

--- unpivot and then count distinct by member ID; only Payment HCCs are pulled in
select mbr_id, metal, age_last, hcc, val, eff_date, exp_date into #paymentHCCcount
from (
SELECT [MBR_ID]
, metal, age_last, eff_date, exp_date
      ,[HHS_HCC001]
      ,[HHS_HCC002]
      ,[HHS_HCC003]
      ,[HHS_HCC004]
      ,[HHS_HCC006]
      ,[HHS_HCC008]
      ,[HHS_HCC009]
      ,[HHS_HCC010]
      ,[HHS_HCC011]
      ,[HHS_HCC012]
      ,[HHS_HCC013]
      ,[HHS_HCC018]
      ,[HHS_HCC019]
      ,[HHS_HCC020]
      ,[HHS_HCC021]
      ,[HHS_HCC022]
      ,[HHS_HCC023]
      ,[HHS_HCC026]
      ,[HHS_HCC027]
	  ,[HHS_HCC028]
      ,[HHS_HCC029]
      ,[HHS_HCC030]
      ,[HHS_HCC034]
      ,[HHS_HCC035_1]
      ,[HHS_HCC035_2]
      ,[HHS_HCC036]
      ,[HHS_HCC037_1]
      ,[HHS_HCC037_2]
      ,[HHS_HCC041]
      ,[HHS_HCC042]
      ,[HHS_HCC045]
      ,[HHS_HCC046]
      ,[HHS_HCC047]
      ,[HHS_HCC048]
      ,[HHS_HCC054]
      ,[HHS_HCC055]
      ,[HHS_HCC056]
      ,[HHS_HCC057]
      ,[HHS_HCC061]
      ,[HHS_HCC062]
      ,[HHS_HCC063]
      ,[HHS_HCC066]
      ,[HHS_HCC067]
      ,[HHS_HCC068]
      ,[HHS_HCC069]
      ,[HHS_HCC070]
      ,[HHS_HCC071]
      ,[HHS_HCC073]
      ,[HHS_HCC074]
      ,[HHS_HCC075]
      ,[HHS_HCC081]
      ,[HHS_HCC082]
      ,[HHS_HCC083]
      ,[HHS_HCC084]
      ,[HHS_HCC087_1]
      ,[HHS_HCC087_2]
      ,[HHS_HCC088]
      ,[HHS_HCC090]
      ,[HHS_HCC094]
      ,[HHS_HCC096]
      ,[HHS_HCC097]
      ,[HHS_HCC102]
      ,[HHS_HCC103]
      ,[HHS_HCC106]
      ,[HHS_HCC107]
      ,[HHS_HCC108]
      ,[HHS_HCC109]
      ,[HHS_HCC110]
      ,[HHS_HCC111]
      ,[HHS_HCC112]
      ,[HHS_HCC113]
      ,[HHS_HCC114]
      ,[HHS_HCC115]
      ,[HHS_HCC117]
      ,[HHS_HCC118]
      ,[HHS_HCC119]
      ,[HHS_HCC120]
      ,[HHS_HCC121]
      ,[HHS_HCC122]
      ,[HHS_HCC123]
      ,[HHS_HCC125]
      ,[HHS_HCC126]
      ,[HHS_HCC127]
      ,[HHS_HCC128]
      ,[HHS_HCC129]
      ,[HHS_HCC130]
      ,[HHS_HCC131]
      ,[HHS_HCC132]
      ,[HHS_HCC135]
      ,[HHS_HCC137]
      ,[HHS_HCC138]
      ,[HHS_HCC139]
      ,[HHS_HCC142]
      ,[HHS_HCC145]
      ,[HHS_HCC146]
      ,[HHS_HCC149]
      ,[HHS_HCC150]
      ,[HHS_HCC151]
      ,[HHS_HCC153]
      ,[HHS_HCC154]
      ,[HHS_HCC156]
      ,[HHS_HCC158]
      ,[HHS_HCC159]
      ,[HHS_HCC160]
      ,[HHS_HCC161_1]
      ,[HHS_HCC161_2]
      ,[HHS_HCC162]
      ,[HHS_HCC163]
      ,[HHS_HCC174]
      ,[HHS_HCC183]
      ,[HHS_HCC184]
      ,[HHS_HCC187]
      ,[HHS_HCC188]
      ,[HHS_HCC203]
      ,[HHS_HCC204]
      ,[HHS_HCC205]
      ,[HHS_HCC207]
      ,[HHS_HCC208]
      ,[HHS_HCC209]
      ,[HHS_HCC210]
      ,[HHS_HCC211]
      ,[HHS_HCC212]
      ,[HHS_HCC217]
      ,[HHS_HCC218]
      ,[HHS_HCC219]
      ,[HHS_HCC223]
      ,[HHS_HCC226]
      ,[HHS_HCC228]
      ,[HHS_HCC234]
      ,[HHS_HCC242]
      ,[HHS_HCC243]
      ,[HHS_HCC244]
      ,[HHS_HCC245]
      ,[HHS_HCC246]
      ,[HHS_HCC247]
      ,[HHS_HCC248]
      ,[HHS_HCC249]
      ,[HHS_HCC251]
      ,[HHS_HCC253]
      ,[HHS_HCC254]
      ,[G01]
      ,[G02B]
      ,[G02D]
      ,[G03]
      ,[G04]
      ,[G06A]
      ,[G07A]
      ,[G08]
      ,[G09A]
      ,[G09C]
      ,[G10]
      ,[G11]
      ,[G12]
      ,[G13]
      ,[G14]
      ,[G21]
      ,[G22]
      ,[G23]
      ,[G15A]
      ,[G16]
      ,[G17A]
      ,[G18A]
      ,[G19B]
	  ,[g24]
  FROM [dbo].[hcc_list]
) hc unpivot
(val for hcc in (
      [HHS_HCC001]
      ,[HHS_HCC002]
      ,[HHS_HCC003]
      ,[HHS_HCC004]
      ,[HHS_HCC006]
      ,[HHS_HCC008]
      ,[HHS_HCC009]
      ,[HHS_HCC010]
      ,[HHS_HCC011]
      ,[HHS_HCC012]
      ,[HHS_HCC013]
      ,[HHS_HCC018]
      ,[HHS_HCC019]
      ,[HHS_HCC020]
      ,[HHS_HCC021]
      ,[HHS_HCC022]
      ,[HHS_HCC023]
      ,[HHS_HCC026]
      ,[HHS_HCC027]
	  ,[HHS_HCC028]
      ,[HHS_HCC029]
      ,[HHS_HCC030]
      ,[HHS_HCC034]
      ,[HHS_HCC035_1]
      ,[HHS_HCC035_2]
      ,[HHS_HCC036]
      ,[HHS_HCC037_1]
      ,[HHS_HCC037_2]
      ,[HHS_HCC041]
      ,[HHS_HCC042]
      ,[HHS_HCC045]
      ,[HHS_HCC046]
      ,[HHS_HCC047]
      ,[HHS_HCC048]
      ,[HHS_HCC054]
      ,[HHS_HCC055]
      ,[HHS_HCC056]
      ,[HHS_HCC057]
      ,[HHS_HCC061]
      ,[HHS_HCC062]
      ,[HHS_HCC063]
      ,[HHS_HCC066]
      ,[HHS_HCC067]
      ,[HHS_HCC068]
      ,[HHS_HCC069]
      ,[HHS_HCC070]
      ,[HHS_HCC071]
      ,[HHS_HCC073]
      ,[HHS_HCC074]
      ,[HHS_HCC075]
      ,[HHS_HCC081]
      ,[HHS_HCC082]
      ,[HHS_HCC083]
      ,[HHS_HCC084]
      ,[HHS_HCC087_1]
      ,[HHS_HCC087_2]
      ,[HHS_HCC088]
      ,[HHS_HCC090]
      ,[HHS_HCC094]
      ,[HHS_HCC096]
      ,[HHS_HCC097]
      ,[HHS_HCC102]
      ,[HHS_HCC103]
      ,[HHS_HCC106]
      ,[HHS_HCC107]
      ,[HHS_HCC108]
      ,[HHS_HCC109]
      ,[HHS_HCC110]
      ,[HHS_HCC111]
      ,[HHS_HCC112]
      ,[HHS_HCC113]
      ,[HHS_HCC114]
      ,[HHS_HCC115]
      ,[HHS_HCC117]
      ,[HHS_HCC118]
      ,[HHS_HCC119]
      ,[HHS_HCC120]
      ,[HHS_HCC121]
      ,[HHS_HCC122]
      ,[HHS_HCC123]
      ,[HHS_HCC125]
      ,[HHS_HCC126]
      ,[HHS_HCC127]
      ,[HHS_HCC128]
      ,[HHS_HCC129]
      ,[HHS_HCC130]
      ,[HHS_HCC131]
      ,[HHS_HCC132]
      ,[HHS_HCC135]
      ,[HHS_HCC137]
      ,[HHS_HCC138]
      ,[HHS_HCC139]
      ,[HHS_HCC142]
      ,[HHS_HCC145]
      ,[HHS_HCC146]
      ,[HHS_HCC149]
      ,[HHS_HCC150]
      ,[HHS_HCC151]
      ,[HHS_HCC153]
      ,[HHS_HCC154]
      ,[HHS_HCC156]
      ,[HHS_HCC158]
      ,[HHS_HCC159]
      ,[HHS_HCC160]
      ,[HHS_HCC161_1]
      ,[HHS_HCC161_2]
      ,[HHS_HCC162]
      ,[HHS_HCC163]
      ,[HHS_HCC174]
      ,[HHS_HCC183]
      ,[HHS_HCC184]
      ,[HHS_HCC187]
      ,[HHS_HCC188]
      ,[HHS_HCC203]
      ,[HHS_HCC204]
      ,[HHS_HCC205]
      ,[HHS_HCC207]
      ,[HHS_HCC208]
      ,[HHS_HCC209]
      ,[HHS_HCC210]
      ,[HHS_HCC211]
      ,[HHS_HCC212]
      ,[HHS_HCC217]
      ,[HHS_HCC218]
      ,[HHS_HCC219]
      ,[HHS_HCC223]
      ,[HHS_HCC226]
      ,[HHS_HCC228]
      ,[HHS_HCC234]
      ,[HHS_HCC242]
      ,[HHS_HCC243]
      ,[HHS_HCC244]
      ,[HHS_HCC245]
      ,[HHS_HCC246]
      ,[HHS_HCC247]
      ,[HHS_HCC248]
      ,[HHS_HCC249]
      ,[HHS_HCC251]
      ,[HHS_HCC253]
      ,[HHS_HCC254]
      ,[G01]
      ,[G02B]
      ,[G02D]
      ,[G03]
      ,[G04]
      ,[G06A]
      ,[G07A]
      ,[G08]
      ,[G09A]
      ,[G09C]
      ,[G10]
      ,[G11]
      ,[G12]
      ,[G13]
      ,[G14]
      ,[G21]
      ,[G22]
      ,[G23]
      ,[G15A]
      ,[G16]
      ,[G17A]
      ,[G18A]
      ,[G19B]
	  ,[G24]
      ) ) as unpvt
	  CREATE NONCLUSTERED INDEX hcc_count
ON [dbo].[#paymentHCCcount] ([val])
INCLUDE ([mbr_id],[hcc])
	  IF OBJECT_ID('TEMPDB..#hCC_COUNT') IS NOT NULL DROP TABLE #hCC_COUNT

select mbr_id, count(distinct hcc) pmt_hcc_count INTO #hCC_COUNT from #paymenthcccount
where val = 1
group by mbr_id



update hc set hcc_count = #hCC_COUNT.pmt_hcc_count
from hcc_list hc  join #hCC_COUNT on hc.mbr_id = #hCC_COUNT.mbr_id
and age_last >= 2

/* This is the logic that updates the severity flag and severe / interaction HCC beginnig with the 2023 benefit year; skipped if benefit year is 2022 or earlier. 

Assumes payment HCC count logic is applied after hierarchies and groupers are applied. For example, if a member has HCC019 and HCC020, HCC is only counted once (under G01). 

Assumes that RXCs and RXC interaction factors are not counted in payment HCC count for both the severity / transplant flag and the EDF indicator


*/
if @benefityear >= 2023
BEGIN
UPDATE HCC_LIST set severe_v3 = 0

UPDATE HCC_LIST
SET severe_v3 = 1
where (HHS_HCC002 = 1 or hhs_hcc003 = 1 or hhs_hcc004 = 1 or hhs_hcc006 = 1 or hhs_hcc018 = 1
or hhs_hcc023 = 1 or hhs_hcc034 = 1 or hhs_hcc041 = 1 or hhs_hcc042 = 1 or hhs_hcc096 = 1 or hhs_hcc121 = 1 or hhs_hcc122 = 1 
	or hhs_hcc125 = 1 or hhs_hcc135 = 1 or hhs_hcc145 = 1 or 
	hhs_hcc156 = 1 or hhs_hcc158 = 1 or hhs_hcc163 =1  or hhs_hcc183 = 1 or 
	hhs_hcc218 =1 or hhs_hcc223 =1 or hhs_hcc251 =1 or G13 = 1 or G14 = 1 or g24=1)
and age_last >= 2

update hcc_list set transplant_flag = 1 where 
	(hhs_hcc018 = 1 or hhs_hcc034 =1 or hhs_hcc041 = 1
or hhs_hcc158 = 1 or hhs_hcc183 = 1 or hhs_hcc251 =1 or g14 = 1 or g24 = 1)
and age_last >= 2
--- count payment HCCs ---


update hcc_list
set ed_1 = 1 where
enr_dur between  1 and 31 and hcc_count >= 1
update hcc_list
set ed_2 = 1 where enr_dur between 32 and 62
and hcc_count >= 1
update hcc_list
set ed_3 = 1 where enr_dur between 63 and 92
and hcc_count >= 1
update hcc_list
set ed_4 = 1 where enr_dur between 93 and 123
and hcc_count >= 1
update hcc_list
set ed_5 = 1
where enr_dur between 124 and 153 and hcc_count >= 1
update hcc_list
set ed_6 = 1
where enr_dur between 154 and 184 and hcc_count >= 1
DROP TABLE #hCC_COUNT
DROP TABLE #paymentHCCcount

update hcc_list
set [SEVERE_1_HCC] = 1 where severe_v3 = 1 and hcc_count = 1
and age_last >= 2

update hcc_list
set [SEVERE_1_HCC] = 1 where severe_v3 = 1 and hcc_count = 1
and age_last >= 2

update hcc_list
set [SEVERE_2_HCC] = 1 where severe_v3 = 1 and hcc_count = 2
  and age_last >= 2

  update hcc_list
set [SEVERE_3_HCC] = 1 where severe_v3 = 1 and hcc_count = 3
and age_last >= 2

  update hcc_list
set [SEVERE_4_HCC] = 1 where severe_v3 = 1 and hcc_count = 4
     and age_last >= 2

	   update hcc_list
set [SEVERE_5_HCC] = 1 where severe_v3 = 1 and hcc_count = 5
and age_last >= 2

  update hcc_list
set [SEVERE_6_HCC] = 1 where severe_v3 = 1 and hcc_count = 6
and age_last >= 2

  update hcc_list
set [SEVERE_7_HCC] = 1 where severe_v3 = 1 and hcc_count = 7
and age_last >= 2

  update hcc_list
set [SEVERE_8_HCC] = 1 where severe_v3 = 1 and hcc_count = 8
and age_last >= 2

  update hcc_list
set [SEVERE_9_HCC] = 1 where severe_v3 = 1 and hcc_count = 9
and age_last >= 2

  update hcc_list
set [SEVERE_10_HCC] = 1 where severe_v3 = 1 and hcc_count >= 10
and age_last >= 2

  update hcc_list
set [TRANSPLANT_4_HCC] = 1 where transplant_flag = 1 and hcc_count = 4
and age_last >= 2

  update hcc_list
set [TRANSPLANT_5_HCC] = 1 where transplant_flag = 1 and hcc_count = 5
and age_last >= 2

  update hcc_list
set [TRANSPLANT_6_HCC] = 1 where transplant_flag = 1 and hcc_count = 6
and age_last >= 2

  update hcc_list
set [TRANSPLANT_7_HCC] = 1 where transplant_flag = 1 and hcc_count = 7
and age_last >= 2

  update hcc_list
set [TRANSPLANT_8_HCC] = 1 where transplant_flag = 1 and hcc_count >= 8
and age_last >= 2

END

/***** Unpivot HCC table to create a temp table with each member and all payment HCCs and other variables that affect risk scores. Since every member should have at least a demographic risk score variable, each member should appear at least once in the unpivot table, join to model factors, produce risk scores *****/

if object_id('tempdb..#hcc_unpivot') is not null drop table #hcc_unpivot

select mbr_id, metal, age_last, hcc, val, eff_date, exp_date into #hcc_unpivot
from (

SELECT [MBR_ID]
, metal, age_last, eff_date, exp_date,
[AGE0_MALE]
      ,[AGE1_MALE]
      ,[AGE0_FEMALE]
      ,[AGE1_FEMALE]
      ,[MAGE_LAST_2_4]
      ,[MAGE_LAST_5_9]
      ,[MAGE_LAST_10_14]
      ,[MAGE_LAST_15_20]
      ,[MAGE_LAST_21_24]
      ,[MAGE_LAST_25_29]
      ,[MAGE_LAST_30_34]
      ,[MAGE_LAST_35_39]
      ,[MAGE_LAST_40_44]
      ,[MAGE_LAST_45_49]
      ,[MAGE_LAST_50_54]
      ,[MAGE_LAST_55_59]
      ,[MAGE_LAST_60_GT]
      ,[FAGE_LAST_2_4]
      ,[FAGE_LAST_5_9]
      ,[FAGE_LAST_10_14]
      ,[FAGE_LAST_15_20]
      ,[FAGE_LAST_21_24]
      ,[FAGE_LAST_25_29]
      ,[FAGE_LAST_30_34]
      ,[FAGE_LAST_35_39]
      ,[FAGE_LAST_40_44]
      ,[FAGE_LAST_45_49]
      ,[FAGE_LAST_50_54]
      ,[FAGE_LAST_55_59]
      ,[FAGE_LAST_60_GT]
      ,[HHS_HCC001]
      ,[HHS_HCC002]
      ,[HHS_HCC003]
      ,[HHS_HCC004]
      ,[HHS_HCC006]
      ,[HHS_HCC008]
      ,[HHS_HCC009]
      ,[HHS_HCC010]
      ,[HHS_HCC011]
      ,[HHS_HCC012]
      ,[HHS_HCC013]
      ,[HHS_HCC018]
      ,[HHS_HCC019]
      ,[HHS_HCC020]
      ,[HHS_HCC021]
      ,[HHS_HCC022]
      ,[HHS_HCC023]
      ,[HHS_HCC026]
      ,[HHS_HCC027]
	  ,[HHS_HCC028]
      ,[HHS_HCC029]
      ,[HHS_HCC030]
      ,[HHS_HCC034]
      ,[HHS_HCC035_1]
      ,[HHS_HCC035_2]
      ,[HHS_HCC036]
      ,[HHS_HCC037_1]
      ,[HHS_HCC037_2]
      ,[HHS_HCC041]
      ,[HHS_HCC042]
      ,[HHS_HCC045]
      ,[HHS_HCC046]
      ,[HHS_HCC047]
      ,[HHS_HCC048]
      ,[HHS_HCC054]
      ,[HHS_HCC055]
      ,[HHS_HCC056]
      ,[HHS_HCC057]
      ,[HHS_HCC061]
      ,[HHS_HCC062]
      ,[HHS_HCC063]
      ,[HHS_HCC066]
      ,[HHS_HCC067]
      ,[HHS_HCC068]
      ,[HHS_HCC069]
      ,[HHS_HCC070]
      ,[HHS_HCC071]
      ,[HHS_HCC073]
      ,[HHS_HCC074]
      ,[HHS_HCC075]
      ,[HHS_HCC081]
      ,[HHS_HCC082]
      ,[HHS_HCC083]
      ,[HHS_HCC084]
      ,[HHS_HCC087_1]
      ,[HHS_HCC087_2]
      ,[HHS_HCC088]
      ,[HHS_HCC090]
      ,[HHS_HCC094]
      ,[HHS_HCC096]
      ,[HHS_HCC097]
      ,[HHS_HCC102]
      ,[HHS_HCC103]
      ,[HHS_HCC106]
      ,[HHS_HCC107]
      ,[HHS_HCC108]
      ,[HHS_HCC109]
      ,[HHS_HCC110]
      ,[HHS_HCC111]
      ,[HHS_HCC112]
      ,[HHS_HCC113]
      ,[HHS_HCC114]
      ,[HHS_HCC115]
      ,[HHS_HCC117]
      ,[HHS_HCC118]
      ,[HHS_HCC119]
      ,[HHS_HCC120]
      ,[HHS_HCC121]
      ,[HHS_HCC122]
      ,[HHS_HCC123]
      ,[HHS_HCC125]
      ,[HHS_HCC126]
      ,[HHS_HCC127]
      ,[HHS_HCC128]
      ,[HHS_HCC129]
      ,[HHS_HCC130]
      ,[HHS_HCC131]
      ,[HHS_HCC132]
      ,[HHS_HCC135]
      ,[HHS_HCC137]
      ,[HHS_HCC138]
      ,[HHS_HCC139]
      ,[HHS_HCC142]
      ,[HHS_HCC145]
      ,[HHS_HCC146]
      ,[HHS_HCC149]
      ,[HHS_HCC150]
      ,[HHS_HCC151]
      ,[HHS_HCC153]
      ,[HHS_HCC154]
      ,[HHS_HCC156]
      ,[HHS_HCC158]
      ,[HHS_HCC159]
      ,[HHS_HCC160]
      ,[HHS_HCC161_1]
      ,[HHS_HCC161_2]
      ,[HHS_HCC162]
      ,[HHS_HCC163]
      ,[HHS_HCC174]
      ,[HHS_HCC183]
      ,[HHS_HCC184]
      ,[HHS_HCC187]
      ,[HHS_HCC188]
      ,[HHS_HCC203]
      ,[HHS_HCC204]
      ,[HHS_HCC205]
      ,[HHS_HCC207]
      ,[HHS_HCC208]
      ,[HHS_HCC209]
      ,[HHS_HCC210]
      ,[HHS_HCC211]
      ,[HHS_HCC212]
      ,[HHS_HCC217]
      ,[HHS_HCC218]
      ,[HHS_HCC219]
      ,[HHS_HCC223]
      ,[HHS_HCC226]
      ,[HHS_HCC228]
      ,[HHS_HCC234]
      ,[HHS_HCC242]
      ,[HHS_HCC243]
      ,[HHS_HCC244]
      ,[HHS_HCC245]
      ,[HHS_HCC246]
      ,[HHS_HCC247]
      ,[HHS_HCC248]
      ,[HHS_HCC249]
      ,[HHS_HCC251]
      ,[HHS_HCC253]
      ,[HHS_HCC254]
      ,[G01]
      ,[G02B]
      ,[G02D]
      ,[G03]
      ,[G04]
      ,[G06A]
      ,[G07A]
      ,[G08]
      ,[G09A]
      ,[G09C]
      ,[G10]
      ,[G11]
      ,[G12]
      ,[G13]
      ,[G14]
      ,[G21]
      ,[G22]
      ,[G23]
      ,[G15A]
      ,[G16]
      ,[G17A]
      ,[G18A]
      ,[G19B]
	  ,[g24]
	  ,[acf_01]
      ,[INT_GROUP_H]
	  ,[SEVERE_1_HCC]
      ,[SEVERE_2_HCC]
      ,[SEVERE_3_HCC]
      ,[SEVERE_4_HCC]
      ,[SEVERE_5_HCC]
      ,[SEVERE_6_HCC]
      ,[SEVERE_7_HCC]
      ,[SEVERE_8_HCC]
      ,[SEVERE_9_HCC]
      ,[SEVERE_10_HCC]
      ,[TRANSPLANT_4_HCC]
      ,[TRANSPLANT_5_HCC]
      ,[TRANSPLANT_6_HCC]
      ,[TRANSPLANT_7_HCC]
      ,[TRANSPLANT_8_HCC]
      ,[ED_1]
      ,[ED_2]
      ,[ED_3]
      ,[ED_4]
      ,[ED_5]
      ,[ED_6]
      ,[ED_7]
      ,[ED_8]
      ,[ED_9]
      ,[ED_10]
      ,[ED_11]
      ,[RXC_01]
      ,[RXC_02]
      ,[RXC_03]
      ,[RXC_04]
      ,[RXC_05]
      ,[RXC_06]
      ,[RXC_07]
      ,[RXC_08]
      ,[RXC_09]
      ,[RXC_10]
      ,[RXC_01_x_HCC001]
      ,[RXC_02_x_HCC037_1_036_035_2_035_1_034]
      ,[RXC_03_x_HCC142]
      ,[RXC_04_x_HCC184_183_187_188]
      ,[RXC_05_x_HCC048_041]
      ,[RXC_06_x_HCC018_019_020_021]
      ,[RXC_07_x_HCC018_019_020_021]
      ,[RXC_08_x_HCC118]
      ,[RXC_09_x_HCC056_057_and_048_041]
      ,[RXC_09_x_HCC056]
      ,[RXC_09_x_HCC057]
      ,[RXC_09_x_HCC048_041]
      ,[RXC_10_x_HCC159_158]
      ,[EXTREMELY_IMMATURE_X_SEVERITY5]
      ,[EXTREMELY_IMMATURE_X_SEVERITY4]
      ,[EXTREMELY_IMMATURE_X_SEVERITY3]
      ,[EXTREMELY_IMMATURE_X_SEVERITY2]
      ,[EXTREMELY_IMMATURE_X_SEVERITY1]
      ,[IMMATURE_X_SEVERITY5]
      ,[IMMATURE_X_SEVERITY4]
      ,[IMMATURE_X_SEVERITY3]
      ,[IMMATURE_X_SEVERITY2]
      ,[IMMATURE_X_SEVERITY1]
      ,[PREMATURE_MULTIPLES_X_SEVERITY5]
      ,[PREMATURE_MULTIPLES_X_SEVERITY4]
      ,[PREMATURE_MULTIPLES_X_SEVERITY3]
      ,[PREMATURE_MULTIPLES_X_SEVERITY2]
      ,[PREMATURE_MULTIPLES_X_SEVERITY1]
      ,[TERM_X_SEVERITY5]
      ,[TERM_X_SEVERITY4]
      ,[TERM_X_SEVERITY3]
      ,[TERM_X_SEVERITY2]
      ,[TERM_X_SEVERITY1]
      ,[AGE1_X_SEVERITY5]
      ,[AGE1_X_SEVERITY4]
      ,[AGE1_X_SEVERITY3]
      ,[AGE1_X_SEVERITY2]
      ,[AGE1_X_SEVERITY1]
  FROM [dbo].[hcc_list]
) hc unpivot
(val for hcc in ([AGE0_MALE]
      ,[AGE1_MALE]
      ,[AGE0_FEMALE]
      ,[AGE1_FEMALE],
[MAGE_LAST_2_4]
      ,[MAGE_LAST_5_9]
      ,[MAGE_LAST_10_14]
      ,[MAGE_LAST_15_20]
      ,[MAGE_LAST_21_24]
      ,[MAGE_LAST_25_29]
      ,[MAGE_LAST_30_34]
      ,[MAGE_LAST_35_39]
      ,[MAGE_LAST_40_44]
      ,[MAGE_LAST_45_49]
      ,[MAGE_LAST_50_54]
      ,[MAGE_LAST_55_59]
      ,[MAGE_LAST_60_GT]
      ,[FAGE_LAST_2_4]
      ,[FAGE_LAST_5_9]
      ,[FAGE_LAST_10_14]
      ,[FAGE_LAST_15_20]
      ,[FAGE_LAST_21_24]
      ,[FAGE_LAST_25_29]
      ,[FAGE_LAST_30_34]
      ,[FAGE_LAST_35_39]
      ,[FAGE_LAST_40_44]
      ,[FAGE_LAST_45_49]
      ,[FAGE_LAST_50_54]
      ,[FAGE_LAST_55_59]
      ,[FAGE_LAST_60_GT]
      ,[HHS_HCC001]
      ,[HHS_HCC002]
      ,[HHS_HCC003]
      ,[HHS_HCC004]
      ,[HHS_HCC006]
      ,[HHS_HCC008]
      ,[HHS_HCC009]
      ,[HHS_HCC010]
      ,[HHS_HCC011]
      ,[HHS_HCC012]
      ,[HHS_HCC013]
      ,[HHS_HCC018]
      ,[HHS_HCC019]
      ,[HHS_HCC020]
      ,[HHS_HCC021]
      ,[HHS_HCC022]
      ,[HHS_HCC023]
      ,[HHS_HCC026]
      ,[HHS_HCC027]
	  ,[HHS_HCC028]
      ,[HHS_HCC029]
      ,[HHS_HCC030]
      ,[HHS_HCC034]
      ,[HHS_HCC035_1]
      ,[HHS_HCC035_2]
      ,[HHS_HCC036]
      ,[HHS_HCC037_1]
      ,[HHS_HCC037_2]
      ,[HHS_HCC041]
      ,[HHS_HCC042]
      ,[HHS_HCC045]
      ,[HHS_HCC046]
      ,[HHS_HCC047]
      ,[HHS_HCC048]
      ,[HHS_HCC054]
      ,[HHS_HCC055]
      ,[HHS_HCC056]
      ,[HHS_HCC057]
      ,[HHS_HCC061]
      ,[HHS_HCC062]
      ,[HHS_HCC063]
      ,[HHS_HCC066]
      ,[HHS_HCC067]
      ,[HHS_HCC068]
      ,[HHS_HCC069]
      ,[HHS_HCC070]
      ,[HHS_HCC071]
      ,[HHS_HCC073]
      ,[HHS_HCC074]
      ,[HHS_HCC075]
      ,[HHS_HCC081]
      ,[HHS_HCC082]
      ,[HHS_HCC083]
      ,[HHS_HCC084]
      ,[HHS_HCC087_1]
      ,[HHS_HCC087_2]
      ,[HHS_HCC088]
      ,[HHS_HCC090]
      ,[HHS_HCC094]
      ,[HHS_HCC096]
      ,[HHS_HCC097]
      ,[HHS_HCC102]
      ,[HHS_HCC103]
      ,[HHS_HCC106]
      ,[HHS_HCC107]
      ,[HHS_HCC108]
      ,[HHS_HCC109]
      ,[HHS_HCC110]
      ,[HHS_HCC111]
      ,[HHS_HCC112]
      ,[HHS_HCC113]
      ,[HHS_HCC114]
      ,[HHS_HCC115]
      ,[HHS_HCC117]
      ,[HHS_HCC118]
      ,[HHS_HCC119]
      ,[HHS_HCC120]
      ,[HHS_HCC121]
      ,[HHS_HCC122]
      ,[HHS_HCC123]
      ,[HHS_HCC125]
      ,[HHS_HCC126]
      ,[HHS_HCC127]
      ,[HHS_HCC128]
      ,[HHS_HCC129]
      ,[HHS_HCC130]
      ,[HHS_HCC131]
      ,[HHS_HCC132]
      ,[HHS_HCC135]
      ,[HHS_HCC137]
      ,[HHS_HCC138]
      ,[HHS_HCC139]
      ,[HHS_HCC142]
      ,[HHS_HCC145]
      ,[HHS_HCC146]
      ,[HHS_HCC149]
      ,[HHS_HCC150]
      ,[HHS_HCC151]
      ,[HHS_HCC153]
      ,[HHS_HCC154]
      ,[HHS_HCC156]
      ,[HHS_HCC158]
      ,[HHS_HCC159]
      ,[HHS_HCC160]
      ,[HHS_HCC161_1]
      ,[HHS_HCC161_2]
      ,[HHS_HCC162]
      ,[HHS_HCC163]
      ,[HHS_HCC174]
      ,[HHS_HCC183]
      ,[HHS_HCC184]
      ,[HHS_HCC187]
      ,[HHS_HCC188]
      ,[HHS_HCC203]
      ,[HHS_HCC204]
      ,[HHS_HCC205]
      ,[HHS_HCC207]
      ,[HHS_HCC208]
      ,[HHS_HCC209]
      ,[HHS_HCC210]
      ,[HHS_HCC211]
      ,[HHS_HCC212]
      ,[HHS_HCC217]
      ,[HHS_HCC218]
      ,[HHS_HCC219]
      ,[HHS_HCC223]
      ,[HHS_HCC226]
      ,[HHS_HCC228]
      ,[HHS_HCC234]
      ,[HHS_HCC242]
      ,[HHS_HCC243]
      ,[HHS_HCC244]
      ,[HHS_HCC245]
      ,[HHS_HCC246]
      ,[HHS_HCC247]
      ,[HHS_HCC248]
      ,[HHS_HCC249]
      ,[HHS_HCC251]
      ,[HHS_HCC253]
      ,[HHS_HCC254]
      ,[G01]
      ,[G02B]
      ,[G02D]
      ,[G03]
      ,[G04]
      ,[G06A]
      ,[G07A]
      ,[G08]
      ,[G09A]
      ,[G09C]
      ,[G10]
      ,[G11]
      ,[G12]
      ,[G13]
      ,[G14]
      ,[G21]
      ,[G22]
      ,[G23]
      ,[G15A]
      ,[G16]
      ,[G17A]
      ,[G18A]
      ,[G19B]
	  ,[g24]
	  ,[acf_01]
      ,[INT_GROUP_H]
	  ,[SEVERE_1_HCC]
      ,[SEVERE_2_HCC]
      ,[SEVERE_3_HCC]
      ,[SEVERE_4_HCC]
      ,[SEVERE_5_HCC]
      ,[SEVERE_6_HCC]
      ,[SEVERE_7_HCC]
      ,[SEVERE_8_HCC]
      ,[SEVERE_9_HCC]
      ,[SEVERE_10_HCC]
      ,[TRANSPLANT_4_HCC]
      ,[TRANSPLANT_5_HCC]
      ,[TRANSPLANT_6_HCC]
      ,[TRANSPLANT_7_HCC]
      ,[TRANSPLANT_8_HCC]
      ,[ED_1]
      ,[ED_2]
      ,[ED_3]
      ,[ED_4]
      ,[ED_5]
      ,[ED_6]
      ,[ED_7]
      ,[ED_8]
      ,[ED_9]
      ,[ED_10]
      ,[ED_11]
      ,[RXC_01]
      ,[RXC_02]
      ,[RXC_03]
      ,[RXC_04]
      ,[RXC_05]
      ,[RXC_06]
      ,[RXC_07]
      ,[RXC_08]
      ,[RXC_09]
      ,[RXC_10]
      ,[RXC_01_x_HCC001]
      ,[RXC_02_x_HCC037_1_036_035_2_035_1_034]
      ,[RXC_03_x_HCC142]
      ,[RXC_04_x_HCC184_183_187_188]
      ,[RXC_05_x_HCC048_041]
      ,[RXC_06_x_HCC018_019_020_021]
      ,[RXC_07_x_HCC018_019_020_021]
      ,[RXC_08_x_HCC118]
      ,[RXC_09_x_HCC056_057_and_048_041]
      ,[RXC_09_x_HCC056]
      ,[RXC_09_x_HCC057]
      ,[RXC_09_x_HCC048_041]
      ,[RXC_10_x_HCC159_158]
      ,[EXTREMELY_IMMATURE_X_SEVERITY5]
      ,[EXTREMELY_IMMATURE_X_SEVERITY4]
      ,[EXTREMELY_IMMATURE_X_SEVERITY3]
      ,[EXTREMELY_IMMATURE_X_SEVERITY2]
      ,[EXTREMELY_IMMATURE_X_SEVERITY1]
      ,[IMMATURE_X_SEVERITY5]
      ,[IMMATURE_X_SEVERITY4]
      ,[IMMATURE_X_SEVERITY3]
      ,[IMMATURE_X_SEVERITY2]
      ,[IMMATURE_X_SEVERITY1]
      ,[PREMATURE_MULTIPLES_X_SEVERITY5]
      ,[PREMATURE_MULTIPLES_X_SEVERITY4]
      ,[PREMATURE_MULTIPLES_X_SEVERITY3]
      ,[PREMATURE_MULTIPLES_X_SEVERITY2]
      ,[PREMATURE_MULTIPLES_X_SEVERITY1]
      ,[TERM_X_SEVERITY5]
      ,[TERM_X_SEVERITY4]
      ,[TERM_X_SEVERITY3]
      ,[TERM_X_SEVERITY2]
      ,[TERM_X_SEVERITY1]
      ,[AGE1_X_SEVERITY5]
      ,[AGE1_X_SEVERITY4]
      ,[AGE1_X_SEVERITY3]
      ,[AGE1_X_SEVERITY2]
      ,[AGE1_X_SEVERITY1]
	  
	  ) ) as unpvt
	  where val = 1

	 if object_id('tempdb..#RiskscoreBYMemberPre_CSR') is not null drop table #RiskscoreBYMemberPre_CSR

/*** calculate risk score by multiplying the value columns by the risk score factors from the risk score factors table based on the member's metal level. Model year variable set at the beginning uses the version populated in the risk score table. When importing new risk score coefficients, need to update the model year variable to the name imported in the model year column
****/
	  --- adult model
	  select sum(case when metal = 'bronze' then val*bronze_level when metal = 'silver' then val*silver_level
	  when metal = 'gold' then val*gold_level when metal = 'platinum' 
	  then val*platinum_level when metal = 'catastrophic' then val*catastrophic_level else 0 end) 
	  risk_score,
	  sum(val*bronze_level) bronze_risk_score,
	  sum(val*silver_level) silver_risk_score,
	  sum(val*gold_level) gold_risk_score,
	  sum(val*platinum_level) platinum_risk_score,
	  sum(val*catastrophic_level) catastrophic_risk_score,
	  mbr_id, eff_date, exp_date into #RiskscoreBYMemberPre_CSR from #hcc_unpivot up 
	  join RiskScoreFactors rf
	  on up.hcc = rf.variable
	  where age_last >= '21'
	  and model = 'Adult'
	  and model_year = @model_year
	  group by mbr_id, eff_date, exp_date
	  union
	  --- child model
	  	  select sum(case when metal = 'bronze' then val*bronze_level when metal = 'silver' then val*silver_level
	  when metal = 'gold' then val*gold_level when metal = 'platinum' then val*platinum_level when metal = 'catastrophic' then val*catastrophic_level else 0 end), 
	  sum(val*bronze_level) bronze_risk_score,
	  sum(val*silver_level) silver_risk_score,
	  sum(val*gold_level) gold_risk_score,
	  sum(val*platinum_level) platinum_risk_score,
	  sum(val*catastrophic_level) catastrophic_risk_score,
	  mbr_id, eff_date, exp_date from #hcc_unpivot up join RiskScoreFactors rf
	  on up.hcc = rf.variable
	  where age_last between '2' and '20'
	  and model = 'Child'
	  and model_year = @model_year
	  group by mbr_id, eff_date, exp_date
	  --- infant model
	  union
	  	  select sum(case when metal = 'bronze' then val*bronze_level when metal = 'silver' then val*silver_level
	  when metal = 'gold' then val*gold_level when metal = 'platinum' then val*platinum_level when metal = 'catastrophic' then val*catastrophic_level else 0 end) risk_score
	  	  ,
	  sum(val*bronze_level) bronze_risk_score,
	  sum(val*silver_level) silver_risk_score,
	  sum(val*gold_level) gold_risk_score,
	  sum(val*platinum_level) platinum_risk_score,
	  sum(val*catastrophic_level) catastrophic_risk_score
	  , mbr_id, eff_date, exp_date  from #hcc_unpivot up join RiskScoreFactors rf
	  on up.hcc = rf.variable
	  where age_last between '0' and '1'
	  and model = 'Infant'
	  and model_year = @model_year
	  group by mbr_id, eff_date, exp_date
if object_id('tempdb..#riskscorepostCSR') is not null 
drop table #riskscorepostCSR
--- take the risk score, then apply the CSR multiplier factors ----
	  select hc.mbr_id, hios, metal, rs.EFF_DATE, rs.EXP_DATE, rs.risk_score rs_pre,
	  rs.risk_score *c.adj_factor rs_post_csr,
	  rs.bronze_risk_score, rs.silver_risk_score, rs.gold_risk_score, rs.platinum_risk_score, rs.catastrophic_risk_score
	  ,rs.silver_risk_score*css.adj_factor silver_87_94_risk_score
	  into #riskscorepostCSR
from #RiskscoreBYMemberPre_CSR rs join hcc_list hc
JOIN CSR_ADJ_FACTORS c on hc.csr = c.csr_code
and c.model_year = @benefityear
join csr_adj_factors css on css.model_year = @benefityear
and css.CSR_Code = '2'
on rs.mbr_id = hc.mbr_id
and rs.EFF_DATE = hc.EFF_DATE and rs.EXP_DATE = hc.EXP_DATE
order by mbr_id

--- update the hcc_list table ----
update hc
set risk_score = rs.rs_post_csr,
hc.bronze_risk_score = rs.bronze_risk_score,
hc.silver_risk_score = rs.silver_risk_score,
hc.gold_risk_score = rs.gold_risk_score,
hc.platinum_risk_score = rs.platinum_risk_score,
hc.catastrophic_risk_score = rs.catastrophic_risk_score,
hc.silver_87_94_risk_score = rs.silver_87_94_risk_score
from
hcc_list hc join #riskscorepostCSR rs on rs.mbr_id = hc.mbr_id
and rs.EFF_DATE = hc.EFF_DATE and rs.EXP_DATE = hc.EXP_DATE
if @droptemp = 1
begin
--- drop all the temp tables ----
if object_id('tempdb..#AcceptableClaims') is not null		  
drop table #AcceptableClaims	  
if object_id('tempdb..#hcc_unpivot') is not null	  
drop table #hcc_unpivot
if object_id('tempdb..#MemberDiagnosisMap') is not null	  
drop table #MemberDiagnosisMap
if object_id('tempdb..#MemberHCCMap') is not null	  
drop table #MemberHCCMap
if object_id('tempdb..#memberMapSvcDt') is not null	  
drop table #memberMapSvcDt
if object_id('tempdb..#RXC_Mapping') is not null	  
drop table #RXC_Mapping
if object_id('tempdb..#RiskscoreBYMemberPre_CSR') is not null 
drop table #RiskscoreBYMemberPre_CSR
if object_id('tempdb..#riskscorepostCSR') is not null 
drop table #riskscorepostCSR
end

if @output_table is not null
begin
if @output_table = 'hcc_list' goto EndCode
if object_id(@output_table) is not null
and @drop_existing = 0
begin
declare @errormessage nvarchar(4000) =
'The output table specified, '+@output_table+' already exists. 
Please drop this table or use another name. 
The script ran successfully other than this issue and the results have still been populated to the hcc_list table.';
throw 50005, @errormessage,1
end 
if object_id(@output_table) is null
exec('select * into '+@output_table+' from hcc_list')
if object_id(@output_table) is not null and @drop_existing = 1
begin
exec ('drop table '+@output_table+'')
exec('select * into '+@output_table+' from hcc_list')
end
end
----- End Model Code. Use the HCC_List table to query your risk scores -----
EndCode:
select left(hc.hios,14), hc.metal, market, ratingarea,
sum(risk_score*(datediff(d, hc.eff_date, hc.exp_date)/30.00))/sum(datediff(d, hc.eff_date,

hc.exp_date)/30.00), sum(datediff(d, hc.eff_date,

hc.exp_date)/30.00)
from hcc_list hc
group by grouping sets ((left(hc.hios,14), hc.metal, market, ratingarea),market)

