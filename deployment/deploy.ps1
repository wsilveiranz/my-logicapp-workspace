Write-Output "Starting Logic App deployment"

$subscriptionId = "80d4fe69-c95b-4dd2-a938-9250f1c8ab03"
$resourceGroup = "WSilveira-Sandbox"
$location = "australiaeast"
$logicAppName = "mylogicapp"
$localLogicAppName = "LogicApps"
$TARGET = "$env:HOME\site\wwwroot"
$tempDeployPath = Join-Path $TARGET ".temp_deploy"

$currentDir = Split-Path -Path $PSScriptRoot -Parent
$currentDir = Join-Path $currentDir $localLogicAppName
Set-Location -Path $currentDir

# ============================================
# 1. Get access token
# ============================================
Write-Output "Getting access token"

$identityEndpoint = $env:IDENTITY_ENDPOINT
$identityHeader = $env:IDENTITY_HEADER
$clientId = "049ae8b1-3432-4cd5-8b9c-9dc225048f18"
$resource = "https://management.azure.com/"

$uriBuilder = New-Object System.UriBuilder($identityEndpoint)
$uriBuilder.Query = "api-version=2019-08-01&resource=$resource&client_id=$clientId"
$tokenUrl = $uriBuilder.Uri.AbsoluteUri

$response = Invoke-RestMethod -Method GET `
    -Uri $tokenUrl `
    -Headers @{ "X-IDENTITY-HEADER" = $identityHeader }
$accessToken = $response.access_token
if (-not $accessToken) {
    Write-Error "ERROR: Failed to authenticate with user-assigned managed identity."
    exit 1
}

# ============================================
# 2. Update app settings
# ============================================
Write-Output "Updating app settings"

# Get existing app settings
$listUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$logicAppName/config/appsettings/list?api-version=2022-03-01"
$headers = @{
    Authorization = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

$currentAppSettingsResponse = Invoke-RestMethod -Method POST `
    -uri $listUri `
    -Headers $headers
if (-not $currentAppSettingsResponse -or -not $currentAppSettingsResponse.properties) {
    Write-Error "ERROR: App settings response is null or missing 'properties'."
    exit 1
}

$currentSettings = @{}
$currentAppSettingsResponse.properties.PSObject.Properties | ForEach-Object {
    $currentSettings[$_.Name] = $_.Value
}

# Combine with new settings
$appSettingsJsonPath = Join-Path $currentDir "cloud.settings.json"
$appSettingsJson = Get-Content -Path $appSettingsJsonPath -Raw
$appSettings = $appSettingsJson | ConvertFrom-Json

$appSettings.Values.PSObject.Properties | ForEach-Object {
    $currentSettings[$_.Name] = $_.Value
}

# Update app settings
$putUri  = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$logicAppName/config/appsettings?api-version=2022-03-01"
$body = @{
    properties = $currentSettings
} | ConvertTo-Json -Compress
$updateAppSettingsResponse = Invoke-RestMethod -Method PUT `
    -uri $putUri `
    -Headers $headers `
    -Body $body
if (-not $updateAppSettingsResponse) {
    Write-Error "ERROR: Failed to update app settings."
    exit 1
}

# ============================================
# 3. Update connection ACLs
# ============================================

# Get managed API connections from connections.json
$connectionsJsonPath = Join-Path $currentDir "connections.json"
$hasConnections = Test-Path $connectionsJsonPath

if ($hasConnections) {
    Write-Output "Updating access policies for existing connections"

    $connectionsJson = Get-Content -Path $connectionsJsonPath -Raw
    $connections = $connectionsJson | ConvertFrom-Json

    # Get logic app system-assigned identity info
    $logicAppUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/${logicAppName}?api-version=2022-03-01"
    $logicAppInfo = Invoke-RestMethod -Method GET `
        -Uri $logicAppUri `
        -Headers $headers
    $principalId = $logicAppInfo.identity.principalId
    $tenantId = $logicAppInfo.identity.tenantId
    $accessPolicyName = "$logicAppName-$principalId"

    $connections.managedApiConnections.PSObject.Properties | ForEach-Object {
        $connectionName = $_.Name
        $connection = $_.Value

        Write-Output "-Updating connection '$connectionName'"

        $headers = @{ Authorization = "Bearer $accessToken" }

        # Get connection info
        $deployedConnectionName = ($connection.connection.id -split "/")[-1]
        $connectionUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/connections/${deployedConnectionName}?api-version=2016-06-01"
        $connectionInfo = Invoke-RestMethod -Method GET `
            -Uri $connectionUri `
            -Headers $headers `
            -ContentType "application/json"

        # Set access policy
        $accessPolicyUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Web/connections/$deployedConnectionName/accessPolicies/${accessPolicyName}?api-version=2018-07-01-preview"
        $headers = @{
            Authorization = "Bearer $accessToken"
            "Content-Type" = "application/json"
        }
        $body = @{
            name = $accessPolicyName
            type = "Microsoft.Web/connections/accessPolicy"
            location = $connectionInfo.location
            properties = @{
                principal = @{
                    type = "ActiveDirectory"
                    identity = @{
                        objectId = $principalId
                        tenantId = $tenantId
                    }
                }
            }
        } | ConvertTo-Json -Depth 6 -Compress
        $response = Invoke-RestMethod -Method PUT `
            -Uri $accessPolicyUri `
            -Headers $headers `
            -Body $body
        if (-not $response) {
            Write-Error "ERROR: Failed to update connection access policy for connection '$deployedConnectionName'."
            exit 1
        }
    }
}

# ============================================
# 4. Copy files to wwwroot
# ============================================

# Clean temp files from previous deployment if needed
if (Test-Path $tempDeployPath) {
    Remove-Item -Path $tempDeployPath -Recurse -Force
}

# Validate deployment files and copy to temp folder
Write-Output "Validating and preparing files for deployment"

New-Item -ItemType Directory -Path $tempDeployPath | Out-Null

# Update authentication in connections.json or parameters.json (if connections parameterized)
$authValue = @{ type = "ManagedServiceIdentity" }

$parametersJsonPath = Join-Path $currentDir "parameters.json"
$hasParameters = Test-Path $parametersJsonPath
if ($hasParameters) {
    $parametersJson = Get-Content -Path $parametersJsonPath -Raw
    $parameters = $parametersJson | ConvertFrom-Json
} else {
    $parameters = @{}
}

if ($hasConnections) {
    $connectionsJson = Get-Content -Path $connectionsJsonPath -Raw
    $connections = $connectionsJson | ConvertFrom-Json

    foreach ($connectionName in $connections.managedApiConnections.PSObject.Properties.Name) {
        if ($parameters.PSObject.Properties.Name -contains "$connectionName-Authentication") {
            $parameters."$connectionName-Authentication".value = $authValue
        } else {
            $connections.managedApiConnections."$connectionName".authentication = $authValue
        }
    }
} else {
    $connections = @{}
}

# Copy updated parameters.json and connections.json
$parametersJson = $parameters | ConvertTo-Json -Depth 6
$parametersJson = $parametersJson -replace '\\u0027', "'"
$parametersTargetPath = Join-Path $tempDeployPath "parameters.json"
$parametersJson | Out-File -FilePath $parametersTargetPath

$connectionsJson = $connections | ConvertTo-Json -Depth 6
$connectionsJson = $connectionsJson -replace '\\u0027', "'"
$connectionsTargetPath = Join-Path $tempDeployPath "connections.json"
$connectionsJson | Out-File -FilePath $connectionsTargetPath

$hostJsonPath = Join-Path $currentDir "host.json"
if (Test-Path $hostJsonPath) {
    Copy-Item $hostJsonPath -Destination $tempDeployPath -Force
} else {
    Write-Error "ERROR: host.json file not found in the current directory."
    exit 1
}

# Detect and copy all valid workflow.json files
$workflowDirs = Get-ChildItem -Path $currentDir -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName "workflow.json")
}
if (-not $workflowDirs) {
    Write-Error "ERROR: No valid workflows found in the current directory."
    exit 1
}

foreach ($workflowDir in $workflowDirs) {
    $workflowJsonPath = Join-Path $workflowDir.FullName "workflow.json"
    $workflowJson = Get-Content -Path $workflowJsonPath -Raw | ConvertFrom-Json

    if ($workflowJson.definition.'$schema' -like "*workflowdefinition.json*") {
        $workflowName = $workflowDir.Name
        $workflowTempTargetDirPath = Join-Path $tempDeployPath $workflowName
        New-Item -ItemType Directory -Path $workflowTempTargetDirPath -Force | Out-Null
        Copy-Item $workflowJsonPath -Destination $workflowTempTargetDirPath -Force
        Write-Output "-Found workflow '$workflowName'"
    }
}

# Remove old deployment files if they exist
Write-Output "Cleaning up old deployment files"

$oldFiles = @(
    "$TARGET\host.json",
    "$TARGET\connections.json",
    "$TARGET\parameters.json"
)

$existingWorkflowDirs = Get-ChildItem -Path $TARGET -Directory
foreach ($dir in $existingWorkflowDirs) {
    $workflowFilePath = Join-Path $dir.FullName "workflow.json"
    if (Test-Path $workflowFilePath) {
        $oldFiles += $dir.FullName
    }
}

foreach ($file in $oldFiles) {
    if (Test-Path $file) {
        Remove-Item $file -Recurse -Force
    }
}

# Copy files to wwwroot
Write-Output "Copying files to wwwroot"
Copy-Item -Path "${tempDeployPath}\*" -Destination $TARGET -Recurse -Force

# Clean up temp deployment files
Write-Output "Cleaning up temp files"
Remove-Item -Path $tempDeployPath -Recurse -Force

Write-Output "Logic App deployment completed successfully."
exit 0
