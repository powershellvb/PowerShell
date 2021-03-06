# Install-Module dbatools 


[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.BatchParser.dll') | out-null


Clear-Host
$instance = "srvsql2016"
$dbaDatabase = "_DBA"
$CleanupTime = 15 <# days #> * 24


$Server = Connect-DbaInstance -SqlInstance $instance
$Server | Select-Object DomainInstanceName,VersionMajor,DatabaseEngineEdition

#region SQL Server configuration
$TempDBLogPath = split-path (Get-DbaDBFile -SqlInstance $instance -Database TempDB | Where-Object {$_.ID -eq 2}).PhysicalName -Parent
$TempDBDataPath = split-path (Get-DbaDBFile -SqlInstance $instance -Database TempDB | Where-Object {$_.ID -eq 1}).PhysicalName -Parent

$TempDBDataFileSizeMB = 4 <# GB #> * 1024 
$TempDBDataFileCount = $(Get-DbaInstanceProperty -SqlInstance $instance  -InstanceProperty  Processors).value

Set-DbaTempDbConfig -SqlInstance $instance -DataPath $TempDBDataPath -LogPath $TempDBLogPath -DataFileSize $TempDBDataFileSizeMB -DataFileCount $TempDBDataFileCount

Set-DbaErrorLogConfig -SqlInstance $instance -LogCount 99
Set-DbaSpConfigure -SqlInstance $instance -name RemoteDacConnectionsEnabled -value 1
Set-DbaSpConfigure -SqlInstance $instance -name OptimizeAdhocWorkloads -value 1
Set-DbaSpConfigure -SqlInstance $instance -name CostThresholdForParallelism -value 25
Set-DbaSpConfigure -SqlInstance $instance -name DefaultBackupCompression -value 1

Set-DbaMaxMemory -SqlInstance $instance

Stop-DbaXESession -SqlInstance $instance -Session "system_health"

Invoke-DbaQuery -SqlInstance $instance -Database "master" -Query "
    ALTER EVENT SESSION [system_health] ON SERVER
    DROP TARGET package0.event_file;
    GO
    ALTER EVENT SESSION [system_health] ON SERVER
    ADD TARGET package0.event_file
        (SET FILENAME=N'system_health.xel',
            max_file_size=(25),
            max_rollover_files=(20)
        )
"
# Get-DbaXESessionTarget

Start-DbaXESession -SqlInstance $instance -Session "system_health"

if (!($(Get-DbaInstanceProperty -SqlInstance $instance -InstanceProperty  Edition).value -Match "Express")){
    Set-DbaAgentServer -SqlInstance $instance -MaximumHistoryRows 999999 -MaximumJobHistoryRows 999999 
}


# Create DBA database
# Create DBA database if needed
if (!(Get-DbaDatabase -SqlInstance $instance -Database $dbaDatabase )){
    New-DbaDatabase -SqlInstance $instance -Name $dbaDatabase
}
else {
    Write-Host "[$dbaDatabase] database already exists"
}


Install-DbaWhoIsActive -SqlInstance $instance -Database $dbaDatabase


# Set-DbaPowerPlan -ComputerName $ComputerName
# Test-DbaPowerPlan -ComputerName $ComputerName



#endregion

#region configuration model
Invoke-DbaQuery -SqlInstance $instance -Database "master" -Query "Alter database model modify file (name=modeldev, size=512MB, filegrowth=64MB);"
Invoke-DbaQuery -SqlInstance $instance -Database "master" -Query "Alter database model modify file (name=modellog, size=64MB, filegrowth=64MB);"
Invoke-DbaQuery -SqlInstance $instance -Database "master" -Query "Alter database model SET RECOVERY FULL;"
#endregion

#region configuration MSDB
Invoke-DbaQuery -SqlInstance $instance -Database "master" -Query "Alter database msdb modify file (name=MSDBData, size=512MB, filegrowth=64MB);"
Invoke-DbaQuery -SqlInstance $instance -Database "master" -Query "Alter database msdb modify file (name=MSDBLog, size=64MB,	 filegrowth=64MB);"
#endregion



#region Install Database maintenance objects
$defaultbackuplocation = (Get-DbaDefaultPath -SqlInstance $instance).Backup
Install-DbaMaintenanceSolution -SqlInstance $instance -Database $dbaDatabase -BackupLocation $defaultbackuplocation -CleanupTime $CleanupTime -InstallJobs -LogToTable -ReplaceExisting

$tSQL = "
	CREATE PROCEDURE dbo.sp_sp_start_job_wait
	(
		@job_name SYSNAME,
		@WaitTime DATETIME = '00:00:30', -- this is parameter for check frequency
		@JobCompletionStatus INT = null OUTPUT
	)
	AS
	BEGIN
		-- https://www.mssqltips.com/sqlservertip/2167/custom-spstartjob-to-delay-next-task-until-sql-agent-job-has-completed/

		SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
		SET NOCOUNT ON

		-- DECLARE @job_name sysname
		DECLARE @job_id UNIQUEIDENTIFIER
		DECLARE @job_owner sysname

		--Createing TEMP TABLE
		CREATE TABLE #xp_results (	job_id UNIQUEIDENTIFIER NOT NULL,
									last_run_date INT NOT NULL,
									last_run_time INT NOT NULL,
									next_run_date INT NOT NULL,
									next_run_time INT NOT NULL,
									next_run_schedule_id INT NOT NULL,
									requested_to_run INT NOT NULL, -- BOOL
									request_source INT NOT NULL,
									request_source_id sysname COLLATE database_default NULL,
									running INT NOT NULL, -- BOOL
									current_step INT NOT NULL,
									current_retry_attempt INT NOT NULL,
									job_state INT NOT NULL
								 )

		SELECT @job_id = job_id FROM msdb.dbo.sysjobs
		WHERE name = @job_name

		SELECT @job_owner = SUSER_SNAME()

		INSERT INTO #xp_results
		EXECUTE master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id 

		-- Start the job if the job is not running
		IF NOT EXISTS(SELECT TOP 1 * FROM #xp_results WHERE running = 1)
			EXEC msdb.dbo.sp_start_job @job_name = @job_name

		-- Give 5 sec for think time.
		WAITFOR DELAY '00:00:05'

		DELETE FROM #xp_results
		INSERT INTO #xp_results
		EXECUTE master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id 

		WHILE EXISTS(SELECT TOP 1 * FROM #xp_results WHERE running = 1)
		BEGIN

			WAITFOR DELAY @WaitTime

			-- Information 
			-- raiserror('JOB IS RUNNING', 0, 1 ) WITH NOWAIT 

			DELETE FROM #xp_results

			INSERT INTO #xp_results
			EXECUTE master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id 

		END

		SELECT TOP 1 @JobCompletionStatus = run_status 
		FROM msdb.dbo.sysjobhistory
		WHERE job_id = @job_id
		AND step_id = 0
		ORDER BY run_date DESC, run_time DESC

		IF @JobCompletionStatus <> 1
		BEGIN
			RAISERROR ('[ERROR]:%s job is either failed, cancelled or not in good state. Please check',16, 1, @job_name) WITH LOG
		END

		RETURN @JobCompletionStatus
	END
"
Invoke-DbaQuery -SqlInstance $instance -Database $dbaDatabase -Query $tSQL
#endregion

#region Creating jobs for instance housekeeping
    $job = new-object Microsoft.SqlServer.Management.Smo.Agent.Job($Server.JobServer, "DBA - HouseKeeping")
    $job.Category = "Database Maintenance"
    $job.Create()

    $job.ApplyToTargetServer("(local)")

    $jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "Cycle Errorlog")
    $jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
    $jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
    $jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
    $jobstep.Command="EXEC msdb.dbo.sp_cycle_errorlog"
    $jobstep.Create()
        
    $jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "CommandLog Cleanup")
    $jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
    $jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
    $jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
    $jobstep.Command="EXEC msdb.dbo.sp_start_job 'CommandLog Cleanup'"
    $jobstep.Create()

    $jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "Output File Cleanup")
    $jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
    $jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
    $jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
    $jobstep.Command="EXEC msdb.dbo.sp_start_job 'Output File Cleanup'"
    $jobstep.Create()
        

    $jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "sp_delete_backuphistory")
    $jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
    $jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
    $jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
    $jobstep.Command="EXEC msdb.dbo.sp_start_job 'sp_delete_backuphistory'"
    $jobstep.Create()

    $jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "sp_purge_jobhistory")
    $jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
    $jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
    $jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
    $jobstep.Command="EXEC msdb.dbo.sp_start_job 'sp_purge_jobhistory'"
    $jobstep.Create()

    $jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseMail - Database Mail cleanup")
    $jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
    $jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
    $jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
    $jobstep.Command="    DECLARE @DeleteBeforeDate DateTime = (Select DATEADD(d,-30, GETDATE()))
    EXEC msdb.dbo.sysmail_delete_mailitems_sp @sent_before = @DeleteBeforeDate
    EXEC msdb.dbo.sysmail_delete_log_sp @logged_before = @DeleteBeforeDate"
    $jobstep.Create()

    $jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseIntegrityCheck - SYSTEM_DATABASES")
    $jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
    $jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
    $jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
    $jobstep.Command="EXEC [$dbaDatabase].[dbo].sp_sp_start_job_wait @job_name='DatabaseIntegrityCheck - SYSTEM_DATABASES', @WaitTime = '00:01:00'"
    $jobstep.Create()

    $jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseBackup - SYSTEM_DATABASES - FULL")
    $jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithSuccess
    $jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
    $jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
    $jobstep.Command="EXEC [$dbaDatabase].[dbo].sp_sp_start_job_wait @job_name='DatabaseBackup - SYSTEM_DATABASES - FULL', @WaitTime = '00:01:00'"
    $jobstep.Create()
        
    $jobschedule = new-object Microsoft.SqlServer.Management.Smo.Agent.JobSchedule($job, $job.name)
    $jobschedule.FrequencyTypes = [Microsoft.SqlServer.Management.Smo.Agent.FrequencyTypes]::Daily
    $jobschedule.FrequencySubDayTypes = [Microsoft.SqlServer.Management.Smo.Agent.FrequencySubDayTypes]::Once
    $jobschedule.FrequencySubDayinterval = 0
    $jobschedule.FrequencyInterval = 1
    $ts1 = new-object System.TimeSpan(0, 0, 1)
    $ts2 = new-object System.TimeSpan(23, 59, 59)
    $jobschedule.ActiveStartTimeOfDay = $ts1
    $jobschedule.ActiveEndTimeOfDay = $ts2

    $jobschedule.ActiveStartDate = (Get-Date).Date #new-object System.DateTime(2003, 1, 1)
    $jobschedule.Create()
#endregion

#region Database backup
# Calling OH not scheduled jobs
$job = new-object Microsoft.SqlServer.Management.Smo.Agent.Job($Server.JobServer, "DBA - USER_DATABASES - FULL")
$job.Category = "Database Maintenance"
$job.Create()

$job.ApplyToTargetServer("(local)")


$jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseIntegrityCheck - USER_DATABASES")
$jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
$jobstep.Command="EXEC [$dbaDatabase].[dbo].sp_sp_start_job_wait @job_name='DatabaseIntegrityCheck - USER_DATABASES', @WaitTime = '00:01:00'"
$jobstep.Create()

$jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "IndexOptimize - USER_DATABASES")
$jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
$jobstep.Command="EXEC [$dbaDatabase].[dbo].sp_sp_start_job_wait @job_name='IndexOptimize - USER_DATABASES', @WaitTime = '00:01:00'"
$jobstep.Create()

$jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseBackup - USER_DATABASES - FULL")
$jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithSuccess
$jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
$jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
$jobstep.Command="EXEC [$dbaDatabase].[dbo].sp_sp_start_job_wait @job_name='DatabaseBackup - USER_DATABASES - FULL', @WaitTime = '00:01:00'"
$jobstep.Create()
    
$jobschedule = new-object Microsoft.SqlServer.Management.Smo.Agent.JobSchedule($job, $job.name)
$jobschedule.FrequencyTypes = [Microsoft.SqlServer.Management.Smo.Agent.FrequencyTypes]::Weekly
$jobschedule.FrequencySubDayTypes = [Microsoft.SqlServer.Management.Smo.Agent.FrequencySubDayTypes]::Once
$jobschedule.FrequencyInterval = [Microsoft.SqlServer.Management.Smo.Agent.WeekDays]::Sunday
$jobschedule.FrequencyRecurrenceFactor = 1
$jobschedule.FrequencySubDayinterval = 0
$ts1 = new-object System.TimeSpan(1, 0, 0)
$ts2 = new-object System.TimeSpan(23, 59, 59)
$jobschedule.ActiveStartTimeOfDay = $ts1
$jobschedule.ActiveEndTimeOfDay = $ts2
$jobschedule.ActiveStartDate = (Get-Date).Date 
$jobschedule.Create()
#endregion

#region Diff backup
# Calling OH not scheduled jobs
$job = new-object Microsoft.SqlServer.Management.Smo.Agent.Job($Server.JobServer, "DBA - USER_DATABASES - DIFF")
$job.Category = "Database Maintenance"
$job.Create()

$job.ApplyToTargetServer("(local)")


$jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseIntegrityCheck - USER_DATABASES")
$jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
$jobstep.Command="EXEC [$dbaDatabase].[dbo].sp_sp_start_job_wait @job_name='DatabaseIntegrityCheck - USER_DATABASES', @WaitTime = '00:01:00'"
$jobstep.Create()

$jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "IndexOptimize - USER_DATABASES")
$jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
$jobstep.Command="EXEC [$dbaDatabase].[dbo].sp_sp_start_job_wait @job_name='IndexOptimize - USER_DATABASES', @WaitTime = '00:01:00'"
$jobstep.Create()

$jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseBackup - USER_DATABASES - DIFF")
$jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithSuccess
$jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
$jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
$jobstep.Command="EXEC [$dbaDatabase].[dbo].sp_sp_start_job_wait @job_name='DatabaseBackup - USER_DATABASES - DIFF', @WaitTime = '00:01:00'"
$jobstep.Create()
    
$jobschedule = new-object Microsoft.SqlServer.Management.Smo.Agent.JobSchedule($job, $job.name)
$jobschedule.FrequencyTypes = [Microsoft.SqlServer.Management.Smo.Agent.FrequencyTypes]::Weekly
$jobschedule.FrequencySubDayTypes = [Microsoft.SqlServer.Management.Smo.Agent.FrequencySubDayTypes]::Once
$jobschedule.FrequencyInterval =  [Microsoft.SqlServer.Management.Smo.Agent.WeekDays]::Monday `
                                + [Microsoft.SqlServer.Management.Smo.Agent.WeekDays]::Tuesday `
                                + [Microsoft.SqlServer.Management.Smo.Agent.WeekDays]::Wednesday `
                                + [Microsoft.SqlServer.Management.Smo.Agent.WeekDays]::Thursday `
                                + [Microsoft.SqlServer.Management.Smo.Agent.WeekDays]::Friday `
                                + [Microsoft.SqlServer.Management.Smo.Agent.WeekDays]::Saturday
$jobschedule.FrequencyRecurrenceFactor = 1
$jobschedule.FrequencySubDayinterval = 0
$ts1 = new-object System.TimeSpan(1, 0, 0)
$ts2 = new-object System.TimeSpan(23, 59, 59)
$jobschedule.ActiveStartTimeOfDay = $ts1
$jobschedule.ActiveEndTimeOfDay = $ts2
$jobschedule.ActiveStartDate = (Get-Date).Date 
$jobschedule.Create()
#endregion

#region Log backup
# Calling OH not scheduled jobs
$job = new-object Microsoft.SqlServer.Management.Smo.Agent.Job($Server.JobServer, "DBA - USER_DATABASES - LOG")
$job.Category = "Database Maintenance"
$job.Create()

$job.ApplyToTargetServer("(local)")

$jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseBackup - USER_DATABASES - LOG")
$jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::GoToNextStep
$jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
$jobstep.Command="EXEC msdb.dbo.sp_start_job 'DatabaseBackup - USER_DATABASES - LOG'"
$jobstep.Create()


$jobstep = new-object Microsoft.SqlServer.Management.Smo.Agent.JobStep($job, "DatabaseBackup - SYSTEM_DATABASES - LOG")
$jobstep.OnSuccessAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithSuccess
$jobstep.OnFailAction = [Microsoft.SqlServer.Management.Smo.Agent.StepCompletionAction]::QuitWithFailure
$jobstep.SubSystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::TransactSql
$jobstep.Command="
EXECUTE [$dbaDatabase].[dbo].[DatabaseBackup]
    @Databases = 'SYSTEM_DATABASES',
    @Directory = N'$defaultbackuplocation',
    @BackupType = 'LOG',
    @Verify = 'Y',
    @CleanupTime = $CleanupTime,
    @CheckSum = 'Y',
    @LogToTable = 'Y'
"
$jobstep.Create()

$jobschedule = new-object Microsoft.SqlServer.Management.Smo.Agent.JobSchedule($job, $job.name)
$jobschedule.FrequencyTypes = [Microsoft.SqlServer.Management.Smo.Agent.FrequencyTypes]::Daily
$jobschedule.FrequencySubDayTypes = [Microsoft.SqlServer.Management.Smo.Agent.FrequencySubDayTypes]::Hour
$jobschedule.FrequencySubDayinterval = 1
$jobschedule.FrequencyInterval = 1
$ts1 = new-object System.TimeSpan(0, 30, 0)
$ts2 = new-object System.TimeSpan(23, 59, 59)
$jobschedule.ActiveStartTimeOfDay = $ts1
$jobschedule.ActiveEndTimeOfDay = $ts2

$jobschedule.ActiveStartDate = (Get-Date).Date #new-object System.DateTime(2003, 1, 1)
$jobschedule.Create()
#endregion

<#

    Start-DbaAgentJob -SqlInstance $instance -Job "DBA - HouseKeeping"
    Start-DbaAgentJob -SqlInstance $instance -Job "DBA - USER_DATABASES - FULL"

#>

