# Get KMS Server From Current Domain
$domain = $env:USERDNSDOMAIN
if (-not $domain) { $domain = Read-Host "Informe o domínio (ex: contoso.local)" }

Resolve-DnsName -Type SRV "_vlmcs._tcp.$domain" |
    Select-Object NameTarget, Port, Priority, Weight