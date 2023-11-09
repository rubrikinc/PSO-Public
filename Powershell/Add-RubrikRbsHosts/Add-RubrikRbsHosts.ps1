<#
.DESCRIPTION
    Adds Rubrik host(s) to a Rubrik cluster.

.PARAMETER ServiceAccountFilepath
    Path to the JSON file containing the client credentials and the access token URI. Obtained from Rubrik Security Cloud. 

.PARAMETER HostListFilepath
    Path to flat file containing list of hostnames used to add hosts.

.EXAMPLE
    Add hosts to Rubriik cluster.
    PS C:\> .\Add-RubrikRbsHosts.ps1 `
    -ServiceAccountFilepath ServiceAccount.json `
    -HostListFilepath RbsHostnames.txt

.INPUTS
    Input (if any)

.OUTPUTS
    Output (if any)

.NOTES
    Name:       Add RBS Host to Rubrik Cluster
    Created:    10/18/2023
    Author:     Rubrik PSO

    Supported for CDM 8.1+
#>
[cmdletbinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ServiceAccountFilepath,

    [Parameter(Mandatory=$true, Position=1)]
    [string]$HostListFilepath
)

#region Functions
function Write-Log() {
    param (
        $message,
        [switch]$isError,
        [switch]$isSuccess,
        [switch]$isWarning
    )
    $color = 'blue'
    if($isError){
        $message = 'ERROR: ' + $message
        $color = 'red'
    } elseif($isSuccess){
        $message = 'SUCCESS: ' + $message
        $color = 'green'
    } elseif($isWarning){
        $message = 'WARNING: ' + $message
        $color = 'yellow'
    }
    $message = "$(get-date) $message"
    Write-Host("$message$($PSStyle.Reset)") -BackgroundColor $color
    $message | out-file log.txt -append
    if($isError){
        exit
    }
}

function Connect-RSC{
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
        Write-Log -message 'Service Account Json is not valid, please redownload from Rubrik Security Cloud' -isError
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
        grant_type = "client_credentials";
        client_id = $serviceAccountJson.client_id;
        client_secret = $serviceAccountJson.client_secret
    } 

    #Try to send payload through to RSC to get bearer token
    try {
        $response = Invoke-RestMethod -Method POST -Uri $serviceAccountJson.access_token_uri -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $headers    
    }
    catch {
        Write-Log -message "Failed to authenticate, check the contents of the service account json, and ensure proper permissions are granted" -isError
    }

    #Create connection object for all subsequent calls with bearer token
    $connection = [PSCustomObject]@{
        headers = @{
            'Content-Type'  = 'application/json';
            'Accept'        = 'application/json';
            'Authorization' = $('Bearer ' + $response.access_token);
        }
        endpoint = $serviceAccountJson.access_token_uri.Replace('/api/client_token', '/api/graphql')
    }
    #End brokering to RSC
    Write-Log -message 'Authentication to RSC succeeded'
    $global:connection = $connection
    return $connection
}

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
            "hosts" = $hostsToAdd
        }
    }
    $response = Invoke-RestMethod -Method POST -Uri $connection.endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $connection.headers
    return $response
}

function Select-RubrikCluster(){
    $payload = @{
        query = 'query ClusterListTableQuery {
            clusterConnection {
                edges {
                node {
                    id
                    name
                }
                }
            }
        }'
    }
    $response = Invoke-RestMethod -Method POST -Uri $connection.endpoint -Body $($payload | ConvertTo-JSON -Depth 100) -Headers $connection.headers
    $clusters = $response.data.clusterConnection.edges
    for ($i = 0; $i -lt $clusters.Count; $i++) {
        Write-Host "$($i + 1): $($clusters[$i].node.name)"
    }
    $selectedClusterIndex = Read-Host "`nSelect Cluster"
    return $clusters[$selectedClusterIndex - 1].node
}
#endregion

#region Main code block
# Connect to RSC
Write-Host -ForegroundColor Yellow "`n============= Connecting to Rubrik Security Cloud =============="
$connection = Connect-RSC -ServiceAccountFile $ServiceAccountFilePath

# Select Rubrik cluster to perform task on
Write-Host -ForegroundColor Yellow "`n============= Select Rubrik Cluster =============="
$SelectedCluster = Select-RubrikCluster

# Load array with RBS client hostnames
Write-Host -ForegroundColor Yellow "`n============= Listing RBS Hosts to Add to Rubrik Cluster =============="
[string[]]$HostList = Get-Content -Path $HostListFilepath
    for ($i = 0; $i -lt $HostList.Count; $i++) {
        Write-Host "$($i + 1): $($HostList[$i])"
    }

# Register RBS hosts to Rubrik cluster
Write-Host -ForegroundColor Yellow "`n============= Adding RBS Hosts to Rubrik Cluster =============="
$HostAddResponse = New-Host -inputHost $HostList -ClusterUuid $SelectedCluster.id
if ($HostAddResponse.data) {
    Write-Host -ForegroundColor Blue "`Host Add(s) SUCESSFUL. See output below below."
}
elseif ($HostAddResponse.errors) {
    Write-Host -ForegroundColor Red "`Host Add(s) FAILED. See error below and correct input."
}
Write-Host $($HostAddResponse | ConvertTo-JSON -Depth 100)
#endregion