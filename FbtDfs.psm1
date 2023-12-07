function Show-DFSRBacklogProgress{
	Param (
		$GroupName = "Games",
		$FolderName = "Games"
		
	)
	
	$msg = (Get-DfsrBacklog -SourceComputerName trb-ps-cor19 -DestinationComputerName jeb-ps-cor23 -GroupName $GroupName -FolderName $FolderName -verbose 4>&1).Message
	$count = $max = $msg.Substring($msg.IndexOf("Count: ") + 7)
	$start = Get-Date
	
	while ($count -gt 0)
	{
		$msg = (Get-DfsrBacklog -SourceComputerName trb-ps-cor19 -DestinationComputerName jeb-ps-cor23 -GroupName $GroupName -FolderName $FolderName -verbose 4>&1).Message
		$count = $msg.Substring($msg.IndexOf("Count: ") + 7)
		$backlog = Get-DfsrBacklog -SourceComputerName trb-ps-cor19 -DestinationComputerName jeb-ps-cor23 -GroupName $GroupName -FolderName $FolderName
		if ($currentFile.Name -ne $backlog[0].FileName)
		{
			$currentFile = get-childitem $backlog[0].FullPathName
			$currentFileLength = $([Math]::Round($currentFile.Length / 1MB, 1))
		}
		Write-Progress -Activity "Processing Backlog (elapsed time: $([Math]::Round(((Get-Date) - $start).TotalMinutes, 0)) minute(s)" -Status "$($max - $count) of $($max)" -PercentComplete (($max - $count) / $max * 100) -CurrentOperation "$($backlog[0].FileName) ($($currentFileLength)MB) | $($backlog[0].FullPathName)"
		Sleep 5
	}
}
