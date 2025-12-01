function Init-SecretSantaWebsite {
# Ensure script runs as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: Please run this script as Administrator." -ForegroundColor Red
    exit 1
}

Start-Transcript -Path "C:\Scripts\Init-SecretSanta.log" -Append

Import-Module WebAdministration

# Unlock handlers section
Write-Host "Unlocking IIS configuration section: system.webServer/handlers"
Set-WebConfiguration -Filter "system.webServer/handlers" -PSPath "MACHINE/WEBROOT/APPHOST" -Metadata overrideMode -Value Allow

# Install ASP.NET 4.5
Write-Host "Installing ASP.NET feature for IIS..."
Install-WindowsFeature Web-Asp-Net45

# Restart IIS
Write-Host "Restarting IIS..."
iisreset

# Variables
$siteName = "tim-brown.co.uk"
$appPools = @("TimBrown", "Secret Santa")
$sitePath = "C:\inetpub\wwwroot\TimBrown"
$appPath = "C:\inetpub\wwwroot\SecretSanta"
$identities = @{
    "TimBrown"      = "FATBOY\web_TimBrown"
    "Secret Santa"  = "FATBOY\web_SecretSanta"
}

# Validate paths
$missingPaths = @()
if (-not (Test-Path $sitePath)) { $missingPaths += $sitePath }
if (-not (Test-Path $appPath)) { $missingPaths += $appPath }

if ($missingPaths.Count -gt 0) {
    Write-Host "ERROR: Missing paths:" -ForegroundColor Red
    $missingPaths | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
    Stop-Transcript
    exit 1
}

# Hosts entries
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"
$hostsEntries = @("127.0.0.1 tim-brown.co.uk","127.0.0.1 www.tim-brown.co.uk")
foreach ($entry in $hostsEntries) {
    if (-not (Select-String -Path $hostsPath -Pattern $entry -Quiet)) {
        Add-Content -Path $hostsPath -Value $entry
        Write-Host "Added hosts entry: $entry"
    }
}

# Remove old IIS objects
foreach ($pool in $appPools) {
    if (Test-Path "IIS:\AppPools\$pool") { Remove-WebAppPool -Name $pool }
}
if (Test-Path "IIS:\Sites\$siteName") { Remove-Website -Name $siteName }

# Prompt for passwords
$credentials = @{}
foreach ($pool in $appPools) {
    $identity = $identities[$pool]
    $securePassword = Read-Host "Enter password for $identity" -AsSecureString
    $credentials[$pool] = $securePassword
}

# Create AppPools
function Create-AppPool($name,$identity,$password){
    New-WebAppPool -Name $name
    Set-ItemProperty "IIS:\AppPools\$name" managedRuntimeVersion "v4.0"
    Set-ItemProperty "IIS:\AppPools\$name" managedPipelineMode "Classic"
    Set-ItemProperty "IIS:\AppPools\$name" processModel.identityType "SpecificUser"
    Set-ItemProperty "IIS:\AppPools\$name" processModel.userName $identity
    $plainPassword=[System.Net.NetworkCredential]::new("",$password).Password
    Set-ItemProperty "IIS:\AppPools\$name" processModel.password $plainPassword
    Set-ItemProperty "IIS:\AppPools\$name" processModel.loadUserProfile $false
}
Create-AppPool "TimBrown" $identities["TimBrown"] $credentials["TimBrown"]
Create-AppPool "Secret Santa" $identities["Secret Santa"] $credentials["Secret Santa"]

# Grant "Log on as batch job"
function Grant-BatchLogonRight($Account){
    $tempFile="$env:TEMP\secedit.inf";$backupFile="$env:TEMP\secedit.sdb"
    secedit /export /cfg $tempFile /areas USER_RIGHTS
    $content=Get-Content $tempFile;$right="SeBatchLogonRight"
    $line=$content|Where-Object{$_-match"^$right"}
    if($line){if($line -notmatch $Account){$content=$content -replace "^$right.*", "$line,$Account"}}else{$content+="$right = $Account"}
    $content|Set-Content $tempFile
    secedit /configure /db $backupFile /cfg $tempFile /areas USER_RIGHTS
    gpupdate /force
}
foreach($identity in $identities.Values){Grant-BatchLogonRight $identity}

# NTFS permissions
foreach($identity in $identities.Values){
    foreach($path in @($sitePath,$appPath)){
        $acl=Get-Acl $path
        $rule=New-Object System.Security.AccessControl.FileSystemAccessRule($identity,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")
        $acl.AddAccessRule($rule);Set-Acl $path $acl
    }
}

# Create Website
New-Website -Name $siteName -PhysicalPath $sitePath -ApplicationPool "TimBrown" -Port 80 -HostHeader "tim-brown.co.uk"
New-WebBinding -Name $siteName -Protocol http -Port 80 -HostHeader "www.tim-brown.co.uk"
New-WebBinding -Name $siteName -Protocol ftp -Port 21

# HTTPS with self-signed cert

# Always refresh: Remove existing certificates and SSL bindings
Write-Host "Refreshing certificates and SSL bindings..." -ForegroundColor Cyan

# Remove existing certificates for DNS names
$dnsNames = @("tim-brown.co.uk","www.tim-brown.co.uk")
$existingCerts = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.DnsNameList -contains "tim-brown.co.uk" -or $_.DnsNameList -contains "www.tim-brown.co.uk" }
foreach ($certItem in $existingCerts) {
    Write-Host "Removing existing certificate: $($certItem.Subject)" -ForegroundColor Yellow
    Remove-Item -Path $certItem.PSPath -Force
}

# Remove all existing SSL bindings for port 443
$sslBindings = Get-ChildItem "IIS:\SslBindings" | Where-Object { $_.BindingInformation -like "*:443:*" }
foreach ($binding in $sslBindings) {
    Write-Host "Removing existing SSL binding: $($binding.BindingInformation)" -ForegroundColor Yellow
    Remove-Item -Path $binding.PSPath -Force
}

Write-Host "Creating self-signed certificate..."
$cert=New-SelfSignedCertificate -DnsName "tim-brown.co.uk","www.tim-brown.co.uk" -CertStoreLocation "cert:\LocalMachine\My"
New-WebBinding -Name $siteName -Protocol https -Port 443 -HostHeader "tim-brown.co.uk"
New-WebBinding -Name $siteName -Protocol https -Port 443 -HostHeader "www.tim-brown.co.uk"

Stop-Website -Name $siteName
Get-WebBinding -Name $siteName -Protocol https | ForEach-Object {
    $bindingPath = "IIS:\SslBindings\$($_.bindingInformation)"
    if (Test-Path $bindingPath) {
        Remove-Item $bindingPath -Force
        Write-Host "Removed existing SSL binding for $($_.bindingInformation)." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
    New-Item $bindingPath -Thumbprint $cert.Thumbprint -SSLFlags 1 -ErrorAction SilentlyContinue
    Write-Host "Created new SSL binding for $($_.bindingInformation)." -ForegroundColor Green
}
Start-Website -Name $siteName


# Ensure SecretSanta is an application
$site=Get-Website -Name $siteName
if($site.PhysicalPath -ne $sitePath){Set-ItemProperty "IIS:\Sites\$siteName" physicalPath $sitePath}
if(-not(Get-WebApplication -Site $siteName|Where-Object{$_.Name -eq "SecretSanta"})){
    New-WebApplication -Site $siteName -Name "SecretSanta" -PhysicalPath $appPath -ApplicationPool "Secret Santa"
}

# Enable Forms Authentication for SecretSanta
Write-Host "Enabling Forms Authentication for SecretSanta..."
Set-WebConfigurationProperty -Filter "system.web/authentication" -PSPath "IIS:\Sites\$siteName/SecretSanta" -Name "mode" -Value "Forms"

# Restart AppPools and verify
foreach($pool in $appPools){
    Start-WebAppPool -Name $pool
    $state=(Get-WebAppPoolState -Name $pool).Value
    Write-Host "AppPool '$pool' state: $state"
    if($state -ne "Started"){Get-EventLog -LogName System -Newest 10|Where-Object{$_.Source -like "*WAS*"}|Format-Table TimeGenerated,EventID,Message -AutoSize}
}

# Create the virtual directory to allow Uploads to be downloaded(!)
$siteName = "tim.brown.co.uk"
$appName = "SecretSanta"
$virtualDirName = "Uploads"
$physicalPath = "C:\inetpub\wwwroot\SecretSantaUploads"

Import-Module WebAdministration

# Define variables
$siteName = "tim-brown.co.uk"
$appName = "SecretSanta"
$virtualDirName = "Uploads"
$physicalPath = "C:\inetpub\wwwroot\SecretSantaUploads"
New-WebVirtualDirectory -Site $siteName -Application $appName -Name $virtualDirName -PhysicalPath $physicalPath -Force

if ($null -ne (Get-WebVirtualDirectory $virtualDirName)) {
    Write-Host "Successfully created virtual directory Uploads"
}
else {
    throw "Unable to create virtual directory Uploads"
}

Write-Host "Website, AppPools, HTTPS, and Forms Authentication configured successfully!"
Stop-Transcript
}