using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

function RegenerateKey($keyId, $providerAddress){
    Write-Host "Regenerating key. Id: $keyId Resource Id: $providerAddress"
    
    $redisName = ($providerAddress -split '/')[8]
    $resourceGroupName = ($providerAddress -split '/')[4]
    
    #Regenerate key 
    $newKeyValue = (New-AzRedisCacheKey -Name $redisName -ResourceGroupName $resourceGroupName -KeyType $keyId -Force)."$($keyId)Key"
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


# Write to the Azure Functions log stream.
Write-Host "HTTP trigger function processed a request."

Try{
    #Validate request paramaters
    $keyVAultName = $Request.Query.KeyVaultName
    $secretName = $Request.Query.SecretName
    if (-not $keyVAultName -or -not $secretName ) {
        $status = [HttpStatusCode]::BadRequest
        $body = "Please pass a KeyVaultName and SecretName on the query string"
        break
    }
    
    Write-Host "Key Vault Name: $keyVAultName"
    Write-Host "Secret Name: $secretName"
    
    #Rotate secret
    Write-Host "Rotation started. Secret Name: $secretName"
    RoatateSecret $keyVAultName $secretName

    $status = [HttpStatusCode]::Ok
    $body = "Secret Rotated Successfully"
     
}
Catch{
    $status = [HttpStatusCode]::InternalServerError
    $body = "Error during secret rotation"
    Write-Error "Secret Rotation Failed: $_.Exception.Message"
}
Finally
{
    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $status
        Body = $body
    })
}

