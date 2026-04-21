#Purpose

Az-SubnetEgressAudit.ps1 is a PowerShell script used to review Azure subnets and identify how outbound internet connectivity is provided.

The script checks each subnet across the Azure subscriptions you can access and looks for approved outbound methods such as:

NAT Gateway
Default route (0.0.0.0/0) through a route table
Load Balancer outbound rules
Public IP assignments on NICs

If a subnet does not have any of these configured, the script flags it as a potential risk because it may be relying on Azure legacy default outbound access.

Why This Script Is Needed

Microsoft is changing how outbound internet access works for Azure virtual networks. New virtual networks and subnets will no longer receive automatic default outbound internet access unless outbound connectivity is explicitly configured.

Because of this change, it is important to identify subnets that do not have a defined outbound method.

This script helps administrators:

Find subnets that may be at risk
Verify whether outbound connectivity is explicitly configured
Support cleanup and remediation planning
Document current Azure network design
What the Script Checks

The script reviews each subnet and checks for the following:

1. NAT Gateway

Determines whether a NAT Gateway is attached to the subnet.

2. Route Table

Checks whether the subnet has a route table with a default route:

0.0.0.0/0

This can indicate traffic is being sent to:

Azure Firewall
Network Virtual Appliance (NVA)
Another explicit outbound path
3. Load Balancer Outbound Rules

Checks whether any NICs in the subnet are associated with backend pools that use outbound rules.

4. Public IP Addresses

Checks whether VMs or NIC IP configurations in the subnet have public IPs assigned.

Requirements

Before running the script, make sure the following PowerShell modules are installed:

Az.Accounts
Az.Network
Az.Compute

You must already be signed in to Azure before running the script.

Example:

Connect-AzAccount

If needed, set the correct subscription or tenant before running the script.

How to Run the Script
Step 1: Open PowerShell

Open PowerShell with an account that has permission to read Azure networking resources.

Step 2: Sign in to Azure

Run:

Connect-AzAccount
Step 3: Run the script

Example:

.\Az-SubnetEgressAudit.ps1
Output Files

The script writes output files to:

C:\Temp

It creates two files with a timestamp:

CSV Report

Example:

C:\Temp\Azure-Subnet-Outbound-Audit-20260421-091748.csv

This file contains the subnet audit results.

Log File

Example:

C:\Temp\Azure-Subnet-Outbound-Audit-20260421-091748.log

This file contains debug and processing details, including any resource-level errors encountered during the audit.

Understanding the Results

The CSV output includes information such as:

Subscription name
Resource group
VNet name
Subnet name
NAT Gateway status
Route table status
Load Balancer outbound rule status
Public IP status
Risk finding
Key Result Field
AppearsToUseLegacyDefaultOutbound = True

This means the script did not find an explicit outbound method for that subnet.

That subnet should be reviewed because it may be depending on legacy default outbound access.

AppearsToUseLegacyDefaultOutbound = False

This means the subnet appears to have an explicit outbound method configured.

Example Use Cases

This script is useful for:

Azure network reviews
AVD environment validation
Security and compliance audits
Pre-migration assessments
Documentation of outbound connectivity design
Identifying subnets affected by Microsoft outbound connectivity changes
Important Notes
The script is read-only and does not make changes in Azure.
The script depends on the Azure account permissions of the person running it.
If a resource cannot be read, the script logs the error and continues processing other resources.
Results should still be reviewed by an administrator, especially for complex network designs.
Recommended Follow-Up

If the script identifies a subnet as at risk, review whether it should use one of the following explicit outbound methods:

NAT Gateway
Azure Firewall
Network Virtual Appliance
Standard Load Balancer outbound rules
Public IP assignment where appropriate

For most cases, NAT Gateway is the preferred Azure-recommended outbound method.

Script Information

File Name: Az-SubnetEgressAudit.ps1
Author: Jeremy Arthur
Organization: UTH / DCO Infrastructure
Version: 1.0.0
Created: 2026-04-21
