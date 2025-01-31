# Function to extract TLS version from Application Gateway JSON
function Get-TlsVersion {
    param (
        [Parameter(Mandatory = $true)]
        [string]$json
    )

    $data = $json | ConvertFrom-Json

    foreach ($listener in $data.httpListeners) {
        if ($listener.sslCertificate) {
            $sslPolicy = $listener.sslCertificate.sslPolicy
            if ($sslPolicy -and $sslPolicy.MinProtocolVersion) {
                return $sslPolicy.MinProtocolVersion
            }
        }
    }

    Write-Warning "No TLS version found for $($data.name) in resource group $($data.resourceGroup)"
    return $null
}

# Function to get available protocols from Application Gateway SSL policy
function Get-AvailableProtocols {
    $availableProtocols = az network application-gateway ssl-policy list-options --query "availableProtocols" -o json | ConvertFrom-Json
    return $availableProtocols
}

# MARK: Define Resources
# Define the list of resources that use TLS versions
$resourceTypes = @(
    "Azure Storage Accounts",
    "Azure Application Gateway"
)

# MARK: Display Selection Menu
Write-Host "Select a resource type to check TLS versions:"
for ($i = 0; $i -lt $resourceTypes.Count; $i++) {
    Write-Host "$($i + 1). $($resourceTypes[$i])"
}

# MARK: Get User Selection
$selection = Read-Host "Enter the number of the resource type"
$selection = [int]$selection

if ($selection -lt 1 -or $selection -gt $resourceTypes.Count) {
    Write-Host "Invalid selection. Exiting script."
    exit
}

$selectedResource = $resourceTypes[$selection - 1]

# MARK: Get Subscriptions
$subscriptions = Get-AzSubscription
$results = @()

foreach ($subscription in $subscriptions) {
    Set-AzContext -SubscriptionId $subscription.Id
    Write-Host "Switched to subscription: $($subscription.Name) ($($subscription.Id))"
    
    $resourceGroups = Get-AzResourceGroup
    $resourcesFound = $false

    foreach ($rg in $resourceGroups) {
        Write-Host "Checking resource group: $($rg.ResourceGroupName)"
        
        $resources = @()
        switch ($selectedResource) {
            "Azure Storage Accounts" {
                $resources = Get-AzStorageAccount -ResourceGroupName $rg.ResourceGroupName
            }
            "Azure Application Gateway" {
                $resources = Get-AzApplicationGateway -ResourceGroupName $rg.ResourceGroupName
            }
        }

        if ($resources.Count -eq 0) {
            continue
        }

        $resourcesFound = $true

        foreach ($resource in $resources) {
            $tlsVersion = $null
            $resourceName = $resource.Name
            switch ($selectedResource) {
                "Azure Storage Accounts" {
                    $tlsVersion = $resource.MinimumTlsVersion
                    $resourceName = $resource.StorageAccountName
                }
                "Azure Application Gateway" {
                    try {
                        $appGwJson = az network application-gateway show --resource-group $rg.ResourceGroupName --name $resource.Name | ConvertFrom-Json
                        $resourceName = $resource.Name
                        if ($appGwJson.PSObject.Properties.Name -contains "sslPolicy") {
                            if ($appGwJson.sslPolicy.PSObject.Properties.Name -contains "MinProtocolVersion") {
                                $tlsVersion = $appGwJson.sslPolicy.MinProtocolVersion
                            }
                            else {
                                Write-Warning "MinProtocolVersion not found in Application Gateway $($resource.Name)"
                            }
                        }
                        else {
                            Write-Warning "sslPolicy not found in Application Gateway $($resource.Name)"
                        }

                        # Check for available protocols
                        $availableProtocols = Get-AvailableProtocols
                        if ($availableProtocols -contains "TLSv1_0" -or $availableProtocols -contains "TLSv1_1") {
                            Write-Host "Unsupported TLS version detected for Application Gateway $($resource.Name)" -ForegroundColor Red
                        }
                        $result = [PSCustomObject]@{
                            SubscriptionId     = $subscription.Id
                            SubscriptionName   = $subscription.Name
                            ResourceGroupName  = $rg.ResourceGroupName
                            ResourceName       = $resource.Name
                            MinimumTlsVersion  = $tlsVersion
                            AvailableProtocols = $availableProtocols -join ", "
                        }
                        $results += $result
                    }
                    catch {
                        Write-Warning "Failed to retrieve TLS version for Application Gateway $($resource.Name): $_"
                    }
                }
            }
            
            if ($tlsVersion) {
                $color = "Green"
                if ($tlsVersion -eq "1.0" -or $tlsVersion -eq "1.1" -or $tlsVersion -eq "TLS1_0" -or $tlsVersion -eq "TLS1_1") {
                    $color = "Red"
                }
                Write-Host "$resourceName - TLS Version: $tlsVersion" -ForegroundColor $color
                $result = [PSCustomObject]@{
                    SubscriptionId    = $subscription.Id
                    SubscriptionName  = $subscription.Name
                    ResourceGroupName = $rg.ResourceGroupName
                    ResourceName      = $resourceName
                    MinimumTlsVersion = $tlsVersion
                }
                $results += $result
            }
            else {
                Write-Host "$resourceName - No valid TLS Version found." -ForegroundColor Red
            }
        }
    }

    if (-not $resourcesFound) {
        Write-Host "No resources found in subscription: $($subscription.Name)" -ForegroundColor Yellow
    }
}

if ($results.Count -gt 0) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $fileName = "$($selectedResource.Replace(' ', '_'))_ResourceTlsVersions_$timestamp.csv"
    $results | Export-Csv -Path $fileName -NoTypeInformation
    Write-Host "TLS version information exported to $fileName"
}
else {
    Write-Host "No resources found with valid TLS version information. Please verify your selection and try again." -ForegroundColor Red
}

# ...existing code...