# Need this variable as long as we support PS v2
$ModuleBasePath = Split-Path $MyInvocation.MyCommand.Path -Parent

# Store error records generated by stderr output when invoking an executable
# This can be accessed from the user's session by executing:
# PS> $m = Get-Module posh-git
# PS> & $m Get-Variable invokeErrors -ValueOnly
$invokeErrors = New-Object System.Collections.ArrayList 256

# General Utility Functions

function Invoke-NullCoalescing {
    $result = $null
    foreach ($arg in $args) {
        if ($arg -is [ScriptBlock]) {
            $result = & $arg
        }
        else {
            $result = $arg
        }
        if ($result) { break }
    }
    $result
}

Set-Alias ?? Invoke-NullCoalescing -Force

function Invoke-Utf8ConsoleCommand([ScriptBlock]$cmd) {
    $currentEncoding = [Console]::OutputEncoding
    $errorCount = $global:Error.Count
    try {
        # A native executable that writes to stderr AND has its stderr redirected will generate non-terminating
        # error records if the user has set $ErrorActionPreference to Stop. Override that value in this scope.
        $ErrorActionPreference = 'Continue'
        try { 
            [Console]::OutputEncoding = [Text.Encoding]::UTF8
            & $cmd
            try { 
                [Console]::OutputEncoding = $currentEncoding
            }
            catch [System.IO.IOException] {}
        }
        catch [System.IO.IOException] {
            & $cmd
        }
    }
    finally {
        # Clear out stderr output that was added to the $Error collection, putting those errors in a module variable
        if ($global:Error.Count -gt $errorCount) {
            $numNewErrors = $global:Error.Count - $errorCount
            $invokeErrors.InsertRange(0, $global:Error.GetRange(0, $numNewErrors))
            if ($invokeErrors.Count -gt 256) {
                $invokeErrors.RemoveRange(256, ($invokeErrors.Count - 256))
            }
            $global:Error.RemoveRange(0, $numNewErrors)
        }
    }
}

function Test-Administrator {
    # PowerShell 5.x only runs on Windows so use .NET types to determine isAdminProcess
    # Or if we are on v6 or higher, check the $IsWindows pre-defined variable.
    if (($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows) {
        $currentUser = [Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())
        return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # Must be Linux or OSX, so use the id util. Root has userid of 0.
    return 0 -eq (id -u)
}

<#
.SYNOPSIS
    Configures your PowerShell profile (startup) script to import the posh-git
    module when PowerShell starts.
.DESCRIPTION
    Checks if your PowerShell profile script is not already importing posh-git
    and if not, adds a command to import the posh-git module. This will cause
    PowerShell to load posh-git whenever PowerShell starts.
.PARAMETER AllHosts
    By default, this command modifies the CurrentUserCurrentHost profile
    script.  By specifying the AllHosts switch, the command updates the
    CurrentUserAllHosts profile (or AllUsersAllHosts, given -AllUsers).
.PARAMETER AllUsers
    By default, this command modifies the CurrentUserCurrentHost profile
    script.  By specifying the AllUsers switch, the command updates the
    AllUsersCurrentHost profile (or AllUsersAllHosts, given -AllHosts).
    Requires elevated permissions.
.PARAMETER Force
    Do not check if the specified profile script is already importing
    posh-git. Just add Import-Module posh-git command.
.EXAMPLE
    PS C:\> Add-PoshGitToProfile
    Updates your profile script for the current PowerShell host to import the
    posh-git module when the current PowerShell host starts.
.EXAMPLE
    PS C:\> Add-PoshGitToProfile -AllHosts
    Updates your profile script for all PowerShell hosts to import the posh-git
    module whenever any PowerShell host starts.
.INPUTS
    None.
.OUTPUTS
    None.
#>
function Add-PoshGitToProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]
        $AllHosts,

        [Parameter()]
        [switch]
        $AllUsers,

        [Parameter()]
        [switch]
        $Force,

        [Parameter(ValueFromRemainingArguments)]
        [psobject[]]
        $TestParams
    )

    if ($AllUsers -and !(Test-Administrator)) {
        throw 'Adding posh-git to an AllUsers profile requires an elevated host.'
    }

    $underTest = $false

    $profileName = $(if ($AllUsers) { 'AllUsers' } else { 'CurrentUser' }) `
                 + $(if ($AllHosts) { 'AllHosts' } else { 'CurrentHost' })
    Write-Verbose "`$profileName = '$profileName'"

    $profilePath = $PROFILE.$profileName
    Write-Verbose "`$profilePath = '$profilePath'"

    # Under test, we override some variables using $args as a backdoor.
    if (($TestParams.Count -gt 0) -and ($TestParams[0] -is [string])) {
        $profilePath = [string]$TestParams[0]
        $underTest = $true
        if ($TestParams.Count -gt 1) {
            $ModuleBasePath = [string]$TestParams[1]
        }
    }

    if (!$profilePath) { $profilePath = $PROFILE }

    if (!$Force) {
        # Search the user's profiles to see if any are using posh-git already, there is an extra search
        # ($profilePath) taking place to accomodate the Pester tests.
        $importedInProfile = Test-PoshGitImportedInScript $profilePath
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE
        }
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE.CurrentUserCurrentHost
        }
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE.CurrentUserAllHosts
        }
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE.AllUsersCurrentHost
        }
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE.AllUsersAllHosts
        }

        if ($importedInProfile) {
            Write-Warning "Skipping add of posh-git import to file '$profilePath'."
            Write-Warning "posh-git appears to already be imported in one of your profile scripts."
            Write-Warning "If you want to force the add, use the -Force parameter."
            return
        }
    }

    if (!$profilePath) {
        Write-Warning "Skipping add of posh-git import to profile; no profile found."
        Write-Verbose "`$PROFILE              = '$PROFILE'"
        Write-Verbose "CurrentUserCurrentHost = '$($PROFILE.CurrentUserCurrentHost)'"
        Write-Verbose "CurrentUserAllHosts    = '$($PROFILE.CurrentUserAllHosts)'"
        Write-Verbose "AllUsersCurrentHost    = '$($PROFILE.AllUsersCurrentHost)'"
        Write-Verbose "AllUsersAllHosts       = '$($PROFILE.AllUsersAllHosts)'"
        return
    }

    # If the profile script exists and is signed, then we should not modify it
    if (Test-Path -LiteralPath $profilePath) {
        if (!(Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue))
        {
            Write-Verbose "Platform doesn't support script signing, skipping test for signed profile."
        }
        else {
            $sig = Get-AuthenticodeSignature $profilePath
            if ($null -ne $sig.SignerCertificate) {
                Write-Warning "Skipping add of posh-git import to profile; '$profilePath' appears to be signed."
                Write-Warning "Add the command 'Import-Module posh-git' to your profile and resign it."
                return
            }
        }
    }

    # Check if the location of this module file is in the PSModulePath
    if (Test-InPSModulePath $ModuleBasePath) {
        $profileContent = "`nImport-Module posh-git"
    }
    else {
        $modulePath = Join-Path $ModuleBasePath posh-git.psd1
        $profileContent = "`nImport-Module '$modulePath'"
    }

    # Make sure the PowerShell profile directory exists
    $profileDir = Split-Path $profilePath -Parent
    if (!(Test-Path -LiteralPath $profileDir)) {
        if ($PSCmdlet.ShouldProcess($profileDir, "Create current user PowerShell profile directory")) {
            New-Item $profileDir -ItemType Directory -Force -Verbose:$VerbosePreference > $null
        }
    }

    if ($PSCmdlet.ShouldProcess($profilePath, "Add 'Import-Module posh-git' to profile")) {
        Add-Content -LiteralPath $profilePath -Value $profileContent -Encoding UTF8
    }
}

<#
.SYNOPSIS
    Gets the file encoding of the specified file.
.DESCRIPTION
    Gets the file encoding of the specified file.
.PARAMETER Path
    Path to the file to check.  The file must exist.
.EXAMPLE
    PS C:\> Get-FileEncoding $profile
    Get's the file encoding of the profile file.
.INPUTS
    None.
.OUTPUTS
    [System.String]
.NOTES
    Adapted from http://www.west-wind.com/Weblog/posts/197245.aspx
#>
function Get-FileEncoding($Path) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $bytes = [byte[]](Get-Content $Path -AsByteStream -ReadCount 4 -TotalCount 4)
    }
    else {
        $bytes = [byte[]](Get-Content $Path -Encoding byte -ReadCount 4 -TotalCount 4)
    }

    if (!$bytes) { return 'utf8' }

    switch -regex ('{0:x2}{1:x2}{2:x2}{3:x2}' -f $bytes[0],$bytes[1],$bytes[2],$bytes[3]) {
        '^efbbbf'   { return 'utf8' }
        '^2b2f76'   { return 'utf7' }
        '^fffe'     { return 'unicode' }
        '^feff'     { return 'bigendianunicode' }
        '^0000feff' { return 'utf32' }
        default     { return 'ascii' }
    }
}

<#
.SYNOPSIS
    Gets a StringComparison enum value appropriate for comparing paths on the OS platform.
.DESCRIPTION
    Gets a StringComparison enum value appropriate for comparing paths on the OS platform.
.EXAMPLE
    PS C:\> $pathStringComparison = Get-PathStringComparison
.INPUTS
    None
.OUTPUTS
    [System.StringComparison]
#>
function Get-PathStringComparison {
    # File system paths are case-sensitive on Linux and case-insensitive on Windows and macOS
    if (($PSVersionTable.PSVersion.Major -ge 6) -and $IsLinux) {
        [System.StringComparison]::Ordinal
    }
    else {
        [System.StringComparison]::OrdinalIgnoreCase
    }
}

function Get-PromptPath {
    $settings = $global:GitPromptSettings
    $stringComparison = Get-PathStringComparison

    # A UNC path has no drive so it's better to use the ProviderPath e.g. "\\server\share".
    # However for any path with a drive defined, it's better to use the Path property.
    # In this case, ProviderPath is "\LocalMachine\My"" whereas Path is "Cert:\LocalMachine\My".
    # The latter is more desirable.
    $pathInfo = $ExecutionContext.SessionState.Path.CurrentLocation
    $currentPath = if ($pathInfo.Drive) { $pathInfo.Path } else { $pathInfo.ProviderPath }
    if (!$settings -or !$currentPath -or $currentPath.Equals($Home, $stringComparison)) {
        return $currentPath
    }

    $abbrevHomeDir = $settings.DefaultPromptAbbreviateHomeDirectory
    $abbrevGitDir = $settings.DefaultPromptAbbreviateGitDirectory

    # Look up the git root
    if ($abbrevGitDir) {
        $gitPath = Get-GitDirectory
        # Up one level from `.git`
        if ($gitPath) { $gitPath = Split-Path $gitPath -Parent }
    }

    # Abbreviate path under a git repository as "<repo-name>:<relative-path>"
    if ($abbrevGitDir -and $gitPath -and $currentPath.StartsWith($gitPath, $stringComparison)) {
        $gitName = Split-Path $gitPath -Leaf
        $relPath = if ($currentPath -eq $gitPath) { "" } else { $currentPath.SubString($gitPath.Length + 1) }
        $currentPath = "$gitName`:$relPath"
    }
    # Abbreviate path under the user's home dir as "~<relative-path>"
    elseif ($abbrevHomeDir -and $currentPath.StartsWith($Home, $stringComparison)) {
        $currentPath = "~" + $currentPath.SubString($Home.Length)
    }

    return $currentPath
}

<#
.SYNOPSIS
    Gets a string with current machine name and user name when connected with SSH
.PARAMETER Format
    Format string to use for displaying machine name ({0}) and user name ({1}).
    Default: "[{1}@{0}]: ", i.e. "[user@machine]: "
.INPUTS
    None
.OUTPUTS
    [String]
#>
function Get-PromptConnectionInfo($Format = '[{1}@{0}]: ') {
    if ($GitPromptSettings -and (Test-Path Env:SSH_CONNECTION)) {
        $MachineName = [System.Environment]::MachineName
        $UserName = [System.Environment]::UserName
        $Format -f $MachineName,$UserName
    }
}

function Get-PSModulePath {
    $modulePaths = $Env:PSModulePath -split ';'
    $modulePaths
}

function Test-InPSModulePath {
    param (
        [Parameter(Position=0, Mandatory=$true)]
        [ValidateNotNull()]
        [string]
        $Path
    )

    $modulePaths = Get-PSModulePath
    if (!$modulePaths) { return $false }

    $pathStringComparison = Get-PathStringComparison
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $inModulePath = @($modulePaths | Where-Object { $Path.StartsWith($_.TrimEnd([System.IO.Path]::DirectorySeparatorChar), $pathStringComparison) }).Count -gt 0

    if ($inModulePath -and ('src' -eq (Split-Path $Path -Leaf))) {
        Write-Warning 'posh-git repository structure is incompatible with %PSModulePath%.'
        Write-Warning 'Importing with absolute path instead.'
        return $false
    }

    $inModulePath
}

function Test-PoshGitImportedInScript {
    param (
        [Parameter(Position=0)]
        [string]
        $Path
    )

    if (!$Path -or !(Test-Path -LiteralPath $Path)) {
        return $false
    }

    $match = (@(Get-Content $Path -ErrorAction SilentlyContinue) -match 'posh-git').Count -gt 0
    if ($match) { Write-Verbose "posh-git found in '$Path'" }
    $match
}

function dbg($Message, [Diagnostics.Stopwatch]$Stopwatch) {
    if ($Stopwatch) {
        Write-Verbose ('{0:00000}:{1}' -f $Stopwatch.ElapsedMilliseconds,$Message) -Verbose # -ForegroundColor Yellow
    }
}
