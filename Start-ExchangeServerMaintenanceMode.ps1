<#
.Synopsis
   Script to automatically put an Exchange 2013 Server into Maintenance Mode.

   Current Version: 1.8

   Version History:
   ----------------
   v1.8: fixed copy/paste bug (AGAIN!); removed code twice; made some overall improvements while at it :-)
   v1.7: removed the need to dot-source the script first
   v1.6: bugfixes in the pre-run checks
   v1.5: included code to restart transport services after changing component state, included check for Exchange 2013 server
         General code improvements. Better remoting support (script can now be executed from a remote server, even for DAG members)
         Better error-handling, improved logic
   v1.4: included additional error handling. Script will now check for local Admin rights and try to resolve the TargetServerFQDN. 
         If not an error is thrown and the script execution aborted.
   v1.3: included code to redirect messages from the server that is to be put in maintenance mode to another server.
   v1.2: included code to exclude poision a Shadow Redundancy queue when checking if all queues were empty

   Credits:
   --------
   Checking for admin credentials:
   http://blogs.technet.com/b/heyscriptingguy/archive/2011/05/11/check-for-admin-credentials-in-a-powershell-script.aspx

.DESCRIPTION
   This script is created to automatically put an Exchange 2013 Server into Maintenance Mode. 
   It will automatically detect if the server is a Mailbox Server and then take appropriate additional actions, if any.

.EXAMPLE
   Running the following command will place a server called "Server1" into Maintenance Mode and move any messages in transit from that server to "Server2".
   Please note that the TargetServer value has to be a FQDN!

   Start-ExchangeServerMaintenanceMode.ps1 -Server Server1 -TargetServerFQDN Server2.domain.com
#>

[CmdletBinding()]
[OutputType([int])]
Param
(
    # determine what server to put in maintenance mode
    [Parameter(Mandatory=$true,
               ValueFromPipelineByPropertyName=$true,
               Position=0)]
    [string]$Server=$env:COMPUTERNAME,

    [Parameter(Mandatory=$false,
               ValueFromPipelineByPropertyName=$true,
               Position=1)]
    [string]$TargetServerFQDN
)

function evaluatequeues(){
    $MessageCount = Get-Queue -Server $Server | ?{$_.Identity -notlike "*\Poison" -and $_.Identity -notlike"*\Shadow\*"} | Select MessageCount
    $count = 0
    Foreach($message in $MessageCount){
        $count += $message.messageCount
    }
    if($count -ne 0){
        Write-Output "INFO: Sleeping for 60 seconds before checking the transport queues again..." -ForegroundColor Yellow
        Start-Sleep -s 30
        evaluatequeues
    }
    else{
        Write-Host "INFO: Transport queues are empty." -ForegroundColor Yellow
        Write-Host "INFO: Putting the entire server into maintenance mode..." -ForegroundColor Yellow
        if(Set-ServerComponentState $Server -Component ServerWideOffline -State Inactive -Requester Maintenance){
            Write-Host "INFO: Done! The components of $Server have successfully been placed into an inactive state!"
        }
        Write-Host "INFO: Restarting MSExchangeTransport service on server $Server..." -ForegroundColor Yellow
            #Restarting transport services based on info from http://blogs.technet.com/b/exchange/archive/2013/09/26/server-component-states-in-exchange-2013.aspx
            #Restarting the services will cause the transport services to immediately pick up the changed state rather than having to wait for a MA responder to take action
            Invoke-Command -ComputerName $Server {Restart-Service MSExchangeTransport | Out-Null}
        
        #restart FE Transport Services if server is also CAS
        if($discoveredServer.IsFrontendTransportServer -eq $true){
            Write-Host "INFO: Restarting the MSExchangeFrontEndTransport Service on server $Server..." -ForegroundColor Yellow
            Invoke-Command -ComputerName $Server {Restart-Service MSExchangeFrontEndTransport} | Out-Null
        }
        Write-Host "INFO: Done! Server $Server is put succesfully into maintenance mode!" -ForegroundColor Green
    }

}

$discoveredServer = Get-ExchangeServer -Identity $Server | Select IsHubTransportServer,IsFrontendTransportServer,AdminDisplayVersion

#Check for Administrative credentials
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")){
    Write-Warning "You do not have Administrator rights to run this script!`nPlease re-run this script as an Administrator!"
	Break
}


#check if the server is an Exchange 2013 server
if($discoveredServer.AdminDisplayVersion.Major -ne "15"){
    Write-Warning "The specified Exchange Server is not an Exchange 2013 server!"
    Write-Warning "Aborting script..."
    Break
}
else{

    if($discoveredServer.IsHubTransportServer -eq $True){
        if(-NOT ($TargetServerFQDN)){
            Write-Warning "TargetServerFQDN is required."
            $TargetServerFQDN = Read-Host -Prompt "Please enter the TargetServerFQDN: "
        }
        
        #Get the FQDN of the Target Server through DNS, even if the input is just a host name
        try{
            $TargetServer = ([System.Net.Dns]::GetHostByName($TargetServerFQDN)).Hostname
        }
        catch{
            Write-Warning "Could not resolve ServerFQDN: $TargetServerFQDN";break
        }

        if((Get-ExchangeServer -Identity $TargetServer | Select IsHubTransportServer).IsHubTransportServer -ne $True){
            Write-Warning "The target server is not a valid Mailbox server."
            Write-Warning "Aborting script..."
            Break
        }

        #Redirecting messages to target system
        Write-Host "INFO: Suspending Transport Service. Draining remaining messages..." -ForegroundColor Yellow
        Set-ServerComponentState $Server -Component HubTransport -State Draining -Requester Maintenance
        Redirect-Message -Server $Server -Target $TargetServer -Confirm:$false

        #suspending cluster node (if the server is part of a DAG)
        $mailboxserver = Get-MailboxServer -Identity $Server | Select DatabaseAvailabilityGroup
        if($mailboxserver.DatabaseAvailabilityGroup -ne $null){
            Write-Host "INFO: Server $Server is a member of a Database Availability Group. Suspending the node now." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "INFO: Node information:" -ForegroundColor Yellow
            Write-Host "-----------------------" -ForegroundColor Yellow
            Invoke-Command -ComputerName $Server -ArgumentList $Server {Suspend-ClusterNode $args[0]}
            Set-MailboxServer $Server -DatabaseCopyActivationDisabledAndMoveNow $true
            Set-MailboxServer $Server -DatabaseCopyAutoActivationPolicy Blocked
            Write-Host ""
            Write-Host ""
        }

        #Evaluate the Transport Queues and put into maintenance mode once all queues are empty
        evaluatequeues

    }
    else{
        Write-Host "INFO: Server $Server is a Client Access Server-only server." -ForegroundColor Yellow
        Write-Host "INFO: Putting the server components into inactive state" -ForegroundColor Yellow
        Set-ServerComponentState $Server -Component ServerWideOffline -State Inactive -Requester Maintenance
        Write-Host "INFO: Restarting transport services..." -ForegroundColor Yellow
        if(Invoke-Command -ComputerName $Server {Restart-Service MSExchangeFrontEndTransport | Out-Null}){
            Write-Host "INFO: Successfully restarted MSExchangeFrontEndTransport service" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "INFO: Done! Server $Server is put succesfully into maintenance mode!" -ForegroundColor Green
    }
}

