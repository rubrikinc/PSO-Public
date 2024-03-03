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
    NOTE: Must be run from Windows
    NOTE: REQUIRES PS6 or greater due to Remote PSSessions and SSL download
    OPTIONAL: Run with ChangeRBSCredentialOnly switch at CLI to change user/pw on existing RBS installs only (no install)

    OPTIONAL: Can connect to RSC and automatically add host to specified cluster. Requires RSC service account XML file
    - Updated 2024.02.29 to use RubrikSecurityCloud PS module from PSGallery instead of custom built functions
    - Connect to RSC using pre-created RSC Service Account XML File (create using Set-RSCServiceAccountFile)
    - Queries RSC and returns list of connected clusters matching "RubrikCluster" string (can be a UUID of the cluster)
    - If no matches, exit
    - If multiple matches, prompt for which cluster
    - If using RSC method, RBS download will be from the IP of the first node in the cluster


.NOTES
    Updated 2023.08.26 by David Oslager for community usage
    - Updated 2024.02.29 to use RubrikSecurityCloud PS module from PSGallery instead of custom functions
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

.EXAMPLE
    Install-RBS-v2.ps1 -RubrikCluster rubrik01 -RBSCredential $RBSCredential -RSCserviceAccountXML .\path\to\SvcAcct.XML

    Connect to RSC and verify cluster name in RSC and it's connected. Then download RBS from IP of first node in cluster "rubrik01"
    and install RBS with RunAs using specified PSCredential Variable (must be defined, or will prompt for user/pw)

#>
#Requires -version 6.0
#Requires -modules RubrikSecurityCloud
[CmdletBinding()]                                # <-- Verbose and Debug enabled with the [CmdletBinding()] directive
param(
    #Rubrik Cluster name 
    # used to search for a match to name in RSC
    # or Cluster UUID (will look up cluster UUID in RSC)
    # or ip address/FQDN if not adding to RSC - used for direct HTTPS connection to download RBS zip package
    [string]$RubrikCluster,
    
    #Comma separated list of computer(s) that should have the Rubrik Backup Service installed
    [String]$ComputerName,

    #Credential to run the Rubrik Backup Service on the Windows Server - Can be username, gMSA, or "LocalSystem"
    [pscredential]$RBSCredential,

    #Username to connect with. If RBSPassword not included on command line, will prompt for password (Secure!)
    [string]$RBSUserName,

    #Optionally, can use username and password (clear text!) via command line. NOT RECOMMENDED
    [string]$RBSPassword,

    #Option to skip add RBSUserName to local administrators group
    #NOTE: Service Account user MUST be member of administrators group. ONLY Use this if user is already a member through nested groups
    [switch]$SkipAddToAdministratorsGroup,

    #Skip RBS install, change RBS user/pw only
    [switch]$ChangeRBSCredentialOnly,

    #Create rule to Open Windows Firewall ports (12800/12801 TCP)
    [switch]$OpenWindowsFirewall,

    #Local Location to store download of RBS
    [string]$Path = "c:\temp",

    # Path to Service account XML file
    [string] $RSCserviceAccountXML,

    # Shows details from RSC GraphQL searches-similar to Verbose, but without the builtin verbose statements, used for debugging
    [switch] $ShowDetails,

    # Create Log file of output
    [switch] $log,

    # Path to write log files. Creates folder if does not exist, defaults to .\Logs
    [string] $logpath = ".\Logs"
)

#Region Pre-Check
if (-not $IsWindows) {
    Write-Host "ERROR! must be run from Windows!" -ForegroundColor Red
    exit
}
#EndRegion


#Suppress progress bars from commands. Will set back to oldProgressPreference at end of script
$oldProgressPreference = $progressPreference; 
$progressPreference = 'SilentlyContinue'


#################################################################################################
#Region Define some constants, regexes, etc
#################################################################################################
$ScriptName           = $($MyInvocation.MyCommand)
$starttime            = Get-Date
$ValidGUIDRegex       = “^[{]?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}[}]?$” 
$dateformat           = 'yyyy-MM-ddTHH:mm:ss'     #ISO8601 time standard
$filedateFormat       = 'yyyy.MM.dd-HHmmss'       #Timestamp for files
$LineSepDashes        = "-" * 120
$LineSepEquals        = "=" * 120
$LineSepHashes        = "#" * 120
$LineSepDashesFull    = "-" * 142
$LineSepEqualsFull    = "=" * 142
$LineSepHashesFull    = "#" * 142
$SleepTime            = 15
$SleepTimeout         = 600

$LineIndentSpaces     = " " * 22

#################################################################################################
#EndRegion Define some constants, regexes, etc
#################################################################################################





#################################################################################################
#Region Functions
#################################################################################################
$CreateLogFolder_scriptBlock = {
    #Create folder for logging if not already exist
    if ($log){
        $script:Logfile="$LogPath\$((Get-Item $ScriptName).BaseName)-$($starttime.ToString($filedateFormat)).log"
        Write-MyLogger $LineSepHashesFull Cyan -NoTimeStamp
        Write-MyLogger "Logging enabled! Logging to $Logfile"
        If (! (Test-Path $LogPath) ) {
            Write-MyLogger "Creating folder for logs: $LogPath"  Green
            New-Item -ItemType Directory -Force -Path $LogPath | out-null
        } else {
            Write-MyLogger "Using existing folder for Logs: $LogPath"  Green
        }
    }
} #End CreateLogFolder_scriptBlock


$HeaderBlock_scriptBlock = {
    $PSBoundParametersString = $(($script:PSBoundParameters | Format-Table -auto | Out-String) -replace "`n", "`n         ")
    #Header block on ouput
    Write-MyLogger $LineSepHashesFull Cyan -NoTimeStamp
    Write-MyLogger "" -NoTimeStamp 
    Write-MyLogger "     $ScriptName - $($starttime.ToString($dateformat))" CYAN -NoTimeStamp 
    Write-MyLogger "" -NoTimeStamp 
    Write-MyLogger "     Bound Parameters: $PSBoundParametersString" -NoTimeStamp 
    Write-MyLogger $LineSepHashesFull Cyan -NoTimeStamp
} #End HeaderBlock_scriptBlock


$EndSummary_scriptBlock = {
    Write-MyLogger $LineSepHashesFull CYAN -NoTimeStamp
    Write-MyLogger "$ScriptName Script Complete"
    Write-MyLogger "    Start time    : $($starttime.ToString($dateformat))"
    Write-MyLogger "    End Time      : $(Get-Date -format $dateFormat)"
    $elapsedtime = new-timespan -start $starttime -end $(Get-Date)
    Write-MyLogger "$("    Elapsed Time  : " + $('{0:00}:{1:00}:{2:00}' -f $elapsedtime.hours,$elapsedtime.Minutes,$elapsedtime.Seconds) )"
    Write-MyLogger $LineSepHashesFull CYAN -NoTimeStamp
    Write-MyLogger -NoTimeStamp
    Write-MyLogger -NoTimeStamp
} #End EndSummary_scriptBlock

Function Write-MyLogger {
    param(
        [String] $message,
        [Alias('ForegroundColor')]
        [String] $color = "white",
        #[string] $LogFile,
        [switch] $NoNewLine,
        [switch] $NoTimeStamp
    )

    <# EXAMPLE USAGE:
    Stardard Logged output to screen using Write-Host
    Output can change color, white is default if not specified

    Write-MyLogger "Starting script now....hold on!" Cyan
    Output: 
    2022-04-06T18:58:27 : Starting script now....hold on!

    #>

    $timeStamp = Get-Date -format $dateformat
    if ($noTimeStamp) {
        $logMessage = $message
    }
    else {
        Write-Host -NoNewline -ForegroundColor White "$timestamp : "
        $logMessage = "[$timeStamp] $message"
    }
    if ($NoNewLine) {
        Write-Host -ForegroundColor $color "$message" -NoNewLine
    }
    else {
        Write-Host -ForegroundColor $color "$message"
    }
    if ($LogFile) {
        #$logMessage | out-string | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' } | Out-File -Append -filePath $LogFile
        $logMessage | out-string | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' } | Add-Content -Path $LogFile -NoNewline
    }        
} #end Write-MyLogger



function New-Host(){
    param(
        [string[]]$inputHost,
        [string]$ClusterUuid
    )
    $hostsToAdd = [System.Collections.ArrayList]::new()
    foreach($item in $inputHost){
        $HostnameToAdd = @{"hostname"=$item}
        $hostsToAdd.add($HostnameToAdd) | Out-Null
    }
    $QueryString = '
    mutation AddPhysicalHostMutation(
        $clusterUuid: String!
        $hosts: [HostRegisterInput!]!
        ) {
            bulkRegisterHost(input: {clusterUuid: $clusterUuid, hosts: $hosts}) {
                data {
                    hostSummary {
                        id
                    }
                }
            }
        }'
    $variables = @{
        clusterUuid = $clusteruuid
        hosts       = $hostsToAdd
    }
    $response = Invoke-Rsc -GqlQuery $QueryString -Var $variables
    return $response
} #End Function New-Host




#EndRegion Functions



#################################################################################################
#Region Main Script
#################################################################################################
& $CreateLogFolder_scriptBlock
& $HeaderBlock_scriptBlock


#prompt for RSCserviceAccountXML
If ($RSCserviceAccountXML) {
    Write-MyLogger "RSCserviceAccountXML specified on command line: $RSCserviceAccountXML" GREEN
} elseif ( $RubrikCluster ) {
    Write-MyLogger "RubrikCluster IP/DNS specified on command line: $RubrikCluster" GREEN
} else {
    Write-MyLogger "No RSCserviceAccountXML Specified on Command Line." Yellow -NoTimeStamp
    Write-MyLogger "  Enter path to RSC XML file to automatically add the windows host to RSC," Yellow -NoTimeStamp
    Write-MyLogger "  or leave blank to continue to skip RSC and automatic registration" Yellow -NoTimeStamp
    $RSCserviceAccountXML = Read-Host -Prompt "Please enter path to RSC Svc Acct XML file"
    write-host
}

#Region RubrikCluster
if ($ChangeRBSCredentialOnly) {
    Write-MyLogger "Change RBS Credential Only specified on command line. Skipping RBS download" GREEN
} elseif ($null -ne $RSCserviceAccountXML -and $RSCserviceAccountXML -ne "") {
    #connect to RSC
    #################################################################################################
    #Region Connect to RSC
    #First confirm we can read the XML file
    try {
        $XMLContent = Get-Content $RSCserviceAccountXML
    }
    catch {
        Write-MyLogger "Service Account XML is not valid, please verify and retru" RED
        exit
    }

    #Try to connect to RSC
    try {
        $connection = Connect-RSC -ServiceAccountFile $RSCserviceAccountXML
    } catch {
        Write-MyLogger "Failed to authenticate, check the contents of the service account XML, and ensure proper permissions are granted" RED
        exit
    }
    Write-MyLogger $LineSepHashesFull Cyan -NoTimeStamp
    #EndRegion Connect to RSC


    #################################################################################################
    #Region Get list of Rubrik clusters from RSC
    #region QueryString and Vars
    $QueryString = '
    query AllClusterConnection($filter: ClusterFilterInput, $sortOrder: SortOrder, $sortBy: ClusterSortByEnum) {
        allClusterConnection(filter: $filter, sortOrder: $sortOrder, sortBy: $sortBy) {
        nodes {
            name
            id
            status
            defaultAddress
            clusterNodeConnection {
                nodes {
                    ipAddress
                }
            }
        }
        }
    }
    '
    $variables = @{
        last      = $null
        sortOrder = "ASC"
        sortBy    = "ClusterName"
        filter    = @{
            name            = $RubrikCluster
            connectionState = "Connected"
            excludeId       = "00000000-0000-0000-0000-000000000000"
        }
    }
    #Endregion QueryString and Vars

    if ($RubrikCluster -match $ValidGUIDRegex) {
        Write-MyLogger "Rubrik Cluster name matches GUID. Searching by ID instead of name" Yellow
        $variables.filter.remove("name")
        $variables.filter.add("id",$RubrikCluster)
    }

    try {
        Write-MyLogger "Querying RSC for list of clusters"
        $RSCRubrikClusters_temp = (Invoke-RSC -GqlQuery $QueryString -Var $variables).nodes
    } catch {
        Write-MyLogger "There was an error querying RSC. Exiting. Please try again" RED
        exit
    }

    #Create object of cluster info from above query
    Write-MyLogger "Verifying cluster is in RSC"
    $RSCRubrikClusters = @()
    foreach ($RSCRubrikCluster_temp in $RSCRubrikClusters_temp) {
        $RSCRubrikCluster = New-Object -Type PSObject
        $RSCRubrikCluster | Add-Member -Type NoteProperty -Name "Name"           -Value $RSCRubrikCluster_temp.Name
        $RSCRubrikCluster | Add-Member -Type NoteProperty -Name "DefaultAddress" -Value $RSCRubrikCluster_temp.DefaultAddress
        $RSCRubrikCluster | Add-Member -Type NoteProperty -Name "Status"         -Value $RSCRubrikCluster_temp.Status
        $RSCRubrikCluster | Add-Member -Type NoteProperty -Name "UUID"           -Value $RSCRubrikCluster_temp.id
        $RSCRubrikCluster | Add-Member -Type NoteProperty -Name "IPAddress"      -Value $RSCRubrikCluster_temp.clusterNodeConnection.Nodes.ipAddress
        if ($RSCRubrikCluster_temp.clusterNodeConnection.Nodes.ipAddress -is [array] ) {
            $RSCRubrikCluster | Add-Member -Type NoteProperty -Name "IPAddress0" -Value $RSCRubrikCluster_temp.clusterNodeConnection.Nodes.ipAddress[0]
        } else {
            $RSCRubrikCluster | Add-Member -Type NoteProperty -Name "IPAddress0" -Value $RSCRubrikCluster_temp.clusterNodeConnection.Nodes.ipAddress
        }
        $RSCRubrikClusters += $RSCRubrikCluster
    }

    #ouput table - kinda like verbose w/o being verbose
    if ($ShowDetails) {
        Write-MyLogger $LineSepDashesFull
        foreach ($RSCRubrikCluster in $RSCRubrikClusters) {
            $i = $RSCRubrikClusters.IndexOf($RSCRubrikCluster)
            Write-MyLogger "RSCCluster[$i].Name             = $($RSCRubrikCluster.Name)" CYAN
            Write-MyLogger "RSCCluster[$i].DefaultAddress   = $($RSCRubrikCluster.DefaultAddress)" CYAN
            Write-MyLogger "RSCCluster[$i].Status           = $($RSCRubrikCluster.Status)" CYAN
            Write-MyLogger "RSCCluster[$i].UUID             = $($RSCRubrikCluster.UUID)" CYAN
            Write-MyLogger "RSCCluster[$i].IPAddress        = $($RSCRubrikCluster.IPAddress)" CYAN
            Write-MyLogger "RSCCluster[$i].IPAddress0       = $($RSCRubrikCluster.IPAddress0)" CYAN
            Write-MyLogger $LineSepDashesFull
        }
    }

    #Find the right cluster based on input
    if ($RscRubrikClusters.count -eq 0) {
        Write-myLogger "Error! No cluster found matching the name/ID ""$RubrikCluster"". Please verify and try again" RED
        exit
    } elseif ($RSCRubrikClusters.count -eq 1) {
        if ($RubrikCluster -match $ValidGUIDRegex) {
            Write-MyLogger "Found Cluster with ID $RubrikCluster and name of $($RSCRubrikClusters.Name)"
            $RubrikCluster = $RSCRubrikClusters.Name
        } else {
            Write-MyLogger "Found Cluster named ""$RubrikCluster"""
        }
        $RubrikClusterObject = $RSCRubrikClusters
    } else {
        if ($RubrikCluster) {
            Write-MyLogger "Multiple Clusters matching ""$RubrikCluster"" found. Please choose which cluster" YELLOW
        } else {
            Write-MyLogger "Multiple Clusters found. Please choose which cluster" YELLOW
        }
        Write-MyLogger -NoTimeStamp
        #create pretty table with cluster names and info for use to pick from interactively
        #Calculate width of each column based on max length, and then calculate total length as sum of all columns
        $len_digits         = (@($RSCRubrikClusters.count.tostring().length,3) | Measure-object -maximum).Maximum
        $len_name           = ($RSCRubrikClusters.name           | measure-object -maximum -property length).maximum
        $len_DefaultAddress = ($RSCRubrikClusters.DefaultAddress | measure-object -maximum -property length).maximum
        #$len_Status         = ($RSCRubrikClusters.Status         | measure-object -maximum -property length).maximum
        $len_Status         = 12 #Had to change this because using Invoke-RSC returns as a value, not as a string
        $len_UUID           = ($RSCRubrikClusters.UUID           | measure-object -maximum -property length).maximum
        $len_IPAddress0     = ($RSCRubrikClusters.IPAddress0     | measure-object -maximum -property length).maximum
        $len_total          = ($len_digits + $len_name + $len_DefaultAddress + $len_Status + $len_UUID + $len_IPAddress0 + 16)

        #Output column headers and line separators
        Write-MyLogger $("-" * $len_total) -NoTimeStamp
        Write-MyLogger ("{0,$($len_digits)}  {1,-$len_name}   {2,-$len_DefaultAddress}   {3,-$len_Status}   {4,-$len_UUID}   {5,-$len_IPAddress0}" -f "Num", "Name", "DefaultAddress", "Status", "UUID", "IPAddress[0]") -NoTimeStamp
        Write-MyLogger $("-" * $len_total) -NoTimeStamp

        $i=1
        foreach ($RSCRubrikCluster in $RSCRubrikClusters) {
            # Output Table with number in first column for user to pick from
            Write-MyLogger ("{0,$($len_digits)}  {1,-$len_name}   {2,-$len_DefaultAddress}   {3,-$len_Status}   {4,-$len_UUID}   {5,-$len_IPAddress0}" -f $i, $RSCRubrikCluster.Name, $RSCRubrikCluster.DefaultAddress, $RSCRubrikCluster.Status, $RSCRubrikCluster.UUID, $RSCRubrikCluster.IPAddress0) -NoTimeStamp
            $i++
        }
        Write-MyLogger $("-" * $len_total) -NoTimeStamp

        do {
            try {
                $SelectedIndex=(Read-Host -Prompt "Select Cluster Number" -erroraction stop).ToInt32($null) 
            } catch {
                Write-MyLogger "Not a proper response. Pick a number from the NUM column. Please try again" RED -NoTimeStamp 
            }
        } while ($SelectedIndex -notin (1..$($RSCRubrikClusters.count)))

        $RubrikClusterObject = $RSCRubrikClusters[$SelectedIndex-1]
        #Write-MyLogger "You selected $($RubrikClusterObjectname)"
        Write-MyLogger -NoTimeStamp

    }
    Write-MyLogger $LineSepDashes
    $RubrikClusterObject | Format-List *
    Write-MyLogger $LineSepDashes
    #$RBSDownloadURL =  "https://$($RubrikClusterObjectIPAddress0)/connector/RubrikBackupService.zip"
    #Write-MyLogger "URL: $RBSDownloadURL"
    #EndRegion Get a list of clusters from RSC
    $RubrikCluster = $RubrikClusterObject.Name
} else {
    #No RSCserviceAccountXML
    If ($RubrikCluster) {
        Write-MyLogger "Rubrik Cluster specified: $RubrikCluster" GREEN
    } else {
        Write-MyLogger "ERROR! Rubrik cluster not specified on command line for RBS Download" RED -NoTimeStamp
        $RubrikCluster = Read-Host -Prompt "Please enter Rubrik Cluster DNS Name or IP to download RBS from"
        write-host
    }
}
#EndRegion RubrikCluster


#Region ComputerName(s)
if ($ComputerName) {
    Write-MyLogger "Target computers: $($computername -join ',')" GREEN
} else {
    if ($ChangeRBSCredentialOnly) {
        Write-MyLogger "ERROR! List of target computers to change RBS user/pw not provided on command line" RED -NoTimeStamp
    } else {
        Write-MyLogger "ERROR! List of target computers to install RBS not provided on command line" RED -NoTimeStamp
    }
    $ComputerName = Read-HOst -Prompt "Please enter list of computers, comma separated" 
    write-host
}
#EndRegion ComputerName(s)


#Region User/Pw/Creds
if ( $RBSCredential -and ($RBSCredential.GetType().Name -eq "PSCredential") ){
    #Credential supplied via command line and var type is a PSCredential
    Write-MyLogger "Credential specified. (user: $($RBSCredential.UserName))" CYAN
} elseif ( $RBSCredential ) {
    #Variable is defined, but not a proper PScredential - Ignore and re-prompt
    Write-MyLogger "Credential entered on CLI, but not a proper PScredential. Prompting for credential" CYAN -NoTimeStamp
    Write-MyLogger "Enter user name and password for the service account that will run the Rubrik Backup Service" Cyan -NoTimeStamp
    $RBSCredential = Get-Credential -title "Rubrik Service Account"
} elseif ( $RBSUserName -match "^LocalSystem$|^Local System$") {
    # Run as LocalSystem - no password needed
    $RBSUserName = "LocalSystem" 
    $RBSPassword = $null
} elseif ( $RBSUserName -and $RBSPassword ){
    Write-MyLogger "Username and password specified via CLI, creating Credential" Cyan
    # Convert Cleartext from CLI to SecureString
    [securestring]$secStringPassword = ConvertTo-SecureString $RBSPassword -AsPlainText -Force
    [pscredential]$RBSCredential     = New-Object System.Management.Automation.PSCredential ($RBSUserName, $secStringPassword)
} elseif ( $RBSUserName ) {
    #UserName only supplied on CLI, prompt for password
    Write-MyLogger "Enter password for the service account ($RBSUserName) that will run the Rubrik Backup Service" Cyan -NoTimeStamp
    $RBSCredential = Get-Credential  -title "Rubrik Service Account"-UserName $RBSUserName -Message "Enter Service Account password or blank/enter for Group Managed Svc Acct (gMSA)"
} else {
    #Nothing supplied - prompt for user/pw
    Write-MyLogger "User/Password not specified on CLI...prompting for credential." Cyan -NoTimeStamp
    Write-MyLogger "  > NOTE: For default of ""LocalSystem"" enter ""LocalSystem"" with a blank password"  Cyan -NoTimeStamp
    Write-MyLogger "  > NOTE: For gMSA accounts, enter DOMAIN\UserName with a blank password" Cyan -NoTimeStamp
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
Write-MyLogger $LineSepHashesFull CYAN -NoTimeStamp


#region Download the Rubrik Connector 
#forcing PS6+ with the Requires at the top of the script. 
#Do not want to use PS 5.x and dealing with SSL self signed certs
#additional steps to invoke-command better run on PS7
if (-not $ChangeRBSCredentialOnly) {
    if (-not (test-path  $Path) ) {
        $null = New-Item -Path $Path -ItemType Directory 
    }
    #If using RSC to register, use the first IP from the cluster (cant guarantee name in RSC is resolvable)
    #If not using RSC, then just use the value from input of cluster (could be DNS or IP)
    if ($RubrikClusterObject) {
        $url =  "https://$($RubrikClusterObject.IPAddress0)/connector/RubrikBackupService.zip"
    } else {
        $url =  "https://$($RubrikCluster)/connector/RubrikBackupService.zip"
    }
    $OutFile = "$Path\RubrikBackupService.zip"

    Write-MyLogger "Downloading RBS zip file from $url" CYAN
    Write-MyLogger "Saving as $OutFile" CYAN

    #Set progress to none - Invoke-Webrequest is annoying and lingers over the CLI after it is complete
    $oldProgressPreference = $progressPreference; 
    $progressPreference = 'SilentlyContinue'
    try {
        $null = Invoke-WebRequest -Uri $url -OutFile $OutFile -SkipCertificateCheck
    } catch {
        Write-MyLogger "ERROR! Could not download RBS zip file from $RubrikCluster. Please verify connectivity" Red
        exit 1
    }
    #Set ProgressPref back to what it was before we did IWR
    $progressPreference = $oldProgressPreference 
    Write-MyLogger "Expanding RBS locally to c:\Temp\RubrikBackupService\" CYAN
    Expand-Archive -LiteralPath $OutFile -DestinationPath "$path\RubrikBackupService" -Force
}
#endregion




##############################################################################################################
#Region Loop Through Computer List
foreach($Computer in $($ComputerName -split ',')){
    Write-MyLogger $LineSepDashes
    Write-MyLogger "Testing connectivity to $Computer to WinRM port/service (TCP5985). Please wait." CYAN
    #if ((Test-Connection -ComputerName $Computer -Count 3 -quiet -ErrorAction SilentlyContinue)) {
    #Using Test-NetConnection (Windows only) to verify WinRM port is open and service running, which is what Invoke-Command uses
    #NOT using Ping incase it is disabled; no ping != unavailable
    if ( Test-NetConnection -ComputerName $computer -CommonTCPPort winrm -InformationLevel quiet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) {
        Write-MyLogger "  > $Computer is reachable - will attempt to install/modify RBS" GREEN
    } else {
        Write-MyLogger "  > $Computer is not reachable, the RBS will not be installed/modified on this server!" RED
        continue
    }  

    if ($ChangeRBSCredentialOnly){
        Write-MyLogger "Changing RBS Password on " CYAN -NoNewline 
    } else {
        Write-MyLogger "Starting Install of RBS on " CYAN -NoNewline 
    }
    Write-MyLogger "$Computer" GREEN -NoNewline -NoTimeStamp
    Write-MyLogger ". Please wait..." CYAN -NoTimeStamp

    #region Copy RBS files, Install RBS, Delete RBS Files
    if (-not $ChangeRBSCredentialOnly) {
        #region Copy the RubrikBackupService files to the remote computer
        Write-MyLogger "Copying RBS files to $Computer. Please wait" CYAN
        try {
            Invoke-Command -ComputerName $Computer -ScriptBlock { 
                New-Item -Path "C:\Temp\RubrikBackupService" -type directory -Force | out-null
            }
            $Session = New-PSSession -ComputerName $Computer 
            foreach ($file in Get-ChildItem C:\Temp\RubrikBackupService) {
                Write-MyLogger "  > Copying $file to $computer"
                Copy-Item -ToSession $Session $file -Destination C:\Temp\RubrikBackupService | out-Null
            }
            Remove-PSSession -Session $Session
        } catch {
            Write-MyLogger "ERROR! There was an error copying the RBS to $Computer. Skipping install on this computer. Please try manually" RED
            #Write-MyLogger "$($error[0].exception.message)" RED
            Write-MyLogger $LineSepDashes
            continue
        }
        #endregion



        #Region Install the RBS on the Remote Computer
        Write-MyLogger "Installing RBS on $Computer. Please wait" CYAN
        $Session = New-PSSession -ComputerName $Computer 
        try {
            Invoke-Command -Session $Session -ScriptBlock {
                Start-Process -FilePath "C:\Temp\RubrikBackupService\RubrikBackupService.msi" -ArgumentList "/quiet" -Wait
                #added sleep to give a few extra seconds for service to install/start on it's own
                sleep 3
            }        
        } catch {
            Write-MyLogger "ERROR! There was an error installing RBS to $Computer. Please try manually" RED
            #Write-MyLogger "$($error[0].exception.message)" RED
            Write-MyLogger $LineSepDashes
            continue    
        }
        Remove-PSSession -Session $Session
        #EndRegion Install the RBS on the Remote Computer



        #Region remove RBS files
        Write-MyLogger "Deleting RBS files on $Computer. Please wait" CYAN
        try {
            Invoke-Command -ComputerName $Computer -ScriptBlock { 
                Remove-Item -Path "C:\Temp\RubrikBackupService" -recurse -Force | out-null
            }
        } catch {
            Write-MyLogger "ERROR! There was an error removing RBS installer files. Please try manually" RED
            #Write-MyLogger "$($error[0].exception.message)" RED
            Write-MyLogger $LineSepDashes
            continue
        }
        #EndRegion Remove RBS Files
    }
    #EndRegion Copy RBS files, Install RBS, Delete RBS Files


    #Region Set Run as user. Skip if RBSUserName=LocalSystem
    if ($RBSUserName -eq "LocalSystem") {
        Write-MyLogger "Running Rubrik Backup Service as LocalSystem" CYAN
    } else {
        #Region adding username to administrators on remote computer
        if ($SkipAddToAdministratorsGroup) {
            Write-MyLogger "Skipping adding user $RBSUserName to administrators group" Yellow
        } else {
            Start-Sleep 5
            Write-MyLogger "Adding $RBSUserName to administrators on $computer" Cyan
            try {
                Invoke-Command -ComputerName $Computer -ScriptBlock { 
                    param ($user)
                    if ( $(Get-LocalGroupMember administrators).name -contains $user) {
                        Write-Host "$using:LineIndentSpaces  > User $user is already a member of the Administrators Group. Nothing to do" -ForegroundColor GREEN
                    } else {
                        Add-LocalGroupMember -Group "Administrators" -Member $user
                    }
                } -ArgumentList $RBSUserName
            } catch {
                Write-MyLogger "ERROR! Could not add $RBSUserName to $Computer\Administrators. Please check manually" RED
                continue
            }
        }
        #EndRegion adding username to administrators on remote computer


        #Region Setting SeServiceLoginRight on remote computer to allow run as a service
        #From: https://stackoverflow.com/questions/313831/using-powershell-how-do-i-grant-log-on-as-service-to-an-account
        Write-MyLogger "Granting ""Log on as a Service"" to $RBSUserName on $computer" Cyan
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
                    Write-Host "$using:LineIndentSpaces  > Exporting Local Policy to temp file"
                    secedit /export /cfg $export | out-null
                    $sids = (Select-String $export -Pattern "SeServiceLogonRight").Line
                    if ($sids -match $sid) {
                        Write-Host "$using:LineIndentSpaces  > User currently granted SeServiceLoginRight - Nothing to do!" -ForegroundColor GREEN
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
                        Write-Host "$using:LineIndentSpaces  > Importing Local Policy with updated SeServiceLoginRight"
                        secedit /import /db $secedt /cfg $import | out-null
                        Write-Host "$using:LineIndentSpaces  > Applying modified Local Policy"
                        secedit /configure /db $secedt | out-null
                        Write-Host "$using:LineIndentSpaces  > Refreshing Group Policy to apply updates to Local Policy"
                        gpupdate /force | out-null                    
                        Remove-Item -Path $import -Force | out-null
                        Remove-Item -Path $secedt -Force | out-null
                    }
                    Remove-Item -Path $export -Force | out-null
                } catch {
                    Write-MyLogger ("Failed to grant SeServiceLogonRight to user account: {0} on host: {1}." -f $username, $computerName) RED
                    $error[0]
                }
            } -ArgumentList ($RBSUserName, $computer)        
        } catch {
            Write-MyLogger "ERROR! Could not add $RBSUserName to $Computer ""Log on as a Service"". Please check manually" RED
            continue
        }
        #EndRegion Setting SeServiceLoginRight on remote computer to allow run as a service
    }
    #EndRegion Set Run as user. Skip if RBSUserName=LocalSystem



    #Region OpenFirewall ports (windows builtin firewall only)
    if ($OpenWindowsFirewall) {
        #WARNING: Opens Windows Firewall to all IPs
        try {
            Write-MyLogger "Adding Firewall Rule for 12800/12801 TCP from any remote IP on all profiles"  Cyan
            Invoke-Command -ComputerName $Computer -ScriptBlock { 
                $RBSFirewallRule = @{
                    DisplayName  = "Rubrik Backup Service"
                    Profile      = @('Domain', 'Private', 'Public') 
                    Direction    = 'Inbound'
                    Action       = 'Allow'
                    Protocol     = 'TCP'
                    LocalPort    = @(12800, 12801)
                }
                if ( Get-NetFirewallRule | Where-Object { $_.displayname -match $RBSFirewallRule.DisplayName } ){
                    Write-Host "$using:LineIndentSpaces  > WARNING! Rule named $($RBSFirewallRule.DisplayName) already exists. Please check manually" -ForegroundColor YELLOW
                } else {
                    $result = New-NetFirewallRule @RBSFirewallRule
                }
            } 
        } catch {
            Write-MyLogger "ERROR! Could not open windows firewall ports (12800/12801TCP). Please check manually" RED
            continue
        }
    }
    #EndRegion OpenFirewall ports (windows firewall only)



    #Region RBSUserName=LocalSystem
    if ( $RBSUserName -eq "LocalSystem" -and -not $ChangeRBSCredentialOnly ) {
        Write-MyLogger "RBSUserName set to LocalSystem. Nothing to do" GREEN
    } else {
        #Set Service to run as RBSUserName/RBSPassword
        Write-MyLogger "Setting service to run as $RBSusername on $Computer" CYAN
        try {
            Get-CimInstance Win32_Service -computer $Computer -Filter "Name='Rubrik Backup Service'" | Invoke-CimMethod -MethodName Change -Arguments @{ StartName = $RBSusername; StartPassword = $RBSPassword } | out-null
        } catch {
            Write-MyLogger "ERROR! Did not set the username $RBSUserName properly on $Computer. Please check manually"
            continue
        }        
        #Restart RBS for new credentials to take effect
        Start-Sleep 5
        Write-MyLogger "Restarting RBS service on $computer" Cyan
        try {
            Invoke-Command -ComputerName $Computer -ScriptBlock { 
                get-service "rubrik backup service" | Stop-Service 
                Start-Sleep 2
                get-service "rubrik backup service" | Start-Service
            }
        } catch {
            Write-MyLogger "ERROR! Could not restart service properly on $Computer. Please check manually"
            continue
        }
    }
    #EndRegion ChangeRBSCredentials *and* RBSUserName=LocalSystem



    #Region Add Windows Host to RSC
    if ($RubrikClusterObject -and -not $ChangeRBSCredentialOnly) {
        Write-MyLogger "Adding Host to RSC via API" CYAN
        $result = New-Host -inputHost $Computer -ClusterUuid $RubrikClusterObject.UUID
        if ($result.errors) {
            Write-MyLogger "ERROR! Could not add host $Computer to Rubrik Cluster $($RubrikClusterObject.Name)"
            Write-MyLogger "RSC Response: `n$LineIndentSpaces  $($result.errors.message)"
        } else {
            Write-MyLogger "Success! Added host $Computer to Rubrik Cluster $($RubrikClusterObject.Name)" GREEN
            Write-MyLogger "  > RSC Object ID: " GREEN -NoNewLine
            Write-MyLogger "$($result.data[0].hostSummary.id)" white -NoTimeStamp
        }
    }
    #endRegion Add Windows Host to RSC


    if ($ChangeRBSCredentialOnly) {
        Write-MyLogger "Changing RBS Credentials on " -NoNewline CYAN
    } else {
        Write-MyLogger "Install of RBS on " -NoNewline CYAN
    }
    Write-MyLogger "$computer complete" GREEN -NoTimeStamp
} 
#EndRegion Loop Through Computer List

#Cleanup RBS downloads from $path folder (ie C:\Temp)
if (-not $ChangeRBSCredentialOnly) {
    Remove-Item -Path $OutFile -Force | out-null
    Remove-Item -Path "$path\RubrikBackupService" -Force -recurse | out-null
}



Write-MyLogger $LineSepHashesFull Cyan -NoTimeStamp
#################################################################################################
#Script Complete
Write-MyLogger "Script Complete!" GREEN
If ($log) {
    Write-MyLogger "Log file can be found at $logfile" GREEN
}
#Disconnect from RSC, if connected
if ($RSCserviceAccountXML) {
    Write-MyLogger "Disconnecting from RSC" GREEN
    Disconnect-Rsc | out-null
}
& $EndSummary_scriptBlock
$progressPreference = $oldProgressPreference 

#EndRegion Main Script