function Show-DFSRBacklogProgress{
	Param (
		$GroupName,
		$FolderName,
		$SourceServer,
  		$DestinationServer
	)
	
	$msg = (Get-DfsrBacklog -SourceComputerName $SourceServer -DestinationComputerName $DestinationServer -GroupName $GroupName -FolderName $FolderName -verbose 4>&1).Message
	$count = $max = $msg.Substring($msg.IndexOf("Count: ") + 7)
	$start = Get-Date
	
	while ($count -gt 0)
	{
		$msg = (Get-DfsrBacklog -SourceComputerName $SourceServer -DestinationComputerName $DestinationServer -GroupName $GroupName -FolderName $FolderName -verbose 4>&1).Message
		$count = $msg.Substring($msg.IndexOf("Count: ") + 7)
		$backlog = Get-DfsrBacklog -SourceComputerName $SourceServer -DestinationComputerName $DestinationServer -GroupName $GroupName -FolderName $FolderName
		if ($currentFile.Name -ne $backlog[0].FileName)
		{
			$currentFile = get-childitem $backlog[0].FullPathName
			$currentFileLength = $([Math]::Round($currentFile.Length / 1MB, 1))
		}
		Write-Progress -Activity "Processing Backlog (elapsed time: $([Math]::Round(((Get-Date) - $start).TotalMinutes, 0)) minute(s)" -Status "$($max - $count) of $($max)" -PercentComplete (($max - $count) / $max * 100) -CurrentOperation "$($backlog[0].FileName) ($($currentFileLength)MB) | $($backlog[0].FullPathName)"
  		get-dfsrbacklog -SourceComputerName $SourceServer -DestinationComputerName $DestinationServer | ft FileName, FullPathName, Index, Fence, Flags, Attributes
		Sleep 5
	}
}
