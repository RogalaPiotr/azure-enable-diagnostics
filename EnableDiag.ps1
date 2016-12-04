﻿Param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("Arm","Classic")] 
    [string] $DeploymentModel,
    [ValidateSet("Windows","Linux")] 
    [string] $OsType,
	[switch] $ChooseSubscription,
	[switch] $ChooseStorage,
	[switch] $ChooseVM,
	[switch] $OverrideDiagnostics
)

#######################################

function CreateResultObject {

    $statusProperties = @{
        'RunType' = @{
            'DeploymentModel'= $DeploymentModel;
            'OverrideDiagnostics' = $OverrideDiagnostics;
        }
        'Subscriptions' = @();
    }

    return New-Object –TypeName PSObject –Prop $statusProperties
}

function CreateSubscriptionResultObject {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $SubscriptionName
    )

    $subscriptionProperties = @{
        'SubscriptionName' = $SubscriptionName;
        'StorageAccounts' = @()
        'VirtualMachines' = @()
        'Result' = @{'Status' = $null; 'ReasonOfFailure' = $null};
    }

    return New-Object –TypeName PSObject –Prop $subscriptionProperties
}

function CreateStorageAccountResultObject {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $StorageAccountName,
        [Parameter(Mandatory=$true)]
		[string] $ResourceGroupName,
        [Parameter(Mandatory=$true)]
		[string] $Location,
        [string] $Status
    )

    $storageAccountProperties = @{
        'StorageAccountName' = $StorageAccountName;
        'ResourceGroupName' = $ResourceGroupName;
        'Location' = $Location;
        'Status' = $Status
    }

    return New-Object –TypeName PSObject –Prop $storageAccountProperties
}

function AcquireStorageAccounts() {
    Param (
	    [System.Object[]]$Vms,
        [System.Object]$SubscriptionResult
	)

	Write-Host("Checking storage in each resource group and location")

    $allStorages = LoadStorageAccounts
	$storagesToUse = @{}
    
	$vmGroupedByLocation = $vms | Group-Object -Property Location
	foreach ($vmLocationGroup in $vmGroupedByLocation) {

	    $location =  $vmLocationGroup.Name;
	    $locationStorages = $allStorages[$location]

	    Write-Host("Checking storage in '$location' location")

	    $vmGroupedByResourceGroup = $vmLocationGroup.Group | Group-Object -Property ResourceGroupName
	    foreach ($vmResourceGroupGroup in $vmGroupedByResourceGroup)
	    {
		    $resourceGroupName = $vmResourceGroupGroup.Name
		    $storages = $locationStorages | where { $_.ResourceGroupName -eq $resourceGroupName  }

		    $toCreate = $false
            $storageAccountResult = $null

            $storageToUse = $null
            if ($storages -ne $null) {
                $storageToUse = SelectStorage $storages
		    } 

		    if ($storageToUse -eq $null) {
                $storageToUse = CreateStorage -ResourceGroupName $resourceGroupName -Location $location
		        $allStorages[$location] = [array]$allStorages[$location] += $storageToUse

			    $storageName = $storageToUse.StorageAccountName
                $storageAccountResult = CreateStorageAccountResultObject -StorageAccountName $storageName -ResourceGroupName $resourceGroupName -Location $location -Status "New"
			    Write-Host("'$storageName' storage account for resource group '$resourceGroupName' in location '$location' was created")
		    }
		    else{
			    $storageName = $storageToUse.StorageAccountName
                $storageAccountResult = CreateStorageAccountResultObject -StorageAccountName $storageName -ResourceGroupName $resourceGroupName -Location $location -Status "Existing"
			    Write-Host("Using '$storageName' storage account for resource group '$resourceGroupName' in location '$location'")
		    }

		    $storagesToUse[$location] = [array]$storagesToUse[$location] += $storageToUse
            $SubscriptionResult.StorageAccounts += $storageAccountResult
	    }
	}
	return $storages
}

function SelectStorage() {
    Param (
        [Parameter(Mandatory=$true)]
        [System.Object[]]$existsingStorageAccounts
    )

    if(!$ChooseStorage){
        return $existsingStorageAccounts[0]
    }

	Write-Host("There are existing storage account/s for resource group '$resourceGroupName' in location '$location':")
    Write-Host("")

	$storageName = $existsingStorageAccounts | foreach {Write-Host($_.StorageAccountName)}
    Write-Host("")

    $toSkip = ToSkip "Use one of them?" $ChooseStorage
    if ($toSkip) {
        return $null
    }

    $selectedStorage = $null
    $chosen = $false
    while (!$chosen) {
        $choice = Read-Host ("Enter name of storage account you want to use")
        $selectedStorage = $existsingStorageAccounts | where {$_.StorageAccountName -eq $choice}

        $chosen = $selectedStorage -ne $null
    }

    return $selectedStorage
}

function CreateStorage() {
    Param (
        [Parameter(Mandatory=$true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory=$true)]
        [string]$Location
              
    )

    $storageName = $null
	$storageName = GetStorageName $ResourceGroupName $Location $ChooseStorage
    Write-Host("Creating storage account'$storageName' for resource group '$resourceGroupName' in location '$location'")

	$retries = 0
    $storageCreated = $false

	while (!$storageCreated)
	{
        try {
		    Write-Host("Creating '$storageName' storage account")
            $storageToUse = CreateStorageAccount $resourceGroupName $storageName $location
    
		    $storageCreated = $true
            return $storageToUse
	    }
	    catch {
		    Write-Host("Failed to create storage")
		    $_

		    if  ($retries -ge 3) {
			    Write-Host("Failed to create storage more than 3 times, terminating script")
			    exit
		    }
		    Write-Host("Retry")
		    $retries++;
	    }
	}
}

function ToSetDiagnostics(){
	Param (
        [Parameter(Mandatory=$true)]
		[System.Object] $Vm,
        [Parameter(Mandatory=$true)]
		[System.Object] $virtualMachineResult
	)
    
    $vmName = $Vm.Name
    $isRunning = IsRunning $Vm
    if (!$isRunning){
        Write-Host("'$vmName' VM is not running")
        $virtualMachineResult.Result.Status = "Skipped"
        $virtualMachineResult.Result.ReasonOfFailure = "Vm is not running"
        return $false
    }

    if (ToSkip "Do you want to enable diagnostic for '$vmName'?" $ChooseVM){
        $virtualMachineResult.Result.Status = "Skipped"
        $virtualMachineResult.Result.ReasonOfFailure = "User choice"
        return $false
	}

    $isEnabled = IsDiagnosticsEnabled $Vm
    if (!$isEnabled){
		return $true
    }

	Write-Host("Diagnostics already enabled for '$vmName'")
	if ($OverrideDiagnostics) {
		Write-Host("Overriding")
        $virtualMachineResult.IsOverriden = $true
		return $true
	}

    $virtualMachineResult.Result.Status = "Skipped"
    $virtualMachineResult.Result.ReasonOfFailure = "Diagnostics already enabled"
    return $false
}

function SetDiagnostics {
    	Param (
        [Parameter(Mandatory=$true)]
		[System.Object] $vm,
        [Parameter(Mandatory=$true)]
        [System.Object] $storage
	)

    $cfgPath = $null

    switch -Regex ($DeploymentModel){
        "[Aa]rm" {$cfgPath = GetDiagnosticsConfigPath $path $vm.Id $vm.StorageProfile.OsDisk.OsType }
        "[Cc]lassic" {$cfgPath = GetDiagnosticsConfigPath $path $vm.ResourceId $vm.ClassicResource.VM.OSVirtualHardDisk.OS}
    }
	 
    SetVmDiagnostic $vm $storage $cfgPath
}

#######################################

$path = split-path -parent $MyInvocation.MyCommand.Definition

switch -Regex ($DeploymentModel){
    "[Aa]rm" {&($path + "/ArmModule.ps1")}
    "[Cc]lassic" {&($path + "/ClassicModule.ps1"
    )} 
    default {throw [System.InvalidOperationException] "$DeploymentModel is not supported. Allowed values are 'Arm' or 'Classic' "}
}

&($path + "/CommonModule.ps1")

EnableLogging $path
$ErrorActionPreference = "Stop"

$subscriptions = $null
$subscriptions = LoadSubscriptions

$subscriptionsCount = $subscriptions.Length
Write-Host("Found $subscriptionsCount subscriptions")

$Result = CreateResultObject
foreach ($subscription in $subscriptions){
	$subscriptionId = $subscription.SubscriptionId
	$subscriptionName = $subscription.SubscriptionName

    $subscriptionResult = CreateSubscriptionResultObject -SubscriptionName $subscriptionName
    $Result.Subscriptions += $subscriptionResult

	try {
		if (ToSkip "Do you want to enable diagnostic in '$subscriptionName' subscription?" $ChooseSubscription){
            $subscriptionResult.Result.Status = "Skipped"
            $subscriptionResult.Result.ReasonOfFailure = "User choice"
			continue
		}

		Write-Host("Enabling diagnostics in '$subscriptionName' subscription")
		SelectSubscription $subscriptionId

		$vms = LoadVirtualMachines $OsType
		$vmsCount = $vms.Length
		if ($vms.Length -eq 0) {
			Write-Host ("No vm were found")
            $subscriptionResult.Result.Status = "Skipped"
            $subscriptionResult.Result.ReasonOfFailure = "No vm were found"
			continue
		}

		Write-Host ("Found $vmsCount virtual machines")
		Write-Host("Acquiring storage accounts")
		
		$storages = AcquireStorageAccounts $vms $subscriptionResult
		foreach ($vm in $vms){
			$resourceGroupName = $vm.ResourceGroupName
            $vmName = $vm.Name
            $vmLocation = $vm.Location

            $virtualMachineResult = CreateVirtualMachineResultObject -Vm $vm
            $subscriptionResult.VirtualMachines += $virtualMachineResult

            try {
                $reloadedVm = ReloadVm $vm
			    $toSet = ToSetDiagnostics $reloadedVm $virtualMachineResult

			    if (!$toSet) {
				    continue
			    }

	            $storage = $storages.Get_Item($vmLocation) | where {$_.ResourceGroupName -eq $resourceGroupName}
                $virtualMachineResult.StorageAccountName = $storage.StorageAccountName
    
                SetDiagnostics $reloadedVm $storage
                $virtualMachineResult.Result.Status = "Success"
            }
            catch {
		        Write-Host("Failed to enable diagnostic for '$vmName' VM")
		        $_
                $virtualMachineResult.Result.Status = "Failed"
                $virtualMachineResult.Result.ReasonOfFailure = $_
	        }
		}

        $subscriptionResult.Result.Status = "Succeed"
	}
	catch {
		Write-Host("Failed to enable diagnostic for '$subscriptionName' subscription")
		$_
        $subscriptionResult.Result.Status = "Failed"
        $subscriptionResult.Result.ReasonOfFailure = $_
	}
}

$Result | ConvertTo-Json -Compress -Depth 10 | Out-File ($path + "/logs/" + $DeploymentModel.ToLower() + "_" + ((Get-Date).ToUniversalTime()).ToString("yyyyMMddTHHmmssfffffffZ") + ".json")