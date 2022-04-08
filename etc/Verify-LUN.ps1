[CmdletBinding(DefaultParameterSetName = 'ByCluster')]
Param (
  [Parameter(ValueFromPipeline = $true, ParameterSetName = 'ByVMHost')]
  $VMHost,
  [Parameter(ValueFromPipeline = $true, ParameterSetName = 'ByCluster')]
  $Cluster,
  [Parameter(Mandatory = $true)]
  $CanonicalName
)

$allInfo = @()

switch ($PSCmdlet.ParameterSetName) {
  'ByVMHost' {
    Get-VMHost $VMHost | ForEach-Object {
      $storSys = Get-View $_.Extensiondata.ConfigManager.StorageSystem
      foreach ($lun in $CanonicalName) {
        $Info = { } | Select-Object VMHost, DeviceState, CanonicalName
        $device = $storSys.StorageDeviceInfo.ScsiLun | Where-Object { $_.CanonicalName -eq $lun }
        switch ($device.OperationalState) {
          'error' {
            $Info.VMHost = $_.Name
            $Info.DeviceState = 'Error'
            $Info.CanonicalName = $lun
          }
          'ok' {
            $Info.VMHost = $_.Name
            $Info.DeviceState = 'Attached'
            $Info.CanonicalName = $lun
          }
          'off' {
            $Info.VMHost = $_.Name
            $Info.DeviceState = 'Detached'
            $Info.CanonicalName = $lun
          }
          Default {
            $Info.VMHost = $_.Name
            $Info.DeviceState = 'Unknown'
            $Info.CanonicalName = $lun
          }
        }
        $allInfo += $Info
      }
    }
  }
  'ByCluster' {
    Get-Cluster $Cluster | Get-VMHost | Where-Object ConnectionState -EQ 'Connected' | ForEach-Object {
      $storSys = Get-View $_.Extensiondata.ConfigManager.StorageSystem
      $VMHost = $_
      foreach ($lun in $CanonicalName) {
        $Info = { } | Select-Object VMHost, DeviceState, CanonicalName
        $device = $storSys.StorageDeviceInfo.ScsiLun | Where-Object { $_.CanonicalName -eq $lun }
        switch ($device.OperationalState) {
          'error' {
            $Info.VMHost = $VMHost
            $Info.DeviceState = 'Error'
            $Info.CanonicalName = $lun
          }
          'ok' {
            $Info.VMHost = $VMHost
            $Info.DeviceState = 'Attached'
            $Info.CanonicalName = $lun
          }
          'off' {
            $Info.VMHost = $VMHost
            $Info.DeviceState = 'Detached'
            $Info.CanonicalName = $lun
          }
          Default {
            $Info.VMHost = $VMHost
            $Info.DeviceState = 'Unknown'
            $Info.CanonicalName = $lun
          }
        }
        $allInfo += $Info
      }
    }
  }
  Default {
    Write-Error -Message $PSItem
  }
}

$allInfo
