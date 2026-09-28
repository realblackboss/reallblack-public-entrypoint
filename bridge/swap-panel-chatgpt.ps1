$ErrorActionPreference = 'Stop'

$Root = Join-Path $env:USERPROFILE 'Desktop\ponte git'
$Server = Join-Path $Root 'server.mjs'
$StartScript = Join-Path $Root 'Iniciar.ps1'
$AppJs = Join-Path $Root 'public\app.js'
$IndexHtml = Join-Path $Root 'public\index.html'
$Runner = Join-Path $Root 'chatgpt-executor.mjs'
$Runtime = Join-Path $Root '.runtime'
$KeyFile = Join-Path $Runtime 'openai.key'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ExpectedRunnerHash = 'de6cbd6d929bcef9b139f695d67ebd0121605696187859590308846734afb488'
$RunnerUrl = 'https://raw.githubusercontent.com/realblackboss/reallblack-public-entrypoint/main/bridge/chatgpt-executor.mjs'
$TempRunner = Join-Path $Runtime 'chatgpt-executor.download.mjs'

function Write-Utf8NoBom([string]$Path,[string]$Text) {
  [IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)
}

function Convert-SecureToPlain([Security.SecureString]$Secure) {
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Stop-PontePanel {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like ('*' + $Root + '*server.mjs*') } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
  Start-Sleep -Milliseconds 700
}

foreach($p in @($Root,$Server,$StartScript,$AppJs,$IndexHtml)) {
  if(-not (Test-Path -LiteralPath $p)) { throw "Arquivo/pasta obrigatório não encontrado: $p" }
}

$serverBefore = Get-Content -LiteralPath $Server -Raw
if($serverBefore -match 'chatgpt-executor\.mjs') {
  Write-Host 'O painel já está configurado para o executor ChatGPT. Nenhuma alteração duplicada foi aplicada.' -ForegroundColor Yellow
  exit 0
}

New-Item -ItemType Directory -Path $Runtime -Force | Out-Null

if(Test-Path -LiteralPath $KeyFile) {
  $secure = Get-Content -LiteralPath $KeyFile -Raw | ConvertTo-SecureString
} else {
  Write-Host ''
  Write-Host 'Cole sua OPENAI API KEY. Ela não será exibida nem enviada para o chat.' -ForegroundColor Cyan
  $secure = Read-Host 'OPENAI API KEY' -AsSecureString
  $secure | ConvertFrom-SecureString | Set-Content -LiteralPath $KeyFile -Encoding ASCII
}
$plainKey = Convert-SecureToPlain $secure
if([string]::IsNullOrWhiteSpace($plainKey)) { throw 'A chave da OpenAI está vazia.' }
$env:OPENAI_API_KEY = $plainKey
if([string]::IsNullOrWhiteSpace($env:OPENAI_MODEL)) { $env:OPENAI_MODEL = 'gpt-5.6' }

Write-Host 'Baixando executor ChatGPT validado...' -ForegroundColor Cyan
Remove-Item -LiteralPath $TempRunner -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -UseBasicParsing -Uri $RunnerUrl -OutFile $TempRunner -TimeoutSec 30
$hash = (Get-FileHash -LiteralPath $TempRunner -Algorithm SHA256).Hash.ToLowerInvariant()
if($hash -ne $ExpectedRunnerHash) { throw 'Falha de integridade: hash do executor ChatGPT não confere.' }

$Node = (Get-Command node.exe -ErrorAction Stop).Source
& $Node --check $TempRunner
if($LASTEXITCODE -ne 0) { throw 'O executor ChatGPT baixado possui erro de sintaxe.' }

Write-Host 'Validando acesso ao modelo ChatGPT...' -ForegroundColor Cyan
$statusOutput = & $Node $TempRunner --status 2>&1
if($LASTEXITCODE -ne 0) { throw ('A conexão ChatGPT/API não foi validada: ' + (($statusOutput | Out-String).Trim())) }

$ProbeWorkspace = Join-Path $Root 'workspace'
New-Item -ItemType Directory -Path $ProbeWorkspace -Force | Out-Null
$probeMeta = @{workspace=$ProbeWorkspace;mode='read-only';additionalDirs=@()} | ConvertTo-Json -Compress
$env:PONTE_JOB = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probeMeta))
$probeOutput = 'Responda exatamente PONTE_CHATGPT_OK. Não use ferramentas.' | & $Node $TempRunner 2>&1
Remove-Item Env:PONTE_JOB -ErrorAction SilentlyContinue
if($LASTEXITCODE -ne 0 -or (($probeOutput | Out-String) -notmatch 'PONTE_CHATGPT_OK')) {
  throw ('O teste real do executor ChatGPT falhou: ' + (($probeOutput | Out-String).Trim()))
}

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup = Join-Path $Root ('checkpoints\executor-chatgpt-' + $Stamp)
New-Item -ItemType Directory -Path (Join-Path $Backup 'public') -Force | Out-Null
Copy-Item -LiteralPath $Server -Destination (Join-Path $Backup 'server.mjs') -Force
Copy-Item -LiteralPath $StartScript -Destination (Join-Path $Backup 'Iniciar.ps1') -Force
Copy-Item -LiteralPath $AppJs -Destination (Join-Path $Backup 'public\app.js') -Force
Copy-Item -LiteralPath $IndexHtml -Destination (Join-Path $Backup 'public\index.html') -Force
$HadRunner = Test-Path -LiteralPath $Runner
if($HadRunner) { Copy-Item -LiteralPath $Runner -Destination (Join-Path $Backup 'chatgpt-executor.mjs') -Force }
$BackupReady = $true

try {
  Move-Item -LiteralPath $TempRunner -Destination $Runner -Force

  $diagBlock = @'
async function diagnose(){
 const [g,c]=await Promise.allSettled([gh(['api','user','--jq','.login']),run(process.execPath,[chatgptRunner,'--status'],{timeout:15000})]);
 checks={github:g.status==='fulfilled'?g.value.trim():null,githubError:g.status==='rejected'?g.reason.message:'',chatgpt:c.status==='fulfilled'&&c.value.code===0,chatgptMessage:c.status==='fulfilled'?redact(c.value.out+c.value.err):c.reason.message};checks.checkedAt=new Date().toISOString();checks.project=projectHealth(config.workspace);checks.node=process.version;return checks;
}
'@
  $spawnLine = @'
 const child=spawn(process.execPath,[chatgptRunner],{cwd:j.workspace,windowsHide:true,shell:false,stdio:['pipe','pipe','pipe'],env:{...process.env,PONTE_JOB:Buffer.from(JSON.stringify({workspace:j.workspace,mode:j.mode,additionalDirs:j.additionalDirs||[]}),'utf8').toString('base64')}});active={job:j,child};
'@.Trim()

  $out = New-Object System.Collections.Generic.List[string]
  foreach($line in [IO.File]::ReadAllLines($Server)) {
    $trim = $line.TrimStart()
    if($trim.StartsWith("const bin=path.join(process.env.LOCALAPPDATA")) { continue }
    if($trim.StartsWith('try{const dirs=fs.readdirSync(bin)')) { continue }
    if($trim.StartsWith("tools.codex||='codex.exe'")) { continue }
    if($trim.StartsWith('async function diagnose(){')) {
      foreach($x in ($diagBlock -split "`r?`n")) { if($x -ne '') { [void]$out.Add($x) } }
      continue
    }
    if($trim.StartsWith('const child=spawn(tools.codex,')) {
      [void]$out.Add($spawnLine)
      continue
    }
    $patched = $line.Replace('parseRemote,codexArgs,killTree','parseRemote,killTree')
    $patched = $patched.Replace('tarefas Codex','tarefas ChatGPT')
    $patched = $patched.Replace('A conexão externa do ChatGPT é configurada separadamente.','O executor ChatGPT usa a conexão OpenAI configurada neste PC.')
    $patched = $patched.Replace('Boolean(checks.codex)','Boolean(checks.chatgpt)')
    [void]$out.Add($patched)
    if($trim.StartsWith('const tools={')) { [void]$out.Add("const chatgptRunner=path.join(APP,'chatgpt-executor.mjs');") }
  }
  Write-Utf8NoBom $Server (($out -join "`n") + "`n")

  $app = Get-Content -LiteralPath $AppJs -Raw
  $app = $app.Replace('snapshot.checks.codexMessage','snapshot.checks.chatgptMessage')
  $app = $app.Replace('snapshot.checks.codex','snapshot.checks.chatgpt')
  $app = $app.Replace('Codex: ','ChatGPT: ')
  $app = $app.Replace('Codex autenticado','ChatGPT conectado')
  $app = $app.Replace('Escrita pelo Codex','Escrita pelo ChatGPT')
  $app = $app.Replace('o Codex pode','o ChatGPT pode')
  Write-Utf8NoBom $AppJs $app

  $html = Get-Content -LiteralPath $IndexHtml -Raw
  $html = $html.Replace('GitHub + Codex','GitHub + ChatGPT')
  $html = $html.Replace('<span>CODEX</span>','<span>CHATGPT</span>')
  $html = $html.Replace('Usa sua conexão existente','Usa o executor ChatGPT configurado neste PC')
  $html = $html.Replace('O Codex trabalha','O ChatGPT trabalha')
  Write-Utf8NoBom $IndexHtml $html

  $start = Get-Content -LiteralPath $StartScript -Raw
  if($start -notmatch 'openai\.key') {
    $needle = "New-Item -ItemType Directory -Path `$runtime -Force | Out-Null"
    $inject = @'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
if(-not $env:OPENAI_API_KEY){
 $keyFile=Join-Path $runtime 'openai.key'
 if(-not (Test-Path -LiteralPath $keyFile)){throw 'Chave OpenAI ausente. Execute novamente o instalador ChatGPT da Ponte Git.'}
 $secure=Get-Content -LiteralPath $keyFile -Raw | ConvertTo-SecureString
 $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
 try{$env:OPENAI_API_KEY=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
}
if(-not $env:OPENAI_MODEL){$env:OPENAI_MODEL='gpt-5.6'}
'@
    if(-not $start.Contains($needle)) { throw 'Não encontrei o ponto seguro para carregar a chave no Iniciar.ps1.' }
    $start = $start.Replace($needle,$inject.TrimEnd())
    Write-Utf8NoBom $StartScript $start
  }

  foreach($f in @($Runner,$Server,$AppJs)) {
    & $Node --check $f
    if($LASTEXITCODE -ne 0) { throw "Erro de sintaxe após alteração: $f" }
  }

  $after = Get-Content -LiteralPath $Server -Raw
  if($after -match 'spawn\(tools\.codex' -or $after -match 'OpenAI.+Codex.+bin') { throw 'Ainda existe chamada ativa ao executor Codex no servidor.' }
  if($after -notmatch 'spawn\(process\.execPath,\[chatgptRunner\]') { throw 'A nova chamada do executor ChatGPT não foi instalada.' }

  Stop-PontePanel
  & $StartScript
  Start-Sleep -Seconds 1

  $access = Get-Content -LiteralPath (Join-Path $Runtime 'access.json') -Raw | ConvertFrom-Json
  $baseUri = 'http://' + '127.0.0.1:' + [string]$access.port
  $health = Invoke-RestMethod -Uri ($baseUri + '/health') -TimeoutSec 5
  if($health.app -ne 'ponte-git') { throw 'O painel não respondeu ao health-check.' }
  $headers = @{'X-Ponte-Token'=[string]$access.token}
  $diag = Invoke-RestMethod -Method Post -Uri ($baseUri + '/api/diagnose') -Headers $headers -ContentType 'application/json' -Body '{}' -TimeoutSec 20
  if(-not $diag.chatgpt) { throw ('ChatGPT não ficou disponível no painel: ' + [string]$diag.chatgptMessage) }

  Write-Host ''
  Write-Host 'ALTERAÇÃO CONCLUÍDA.' -ForegroundColor Green
  Write-Host ('Executor: ChatGPT / ' + $env:OPENAI_MODEL)
  Write-Host ('GitHub: ' + [string]$diag.github)
  Write-Host 'Estrutura visual, histórico, Nova tarefa, GitHub, MCP e pasta do projeto foram preservados.'
  Write-Host 'O botão Nova tarefa não chama mais o Codex.' -ForegroundColor Green
  Write-Host ('Checkpoint: ' + $Backup)
} catch {
  $failure = $_.Exception.Message
  Write-Host ''
  Write-Host ('Falha na troca: ' + $failure) -ForegroundColor Red
  if($BackupReady) {
    Write-Host 'Revertendo automaticamente para a versão anterior...' -ForegroundColor Yellow
    Copy-Item -LiteralPath (Join-Path $Backup 'server.mjs') -Destination $Server -Force
    Copy-Item -LiteralPath (Join-Path $Backup 'Iniciar.ps1') -Destination $StartScript -Force
    Copy-Item -LiteralPath (Join-Path $Backup 'public\app.js') -Destination $AppJs -Force
    Copy-Item -LiteralPath (Join-Path $Backup 'public\index.html') -Destination $IndexHtml -Force
    if($HadRunner) { Copy-Item -LiteralPath (Join-Path $Backup 'chatgpt-executor.mjs') -Destination $Runner -Force }
    else { Remove-Item -LiteralPath $Runner -Force -ErrorAction SilentlyContinue }
    try { Stop-PontePanel; & $StartScript } catch {}
  }
  throw ('Alteração revertida. Motivo: ' + $failure)
} finally {
  Remove-Item -LiteralPath $TempRunner -Force -ErrorAction SilentlyContinue
  Remove-Item Env:PONTE_JOB -ErrorAction SilentlyContinue
  $plainKey = $null
}
