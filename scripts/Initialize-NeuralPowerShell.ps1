# Start-Process can pass PowerShell 7's module paths to Windows PowerShell.
# Prefer this host's built-in modules before any command autoload occurs, while
# retaining user module paths. This changes only the current process environment.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $neuralNativeModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
    $neuralInheritedModulePath = [string]$env:PSModulePath
    $neuralFirstModulePath = $neuralInheritedModulePath.Split([IO.Path]::PathSeparator)[0].TrimEnd('\', '/')
    if ($neuralFirstModulePath -ine $neuralNativeModulePath.TrimEnd('\', '/')) {
        $env:PSModulePath = if ($neuralInheritedModulePath) {
            $neuralNativeModulePath + [IO.Path]::PathSeparator + $neuralInheritedModulePath
        } else { $neuralNativeModulePath }
    }
}
