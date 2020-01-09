
#get a random lowercase string https://devblogs.microsoft.com/scripting/generate-random-letters-with-powershell/
$RANDOM = $(-join ((97..122) | Get-Random -Count 5 | % {[char]$_}))

$RANDOM = "wtzao"
$rg = "myResourceGroup$RANDOM"
$location = 'westus'
$saName = "mystorageaccount$RANDOM"
$sendAspName = "mySendPlan$RANDOM"
$receiveAspName = "myReceivePlan$RANDOM"
$sendFaName = "mysendfunctionapp$RANDOM"
$receiveFaName = "myreceivefunctionapp$RANDOM"
$faEventHubAppConfig = "my_RootManageSharedAccessKey_EVENTHUB"
$faStorageAccountConfig = "AzureWebJobsStorage"
$kvName = "mykeyvault$RANDOM"
$kvSecretName = 'SuperSecret'
$kvSecretValue = 'My super secret!'
$kvEHSecretName = 'EventHubConnection'
$kvSASecretName = 'StorageAccountConnection'
$kvMonitorName = 'monitoring-my-kv'
$ehName = "alert-eh"
$ehNamespace = "mynamespace$RANDOM"
$ehConsumerGroup = "myconsumergroup"
$sendFaFolder = "az-mon-eh-send-kv-python"
$receiveFaFolder = "az-mon-eh-receive-kv-python"
$sendFuncName = "SendAlertHttpTrigger"
$sendURIPath = "api/$sendFuncName"
$sendActionGroupName = "myAlertActionGroup"
$sendActionGroupReceiverName = "myAGreceiver"
$saAlertName = "myStorageAccountAlert"

$vnetName = "myVnet$RANDOM"
#be sure that the VNET address space doesn't have conflicts with existing VNETs address spaces in subscription
$vnetAddressPrefix = "10.3.0.0/16"
#https://docs.microsoft.com/en-us/azure/app-service/web-sites-integrate-with-vnet
#The feature requires an unused subnet that is a /27 with 32 addresses or larger in your Resource Manager VNet
$receiveSubnetAddressPrefix = "10.3.3.0/24"
$receiveSubnetName = "myAlertReceiveSubnet"
$subnetAddressPrefix = "10.3.0.0/24"
$subnetName = "myAlertSubnet"

$vmSubnetAddressPrefix = "10.3.1.0/24"
$vmSubnetName = "default"
$vmAdminUserName = "myAdmin"
$vmAdminPassword = "ReplaceP@ssw0rd123$"
$vmName = "myVM$RANDOM"
$vmImage = "Win2016Datacenter"
$vmPublicIpAddressAllocation = "static"
$vmSize = "Standard_DS2_v2"
$vmAlertName = "$vmName-Alert"
$usePushDeploy = $False #attempt to push function applications.  This assumes that we're able to resolve the network host from within VNET.

#create an rg
az group create -n $rg -l $location

az network vnet create -g $rg -n $vnetName --address-prefixes $vnetAddressPrefix --subnet-name $subnetName --subnet-prefixes $subnetAddressPrefix
$subnetID = $(az network vnet show -g $rg -n $vnetName --query "subnets[?name=='$subnetName'].id" -o tsv)

$vmSubnetObject = $(az network vnet subnet create -g $rg --vnet-name $vnetName -n $vmSubnetName --address-prefixes $vmSubnetAddressPrefix) | ConvertFrom-Json
$receiveSubnetObject = $(az network vnet subnet create -g $rg --vnet-name $vnetName -n $receiveSubnetName --address-prefixes $receiveSubnetAddressPrefix) | ConvertFrom-Json

az network vnet subnet update --resource-group $rg --vnet-name $vnetName --name $subnetName --service-endpoints "Microsoft.KeyVault", "Microsoft.Storage", "Microsoft.EventHub"
az network vnet subnet update --resource-group $rg --vnet-name $vnetName --name $vmSubnetName --service-endpoints "Microsoft.KeyVault", "Microsoft.Storage", "Microsoft.EventHub"
az network vnet subnet update --resource-group $rg --vnet-name $vnetName --name $receiveSubnetName --service-endpoints "Microsoft.KeyVault", "Microsoft.Storage", "Microsoft.EventHub"

#This subnet is hosting a VM.
Write-Host "Creating a VM"
$defaultSubnetID = "/subscriptions/$subscriptionID/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/$vmSubnetName"
#need to asssociate with a static ip address
az vm create --image $vmImage --admin-username $vmAdminUserName --admin-password $vmAdminPassword -l $location -g $rg -n $vmName --subnet $defaultSubnetID --public-ip-address-allocation $vmPublicIpAddressAllocation --size $vmSize

# Create a storage account in the resource group.
az storage account create --name $saName --location $location --resource-group $rg --sku Standard_LRS
az storage account network-rule add -g $rg -n $saName --subnet $subnetID
az storage account network-rule add -g $rg -n $saName --subnet $receiveSubnetObject.id

#create app service plan and function for Sender
Write-Host "Creating Function App for Sender"
az appservice plan create --name $sendAspName --resource-group $rg --sku P2V2 --is-linux
az functionapp create --name $sendFaName --resource-group $rg --plan $sendAspName --storage-account $saName --os-type Linux --runtime python --runtime-version 3.7
az functionapp vnet-integration add -g $rg -n $sendFaName --vnet $vnetName --subnet $subnetName

az functionapp identity assign --name $sendFaName --resource-group $rg

#create app service plan and function for Receiver
Write-Host "Creating Function App for Receiver"
az appservice plan create --name $receiveAspName --resource-group $rg --sku P2V2 --is-linux
az functionapp create --name $receiveFaName --resource-group $rg --plan $receiveAspName --storage-account $saName --os-type Linux --runtime python --runtime-version 3.7
#need a separate subnet to avoid conflict with hosting another function app.
az functionapp vnet-integration add -g $rg -n $receiveFaName --vnet $vnetName --subnet $receiveSubnetName

az functionapp identity assign --name $receiveFaName --resource-group $rg

#get service principal ID attached to function app
Write-Host "Get SP for Sender"
$sendSpID=$(az functionapp show --resource-group $rg --name $sendFaName --query identity.principalId --out tsv)

Write-Host "Get SP for Receiver"
$receiveSpID=$(az functionapp show --resource-group $rg --name $receiveFaName --query identity.principalId --out tsv)

#create a key vault
Write-Host "Create Key Vault"
az keyvault create --name $kvName --resource-group $rg --location $location

az keyvault network-rule add -g $rg -n $kvName --vnet $vnetName --subnet $subnetName
az keyvault network-rule add -g $rg -n $kvName --vnet $vnetName --subnet $vmSubnetName
az keyvault network-rule add -g $rg -n $kvName --vnet $vnetName --subnet $receiveSubnetName

#create a secret for Key Vault
Write-Host "Create Key Vault Secrets"
az keyvault secret set --name $kvSecretName --value $kvSecretValue --description FunctionAppsecret  --vault-name $kvName

#grant access to key vault.  The Service Principal bound to the Function App needs rights to access the secret in Key vault.
Write-Host "Allow KV access to Sender App"
az keyvault set-policy --name $kvName --resource-group $rg --object-id $sendSpID --secret-permissions get

Write-Host "Allow KV access to Receiver App"
az keyvault set-policy --name $kvName --resource-group $rg --object-id $receiveSpID --secret-permissions get

#get secret URI
$secretURI = $(az keyvault secret show --name $kvSecretName --vault-name $kvName --query id --output tsv)

#bind app setting / environment variable for Azure Function app to key vault secret URI.  Note the extra space for parsing the secret.
Write-Host "Bind App Setting for KV Secret for Sender"
az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$kvSecretName=@Microsoft.KeyVault(SecretUri=$secretURI) "

Write-Host "Bind App Setting for KV Secret for Receiver"
az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$kvSecretName=@Microsoft.KeyVault(SecretUri=$secretURI) "

#create event hub
Write-Host "Create Event Hub Namespace and Event Hub"
az eventhubs namespace create --resource-group $rg --name $ehNamespace --location $location

az eventhubs namespace network-rule add -g $rg --namespace-name $ehNamespace --vnet $vnetName --subnet $subnetName
az eventhubs namespace network-rule add -g $rg --namespace-name $ehNamespace --vnet $vnetName --subnet $receiveSubnetName

az eventhubs namespace network-rule add --action Allow --ignore-missing-endpoint true --namespace-name $ehNamespace --resource-group $rg --subnet $subnetName --subscription $subscriptionID --vnet-name $vnetName
az eventhubs namespace network-rule add --action Allow --ignore-missing-endpoint true --namespace-name $ehNamespace --resource-group $rg --subnet $receiveSubnetName --subscription $subscriptionID --vnet-name $vnetName
az eventhubs namespace network-rule add --action Allow --ignore-missing-endpoint true --namespace-name $ehNamespace --resource-group $rg --subnet $vmSubnetName --subscription $subscriptionID --vnet-name $vnetName

az eventhubs eventhub create --resource-group $rg --namespace-name $ehNamespace --name $ehName --message-retention 4 --partition-count 15
az eventhubs eventhub consumer-group create --resource-group $rg --name $ehConsumerGroup --namespace-name $ehNamespace --eventhub-name $ehName

#store event hub connection string in key vault, and bind key vault to function app settings for event hub trigger use
Write-Host "Store EH Secret in KV"
$ehcs = $(az eventhubs namespace authorization-rule keys list --resource-group $rg --namespace-name $ehNamespace --name RootManageSharedAccessKey --query primaryConnectionString --output tsv)
$kvEHSecretValue = "$ehcs;EntityPath=$ehName"

az keyvault secret set --name $kvEHSecretName --value $kvEHSecretValue --description FunctionAppsecret  --vault-name $kvName
$ehsecretURI = $(az keyvault secret show --name $kvEHSecretName --vault-name $kvName --query id --output tsv)

#bind app setting / environment variable for Azure Function app to key vault secret URI.  Note the extra space for parsing the secret.
Write-Host "Bind App Setting for KV Secret for Sender"
az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$faEventHubAppConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "

Write-Host "Bind App Setting for KV Secret for Receiver"
az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$faEventHubAppConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "

#storage account for function app
Write-Host "Get SA Settings"
$saKey = $(az storage account keys list -n $saName -g $rg --query [0].value --output tsv)
$kvSASecretValue = "DefaultEndpointsProtocol=https;AccountName=$saName;AccountKey=$saKey;EndpointSuffix=core.windows.net"

az keyvault secret set --name $kvSASecretName --value $kvSASecretValue --description FunctionAppsecret  --vault-name $kvName
$sasecretURI = $(az keyvault secret show --name $kvSASecretName --vault-name $kvName --query id --output tsv)

Write-Host "Bind App Setting for KV Secret for Sender"
az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$faStorageAccountConfig=@Microsoft.KeyVault(SecretUri=$sasecretURI) "

Write-Host "Bind App Setting for KV Secret for Receiver"
az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$faStorageAccountConfig=@Microsoft.KeyVault(SecretUri=$sasecretURI) "


#clean up.  for now broken out for clarity.
Write-Host "Broken out secrets for EH in KV + Binding"
$kvEHHostNameSecretValue = "$ehNamespace.servicebus.windows.net"
az keyvault secret set --name $kvEHHostNameSecretName --value $kvEHHostNameSecretValue --description FunctionAppsecret  --vault-name $kvName
$ehsecretURI = $(az keyvault secret show --name $kvEHHostNameSecretName --vault-name $kvName --query id --output tsv)

az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$faEHHostNameConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "
az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$faEHHostNameConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "

$kvEHSasSecretValue = "RootManageSharedAccessKey"
az keyvault secret set --name $kvEHSasPolicyConfigName --value $kvEHSasSecretValue --description FunctionAppsecret  --vault-name $kvName
$ehsecretURI = $(az keyvault secret show --name $kvEHSasPolicyConfigName --vault-name $kvName --query id --output tsv)

az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$faEHSasPolicyConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "
az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$faEHSasPolicyConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "

$kvEHSasKeySecretValue = $(az eventhubs namespace authorization-rule keys list --resource-group $rg --namespace-name $ehNamespace --name RootManageSharedAccessKey --query primaryKey --output tsv)
az keyvault secret set --name $kvEHSasKeyName --value $kvEHSasKeySecretValue --description FunctionAppsecret  --vault-name $kvName
$ehsecretURI = $(az keyvault secret show --name $kvEHSasKeyName --vault-name $kvName --query id --output tsv)

az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$faEHSasKeyConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "
az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$faEHSasKeyConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "

$kvEHNameSecretValue = $ehName
az keyvault secret set --name $kvEhName --value $kvEHNameSecretValue --description FunctionAppsecret  --vault-name $kvName
$ehsecretURI = $(az keyvault secret show --name $kvEhName --vault-name $kvName --query id --output tsv)

az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$faEHNameConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "
az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$faEHNameConfig=@Microsoft.KeyVault(SecretUri=$ehsecretURI) "

## Make sure to use az login --use-device-code
Write-Host "Attempt to deploy function apps"
if ($usePushDeploy)
{
    #Set Function App Settings for Deployment.
    #used for deployment.  For Azure DevOps, set this to false.  For zip deploy, set it to true.
    $faEnableOryxBuildConfig = "ENABLE_ORYX_BUILD"
    $faEnableOryxBuildConfigValue = "true"

    #used for deployment.  For Azure DevOps, set this to false.  For zip deploy, set it to true.
    $faScmDoBuildDuringDeploymentConfig = "SCM_DO_BUILD_DURING_DEPLOYMENT"
    $faScmDoBuildDuringdeploymentConfigValue = "true"

    az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$faEnableOryxBuildConfig=$faEnableOryxBuildConfigValue) "
    az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$faEnableOryxBuildConfig=$faEnableOryxBuildConfigValue) "
    az functionapp config appsettings set --name $sendFaName --resource-group $rg --settings "$faScmDoBuildDuringDeploymentConfig=$faScmDoBuildDuringdeploymentConfigValue) "
    az functionapp config appsettings set --name $receiveFaName --resource-group $rg --settings "$faScmDoBuildDuringDeploymentConfig=$faScmDoBuildDuringdeploymentConfigValue) "

    
    ### zip deploy (from a VM in the VNET allowed to access scm):
    # in the zip folder, this should sit at the function app root; do not include .venv / .python_packages as the runtimes may be different.
    # this also assumes the environment that we're using will also have network connectivity to communicate with the ASE.
    $sendFaZipPath = ".\az-mon-eh-send-kv-python.zip"
    if ($(Test-Path $sendFaZipPath) -eq $True)
    {
        Write-Host "Found the send function app zip"
        $sendPublishProfileObject = $(az functionapp deployment list-publishing-profiles -n $sendFaName -g $rg --query "[?publishMethod=='MSDeploy'].{userName:userName, userPWD:userPWD}" | ConvertFrom-Json)
        $userCred = $sendPublishProfileObject.userName + ":" + $sendPublishProfileObject.userPWD
        $auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$usercred"))
        Invoke-WebRequest -Uri "https://$sendFaName.scm.azurewebsites.net/api/zipdeploy" -Method POST -InFile $sendFaZipPath -Headers @{ "Authorization" = "Basic $auth" } -ContentType "application/zip"
        
        Write-Host "Check on send app deployments"
        Invoke-WebRequest -Uri "https://$sendFaName.scm.azurewebsites.net/api/deployments" -Method POST -Headers @{ "Authorization" = "Basic $auth" } -ContentType "application/json"
    }
    else 
    {
        Write-Host "Did not find send function app zip"
    }

    $receiveFaZipPath = ".\az-mon-eh-receive-kv-python.zip"
    if ($(Test-Path $receiveFaZipPath) -eq $True)
    {
        Write-Host "Found the receive function app zip"
        $receivePublishProfileObject = $(az functionapp deployment list-publishing-profiles -n $receiveFaName -g $rg --query "[?publishMethod=='MSDeploy'].{userName:userName, userPWD:userPWD}" | ConvertFrom-Json)
        $userCred = $receivePublishProfileObject.userName + ":" + $receivePublishProfileObject.userPWD
        $auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$usercred"))
        Invoke-WebRequest -Uri "https://$receiveFaName.scm.azurewebsites.net/api/zipdeploy" -Method POST -InFile $receiveFaZipPath -Headers @{ "Authorization" = "Basic $auth" } -ContentType "application/zip"

        #check on the deployments
        Write-Host "Check on receive app deployments"
        Invoke-WebRequest -Uri "https://$receiveFaName.scm.azurewebsites.net/api/deployments" -Method POST -Headers @{ "Authorization" = "Basic $auth" } -ContentType "application/json"
    }
    else 
    {
        Write-Host "Did not find receive function app zip"
    }
}
else
{
    #deploy azure function https://github.com/Azure/azure-functions-core-tools

    ##assumes that we're in a folder that has sub folders for each function
    ##root
    ## .\scenario1
    ## .\scenario1\FunctionTrigger
    ## .\scenario2
    ## .\scenario2\FunctionTrigger
    ## .\deploy.ps1

    Write-Host "Publishing Send Function"
    Push-Location $sendFaFolder
    #might need to check if the publish was successful, or run twice?
    func azure functionapp publish $sendFaName
    func azure functionapp publish $sendFaName
    Pop-Location

    Write-Host "Publishing Receive Function"
    Push-Location $receiveFaFolder
    func azure functionapp publish $receiveFaName
    func azure functionapp publish $receiveFaName
    Pop-Location
}

#Add HTTP trigger for Action Group and Alert from Azure Monitor.  Need to have the Function Deployed first to get the function URL?

Write-Host "Add Alert for Sender App"
$faSender = $(az functionapp show -n $sendFaName -g $rg)
$faSenderObject = $faSender | ConvertFrom-Json
$faSenderId = $faSenderObject.id
#https://stackoverflow.com/questions/46338239/retrieve-the-host-keys-from-an-azure-function-app
$faSendKey = $(az rest --method post --uri "$faSenderId/host/default/listKeys?api-version=2018-11-01" --query functionKeys.default --output tsv)

$faHostName = $faSenderObject.defaultHostName
$faSendURI = "https://$faHostName/$sendURIPath" + "?code=$faSendKey"
#$faSendURI = "https://mysendfunctionappmagqs.azurewebsites.net/api/sendalerthttptrigger?code=3UDKzMxpmrt57FLAEkS712m83WOcWFSwyzuUvX0sBwycEAp9lLrWOA=="
##az monitor action-group create -g $rg -n MyActionGroup --action NAME FUNCTION_APP_RESOURCE_ID FUNCTION_NAME HTTP_TRIGGER_URL [usecommonalertschema]
$sendActionGroup = $(az monitor action-group create -g $rg -n $sendActionGroupName -a azurefunction $sendActionGroupReceiverName $faSenderObject.id $sendFuncName $faSendURI useCommonAlertSchema)
$sendActionGroupObject = $sendActionGroup | ConvertFrom-Json

$saId = $(az storage account show -n $saName -g $rg --query id -o tsv)
##simpler metric alert on storage account.
$saAlert = $(az monitor metrics alert create -n $saAlertName -g $rg --scopes $saId --evaluation-frequency 1m --window-size 1m --action $sendActionGroupObject.id --description "Storage Transactions" --condition "total transactions >= 0")

$saAlert

$vmId = $(az vm show -g $rg -n $vmName --query id -o tsv)
$vmAlert = $(az monitor metrics alert create -n $vmAlertName -g $rg --scopes $vmId --evaluation-frequency 1m --window-size 1m --action $sendActionGroupObject.id --description "Percentage CPU Used" --condition "avg Percentage CPU >= 0")

$vmAlert

##restart a VM
##az vm restart --ids $(az vm list -g $rg --query "[].id" -o tsv)
az vm stop --ids $vmId
#wait for a minute to start up the VM again.
sleep 60
az vm start --ids $vmId


#add network restriction on function app for sender.
Write-host "Add Azure Monitor Service Tags for Function App (Sender) to restrict inbound network access"
$priority = 10
$index = 0
##load service tags from here: https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_20200106.json
$azureMonitorServiceTags = Get-Content .\serviceTags.json
$azureMonitorServiceTagsObject = $azureMonitorServiceTags | ConvertFrom-Json
$azureMonitorServiceTagsObject.properties.addressPrefixes.ForEach({ 
    az functionapp config access-restriction add -g $rg -n $sendFaName --rule-name "$ruleName-$index" --action Allow --ip-address $_ --priority $priority;
    $priority += 10;
    $index += 1;
    Write-Host "Added Rule for $addressPrefix"
})

#similarly, we can also restrict SCM access too.
###az functionapp config access-restriction add -g $rg -n $sendFaName --rule-name "Developer SCM" --action Allow --vnet-name $vnetName --subnet $vmSubnetName --ignore-missing-endpoint true --priority 250 --scm-site true