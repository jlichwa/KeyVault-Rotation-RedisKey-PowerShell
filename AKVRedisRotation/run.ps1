param($eventGridEvent, $TriggerMetadata)

function RegenerateKey($keyId, $providerAddress){
    Write-Host "Regenerating key. Id: $keyId Resource Id: $providerAddress"
    
    $redisName = ($providerAddress -split '/')[8]
    $resourceGroupName = ($providerAddress -split '/')[4]
    $subscriptionId = ($providerAddress -split '/')[2]
    
    #Regenerate key 
    #$newKeyValue = (New-AzRedisCacheKey -Name $redisName -ResourceGroupName myGroup -KeyType $keyId -Force|where KeyName -eq $keyId).value
    $tokenAuthURI = $env:MSI_ENDPOINT + "?resource=https://management.azure.com/&api-version=2017-09-01"
    $tokenResponse = Invoke-RestMethod -Method Get -Headers @{"Secret"="$env:MSI_SECRET"} -Uri $tokenAuthURI
    $accessToken = $tokenResponse.access_token
    
    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Cache/Redis/$redisName/regenerateKey?api-version=2018-03-01"
    $postParams = @{"keyType"=$keyId}
    Invoke-WebRequest -Uri $uri -Method Post -Headers @{Authorization ="Bearer $accessToken"} -Body $postParams

    $newKeyValue = (Get-AzRedisCacheKey -ResourceGroupName $resourceGroupName -Name $redisName)."$($keyId)Key"
    return $newKeyValue
}

function AddSecretToKeyVault($keyVAultName,$secretName,$newAccessKeyValue,$exprityDate,$tags){
    
    $secretvalue = ConvertTo-SecureString "$newAccessKeyValue" -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $keyVAultName -Name $secretName -SecretValue $secretvalue -Tag $tags -Expires $expiryDate

}

function GetAlternateCredentialId($keyId){
    $validCredentialIdsRegEx = 'Primary|Secondary'
    
    If($keyId -NotMatch $validCredentialIdsRegEx){
        throw "Invalid credential id: $keyId. Credential id must follow this pattern:$validCredentialIdsRegEx"
    }
    If($keyId -eq 'Primary'){
        return "Secondary"
    }
    Else{
        return "Primary"
    }
}

function RoatateSecret($keyVaultName,$secretName){
    #Retrieve Secret
    $secret = (Get-AzKeyVaultSecret -VaultName $keyVAultName -Name $secretName)
    Write-Host "Secret Retrieved"
    
    #Retrieve Secret Info
    $validityPeriodDays = $secret.Tags["ValidityPeriodDays"]
    $credentialId=  $secret.Tags["CredentialId"]
    $providerAddress = $secret.Tags["ProviderAddress"]
    
    Write-Host "Secret Info Retrieved"
    Write-Host "Validity Period: $validityPeriodDays"
    Write-Host "Credential Id: $credentialId"
    Write-Host "Provider Address: $providerAddress"

    #Get Credential Id to rotate - alternate credential
    $alternateCredentialId = GetAlternateCredentialId $credentialId
    Write-Host "Alternate credential id: $alternateCredentialId"

    #Regenerate alternate access key in provider
    $newAccessKeyValue = (RegenerateKey $alternateCredentialId $providerAddress)[-1]
    Write-Host "Access key regenerated. Access Key Id: $alternateCredentialId Resource Id: $providerAddress"

    #Add new access key to Key Vault
    $newSecretVersionTags = @{}
    $newSecretVersionTags.ValidityPeriodDays = $validityPeriodDays
    $newSecretVersionTags.CredentialId=$alternateCredentialId
    $newSecretVersionTags.ProviderAddress = $providerAddress

    $expiryDate = (Get-Date).AddDays([int]$validityPeriodDays).ToUniversalTime()
    AddSecretToKeyVault $keyVAultName $secretName $newAccessKeyValue $expiryDate $newSecretVersionTags

    Write-Host "New access key added to Key Vault. Secret Name: $secretName"
}

# Make sure to pass hashtables to Out-String so they're logged correctly
$eventGridEvent | ConvertTo-Json | Write-Host

$secretName = $eventGridEvent.subject
$keyVaultName = $eventGridEvent.data.VaultName
Write-Host "Key Vault Name: $keyVAultName"
Write-Host "Secret Name: $secretName"

#Rotate secret
Write-Host "Rotation started."
RoatateSecret $keyVAultName $secretName
Write-Host "Secret Rotated Successfully"

