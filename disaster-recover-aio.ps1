<#
.SYNOPSIS
    This script automates overall process of bringing up & down DR system onprem
.DESCRIPTION
    The steps executed on this script has been created in mind to accomplish bringing up DR as fast as possible within 10 minutes
    It may or may not represent the same steps being executed on the vSphere vCenter GUI
    However this script has been extensively tested on real DR environment with successful results
    For any errors, kindly find the .log file created when running the script

    Currently supports:
    - verify all LUN(s) both Datastore LUN and RDM LUN
    - Shutdown VM(s)
    - attach RDM LUN if detected as Detached during verification process
    - assign 'vmfsrescanrequired' flag whenever Datastore isn't properly detached during bring down process
        - execute vmfs rescan whenever flag detected on ESX host where VM with DS currently resides
    - attach LUN to its ESX host  where VM with DS currently resides (skipped if 'vmfsrescanrequired')
    - initiate vmfs snapshot resignature and resolve
    - rename vmfs snapshot DS to remove random number snap-xxxx-dsname
    - mount all vDisk(s) and RDM to VM(s) based on comma separated value file (.csv), adjust here for any additional disk needed
    - power on all VM(s)
    - continue attach DS LUN to remaining ESX host(s) to resolve VMFS by itself (skipped if 'vmfsrescanrequired')
        - execute vmfs recan whenever flag detected on remaining ESX host(s)
	- Unmount vDisk(s) & RDM(s)
	- Unmount Datastore
	- Detach Datastore LUN only (Detaching Datastore LUN might take too much time)
	- Verify Datastore LUN Device State
	- Rescan VMFS (Might not be successful as Detaching LUN might make Host Not Responding) *this steps is essential
.NOTES
    File Name   : disaster-recover-aio.ps1
    Author      : ariff.azman
    Version     : 1.0
.LINK

.INPUTS
    Comma seperated value .csv file that include replicated VM, vDisk, RDM, Cluster details
.OUTPUTS
    Verbose logging transcript .log file
#>

# functions
function Write-Info {
    param ($Message)
    $time = $(Get-Date).ToString("dd-MM-yy h:mm:ss tt") + ''
    Write-Verbose -Message "$time $Message." -Verbose
}

function Write-Exception {
    param ($ExceptionItem)
    $exc = $exceptionItem
    $time = $(Get-Date).ToString("dd-MM-yy h:mm:ss tt") + ''
    if ($exc.Exception.ErrorCategory) {
        $item = $exc.Exception.ErrorCategory | Out-String
        $itemfixed = $item.Replace([environment]::NewLine , '')
        Write-Warning -Message "$time $itemfixed."
    }
    elseif ($exc.Exception) {
        $item = $exc.Exception | Out-String
        $itemfixed = $item.Replace([environment]::NewLine , '')
        Write-Warning -Message "$time $itemfixed."
    }
    else {
        $item = $exc | Out-String
        $itemfixed = $item.Replace([environment]::NewLine , '')
        Write-Warning -Message "$time $itemfixed."
    }
}

function ExitScript {
    Disconnect-VIServer $vCenter -Confirm:$false | Out-Null
    Write-Info "Transcript stopped, output file is $currTranscriptName"
    Stop-Transcript | Out-Null
    exit
}

if (Get-Module -Name VMWare.PowerCLI -ListAvailable) {
    #  continue
}
else {
    Write-Exception "VMWare.PowerCLI Module not Installed"
    ExitScript
}

# Begin Main Script ********************************************************************************
$vCenter = '10.10.10.10'
$currDate = $(Get-Date).ToString("dd-MMM-yy")
$currTranscriptName = "$PSScriptRoot\logs\transcript-up-$currDate.log"

Start-Transcript -Path $currTranscriptName -Append | Out-Null

Write-Info "Transcript started, output file is $currTranscriptName"
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

$drList = Get-ChildItem "$PSScriptRoot\info\" | ForEach-Object Name

Write-Host "......................................................................................."
$drList | ForEach-Object {
    Write-Host "$($_.ToUpper()) | " -NoNewline
}
Write-Host "`n......................................................................................."

while($drSelected -notin $drList){
    $drSelected = Read-Host -Prompt "Enter DR system of choice?"
    if($drSelected -notin $drList){
        Write-Exception -ExceptionItem "No such DR exists"
    }
}

# Import .csv files *******************************************************************************

$header = Get-Content "$PSScriptRoot\info\$drSelected\header.txt"
Write-Output "--------------------------------------------------------------------------------------"
$header | ForEach-Object {
    Write-Output $_
    Start-Sleep -Milliseconds 200
}
Write-Output "--------------------------------------------------------------------------------------"

$diskList = Import-Csv "$PSScriptRoot\info\$drSelected\list-disk.csv"
$lunList = Import-Csv "$PSScriptRoot\info\$drSelected\list-lun.csv"
$vmList = Import-Csv "$PSScriptRoot\info\$drSelected\list-vm.csv"

try {
    Connect-VIServer $vCenter -Credential (Get-Credential -Message 'Provide "\a-" Credential') -ErrorAction Stop | Out-Null
    Write-Info "Establishing connection to vCenter Server suceeded: $vCenter"
}
catch {
    Write-Exception -ExceptionItem $PSItem
    ExitScript
}

do {
    $drActivity = Read-Host -Prompt "Which DR activity to execute?[up/down]"
    switch ($drActivity) {
        'up' {
            # Verify_LUN ***************************************************************************************
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Verify LUN (s) [START]"
            Write-Output "--------------------------------------------------------------------------------------"

            $dsState = @()
            $rdmState = @()

            Write-Info -Message "Verifying Datastore LUN(s) Device State"
            # LUN(s) used as Datastore being verified here
            $dsState = $lunList | Where-Object Datastore -ne 'RDM' | ForEach-Object {
                & "$PSScriptRoot\etc\Verify-LUN.ps1" -Cluster $_.Cluster -CanonicalName $_.CanonicalName
            }

            # Best LUN(s) state where full bring down process takes place
            if ($dsState | Where-Object DeviceState -eq 'Detached') {
                Write-Info -Message "Datastore LUN(s) Detached"
                $vmfsRescanRequired = $false
            }
            elseif ($dsState | Where-Object DeviceState -eq 'Attached') {
                Write-Exception -ExceptionItem "Datastore LUN(s) Attached"
                $vmfsRescanRequired = $true
            }
            elseif (!$dsState){
                Write-Info -Message "No Datastore involved"
            }
            else {
                Write-Exception -ExceptionItem "Datastore LUN(s) Dead or Error"
                Write-Exception -ExceptionItem "Unable to proceed, storage access is disabled"
                ExitScript
            }

            $verifyAttempt = 1
            do {
                Write-Info -Message "Verifying RDM LUN(s) Device State - Attempt $verifyAttempt"

                # LUN(s) used as RDM being verified here
                # Usually to verify whether storage access has been enabled or not

                $rdmCluster = $lunlist | Where-Object Datastore -eq 'RDM' | Select-Object Cluster -Unique
                $rdmState = $rdmCluster | ForEach-Object {
                    $rdmlun = @()
                    $Cluster = $_.Cluster
                    $rdmlun += $lunlist | Where-Object { $_.Datastore -eq 'RDM' -and $_.Cluster -eq $Cluster }
                    & "$PSScriptRoot\etc\Verify-LUN.ps1" -Cluster $Cluster -CanonicalName $rdmlun.CanonicalName
                }

                # For some special case where RDM is accidentally detached?
                if ($rdmState | Where-Object DeviceState -eq 'Detached') {
                    Write-Exception -ExceptionItem "RDM LUN(s) Detached"
                    Write-Info -Message "Attempting to Attach RDM LUN(s)"
                    $rdmState | Where-Object DeviceState -eq 'Detached' | ForEach-Object {
                        & "$PSScriptRoot\etc\Attach-Lun.ps1" -VMHost $_.VMHost -CanonicalName $_.CanonicalName
                    }
                }
                elseif ($rdmState | Where-Object DeviceState -eq 'Attached') {
                    Write-Info -Message "RDM LUN(s) Attached"
                    $verifyConfirm = $null
                }
                else {
                    Write-Exception -ExceptionItem "RDM LUN(s) Dead or Error, unable to proceed, storage access still disabled"
                    $verifyConfirm = Read-Host -Prompt "Verify Again? [y/n]"
                    if ($verifyConfirm -match "n|N") {
                        ExitScript
                    }
                }
                $verifyAttempt++

            } while ($verifyConfirm -match "y|Y")

            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Verify LUN (s) [END]"
            Write-Output "--------------------------------------------------------------------------------------"

            # VM_Guest_PowerOff / Stop-VM **********************************************************************
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Shutdown Virtual Machines [START]"
            Write-Output "--------------------------------------------------------------------------------------"
            $vmList | ForEach-Object {
                $VMName = $_.Name
                try {
                    Write-Info "Powering Off <$VMName>"
                    Stop-VM -VM $VMName -Confirm:$false -ErrorAction Stop | Out-Null
                }catch { Write-Exception -ExceptionItem $PSItem }
            }
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Shutdown VM [END]"
            Write-Output "--------------------------------------------------------------------------------------"
            # **************************************************************************************************

            # VMFS_Rescan **************************************************************************************
            if ($vmfsRescanRequired) {
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "VMFS Initial Rescan [START]"
                Write-Output "--------------------------------------------------------------------------------------"
                $vmList | Where-Object HasDatastore -eq $true | ForEach-Object {
                    $VMName = $_.Name
                    Get-VM $VMName | Get-VMHost | ForEach-Object {
                        $VMHost = $_.Name
                        Write-Info "Rescanning VMFS at [$VMHost]"
                        Get-VMHostStorage -VMHost $VMHost -RescanVmfs -Verbose -ErrorAction Stop | Out-Null
                    }
                }
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Host "VMFS Initial Rescan [END]"
                Write-Output "--------------------------------------------------------------------------------------"
            }
            # **************************************************************************************************

            # VMFS_Snapshot_Resignature ************************************************************************
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "LUN Inital Attach & VMFS Resolve [START]"
            Write-Output "--------------------------------------------------------------------------------------"
            $vmList | Where-Object HasDatastore -eq $true | ForEach-Object {
                $VMName = $_.Name
                $VMHost = Get-VM $VMName | Get-VMHost
                Write-Info "$VMName has a vDisk(s) Datastore, currently inside [$VMHost]"

                $lunList | Where-Object Datastore -ne 'RDM' | ForEach-Object {
                    $dsName = $_.Datastore
                    & "$PSScriptRoot\etc\Attach-Lun.ps1" -VMHost $VMHost -CanonicalName $_.CanonicalName
                    $esxcli = $VMHost | Get-EsxCli -WarningAction SilentlyContinue # currently using version 1, version 2 is latest

                    Write-Info "Checking for unresolved VMFS snapshot on [$VMHost]"
                    $snapAvail = $esxcli.storage.vmfs.snapshot.list() # confirming the snapshot availability

                    if ($snapAvail) {
                        Write-Info "$VMHost has unresolved VMFS snapshot"
                        Start-Sleep -Seconds 2
                        # Use this to mount with resignature ***************************************
                        Write-Info "Resignaturing VMFS snapshot [$($snapAvail.VolumeName)]"
                        $vmfsOutput = $esxcli.storage.vmfs.snapshot.resignature($dsName.Remove(0, 5))
                        # **************************************************************************
                        # Use this to mount without resignature ************************************
                        # Write-Info "Mounting VMFS snapshot [$($snapAvail.VolumeName)]"
                        # $vmfsOutput = $esxcli.storage.vmfs.snapshot.mount($dsName.Remove(0,5))
                        # **************************************************************************
                        if ($vmfsOutput -eq 'true') {
                            Write-Info "VMFS snapshot [$($snapAvail.VolumeName)] resignatured sucessfully at [$VMHost]"
                            Write-Info "Allocating [$VMHost] some grace period for 10 seconds"
                            Start-Sleep -Seconds 10 # pausing for 10 seconds so that ds current name can be captured
                            $dsToRename = $VMHost | Get-Datastore | Where-Object Name -Match $dsName.Remove(0, 5) | ForEach-Object { $_.Name }
                            Write-Info "Current Datastore Name: `"$dsToRename`""
                            Write-Info "New Datastore Name: `"$dsName`""
                            try {
                                Write-Info "Renaming VMFS datastore"
                                # rename to name based on BDC with 'snap-xxxxx' on it
                                $VMHost | Get-Datastore | Where-Object Name -EQ $dsToRename | Set-Datastore -Name $dsName | Out-Null
                            }
                            catch { Write-Exception -ExceptionItem $PSItem }
                        }
                        else { Write-Exception "Fail to resignature $($snapAvail.VolumeName) at [$VMHost]" }
                    }
                    else { Write-Exception -ExceptionItem "$VMHost has no unresolved VMFS snapshot(s)" }
                }
            }
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "LUN Inital Attach & VMFS Resolve [END]"
            Write-Output "--------------------------------------------------------------------------------------"

            # Disk_Mount ***************************************************************************************
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Disk Mount [START]"
            Write-Output "--------------------------------------------------------------------------------------"
            $diskList | ForEach-Object {
                $VMName = $_.Parent
                $diskType = $_.DiskType
                $filename = $_.Filename
                $canonicalName = $_.CanonicalName
                try {
                    if ($diskType -eq 'RawPhysical') {
                        Write-Info "Mounting RDM Disk <$VMName>: $canonicalName"
                        New-Harddisk -VM $VMName -DiskType RawPhysical -DeviceName /vmfs/devices/disks/$canonicalName -ErrorAction Stop | Out-Null
                    }
                    elseif ($diskType -eq 'Flat') {
                        Write-Info "Mounting Virtual Disk <$VMName>: $filename"
                        New-Harddisk -VM $VMName -DiskPath $filename -ErrorAction Stop | Out-Null
                    }
                }
                catch { Write-Exception -ExceptionItem $PSItem }
            }
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Disk Mount [END]"
            Write-Output "--------------------------------------------------------------------------------------"
            # **************************************************************************************************

            # VM_Start ******************************************************************************************
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Power On VM [START]"
            Write-Output "--------------------------------------------------------------------------------------"
            $vmList | ForEach-Object {
                $VMName = $_.Name
                try {
                    Write-Info "Starting VM <$VMName>"
                    Start-VM $VMName -Confirm:$false -ErrorAction Stop | Out-Null
                }
                catch { Write-Exception -ExceptionItem $PSItem }
            }
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Power On VM [END]"
            Write-Output "--------------------------------------------------------------------------------------"
            # **************************************************************************************************

            # LUN Final Attach | VMFS Final Rescan *************************************************************
            if ($vmfsRescanRequired) {
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "VMFS Final Rescan [START]"
                Write-Output "--------------------------------------------------------------------------------------"
                $lunList | Where-Object Datastore -ne RDM | ForEach-Object {
                    $Cluster = $_.Cluster
                    Get-Cluster $Cluster | Get-VMHost | ForEach-Object {
                        $VMHost = $_.Name
                        try {
                            Write-Info "Rescanning VMFS at [$VMHost]"
                            Get-VMHostStorage -VMHost $VMHost -RescanVmfs -ErrorAction Stop | Out-Null
                        }
                        catch { Write-Exception -ExceptionItem $PSItem }
                    }
                }
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Host "VMFS Final Rescan [END]"
                Write-Output "--------------------------------------------------------------------------------------"
            }
            elseif ($dsState) {
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "LUN Final Attach [START]"
                Write-Output "--------------------------------------------------------------------------------------"
                $dsState = @()
                Write-Info -Message "Verifying Datastore LUN(s) Device State"
                # LUN(s) used as Datastore being verified here
                $lunList | Where-Object Datastore -ne 'RDM' | ForEach-Object {
                    $dsState += & "$PSScriptRoot\etc\Verify-LUN.ps1" -Cluster $_.Cluster -CanonicalName $_.CanonicalName
                }
                # LUN(s) used as Datastore attach lastly
                $dsState | Where-Object DeviceState -eq 'Detached' | ForEach-Object {
                    & "$PSScriptRoot\etc\Attach-Lun.ps1" -VMHost $_.VMHost -CanonicalName $_.CanonicalName
                }
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "LUN Final Attach [END]"
                Write-Output "--------------------------------------------------------------------------------------"
            }else {
                Write-Info -Message "No Datastore Involved"
            }
            $drConfirmed = $true
        }
        'down' {
            # VM_Guest_PowerOff / Stop-VM **********************************************************************
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Shutdown Virtual Machines [START]"
            Write-Output "--------------------------------------------------------------------------------------"
            $vmList | ForEach-Object {
                $VMName = $_.Name
                try {
                    # Use this to shutdown by Guest OS
                    # Write-Info "Initiate Guest OS Shutdown for <$VMName>"
                    # Shutdown-VMGuest -VM $VMName -Confirm:$false -ErrorAction Stop | Out-Null
                    # Use this to Power Off VM immediately
                    Write-Info "Powering Off <$VMName>"
                    Stop-VM -VM $VMName -Confirm:$false -ErrorAction Stop | Out-Null
                }catch { Write-Exception -ExceptionItem $PSItem }
            }
            # Wait some time for VM to fully be powered off to unmount disk
            Write-Info "Allocating some grace period for VM(s) to power off properly <60s>"
            Start-Sleep -Seconds 60
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Shutdown VM [END]"
            Write-Output "--------------------------------------------------------------------------------------"
            # **************************************************************************************************

            # Disk_Unmount *************************************************************************************
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Disk Unmount [START]"
            Write-Output "--------------------------------------------------------------------------------------"
            $diskList | ForEach-Object {
                $VMName = $_.Parent
                $diskType = $_.DiskType
                $filename = $_.Filename
                $canonicalName = $_.CanonicalName
                try {
                    if($diskType -eq "RawPhysical"){
                        Write-Info "Unmounting Disk <$VMName>: $canonicalName"
                        Get-HardDisk -VM $VMName | Where-Object -Property ScsiCanonicalName -eq $canonicalName | Remove-HardDisk -DeletePermanently -Confirm:$false -ErrorAction Stop | Out-Null
                        # parameter -DeletePermanently is the equivalent for "Delete files from datastore" on GUI (use for RDM disks only)
                    }
                    elseif($diskType -eq "Flat"){
                        Write-Info "Unmounting Disk <$VMName>: $filename"
                        Get-HardDisk -VM $VMName | Where-Object -Property Filename -eq $filename | Remove-HardDisk -Confirm:$false -ErrorAction Stop | Out-Null
                    }
                }catch { Write-Exception -ExceptionItem $PSItem }
            }
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Disk Unmount [END]"
            Write-Output "--------------------------------------------------------------------------------------"
            # **************************************************************************************************

            if ($lunList | Where-Object Datastore -ne RDM) {
                # DS_Unmount ***************************************************************************************
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "Datastore Unmount [START]"
                Write-Output "--------------------------------------------------------------------------------------"
                $lunList | Where-Object Datastore -ne RDM | ForEach-Object {
                    $dsName = $_.Datastore
                        try{
                            & "$PSScriptRoot\etc\Unmount-Datastore.ps1" -Datastore $dsName
                        }catch { Write-Exception -ExceptionItem $PSItem }
                }
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "Datastore Unmount [END]"
                Write-Output "--------------------------------------------------------------------------------------"
                # # **************************************************************************************************

                # LUN_Detach ***************************************************************************************
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "Datastore LUN Detach [START]"
                Write-Output "--------------------------------------------------------------------------------------"
                $lunList | Where-Object Datastore -ne RDM | ForEach-Object {
                    $dsName = $_.Datastore
                    & "$PSScriptRoot\etc\Detach-LUN.ps1" -Datastore $dsName
                }
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "Datastore LUN Detach [END]"
                Write-Output "--------------------------------------------------------------------------------------"
                # **************************************************************************************************

                do {
                    Write-Info -Message "Verifying Datastore LUN(s) Device State"
                    $dsState = @()
                    $dsState = $lunList | Where-Object Datastore -ne 'RDM' | ForEach-Object {
                        & "$PSScriptRoot\etc\Verify-LUN.ps1" -Cluster $_.Cluster -CanonicalName $_.CanonicalName
                    }
                    Start-Sleep -Seconds 300
                } until ($dsState | Where-Object DeviceState -eq 'Detached')

                # VMFS_Rescan **************************************************************************************
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Output "VMFS Rescan [START]"
                Write-Output "--------------------------------------------------------------------------------------"
                $lunList | Where-Object Datastore -ne RDM | ForEach-Object {
                    $Cluster = $_.Cluster
                    Get-Cluster $Cluster | Get-VMHost | ForEach-Object {
                        $VMHost = $_.Name
                        try {
                            Write-Info "Rescanning VMFS at [$VMHost]"
                            Get-VMHostStorage -VMHost $VMHost -RescanVmfs -ErrorAction Stop | Out-Null
                        }catch{ Write-Exception -ExceptionItem $PSItem }
                    }
                }
                Write-Output "--------------------------------------------------------------------------------------"
                Write-Host "VMFS Rescan [END]"
                Write-Output "--------------------------------------------------------------------------------------"
                # **************************************************************************************************
            }
            else {
                Write-Info -Message "No Datastore Involved"
            }

            # VM_Start ******************************************************************************************
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Power On VM [START]"
            Write-Output "--------------------------------------------------------------------------------------"
            $vmList | ForEach-Object {
                $VMName = $_.Name
                try {
                    Write-Info "Starting VM <$VMName>"
                    Start-VM $VMName -Confirm:$false -ErrorAction Stop | Out-Null
                }
                catch { Write-Exception -ExceptionItem $PSItem }
            }
            Write-Output "--------------------------------------------------------------------------------------"
            Write-Output "Power On VM [END]"
            Write-Output "--------------------------------------------------------------------------------------"
            # **************************************************************************************************
            $drConfirmed = $true
        }
        Default {
            Write-Exception "Unknown command"
            $drConfirmed = $false
        }
    }
} until ($drConfirmed)

ExitScript

# End Main Script ************************************************************************************************
