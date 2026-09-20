<#
  Workplace-Disk.ps1 — мережевий диск Workplace (Samba на Raspberry Pi).

  Перше налаштування (один раз на кожному ПК):
      powershell -ExecutionPolicy Bypass -File .\Workplace-Disk.ps1 -Install

  Далі диск підключається сам. Вручну:  InitDisk

  Скрипт не зберігає пароль: він лежить у Диспетчері облікових даних Windows (cmdkey).
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$RegisterTask,   # службовий режим: лише створення завдання (викликається з правами адміністратора)
    [string]$Server   = 'server',
    [string]$ServerIP = '192.168.31.218',
    [string]$Share    = 'Workplace',
    [string]$User     = 'vlad',
    [string]$Label    = 'Workplace',
    [string]$Letter   = 'W'
)

$ErrorActionPreference = 'Stop'
$unc   = "\\$Server\$Share"
$uncIP = "\\$ServerIP\$Share"

function Get-OurMapping {
    Get-SmbMapping -ErrorAction SilentlyContinue |
        Where-Object { $_.RemotePath -eq $unc -or $_.RemotePath -eq $uncIP } |
        Select-Object -First 1
}

function Get-FreeLetter {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($l in @($Letter) + @('V','U','T','S','R','Y','X')) {
        if ($used -notcontains $l) { return $l }
    }
    throw 'Немає вільної букви диска'
}

function Set-DriveLabel {
    # Назва диска в Провіднику. Ключ створюється для обох адрес: за іменем і за IP.
    foreach ($host_ in @($Server, $ServerIP)) {
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##$host_#$Share"
        try {
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -Path $key -Name '_LabelFromReg' -Value $Label -PropertyType String -Force | Out-Null
        } catch { }
    }
}

function Connect-Workplace {
    $m = Get-OurMapping
    if ($m -and (Test-Path "$($m.LocalPath)\" -ErrorAction SilentlyContinue)) {
        return $m.LocalPath.TrimEnd(':')   # уже підключений, нічого не робимо
    }

    # мертве підключення прибираємо, щоб звільнити букву
    if ($m) { try { Remove-SmbMapping -LocalPath $m.LocalPath -Force -ErrorAction SilentlyContinue } catch { } }

    $target = if ($m) { $m.LocalPath.TrimEnd(':') } else { Get-FreeLetter }

    foreach ($path in @($unc, $uncIP)) {
        & net.exe use "${target}:" $path /persistent:yes 2>&1 | Out-Null
        if (Test-Path "${target}:\" -ErrorAction SilentlyContinue) {
            Set-DriveLabel
            return $target
        }
    }
    throw "Не вдалося підключити $unc"
}

function New-HiddenLauncher {
    # powershell.exe навіть з -WindowStyle Hidden показує вікно консолі на долю секунди.
    # Обгортка на VBScript запускає його зовсім без вікна (0 = hidden).
    $dir = Join-Path $env:LOCALAPPDATA 'WorkplaceDisk'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $vbs = Join-Path $dir 'run-hidden.vbs'
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""' + $PSCommandPath + '""'
    @(
        'Set sh = CreateObject("WScript.Shell")'
        'sh.Run "' + $cmd + '", 0, False'
    ) -join "`r`n" | Set-Content -Path $vbs -Encoding ASCII
    return $vbs
}

function Register-WorkplaceTask {
    # Завдання виконується від імені поточного користувача і лише коли він у системі,
    # інакше підключений диск не буде видно в Провіднику.
    $vbs      = New-HiddenLauncher
    $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//nologo `"$vbs`""
    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10))
    )
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName "Workplace disk" -Action $action -Trigger $triggers `
            -Settings $settings -Principal $principal -Description "Підключає мережевий диск $Label" `
            -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Install-Workplace {
    Write-Host "Налаштування диска $Label ($unc)" -ForegroundColor Cyan

    # 1. Пароль Samba у Диспетчер облікових даних (запитає інтерактивно)
    Write-Host "`n1. Пароль Samba для користувача $User (вводиться один раз):" -ForegroundColor Yellow
    & cmdkey.exe "/add:$Server"   "/user:$User" '/pass'
    & cmdkey.exe "/add:$ServerIP" "/user:$User" '/pass'

    # 2. Підключення
    Write-Host "`n2. Підключаю диск..." -ForegroundColor Yellow
    $letter = Connect-Workplace
    Write-Host "   Готово: ${letter}: -> $unc" -ForegroundColor Green

    # 3. Автопідключення: при вході в систему і кожні 10 хвилин
    Write-Host "`n3. Автопідключення (Планувальник завдань)..." -ForegroundColor Yellow
    if (Register-WorkplaceTask) {
        Write-Host "   Завдання 'Workplace disk' створено" -ForegroundColor Green
    } else {
        # Планувальник вимагає прав адміністратора — просимо їх лише для цього кроку.
        # Сам диск підключається без адміністратора, інакше він не був би видимий у Провіднику.
        Write-Host "   Потрібні права адміністратора, з'явиться запит UAC..." -ForegroundColor Yellow
        $args_ = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -RegisterTask -Letter $Letter -Server $Server -ServerIP $ServerIP -Share $Share -User $User -Label `"$Label`""
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList $args_ -Wait -WindowStyle Hidden
        } catch { }

        if (Get-ScheduledTask -TaskName "Workplace disk" -ErrorAction SilentlyContinue) {
            Write-Host "   Завдання 'Workplace disk' створено" -ForegroundColor Green
        } else {
            # Запасний варіант без адміністратора: ярлик в автозавантаженні.
            # Спрацьовує при вході в систему, але не повторюється кожні 10 хвилин.
            $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Workplace disk.lnk'
            $sh  = New-Object -ComObject WScript.Shell
            $s   = $sh.CreateShortcut($lnk)
            $s.TargetPath = 'wscript.exe'
            $s.Arguments  = "//nologo `"$(New-HiddenLauncher)`""
            $s.Description = "Підключає мережевий диск $Label"
            $s.Save()
            Write-Host "   Без адміністратора: додано ярлик в автозавантаження." -ForegroundColor Yellow
            Write-Host "   Диск підключатиметься при вході в систему. Якщо сервер перезавантажиться" -ForegroundColor Yellow
            Write-Host "   під час роботи — виконай InitDisk." -ForegroundColor Yellow
        }
    }

    # 4. Команда InitDisk у профілі PowerShell
    Write-Host "`n4. Команда InitDisk..." -ForegroundColor Yellow
    $marker = '# --- Workplace disk ---'
    if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
    if ((Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue) -notmatch [regex]::Escape($marker)) {
        Add-Content -Path $PROFILE -Encoding utf8 -Value @"

$marker
function InitDisk { & "$PSCommandPath" @args }
"@
    }
    Write-Host "   Додано в $PROFILE" -ForegroundColor Green

    Write-Host "`nВсе. Диск ${letter}: підключатиметься сам. Вручну — команда InitDisk" -ForegroundColor Cyan
}

if ($RegisterTask) {
    if (-not (Register-WorkplaceTask)) { exit 1 }
} elseif ($Install) {
    Install-Workplace
} else {
    $letter = Connect-Workplace
    if ($MyInvocation.InvocationName -ne '') { Write-Host "${letter}: -> $unc" }
}