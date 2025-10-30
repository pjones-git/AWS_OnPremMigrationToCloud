# AWS Application Migration Service (MGN) - Migration Process

## Overview
This document details the step-by-step process used to migrate the on-premise Windows Server hosting QuickBooks databases to AWS using AWS Application Migration Service (MGN).

## Prerequisites

### On-Premise Requirements
- Windows Server with QuickBooks Enterprise installed
- Administrative access to source server
- Internet connectivity (outbound port 443 required)
- Minimum 10GB free disk space for MGN agent
- Firewall rules allowing outbound HTTPS traffic

### AWS Requirements
- AWS Account with appropriate IAM permissions
- VPC configured with public and private subnets
- Internet Gateway and NAT Gateway configured
- AWS MGN service initialized in target region (us-east-1)
- S3 bucket for staging and backup

## Phase 1: AWS MGN Service Initialization

### Step 1.1: Initialize MGN Service
```bash
# Using AWS CLI
aws mgn initialize-service --region us-east-1
```

### Step 1.2: Configure Replication Settings
1. Navigate to AWS MGN Console
2. Click "Settings" → "Replication settings"
3. Configure:
   - **Staging area subnet:** Public subnet (10.0.1.0/24)
   - **Replication server instance type:** t3.small
   - **EBS encryption:** Enabled (AWS managed key)
   - **Data routing:** Use private IP for data transfer

### Step 1.3: Create Replication Template
```json
{
  "stagingAreaSubnetId": "subnet-xxxxxxxxx",
  "associateDefaultSecurityGroup": true,
  "replicationServersSecurityGroupsIds": ["sg-xxxxxxxxx"],
  "replicationServerInstanceType": "t3.small",
  "useDedicatedReplicationServer": false,
  "ebsEncryption": "DEFAULT",
  "defaultLargeStagingDiskType": "GP3",
  "bandwidthThrottling": 0,
  "dataPlaneRouting": "PRIVATE_IP"
}
```

## Phase 2: Source Server Preparation

### Step 2.1: Pre-Migration Backup
```powershell
# On source Windows Server
# Create full backup of QuickBooks databases
$backupPath = "D:\Backups\Pre-Migration-$(Get-Date -Format 'yyyy-MM-dd')"
New-Item -ItemType Directory -Path $backupPath

# Copy QuickBooks company files
Copy-Item "C:\ProgramData\Intuit\QuickBooks\Company Files\*" -Destination $backupPath -Recurse

# Verify QuickBooks database integrity
& "C:\Program Files\Intuit\QuickBooks\QBDBMgrN.exe" -VerifyDatabase
```

### Step 2.2: Document Current Configuration
```powershell
# Export installed applications list
Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | 
  Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | 
  Export-Csv -Path "C:\Temp\installed-software.csv"

# Export network configuration
Get-NetIPConfiguration | Out-File "C:\Temp\network-config.txt"
Get-NetAdapter | Out-File "C:\Temp\network-adapters.txt" -Append

# Export QuickBooks configuration
Get-ChildItem "C:\ProgramData\Intuit\QuickBooks" -Recurse | 
  Select-Object FullName, Length, LastWriteTime | 
  Export-Csv -Path "C:\Temp\qb-files.csv"
```

### Step 2.3: Prepare Source Server
```powershell
# Disable Windows Firewall temporarily for MGN agent installation
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# Enable VSS (Volume Shadow Copy Service) for consistent snapshots
Set-Service -Name VSS -StartupType Automatic
Start-Service -Name VSS

# Ensure .NET Framework 4.5+ is installed (required for MGN agent)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" | 
  Select-Object Version, Release
```

## Phase 3: MGN Agent Installation

### Step 3.1: Download MGN Agent
1. In AWS MGN Console, click "Add servers"
2. Select "Windows" as operating system
3. Download the AWS Replication Agent installer
4. Transfer installer to source server

### Step 3.2: Install MGN Agent
```powershell
# Run as Administrator on source server
$installerPath = "C:\Temp\AwsReplicationWindowsInstaller.exe"

# Install with AWS credentials (use IAM role or temporary credentials)
& $installerPath `
  --region us-east-1 `
  --aws-access-key-id "AKIAXXXXXXXXXXXXXXXX" `
  --aws-secret-access-key "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" `
  --no-prompt

# Verify agent installation
Get-Service | Where-Object {$_.Name -like "*AWS*"}
```

### Step 3.3: Configure Agent
```powershell
# Configure throttling if needed (during business hours)
$configPath = "C:\Program Files (x86)\AWS Replication Agent\config.ini"

# Set bandwidth limit to 50 Mbps during business hours
# [Throttling]
# Enabled=true
# MaxBandwidthMbps=50
```

## Phase 4: Continuous Data Replication

### Step 4.1: Monitor Replication Progress
1. Navigate to AWS MGN Console → "Source servers"
2. Locate the source server
3. Monitor:
   - **Replication status:** "Initial sync" → "Continuous replication"
   - **Lag time:** Should be < 5 minutes after initial sync
   - **Replicated data:** Verify volume sizes match source

### Step 4.2: Validate Initial Sync
```bash
# Check replication status via AWS CLI
aws mgn describe-source-servers --region us-east-1 \
  --filters '{"sourceServerIDs": ["s-xxxxxxxxx"]}' \
  --query 'items[*].dataReplicationInfo'
```

Expected output:
```json
{
  "dataReplicationState": "CONTINUOUS",
  "etaDateTime": null,
  "lagDuration": "PT2M30S",
  "replicatedDisks": [
    {
      "backloggedStorageBytes": 0,
      "deviceName": "/dev/sda1",
      "replicatedStorageBytes": 483883827200,
      "totalStorageBytes": 483883827200
    }
  ]
}
```

### Step 4.3: Allow Replication to Stabilize
- Wait for "Continuous replication" status
- Monitor for 24-48 hours before cutover
- Verify lag time remains < 5 minutes consistently

## Phase 5: Launch Template Configuration

### Step 5.1: Configure Launch Settings
1. In MGN Console, select source server
2. Click "Launch settings" → "Edit"
3. Configure:

**General settings:**
- Instance type: m5.xlarge
- Launch disposition: Test and Cutover

**Networking:**
- Target subnet: Private subnet (10.0.2.0/24)
- Security groups: quickbooks-server-sg
- Private IP: 10.0.2.10 (static)

**Storage:**
- Volume type: gp3
- IOPS: 3000
- Throughput: 125 MB/s
- Encryption: Enabled

**Advanced:**
- IAM instance profile: QuickBooksEC2Role
- User data: (See Step 5.2)

### Step 5.2: Post-Launch Configuration Script
```powershell
<powershell>
# Post-launch configuration for QuickBooks server

# Set hostname
Rename-Computer -NewName "QB-PROD-01" -Force

# Configure Windows Firewall
New-NetFirewallRule -DisplayName "QuickBooks Database Server" `
  -Direction Inbound -Protocol TCP -LocalPort 8019 -Action Allow

New-NetFirewallRule -DisplayName "QuickBooks Multi-User Access" `
  -Direction Inbound -Protocol TCP -LocalPort 55378-55382 -Action Allow

New-NetFirewallRule -DisplayName "RDP Access" `
  -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow

# Install CloudWatch agent
$cwAgentUrl = "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi"
$cwAgentPath = "C:\Temp\amazon-cloudwatch-agent.msi"
Invoke-WebRequest -Uri $cwAgentUrl -OutFile $cwAgentPath
Start-Process msiexec.exe -ArgumentList "/i $cwAgentPath /qn" -Wait

# Configure time zone
Set-TimeZone -Id "Eastern Standard Time"

# Enable RDP
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
  -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Restart to apply changes
# Restart-Computer -Force
</powershell>
```

## Phase 6: Test Launch

### Step 6.1: Perform Test Launch
1. Select source server in MGN Console
2. Click "Test and Cutover" → "Launch test instances"
3. Click "Launch"
4. Monitor EC2 console for instance creation

### Step 6.2: Validate Test Instance
```powershell
# Connect via RDP to test instance
# Verify QuickBooks installation
Test-Path "C:\Program Files\Intuit\QuickBooks"

# Verify database files
Get-ChildItem "C:\ProgramData\Intuit\QuickBooks\Company Files"

# Test QuickBooks database manager
& "C:\Program Files\Intuit\QuickBooks\QBDBMgrN.exe" -status

# Verify services
Get-Service | Where-Object {$_.Name -like "*QuickBooks*"}
```

### Step 6.3: Test User Access
1. Create test user account
2. Test RDP connectivity from on-premise network
3. Launch QuickBooks and connect to test database
4. Verify multi-user functionality
5. Test printer redirection

### Step 6.4: Mark Test as Complete
```bash
# Mark test launch as complete
aws mgn update-launch-configuration --source-server-id s-xxxxxxxxx \
  --launch-disposition STARTED --region us-east-1

# Terminate test instance if successful
aws mgn mark-as-archived --source-server-id s-xxxxxxxxx --region us-east-1
```

## Phase 7: Production Cutover

### Step 7.1: Pre-Cutover Checklist
- [ ] Test launch validated successfully
- [ ] Users notified of maintenance window
- [ ] Change management approval obtained
- [ ] Backup of source server completed
- [ ] Rollback plan documented
- [ ] Replication lag < 2 minutes

### Step 7.2: Final Data Sync
```powershell
# On source server - stop QuickBooks services
Stop-Service -Name "QuickBooksDB*" -Force

# Close all QuickBooks applications
Get-Process | Where-Object {$_.ProcessName -like "*qb*"} | Stop-Process -Force

# Wait for final replication
Start-Sleep -Seconds 300  # 5 minutes

# Verify no pending writes
Get-Service VSS | Select-Object Status
```

### Step 7.3: Launch Production Instance
1. In MGN Console, select source server
2. Click "Launch cutover instances"
3. Verify launch template settings
4. Click "Launch"
5. Monitor instance initialization

### Step 7.4: Post-Cutover Configuration
```powershell
# Connect to new EC2 instance via RDP

# Verify QuickBooks Database Server Manager is running
Start-Service "QuickBooksDBXX"

# Update QuickBooks configuration for multi-user access
# Open QuickBooks Database Server Manager
# Scan folder: C:\ProgramData\Intuit\QuickBooks\Company Files

# Verify all 3 databases are accessible
& "C:\Program Files\Intuit\QuickBooks\QBDBMgrN.exe" -ListDatabases
```

### Step 7.5: Update Network Routing
```bash
# Update DNS record to point to new EC2 instance private IP
# (Assuming Route 53 is used)
aws route53 change-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "quickbooks.internal.company.com",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "10.0.2.10"}]
      }
    }]
  }'
```

### Step 7.6: User Acceptance Testing
1. Connect test users via RDP
2. Launch QuickBooks client
3. Connect to each of the 3 company databases
4. Perform sample transactions
5. Generate test reports
6. Verify printer redirection works

## Phase 8: Post-Migration Tasks

### Step 8.1: Enable Backup
```bash
# Create backup plan for EC2 instance
aws backup create-backup-plan --backup-plan file://backup-plan.json

# Associate resources with backup plan
aws backup create-backup-selection \
  --backup-plan-id backup-plan-id \
  --backup-selection file://backup-selection.json
```

### Step 8.2: Configure Monitoring
```bash
# Enable detailed CloudWatch monitoring
aws ec2 monitor-instances --instance-ids i-xxxxxxxxx

# Create CloudWatch alarms for critical metrics
aws cloudwatch put-metric-alarm --alarm-name qb-server-cpu-high \
  --alarm-description "Alert when CPU exceeds 80%" \
  --metric-name CPUUtilization --namespace AWS/EC2 \
  --statistic Average --period 300 --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 \
  --dimensions Name=InstanceId,Value=i-xxxxxxxxx
```

### Step 8.3: Finalize MGN
```bash
# Mark migration as complete
aws mgn finalize-cutover --source-server-id s-xxxxxxxxx --region us-east-1

# Archive source server (keeps data for 90 days)
aws mgn mark-as-archived --source-server-id s-xxxxxxxxx --region us-east-1
```

### Step 8.4: Decommission Source Server
1. Verify all users migrated to AWS instance
2. Monitor for 7 days post-migration
3. Uninstall MGN agent from source server
4. Power down source server (keep for 30 days)
5. Schedule source server decommissioning

## Rollback Procedure

If issues occur during cutover:

### Step 1: Immediate Rollback
```powershell
# Start QuickBooks services on original source server
Start-Service -Name "QuickBooksDB*"

# Notify users to reconnect to on-premise server
# Update DNS to point back to on-premise server
```

### Step 2: Terminate AWS Instance
```bash
# Stop the EC2 instance
aws ec2 stop-instances --instance-ids i-xxxxxxxxx

# Do not terminate - keep for troubleshooting
```

### Step 3: Investigate and Retry
1. Review CloudWatch logs
2. Check MGN replication status
3. Verify data integrity
4. Address issues found
5. Schedule new cutover window

## Troubleshooting

### Issue: High Replication Lag
**Solution:**
- Check source server disk I/O performance
- Verify network bandwidth between on-premise and AWS
- Consider enabling bandwidth throttling during off-hours

### Issue: MGN Agent Installation Failed
**Solution:**
```powershell
# Check Windows event logs
Get-EventLog -LogName Application -Source "AWS*" -Newest 50

# Verify .NET Framework version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"

# Reinstall with logging enabled
& $installerPath --region us-east-1 --verbose
```

### Issue: QuickBooks Database Not Accessible After Migration
**Solution:**
```powershell
# Restart QuickBooks Database Server Manager
Restart-Service "QuickBooksDBXX"

# Re-scan company files folder
& "C:\Program Files\Intuit\QuickBooks\QBDBMgrN.exe" -ScanFolder "C:\ProgramData\Intuit\QuickBooks\Company Files"

# Check file permissions
icacls "C:\ProgramData\Intuit\QuickBooks\Company Files"
```

## Summary

This migration process successfully moved 3 QuickBooks databases from on-premise to AWS with minimal downtime. Key success factors:
- Thorough pre-migration testing
- Proper replication monitoring
- Well-defined rollback procedures
- Clear communication with stakeholders

**Migration completed:** August 2024  
**Total downtime:** 1 hour 45 minutes  
**Success criteria met:** ✅ All databases accessible, users connected successfully
