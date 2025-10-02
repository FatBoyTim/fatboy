function Show-DFSRBacklogProgress {
	Param (
		$GroupName,
		$FolderName,
		$SourceServer,
  		$DestinationServer,
    		$ResultsCount = 30
	)
	
	$error = $true
	while ($error) {
		try {
		 	$msg = (Get-DfsrBacklog -SourceComputerName $SourceServer -DestinationComputerName $DestinationServer -GroupName $GroupName -FolderName $FolderName -verbose 4>&1).Message
			$error = $false
			
			$count = $max = $msg.Substring($msg.IndexOf("Count: ") + 7)
   			if ($msg.IndexOf("No backlog for the replicated folder") -eq 0) {
     				$count = 0
				Write-Host "No backlog detected"
		  		$events = Get-WinEvent -FilterHashtable @{LogName="DFS Replication";ProviderName="DFSR";Id=4104} | ?{$_.Message -match $FolderName}
	     			if ($events.Count -eq 1)
				{
	   				Write-Host "Event log entry detected $($events[0].TimeCreated) confirming replication completed, run 'Get-WinEvent -FilterHashtable @{LogName=`"DFS Replication`";ProviderName=`"DFSR`";Id=4104} | ft -Wrap' for more details."
	       				$events | ft -Wrap 
	       			}
		  		elseif ($events.Count -gt 1) 
	     			{
					Write-Host "Multiple event log entries detected confirming replication has completed, run 'Get-WinEvent -FilterHashtable @{LogName=`"DFS Replication`";ProviderName=`"DFSR`";Id=4104} | ft -Wrap' for more details."
	       				$events | ft -Wrap
				}
	   			else
	   			{
	      				Write-Host "No event log entries detected confirming replication has completed, run 'Get-WinEvent -FilterHashtable @{LogName=`"DFS Replication`";ProviderName=`"DFSR`";Id=4104} | ft -Wrap' to monitor."
	      			}
       			}
	 		else
   			{
				$count = $msg.Substring($msg.IndexOf("Count: ") + 7)
   			}
			$start = Get-Date

		} catch {
			$error = $true
			cls
			Write-Host "Waiting for replication group to be picked up by replication group members"
			Sleep 1
		}
	}
	
	while ($count -gt 0)
	{
 		$msg = (Get-DfsrBacklog -SourceComputerName $SourceServer -DestinationComputerName $DestinationServer -GroupName $GroupName -FolderName $FolderName -verbose 4>&1).Message
   		if ($msg.IndexOf("No backlog for the replicated folder") -eq 0) {
     			$count = 0
       		}
	 	else
   		{
			$count = $msg.Substring($msg.IndexOf("Count: ") + 7)
   		}
		$backlog = Get-DfsrBacklog -SourceComputerName $SourceServer -DestinationComputerName $DestinationServer -GroupName $GroupName -FolderName $FolderName
  		if ($backlog.Count -gt 0) {
			if ($currentFile.Name -ne $backlog[0].FileName)
			{
				$currentFile = get-childitem $backlog[0].FullPathName
				$currentFileLength = $([Math]::Round($currentFile.Length / 1MB, 1))
			}
			Write-Progress -Activity "Processing Backlog (elapsed time: $([Math]::Round(((Get-Date) - $start).TotalMinutes, 0)) minute(s))" -Status "$($max - $count) of $($max)" `
	  			-PercentComplete (($max - $count) / $max * 100) -CurrentOperation "$($backlog[0].FileName) ($($currentFileLength)MB) | $($backlog[0].FullPathName)"
			
    			if ($null -ne $SourceServer -and $null -ne $DestinationServer) {
	    			$table = get-dfsrbacklog -SourceComputerName $SourceServer -DestinationComputerName $DestinationServer | Sort-Object Index | select -first $ResultsCount 
				Clear-Host
   				Write-Host "`n`n`n`n`n`n`n`n"
       				$table | ft FileName, FullPathName, Index, Fence, Flags, Attributes
      			}
	 		Sleep 5
	 	}
	}
}

function Get-OutOfSyncServerData {
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true)] $ReferencePath,
		[Parameter(Mandatory = $true)] $DifferencePath,
		[Switch] $SkipFiles,
		[Switch] $SkipFolders,
		[Switch] $PassThru
	)
	
	#if ($PSBoundParameters['Debug']) {
	#	$DebugPreference = 'Continue'
	#}

	Write-Verbose "Getting list of items from $($ReferencePath)"
  	$ref = Get-ChildItem $ReferencePath -Recurse
	
	Write-Verbose "Getting list of items from $($DifferencePath)"
   	$diff = Get-ChildItem $DifferencePath -Recurse
	
	$files = @()
	if (!$SkipFiles) {
		Write-Verbose "Comparing files"
		$refFiles = $ref | ?{$_.Attributes -notmatch "Directory"}
		$diffFiles = $diff | ?{$_.Attributes -notmatch "Directory"}
		$files = Compare-Object $refFiles $diffFiles -Property Name, LastWriteTime, Length -PassThru:$PassThru
		if ($files.Count -eq 0)
		{
			Write-Verbose "Files are synchronised"
			$files = @()
		} else {
			Write-Verbose "Detected $($files.Count) difference(s) in files"
		}
	}

	$dirs = @()
	if (!$SkipFolders) {
		Write-Verbose "Comparing directories"
		$refDirs = $ref | ?{$_.Attributes -match "Directory"}
		$diffDirs = $diff | ?{$_.Attributes -match "Directory"}
		$dirs = Compare-Object $refDirs $diffDirs -Property Name, Created, Length -PassThru:$PassThru
		if ($dirs.Count -eq 0)
		{
			Write-Verbose "Directories are synchronised"
			$dirs = @()
		} else {
			Write-Verbose "Detected $($dirs.Count) difference(s) in directories"
		}
	}
	
   	return $files, $dirs
}

function Sync-ServerData {
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Mandatory = $true)] $ReferencePath,
		[Parameter(Mandatory = $true)] $DifferencePath,
		[Switch] $SkipFiles,
		[Switch] $SkipFolders
	)
	
	if ($PSBoundParameters['Debug']) {
		$DebugPreference = 'SilentlyContinue'
	}
	
	if ($SkipFolders) {
		Write-Warning "Use of -SkipFolders will generate errors and fail to copy files if the equivalent directory does not exist on the destination"
	}
	
	$results = Get-OutOfSyncServerData -ReferencePath $ReferencePath -DifferencePath $DifferencePath -SkipFiles:$SkipFiles -SkipFolders:$SkipFolders -PassThru 
	foreach ($result in $results[1])
	{
		$src = $result.FullName
		if ($result.FullName.IndexOf($ReferencePath) -eq 0)
		{
			$dest = $result.FullName.Replace($ReferencePath, $DifferencePath)
		} else {
			$dest = $result.FullName.Replace($DifferencePath, $ReferencePath)
		}
		
		if ($PSCmdlet.ShouldProcess($result.Name, "Copy folder from '$($src)' to '$($dest)'")) {
			Write-Verbose "Copying directory from '$($src)' to '$($dest)'"
			Copy-Item $src $dest
		}
	}
	
	$foundList = @()
	foreach ($result in $results[0])
	{
		$found = $false
		$duplicate = $false
		foreach ($file in $results[0]) {
			if ($foundList.Contains($file.FullName.Replace($ReferencePath, "").Replace($DifferencePath, ""))) {
				Write-Verbose "Already processed $($file.FullName) so ignoring it "
				$duplicate = $true
				continue
			}
			
			if ($result.Name -eq $file.Name -and $file.FullName -ne $result.FullName) {
				if ($file.LastWriteTime -gt $result.LastWriteTime)
				{
					Write-Verbose "File $($file.FullName) is newer than its counterpart and will be used as the source"
					$src = $file.FullName
					$dest = $result.FullName
				} elseif ($result.LastWriteTime -gt $file.LastWriteTime) {
					Write-Verbose "File $($result.FullName) is newer than its counterpart and will be used as the source"
					$src = $result.FullName
					$dest = $file.FullName
				}
				$foundList += ($file.FullName.Replace($ReferencePath, "").Replace($DifferencePath, ""))
				$found = $true
				break
				
			}
		}
		
		if ($duplicate) {
			continue
		}
		
		if (!$found) {
			Write-Verbose "No counterpart to $($result.FullName) found"
			$src = $result.FullName
			if ($result.FullName.IndexOf($ReferencePath) -eq 0)
			{
				$dest = $result.FullName.Replace($ReferencePath, $DifferencePath)
			} else {
				$dest = $result.FullName.Replace($DifferencePath, $ReferencePath)
			}
		}
		
		if ($PSCmdlet.ShouldProcess($result.Name, "Copy file from '$($src)' to '$($dest)'")) {
			Write-Verbose "Copying file from '$($src)' to '$($dest)'"
			Copy-Item $src $dest -Force
		}
	}
}


function Get-FbtDfsReplicatedFoldersBacklog {
    [CmdletBinding()]
    Param (
        [switch] $ShowProgress
    )
    # Local variables
    $count = 0 
    $foldersLookup = @{}

    Write-Verbose "Getting DFSR State objects"
    $states = Get-DFSRState
    
    Write-Verbose "Retrieving folder names"
    foreach ($state in $states) {
        $count++
        if ($ShowProgress) {
            Write-Progress -Activity "Retrieving folder names" -CurrentOperation "Getting data for $($state.FileName) ($($count) of $($states.Count))" -PercentComplete (($count/$states.Count)*100)
        }
        
        if ($null -eq $foldersLookup.($state.ReplicatedFolderIdentifier))
        {
            $folderName = (Get-DfsReplicatedFolder | ?{$_.Identifier -eq $state.ReplicatedFolderIdentifier} | select -ExpandProperty FolderName)
            Write-Debug "Adding  $folderName"
            $foldersLookup += @{$state.ReplicatedFolderIdentifier = $folderName }
        }
        
        $fn = $foldersLookup.($state.ReplicatedFolderIdentifier)
        $state | Add-Member -MemberType NoteProperty -Name FolderName -Value $fn
    }
    return $states | Group-Object FolderName | select Name, Count | Sort-Object Name
}

function Get-FbtDfsBacklogCount {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)] [String] $SourceComputerName,
        [Parameter(Mandatory=$true)] [String] $DestinationComputerName,
        [Parameter(ValueFromPipeline=$true)][String] $FolderName
    )
    Get-DfsrBacklog -SourceComputerName $SourceComputerName -DestinationComputerName $DestinationComputerName -FolderName $FolderName -Verbose | Out-Null 4>$1

}

function Test-Ping { while($true) { try { $ping = Test-Connection 8.8.8.8 -Count 1 -ErrorAction Stop; Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Ping SUCCEEDED ($($ping.ResponseTime)ms)" } catch { Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Ping FAILED" }; sleep 1 } }


function Set-ActiveWindow {
    param (
        [string]$WindowTitle = "Citrix Workspace"  # Adjust this to match your Citrix window title
    )

    Add-Type @"
    using System;
    using System.Runtime.InteropServices;

    public class WinAPI {
        [DllImport("user32.dll")]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
"@

    $hWnd = [WinAPI]::FindWindow($null, $WindowTitle)
    if ($hWnd -ne [IntPtr]::Zero) {
        [WinAPI]::SetForegroundWindow($hWnd) | Out-Null
        Write-Output "Window '$WindowTitle' set to foreground."
    } else {
        Write-Output "Window '$WindowTitle' not found."
    }
}

function Get-IdleTimeSeconds {
    Add-Type @"
    using System;
    using System.Runtime.InteropServices;

    public class IdleTime {
        [DllImport("user32.dll")]
        public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [StructLayout(LayoutKind.Sequential)]
        public struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }

        public static uint GetIdleTime() {
            LASTINPUTINFO lastInputInfo = new LASTINPUTINFO();
            lastInputInfo.cbSize = (uint)Marshal.SizeOf(lastInputInfo);
            GetLastInputInfo(ref lastInputInfo);
            return ((uint)Environment.TickCount - lastInputInfo.dwTime) / 1000;
        }
    }
"@

    return [IdleTime]::GetIdleTime()
}

function Send-KeyboardKeepAwake {
	[CmdletBinding()]
	Param ( 
		$Interval = 30,
		$Keys = $null
	)
	Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): Timeout period in seconds: $timeout"
	if ($Keys -eq $null) { $useDate = $true } else { $useDate = $false }
	$wshell = New-Object -ComObject WScript.Shell
	
	$firstRun = $true
	while ($true) {
		Start-Sleep $Interval
		$idleTime = Get-IdleTimeSeconds
		$timeout = (2 * $Interval)
		Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): Idle time in seconds: $idleTime"
		Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): Timeout period in seconds: $timeout"
		if ($idleTime -ge $timeout)
		{
			Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): Sending Keep-Awake"
			#Set-ActiveWindow -WindowTitle "VDI GBR Win11 PVM - Desktop Viewer"
			if ($useDate) {
				if ($firstRun) {
					Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): Sending 1st Keep-Awake"
					$wshell.SendKeys("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
					$firstRun = $false
				} else {
					Write-Verbose "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): Sending Keep-Awake"
					$wshell.SendKeys(" | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
				}
			} else {
				$wshell.SendKeys($Keys)
			}
		}
	}
}





#Get-FbtDfsReplicatedFoldersBacklog | select -ExpandProperty Name | %{Get-FbtDfsBacklogCount -SourceComputerName jeb-ps-cor19 -DestinationComputerName trb-ps-cor19 -FolderName $_}
