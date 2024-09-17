#$ErrorActionPreference = $env:ErrorActionPreference

$Env:ArcBoxDir = "C:\ArcBox"
$Env:ArcBoxLogsDir = "$Env:ArcBoxDir\Logs"
$Env:ArcBoxVMDir = "F:\Virtual Machines"
$Env:ArcBoxIconDir = "$Env:ArcBoxDir\Icons"
$Env:ArcBoxTestsDir = "$Env:ArcBoxDir\Tests"
$Env:ArcBoxDscDir = "$Env:ArcBoxDir\DSC"
$agentScript = "$Env:ArcBoxDir\agentScript"

# Set variables to execute remote powershell scripts on guest VMs
$nestedVMArcBoxDir = $Env:ArcBoxDir
$spnTenantId = $env:spnTenantId
$subscriptionId = $env:subscriptionId
$azureLocation = $env:azureLocation
$resourceGroup = $env:resourceGroup
#$resourceTags = $env:resourceTags
$namingPrefix = $env:namingPrefix

$changeTrackingDCR = $env:changeTrackingDCR
$vmInsightsDCR = $env:vmInsightsDCR

# Moved VHD storage account details here to keep only in place to prevent duplicates.
$vhdSourceFolder = "https://jumpstartprodsg.blob.core.windows.net/arcbox/prod/*"
$vhdSourceFolderESU = "https://jumpstartprodsg.blob.core.windows.net/scenarios/prod/*"

# Archive existing log file and create new one
$logFilePath = "$Env:ArcBoxLogsDir\ArcServersLogonScript.log"
if (Test-Path $logFilePath) {
    $archivefile = "$Env:ArcBoxLogsDir\ArcServersLogonScript-" + (Get-Date -Format "yyyyMMddHHmmss")
    Rename-Item -Path $logFilePath -NewName $archivefile -Force
}

Start-Transcript -Path $logFilePath -Force -ErrorAction SilentlyContinue

# Remove registry keys that are used to automatically logon the user (only used for first-time setup)
$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$keys = @("AutoAdminLogon", "DefaultUserName", "DefaultPassword")

foreach ($key in $keys) {
    try {
        $property = Get-ItemProperty -Path $registryPath -Name $key -ErrorAction Stop
        Remove-ItemProperty -Path $registryPath -Name $key
        Write-Host "Removed registry key that are used to automatically logon the user: $key"
    }
    catch {
        Write-Verbose "Key $key does not exist."
    }
}

# Create Windows Terminal desktop shortcut
$WshShell = New-Object -comObject WScript.Shell
$WinTerminalPath = (Get-ChildItem "C:\Program Files\WindowsApps" -Recurse | Where-Object { $_.name -eq "wt.exe" }).FullName
$Shortcut = $WshShell.CreateShortcut("$Env:USERPROFILE\Desktop\Windows Terminal.lnk")
$Shortcut.TargetPath = $WinTerminalPath
$shortcut.WindowStyle = 3
$shortcut.Save()

# Create desktop shortcut for Logs-folder
$WshShell = New-Object -comObject WScript.Shell
$LogsPath = "C:\ArcBox\Logs"
$Shortcut = $WshShell.CreateShortcut("$Env:USERPROFILE\Desktop\Logs.lnk")
$Shortcut.TargetPath = $LogsPath
$shortcut.WindowStyle = 3
$shortcut.Save()

# Configure Windows Terminal as the default terminal application
$registryPath = "HKCU:\Console\%%Startup"

if (Test-Path $registryPath) {
    Set-ItemProperty -Path $registryPath -Name "DelegationConsole" -Value "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"
    Set-ItemProperty -Path $registryPath -Name "DelegationTerminal" -Value "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}"
}
else {
    New-Item -Path $registryPath -Force | Out-Null
    Set-ItemProperty -Path $registryPath -Name "DelegationConsole" -Value "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"
    Set-ItemProperty -Path $registryPath -Name "DelegationTerminal" -Value "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}"
}


################################################
# Setup Hyper-V server before deploying VMs for each flavor
################################################
# Install and configure DHCP service (used by Hyper-V nested VMs)
Write-Host "Configuring DHCP Service"
$dnsClient = Get-DnsClient | Where-Object { $_.InterfaceAlias -eq "Ethernet" }
$dhcpScope = Get-DhcpServerv4Scope
if ($dhcpScope.Name -ne "ArcBox") {
    Add-DhcpServerv4Scope -Name "ArcBox" `
        -StartRange 10.10.1.100 `
        -EndRange 10.10.1.200 `
        -SubnetMask 255.255.255.0 `
        -LeaseDuration 1.00:00:00 `
        -State Active
}

$dhcpOptions = Get-DhcpServerv4OptionValue
if ($dhcpOptions.Count -lt 3) {
    Set-DhcpServerv4OptionValue -ComputerName localhost `
        -DnsDomain $dnsClient.ConnectionSpecificSuffix `
        -DnsServer 168.63.129.16, 10.16.2.100 `
        -Router 10.10.1.1 `
        -Force
}

# Create the NAT network
Write-Host "Creating Internal NAT"
$natName = "InternalNat"
$netNat = Get-NetNat
if ($netNat.Name -ne $natName) {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 10.10.1.0/24
}

# Create an internal switch with NAT
Write-Host "Creating Internal vSwitch"
$switchName = 'InternalNATSwitch'

# Verify if internal switch is already created, if not create a new switch
$inernalSwitch = Get-VMSwitch
if ($inernalSwitch.Name -ne $switchName) {
    New-VMSwitch -Name $switchName -SwitchType Internal
    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*" + $switchName + "*" }

    # Create an internal network (gateway first)
    Write-Host "Creating Gateway"
    New-NetIPAddress -IPAddress 10.10.1.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex

    # Enable Enhanced Session Mode on Host
    Write-Host "Enabling Enhanced Session Mode"
    Set-VMHost -EnableEnhancedSessionMode $true
}

Write-Host "Creating demo VM Credentials"
# Hard-coded username and password for the nested demo VMs
$nestedWindowsUsername = "Administrator"
$nestedWindowsPassword = "JS123!!"

# Hard-coded username and password for the nested demo 2012 VM
$nestedWindows2k12Username = "Administrator"
$nestedWindows2k12Password = "JS123!!"

# Create Windows credential object
$secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
$winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

# Create Windows credential object for 2012
$secWindows2k12Password = ConvertTo-SecureString $nestedWindows2k12Password -AsPlainText -Force
$win2k12Creds = New-Object System.Management.Automation.PSCredential ($nestedWindows2k12Username, $secWindows2k12Password)

# Creating Hyper-V Manager desktop shortcut
Write-Host "Creating Hyper-V Shortcut"
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\All Users\Desktop" -Force

# Configure the ArcBox Hyper-V host to allow the nested VMs onboard as Azure Arc-enabled servers
<#Write-Host "Blocking IMDS"
Write-Output "Configure the ArcBox VM to allow the nested VMs onboard as Azure Arc-enabled servers"
Set-Service WindowsAzureGuestAgent -StartupType Disabled -Verbose
Stop-Service WindowsAzureGuestAgent -Force -Verbose

if (!(Get-NetFirewallRule -Name BlockAzureIMDS -ErrorAction SilentlyContinue).Enabled) {
    New-NetFirewallRule -Name BlockAzureIMDS -DisplayName "Block access to Azure IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254
}#>

$cliDir = New-Item -Path "$Env:ArcBoxDir\.cli\" -Name ".servers" -ItemType Directory -Force
if (-not $($cliDir.Parent.Attributes.HasFlag([System.IO.FileAttributes]::Hidden))) {
    $folder = Get-Item $cliDir.Parent.FullName -ErrorAction SilentlyContinue
    $folder.Attributes += [System.IO.FileAttributes]::Hidden
}

$Env:AZURE_CONFIG_DIR = $cliDir.FullName

# Install Azure CLI extensions
Write-Host "Az CLI extensions"
az extension add --name ssh --yes --only-show-errors
az extension add --name log-analytics-solution --yes --only-show-errors
az extension add --name connectedmachine --yes --only-show-errors
az extension add --name monitor-control-service --yes --only-show-errors

#Write-Header "Az CLI extensions"

# az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors

# @("ssh", "log-analytics-solution", "connectedmachine", "monitor-control-service") |
# ForEach-Object -Parallel {
#     az extension add --name $PSItem --yes --only-show-errors
# }

# Required for CLI commands
Write-Host "Az CLI Login"
az login --identity
az account set -s $subscriptionId

# Connect to azure using azure powershell
$null = Connect-AzAccount -Identity -Tenant $spnTenantId
$null = Select-AzSubscription -SubscriptionId $subscriptionId
$accessToken = ConvertFrom-SecureString ((Get-AzAccessToken -AsSecureString).Token) -AsPlainText

Set-AzContext -Subscription $subscriptionId -tenant $spnTenantId
# Onboard nested Windows and Linux VMs to Azure Arc
  
Write-Header "Fetching Nested VMs"

$Win2k19vmName = "$namingPrefix-Win2K19"
$win2k19vmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Win2K19.vhdx"

$Win2k22vmName = "$namingPrefix-Win2K22"
$Win2k22vmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Win2K22.vhdx"

$Ubuntu01vmName = "$namingPrefix-Ubuntu-01"
$Ubuntu01vmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Ubuntu-01.vhdx"

$Ubuntu02vmName = "$namingPrefix-Ubuntu-02"
$Ubuntu02vmvhdPath = "${Env:ArcBoxVMDir}\ArcBox-Ubuntu-02.vhdx"

$Win2k12vmName = "JSWin2K12Base"
$Win2k12MachineName = "$namingPrefix-Win2k12"
$win2k12vmvhdPath = "${Env:ArcBoxVMDir}\${Win2k12vmName}.vhdx"
        
$SQLvmName = "$namingPrefix-SQL"
$SQLvmvhdPath = "$Env:ArcBoxVMDir\${SQLvmName}.vhdx"
 
# Verify if VHD files already downloaded especially when re-running this script
if (!((Test-Path $win2k19vmvhdPath) -and (Test-Path $Win2k22vmvhdPath) -and (Test-Path $Ubuntu01vmvhdPath) -and (Test-Path $Ubuntu02vmvhdPath) -and (Test-Path $win2k12vmvhdPath) -and (Test-Path $SQLvmvhdPath))) {
    <# Action when all if and elseif conditions are false #>
    $Env:AZCOPY_BUFFER_GB = 4
    Write-Output "Downloading nested VMs VHDX files. This can take some time, hold tight..."
    azcopy cp $vhdSourceFolder $Env:ArcBoxVMDir --include-pattern "ArcBox-Win2K19.vhdx;ArcBox-Win2K22.vhdx;ArcBox-Ubuntu-01.vhdx;ArcBox-Ubuntu-02.vhdx;ArcBox-SQL.vhdx" --recursive=true --check-length=false --log-level=ERROR
    azcopy cp $vhdSourceFolderESU $Env:ArcBoxVMDir --include-pattern "${Win2k12vmName}.vhdx;" --recursive=true --check-length=false --log-level=ERROR --check-md5 NoCheck
}

        

# Create the nested VMs if not already created
Write-Header "Create Hyper-V VMs"
$serversDscConfigurationFile = "$Env:ArcBoxDscDir\virtual_machines_itpro.dsc.yml"
        (Get-Content -Path $serversDscConfigurationFile) -replace 'namingPrefixStage', $namingPrefix | Set-Content -Path $serversDscConfigurationFile
winget configure --file C:\ArcBox\DSC\virtual_machines_itpro.dsc.yml --accept-configuration-agreements --disable-interactivity

# Configure WinRM for 2012 machine
$2012Machine = Get-VM $Win2k12MachineName
$privateIpAddress = $2012Machine.networkAdapters.ipaddresses[0]
Enable-PSRemoting
set-item wsman:\localhost\client\trustedhosts -Concatenate -value $privateIpAddress -Force
set-item wsman:\localhost\client\trustedhosts -Concatenate -value "$Win2k12vmName" -Force
Restart-Service WinRm -Force
$file = "C:\Windows\System32\drivers\etc\hosts"
$hostfile = Get-Content $file
$hostfile += "$privateIpAddress $Win2k12vmName"
Set-Content -Path $file -Value $hostfile -Force

Write-Header "Creating Linux VM Credentials"
# Hard-coded username and password for the nested VMs
$nestedLinuxUsername = "jumpstart"
$nestedLinuxPassword = "JS123!!"

# Create Windows credential object for 2012
#$secWindows2k12Password = ConvertTo-SecureString $nestedWindows2k12Password -AsPlainText -Force
#$win2k12Creds = New-Object System.Management.Automation.PSCredential ($nestedWindows2k12Username, $secWindows2k12Password)


# Create Linux credential object
$secLinuxPassword = ConvertTo-SecureString $nestedLinuxPassword -AsPlainText -Force
$linCreds = New-Object System.Management.Automation.PSCredential ($nestedLinuxUsername, $secLinuxPassword)

# Restarting Windows VM Network Adapters
Write-Host "Restarting Network Adapters"
Start-Sleep -Seconds 30
Invoke-Command -VMName $Win2k19vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
Invoke-Command -VMName $Win2k22vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
$session = New-PSSession -ComputerName $Win2k12vmName -Credential $win2k12Creds
Invoke-Command -session $session -Script {Get-NetAdapter | Restart-NetAdapter} -AsJob | Receive-Job -Wait
Exit-PSSession
Invoke-Command -VMName $SQLvmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds

Start-Sleep -Seconds 10

# Renaming 2012 machine
Invoke-Command -ComputerName $Win2k12vmName -ScriptBlock { Rename-Computer -NewName $using:Win2k12MachineName -Restart} -Credential $win2k12Creds

# Getting the Ubuntu nested VM IP address
$Ubuntu01VmIp = Get-VM -Name $Ubuntu01vmName | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses | Select-Object -Index 0
$Ubuntu02VmIp = Get-VM -Name $Ubuntu02vmName | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses | Select-Object -Index 0

# # Configuring SSH for accessing Linux VMs
# Write-Output "Generating SSH key for accessing nested Linux VMs"

# $null = New-Item -Path ~ -Name .ssh -ItemType Directory
# ssh-keygen -t rsa -N '' -f $Env:USERPROFILE\.ssh\id_rsa

# Copy-Item -Path "$Env:USERPROFILE\.ssh\id_rsa.pub" -Destination "$Env:TEMP\authorized_keys"

# # Automatically accept unseen keys but will refuse connections for changed or invalid hostkeys.
# Add-Content -Path "$Env:USERPROFILE\.ssh\config" -Value "StrictHostKeyChecking=accept-new"

# Get-VM *Ubuntu* | Copy-VMFile -SourcePath "$Env:TEMP\authorized_keys" -DestinationPath "/home/$nestedLinuxUsername/.ssh/" -FileSource Host -Force -CreateFullPath

# if ($namingPrefix -ne "ArcBox") {

#     # Renaming the nested linux VMs
#     Write-Output "Renaming the nested Linux VMs"

#     Invoke-Command -HostName $Ubuntu01VmIp -KeyFilePath "$Env:USERPROFILE\.ssh\id_rsa" -UserName $nestedLinuxUsername -ScriptBlock {

#         Invoke-Expression "sudo hostnamectl set-hostname $using:ubuntu01vmName;sudo systemctl reboot"

#     }

#     Restart-VM -Name $ubuntu01vmName

#     Invoke-Command -HostName $Ubuntu02VmIp -KeyFilePath "$Env:USERPROFILE\.ssh\id_rsa" -UserName $nestedLinuxUsername -ScriptBlock {

#         Invoke-Expression "sudo hostnamectl set-hostname $using:ubuntu02vmName;sudo systemctl reboot"

#     }

#     Restart-VM -Name $ubuntu02vmName

# }

# Get-VM *Ubuntu* | Wait-VM -For IPAddress

# Write-Host "Waiting for the nested Linux VMs to come back online...waiting for 10 seconds"

Start-Sleep -Seconds 10

# Copy installation script to nested Windows VMs
Write-Output "Transferring installation script to nested Windows VMs..."
Copy-VMFile $Win2k19vmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force
#Copy-VMFile $Win2k22vmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force
Copy-VMFile $Win2k12MachineName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force

#Copy-VMFile $SQLvmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force
Copy-VMFile $SQLvmName -SourcePath "$agentScript\testDefenderForSQL.ps1" -DestinationPath "$Env:ArcBoxDir\testDefenderForSQL.ps1" -CreateFullPath -FileSource Host -Force
Copy-VMFile $SQLvmName -SourcePath "$agentScript\SqlAdvancedThreatProtectionShell.psm1" -DestinationPath "$Env:ArcBoxDir\SqlAdvancedThreatProtectionShell.psm1" -CreateFullPath -FileSource Host -Force


# Update Linux VM onboarding script connect toAzure Arc, get new token as it might have been expired by the time execution reached this line.
$accessToken = ConvertFrom-SecureString ((Get-AzAccessToken -AsSecureString).Token) -AsPlainText
        (Get-Content -path "$agentScript\installArcAgentUbuntu.sh" -Raw) -replace '\$accessToken', "'$accessToken'" -replace '\$resourceGroup', "'$resourceGroup'" -replace '\$spnTenantId', "'$Env:spnTenantId'" -replace '\$azureLocation', "'$Env:azureLocation'" -replace '\$subscriptionId', "'$subscriptionId'" | Set-Content -Path "$agentScript\installArcAgentModifiedUbuntu.sh"

# Download and restore AdventureWorks Database to SQLvm
Write-Host "Restoring AdventureWorks database"
Copy-VMFile $SQLvmName -SourcePath "$Env:ArcBoxDir\AdventureWorksLT2019.bak" -DestinationPath "$Env:ArcBoxDir\AdventureWorksLT2019.bak" -CreateFullPath -FileSource Host -Force
Start-Sleep -Seconds 3
Invoke-Command -VMName $SQLvmName -ScriptBlock {Restore-SqlDatabase -ServerInstance $Env:COMPUTERNAME -Database "AdventureWorksLT2019" -BackupFile C:\ArcBox\AdventureWorksLT2019.bak -PassThru -Verbose} -Credential $winCreds

# Copy installation script to nested Linux VMs
Write-Output "Transferring installation script to nested Linux VMs..."
Set-SCPItem -ComputerName $Ubuntu01VmIp -Credential $linCreds -Destination "/home/$nestedLinuxUsername" -Path "$agentScript\installArcAgentModifiedUbuntu.sh" -Force
#Set-SCPItem -ComputerName $Ubuntu02VmIp -Credential $linCreds -Destination "/home/$nestedLinuxUsername" -Path "$agentScript\installArcAgentModifiedUbuntu.sh" -Force


#$Ubuntu02vmvhdPath = "${Env:ArcBoxVMDir}\${Ubuntu02vmName}.vhdx"
Write-Output "Onboarding the nested Windows VMs as Azure Arc-enabled servers"
Invoke-Command -VMName $Win2k19vmName -ScriptBlock { powershell -File $Using:nestedVMArcBoxDir\installArcAgent.ps1  -accessToken $Using:accessToken, -spnTenantId $Using:spnTenantId, -subscriptionId $Using:subscriptionId, -resourceGroup $Using:resourceGroup, -azureLocation $Using:azureLocation } -Credential $winCreds
Invoke-Command -ComputerName $Win2k12vmName -ScriptBlock { powershell -File $Using:nestedVMArcBoxDir\installArcAgent.ps1 -accessToken $Using:accessToken, -spnTenantId $Using:spnTenantId, -subscriptionId $Using:subscriptionId, -resourceGroup $Using:resourceGroup, -azureLocation $Using:azureLocation } -Credential $win2k12Creds

Write-Output "Onboarding the nested Linux VMs as an Azure Arc-enabled servers"
$ubuntuSession = New-SSHSession -ComputerName $Ubuntu01VmIp -Credential $linCreds -Force -WarningAction SilentlyContinue
$Command = "sudo sh /home/$nestedLinuxUsername/installArcAgentModifiedUbuntu.sh"
$(Invoke-SSHCommand -SSHSession $ubuntuSession -Command $Command -Timeout 600 -WarningAction SilentlyContinue).Output
$command = "curl -o ~/Downloads/eicar.com.txt"
$(Invoke-SSHCommand -SSHSession $ubuntuSession -Command $Command -Timeout 600 -WarningAction SilentlyContinue).Output

#############################################################
# Install VSCode extensions
#############################################################
Write-Host "Installing VSCode extensions"
# Install VSCode extensions
$VSCodeExtensions = @(
    'ms-vscode.powershell',
    'esbenp.prettier-vscode',
    'ms-vscode-remote.remote-ssh'
)

foreach ($extension in $VSCodeExtensions) {
    code --install-extension $extension
}

#############################################################
# Install PowerShell 7
#############################################################
Write-Host "Installing PowerShell 7 on the client VM"

Start-Process msiexec.exe -ArgumentList "/I $Env:ArcBoxDir\PowerShell-7.4.1-win-x64.msi /quiet"

Write-Host "Installing PowerShell 7 on the ArcBox-Win2K22 machine"
Copy-VMFile $Win2k22vmName -SourcePath "$Env:ArcBoxDir\PowerShell-7.4.1-win-x64.msi" -DestinationPath "$Env:ArcBoxDir\PowerShell-7.4.1-win-x64.msi" -CreateFullPath -FileSource Host -Force
Invoke-Command -VMName $Win2k22vmName -ScriptBlock { Start-Process msiexec.exe -ArgumentList "/I C:\ArcBox\PowerShell-7.4.1-win-x64.msi /quiet" } -Credential $winCreds

Write-Host "Installing PowerShell 7 on the ArcBox-Win2K19 machine"
Copy-VMFile $Win2k19vmName -SourcePath "$Env:ArcBoxDir\PowerShell-7.4.1-win-x64.msi" -DestinationPath "$Env:ArcBoxDir\PowerShell-7.4.1-win-x64.msi" -CreateFullPath -FileSource Host -Force
Invoke-Command -VMName $Win2k19vmName -ScriptBlock { Start-Process msiexec.exe -ArgumentList "/I C:\ArcBox\PowerShell-7.4.1-win-x64.msi /quiet" } -Credential $winCreds

Write-Host "Installing PowerShell 7 on the nested ArcBox-Ubuntu-01 VM"
$ubuntuSession = New-SSHSession -ComputerName $Ubuntu01VmIp -Credential $linCreds -Force -WarningAction SilentlyContinue
$Command = "wget https://github.com/PowerShell/PowerShell/releases/download/v7.3.3/powershell_7.3.3-1.deb_amd64.deb;sudo dpkg -i /home/jumpstart/powershell_7.3.3-1.deb_amd64.deb"
$(Invoke-SSHCommand -SSHSession $ubuntuSession -Command $Command -Timeout 600 -WarningAction SilentlyContinue).Output

Write-Host "Installing PSWSMan on the Linux VM"
$ubuntuSession = New-SSHSession -ComputerName $Ubuntu01VmIp -Credential $linCreds -Force -WarningAction SilentlyContinue
$Command = "sudo pwsh -command 'Install-Module -Force -PassThru -Name PSWSMan'"
$(Invoke-SSHCommand -SSHSession $ubuntuSession -Command $Command -Timeout 600 -WarningAction SilentlyContinue).Output

Write-Host "Configuring PSWSMan on the Linux VM"
$ubuntuSession = New-SSHSession -ComputerName $Ubuntu01VmIp -Credential $linCreds -Force -WarningAction SilentlyContinue
$Command = "sudo pwsh -command 'Install-WSMan'"
$(Invoke-SSHCommand -SSHSession $ubuntuSession -Command $Command -Timeout 600 -WarningAction SilentlyContinue).Output

#---
Write-Host "Assigning Data collection rules to Arc-enabled machines"
$windowsArcMachine = (Get-AzConnectedMachine -ResourceGroupName $resourceGroup -Name $Win2k19vmName).Id
$linuxArcMachine = (Get-AzConnectedMachine -ResourceGroupName $resourceGroup -Name $Ubuntu01vmName).Id
az monitor data-collection rule association create --name "vmInsighitsWindows" --rule-id $vmInsightsDCR --resource $windowsArcMachine --only-show-errors
az monitor data-collection rule association create --name "vmInsighitsLinux" --rule-id $vmInsightsDCR --resource $LinuxArcMachine --only-show-errors
az monitor data-collection rule association create --name "changeTrackingWindows" --rule-id $changeTrackingDCR --resource $windowsArcMachine --only-show-errors
az monitor data-collection rule association create --name "changeTrackingLinux" --rule-id $changeTrackingDCR --resource $LinuxArcMachine --only-show-errors

Write-Host "Installing the AMA agent on the Arc-enabled machines"
az connectedmachine extension create --name AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor --type AzureMonitorWindowsAgent --machine-name $Win2k19vmName --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade true --no-wait
az connectedmachine extension create --name AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor --type AzureMonitorLinuxAgent --machine-name $Ubuntu01vmName --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade true --no-wait

Write-Host "Installing the changeTracking agent on the Arc-enabled machines"
az connectedmachine extension create --name ChangeTracking-Windows --publisher Microsoft.Azure.ChangeTrackingAndInventory --type-handler-version 2.20 --type ChangeTracking-Windows --machine-name $Win2k19vmName --resource-group $resourceGroup  --location $azureLocation --enable-auto-upgrade --no-wait
az connectedmachine extension create --name ChangeTracking-Linux --publisher Microsoft.Azure.ChangeTrackingAndInventory --type-handler-version 2.20 --type ChangeTracking-Linux --machine-name $Ubuntu01vmName --resource-group $resourceGroup  --location $azureLocation --enable-auto-upgrade --no-wait

Write-Host "Installing the Azure Update Manager agent on the Arc-enabled machines"
az connectedmachine assess-patches --resource-group $resourceGroup --name $Win2k19vmName --no-wait
az connectedmachine assess-patches --resource-group $resourceGroup --name $Ubuntu01vmName --no-wait

# Write-Host "Installing the AdminCenter extension on the Arc-enabled windows machine"
## $Setting = "{'port':'6516'}"
#$Setting = '{\"port\":\"6516\"}'
# az connectedmachine extension create --name AdminCenter --publisher Microsoft.AdminCenter --type AdminCenter --machine-name $Win2k19vmName --resource-group $resourceGroup --location $azureLocation --settings $Setting --enable-auto-upgrade --no-wait
# $putPayload = "{'properties': {'type': 'default'}}"
# Invoke-AzRestMethod -Method PUT -Uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$Win2k19vmName/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15" -Payload $putPayload
# $patch = @{ "properties" =  @{ "serviceName" = "WAC"; "port" = 6516}}
# $patchPayload = ConvertTo-Json $patch
# Invoke-AzRestMethod -Method PUT -Path /subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$Win2k19vmName/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/WAC?api-version=2023-03-15 -Payload $patchPayload
#$port = "6516"
#$portint = 6516
#$Setting = @{"port" = $port} 
#New-AzConnectedMachineExtension -Name "AdminCenter" -ResourceGroupName $resourceGroup -MachineName $Win2k19vmName -Location $azureLocation -Publisher "Microsoft.AdminCenter" -Settings $Setting -ExtensionType "AdminCenter" -EnableAutomaticUpgrade -NoWait
#$putPayload = "{'properties': {'type': 'default'}}"
#Invoke-AzRestMethod -Method PUT -Uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$Win2k19vmName/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15" -Payload $putPayload
#$patch = @{ "properties" =  @{ "serviceName" = "WAC"; "port" = $portint}} 
#$patchPayload = ConvertTo-Json $patch 
#Invoke-AzRestMethod -Method PUT -Path /subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$Win2k19vmName/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/WAC?api-version=2023-03-15 -Payload $patchPayload

Write-Host "Installing the dependencyAgent extension on the Arc-enabled windows machine"
$dependencyAgentSetting = '{\"enableAMA\":\"true\"}'
az connectedmachine extension create --name DependencyAgent --publisher Microsoft.Azure.Monitoring.DependencyAgent --type-handler-version 9.10 --type DependencyAgentWindows --machine-name $Win2k19vmName --settings $dependencyAgentSetting --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade --no-wait

Write-Host "Enabling SSH access to Arc-enabled servers"
$VMs = @("ArcBox-Ubuntu-01", "ArcBox-Win2K19")
$VMs | ForEach-Object -Parallel {
    $spnTenantId  =  $Using:spnTenantId
    $subscriptionId  =  $Using:subscriptionId
    $resourceGroup  =  $Using:resourceGroup

    $null = Connect-AzAccount -Identity -Tenant $spntenantId -Subscription $subscriptionId -Scope Process -WarningAction SilentlyContinue
    $null = Select-AzSubscription -SubscriptionId $subscriptionId

    $vm = $PSItem
    $connectedMachine = Get-AzConnectedMachine -Name $vm -ResourceGroupName $resourceGroup -SubscriptionId $subscriptionId

    $connectedMachineEndpoint = (Invoke-AzRestMethod -Method get -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15").Content | ConvertFrom-Json

    if (-not ($connectedMachineEndpoint.properties | Where-Object { $_.type -eq "default" -and $_.provisioningState -eq "Succeeded" })) {
        Write-Output "Creating default endpoint for $($connectedMachine.Name)"
        $null = Invoke-AzRestMethod -Method put -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15" -Payload '{"properties": {"type": "default"}}'
    }
    $connectedMachineSshEndpoint = (Invoke-AzRestMethod -Method get -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15").Content | ConvertFrom-Json

    if (-not ($connectedMachineSshEndpoint.properties | Where-Object { $_.serviceName -eq "SSH" -and $_.provisioningState -eq "Succeeded" })) {
        Write-Output "Enabling SSH on $($connectedMachine.Name)"
        $null = Invoke-AzRestMethod -Method put -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15" -Payload '{"properties": {"serviceName": "SSH", "port": 22}}'
    }
    else {
        Write-Output "SSH already enabled on $($connectedMachine.Name)"
    }

}

# Removing the LogonScript Scheduled Task so it won't run on next reboot
Write-Host "Removing Logon Task"
if ($null -ne (Get-ScheduledTask -TaskName "ArcServersLogonScript" -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskName "ArcServersLogonScript" -Confirm:$false
}

# Executing the deployment logs bundle PowerShell script in a new window
Write-Host "Uploading Log Bundle"
Invoke-Expression 'cmd /c start Powershell -Command {
$RandomString = -join ((48..57) + (97..122) | Get-Random -Count 6 | % {[char]$_})
Write-Host "Sleeping for 5 seconds before creating deployment logs bundle..."
Start-Sleep -Seconds 5
Write-Host "`n"
Write-Host "Creating deployment logs bundle"
7z a $Env:ArcBoxLogsDir\LogsBundle-"$RandomString".zip $Env:ArcBoxLogsDir\*.log
}'

# Changing to Jumpstart ArcBox wallpaper
# Changing to Client VM wallpaper
$imgPath = "$Env:ArcBoxDir\wallpaper.png"
$code = @' 
using System.Runtime.InteropServices; 
namespace Win32{ 
    
    public class Wallpaper{ 
        [DllImport("user32.dll", CharSet=CharSet.Auto)] 
        static extern int SystemParametersInfo (int uAction , int uParam , string lpvParam , int fuWinIni) ; 
        
        public static void SetWallpaper(string thePath){
            SystemParametersInfo(20,0,thePath,3);
        }
    }
}
'@

# Set wallpaper image based on the ArcBox Flavor deployed
Write-Host "Changing Wallpaper"
$imgPath = "$Env:ArcBoxDir\wallpaper.png"
Add-Type $code
[Win32.Wallpaper]::SetWallpaper($imgPath)

<# Send telemtry
$Url = "https://arcboxleveluptelemtry.azurewebsites.net/api/triggerDeployment?"
$rowKey = -join ((97..122) | Get-Random -Count 10 | ForEach-Object { [char]$_ })
$headers = @{
    'Content-Type' = 'application/json'
}
$Body = @{
    Location     = $azureLocation
    PartitionKey = "Location"
    RowKey       = $rowKey
}
$Body = $Body | ConvertTo-Json
Invoke-RestMethod -Method 'Post' -Uri $url -Body $body -Headers $headers
#>
Stop-Transcript

# Write-Header "Enabling SSH access and triggering update assessment for Arc-enabled servers"
# $VMs = @("$namingPrefix-SQL", "$namingPrefix-Ubuntu-01", "$namingPrefix-Ubuntu-02", "$namingPrefix-Win2K19", "$namingPrefix-Win2K22")
# $VMs | ForEach-Object -Parallel {
#     $null = Connect-AzAccount -Identity -Tenant $using:spnTenantId -Subscription $using:subscriptionId -Scope Process -WarningAction SilentlyContinue

#     $vm = $PSItem
#     $connectedMachine = Get-AzConnectedMachine -Name $vm -ResourceGroupName $using:resourceGroup -SubscriptionId $using:subscriptionId
#     $connectedMachineEndpoint = (Invoke-AzRestMethod -Method get -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15").Content | ConvertFrom-Json

#     if (-not ($connectedMachineEndpoint.properties | Where-Object { $_.type -eq "default" -and $_.provisioningState -eq "Succeeded" })) {
#         Write-Output "Creating default endpoint for $($connectedMachine.Name)"
#         $null = Invoke-AzRestMethod -Method put -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15" -Payload '{"properties": {"type": "default"}}'
#     }
#     $connectedMachineSshEndpoint = (Invoke-AzRestMethod -Method get -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15").Content | ConvertFrom-Json

#     if (-not ($connectedMachineSshEndpoint.properties | Where-Object { $_.serviceName -eq "SSH" -and $_.provisioningState -eq "Succeeded" })) {
#         Write-Output "Enabling SSH on $($connectedMachine.Name)"
#         $null = Invoke-AzRestMethod -Method put -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15" -Payload '{"properties": {"serviceName": "SSH", "port": 22}}'
#     }
#     else {
#         Write-Output "SSH already enabled on $($connectedMachine.Name)"
#     }

#     Write-Output "Triggering Update Manager assessment on $($connectedMachine.Name)"
#     $null = Invoke-AzRestMethod -Method POST -Path "/subscriptions/$($using:subscriptionId)/resourceGroups/$($using:resourceGroup)/providers/Microsoft.HybridCompute/machines/$($connectedMachine.Name)/assessPatches?api-version=2020-08-15-preview" -Payload '{}'

# }



# # Removing the LogonScript Scheduled Task so it won't run on next reboot
# Write-Header "Removing Logon Task"
# if ($null -ne (Get-ScheduledTask -TaskName "ArcServersLogonScript" -ErrorAction SilentlyContinue)) {
#     Unregister-ScheduledTask -TaskName "ArcServersLogonScript" -Confirm:$false
# }


# #Changing to Jumpstart ArcBox wallpaper

# Write-Header "Changing wallpaper"

# # bmp file is required for BGInfo
# Convert-JSImageToBitMap -SourceFilePath "$Env:ArcBoxDir\wallpaper.png" -DestinationFilePath "$Env:ArcBoxDir\wallpaper.bmp"

# Set-JSDesktopBackground -ImagePath "$Env:ArcBoxDir\wallpaper.bmp"

# if ($Env:flavor -eq "ITPro") {

#     Write-Header "Running tests to verify infrastructure"

#     & "$Env:ArcBoxTestsDir\Invoke-Test.ps1"

# }

# Write-Header "Creating deployment logs bundle"

# $RandomString = -join ((48..57) + (97..122) | Get-Random -Count 6 | % { [char]$_ })
# $LogsBundleTempDirectory = "$Env:windir\TEMP\LogsBundle-$RandomString"
# $null = New-Item -Path $LogsBundleTempDirectory -ItemType Directory -Force

# #required to avoid "file is being used by another process" error when compressing the logs
# Copy-Item -Path "$Env:ArcBoxLogsDir\*.log" -Destination $LogsBundleTempDirectory -Force -PassThru
# Compress-Archive -Path "$LogsBundleTempDirectory\*.log" -DestinationPath "$Env:ArcBoxLogsDir\LogsBundle-$RandomString.zip" -PassThru

# Stop-Transcript