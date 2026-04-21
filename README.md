Az-SubnetEgressAudit.ps1
Overview

Az-SubnetEgressAudit.ps1 is a PowerShell script that audits Azure subnets to determine how outbound (egress) internet connectivity is configured.

It identifies subnets that may be relying on Azure’s legacy default outbound access, which is being deprecated for new virtual networks.

Why This Matters

Microsoft is changing how outbound connectivity works in Azure:

New VNets/subnets will not receive default outbound internet access
Outbound connectivity must be explicitly configured

This script helps you:

Identify subnets at risk
Validate outbound design
Support remediation planning
Document current network architecture
What the Script Checks

Each subnet is evaluated for the following outbound methods:

NAT Gateway
Route Table (0.0.0.0/0)
Load Balancer outbound rules
Public IP assignments

If none of these are found, the subnet is flagged as at risk.

Requirements
PowerShell 5.1 or later
Azure PowerShell modules:
Az.Accounts
Az.Network
Az.Compute
Azure permissions to read:
VNets
Subnets
NICs
Load Balancers
Route Tables
Authentication

You must authenticate to Azure before running the script:

Connect-AzAccount

Optionally set your subscription:

Set-AzContext -SubscriptionId <SubscriptionId>
Usage

Run the script from PowerShell:

.\Az-SubnetEgressAudit.ps1

The script will automatically scan all accessible subscriptions.

Output

The script writes output files to:

C:\Temp
CSV Report

Contains the full audit results:

Azure-Subnet-Outbound-Audit-<timestamp>.csv
Log File

Contains debug and processing details:

Azure-Subnet-Outbound-Audit-<timestamp>.log
Understanding Results

Key field in the CSV:

AppearsToUseLegacyDefaultOutbound
True
→ No explicit outbound method detected
→ Subnet may rely on deprecated default outbound access
False
→ Explicit outbound method found
Example Output Fields
Subscription
ResourceGroup
VNet
Subnet
NAT Gateway status
Route Table status
Load Balancer outbound status
Public IP presence
Risk finding
Common Use Cases
Azure network audits
AVD environment validation
Security and compliance reviews
Migration readiness checks
Outbound connectivity standardization
Important Notes
This script is read-only
No changes are made to Azure resources
Results depend on your Azure permissions
Errors are logged and do not stop execution
Recommended Remediation

If a subnet is flagged as at risk, consider implementing:

NAT Gateway (recommended)
Azure Firewall
Network Virtual Appliance (NVA)
Load Balancer outbound rules
Public IPs (if appropriate)
Script Information
Field	Value
Name	Az-SubnetEgressAudit.ps1
Author	Jeremy Arthur
Organization	UTH / DCO Infrastructure
Version	1.0.0
Created	2026-04-21
