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

