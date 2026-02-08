@echo off
setlocal

where python >nul 2>nul
if %errorlevel%==0 (
  set PY=python
) else (
  where py >nul 2>nul
  if %errorlevel%==0 (
    set PY=py -3
  ) else (
    echo Python not found. Attempting to install with winget...
    where winget >nul 2>nul
    if %errorlevel%==0 (
      winget install --id Python.Python.3 --exact --source winget
      set PY=python
    ) else (
      echo winget not found. Please install Python 3 manually.
      exit /b 1
    )
  )
)

%PY% -m pip install --upgrade pip
%PY% -m pip install requests

%PY% "%~dp0bridge.py"
endlocal
