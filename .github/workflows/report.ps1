Param (
  $actions,
  $logSummary
)

Write-Host "Found [$($actions.Count)] actions to report on"
Write-Host "Log summary path: [$logSummary]"

$global:highAlerts = 0
$global:criticalAlerts = 0
$global:vulnerableRepos = 0
$global:maxHighAlerts = 0
$global:maxCriticalAlerts = 0
$global:reposAnalyzed = 0

$nodeBasedActions = 0
$dockerBasedActions = 0
$localDockerFile = 0
$remoteDockerfile = 0
$actionYmlFile = 0
$actionYamlFile = 0
$actionDockerFile = 0
$compositeAction = 0
$unknownActionType = 0
$repoInfo = 0
# store current datetime
$oldestRepo = Get-Date
$updatedLastMonth = 0
$updatedLastQuarter = 0
$updatedLast6Months = 0
$updatedLast12Months = 0
$moreThen12Months = 0
$sumDaysOld = 0
$archived = 0

function GetVulnerableIfo {
    Param (
        $action,
        $actionType
    )
    if ($action.vulnerabilityStatus) {
        $global:reposAnalyzed++
        if ($action.vulnerabilityStatus.high -gt 0) {
            $global:highAlerts++

            if ($action.vulnerabilityStatus.high -gt $maxHighAlerts) {
                $global:maxHighAlerts = $action.vulnerabilityStatus.high
            }
        }

        if ($action.vulnerabilityStatus.critical -gt 0) {
            $global:criticalAlerts++

            if ($action.vulnerabilityStatus.critical -gt $maxCriticalAlerts) {
                $global:maxCriticalAlerts = $action.vulnerabilityStatus.critical
            }
        }

        if ($action.vulnerabilityStatus.critical -gt 0 -or $action.vulnerabilityStatus.high -gt 0) {
            $global:vulnerableRepos++
        }

        if ($action.vulnerabilityStatus.critical + $action.vulnerabilityStatus.high -gt 10) {
            "https://github.com/actions-marketplace-validations/$($action.name) Critical: $($action.vulnerabilityStatus.critical) High: $($action.vulnerabilityStatus.high)" | Out-File -FilePath VulnerableRepos-$actionType.txt -Append
        }
    }
}

foreach ($action in $actions) {
        
    GetVulnerableIfo -action $action -actionType "Any"

    if ($action.actionType) {
        # actionType
        if ($action.actionType.actionType -eq "Docker") {
            $dockerBasedActions++
            if ($action.actionType.actionDockerType -eq "Dockerfile") {
                $localDockerFile++
            }
            elseif ($action.actionType.actionDockerType -eq "Image") {
                $remoteDockerfile++
            }
        }
        elseif ($action.actionType.actionType -eq "Node") {
            $nodeBasedActions++
        }        
        elseif ($action.actionType.actionType -eq "Composite") {
            $compositeAction++
        }
        elseif (($action.actionType.actionType -eq "Unkown") -or ($null -eq $action.actionType.actionType)){
            $unknownActionType++
        }

        # action definition sort
        if ($action.actionType.fileFound -eq "action.yml") {
            $actionYmlFile++
        }
        elseif ($action.actionType.fileFound -eq "action.yaml") {
            $actionYamlFile++
        }
        elseif ($action.actionType.fileFound -eq "Dockerfile") {
            $actionDockerFile++
        }
    }
    else {
        $unknownActionType++
    }

    if ($action.repoInfo -And $action.repoInfo.updated_at ) {
        $repoInfo++

        if ($action.repoInfo.updated_at -lt $oldestRepo) {
            $oldestRepo = $action.repoInfo.updated_at
        }

        if ($action.repoInfo.updated_at -gt (Get-Date).AddMonths(-1)) {
            $updatedLastMonth++
        }
        elseif ($action.repoInfo.updated_at -gt (Get-Date).AddMonths(-3)) {
            $updatedLastQuarter++
        } 
        elseif ($action.repoInfo.updated_at -gt (Get-Date).AddMonths(-6)) {
            $updatedLast6Months++
        }
        elseif ($action.repoInfo.updated_at -gt (Get-Date).AddMonths(-12)) {
            $updatedLast12Months++
        }
        else {
            $moreThen12Months++
        }

        $sumDaysOld += ((Get-Date) - $action.repoInfo.updated_at).Days

        if ($action.repoInfo.archived) {
            $archived++
        }
    }
}

function GetTagReleaseInfo {
    $tagButNoRelease = 0
    $tagInfo = 0
    $releaseInfo = 0
    $countMismatch = 0
    foreach ($action in $actions) {
        if ($action.tagInfo) {
            $tagInfo++
            if (!$action.releaseInfo) {
                $tagButNoRelease++
            }
            else {                
                $releaseInfo++

                $tagCount = 0
                if ($action.tagInfo.GetType().FullName -eq "System.Object[]") {
                    $tagCount = $action.tagInfo.Count
                }
                elseif ($null -ne $action.tagInfo) {
                    $tagCount = 1
                }

                $releaseCount = 0
                if ($action.releaseInfo.GetType().FullName -eq "System.Object[]") {
                    $releaseCount = $action.releaseInfo.Count
                }
                elseif ($null -ne $action.releaseInfo.Length) {
                    $releaseCount = 1
                }

                if (($tagCount -gt 0) -And ($releaseCount -gt 0)) {
                    if ($tagCount -ne $releaseCount) {
                        $countMismatch++
                    }
                }
            }
        }
    }

    Write-Host ""
    Write-Host "Total actions: $($actions.Count)"
    Write-Host "Repos with tag info but no releases: $tagButNoRelease"
    Write-Host "Repos with mismatches between tag and release count: $countMismatch"
}

function LogMessage {
    Param (
        $message
    )

    Write-Host $message 
    if ($logSummary) {
        $message | Out-File $logSummary -Append
    }
}

# calculations
function VulnerabilityCalculations {
    $averageHighAlerts = 0
    $averageCriticalAlerts = 0
    if ($reposAnalyzed -eq 0) {
        Write-Error "No repos analyzed"        
    } 
    else {
        $averageHighAlerts = $global:highAlerts / $global:reposAnalyzed
        $averageCriticalAlerts = $global:criticalAlerts / $global:reposAnalyzed
    }

    Write-Host "Summary: "
    LogMessage "## Potentially vulnerable Repos: $vulnerableRepos out of $reposAnalyzed analyzed repos [Total: $($actions.Count)]"

    LogMessage "| Type                  | Count           |"
    LogMessage "|---|---|"
    LogMessage "| Total high alerts     | $($global:highAlerts)     |"
    LogMessage "| Total critical alerts | $($global:criticalAlerts) |"
    LogMessage ""
    LogMessage "| Maximum number of alerts per repo | Count              |"
    LogMessage "|---|---|"
    LogMessage "| High alerts                       | $($global:maxHighAlerts)     |"
    LogMessage "| Critical alerts                   | $($global:maxCriticalAlerts) |"
    LogMessage ""
    LogMessage "| Average number of alerts per vuln. repo | Count              |"
    LogMessage "|---|---|"
    LogMessage "| High alerts per vulnerable repo         | $([math]::Round($averageHighAlerts, 1))|"
    LogMessage "| Critical alerts per vulnerable repo     | $([math]::Round($averageCriticalAlerts, 1))|"
}

function ReportVulnChartInMarkdown {
    Param (
        $chartTitle,
        $actions
    )
    if (!$logSummary) {
        # do not report locally
        return
    }

    Write-Host "Writing chart [$chartTitle] with information about [$($actions.Count)] actions and [$global:reposAnalyzed] reposAnalyzed"

    LogMessage ""
    LogMessage "``````mermaid"
    LogMessage "%%{init: {'theme':'dark', 'themeVariables': { 'darkMode':'true','primaryColor': '#000000', 'pie1':'#686362', 'pie2':'#d35130' }}}%%"
    LogMessage "pie title Potentially vulnerable $chartTitle"
    LogMessage "    ""Unknown: $($actions.Count - $global:reposAnalyzed)"" : $($actions.Count - $global:reposAnalyzed)"
    LogMessage "    ""Vulnerable actions: $($global:vulnerableRepos)"" : $($global:vulnerableRepos)"
    LogMessage "    ""Non vulnerable actions: $($global:reposAnalyzed - $global:vulnerableRepos)"" : $($global:reposAnalyzed - $global:vulnerableRepos)"
    LogMessage "``````"
}

function ReportInsightsInMarkdown {
    if (!$logSummary) {
        # do not report locally
        return
    }

    LogMessage "## Action type"
    LogMessage "Action type is determined by the action definition file and can be either Node (JavaScript/TypeScript) or Docker based, or it can be a composite action. A remote image means it is pulled directly from a container registry, instead of a local file."
    LogMessage "``````mermaid"
    LogMessage "flowchart LR"
    LogMessage "  A[$reposAnalyzed Actions]-->B[$nodeBasedActions Node based]"
    LogMessage "  A-->C[$dockerBasedActions Docker based]"
    LogMessage "  A-->D[$compositeAction Composite actions]"
    LogMessage "  C-->E[$localDockerFile Local Dockerfile]"
    LogMessage "  C-->F[$remoteDockerfile Remote image]"
    LogMessage "  A-->G[$unknownActionType Unknown]"
    LogMessage "``````"
    LogMessage ""
    LogMessage "## Action definition setup"
    LogMessage "How is the action defined? The runner can pick it up from these files in the root of the repo: action.yml, action.yaml, or Dockerfile. The Dockerfile can also be referened from the action definition file. If that is the case, it will show up as one of those two files in this overview."
    LogMessage "``````mermaid"
    LogMessage "flowchart LR"
    $ymlPercentage = [math]::Round($actionYmlFile/$reposAnalyzed * 100 , 1)
    LogMessage "  A[$reposAnalyzed Actions]-->B[$actionYmlFile action.yml - $ymlPercentage%]"
    $yamlPercentage = [math]::Round($actionYamlFile/$reposAnalyzed * 100 , 1)
    LogMessage "  A-->C[$actionYamlFile action.yaml - $yamlPercentage%]"
    $dockerPercentage = [math]::Round($actionDockerFile/$reposAnalyzed * 100 , 1)
    LogMessage "  A-->D[$actionDockerFile Dockerfile - $dockerPercentage%]"
    $unknownActionDefinitionCount = $reposAnalyzed - $actionYmlFile - $actionYamlFile - $actionDockerFile
    $unknownActionPercentage = [math]::Round($unknownActionDefinitionCount/$reposAnalyzed * 100 , 1)
    LogMessage "  A-->E[$unknownActionDefinitionCount Unknown - $unknownActionPercentage%]"
    LogMessage "``````"
}

function ReportAgeInsights {
    LogMessage "## Repo age"
    LogMessage "How recent where the repos updated? Determined by looking at the last updated date."
    LogMessage "|Analyzed|Total: $repoInfo|Analyzed: $reposAnalyzed repos|100%|"
    LogMessage "|---|---|---|---|"
    $timeSpan = New-TimeSpan –Start $oldestRepo –End (Get-Date)
    LogMessage "|Oldest repository             |$($timeSpan.Days) days old            |||"
    LogMessage "|Updated last month             | $updatedLastMonth   |$repoInfo repos |$([math]::Round($updatedLastMonth   /$repoInfo * 100 , 1))%|"
    LogMessage "|Updated within last 3 months   | $updatedLastQuarter |$repoInfo repos |$([math]::Round($updatedLastQuarter /$repoInfo * 100 , 1))%|"
    LogMessage "|Updated within last 3-6 months | $updatedLast6Months |$repoInfo repos |$([math]::Round($updatedLast6Months /$repoInfo * 100 , 1))%|"
    LogMessage "|Updated within last 6-12 months| $updatedLast12Months|$repoInfo repos |$([math]::Round($updatedLast12Months/$repoInfo * 100 , 1))%|"
    LogMessage "|Updated more then 12 months ago| $moreThen12Months   |$repoInfo repos |$([math]::Round($moreThen12Months   /$repoInfo * 100 , 1))%|"
    LogMessage ""
    LogMessage "Average age: $([math]::Round($sumDaysOld / $repoInfo, 1)) days"
    LogMessage "Archived repos: $archived"

}

# call the report functions
ReportAgeInsights
LogMessage ""

ReportInsightsInMarkdown
VulnerabilityCalculations
ReportVulnChartInMarkdown -chartTitle "actions"  -actions $actions


# reset everything for just the Node actions
$global:highAlerts = 0
$global:criticalAlerts = 0
$global:vulnerableRepos = 0
$global:maxHighAlerts = 0
$global:maxCriticalAlerts = 0
$global:reposAnalyzed = 0
$nodeBasedActions = $actions | Where-Object {($null -ne $_.actionType) -and ($_.actionType.actionType -eq "Node")}
foreach ($action in $nodeBasedActions) {        
    GetVulnerableIfo -action $action -actionType "Node"
}
ReportVulnChartInMarkdown -chartTitle "Node actions" -actions $nodeBasedActions


# reset everything for just the Composite actions
$global:highAlerts = 0
$global:criticalAlerts = 0
$global:vulnerableRepos = 0
$global:maxHighAlerts = 0
$global:maxCriticalAlerts = 0
$global:reposAnalyzed = 0
$compositeActions = $actions | Where-Object {($null -ne $_.actionType) -and ($_.actionType.actionType -eq "Composite")}
foreach ($action in $compositeActions) {        
    GetVulnerableIfo -action $action -actionType "Composite"
}
ReportVulnChartInMarkdown -chartTitle "Composite actions"  -actions $compositeActions

GetTagReleaseInfo
