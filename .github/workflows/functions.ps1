Param (
  $actions,
  $numberOfReposToDo = 10,
  $access_token = $env:GITHUB_TOKEN
)

. $PSScriptRoot/library.ps1

$statusFile = "status.json"
$failedStatusFile = "failedForks.json"
Write-Host "Got an access token with length of [$($access_token.Length)], running for [$($numberOfReposToDo)] repos"
function GetForkedActionRepos {

    # if file exists, read it
    $status = $null
    if (Test-Path $statusFile) {
        Write-Host "Using existing status file"
        $status = Get-Content $statusFile | ConvertFrom-Json
        if (Test-Pqth $failedStatusFile) {
          $failedForks = Get-Content $failedStatusFile | ConvertFrom-Json
        }
        
        Write-Host "Found $($status.Count) existing repos in status file"
    }
    else {
        # build up status from scratch
        Write-Host "Loading current forks and status from scratch"

        # get all existing repos in target org
        $forkedRepos = GetForkedActionRepoList
        Write-Host "Found $($forkedRepos.Count) existing repos in target org"
        # convert list of forkedRepos to a new array with only the name of the repo
        $status = New-Object System.Collections.ArrayList
        foreach ($repo in $forkedRepos) {
            $status.Add(@{name = $repo.name; dependabot = $null})
        }
        Write-Host "Found $($status.Count) existing repos in target org"
        # for each repo, get the Dependabot status
        foreach ($repo in $status) {
            $repo.dependabot = $(GetDependabotStatus -owner $forkOrg -repo $repo.name)
        }
    }
    return ($status, $failedForks)
}

function GetDependabotStatus {
    Param (
        $owner,
        $repo        
    )

    $url = "repos/$owner/$repo/vulnerability-alerts"
    $status = ApiCall -method GET -url $url -body $null -expected 204
    return $status
}

function GetForkedActionRepoList {
    # get all existing repos in target org
    $repoUrl = "orgs/$forkOrg/repos?type=forks"
    $repoResponse = ApiCall -method GET -url $repoUrl -body "{`"organization`":`"$forkOrg`"}"
    Write-Host "Found [$($repoResponse.Count)] existing repos in org [$forkOrg]"
    
    #foreach ($repo in $repoResponse) {
    #    Write-Host "Found $($repo | ConvertTo-Json)"
    #}
    return $repoResponse
}
function RunForActions {
    Param (
        $actions,
        $existingForks,
        $failedForks
    )

    Write-Host "Running for [$($actions.Count)] actions"
    # filter actions list to only the ones with a repoUrl
    $actions = $actions | Where-Object { $null -ne $_.repoUrl -and $_.repoUrl -ne "" }
    Write-Host "Found [$($actions.Count)] actions with a repoUrl"

    # do the work
    ($newlyForkedRepos, $existingForks, $failedForks) = ForkActionRepos -actions $actions -existingForks $existingForks -failedForks $failedForks
    SaveStatus -failedForks $failedForks
    Write-Host "Forked [$($newlyForkedRepos)] new repos in [$($existingForks.Length)] repos"
    SaveStatus -existingForks $existingForks

    ($existingForks, $dependabotEnabled) = EnableDependabotForForkedActions -actions $actions -existingForks $existingForks -numberOfReposToDo $numberOfReposToDo
    Write-Host "Enabled Dependabot on [$($dependabotEnabled)] repos"
    SaveStatus -existingForks $existingForks

    $existingForks = GetDependabotAlerts -existingForks $existingForks

    return $existingForks
}

function GetDependabotAlerts { 
    Param (
        $existingForks
    )

    Write-Host "Loading vulnerability alerts for repos"

    $i = $existingForks.Length
    $max = $existingForks.Length + ($numberOfReposToDo * 2)

    $highAlerts = 0
    $criticalAlerts = 0
    $vulnerableRepos = 0
    foreach ($repo in $existingForks) {

        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        if ($repo.name -eq "" -or $null -eq $repo.name) {
            Write-Host "Skipping repo with no name" $repo | ConvertTo-Json
            continue
        }

        if ($repo.vulnerabilityStatus) {
            $timeDiff = [DateTime]::UtcNow.Subtract($repo.vulnerabilityStatus.lastUpdated)
            if ($timeDiff.Hours -lt 72) {
                Write-Debug "Skipping repo [$($repo.name)] as it was checked less than 72 hours ago"
                continue
            }
        }

        Write-Debug "Loading vulnerability alerts for [$($repo.name)]"
        $dependabotStatus = $(GetDependabotVulnerabilityAlerts -owner $forkOrg -repo $repo.name)
        if ($dependabotStatus.high -gt 0) {
            Write-Host "Found [$($dependabotStatus.high)] high alerts for repo [$($repo.name)]"
            $highAlerts++
        }
        if ($dependabotStatus.critical -gt 0) {
            Write-Host "Found [$($dependabotStatus.critical)] critical alerts for repo [$($repo.name)]"
            $criticalAlerts++
        }

        if ($dependabotStatus.high -gt 0 -or $dependabotStatus.critical -gt 0) {
            $vulnerableRepos++
        }

       $vulnerabilityStatus = @{
            high = $dependabotStatus.high
            critical = $dependabotStatus.critical
            lastUpdated = [DateTime]::UtcNow
        }
        #if ($repo.vulnerabilityStatus) {
        if (Get-Member -inputobject $repo -name "vulnerabilityStatus" -Membertype Properties) {
            $repo.vulnerabilityStatus = $vulnerabilityStatus
        }
        else {
            $repo | Add-Member -Name vulnerabilityStatus -Value $vulnerabilityStatus -MemberType NoteProperty
        }

        $i++ | Out-Null
    }

    Write-Host "Found [$($vulnerableRepos)] repos with a total of [$($highAlerts)] high alerts"
    Write-Host "Found [$($vulnerableRepos)] repos with a total of [$($criticalAlerts)] critical alerts"

    # todo: store this data in the status file?

    return $existingForks
}

function GetDependabotVulnerabilityAlerts {
    Param (
        $owner,
        $repo
    )

    $query = '
    query($name:String!, $owner:String!){
        repository(name: $name, owner: $owner) {
            vulnerabilityAlerts(first: 100) {
                nodes {
                    createdAt
                    dismissedAt
                    securityVulnerability {
                        package {
                            name
                        }
                        advisory {
                            description
                            severity
                        }
                    }
                }
            }
        }
    }'
    
    $variables = "
        {
            ""owner"": ""$owner"",
            ""name"": ""$repo""
        }
        "
    
    $uri = "https://api.github.com/graphql"
    $requestHeaders = @{
        Authorization = GetBasicAuthenticationHeader
    }
    
    Write-Debug "Loading vulnerability alerts for repo $repo"
    $response = (Invoke-GraphQLQuery -Query $query -Variables $variables -Uri $uri -Headers $requestHeaders -Raw | ConvertFrom-Json)
    #Write-Host ($response | ConvertTo-Json)
    $nodes = $response.data.repository.vulnerabilityAlerts.nodes
    #Write-Host "Found [$($nodes.Count)] vulnerability alerts"
    #Write-Host $nodes | ConvertTo-Json
    $moderate=0
    $high=0
    $critical=0
    foreach ($node in $nodes) {
        #Write-Host "Found $($node.securityVulnerability.advisory.severity)"
        #Write-Host $node.securityVulnerability.advisory.severity
        switch ($node.securityVulnerability.advisory.severity) {            
            "MODERATE" {
                $moderate++
            }
            "HIGH" {
                $high++
            }
            "CRITICAL" {
                $critical++
            }
        }
    }
    #Write-Host "Dependabot status: " $($response | ConvertTo-Json -Depth 10)
    return @{
        moderate = $moderate
        high = $high
        critical = $critical
    }
}

function ForkActionRepos {
    Param (
        $actions,
        $existingForks,
        $failedForks
    )

    $i = $existingForks.Length
    $max = $existingForks.Length + $numberOfReposToDo
    $newlyForkedRepos = 0
    $counter = 0

    Write-Host "Filtering repos to the ones we still need to fork"
    # filter the actions list down to the set we still need to fork (not knwon in the existingForks list)
    $actionsToProcess = $actions | Where-Object { $existingForks.name -notcontains (SplitUrlLastPart $_.RepoUrl) }
    Write-Host "Found [$($actionsToProcess.Count)] actions still to process for forking"

    # get existing forks with owner/repo values instead of full urls
    foreach ($action in $actionsToProcess) {
        if ($i -ge $max) {
            # do not run to long
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
            break
        }

        # show every 100 executions a message
        if ($counter % 100 -eq 1) {
            Write-Host "Checked forked for ${counter} repos"
        }

        ($owner, $repo) = $(SplitUrl $action.RepoUrl)
        # check if fork already exists
        $existingFork = $existingForks | Where-Object { $_.name -eq $repo }
        $failedFork = $failedForks | Where-Object { $_.name -eq $repo -And $_.owner -eq $owner}
        if ($null -eq $existingFork -And $failedFork.timesFailed -lt 5) {        
            Write-Host "$i/$max Checking repo [$repo]"
            $forkResult = ForkActionRepo -owner $owner -repo $repo
            if ($forkResult) {
                # add the repo to the list of existing forks
                Write-Debug "Repo forked"
                $newlyForkedRepos++
                $newFork = @{ name = $repo; dependabot = $null; owner = $owner }
                $existingForks += $newFork
                    
                # back off just a little after a new fork
                Start-Sleep 2
                $i++ | Out-Null
            }
            else {
                if ($failedFork) {
                    # up the number of times we failed to fork this repo
                    $failedFork.timesFailed++
                }
                else {
                # let's store a list of failed forks
                    Write-Host "Failed to fork repo [$owner/$repo]"
                    $failedFork = @{ name = $repo; owner = $owner; timesFailed = 0 }
                    $failedForks += $failedFork
                }
            }
        }
        else {
            Write-Host "Fake message for double check"
        }
        $counter++ | Out-Null
    }

    return ($newlyForkedRepos, $existingForks, $failedForks)
}

function EnableDependabotForForkedActions {
    Param (
        $actions,
        $existingForks,
        $numberOfReposToDo    
    )
    # enable dependabot for all repos
    $i = $existingForks.Length
    $max = $existingForks.Length + $numberOfReposToDo
    $dependabotEnabled = 0

    Write-Host "Enabling dependabot on forked repos"
    foreach ($action in $actions) {

        if ($i -ge $max) {
            # do not run to long
            break            
            Write-Host "Reached max number of repos to do, exiting: i:[$($i)], max:[$($max)], numberOfReposToDo:[$($numberOfReposToDo)]"
        }

        $repo = SplitUrlLastPart $action.RepoUrl
        Write-Debug "Checking existing forks for an object with name [$repo] from [$($action.RepoUrl)]"
        $existingFork = $existingForks | Where-Object { $_.name -eq $repo }

        if ($null -ne $existingFork -And $null -eq $existingFork.dependabot) {
            if (EnableDependabot $existingFork) {
                Write-Debug "Dependabot enabled on [$repo]"
                $existingFork.dependabot = $true
                
                if (Get-Member -inputobject $repo -name "vulnerabilityStatus" -Membertype Properties) {
                    # reset lastUpdatedStatus
                    $repo.vulnerabilityStatus.lastUpdated = [DateTime]::UtcNow.AddYears(-1)
                }
                
                $dependabotEnabled++ | Out-Null
                $i++ | Out-Null

                # back off just a little
                Start-Sleep 2 
            }
            else {
                # could not enable dependabot for some reason. Store it as false so we can skip it next time and save execution time
                $existingFork.dependabot = $false
            }
        }             
    }    
    return ($existingForks, $dependabotEnabled)
}

function EnableDependabot {
    Param ( 
      $existingFork
    )
    if ($existingFork.name -eq "" -or $null -eq $existingFork.name) {
        Write-Host "No repo name found, skipping [$($existingFork.name)]" $existingFork | ConvertTo-Json
        return $false
    }

    # enable dependabot if not enabled yet
    if ($null -eq $existingFork.dependabot) {
        Write-Debug "Enabling Dependabot for [$($existingFork.name)]"
        $url = "repos/$forkOrg/$($existingFork.name)/vulnerability-alerts"
        $status = ApiCall -method PUT -url $url -body $null -expected 204
        if ($status -eq $true) {
            return $true
        }
        return $status
    }

    return $false
}

function ForkActionRepo {
    Param (
        $owner,
        $repo
    )

    if ($owner -eq "" -or $null -eq $owner -or $repo -eq "" -or $null -eq $repo) {
        return $false
    }
    # fork the action repository to the actions-marketplace-validations organization on github
    $forkUrl = "repos/$owner/$repo/forks"
    # call the fork api
    $forkResponse = ApiCall -method POST -url $forkUrl -body "{`"organization`":`"$forkOrg`"}" -expected 202

    if ($null -ne $forkResponse -and $forkResponse -eq "True") {    
        Write-Host "  Forked [$owner/$repo] to [$forkOrg/$($forkResponse.name)]"
        if ($null -eq $forkResponse.name){
            # response is just 'True' since we pass in expected, could be improved by returning both the response and the check on status code
            #Write-Host "Full fork response: " $forkResponse | ConvertTo-Json
        }
        return $true
    }
    else {
        return $false
    }
}

Write-Host "Got $($actions.Length) actions"
GetRateLimitInfo

# default variables
$forkOrg = "actions-marketplace-validations"

# load the list of forked repos
($existingForks, $failedForks) = GetForkedActionRepos

# run the functions for all actions
$existingForks = RunForActions -actions $actions -existingForks $existingForks -failedForks $failedForks
Write-Host "Ended up with $($existingForks.Count) forked repos"
# save the status
SaveStatus -existingForks $existingForks

GetRateLimitInfo

Write-Host "End of script, added [$numberOfReposToDo] forked repos"