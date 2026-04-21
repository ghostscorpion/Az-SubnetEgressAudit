<#
.SYNOPSIS
Audits Azure subnets for outbound (egress) connectivity configuration.

.DESCRIPTION
Scans all accessible Azure subscriptions and evaluates each subnet to determine
whether explicit outbound connectivity is configured or if the subnet may be
relying on legacy default outbound access.

Checks include:
- NAT Gateway attachment
- Default route (0.0.0.0/0) via route table
- Load Balancer outbound rules
- Public IP assignments on NICs

Subnets without any of these are flagged as potentially at risk.

.NOTES
File Name   : Az-SubnetEgressAudit.ps1
Author      : Scorpion
Organization: ScorpionLabs.space
Created     : 2026-04-21
Version     : 1.0.0

Requirements:
- Az.Accounts
- Az.Network
- Az.Compute
- Pre-authenticated Azure session (Connect-AzAccount)

Output:
- CSV report (all subnets)
- LOG file (processing/debug details)
#>

# Requires:
#   Az.Accounts
#   Az.Network
#   Az.Compute

$ErrorActionPreference = 'Stop'

function Get-ResourceGroupFromId {
    param([string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }
    if ($ResourceId -match '/resourceGroups/([^/]+)/') { return $matches[1] }
    return $null
}

function Get-NameFromId {
    param([string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }
    return ($ResourceId.TrimEnd('/') -split '/')[-1]
}

function Safe-Join {
    param([object[]]$Values, [string]$Delimiter = '; ')
    if (-not $Values) { return '' }
    return (($Values | Where-Object { $_ -ne $null -and "$_" -ne '' }) -join $Delimiter)
}

Write-Host "Initializing Azure session..." -ForegroundColor Cyan

$requiredModules = @("Az.Accounts","Az.Network","Az.Compute")

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing missing module: $module" -ForegroundColor Yellow
        Install-Module -Name $module -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module $module -ErrorAction Stop | Out-Null
}

try {
    Update-AzConfig -EnableLoginByWam $false -Scope CurrentUser -ErrorAction Stop | Out-Null
}
catch {
    Write-Warning "Could not update WAM setting: $($_.Exception.Message)"
}

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    try {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Standard login failed. Falling back to device code."
        Connect-AzAccount -DeviceCode -ErrorAction Stop | Out-Null
    }
}

Write-Host "Azure session ready." -ForegroundColor Green

$subscriptions = Get-AzSubscription | Sort-Object Name
$results = @()
$debugLog = @()

foreach ($sub in $subscriptions) {
    Write-Host "Auditing subscription: $($sub.Name) [$($sub.Id)]" -ForegroundColor Cyan

    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Could not set context for subscription $($sub.Name): $($_.Exception.Message)"
        continue
    }

    try { $allVnets = @(Get-AzVirtualNetwork -ErrorAction Stop) } catch { $allVnets = @(); $debugLog += "VNET_FAIL [$($sub.Name)]: $($_.Exception.Message)" }
    try { $allNics  = @(Get-AzNetworkInterface -ErrorAction Stop) } catch { $allNics  = @(); $debugLog += "NIC_FAIL [$($sub.Name)]: $($_.Exception.Message)" }
    try { $allVms   = @(Get-AzVM -Status -ErrorAction Stop) } catch { $allVms   = @(); $debugLog += "VM_FAIL [$($sub.Name)]: $($_.Exception.Message)" }
    try { $allLbs   = @(Get-AzLoadBalancer -ErrorAction Stop) } catch { $allLbs   = @(); $debugLog += "LB_FAIL [$($sub.Name)]: $($_.Exception.Message)" }

    $nicToVm = @{}
    foreach ($vm in $allVms) {
        $vmPowerState = (($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).DisplayStatus)
        foreach ($nicRef in @($vm.NetworkProfile.NetworkInterfaces)) {
            if ($nicRef.Id) {
                $nicToVm[$nicRef.Id.ToLowerInvariant()] = [pscustomobject]@{
                    VmName          = $vm.Name
                    VmResourceGroup = $vm.ResourceGroupName
                    PowerState      = $vmPowerState
                }
            }
        }
    }

    $subnetToNicEntries = @{}
    foreach ($nic in $allNics) {
        foreach ($ipcfg in @($nic.IpConfigurations)) {
            if ($ipcfg.Subnet -and $ipcfg.Subnet.Id) {
                $subnetKey = $ipcfg.Subnet.Id.ToLowerInvariant()

                if (-not $subnetToNicEntries.ContainsKey($subnetKey)) {
                    $subnetToNicEntries[$subnetKey] = @()
                }

                $subnetToNicEntries[$subnetKey] += [pscustomobject]@{
                    NicName         = $nic.Name
                    NicId           = $nic.Id
                    IpConfigName    = $ipcfg.Name
                    SubnetId        = $ipcfg.Subnet.Id
                    PublicIpId      = if ($ipcfg.PublicIpAddress) { $ipcfg.PublicIpAddress.Id } else { $null }
                    HasPublicIp     = [bool]$ipcfg.PublicIpAddress
                    BackendPoolIds  = @($ipcfg.LoadBalancerBackendAddressPools | ForEach-Object { $_.Id })
                    VmName          = if ($nicToVm.ContainsKey($nic.Id.ToLowerInvariant())) { $nicToVm[$nic.Id.ToLowerInvariant()].VmName } else { $null }
                }
            }
        }
    }

    $backendPoolToOutboundRules = @{}
    foreach ($lb in $allLbs) {
        try {
            $lbOutboundRules = @()
            if ($lb.OutboundRules) {
                $lbOutboundRules = @($lb.OutboundRules)
            }
            else {
                try {
                    $lbOutboundRules = @(Get-AzLoadBalancerOutboundRuleConfig -LoadBalancer $lb -ErrorAction Stop)
                }
                catch {
                    $lbOutboundRules = @()
                    $debugLog += "OUTBOUND_RULE_READ_FAIL [$($sub.Name)] LB=$($lb.Name): $($_.Exception.Message)"
                }
            }

            foreach ($rule in $lbOutboundRules) {
                foreach ($pool in @($rule.BackendAddressPool)) {
                    if ($pool -and $pool.Id) {
                        $poolKey = $pool.Id.ToLowerInvariant()
                        if (-not $backendPoolToOutboundRules.ContainsKey($poolKey)) {
                            $backendPoolToOutboundRules[$poolKey] = @()
                        }
                        $backendPoolToOutboundRules[$poolKey] += [pscustomobject]@{
                            LoadBalancerName = $lb.Name
                            RuleName         = $rule.Name
                        }
                    }
                }
            }
        }
        catch {
            $debugLog += "LB_PROCESS_FAIL [$($sub.Name)] LB=$($lb.Name): $($_.Exception.Message)"
        }
    }

    foreach ($vnet in $allVnets) {
        foreach ($subnet in @($vnet.Subnets)) {
            try {
                $subnetId = $subnet.Id.ToLowerInvariant()
                $subnetPrefix = if ($subnet.AddressPrefix) {
                    $subnet.AddressPrefix
                } elseif ($subnet.AddressPrefixes) {
                    ($subnet.AddressPrefixes -join ', ')
                } else {
                    ''
                }

                $natGatewayId   = if ($subnet.NatGateway) { $subnet.NatGateway.Id } else { $null }
                $natGatewayName = Get-NameFromId $natGatewayId
                $hasNatGateway  = [bool]$natGatewayId

                $routeTableId   = if ($subnet.RouteTable) { $subnet.RouteTable.Id } else { $null }
                $routeTableName = Get-NameFromId $routeTableId
                $hasDefaultRoute = $false
                $defaultNextHopType = $null
                $defaultNextHopIp   = $null

                if ($routeTableId) {
                    try {
                        $rtRg = Get-ResourceGroupFromId $routeTableId
                        $rtNm = Get-NameFromId $routeTableId
                        $rt = Get-AzRouteTable -ResourceGroupName $rtRg -Name $rtNm -ErrorAction Stop
                        $defaultRoute = @($rt.Routes | Where-Object { $_.AddressPrefix -eq '0.0.0.0/0' }) | Select-Object -First 1
                        if ($defaultRoute) {
                            $hasDefaultRoute = $true
                            $defaultNextHopType = $defaultRoute.NextHopType
                            $defaultNextHopIp   = $defaultRoute.NextHopIpAddress
                        }
                    }
                    catch {
                        $debugLog += "ROUTE_READ_FAIL [$($sub.Name)] $($vnet.Name)/$($subnet.Name): $($_.Exception.Message)"
                    }
                }

                $nicEntries = if ($subnetToNicEntries.ContainsKey($subnetId)) { @($subnetToNicEntries[$subnetId]) } else { @() }

                $publicIpDetails = @()
                $lbOutboundDetails = @()

                foreach ($entry in $nicEntries) {
                    if ($entry.HasPublicIp) {
                        $publicIpDetails += "PIP=$((Get-NameFromId $entry.PublicIpId)) VM=$($entry.VmName) NIC=$($entry.NicName) IPCFG=$($entry.IpConfigName)"
                    }

                    foreach ($poolId in @($entry.BackendPoolIds)) {
                        if ($poolId -and $backendPoolToOutboundRules.ContainsKey($poolId.ToLowerInvariant())) {
                            foreach ($rule in @($backendPoolToOutboundRules[$poolId.ToLowerInvariant()])) {
                                $lbOutboundDetails += "LB=$($rule.LoadBalancerName) Rule=$($rule.RuleName) VM=$($entry.VmName) NIC=$($entry.NicName)"
                            }
                        }
                    }
                }

                $hasPublicIp = $publicIpDetails.Count -gt 0
                $hasLbOutboundRule = $lbOutboundDetails.Count -gt 0

                $finding = @()
                if ($hasNatGateway) { $finding += "Explicit outbound via NAT Gateway" }
                if ($hasDefaultRoute) { $finding += "0.0.0.0/0 route to $defaultNextHopType$(if($defaultNextHopIp){ " ($defaultNextHopIp)" })" }
                if ($hasLbOutboundRule) { $finding += "Standard Load Balancer outbound rule found" }
                if ($hasPublicIp) { $finding += "Public IP found on NIC/IP config" }

                $appearsLegacyDefaultOutbound = $false
                if (-not $hasNatGateway -and -not $hasDefaultRoute -and -not $hasLbOutboundRule -and -not $hasPublicIp) {
                    $appearsLegacyDefaultOutbound = $true
                    $finding += "No explicit outbound method found"
                }

                $results += [pscustomobject]@{
                    SubscriptionName                  = $sub.Name
                    SubscriptionId                    = $sub.Id
                    ResourceGroup                     = $vnet.ResourceGroupName
                    VnetName                          = $vnet.Name
                    SubnetName                        = $subnet.Name
                    SubnetPrefix                      = $subnetPrefix
                    NatGatewayAttached                = $hasNatGateway
                    NatGatewayName                    = $natGatewayName
                    RouteTableName                    = $routeTableName
                    HasDefaultRoute                   = $hasDefaultRoute
                    DefaultRouteNextHopType           = $defaultNextHopType
                    DefaultRouteNextHopIp             = $defaultNextHopIp
                    HasLoadBalancerOutboundRule       = $hasLbOutboundRule
                    LoadBalancerOutboundDetails       = Safe-Join $lbOutboundDetails
                    HasPublicIpOnNic                  = $hasPublicIp
                    PublicIpDetails                   = Safe-Join $publicIpDetails
                    VmCountInSubnet                   = (@($nicEntries | Where-Object { $_.VmName } | Select-Object -ExpandProperty VmName -Unique)).Count
                    VmNames                           = Safe-Join (@($nicEntries | Where-Object { $_.VmName } | Select-Object -ExpandProperty VmName -Unique)) ', '
                    AppearsToUseLegacyDefaultOutbound = $appearsLegacyDefaultOutbound
                    Finding                           = Safe-Join $finding ' | '
                }
            }
            catch {
                $debugLog += "SUBNET_PROCESS_FAIL [$($sub.Name)] $($vnet.Name)/$($subnet.Name): $($_.Exception.Message)"
            }
        }
    }
}

# Ensure output folder exists
$folder = "C:\Temp"
if (-not (Test-Path $folder)) {
    New-Item -Path $folder -ItemType Directory | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = "$folder\Azure-Subnet-Outbound-Audit-$timestamp.csv"
$logPath = "$folder\Azure-Subnet-Outbound-Audit-$timestamp.log"

$results |
    Sort-Object SubscriptionName, ResourceGroup, VnetName, SubnetName |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$debugLog | Out-File -FilePath $logPath -Encoding UTF8

$atRisk = @($results | Where-Object { $_.AppearsToUseLegacyDefaultOutbound })

Write-Host ""
Write-Host "Audit complete." -ForegroundColor Green
Write-Host "CSV : $csvPath"
Write-Host "LOG : $logPath"
Write-Host ""

if ($atRisk.Count -gt 0) {
    Write-Host "Subnets that appear to lack explicit outbound connectivity:" -ForegroundColor Yellow
    $atRisk |
        Select-Object SubscriptionName, ResourceGroup, VnetName, SubnetName, SubnetPrefix, VmCountInSubnet, Finding |
        Format-Table -AutoSize
}
else {
    Write-Host "No obvious at-risk subnets found." -ForegroundColor Green
}
