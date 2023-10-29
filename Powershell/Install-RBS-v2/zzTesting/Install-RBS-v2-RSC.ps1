
[CmdletBinding()]                                # <-- Verbose and Debug enabled with the [CmdletBinding()] directive
param(
    #Quantity (int) of records to query (default = 50)
    [int]    $QueryQuantity = 50,

    #Name of Rubrik Cluster to connect to via RSC
    #[Parameter(Mandatory=$true)]
    [string] $RubrikCluster,


    [string] $WindowsHost = "app-chi102.lab.local",


    # Path to Service account JSON file
    #[Parameter(Mandatory=$true)]
    [string] $RSCserviceAccountJSON,

    # Shows details from RSC GraphQL searches like Verbose, but without the builtin verbose statements
    [switch] $ShowDetails,

    # Create Log file of output
    [switch] $log,

    # Path to write log files. Creates folder if does not exist, defaults to .\Logs
    [string] $logpath = ".\Logs"
)


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

#################################################################################################
#EndRegion Define some constants, regexes, etc
#################################################################################################







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



function Connect-RSC {
    [CmdletBinding()]
    param (    
        [Parameter(Mandatory)]
        [String]
        #Service account file from Rubrik Security Cloud with permissions to handle M365 operations
        $serviceAccountFile
    )

    #The following lines are for brokering the connection to RSC
    #Test the service account json for valid json content
    try {
        Get-Content $serviceAccountFile | ConvertFrom-Json | out-null
    }
    catch {
        Write-MyLogger "Service Account Json is not valid, please redownload from Rubrik Security Cloud" RED
        exit
    }

    #Convert the service account json to a PowerShell object
    $serviceAccountJson = Get-Content $serviceAccountFile | convertfrom-json

    #Create headers for the initial connection to RSC
    $headers = @{
        'Content-Type' = 'application/json';
        'Accept'       = 'application/json';
    }

    #Create payload to send for authentication to RSC
    $payload = @{
        grant_type    = "client_credentials";
        client_id     = $serviceAccountJson.client_id;
        client_secret = $serviceAccountJson.client_secret
    } 

    #Try to send payload through to RSC to get bearer token
    try {
        $response = Invoke-RestMethod -Method POST -Uri $serviceAccountJson.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers    
    }
    catch {
        Write-MyLogger "Failed to authenticate, check the contents of the service account json, and ensure proper permissions are granted" RED
        exit
    }

    #Create connection object for all subsequent calls with bearer token
    $connection = [PSCustomObject]@{
        headers  = @{
            'Content-Type'  = 'application/json';
            'Accept'        = 'application/json';
            'Authorization' = $('Bearer ' + $response.access_token);
        }
        endpoint = $serviceAccountJson.access_token_uri.Replace('/api/client_token', '/api/graphql')
    }
    #End brokering to RSC
    Write-MyLogger "Authentication to RSC succeeded" GREEN
    $global:connection = $connection
    return $connection
} #end Connect-RSC


function Get-RSCRubrikData {
    param (
        #Payload to pass to GraphQL Query
        [hashtable]$Payload,
        [string]   $QueryType = "nodes",
        [string]   $QueryDescription = "data",
        [switch]   $silent
    )
    if (-not $silent) {
        Write-MyLogger "Querying RSC for $QueryDescription....please wait"
    }
    $data = [System.Collections.ArrayList]::new()
    $response = Invoke-RestMethod  @ConnectToRSCParams -Body $($payload | ConvertTo-JSON -Depth 100) 
    $QueryName = $response.data.psobject.properties.name
    if ($ShowDetails) {write-mylogger "QueryName = $QueryName" MAGENTA}
    foreach ($item in $response.data.$QueryName.$QueryType) {
        $data.add($item) | out-null
    }
    while ($response.data.$QueryName.pageInfo.hasNextPage) {
        #if (-not $silent) {
            Write-MyLogger " > Grabbed a page of data, grabbing another"
        #}
        $payload.variables.after = $response.data.$QueryName.pageinfo.endCursor
        $response = Invoke-RestMethod  @ConnectToRSCParams -Body $($payload | ConvertTo-JSON -Depth 100) 
        foreach ($item in $response.data.$QueryName.$QueryType) {
            $data.add($item) | out-null
        }
    }
    return $data

} #end Get-RSCRubrikData












#################################################################################################
#Region Main Script
#################################################################################################



#################################################################################################
#Region Connect to RSC, create Splat of common params
$connection = Connect-RSC -serviceAccountFile $RSCserviceAccountJSON
$ConnectToRSCParams = @{
  Method  = 'POST'
  Uri     = $connection.endpoint 
  Headers = $connection.headers
}
#EndRegion Connect to RSC
Write-MyLogger $LineSepHashesFull Cyan -NoTimeStamp





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

#$QueryQuantity = 50
$variables = @{
    first     = $QueryQuantity
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

$Payload = @{
    query     = $QueryString
    variables = $variables
}
$RSCRubrikClusters_temp = Get-RSCRubrikData -Payload $Payload -QueryDescription "list of Rubrik Clusters"
Write-MyLogger "Verifying cluster is in RSC: "
#$RSCRubrikClusters = $RSCRubrikClusters_temp | Select Name, DefaultAddress, Status, @{N="UUID";E={$_.id}}, @{N="IPAddress"; E={$_.clusterNodeConnection.Nodes.ipAddress}}
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

if ($RscRubrikClusters.count -eq 0) {
    Write-myLogger "Error! No cluster found matching the name ""$RubrikCluster"". Please verify and try again" RED
    exit
} elseif ($RSCRubrikClusters.count -eq 1) {
    Write-MyLogger "Found Cluster named ""$RubrikCluster"""
    $RubrikClusterObject = $RSCRubrikClusters
} else {
    if ($RubrikCluster) {
        Write-MyLogger "Multiple Clusters matching ""$RubrikCluster"" found. Please choose which cluster" YELLOW
    } else {
        Write-MyLogger "Multiple Clusters found. Please choose which cluster" YELLOW
    }
    Write-MyLogger -NoTimeStamp
    #Calculate width of each column based on max length, and then calculate total length as sum of all columns
    $len_digits         = (@($RSCRubrikClusters.count.tostring().length,3) | Measure-object -maximum).Maximum
    $len_name           = ($RSCRubrikClusters.name           | measure-object -maximum -property length).maximum
    $len_DefaultAddress = ($RSCRubrikClusters.DefaultAddress | measure-object -maximum -property length).maximum
    $len_Status         = ($RSCRubrikClusters.Status         | measure-object -maximum -property length).maximum
    $len_UUID           = ($RSCRubrikClusters.UUID           | measure-object -maximum -property length).maximum
    $len_IPAddress0     = ($RSCRubrikClusters.IPAddress0     | measure-object -maximum -property length).maximum
    $len_total          = ($len_digits + $len_name + $len_DefaultAddress + $len_Status + $len_UUID + $len_IPAddress0 + 16)

    #Output column headers and line separators
    Write-MyLogger $("-" * $len_total) -NoTimeStamp
    Write-MyLogger ("{0,$($len_digits)}   {1,-$len_name}   {2,-$len_DefaultAddress}   {3,-$len_Status}   {4,-$len_UUID}   {5,-$len_IPAddress0}" -f "Num", "Name", "DefaultAddress", "Status", "UUID", "IPAddress[0]") -NoTimeStamp
    Write-MyLogger $("-" * $len_total) -NoTimeStamp

    $i=1
    foreach ($RSCRubrikCluster in $RSCRubrikClusters) {
        # Output Table with number in first column for user to pick from
        Write-MyLogger ("{0,$($len_digits+1)}  {1,-$len_name}   {2,-$len_DefaultAddress}   {3,-$len_Status}   {4,-$len_UUID}   {5,-$len_IPAddress0}" -f $i, $RSCRubrikCluster.Name, $RSCRubrikCluster.DefaultAddress, $RSCRubrikCluster.Status, $RSCRubrikCluster.UUID, $RSCRubrikCluster.IPAddress0) -NoTimeStamp
        $i++
    }
    Write-MyLogger $("-" * $len_total) -NoTimeStamp

    do {
        try {
            $SelectedIndex=(Read-Host -Prompt "Select a Cluster" -erroraction stop).ToInt32($null) 
        } catch {
            Write-MyLogger "Not a proper response. Please try again" RED -NoTimeStamp 
        }
    } while ($SelectedIndex -notin (1..$($RSCRubrikClusters.count)))

    $RubrikClusterObject = $RSCRubrikClusters[$SelectedIndex-1]
    #Write-MyLogger "You selected $($RubrikClusterObjectname)"
    Write-MyLogger -NoTimeStamp

}
Write-MyLogger $LineSepDashes
$RubrikClusterObject | Format-List *
Write-MyLogger $LineSepDashes
$RBSDownloadURL =  "https://$($RubrikClusterObjectIPAddress0)/connector/RubrikBackupService.zip"
Write-MyLogger "URL: $RBSDownloadURL"
#EndRegion Get a list of clusters from RSC







function New-Host(){
    param(
        [string[]]$inputHost,
        [string]$ClusterUuid
    )
    $hostsToAdd = [System.Collections.ArrayList]::new()
    foreach($item in $inputHost){
        $this = @{"hostname"=$item}
        $hostsToAdd.add($this) | Out-Null
    }
    $payload = @{
        query = 'mutation AddPhysicalHostMutation(
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
        variables = @{
            clusterUuid = $clusteruuid
            hosts       = $hostsToAdd
        }
    }
    $response = Invoke-RestMethod @ConnectToRSCParams -Body $($payload | ConvertTo-JSON -Depth 100)
    return $response
}


#Region Add Windows Host to RSC
Write-MyLogger $LineSepDashesFull
Write-MyLogger "Adding Hosts to RSC"
$result = New-Host -inputHost $WindowsHost -ClusterUuid $RubrikClusterObjectUUID

if ($result.errors) {
    Write-MyLogger "ERROR! Could not add host $WindowsHost to Rubrik Cluster $($RubrikClusterObjectName)"
    Write-MyLogger "RSC Response: `n$($result.errors.message)"
} else {
    Write-MyLogger "Success! Added host $WindowsHost to Rubrik Cluster $($RubrikClusterObjectName) with id $($result.data.bulkRegisterHost.data[0].hostSummary.id)"
}

Write-MyLogger $LineSepDashesFull
Write-MyLogger $LineSepDashesFull
Write-MyLogger $LineSepDashesFull
Write-MyLogger "Script Complete!" GREEN
Write-MyLogger $LineSepDashesFull



#EndRegion Add Windows Host to RSC
