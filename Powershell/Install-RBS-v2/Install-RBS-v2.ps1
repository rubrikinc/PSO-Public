<#
.SYNOPSIS
    Install Rubrik Backup Service from a specific cluster to a list of Windows Computers

.DESCRIPTION
    Install Rubrik Backup Service from a specific cluster to a list of Windows Computers. 
    Run with any combination of command line arguments. Script will prompt for anything not on CLI. 
    - Downloads RBS from specified cluster and extracts file. 
    - Copies to each server and remotely installs RBS (in order of input, one at a time) 
    - Deletes RBS files on remote computers
    - Grants service account "Log on as a service" on remote server
    - Sets service to run as specified user account and restarts service. 
         OPTIONAL: Can specify "LocalSystem" as user account for built in "LocalSystem" Account
    NOTE: REQUIRES PS6 or greater due to Remote PSSessions and SSL download
    OPTIONAL: Run with ChangeRBSCredentialOnly switch at CLI to change user/pw on existing RBS installs only (no install)

.NOTES
    Updated 2023.08.26 by David Oslager for community usage
    GitHub: doslagerRubrik
    Originally based on Install-RubrikBackupService.ps1 by Chris Lumnah
    https://github.com/rubrikinc/rubrik-scripts-for-powershell/blob/master/RBS/Install-RubrikBackupService.ps1

.EXAMPLE
    Install-RBS-v2.ps1 

    Install RBS remotely and prompt for all of the variables.

.EXAMPLE
    Install-RBS-v2.ps1 -ComputerName "server1.domain.com,server2.domain.com,server3.domain.com"

    Install RBS on computerName one at a time - Must be comma separated, and the entire string in quotes
    Prompt for Rubrik Cluster and credential info

.EXAMPLE
    Install-RBS-v2.ps1 -RubrikCluster rubrik01.domain.com -RBSUserName DOMAIN\svc-RubrikRBS -RBSPassword P@ssw0rd123

    Install RBS from Cluster "rubrik01.domain.com" using specified Username and Password (WARNING! Cleartext on commandline)

.EXAMPLE
    Install-RBS-v2.ps1 -RubrikCluster rubrik01.domain.com -RBSCredential $RBSCredential

    Install RBS from Cluster "rubrik01.domain.com" using specified PSCredential Variable (must be defined, or will prompt for user/pw)

#>
#Requires -version 6.0
[CmdletBinding()]                                # <-- Verbose and Debug enabled with the [CmdletBinding()] directive
param(
    #Rubrik Cluster name or ip address
    [string]$RubrikCluster,
    
    #Comma separated list of computer(s) that should have the Rubrik Backup Service installed onto and then added into Rubrik 
    [String]$ComputerName,

    #Credential to run the Rubrik Backup Service on the Computer
    [pscredential]$RBSCredential,

    #Username to connect with. If RBSPassword not included on command line, will prompt for password (Secure!)
    [string]$RBSUserName,

    #Optionally, can use username and password (clear text!) via command line. NOT RECOMMENDED
    [string]$RBSPassword,

    #Skip RBS install, change RBS user/pw only
    [switch]$ChangeRBSCredentialOnly,

    #Create rule to Open Windows Firewall ports (12800/12801 TCP)
    [switch]$OpenWindowsFirewall,

    #Local Location to store download of RBS
    [string]$Path = "c:\temp"
)

#Region Pre-Check and constants
if (-not $IsWindows) {
    Write-Host "ERROR! must be run from Windows!" -ForegroundColor Red
    exit
}
$dateformat    = 'yyyy-MM-ddTHH:mm:ss'     #ISO8601 time standard
$LineSepDashes = "-" * 150
#EndRegion



#################################################################################################
#Region Functions
#################################################################################################
Function Restart-RBS {
    Param (
        [string]$computer
    )
    #Region Restarting Service on remote computer
    Start-Sleep 5
    Write-Host "Restarting RBS service on $computer" -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName $Computer -ScriptBlock { 
            get-service "rubrik backup service" | Stop-Service 
            Start-Sleep 2
            get-service "rubrik backup service" | Start-Service
        }
    } catch {
        Write-Host "ERROR! Could not restart service properly on $Computer. Please check manually"
        continue
    }
    #EndRegion Restarting Service on remote computer        
}

Function Set-ServiceRunAs {
    Param (
        [string]$Computer,
        [string]$RBSUserName,
        [string]$RBSPassword
    )
    Write-Host "Setting service to run as $RBSusername on $Computer" -ForegroundColor CYAN
    try {
        Get-CimInstance Win32_Service -computer $Computer -Filter "Name='Rubrik Backup Service'" | Invoke-CimMethod -MethodName Change -Arguments @{ StartName = $RBSusername; StartPassword = $RBSPassword } | out-null
    } catch {
        Write-Host "ERROR! Did not set the username $RBSUserName properly on $Computer. Please check manually"
        continue
    }        
}
#EndRegion Functions



#################################################################################################
# Begin Main Script
#################################################################################################
write-host $LineSepDashes
Write-Host "Starting Install-RBS-v2.ps1 - $(Get-Date -format $dateformat)" -ForegroundColor GREEN
write-host $LineSepDashes

#Region RubrikCluster
if (-not $ChangeRBSCredentialOnly) {
    If ($RubrikCluster) {
        Write-Host "Rubrik Cluster specified: $RubrikCluster" -ForegroundColor GREEN
    } else {
        Write-Host "ERROR! Rubrik cluster not specified on command line for RBS Download" -ForegroundColor RED
        $RubrikCluster = Read-Host -Prompt "Please enter Rubrik Cluster Name or IP to download RBS from"
        write-host
    }
} else {
    Write-Host "Change RBS Credential Only specified on command line. Skipping RBS download" -ForegroundColor GREEN
}
#EndRegion RubrikCluster


#Region ComputerName(s)
if ($ComputerName) {
    Write-Host "Target computers: $($computername -join ',')" -ForegroundColor GREEN
} else {
    if ($ChangeRBSCredentialOnly) {
        Write-Host "ERROR! List of target computers to change RBS user/pw not provided on command line" -ForegroundColor RED
    } else {
        Write-Host "ERROR! List of target computers to install RBS not provided on command line" -ForegroundColor RED
    }
    $ComputerName = Read-HOst -Prompt "Please enter list of computers, comma separated" 
    write-host
}
#EndRegion ComputerName(s)


#Region User/Pw/Creds
if ( $RBSCredential -and ($RBSCredential.GetType().Name -eq "PSCredential") ){
    #Credential supplied via command line and var type is a PSCredential
    Write-Host "Credential specified." -ForegroundColor CYAN
} elseif ( $RBSCredential ) {
    #Variable is defined, but not a proper PScredential - Ignore and re-prompt
    Write-Host "Credential entered on CLI, but not a proper PScredential. Prompting for credential" -ForegroundColor CYAN
    Write-Host "Enter user name and password for the service account that will run the Rubrik Backup Service" -ForegroundColor Cyan
    $RBSCredential = Get-Credential -title "Rubrik Service Account"
} elseif ( $RBSUserName -match "^LocalSystem$|^Local System$") {
    # Run as LocalSystem - no password needed
    $RBSUserName = "LocalSystem" 
    $RBSPassword = $null
} elseif ( $RBSUserName -and $RBSPassword ){
    Write-Host "Username and password specified via CLI, creating Credential" -ForegroundColor Cyan
    # Convert Cleartext from CLI to SecureString
    [securestring]$secStringPassword = ConvertTo-SecureString $RBSPassword -AsPlainText -Force
    [pscredential]$RBSCredential     = New-Object System.Management.Automation.PSCredential ($RBSUserName, $secStringPassword)
} elseif ( $RBSUserName ) {
    #UserName only supplied on CLI, prompt for password
    Write-Host "Enter password for the service account ($RBSUserName) that will run the Rubrik Backup Service" -ForegroundColor Cyan
    $RBSCredential = Get-Credential  -title "Rubrik Service Account"-UserName $RBSUserName -Message "Enter Service Account password or blank/enter for Group Managed Svc Acct (gMSA)"
} else {
    #Nothing supplied - prompt for user/pw
    Write-Host "User/Password not specified on CLI...prompting for credential." -ForegroundColor Cyan
    Write-Host "  > NOTE: Enter ""LocalSystem"" with a blank password for default"  -ForegroundColor Cyan
    Write-Host "  > NOTE: For gMSA accounts, enter DOMAIN\UserName with a blank password" -ForegroundColor Cyan
    $RBSCredential = Get-Credential -title "Enter user name and password for the service account that will run the Rubrik Backup Service" 
}

#Pull the user and password back out of the credential
if ($RBSUserName -ne "LocalSystem") {
    $RBSUsername = $($RBSCredential.UserName)
    $RBSPassword = $($RBSCredential.GetNetworkCredential().Password)
    Write-Verbose "RBS Username:  $RBSUsername"
    Write-Verbose "RBS Password:  $RBSPassword"    
}
#EndRegion User/Pw/Creds
write-host $LineSepDashes


#region Download the Rubrik Connector 
#forcing PS6+ with the Requires at the top of the script. 
#Do not want to use PS 5.x and dealing with SSL self signed certs
#additional steps to invoke-command better run on PS7
if (-not $ChangeRBSCredentialOnly) {
    if (-not (test-path  $Path) ) {
        $null = New-Item -Path $Path -ItemType Directory 
    }
    $url =  "https://$($RubrikCluster)/connector/RubrikBackupService.zip"
    $OutFile = "$Path\RubrikBackupService.zip"

    Write-Host "Downloading RBS zip file from $url" -ForegroundColor CYAN
    write-Host "Saving as $OutFile" -ForegroundColor CYAN

    #Set progress to none - Invoke-Webrequest is annoying and lingers over the CLI after it is complete
    $oldProgressPreference = $progressPreference; 
    $progressPreference = 'SilentlyContinue'
    try {
        $null = Invoke-WebRequest -Uri $url -OutFile $OutFile -SkipCertificateCheck
    } catch {
        Write-Host "ERROR! Could not download RBS zip file from $RubrikCluster. Please verify connectivity" -ForegroundColor Red
        exit 1
    }
    #Set ProgressPref back to what it was before we did IWR
    $progressPreference = $oldProgressPreference 
    Write-Host "Expanding RBS locally to c:\Temp\RubrikBackupService\" -ForegroundColor CYAN
    Expand-Archive -LiteralPath $OutFile -DestinationPath "$path\RubrikBackupService" -Force
    write-host $LineSepDashes
}
#endregion

#Region Validate the Servername(s) and if it is online
write-Host "Testing connectivity to each target server. Please wait." -ForegroundColor CYAN
$ValidComputerList=@()
foreach( $Computer in $($ComputerName -split ',') ) {
    if ((Test-Connection -ComputerName $Computer -Count 3 -quiet -ErrorAction SilentlyContinue)) {
        Write-Host "$Computer is reachable - will attempt to install/modify RBS" -ForegroundColor GREEN
        $ValidComputerList +=$Computer
    } else {
        Write-Host "  > $Computer is not reachable, the RBS will not be installed/modified on this server!" -ForegroundColor RED
    }  
}
write-host $LineSepDashes
#EndRegion Validate the Servername(s) and if it is online



##############################################################################################################
#Region Loop Through Computer List
foreach($Computer in $ValidComputerList){
    if ($ChangeRBSCredentialOnly){
        Write-Host "Changing RBS Password on " -ForegroundColor CYAN -NoNewline 
    } else {
        Write-Host "Starting Install of RBS on " -ForegroundColor CYAN -NoNewline 
    }
    Write-Host "$Computer" -ForegroundColor GREEN -NoNewline
    Write-Host ". Please wait - $(Get-Date -format $dateformat)" -ForegroundColor CYAN

    #region Copy RBS files, Install RBS, Delete RBS Files
    if (-not $ChangeRBSCredentialOnly) {
        #region Copy the RubrikBackupService files to the remote computer
        Write-Host "Copying RBS files to $Computer. Please wait" -ForegroundColor CYAN
        try {
            Invoke-Command -ComputerName $Computer -ScriptBlock { 
                New-Item -Path "C:\Temp\RubrikBackupService" -type directory -Force | out-null
            }
            $Session = New-PSSession -ComputerName $Computer 
            foreach ($file in Get-ChildItem C:\Temp\RubrikBackupService) {
                write-host "  > Copying $file to $computer"
                Copy-Item -ToSession $Session $file -Destination C:\Temp\RubrikBackupService | out-Null
            }
            Remove-PSSession -Session $Session
        } catch {
            Write-Host "ERROR! There was an error copying the RBS to $Computer. Skipping install on this computer. Please try manually" -ForegroundColor RED
            #Write-Host "$($error[0].exception.message)" -ForegroundColor RED
            write-host $LineSepDashes
            continue
        }
        #endregion



        #Region Install the RBS on the Remote Computer
        Write-Host "Installing RBS on $Computer. Please wait" -ForegroundColor CYAN
        $Session = New-PSSession -ComputerName $Computer 
        try {
            Invoke-Command -Session $Session -ScriptBlock {
                Start-Process -FilePath "C:\Temp\RubrikBackupService\RubrikBackupService.msi" -ArgumentList "/quiet" -Wait
            }        
        } catch {
            Write-Host "ERROR! There was an error installing RBS to $Computer. Please try manually" -ForegroundColor RED
            #Write-Host "$($error[0].exception.message)" -ForegroundColor RED
            write-host $LineSepDashes
            continue    
        }
        Remove-PSSession -Session $Session
        #EndRegion Install the RBS on the Remote Computer



        #Region remove RBS files
        Write-Host "Deleting RBS files on $Computer. Please wait" -ForegroundColor CYAN
        try {
            Invoke-Command -ComputerName $Computer -ScriptBlock { 
                Remove-Item -Path "C:\Temp\RubrikBackupService" -recurse -Force | out-null
            }
        } catch {
            Write-Host "ERROR! There was an error removing RBS installer files. Please try manually" -ForegroundColor RED
            #Write-Host "$($error[0].exception.message)" -ForegroundColor RED
            write-host $LineSepDashes
            continue
        }
        #EndRegion Remove RBS Files
    }
    #EndRegion Copy RBS files, Install RBS, Delete RBS Files


    #Region Set Run as user. Skip if RBSUserName=LocalSystem
    if ($RBSUserName -eq "LocalSystem") {
        Write-Host "Running Rubrik Backup Service as LocalSystem" -ForegroundColor CYAN
    } else {
        #Region adding username to administrators on remote computer
        Start-Sleep 5
        Write-Host "Adding $RBSUserName to administrators on $computer" -ForegroundColor Cyan
        try {
            Invoke-Command -ComputerName $Computer -ScriptBlock { 
                param ($user)
                if ( $(Get-LocalGroupMember administrators).name -contains $user) {
                    Write-Host "  > User $user is already a member of the Administrators Group. Nothing to do" -ForegroundColor GREEN
                } else {
                    Add-LocalGroupMember -Group "Administrators" -Member $user
                }
            } -ArgumentList $RBSUserName
        } catch {
            Write-Host "ERROR! Could not add $RBSUserName to $Computer\Administrators. Please check manually" -ForegroundColor RED
            continue
        }
        #EndRegion Restarting Service on remote computer


        #Region Setting SeServiceLoginRight on remote computer to allow run as a service
        #From: https://stackoverflow.com/questions/313831/using-powershell-how-do-i-grant-log-on-as-service-to-an-account
        Write-Host "Granting ""Log on as a Service"" to $RBSUserName on $computer" -ForegroundColor Cyan
        try {
            Invoke-Command -ComputerName $computer -Script {
                param(
                    [string] $username,
                    [string] $computerName
                )
                $tempPath = [System.IO.Path]::GetTempPath()
                $import = Join-Path -Path $tempPath -ChildPath "import.inf"
                if(Test-Path $import) { Remove-Item -Path $import -Force }
                $export = Join-Path -Path $tempPath -ChildPath "export.inf"
                if(Test-Path $export) { Remove-Item -Path $export -Force }
                $secedt = Join-Path -Path $tempPath -ChildPath "secedt.sdb"
                if(Test-Path $secedt) { Remove-Item -Path $secedt -Force }
                try {
                    #Write-Host ("  > Granting SeServiceLogonRight to user account: {0} on host: {1}." -f $username, $computerName)
                    $sid = ((New-Object System.Security.Principal.NTAccount($username)).Translate([System.Security.Principal.SecurityIdentifier])).Value
                    Write-Host "  > Exporting Local Policy to temp file"
                    secedit /export /cfg $export | out-null
                    $sids = (Select-String $export -Pattern "SeServiceLogonRight").Line
                    if ($sids -match $sid) {
                        Write-Host "  > User currently granted SeServiceLoginRight - Nothing to do!" -ForegroundColor GREEN
                    } else {
                        foreach ($line in @("[Unicode]", 
                                            "Unicode=yes", 
                                            "[System Access]", 
                                            "[Event Audit]", 
                                            "[Registry Values]", 
                                            "[Version]", 
                                            "signature=`"`$CHICAGO$`"", 
                                            "Revision=1", 
                                            "[Profile Description]", 
                                            "Description=GrantLogOnAsAService security template", 
                                            "[Privilege Rights]", 
                                            "$sids,*$sid")){
                            Add-Content $import $line
                        }
                        Write-Host "  > Importing Local Policy with updated SeServiceLoginRight"
                        secedit /import /db $secedt /cfg $import | out-null
                        Write-Host "  > Applying modified Local Policy"
                        secedit /configure /db $secedt | out-null
                        Write-Host "  > Refreshing Group Policy to apply updates to Local Policy"
                        gpupdate /force | out-null                    
                        Remove-Item -Path $import -Force | out-null
                        Remove-Item -Path $secedt -Force | out-null
                    }
                    Remove-Item -Path $export -Force | out-null
                } catch {
                    Write-Host ("Failed to grant SeServiceLogonRight to user account: {0} on host: {1}." -f $username, $computerName) -ForegroundColor RED
                    $error[0]
                }
            } -ArgumentList ($RBSUserName, $computer)        
        } catch {
            Write-Host "ERROR! Could not add $RBSUserName to $Computer ""Log on as a Service"". Please check manually" -ForegroundColor RED
            continue
        }
        #EndRegion Setting SeServiceLoginRight on remote computer to allow run as a service
    }
    #EndRegion Set Run as user. Skip if RBSUserName=LocalSystem



    #Region OpenFirewall ports (windows builtin firewall only)
    if ($OpenWindowsFirewall) {
        #WARNING: Opens Windows Firewall to all IPs
        try {
            Invoke-Command -ComputerName $Computer -ScriptBlock { 
                Write-Host "Adding Firewall Rule for 12800/12801 TCP from any remote IP on all profiles"  -ForegroundColor Cyan
                $RBSFirewallRule = @{
                    DisplayName  = "Rubrik Backup Service"
                    Profile      = @('Domain', 'Private', 'Public') 
                    Direction    = 'Inbound'
                    Action       = 'Allow'
                    Protocol     = 'TCP'
                    LocalPort    = @(12800, 12801)
                }
                if ( Get-NetFirewallRule | Where-Object { $_.displayname -match $RBSFirewallRule.DisplayName } ){
                    Write-Host "  > WARNING! Rule named $($RBSFirewallRule.DisplayName) already exists. Please check manually" -ForegroundColor YELLOW
                } else {
                    $result = New-NetFirewallRule @RBSFirewallRule
                }
            } 
        } catch {
            Write-Host "ERROR! Could not open windows firewall ports (12800/12801TCP). Please check manually" -ForegroundColor RED
            continue
        }
    }
    #EndRegion OpenFirewall ports (windows firewall only)



    #Region RBSUserName=LocalSystem
    if ( $RBSUserName -eq "LocalSystem" -and -not $ChangeRBSCredentialOnly ) {
        Write-Host "RBSUserName set to LocalSystem. Nothing to do" -ForegroundColor GREEN
    } else {
        #Set Service to run as RBSUserName/RBSPassword
        Set-ServiceRunAs -Computer $Computer -RBSUserName $RBSUserName -RBSPassword $RBSPassword

        #Restart RBS for new credentials to take effect
        Restart-RBS -computer $Computer
    }
    #EndRegion ChangeRBSCredentials *and* RBSUserName=LocalSystem

    
    if ($ChangeRBSCredentialOnly) {
        Write-Host "Changing RBS Credentials " -NoNewline -ForegroundColor CYAN
    } else {
        Write-Host "Install of RBS " -NoNewline -ForegroundColor CYAN
    }
    Write-Host "on $computer complete - $(Get-Date -format $dateformat)" -ForegroundColor GREEN
    write-host $LineSepDashes

} 
#EndRegion Loop Through Computer List

#Cleanup RBS downloads from $path folder (ie C:\Temp)
if (-not $ChangeRBSCredentialOnly) {
    Remove-Item -Path $OutFile -Force | out-null
    Remove-Item -Path "$path\RubrikBackupService" -Force -recurse | out-null
}

Write-Host "Script complete - $(Get-Date -format $dateformat)" -ForegroundColor Green
