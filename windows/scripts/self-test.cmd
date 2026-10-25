@echo off
setlocal
pushd "%~dp0"
start "" /wait "%~dp0StillCodexSwitcher.exe" --self-test --test-output "%TEMP%\StillCodexSwitcher-tests.txt"
set "TEST_RESULT=%ERRORLEVEL%"
if exist "%TEMP%\StillCodexSwitcher-tests.txt" type "%TEMP%\StillCodexSwitcher-tests.txt"
echo.
echo Test exit code: %TEST_RESULT%
echo No real Codex account was changed by these fixture tests.
popd
pause
exit /b %TEST_RESULT%
