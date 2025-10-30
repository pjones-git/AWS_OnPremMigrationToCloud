<#
.SYNOPSIS
    Creates 66 user accounts for QuickBooks RDP access on AWS EC2 Windows Server
    
.DESCRIPTION
    This script automates the creation of 66 user accounts with RDP access rights.
    Users are added to the "Remote Desktop Users" group and configured with
    appropriate permissions for QuickBooks access.
    
.NOTES
    File Name      : Create-RDPUsers.ps1
    Author         : Paul Jones
    Prerequisite   : PowerShell 5.1 or higher, Administrator privileges
    Created        : August 2024
    
.EXAMPLE
    .\Create-RDPUsers.ps1 -UserListCSV "C:\Users\users.csv"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$UserListCSV = "C:\Temp\qb_users.csv",
    
    [Parameter(Mandatory=$false)]
    [string]$DefaultPassword = "Ch@ngeMe2024!",
    
    [Parameter(Mandatory=$false)]
    [bool]$ForcePasswordChange = $true
)

# Ensure script is running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Import required modules
Import-Module ActiveDirectory -ErrorAction SilentlyContinue

# Create log file
$LogFile = "C:\Logs\UserCreation_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
New-Item -ItemType Directory -Path "C:\Logs" -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogFile -Append
    Write-Host $Message
}

Write-Log "=== QuickBooks User Creation Script Started ==="

# Check if user list CSV exists
if (-not (Test-Path $UserListCSV)) {
    Write-Log "User list CSV not found. Creating sample template..."
    
    # Create sample user list
    $sampleUsers = @()
    for ($i = 1; $i -le 66; $i++) {
        $sampleUsers += [PSCustomObject]@{
            FirstName = "User"
            LastName = "QB$i"
            Username = "qbuser$($i.ToString('00'))"
            Email = "qbuser$($i.ToString('00'))@company.com"
            Department = if ($i -le 22) { "Accounting" } elseif ($i -le 44) { "Finance" } else { "Operations" }
        }
    }
    
    $sampleUsers | Export-Csv -Path $UserListCSV -NoTypeInformation
    Write-Log "Sample user list created at: $UserListCSV"
    Write-Log "Please review and update the user list, then run the script again."
    exit 0
}

# Import user list
try {
    $users = Import-Csv -Path $UserListCSV
    Write-Log "Imported $($users.Count) users from CSV"
} catch {
    Write-Log "ERROR: Failed to import CSV - $($_.Exception.Message)"
    exit 1
}

# Create users
$successCount = 0
$failCount = 0
$results = @()

foreach ($user in $users) {
    $username = $user.Username
    $fullName = "$($user.FirstName) $($user.LastName)"
    
    Write-Log "Processing user: $username ($fullName)"
    
    try {
        # Check if user already exists
        $existingUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
        
        if ($existingUser) {
            Write-Log "  WARNING: User $username already exists - skipping"
            $results += [PSCustomObject]@{
                Username = $username
                FullName = $fullName
                Status = "Skipped"
                Reason = "Already exists"
            }
            continue
        }
        
        # Convert password to secure string
        $securePassword = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force
        
        # Create local user account
        New-LocalUser -Name $username `
                     -Password $securePassword `
                     -FullName $fullName `
                     -Description "QuickBooks User - $($user.Department)" `
                     -PasswordNeverExpires:(!$ForcePasswordChange) `
                     -UserMayNotChangePassword:$false `
                     -AccountNeverExpires `
                     -ErrorAction Stop
        
        Write-Log "  Created user account: $username"
        
        # Add user to Remote Desktop Users group
        Add-LocalGroupMember -Group "Remote Desktop Users" -Member $username -ErrorAction Stop
        Write-Log "  Added to Remote Desktop Users group"
        
        # Add user to Users group (for QuickBooks access)
        Add-LocalGroupMember -Group "Users" -Member $username -ErrorAction SilentlyContinue
        
        # Set user to change password at next logon if required
        if ($ForcePasswordChange) {
            $user = Get-LocalUser -Name $username
            $user | Set-LocalUser -PasswordNeverExpires $false
            Write-Log "  Configured password change requirement"
        }
        
        # Create user profile directory
        $profilePath = "C:\Users\$username"
        New-Item -ItemType Directory -Path $profilePath -Force -ErrorAction SilentlyContinue | Out-Null
        
        # Set permissions for QuickBooks data access
        $qbDataPath = "C:\ProgramData\Intuit\QuickBooks\Company Files"
        if (Test-Path $qbDataPath) {
            icacls $qbDataPath /grant "${username}:(OI)(CI)M" /T | Out-Null
            Write-Log "  Granted QuickBooks data access"
        }
        
        $successCount++
        $results += [PSCustomObject]@{
            Username = $username
            FullName = $fullName
            Email = $user.Email
            Department = $user.Department
            Status = "Success"
            Reason = "User created successfully"
        }
        
        Write-Log "  SUCCESS: User $username created successfully"
        
    } catch {
        $failCount++
        $errorMsg = $_.Exception.Message
        Write-Log "  ERROR: Failed to create user $username - $errorMsg"
        
        $results += [PSCustomObject]@{
            Username = $username
            FullName = $fullName
            Status = "Failed"
            Reason = $errorMsg
        }
    }
}

# Export results
$resultsPath = "C:\Logs\UserCreation_Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $resultsPath -NoTypeInformation
Write-Log "Results exported to: $resultsPath"

# Summary
Write-Log "=== User Creation Summary ==="
Write-Log "Total users processed: $($users.Count)"
Write-Log "Successfully created: $successCount"
Write-Log "Failed: $failCount"
Write-Log "Skipped: $($users.Count - $successCount - $failCount)"
Write-Log "=== Script Completed ==="

# Display next steps
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "1. Run Configure-Office365.ps1 to setup Office 365 profiles"
Write-Host "2. Run Setup-PrinterRedirection.ps1 to configure printer mapping"
Write-Host "3. Run Configure-OneDrive.ps1 to setup OneDrive sync"
Write-Host "4. Test RDP access from on-premise network"
Write-Host "5. Distribute credentials to users securely`n" -ForegroundColor Green
