	
	<#
	.SYNOPSIS 
		Syncs all runbooks in a VSO git repository to an Azure Automation account.

	.DESCRIPTION
		Syncs all runbooks in a VSO git repository to an Azure Automation account starting with dependent (child)
		runbooks and followed by parent runbooks to an existing Automation Account.  This runbook will recursively
		treat all sub directories within the VSORunbookFolderPath as dependent (child) runbooks and publish these 
		first

		With the -FlatFilesMode parameter, syncs all runbooks in the specified folder in a VSO git repository to 
		an Azure Automation Account by building a dependency graph and publishing bottom-up.
    
		Requires a VSO Alternate Authentication Credential for connecting with VSO-Git repository, stored 
		in a Automation credential asset.
    
        
	.PARAMETER VSOCredentialName
		Name of the credential asset containing the VSO Alternate Authentication Credential name 
		and password configured from VSO Profile dialog.
    
	.PARAMETER VSOAccount
		Name of the account name for VSO Online.  Ex. https://accountname.visualstudio.com

	.PARAMETER VSOProject
		Name of the VSO project that contains the repository     

	.PARAMETER VSORepository
		Name of the repository that contains the runbook project

	.PARAMETER VSORunbookFolderPath
		Project path to the root where the runbooks are located.  Ex. /Project1/ProjectRoot
		where ProjectRoot contains the parent runbooks 
    
	.PARAMETER TargetSubscriptionId
		The Id of the Azure Subscription where the Automation Assets will be deployed.

	.PARAMETER TargetResourceGroup
		Name of the Resource Group that contains the TargetAutomationAccount.

	.PARAMETER TargetAutomationAccount
		Name of the Automation Account to where the runbooks should be synced.

	.PARAMETER TargetCredentialName
		Name of the Azure Credential asset that was created in the Automation service.
		This credential asset contains represents a user with permission to manage the TargetAutomationAccount.
    
	.PARAMETER VSOBranch
		Optional name of the Git branch to retrieve the runbooks from.  Defaults to "master"

	.PARAMETER FlatFilesMode
		Optional. Defaults to "$false"
		Flag enables forced-publishing of runbooks to satisfy parent/child caveats - without resorting to cumbersome source folder structures. 
		1. The runbook will loop through the flat list of runbooks, attempting to Import & Publish each, in the order they are enumerated from VSO.
		2. If a runbook fails import, it's assumed that's because the Automation Account is missing a required child runbook.
		3. The code will continue attempting to import the remaining runbooks. 
		4. If errors occured, steps 1-3 are repeated.
		5. Successfully synced runbooks will not be imported on subsequent tries.
		6. If errors occured and no runbooks are synced in a given try, the process gives up, assuming the issue is not a parent/child dependency.

	.EXAMPLE
		Sync-VsoGitRmRunbook -VSOCredentialName "VSOCredentialAsset" -VSOAccount "AccountName" 
			-VSOProject "Project" -VSORepository "Repository" -VSORunbookFolderPath "/Project1/ProjectRoot" 
			-TargetAutomationAccount "AccountName" -AzureConnectionName "ConnectionAssetName" -VSOBranch "master"

	#>

	function Sync-VsoGitRmRunbooks
	{
		[CmdletBinding()]	
		param (
		   [Parameter(Mandatory=$True)]
		   [string] $VSOCredentialName,

		   [Parameter(Mandatory=$True)]
		   [string] $VSOAccount,

		   [Parameter(Mandatory=$True)]
		   [string] $VSOProject,

		   [Parameter(Mandatory=$True)]
		   [string] $VSORepository,

		   [Parameter(Mandatory=$True)]
		   [string] $VSOBranch,

		   [Parameter(Mandatory=$True)]
		   [string] $VSORunbookFolderPath,

		   [Parameter(Mandatory=$True)]
		   [string] $TargetCredentialName,
	   
		   [Parameter(Mandatory=$True)]
		   [string] $TargetSubscriptionId,
       
		   [Parameter(Mandatory=$True)]
		   [string] $TargetResourceGroup,

		   [Parameter(Mandatory=$True)]
		   [string] $TargetAutomationAccount,

		   [Parameter(Mandatory=$False)]
		   [bool] $FlatFilesMode = $true
		)

		$psExtension = ".ps1"
		$grExtension = ".graphrunbook"
		$vsoApiVersion = "1.0-preview"
		    	
		#Getting Credentail asset for VSO alternate authentication credentail
		$VSOCred = Get-AutomationPSCredential -Name $VSOCredentialName
		if ($VSOCred -eq $null)
		{
			throw "Could not retrieve '$VSOCredentialName' credential asset. Check that you created this asset in the Automation service."
		}    
		$VSOAuthUserName = $VSOCred.UserName
		$VSOAuthPassword = $VSOCred.GetNetworkCredential().Password
    
		#Creating authorization header 
		$basicAuth = ("{0}:{1}" -f $VSOAuthUserName,$VSOAuthPassword)
		$basicAuth = [System.Text.Encoding]::UTF8.GetBytes($basicAuth)
		$basicAuth = [System.Convert]::ToBase64String($basicAuth)
		$headers = @{Authorization=("Basic {0}" -f $basicAuth)}

		#ex. "https://gkeong.visualstudio.com/defaultcollection/_apis/git/automation-git-test2-proj/repositories/automation-git-test2-proj/items?scopepath=/Project1/Project1/&recursionlevel=full&includecontentmetadata=true&versionType=branch&version=production&api-version=1.0-preview"
		$VSOURL = "https://" + $VSOAccount + ".visualstudio.com/defaultcollection/_apis/git/" + 
				$VSOProject + "/repositories/" + $VSORepository + "/items?scopepath=" + $VSORunbookFolderPath +  
				"&recursionlevel=full&includecontentmetadata=true&versionType=branch&version=" + $VSOBranch +  
				"&api-version=" + $vsoApiVersion
		Write-Verbose("Connecting to VSO using URL: $VSOURL")
		$results = Invoke-RestMethod -Uri $VSOURL -Method Get -Headers $headers

		$VerbosePreference = "Continue"
		#$results | ConvertTo-Json | Write-Verbose

		$allRunbooks = [AzureAutomationVsoGitSync.Models.SortedRunbookCollection]@{}

		#grab folders & files
		$folderObj = @()
		foreach ($item in $results.value)
		{
			if ($item.gitObjectType -eq "tree")
			{
				$folderObj += $item
			}
			elseif (($item.gitObjectType -eq "blob") -and ($item.path -match $psExtension -or $item.path -match $grExtension))
			{
				# get runbook file name
				$path = $item.path; 
				$fileName = [AzureAutomationVsoGitSync.Models.Runbook]::GetRunbookFileName($path); 

				# local temp path for runbook
				$tempPath = Join-Path -Path $env:SystemDrive -ChildPath "temp"
				$outFile = Join-Path -Path $tempPath -ChildPath $fileName

				# download the runbook
				$fileUrl = $item.url
				Write-Verbose "`tGET $fileName"
				$VerbosePreference = "SilentlyContinue"
				Invoke-RestMethod -Uri $fileUrl -Method Get -Headers $headers -OutFile $outFile 
				$VerbosePreference = "Continue"

				$new = $allRunbooks.Add($outFile, $fileUrl)
			}
		}
		
		# Select the Azure Subscription
		$VerbosePreference = "SilentlyContinue"
		$azCred = Get-AutomationPSCredential -Name $TargetCredentialName
		$azAcct = Add-AzureRmAccount -Credential $azCred -SubscriptionId $TargetSubscriptionId
		$azSub = Select-AzureRmSubscription -SubscriptionId $TargetSubscriptionId
		$VerbosePreference = "Continue"

		# enumerate existing automation accounts & runbooks
		#Get-AzureRmAutomationAccount -ResourceGroupName $TargetResourceGroup | ConvertTo-Json | Write-Verbose
		#Get-AzureRmAutomationRunbook -ResourceGroupName $TargetResourceGroup -AutomationAccountName $TargetAutomationAccount | ConvertTo-Json | Write-Verbose 

		if ($FlatFilesMode)
		{
			$sysDrive = $env:SystemDrive
			
			# [SortedRunbookCollection].Result will be the topologically-sorted list of runbooks
			# (Leaf nodes first)
            
			$vsoApiVersion = $true

			$haveSynced = @{}
			$errorSync = @{}

			Write-Verbose "Publish Order (by dependency):"
			$sorted = $allRunbooks.Result
			$sorted | Select Name | ConvertTo-Json | Write-Verbose

			foreach($rb in $sorted)
			{
				$outFile = $rb.FilePath
				$runbookName = $rb.Name
				$rbType = $rb.Type
                
				try 
				{
					# if not yet synced .. import & add to synced collection
					if (!$haveSynced.ContainsKey($runbookName))
					{
						if ($rbType -eq [AzureAutomationVsoGitSync.Models.RunbookType]::Graph)
						{
							Write-Verbose  "Importing $runbookName as Graph."
							Import-AzureRmAutomationRunbook -ResourceGroupName $TargetResourceGroup -AutomationAccountName $TargetAutomationAccount -Path $outFile -Force -Published -Type Graph 
						}
						elseif ($rbType -eq [AzureAutomationVsoGitSync.Models.RunbookType]::PowerShellWorkflow)
						{                                
							Write-Verbose  "Importing $runbookName as PowerShellWorkflow."
							Import-AzureRmAutomationRunbook -ResourceGroupName $TargetResourceGroup -AutomationAccountName $TargetAutomationAccount -Path $outFile -Force -Published -Type PowerShellWorkflow 
						}
						elseif ($rbType -eq [AzureAutomationVsoGitSync.Models.RunbookType]::PowerShell)
						{
							Write-Verbose  "Importing $runbookName as PowerShell."
							Import-AzureRmAutomationRunbook -ResourceGroupName $TargetResourceGroup -AutomationAccountName $TargetAutomationAccount -Path $outFile -Force -Published -Type PowerShell 
						}
						else
						{
							throw "Could not determine type of runbook $($rb.FileName) from $rbType"
						}
                            
						#Write-Verbose "Publishing.."
						#$rb = Publish-AzureRmAutomationRunbook -ResourceGroupName $TargetResourceGroup -AutomationAccountName $TargetAutomationAccount -Name $runbookName -ErrorAction Continue | Write-Verbose
                        
						$haveSynced.Add($runbookName, $rb.FileUrl)
					}
					else
					{
						Write-Verbose("Runbook $runbookName already synced. Duplicate?")
					}
				}
				catch [System.Exception] 
				{
					$ex = ConvertTo-Json $_
					if (!$errorSync.ContainsKey($runbookName))
					{
						$errorsync.add( $runbookname, $ex )
					}
					Write-Verbose $ex
					Write-Error $_
				}
			}

			Write-Verbose "Done.`n"
                
			Write-Verbose "Synced $($haveSynced.Count) of $($sorted.Count)"
			#Write-Verbose "Errors $($errorSync.Count)"

			if ($errorSync.Count > 0)
			{
				Write-Verbose "Errors:"
				$errorSync | ConvertTo-Json | Write-Verbose
			}

			if ($haveSynced.Count -eq $sorted.Count)
			{
				Write-Verbose "All runbooks synced."
			}

		}
		else
		{
			$haveSynced = @{}
			$errorSync = @{}

			#recursively go through most inner child folders first, then their parents, parents parents, etc.
			for ($i = $folderObj.count - 1; $i -ge 0; $i--)
			{
				Write-Verbose("Processing files in $($folderObj[$i].path)")
				$folderURL = "https://" + $VSOAccount + ".visualstudio.com/defaultcollection/_apis/git/" + 
						$VSOProject + "/repositories/" + $VSORepository + "/items?scopepath=" + $folderObj[$i].path +  
						"&recursionLevel=OneLevel&includecontentmetadata=true&versionType=branch&version=" + 
						$VSOBranch + "&api-version=" + $vsoApiVersion
 
				$results = Invoke-RestMethod -Uri $folderURL -Method Get -Headers $headers
        
				foreach ($item in $results.value)
				{
					try 
					{
						$pathsplit = $item.path.Split("/")
						$filename = $pathsplit[$pathsplit.Count - 1]
						$tempPath = Join-Path -Path $env:SystemDrive -ChildPath "temp"
						$outFile = Join-Path -Path $tempPath -ChildPath $filename
 
						#Get the runbook name
						$fname = $filename
						$tempPathSplit = $fname.Split(".")
						$runbookName = $tempPathSplit[0]
						$rbType = $rb.Type
        
						# if not yet synced .. import & add to synced collection
						if (!$haveSynced.ContainsKey($runbookName))
						{
							if ($rbType -eq [RunbookType]::Graph)
							{
								Write-Verbose  "Importing $runbookName as Graph."
								Import-AzureRmAutomationRunbook -ResourceGroupName $TargetResourceGroup -AutomationAccountName $TargetAutomationAccount -Path $outFile -Force -Published -Type Graph 
							}
							elseif ($rbType -eq [RunbookType]::PowerShellWorkflow)
							{                                
								Write-Verbose  "Importing $runbookName as PowerShellWorkflow."
								Import-AzureRmAutomationRunbook -ResourceGroupName $TargetResourceGroup -AutomationAccountName $TargetAutomationAccount -Path $outFile -Force -Published -Type PowerShellWorkflow 
							}
							elseif ($rbType -eq [RunbookType]::PowerShell)
							{
								Write-Verbose  "Importing $runbookName as PowerShell."
								Import-AzureRmAutomationRunbook -ResourceGroupName $TargetResourceGroup -AutomationAccountName $TargetAutomationAccount -Path $outFile -Force -Published -Type PowerShell 
							}
							else
							{
								throw "Could not determine type of runbook $($rb.FileName) from $rbType"
							}
						
							$haveSynced.Add($runbookName, $rb.FileUrl)
						}
						else
						{
							Write-Verbose("Runbook $runbookName already synced. Duplicate?")
						}
					}
					catch [System.Exception] 
					{
						$ex = ConvertTo-Json $_
						if (!$errorSync.ContainsKey($runbookName))
						{
							$errorsync.add( $runbookname, $ex )
						}
						Write-Verbose $ex
						Write-Error $_
					}
					
				}
			}

			
			Write-Verbose "Done.`n"
                
			Write-Verbose "Synced $($haveSynced.Count) of $($allRunbooks.Results.Count)"

			if ($errorSync.Count > 0)
			{
				Write-Verbose "Errors:"
				$errorSync | ConvertTo-Json | Write-Verbose
			}

			if ($haveSynced.Count -gt 0 -and $haveSynced.Count -eq $results.Count)
			{
				Write-Verbose "All runbooks synced."
			}
		}
	}
