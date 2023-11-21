#requires -modules VMware.VimAutomation.Core

# https://build.rubrik.com
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Creates a new role in vSphere with the restricted privileges needed to run Rubrik CDM. Assigns role to 
Rubrik Service Account at the root of Hosts and Clusters.

.DESCRIPTION
The create_vCenter_User.ps1 cmdlet will create a new role in a vCenter with the minimum privileges to 
allow Rubrik CDM to perform data protection in vSphere. The new role will be assigned to a specified
user in vCenter. Options are provided for creating roles in on-prem vCenters, VMware Cloud on AWS (VMC)
vCenters, Azure VMware Cloud Solution (AVS) and  Google VMware Cloud Engine (GCVE).

.NOTES
Updated 2023.08.26 by David Oslager for community usage
GitHub: doslagerRubrik

You can use a vCenter credential file for authentication
To create one: Get-Credential | Export-CliXml -Path ./vcenter_cred.xml

.EXAMPLE
create_vCenter_User.ps1 

Create the restricted permissions and prompt for all of the variables.

.EXAMPLE
create_vCenter_User.ps1 -vCenter <vcenter_server> -vCenterAdminUser <vcenter_admin_user> -vCenterAdminPassword <vcenter_admin_password> -RubrikServiceAccount <username_for_rubrik_role> -RubrikRoleName <role_name> -vCenterType ONPREM

Create the restricted permissions in an On-Prem vCenter using a username and password specified on the command line.

.EXAMPLE
create_vCenter_User.ps1 -vCenter <vcenter_server> -vCenterCredFile <credential_file> -RubrikServiceAccount <username_for_rubrik_role> -RubrikRoleName <role_name> -vCenterType VMC

Create the restricted permissions in an VMC vCenter using a specific vCenter credential file.

.EXAMPLE
create_vCenter_User.ps1 -vCenter <vcenter_server> -RubrikServiceAccount <username_for_rubrik_role> -RubrikRoleName <role_name> -vCenterType AVS

Create the restricted permissions in an AVS vCenter and prompt for the vCenter username and password.
#>
#
param (
  [CmdletBinding()]

  # Hostname, FQDN or IP of the vCenter server.
  [string]$vCenter,

  # vCenter user with with admin privileges to create the Role and assign that role.
  [string]$vCenterAdminUser,

  # Password for vCenter admin user.
  [string]$vCenterAdminPassword,

  # Rubrik Service Account in vSphere to assign Rubrik privileges to.
  [string]$RubrikServiceAccount,

  # Role name to create. Default: Rubrik_Backup_Service
  [string]$RubrikRoleName,
 
  # Create Rubrik vCenter Role only and exit. Default: false
  [switch]$CreateRoleOnly,

  #Select the type of vCenter to add privileges for. No Default
  [string]$vCenterType,

  # vCenter credential file to use. 
  [string]$vCenterCredFile
)


$LineSepDashes = "-" * 150
write-host $LineSepDashes
Write-Host ""
Write-Host "PowerCLI script to create Rubrik Role which includes required privileges and assigns the designated Rubrik Service Account to Role" -ForeGroundColor Cyan 
Write-Host ""
write-host $LineSepDashes

try {
    Write-Host "Importing VMware PowerCLI" -ForegroundColor CYAN
    Import-Module VMware.VimAutomation.Core -ErrorAction STOP
} catch {
    Write-Host "Failed to import VMware PowerCLI. Please verify it is installed"
    Write-Host "$($error[0].exception.message)" -ForegroundColor RED
    Write-Host
    write-host $LineSepDashes
    exit
}




#region Define Privs
#Baseline Privileges to assign to role
#verified and update as per: https://docs.rubrik.com/en-us/saas/cdm/vcenter_privs.html
$Rubrik_Base_Privileges = @(
    'Cryptographer.Access'
    'Datastore.AllocateSpace'
    'Datastore.Browse'
    'Datastore.Config'
    'Datastore.Delete'    
    'Datastore.FileManagement'
    'Datastore.Move'
    'Global.DisableMethods' 
    'Global.EnableMethods' 
    'Global.ManageCustomFields' 
    'Global.SetCustomField' 
    'InventoryService.Tagging.AttachTag' 
    'Network.Assign'
    'Resource.AssignVMToPool'
    'Resource.ColdMigrate'
    'Resource.HotMigrate'
    'Resource.QueryVMotion' 
    'Sessions.TerminateSession'
    'Sessions.ValidateSession'
    'StorageProfile.Update'
    'StorageProfile.View' 
    'System.Anonymous'
    'System.Read'
    'System.View'
    'VirtualMachine.Config.AddExistingDisk'
    'VirtualMachine.Config.AddNewDisk'
    'VirtualMachine.Config.AddRemoveDevice'
    'VirtualMachine.Config.AdvancedConfig'
    'VirtualMachine.Config.Annotation'
    'VirtualMachine.Config.ChangeTracking'
    'VirtualMachine.Config.DiskLease'
    'VirtualMachine.Config.EditDevice' 
    'VirtualMachine.Config.Memory' 
    'VirtualMachine.Config.RemoveDisk'
    'VirtualMachine.Config.Rename'
    'VirtualMachine.Config.Resource'
    'VirtualMachine.Config.Settings'
    'VirtualMachine.Config.SwapPlacement'
    'VirtualMachine.GuestOperations.Execute'
    'VirtualMachine.GuestOperations.Modify'
    'VirtualMachine.GuestOperations.Query'
    'VirtualMachine.Interact.AnswerQuestion'
    'VirtualMachine.Interact.Backup'
    'VirtualMachine.Interact.DeviceConnection'
    'VirtualMachine.Interact.GuestControl'
    'VirtualMachine.Interact.PowerOff'
    'VirtualMachine.Interact.PowerOn'
    'VirtualMachine.Interact.Reset'
    'VirtualMachine.Interact.Suspend'
    'VirtualMachine.Interact.ToolsInstall'
    'VirtualMachine.Inventory.Create'
    'VirtualMachine.Inventory.CreateFromExisting' 
    'VirtualMachine.Inventory.Delete'
    'VirtualMachine.Inventory.Move'
    'VirtualMachine.Inventory.Register'
    'VirtualMachine.Inventory.Unregister'
    'VirtualMachine.Provisioning.Clone' 
    'VirtualMachine.Provisioning.Customize'
    'VirtualMachine.Provisioning.DiskRandomAccess'
    'VirtualMachine.Provisioning.DiskRandomRead'
    'VirtualMachine.Provisioning.GetVmFiles'
    'VirtualMachine.Provisioning.PutVmFiles'
    'VirtualMachine.State.CreateSnapshot'
    'VirtualMachine.State.RemoveSnapshot'
    'VirtualMachine.State.RenameSnapshot'
    'VirtualMachine.State.RevertToSnapshot'
)

$Rubrik_vCenter_7_Privileges = @(
      'InventoryService.Tagging.CreateCategory'
      'InventoryService.Tagging.CreateTag'
      'InventoryService.Tagging.ObjectAttachable'
)

$Rubrik_VMC_AVS_GCVE_Privileges = $Rubrik_Base_Privileges + @(
    'VApp.Import' 
)

$Rubrik_OnPrem_Privileges = $Rubrik_Base_Privileges + @(
    'Host.Config.Image' 
    'Host.Config.Maintenance' 
    'Host.Config.Patch'
    'Host.Config.Storage' 
    'Host.Config.SystemManagement' 
)
#EndRegion Define Privs


#region Confirm vCenter
if (! $vCenter) {
    Write-Host "vCenter Servername not specified" -ForegroundColor Yellow
    $vCenter = Read-Host -Prompt "vCenter server name "
}

Write-Host "Verifying connectivity to $vCenter" -ForegroundColor CYAN
if ((Test-Connection -ComputerName $vcenter -Quiet) -eq $false) {
    Write-Host "  > ERROR! Could not reach vCenter. Please verify and try again" -ForegroundColor RED
    Write-Host
    write-host $LineSepDashes
    exit
} else {
    Write-Host "  > Ping to $vCenter succeeded!" -ForegroundColor GREEN
}
#EndRegion Confirm vCenter


#Region vCenter Type
if ($vCenterType -notin @("OnPrem", "VMC", "AVS", "GVCE")) {
    if ( $vCenterType -eq "" ) {
        Write-Host "ERROR! vCenter type specified is blank" -ForegroundColor RED
    } else {
        Write-Host "ERROR! vCenter type specified is incorrect" -ForegroundColor RED
    }
    $title      = "Choose which type of vCenter - OnPrem, VMware Cloud, Amazon, Google Cloud"
    $message    = ""
    $Options    = [System.Management.Automation.Host.ChoiceDescription[]] @("&OnPrem", "&VMC", "&AVS", "&GVCE" )
    $result     = $host.ui.PromptForChoice($title, $message, $options, 0) 
    switch ($result) {
        0 {  $vCenterType = "ONPREM"  }
        1 {  $vCenterType = "VMC"     }
        2 {  $vCenterType = "AVS"     }
        3 {  $vCenterType = "GVCE"    }
    }
}
Write-Host "vCenter Type set to " -ForegroundColor Cyan -NoNewline
Write-Host "$($vCenterType.ToUpper())"  -ForegroundColor GREEN
Write-Host

#EndRegion vCenter Type




#Region Connect to vCenter
if ($Global:DefaultVIServers) {
    Write-Host "WARNING: Already connected to $($Global:DefaultVIServers -join ",")! Continue? Existing connections will be terminated"  -ForegroundColor YELLOW
    $title      = "Do you want to continue? Press X to exit immediately, or C to continue"
    $message    = ""
    $PromptExit = New-Object System.Management.Automation.Host.ChoiceDescription "e&Xit", "Exit"
    $PromptCont = New-Object System.Management.Automation.Host.ChoiceDescription "&Continue", "Continue"
    $options    = [System.Management.Automation.Host.ChoiceDescription[]]($PromptExit, $PromptCont)
    $result     = $host.ui.PromptForChoice($title, $message, $options, -1) # -1 means no default choice so user HAS to hit C to continue; errant ENTER strokes will not automatically continue
    switch ($result) {
        0 {
              Write-Host ""
              Write-Host "Exiting..." -foregroundcolor Red
              Write-Host
              write-host $LineSepDashes
              exit
          }
        1 {
              Write-Host ""
              Write-Host "Continuing...Disconnecting from all vCenters" -foregroundcolor Green
              disconnect-viserver -server * -confirm:$False  
          } #No default needed--results from PromptForChoice can only be 0 or 1 in this case; Anything other then X or C will reprompt
    }
}

Write-Host "Connecting to vCenter at $vCenter." -ForeGroundColor Cyan
# If no credential file and no vCenter username/password provided then prompt for creds
if ($vCenterCredFile -and ( Test-Path $vCenterCredFile) ) {
    Write-Host "  > Credential file found! Connecting to vCenter" -ForegroundColor green
    $credential = Import-Clixml -Path $vCenterCredFile
    $vCenterParams = @{
        Server     = $vCenter
        Credential = $credential
    }
} elseif ($vCenterAdminUser -and $vCenterAdminPassword) {
    # Else if user is provided use the username and password
    Write-Host "  > User and password specified! Connecting to vCenter" -ForegroundColor green
    $vCenterParams = @{
        Server     = $vCenter
        Username   = $vCenterAdminUser
        Password   = $vCenterAdminPassword
    }
} elseif ($vCenterAdminUser) {
    write-Host "  > User specified! Prompting for Password" -ForegroundColor Yellow
    # If username provided but not password, prompt for password
    $credential = Get-Credential -UserName $vCenterAdminUser -Message "Please enter vCenter admin credentials" -Title "User account with Admin privs on vCenter to create Rubrik Role"
    $vCenterParams = @{
        Server     = $vCenter
        Credential = $credential
    }
} else {
    Write-Host "  > No credential file found, no user/pw specified on command line, please provide vCenter Admin credentials" -ForegroundColor Yellow
    $credential = Get-Credential -Message "Please enter vCenter admin credentials" -Title "User account with Admin privs on vCenter to create Rubrik Role"
    $vCenterParams = @{
        Server     = $vCenter
        Credential = $credential
    }
}

#Connect to vCenter
try { 
    Connect-VIServer @vCenterParams -ErrorAction stop | Out-Null
    Write-Host "  > Successfully connected to vCenter $vCenter" -ForegroundColor GREEN
} catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin]{
    Write-Host "  > ERROR! Login failed. Please confirm credentials and try again" -ForegroundColor Red
    Write-Host
    write-host $LineSepDashes
    exit
} catch {
    Write-Host "  > ERROR! Connect to vCenter failed. Possible issues:" -ForegroundColor Red
    Write-Host "     - Invalid Cert being ignored, set action via: "
    Write-Host "          Set-PowerCLIConfiguration -InvalidCertificateAction Ignore" -ForegroundColor Magenta
    Write-Host "     - Host not reachable. Confirm firewalls, etc"
    Write-Host $PSItem.Exception.Message -ForegroundColor RED
    Write-Host
    write-host $LineSepDashes
    exit
}
#EndRegion Connect to vCenter



#Region Role Name
if (! $RubrikRoleName){
    Write-Host "Name of vCenter Role name not specified on CLI. Please enter Role Name: " -foregroundcolor Yellow
    $RubrikRoleName = read-host "Rubrik vCenter Role Name [ Rubrik_Backup_Service ] "
    if ( [string]::IsNullOrEmpty($RubrikRoleName)  ) {
        $RubrikRoleName  = "Rubrik_Backup_Service"
    }
} else {
    Write-Host "Rubrik Role Name specified on Command Line"
}
Write-Host "Rubrik Role Name will be: " -nonewline 
Write-Host "$RubrikRoleName" -ForegroundColor GREEN
#EndRegion Role Name


# Rubrik Service Account User
# The Rubrik User account is a non-login, least-privileged, vCenter Server account that you specify during deployment.
if (! $CreateRoleOnly ) {
    $RubrikServiceAccountRegEx = "@"
    if (! $RubrikServiceAccount) {
        Write-Host "Rubrik Service Account not specified. Please enter account name in full format:" -ForegroundColor yellow
        Write-Host "  > Examples:  " -ForegroundColor yellow -NoNewline
        Write-Host "MYDOMAIN\RubrikSvcAcct      - AD account using NetBIOS name"  -ForegroundColor CYAN
        Write-Host "               vsphere.local\RubrikSvcAcct - VMware local SSO account" -ForegroundColor CYAN
        Write-Host "               NOTE: user must be in DOMAIN\user format" -ForegroundColor CYAN
        $RubrikServiceAccount = Read-Host "Rubrik Service Account "
    }
    if ($RubrikServiceAccount -match $RubrikServiceAccountRegEx) {
        Write-Host "ERROR! you specified the user in an incorrect format. Must be DOMAIN\user Please try again." -ForegroundColor Red
        $null = Disconnect-VIServer $vCenter -Confirm:$false
        EXIT
    }
    # Verify user exists. If does not exist, prompt to create role only or exit
    if (! $(Get-VIAccount -name $RubrikServiceAccount)) {
        Write-Host "ERROR! User specified ($RubrikServiceAccount) does not exist. " -ForegroundColor RED
        $title   = "Continue with creating role only?"
        $message = "Press X to exit immediately, or C to continue and create vCenter Role only: "
        $PromptExit = New-Object System.Management.Automation.Host.ChoiceDescription "e&Xit", "Exit"
        $PromptCont = New-Object System.Management.Automation.Host.ChoiceDescription "&Continue", "Continue"
        $options = [System.Management.Automation.Host.ChoiceDescription[]]($PromptExit, $PromptCont)
        $result = $host.ui.PromptForChoice($title, $message, $options, -1) # -1 means no default choice so user HAS to hit C to continue; errant ENTER strokes will not automatically continue
        switch ($result) {
            0 {
                Write-Host "Exiting" -ForegroundColor Red
                $null = Disconnect-VIServer $vCenter -Confirm:$false
                exit 
            }
            1 {
                Write-Host "Continuing with vCenter Role only" -foregroundcolor Green
                $CreateRoleOnly = $true
            } #No default needed--results from PromptForChoice can only be 0 or 1 in this case; Anything other then X or C will reprompt
        }
    }
}



#Set privleges based on vCenter Type
if ($vCenterType -eq 'ONPREM') {
  $Rubrik_Privileges = $Rubrik_OnPrem_Privileges
} 
else {
  $Rubrik_Privileges = $Rubrik_VMC_AVS_GCVE_Privileges
}

# Check vCenter version and add appropriate privileges
Write-Debug ('vCenter version is: ' + [System.Version]$Global:DefaultVIServer.Version)
if ([System.Version]$Global:DefaultVIServer.Version -ge [System.Version]"7.0.0") {
    Write-Debug 'Adding vCenter 7 privileges'
    $Rubrik_Privileges += $Rubrik_vCenter_7_Privileges
}

Write-Debug 'Effective privileges are:'
Write-Debug ($Rubrik_Privileges | Format-Table | Out-String)

# Create new role
Write-Host "Creating a new role called $RubrikRoleName " -ForeGroundColor Cyan 
try {
    #New-VIRole -Name $RubrikRoleName -Privilege (Get-VIPrivilege -id $Rubrik_Privileges) -ErrorAction stop | Out-Null
    $null = New-VIRole -Name $RubrikRoleName -Privilege (Get-VIPrivilege -id $Rubrik_Privileges) -ErrorAction stop 
} catch {
    Write-Host "ERROR Creating Role. Exiting" -ForegroundColor RED
    Write-Host "$($error[0].exception.message)" -ForegroundColor RED
    Write-Host
    write-host $LineSepDashes
    $null = Disconnect-VIServer $vCenter -Confirm:$false
    exit
}

#Exit if CreateRoleOnly specified
If ($CreateRoleOnly) {
    Write-Host "CreateRoleOnly specified on command line. Exiting." -ForegroundColor Yellow
    $null = Disconnect-VIServer $vCenter -Confirm:$false
    exit
}

#Get the Root Folder
$rootFolder = Get-Folder -NoRecursion
#Create the Permission
Write-Host "Granting permissions on object $rootFolder to $RubrikServiceAccount as role $RubrikRoleName with Propagation = $true" -ForeGroundColor Cyan
try {
   $null = New-VIPermission -Entity $rootFolder -Principal $RubrikServiceAccount -Role $RubrikRoleName -Propagate:$true -ErrorAction stop
} catch {
    Write-Host "ERROR Applying permissions at root. Exiting" -ForegroundColor RED
    Write-Host "$($error[0].exception.message)" -ForegroundColor RED
    Write-Host
    write-host $LineSepDashes
    $null = Disconnect-VIServer $vCenter -Confirm:$false
    Exit
}

#Disconnect from the vCenter Server
Write-Host "COMPLETE! Disconnecting from vCenter at $vCenter" -ForeGroundColor Cyan
$null = Disconnect-VIServer $vCenter -Confirm:$false
Write-Host
write-host $LineSepDashes
